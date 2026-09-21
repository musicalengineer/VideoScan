#!/usr/bin/env python3
"""Follow Hallie's rotating JSONL transcript as a compact QA conversation.

The production log retains full citations and paths. This watcher deliberately
prints only conversational fields and highlights turns that deserve review.
It never opens the catalog and never writes to the transcript.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import sys
import threading
import time


DEFAULT_LOG_DIR = Path.home() / "Library/Logs/VideoScan/Hallie"
FAILURE_OUTCOMES = {"declined", "unsupported", "error", "failed"}
FAILURE_PHRASES = (
    "i don't find",
    "i couldn't",
    "i can't",
    "i'm having trouble",
    "not supported",
    "nothing matched",
    "found nothing",
    "try a fuller name",
    "no evidence",
)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Follow and compactly parse Hallie's conversation log.")
    parser.add_argument("--log-dir", type=Path, default=DEFAULT_LOG_DIR)
    parser.add_argument(
        "--last", type=int, default=0,
        help="print the last N existing events before following")
    parser.add_argument(
        "--all", action="store_true",
        help="include system/reset events (hidden by default)")
    parser.add_argument("--poll", type=float, default=0.25)
    parser.add_argument("--color", choices=("auto", "always", "never"), default="auto",
                        help="color queries cyan and Hallie's answers green (default: terminals only)")
    return parser.parse_args()


def use_color(mode: str) -> bool:
    return mode == "always" or (mode == "auto" and sys.stdout.isatty() and "NO_COLOR" not in os.environ)


def newest_log(log_dir: Path) -> Path | None:
    logs = sorted(log_dir.glob("hallie-conversation-*.jsonl"))
    return logs[-1] if logs else None


def local_time(raw: object) -> str:
    if not isinstance(raw, str):
        return "--:--:--"
    try:
        stamp = dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
        return stamp.astimezone().strftime("%H:%M:%S")
    except ValueError:
        return raw[:8]


def compact_text(raw: object, limit: int = 500) -> str:
    text = " ".join(str(raw or "").split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def likely_failure(event: dict[str, object]) -> bool:
    outcome = str(event.get("outcome") or "").lower()
    route = str(event.get("route") or "").lower()
    kind = str(event.get("kind") or "").lower()
    text = str(event.get("text") or "").lower()
    return (
        kind == "error"
        or outcome in FAILURE_OUTCOMES
        or route.startswith("unsupported")
        or any(phrase in text for phrase in FAILURE_PHRASES)
    )


def render(line: str, include_system: bool, *, color: bool = False, stream=None) -> None:
    try:
        event = json.loads(line)
    except json.JSONDecodeError as error:
        print(f"⚠ malformed JSONL: {error}", file=stream, flush=True)
        return
    if not isinstance(event, dict):
        return
    kind = str(event.get("kind") or "unknown").lower()
    if kind == "system" and not include_system:
        return
    client = str(event.get("client") or "?").upper()
    speaker = "YOU" if kind == "user" else "HALLIE" if kind == "assistant" else kind.upper()
    route = event.get("route")
    outcome = event.get("outcome")
    status = ""
    if route or outcome:
        status = " [" + "/".join(
            str(value) for value in (route, outcome) if value) + "]"
    marker = "⚠ REVIEW " if likely_failure(event) else ""
    text = (f"{local_time(event.get('timestamp'))} "
            f"{client} {speaker}{status}: {compact_text(event.get('text'))}")
    if color:
        if marker:
            marker = f"\033[33m{marker}\033[0m"
        tint = {"user": "36", "assistant": "32", "error": "31"}.get(kind)
        if tint:
            text = f"\033[{tint}m{text}\033[0m"
    print(
        f"{marker}{text}",
        file=stream, flush=True)


class LiveTranscript:
    """Follow only one replay, without stealing stdout from its JSON results.

    Capture EOF before the replay starts; keep offsets across log rotation.
    Stop with a final drain so the last answer appears before grading starts.
    """

    def __init__(self, run_id: str, log_dir: Path = DEFAULT_LOG_DIR, *, stream=None):
        self.run_id = run_id
        self.log_dir = log_dir
        self.stream = stream if stream is not None else sys.stderr
        self._stop = threading.Event()
        self._offsets: dict[Path, int] = {}
        self._thread = None
        self.review_count = 0

    def __enter__(self):
        self._offsets = {p: p.stat().st_size for p in self.log_dir.glob("hallie-conversation-*.jsonl")}
        print("\033[36mQueries\033[0m · \033[32mHallie responses\033[0m · "
              "\033[33mReview flags\033[0m", file=self.stream, flush=True)
        self._thread = threading.Thread(target=self._follow, name="hallie-live-transcript", daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *_):
        self._stop.set()
        self._thread.join()

    def _follow(self):
        try:
            while not self._stop.wait(0.1):
                self._drain()
            self._drain()
        except (OSError, ValueError) as error:
            self.review_count = None  # An interrupted display is not a measured zero.
            print(f"Live transcript unavailable: {error}", file=self.stream, flush=True)

    def _drain(self):
        for path in sorted(self.log_dir.glob("hallie-conversation-*.jsonl")):
            offset = self._offsets.get(path, 0)
            size = path.stat().st_size
            if size == offset:
                continue
            with path.open("rb") as source:
                source.seek(offset if size >= offset else 0)
                while True:
                    start = source.tell()
                    raw = source.readline()
                    if not raw.endswith(b"\n"):
                        self._offsets[path] = start
                        break
                    self._offsets[path] = source.tell()
                    try:
                        line = raw.decode("utf-8")
                        event = json.loads(line)
                    except (UnicodeDecodeError, json.JSONDecodeError):
                        continue
                    if isinstance(event, dict) and event.get("runID") == self.run_id:
                        if str(event.get("kind") or "").lower() != "system" and likely_failure(event):
                            self.review_count += 1
                        render(line, False, color=True, stream=self.stream)


def existing_tail(path: Path, count: int) -> list[str]:
    if count <= 0:
        return []
    try:
        with path.open(encoding="utf-8") as source:
            return source.readlines()[-count:]
    except OSError:
        return []


def main() -> int:
    args = arguments()
    color = use_color(args.color)
    if args.poll <= 0:
        print("error: --poll must be positive", file=sys.stderr)
        return 2
    initial_path = newest_log(args.log_dir)
    if initial_path is None:
        print(f"waiting for Hallie log in {args.log_dir}", flush=True)
    else:
        for line in existing_tail(initial_path, max(0, args.last)):
            render(line, args.all, color=color)

    source = None
    current_path: Path | None = None
    try:
        while True:
            latest = newest_log(args.log_dir)
            if latest is None:
                time.sleep(args.poll)
                continue
            if latest != current_path:
                if source is not None:
                    source.close()
                source = latest.open(encoding="utf-8")
                # A newly rotated daily file must be read from its beginning;
                # the file present when the watcher starts begins at EOF.
                if current_path is None and latest == initial_path:
                    source.seek(0, 2)
                current_path = latest
                print(f"watching {latest}", flush=True)
            assert source is not None
            line = source.readline()
            if line:
                render(line, args.all, color=color)
                continue
            try:
                if source.tell() > latest.stat().st_size:
                    source.seek(0)
            except OSError:
                pass
            time.sleep(args.poll)
    except KeyboardInterrupt:
        return 0
    finally:
        if source is not None:
            source.close()


if __name__ == "__main__":
    raise SystemExit(main())
