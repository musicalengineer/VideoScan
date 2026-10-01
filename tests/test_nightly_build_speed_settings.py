"""Sensors for the 2026-10-01 Release-nightly build timeout.

The first Release nightly (4723c19b) hit the 5400 s build watchdog with
VideoScanTests unbuilt: launchd ran it at ProcessType=Background (efficiency
cores, throttled I/O) and the test target compiled whole-module as ONE
single-threaded job (~49k Swift Testing macro expansions, 26 GB peak).
Measured on the M5: 1829 s whole build -> 411 s with the test target
single-file. These pin both fixes so neither quietly reverts.
"""
import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
PBXPROJ = REPO / "VideoScan" / "VideoScan.xcodeproj" / "project.pbxproj"
INSTALLER = REPO / "scripts" / "install_nightly.sh"


def _test_target_release_block() -> str:
    text = PBXPROJ.read_text()
    blocks = re.findall(r"/\* Release \*/ = \{\s*isa = XCBuildConfiguration;(.*?)name = Release;", text, re.S)
    test_blocks = [b for b in blocks if 'PRODUCT_BUNDLE_IDENTIFIER = "Rick-Breen.VideoScanTests"' in b]
    assert len(test_blocks) == 1, f"expected one VideoScanTests Release config, found {len(test_blocks)}"
    return test_blocks[0]


def test_unit_test_target_compiles_single_file_in_release():
    assert "SWIFT_COMPILATION_MODE = singlefile;" in _test_target_release_block()


def test_app_release_stays_whole_module():
    # Production parity: only the test bundle changes mode.
    assert "SWIFT_COMPILATION_MODE = wholemodule;" in PBXPROJ.read_text()


def test_nightly_launchd_job_is_not_background_priority():
    text = INSTALLER.read_text()
    m = re.search(r"<key>ProcessType</key>\s*<string>(\w+)</string>", text)
    assert m, "ProcessType missing from the nightly plist"
    assert m.group(1) != "Background", "Background pins the build to efficiency cores (2026-10-01 timeout)"
