"""scripts/complexity_backfill.py: commit choice, folder mapping for old
layouts, the row shape, and the publisher's handling of the stream (privacy
gate on backfill rows; CI's own rows kept verbatim). No git, no repo scan."""
from __future__ import annotations

import json
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tools"))

import complexity_backfill as bf  # noqa: E402
import complexity_metrics as cm  # noqa: E402
import publish_metrics as pm  # noqa: E402

UTC = timezone.utc


def history(days):
    """One commit per listed day (two on some), newest first."""
    out = []
    for i, d in enumerate(sorted(days, reverse=True)):
        out.append((f"{i:040x}", datetime(d.year, d.month, d.day, 15, 0, tzinfo=UTC)))
    return out


def test_choose_weekly_then_daily_oldest_first_no_duplicates():
    today = date(2026, 10, 5)
    days = [date(2026, 4, 16), date(2026, 4, 18), date(2026, 4, 30)] + \
           [today - timedelta(days=k) for k in range(0, 20)]
    picks = bf.choose_commits(history(days), date(2026, 4, 15), today, daily_days=14)
    when = [w.date() for _, w in picks]
    assert when == sorted(when) and len({s for s, _ in picks}) == len(picks)
    assert date(2026, 4, 18) in when and date(2026, 4, 16) not in when   # last of its week
    assert date(2026, 4, 30) in when
    assert all((today - timedelta(days=k)) in when for k in range(14))  # every recent day
    assert date(2026, 5, 6) not in when                                  # empty week: no row


def test_old_flat_layout_maps_by_file_name():
    current = ["VideoScan/VideoScan/Catalog/CatalogStore.swift", "VideoScan/VideoScan/People/PersonFinderView.swift",
               "VideoScan/VideoScanCore/Sources/X/A.swift", "scripts/a.py"]
    mapped = bf.folder_mapper(current)
    assert mapped("VideoScan/VideoScan/CatalogStore.swift") == "Catalog"          # flat, by name
    assert mapped("VideoScan/VideoScan/People/PersonFinderView.swift") == "People"  # same folder today
    assert mapped("VideoScan/VideoScan/GoneLongAgo.swift") is None
    assert mapped("VideoScan/VideoScanCore/Sources/Y/B.swift") == "Core"
    assert mapped("scripts/old.py") == "scripts"


def func(file, ccn, nloc=10, lang="swift"):
    f = cm.Func(file=file, name="f", long_name="f", ccn=ccn, nloc=nloc, start_line=1, lang=lang)
    f.key = f"{file}::f"
    return f


def test_row_shape_and_totals_only_when_too_little_maps():
    when = datetime(2026, 4, 22, 14, 0, tzinfo=UTC)
    mapped = bf.folder_mapper(["VideoScan/VideoScan/Catalog/A.swift"])
    good = [func("VideoScan/VideoScan/A.swift", 35), func("scripts/x.py", 3, lang="python")]
    row = bf.backfill_row(good, {"VideoScan/VideoScan/A.swift": 900, "scripts/x.py": 10}, "abcdef1234", when,
                          mapped, "1.22.1")
    assert row["backfill"] is True and row["run_kind"] == "backfill" and row["ts"] == "2026-04-22T14:00:00Z"
    assert row["sha"] == "abcdef12" and row["swift_by_folder"]["Catalog"]["ccn_over_30"] == 1
    assert row["totals"]["all"]["ccn_over_30"] == 1 and row["totals"]["all"]["files_over_800"] == 1
    assert "top15" not in row and "debt_new" not in row                  # nothing path-like leaves
    pm.validate("complexity.jsonl", row, {"Catalog", "Core", "(app root)"})
    bad = [func("VideoScan/VideoScan/A.swift", 5), func("VideoScan/VideoScan/Gone.swift", 5)]
    row = bf.backfill_row(bad, {}, "abcdef1234", when, mapped, None)
    assert row["swift_by_folder"] is None and row["folders_mapped_pct"] == 50.0   # dashboard: totals only
    pm.validate("complexity.jsonl", row, {"Catalog"})


def test_privacy_gate_refuses_paths_and_names_on_backfill_rows():
    when = datetime(2026, 4, 22, tzinfo=UTC)
    row = bf.backfill_row([func("VideoScan/VideoScan/A.swift", 3)], {}, "abcdef12", when,
                          bf.folder_mapper(["VideoScan/VideoScan/Catalog/A.swift"]), None)
    leaky = dict(row, top15=[{"file": "VideoScan/VideoScan/A.swift", "function": "f"}])
    with pytest.raises(pm.PrivacyError):
        pm.validate("complexity.jsonl", leaky, {"Catalog"})
    with pytest.raises(pm.PrivacyError):
        pm.validate("complexity.jsonl", dict(row, swift_by_folder={"Donna's stuff": row["totals"]["swift"]}), {"Catalog"})


def test_publisher_appends_backfill_and_keeps_ci_rows_verbatim(tmp_path):
    ci_row = {"ts": "2026-10-06T05:10:00Z", "sha": "1234abcd", "run_kind": "nightly", "totals": {"all": {}},
              "top15": [{"file": "VideoScan/VideoScan/Catalog/A.swift", "function": "A.big", "ccn": 40, "nloc": 9}]}
    (tmp_path / "complexity.jsonl").write_text(json.dumps(ci_row) + "\n")
    when = datetime(2026, 4, 22, tzinfo=UTC)
    row = bf.backfill_row([func("VideoScan/VideoScan/A.swift", 3)], {}, "abcdef12", when,
                          bf.folder_mapper(["VideoScan/VideoScan/Catalog/A.swift"]), None)
    text = pm.sanitized_files({"complexity.jsonl": [row]}, tmp_path, {"Catalog"})["complexity.jsonl"]
    rows = [json.loads(l) for l in text.splitlines()]
    assert [r["ts"] for r in rows] == ["2026-04-22T00:00:00Z", "2026-10-06T05:10:00Z"]
    assert rows[1] == ci_row                                            # untouched, not re-validated
    (tmp_path / "complexity.jsonl").write_text(text)
    again = pm.sanitized_files({"complexity.jsonl": [row]}, tmp_path, {"Catalog"})["complexity.jsonl"]
    assert again == text                                                # idempotent
