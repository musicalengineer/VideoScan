"""Model backends behind one small interface, so the tool loop is written once.

    AnthropicBackend  — Messages API, native tool use, prompt caching, effort.
                        The client is anything with .messages.create(**kw):
                        the real SDK client, the scripted fake, or the
                        cassette player (dry run).
    OllamaBackend     — Ollama /api/chat with tools (local Mac, the M5 Ultra,
                        or Ollama Cloud). Same loop, same tools, $0.

A Conversation holds the provider-native messages for one scenario; history
across follow-up turns is just the same Conversation reused.
"""
from __future__ import annotations

import copy
import hashlib
import json
import os
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field

from . import costs
from .prompt import SYSTEM_PROMPT, system_blocks
from .toolbox import ollama_tool_schemas, tool_schemas


@dataclass
class ToolUse:
    id: str
    name: str
    input: dict


@dataclass
class ModelReply:
    tool_uses: list
    text: str
    stop_reason: str
    usage: dict
    latency_s: float
    raw: dict
    stop_details: dict | None = None


@dataclass
class Conversation:
    messages: list = field(default_factory=list)
    open_tool_uses: list = field(default_factory=list)   # [(id, name)] awaiting a result


class BackendError(Exception):
    def __init__(self, kind: str, detail: str, fatal: bool = False):
        super().__init__(f"{kind}: {detail}")
        self.kind, self.detail, self.fatal = kind, detail, fatal


def canonical_hash(obj) -> str:
    return hashlib.sha256(json.dumps(obj, sort_keys=True, ensure_ascii=False, default=str).encode()).hexdigest()[:16]


def _plain(x):
    """SDK objects / pydantic models → plain JSON data."""
    if hasattr(x, "to_dict"):
        return x.to_dict()
    if hasattr(x, "model_dump"):
        return x.model_dump()
    return json.loads(json.dumps(x, default=str))


def _strip_none(block: dict) -> dict:
    return {k: v for k, v in block.items() if v is not None}


class AnthropicBackend:
    provider = "anthropic"

    def __init__(self, client, model: str, *, effort: str = "medium", max_tokens: int = 6000,
                 prices: dict | None = None, recorder=None, keep_requests: bool = False, clock=time.monotonic,
                 strict_tools: str = "all"):
        self.client, self.model, self.effort, self.max_tokens = client, model, effort, max_tokens
        self.clock = clock
        self.price = costs.price_row(prices or costs.load_prices(), model)
        self.tools = tool_schemas(strict_tools)
        self.system = system_blocks()
        self.recorder = recorder
        self.requests: list[dict] = [] if keep_requests else None
        self.row_id, self.call_n = None, 0

    # -- turn context (cassettes / scripted fake key on the corpus row)
    def begin_turn(self, row: dict) -> None:
        self.row_id, self.call_n = row.get("id"), 0
        if hasattr(self.client, "begin_turn"):
            self.client.begin_turn(row)

    def new_conversation(self) -> Conversation:
        return Conversation()

    def _close_open(self, conv: Conversation, why: str) -> list:
        blocks = [{"type": "tool_result", "tool_use_id": tid, "is_error": True,
                   "content": f"not run: {why}"} for tid, _ in conv.open_tool_uses]
        conv.open_tool_uses = []
        return blocks

    def add_user_text(self, conv: Conversation, text: str) -> None:
        content = self._close_open(conv, "the turn ended") + [{"type": "text", "text": text}]
        conv.messages.append({"role": "user", "content": content})

    def add_tool_results(self, conv: Conversation, results: list, note: str | None = None) -> None:
        """results: [(tool_use_id, name, content_str, is_error)] — ALL in one user message."""
        done = {r[0] for r in results}
        content = [{"type": "tool_result", "tool_use_id": tid, "content": body, **({"is_error": True} if err else {})}
                   for tid, _, body, err in results]
        conv.open_tool_uses = [(t, n) for t, n in conv.open_tool_uses if t not in done]
        content = self._close_open(conv, "no result") + content
        if note:
            content.append({"type": "text", "text": note})
        conv.messages.append({"role": "user", "content": content})

    def request(self, conv: Conversation) -> dict:
        return {"model": self.model, "max_tokens": self.max_tokens, "system": self.system, "tools": self.tools,
                "messages": conv.messages, "cache_control": {"type": "ephemeral"},
                "output_config": {"effort": self.effort}}

    def ceiling_usd(self, conv: Conversation) -> float:
        req = self.request(conv)
        chars = len(json.dumps({k: req[k] for k in ("system", "tools", "messages")}, ensure_ascii=False, default=str))
        return costs.call_ceiling_usd(chars, self.max_tokens, self.price)

    def cost(self, usage: dict) -> float:
        return costs.cost_usd(usage, self.price)

    def call(self, conv: Conversation, timeout: float | None = None) -> ModelReply:
        kwargs = self.request(conv)
        snapshot = json.loads(json.dumps(kwargs, default=str))
        if self.requests is not None:
            self.requests.append(snapshot)
        client = self.client
        if timeout and hasattr(client, "with_options"):
            client = client.with_options(timeout=max(timeout, 1.0), max_retries=1)
        t0 = self.clock()
        try:
            resp = client.messages.create(**kwargs)
        except BackendError:
            raise
        except Exception as e:  # typed SDK errors are mapped, never swallowed silently
            raise map_anthropic_error(e) from e
        latency = self.clock() - t0
        d = _plain(resp)
        if self.recorder:
            self.recorder.save(self.model, self.row_id, self.call_n, snapshot, d, latency)
        self.call_n += 1
        content = [_strip_none(b) for b in d.get("content") or []]
        conv.messages.append({"role": "assistant", "content": content})
        uses = [ToolUse(b["id"], b["name"], b.get("input") or {}) for b in content if b.get("type") == "tool_use"]
        conv.open_tool_uses = [(u.id, u.name) for u in uses]
        u = d.get("usage") or {}
        usage = {"input": u.get("input_tokens") or 0, "output": u.get("output_tokens") or 0,
                 "cacheWrite": u.get("cache_creation_input_tokens") or 0,
                 "cacheRead": u.get("cache_read_input_tokens") or 0}
        text = " ".join(b.get("text", "") for b in content if b.get("type") == "text").strip()
        return ModelReply(uses, text, d.get("stop_reason") or "end_turn", usage, latency, d, d.get("stop_details"))


