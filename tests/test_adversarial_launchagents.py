"""LaunchAgent templates + installer for the nightly adversarial review (2026-10-01)."""

from __future__ import annotations

import plistlib
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
DIR = ROOT / "scripts" / "adversarial"


@pytest.mark.parametrize("label,hour,minute,command", [
    ("com.videoscan.adversarial-review", 0, 30, "run"),
    ("com.videoscan.adversarial-confirm", 5, 30, "confirm"),
])
def test_plist_template(label, hour, minute, command):
    data = plistlib.loads((DIR / f"{label}.plist").read_bytes())
    assert data["Label"] == label
    assert data["StartCalendarInterval"] == {"Hour": hour, "Minute": minute}
    args = data["ProgramArguments"]
    assert args[:3] == ["/usr/bin/python3", "__CHECKOUT__/tools/adversarial_nightly.py", command]
    assert data["Nice"] == 10 and data["ProcessType"] == "Background"
    assert data["StandardOutPath"] == "__HOME__/Library/Logs/VideoScan/adversarial_review_launchd.log"
    assert data["EnvironmentVariables"]["PATH"].startswith("/opt/homebrew/bin:")


def test_confirm_does_not_launch_the_app_during_the_shadow_week():
    args = plistlib.loads((DIR / "com.videoscan.adversarial-confirm.plist").read_bytes())["ProgramArguments"]
    assert "--no-app-run" in args


def test_installer_gates_on_shadow_mode():
    script = (DIR / "install.sh").read_text()
    assert "status --json" in script and '"shadow"' in script and "REFUSING" in script
    assert "launchctl bootstrap" in script and "plutil -lint" in script
    assert not any(line.lstrip().startswith(("rm ", "rm\t")) or " rm -" in line
                   for line in script.splitlines())   # uninstall moves to .trash, never deletes
