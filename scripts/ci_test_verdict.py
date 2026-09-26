#!/usr/bin/env python3
"""Fail-closed gate for CI's intentionally failing Swift Testing canary.

A run is accepted only when ALL of these hold:
  * exactly one failing canary (CICanaryTests.mustFail) and a passing mustPass;
  * no other failure record — neither a "✘ Test … failed after" line nor a
    "✘ Test … recorded an issue" line (a test that hits its time limit or
    takes the host down records the issue and may never print "failed
    after": CI run 36223041786);
  * the test host was never restarted by xcodebuild (a restart means a test
    crashed, hung or exceeded its time limit, and Swift Testing's final
    summary then covers only the LAST launch);
  * exactly one Swift Testing run summary, failed with the canary as its only
    issue that is not a known issue (withKnownIssue records count in the total);
  * xcodebuild's own exit code is 65 (tests failed — the canary).
"""
import argparse
import re
from pathlib import Path

RESTART = "Restarting after unexpected exit, crash, or test timeout"
CANARY_NAME = r"mustFail\(\)"


SUMMARY = re.compile(
    r"^✘ Test run with \d+ tests? .*failed after .* with (\d+) issues?"
    r"(?: \(including (\d+) known issues?\))?\.$")


def canary_only_summary(line):
    """True for a failed run summary whose only UNKNOWN issue is the canary.

    withKnownIssue records count in Swift Testing's total, so a complete
    run with the canary and three known issues prints
    "… with 4 issues (including 3 known issues)." (ricksm5, fix/ci-red-5,
    the first complete run of the whole plan ever fed to this gate).
    """
    match = SUMMARY.match(line)
    if not match:
        return False
    issues, known = int(match.group(1)), int(match.group(2) or 0)
    return issues - known == 1


def problems(text, exit_code):
    text = re.sub(r"\x1b\[[0-9;]*m", "", text).replace("​", "")
    lines = text.splitlines()
    failures = [s for s in lines if re.match(
        r"^(?:✘ Test (?!run with ).*failed after|Test Case .*failed)", s)]
    canary = [s for s in failures if re.match(rf"^✘ Test {CANARY_NAME}.*failed after", s)]
    # "recorded an issue" (NOT "recorded a known issue" — withKnownIssue is
    # an expected failure by design). The canary records one too.
    issues = [s for s in lines if re.match(r"^✘ Test (?!run with ).* recorded an issue\b", s)
              and not re.match(rf"^✘ Test {CANARY_NAME} recorded an issue\b", s)]
    errors = []
    diagnostics = "\n".join(s for s in lines if not re.match(r"^[✔✘◇] (?:Test|Suite) ", s))
    restarts = sum(1 for s in lines if RESTART in s)
    if restarts:
        errors.append(
            f"Test host restarted {restarts} time(s) by xcodebuild ('{RESTART}'): "
            "a test crashed, hung or exceeded its time limit; the Swift Testing summary "
            "covers only the last launch — see the ✘ lines and the result bundle's spindump")
    elif re.search(r"(?:test runner|test host|test process).*crash|lost connection|failed to (?:launch|establish)|testing cancel[le]+d|test runner hung|testing.*timed out", diagnostics, re.IGNORECASE):
        errors.append("Possible test infrastructure failure; inspect the result bundle")
    if len(canary) != 1:
        errors.append("Expected exactly one failing canary")
    if not any(re.match(r"^✔ Test mustPass\(\).*passed after", s) for s in lines):
        errors.append("Passing canary missing")
    real = [s for s in failures if s not in canary]
    if real:
        errors.append(f"{len(real)} real test failure record(s): " + " | ".join(real))
    if issues:
        errors.append(f"{len(issues)} test issue record(s) outside the canary: " + " | ".join(issues))
    summaries = [s for s in lines if re.match(r"^[✔✘] Test run with \d+ tests? ", s)]
    if not any(canary_only_summary(s) for s in summaries):
        seen = " | ".join(summaries) if summaries else "none"
        errors.append("Missing completed Swift Testing summary with only the canary issue "
                      f"(summaries seen: {seen})")
    elif len(summaries) > 1:
        errors.append(f"{len(summaries)} Swift Testing run summaries; expected exactly one: "
                      + " | ".join(summaries))
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