def map_anthropic_error(e: Exception) -> BackendError:
    name = type(e).__name__
    status = getattr(e, "status_code", None)
    fatal = name in ("AuthenticationError", "PermissionDeniedError", "NotFoundError") or status in (401, 403, 404)
    if name == "BadRequestError" or status == 400:
        fatal = True     # a malformed request will fail the same way on every turn
    msg = getattr(e, "message", None) or str(e)
    return BackendError(f"api_error:{status or name}", msg[:300], fatal=fatal)


# ---------------------------------------------------------------- Ollama

def _http_post(url: str, payload: dict, headers: dict, timeout: float) -> dict:
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), method="POST",
                                 headers={"Content-Type": "application/json", **headers})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


def _http_get(url: str, headers: dict, timeout: float) -> dict:
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


class OllamaBackend:
    provider = "ollama"

    def __init__(self, model: str, *, host: str = "http://localhost:11434", api_key: str | None = None,
                 seed: int = 0, num_ctx: int = 32768, prices: dict | None = None,
                 post=_http_post, get=_http_get, keep_requests: bool = False, recorder=None, turn_hook=None):
        self.model, self.host, self.seed, self.num_ctx = model, host.rstrip("/"), seed, num_ctx
        self.host_kind = "local" if any(h in self.host for h in ("localhost", "127.0.0.1", ".local", "192.168.", "10."))\
            else "cloud"
        self.price = costs.price_row(prices or costs.load_prices(), model, "ollama", self.host_kind)
        self.headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
        self.post, self.get = post, get
        self.tools = ollama_tool_schemas()
        self.requests: list[dict] = [] if keep_requests else None
        self.recorder = recorder
        self.row_id, self.call_n, self._ids = None, 0, 0
        self.turn_hook = turn_hook

    def check(self) -> None:
        try:
            tags = self.get(f"{self.host}/api/tags", self.headers, 5)
        except (urllib.error.URLError, OSError, ValueError) as e:
            raise BackendError("ollama_unreachable", f"{self.host}: {e}", fatal=True) from e
        names = {m.get("name") for m in tags.get("models", [])}
        if self.host_kind == "local" and self.model not in names and f"{self.model}:latest" not in names:
            raise BackendError("ollama_model_missing", f"{self.model} not pulled on {self.host}", fatal=True)

    def begin_turn(self, row: dict) -> None:
        self.row_id, self.call_n = row.get("id"), 0
        if self.turn_hook:
            self.turn_hook(row)

    def new_conversation(self) -> Conversation:
        return Conversation(messages=[{"role": "system", "content": SYSTEM_PROMPT}])

    def _close_open(self, conv, why):
        msgs = [{"role": "tool", "tool_name": n, "content": f"not run: {why}"} for _, n in conv.open_tool_uses]
        conv.open_tool_uses = []
        return msgs

    def add_user_text(self, conv, text):
        conv.messages += self._close_open(conv, "the turn ended")
        conv.messages.append({"role": "user", "content": text})

    def add_tool_results(self, conv, results, note=None):
        done = {r[0] for r in results}
        conv.open_tool_uses = [(t, n) for t, n in conv.open_tool_uses if t not in done]
        conv.messages += self._close_open(conv, "no result")
        for _, name, body, err in results:
            conv.messages.append({"role": "tool", "tool_name": name, "content": ("ERROR " if err else "") + body})
        if note:
            conv.messages.append({"role": "user", "content": note})

    def request(self, conv):
        return {"model": self.model, "messages": conv.messages, "tools": self.tools, "stream": False,
                "options": {"temperature": 0, "seed": self.seed, "num_ctx": self.num_ctx}}

    def ceiling_usd(self, conv):
        return 0.0

    def cost(self, usage):
        return costs.cost_usd(usage, self.price)

    def call(self, conv, timeout=None):
        payload = self.request(conv)
        snapshot = json.loads(json.dumps(payload, default=str))
        if self.requests is not None:
            self.requests.append(snapshot)
        t0 = time.monotonic()
        try:
            d = self.post(f"{self.host}/api/chat", payload, self.headers, max(timeout or 120, 1.0))
        except urllib.error.HTTPError as e:
            raise BackendError(f"ollama_http:{e.code}", str(e)[:300], fatal=e.code in (401, 403, 404)) from e
        except (urllib.error.URLError, OSError, TimeoutError) as e:
            raise BackendError("ollama_unreachable", str(e)[:300]) from e
        latency = time.monotonic() - t0
        if self.recorder:
            self.recorder.save(f"ollama-{self.model}", self.row_id, self.call_n, snapshot, d, latency)
        self.call_n += 1
        msg = copy.deepcopy(d.get("message") or {"role": "assistant", "content": ""})
        msg.setdefault("role", "assistant")
        conv.messages.append(msg)
        uses = []
        for tc in msg.get("tool_calls") or []:
            fn = tc.get("function") or {}
            args = fn.get("arguments") or {}
            if isinstance(args, str):
                try:
                    args = json.loads(args)
                except ValueError:
                    args = {"_unparsed": args}
            self._ids += 1
            uses.append(ToolUse(f"ollama_{self._ids}", fn.get("name") or "", args))
        conv.open_tool_uses = [(u.id, u.name) for u in uses]
        usage = {"input": d.get("prompt_eval_count") or 0, "output": d.get("eval_count") or 0,
                 "cacheWrite": 0, "cacheRead": 0}
        stop = "tool_use" if uses else ("max_tokens" if d.get("done_reason") == "length" else "end_turn")
        return ModelReply(uses, (msg.get("content") or "").strip(), stop, usage, latency, d)


# ---------------------------------------------------------------- cassettes

class Recorder:
    """--record: one JSON file per model call, keyed by row id and call number."""

    def __init__(self, root: str):
        self.root = root

    def save(self, model, row_id, n, request: dict, response: dict, latency_s: float = 0.0) -> None:
        d = os.path.join(self.root, model, str(row_id))
        os.makedirs(d, exist_ok=True)
        from .keys import scrub
        body = json.dumps({"requestHash": canonical_hash(request), "model": model, "row": row_id, "n": n,
                           "latencyS": round(latency_s, 3), "request": request, "response": response}, ensure_ascii=False, indent=1, default=str)
        with open(os.path.join(d, f"{n}.json"), "w", encoding="utf-8") as fh:
            fh.write(scrub(body))
