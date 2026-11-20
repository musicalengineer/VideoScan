"""Nightly failure-modes self-test, group "rows": row builders, parsers, verdict ladder, watchdog, machine setup (7-13, 15).

One module per group so scripts/pytest_shards.py runs the groups at once (it deals whole modules to
shards); the groups, their sections and floors live in tests/nightly_failure_modes_groups.py.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from nightly_failure_modes_groups import needs_mac, run_group  # noqa: E402


@needs_mac
def test_nightly_failure_modes_rows_group_passes():
    run_group("rows")
