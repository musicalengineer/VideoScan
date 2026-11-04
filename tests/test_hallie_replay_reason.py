"""WHY a Hallie replay lane answered nothing, as a publishable code (2026-11-04).

The M4 and the Ultra both replayed 0 of 56 strict questions that night; the run
log said why in one line ("hallie: catalog.sqlite would not open for reading:
the database is read-only and its schema is not current") and the metrics card
said "incomplete (a few)". The replay now names the reason as a code the page
turns into words. Codes only: a path or a host never leaves the Mac."""
import importlib.util
import re
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("hallie_replay_reason", REPO / "scripts" / "hallie_replay_reason.py")
hrr = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hrr)

# The 11/04 strict run log, verbatim but for the home path.
LOG_1104 = """[eval] binary: /Users/x/Library/Caches/videoscan-nightly-dd/Build/Products/Release/VideoScan.app/Contents/MacOS/VideoScan (built 02:24:48)
[eval] 56 questions → /Users/x/dev/VideoScan/scripts/hallie --no-actions --log-run-id hallie-eval-20261104T025014-0e6f3610 --compose --host http://127.0.0.1:11434 --model llama3.3:70b
[eval] session finished in 1s (exit 2)
hallie: catalog.sqlite would not open for reading: the database is read-only and its schema is not current

[eval] wrote 0 paired turns → /Users/x/Library/Logs/VideoScan/hallie-eval/nightly-20261104T025013-strict.json
[eval] WARNING: 56 questions produced no matched turn: strict-001, strict-002 …
"""
CODE_RE = re.compile(r"^[a-z][a-z0-9-]{0,31}(?:[:=][a-z0-9=.:-]{1,24})?$")    # tools/publish_metrics.py CODE_RE


def test_the_1104_log_is_catalog_schema_not_current():
    assert hrr.reason(LOG_1104, completed=0) == "catalog-schema-not-current"


def test_a_lane_that_answered_something_has_no_did_not_run_reason():
    assert hrr.reason(LOG_1104, completed=3) is None


def test_each_known_refusal_has_its_code_and_unknown_is_no_turns():
    cases = {
        "hallie: nothing synced from RicksUltra.local yet — no catalog.sqlite with its catalog.cutover at /x": "catalog-not-synced",
        "hallie: /x/viewer-catalog/catalog.sqlite (the synced copy from RicksUltra.local) would not open for reading: "
        "the database is read-only and its schema is not current": "catalog-schema-not-current",
        "hallie: catalog.sqlite would not open for reading: could not open: disk I/O error": "catalog-unreadable",
        "hallie: no catalog.cutover beside /x/catalog.sqlite: this catalog was never switched to SQLite.": "catalog-not-switched",
        "hallie: no Debug or Release VideoScan executable found": "no-app-binary",
        "[eval] session finished in 900s (exit -9)": "no-turns",
    }
    for text, code in cases.items():
        assert hrr.reason(text, completed=0) == code, text
        assert CODE_RE.match(code), code


def test_the_replay_script_puts_the_reason_in_each_lane_row():
    script = (REPO / "scripts" / "nightly_hallie_replay.sh").read_text()
    assert "hallie_replay_reason.py" in script
    assert 'f"hallie_{name}_reason"' in script
