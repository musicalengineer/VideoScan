"""Nightly failure-modes self-test, group "shards": the app phase as K test hosts (section 19).

One module per group so scripts/pytest_shards.py runs the groups at once (it deals whole modules to
shards); the groups, their sections and floors live in tests/nightly_failure_modes_groups.py.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from nightly_failure_modes_groups import needs_mac, run_group  # noqa: E402


@needs_mac
def test_nightly_failure_modes_shards_group_passes():
    run_group("shards")
