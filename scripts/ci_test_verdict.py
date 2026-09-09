#!/usr/bin/env python3
"""Fail-closed gate for CI's intentionally failing Swift Testing canary."""
import argparse
import re
from pathlib import Path


def problems(text, exit_code):
    text = re.sub(r"\x1b\[[0-9;]*m", "", text).replace("\u200b", "")
    lines = text.splitlines()
    failures = [s for s in lines if re.match(
        r"^(?:✘ Test (?!run with ).*failed after|Test Case .*failed)", s)]
    canary = [s for s in failures if re.match(r"^✘ Test mustFail\(\).*failed after", s)]
    errors = []
    diagnostics = "\n".join(s for s in lines if not re.match(r"^[✔✘◇] (?:Test|Suite) ", s))
    if re.search(r"(?:test runner|test host|test process).*crash|lost connection|failed to (?:launch|establish)|testing cancel[le]+d|test runner hung|testing.*timed out", diagnostics, re.IGNORECASE):
        errors.append("Possible test infrastructure failure; inspect the result bundle")
    if len(canary) != 1:
        errors.append("Expected exactly one failing canary")
    if not any(re.match(r"^✔ Test mustPass\(\).*passed after", s) for s in lines):
        errors.append("Passing canary missing")
    real = [s for s in failures if s not in canary]
    if real:
        errors.append(f"{len(real)} real test failure record(s): " + " | ".join(real))
    if not any(re.match(r"^✘ Test run with \d+ tests? .*failed after .* with 1 issue\.$", s) for s in lines):
        errors.append("Missing completed Swift Testing summary with only the canary issue")
    if exit_code != 65:
        errors.append(f"Unexpected xcodebuild exit {exit_code}; expected 65 for canary")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--exit-code", required=True, type=int)
    args = parser.parse_args()
    try:
        errors = problems(args.log.read_text(encoding="utf-8"), args.exit_code)
    except (OSError, UnicodeError) as error:
        errors = [f"Cannot read test evidence: {error}"]
    for error in errors:
        print(f"::error::{error}")
    if not errors:
        print("CI verdict: complete run; only the expected canary failed")
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
