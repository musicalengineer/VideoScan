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
from pathlib import Path
import sys
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
    return parser.parse_args()


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


def render(line: str, include_system: bool) -> None:
    try:
        event = json.loads(line)
    except json.JSONDecodeError as error:
        print(f"⚠ malformed JSONL: {error}", flush=True)
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
    print(
        f"{marker}{local_time(event.get('timestamp'))} "
        f"{client} {speaker}{status}: {compact_text(event.get('text'))}",
        flush=True)


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
    if args.poll <= 0:
        print("error: --poll must be positive", file=sys.stderr)
        return 2
    initial_path = newest_log(args.log_dir)
    if initial_path is None:
        print(f"waiting for Hallie log in {args.log_dir}", flush=True)
    else:
        for line in existing_tail(initial_path, max(0, args.last)):
            render(line, args.all)

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
                render(line, args.all)
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
