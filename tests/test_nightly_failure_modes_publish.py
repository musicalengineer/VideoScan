"""Nightly failure-modes self-test, group "publish": the metrics publish/queue chain (sections 1-6) and the fake rota Mac (16-18).

One module per group so scripts/pytest_shards.py runs the groups at once (it deals whole modules to
shards); the groups, their sections and floors live in tests/nightly_failure_modes_groups.py.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from nightly_failure_modes_groups import needs_mac, run_group  # noqa: E402


@needs_mac
def test_nightly_failure_modes_publish_group_passes():
    run_group("publish")
