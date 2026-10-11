"""Prices, per-call cost, and the HARD spend cap.

The cap is checked BEFORE every model call against a worst-case ceiling for
that call (all input billed as a cache write, the full max_tokens billed as
output). A call is only made when spent + ceiling <= cap, so the actual spend
of a run can never pass the cap, whatever the model does.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field

PRICES_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "prices.json")
CHARS_PER_TOKEN_FLOOR = 3.0   # conservative: real English+JSON runs ~3.5–4 chars/token
CEILING_MARGIN = 1.15         # +15% on the input estimate (tokenizer drift)


class SpendCapReached(Exception):
    pass


def load_prices(path: str = PRICES_PATH) -> dict:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def price_row(prices: dict, model: str, provider: str = "anthropic", host_kind: str = "local") -> dict:
    if provider == "ollama":
        return prices["ollama"][host_kind]
    if model not in prices["models"]:
        raise KeyError(f"no price for {model!r} in {PRICES_PATH}; add it before running")
    return prices["models"][model]


def cost_usd(usage: dict, row: dict) -> float:
    """usage keys: input, cacheWrite, cacheRead, output (token counts)."""
    return (usage.get("input", 0) * row["input"]
            + usage.get("cacheWrite", 0) * row["cacheWrite"]
            + usage.get("cacheRead", 0) * row["cacheRead"]
            + usage.get("output", 0) * row["output"]) / 1e6


def estimate_input_tokens(payload_chars: int) -> int:
    return int(payload_chars / CHARS_PER_TOKEN_FLOOR * CEILING_MARGIN) + 1


def call_ceiling_usd(payload_chars: int, max_tokens: int, row: dict) -> float:
    """Worst case for one call: every input token billed at the cache-write
    rate (the dearest input rate) and max_tokens of output (thinking included)."""
    worst_in = max(row["input"], row["cacheWrite"])
    return (estimate_input_tokens(payload_chars) * worst_in + max_tokens * row["output"]) / 1e6


@dataclass
class SpendCap:
    limit_usd: float
    spent_usd: float = 0.0
    calls: int = 0
    refused: list = field(default_factory=list)

    def check(self, ceiling_usd: float, what: str = "") -> None:
        if self.spent_usd + ceiling_usd > self.limit_usd:
            self.refused.append({"what": what, "spent": round(self.spent_usd, 6),
                                 "ceiling": round(ceiling_usd, 6), "limit": self.limit_usd})
            raise SpendCapReached(
                f"spend cap ${self.limit_usd:.2f}: spent ${self.spent_usd:.4f}, next call could cost up to "
                f"${ceiling_usd:.4f} — stopping the run")

    def add(self, usd: float) -> None:
        self.spent_usd += usd
        self.calls += 1


# Per-turn token model from the spec (§8) — used only by `estimate`, never for billing.
TURN_MODEL = {"fresh": 200, "cacheWrite": 3600, "cacheRead": 16000, "output": {"low": 875, "medium": 1750,
                                                                                 "high": 2600, "xhigh": 3500,
                                                                                 "max": 4500}}


def per_turn_estimate(row: dict, effort: str = "medium") -> float:
    t = TURN_MODEL
    return cost_usd({"input": t["fresh"], "cacheWrite": t["cacheWrite"], "cacheRead": t["cacheRead"],
                     "output": t["output"].get(effort, t["output"]["medium"])}, row)
