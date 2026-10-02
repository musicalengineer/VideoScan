"""tools/adversarial_confirm.py — lint, labels, sandbox wrap, watchdog, records.

Fake `swift` / `xcodebuild` / `claude` executables; no network, no Xcode
build, no app launch. The real process-group watchdog lib is used.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(ROOT / "tests"))

import adversarial_confirm as conf  # noqa: E402
import adversarial_nightly as adv  # noqa: E402
from test_adversarial_nightly import env, sh, write, set_baseline, change_day  # noqa: E402,F401

GOOD = """// target: core
// test: WriterSafetyTests/saveNeverClobbers
import Testing
import Foundation
@testable import VideoScanCore

@Suite struct WriterSafetyTests {
    @Test func saveNeverClobbers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(Bool(false), "claim reproduces")
    }
}
"""

FAKE_CLAUDE = r'''#!/usr/bin/env python3
import json, sys
sys.stdin.read()
core = open(__file__ + ".core").read()
app = core.replace("// target: core", "// target: app").replace("VideoScanCore", "VideoScan").replace("WriterSafetyTests", "AppWriterTests")
text = f"""Credits spent: unavailable | Finding count: 4
Verdict: fix — x

### F1 — P1 — core claim
- File: VideoScan/VideoScan/Archive/Writer.swift:2
- Invariant: ARCH-2
- Key: VideoScan/VideoScan/Archive/Writer.swift#save#ARCH-2
- Claim: c

```swift
{core}```

### F2 — P2 — app claim
- File: VideoScan/VideoScan/Archive/Writer.swift:2
- Invariant: ARCH-9
- Key: VideoScan/VideoScan/Archive/Writer.swift#save#ARCH-9
- Claim: c

```swift
{app}```

### F3 — P1 — dangerous draft
- File: VideoScan/VideoScan/Archive/Writer.swift:2
- Invariant: ARCH-1
- Key: VideoScan/VideoScan/Archive/Writer.swift#move#ARCH-1
- Claim: c

```swift
// target: core
// test: BadTests/touchesVolumes
import Testing
@Suite struct BadTests {{ @Test func touchesVolumes() {{ _ = "/Volumes/FamilyArchive" }} }}
```

### F4 — P3 — logging
- File: VideoScan/VideoScan/Archive/Writer.swift:1
- Invariant: ARCH-9
- Key: VideoScan/VideoScan/Archive/Writer.swift#log#ARCH-9
- Claim: c
"""
print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": text,
                  "total_cost_usd": 0.5, "usage": {"input_tokens": 10, "output_tokens": 10}}))
'''

FAKE_SWIFT = r'''#!/usr/bin/env python3
import os, sys, time, glob
args = sys.argv[1:]
log = os.environ.get("FAKE_TOOL_LOG")
if log:
    with open(log, "a") as h:
        h.write(" ".join(args) + " | HOME=" + os.environ.get("HOME", "") + "\n")
mode = os.environ.get("FAKE_SWIFT_MODE", "red")
pkg = args[args.index("--package-path") + 1]
drafts = glob.glob(os.path.join(pkg, "Tests", "VideoScanCoreTests", "AdvDraft_*.swift"))
if args[0] == "build":
    if mode == "compile-error" and drafts:
        print(f"{drafts[0]}:5:3: error: cannot find 'x' in scope"); sys.exit(1)
    if mode == "build-broken":
        print("Sources/VideoScanCore/A.swift:1:1: error: boom"); sys.exit(1)
    print("Build complete!"); sys.exit(0)
if args[0] == "test":
    name = args[args.index("--filter") + 1]
    fp8 = name.split("_")[1]
    if mode == "hang":
        time.sleep(30)
    if mode == "pass":
        print(f'✔ Test run with 1 test in 1 suite passed after 0.001 seconds.'); sys.exit(0)
    print(f'✘ Test saveNeverClobbers() recorded an issue at AdvDraft_{fp8}.swift:11:9: Expectation failed: Bool(false)')
    print('✘ Test run with 1 test in 1 suite failed after 0.002 seconds with 1 issue.')
    sys.exit(1)
'''

FAKE_XCODEBUILD = r'''#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
log = os.environ.get("FAKE_TOOL_LOG")
if log:
    with open(log, "a") as h:
        h.write("xcodebuild " + " ".join(args) + "\n")
if "-resolvePackageDependencies" in args:
    print("resolved source packages: x"); sys.exit(0)
if "build-for-testing" in args:
    print("** TEST BUILD SUCCEEDED **"); sys.exit(0)
if "test-without-building" in args:
    only = [a.split("/")[-1] for a in args if a.startswith("-only-testing:")]
    for suite in only:
        fp8 = suite.split("_")[1]
        print(f"✘ Test saveNeverClobbers() recorded an issue at AdvDraft_{fp8}.swift:11:9: Expectation failed: Bool(false)")
        print(f"✘ Suite {suite} failed after 0.01 seconds with 1 issue.")
    sys.exit(65)
'''


def make_exe(path: Path, text: str) -> Path:
    path.write_text(text)
    path.chmod(0o755)
    return path


@pytest.fixture
def cenv(env, monkeypatch):
    tmp = env["tmp"]
    claude = make_exe(tmp / "fake-claude-confirm", FAKE_CLAUDE)
    (tmp / "fake-claude-confirm.core").write_text(GOOD)
    monkeypatch.setenv("VIDEOSCAN_CLAUDE_BIN", str(claude))
    monkeypatch.setenv("VIDEOSCAN_ADV_SWIFT", str(make_exe(tmp / "fake-swift", FAKE_SWIFT)))
    monkeypatch.setenv("VIDEOSCAN_ADV_XCODEBUILD", str(make_exe(tmp / "fake-xcodebuild", FAKE_XCODEBUILD)))
    monkeypatch.setenv("VIDEOSCAN_ADV_SANDBOX_EXEC", "")
    monkeypatch.setenv("VIDEOSCAN_ADV_SKIP_BUSY_CHECK", "1")
    monkeypatch.setenv("VIDEOSCAN_ADV_DEADLINE", "23:59")
    monkeypatch.setenv("FAKE_TOOL_LOG", str(tmp / "tools.log"))
    # The fake repo needs the Core test folder the drafts go into.
    write(env["repo"], "VideoScan/VideoScanCore/Tests/VideoScanCoreTests/Keep.swift", "// keep\n")
    write(env["repo"], "VideoScan/VideoScanTests/Keep.swift", "// keep\n")
    sh(env["repo"], "add", "-A")
    sh(env["repo"], "commit", "-q", "-m", "test folders")
    change_day(env["repo"])
    set_baseline(env, env["base"])
    assert adv.run(None, "2026-10-02") == 0
    return env


def confirm_results(env) -> dict:
    return json.loads((env["state"] / "runs" / "2026-10-02" / "confirm.json").read_text())


def by_title(env) -> dict:
    findings = json.loads((env["state"] / "runs" / "2026-10-02" / "findings.json").read_text())
    # Both fake briefs answer alike, so brief 2's copies are same-run dups.
    return {f["title"]: f for f in reversed(findings) if not f.get("dup")}


# ---------------------------------------------------------------- lint

def test_lint_accepts_a_synthetic_draft():
    assert conf.lint_draft(GOOD, "WriterSafetyTests/saveNeverClobbers", "core") == []


@pytest.mark.parametrize("snippet", [
    '"/Volumes/X"', "FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)",
    "FileManager.default.homeDirectoryForCurrentUser", '"FamilyArchive"', '"00_Index"', "Process()",
    "URLSession.shared", "UserDefaults.standard.set(1, forKey: \"k\")", "XCUIApplication()",
    '"/Users/someone/file"', '"~/Movies"', "NSHomeDirectory()",
])
def test_lint_rejects_reaching_outside_the_sandbox(snippet):
    draft = GOOD.replace('#expect(Bool(false), "claim reproduces")', f"_ = {snippet}")
    assert conf.lint_draft(draft, "WriterSafetyTests/saveNeverClobbers", "core")


def test_lint_requires_shape():
    assert "no red test drafted" in conf.lint_draft(None, None, None)
    assert any("target" in p for p in conf.lint_draft(GOOD, "WriterSafetyTests/saveNeverClobbers", None))
    assert any("suite" in p for p in conf.lint_draft(GOOD, "Other/saveNeverClobbers", "core"))
    assert any("test" in p for p in conf.lint_draft(GOOD, "WriterSafetyTests/nope", "core"))


def test_prepare_renames_the_suite():
    code, suite, name = conf.prepare_draft(GOOD, "abcdef0123456789", "WriterSafetyTests/saveNeverClobbers")
    assert suite == "AdvDraft_abcdef01_WriterSafetyTests" and name == "saveNeverClobbers"
    assert "struct AdvDraft_abcdef01_WriterSafetyTests" in code and "struct WriterSafetyTests" not in code


# ---------------------------------------------------------------- classify

@pytest.mark.parametrize("output,rc,label,reason", [
    ("✘ Test t() recorded an issue at AdvDraft_aaaa1111.swift:3:5: Expectation failed: x", 1, "confirmed-red", "#expect"),
    ("✘ Test t() recorded an issue at AdvDraft_aaaa1111.swift:3:5: Requirement failed", 1, "confirmed-red", "#expect"),
    ("✘ Test t() recorded an issue at AdvDraft_aaaa1111.swift:3:5: Caught error: E()", 1, "unconfirmed", "threw"),
    ("✔ Test run with 1 test in 1 suite passed after 0.1 seconds.", 0, "unconfirmed", "passed"),
    ("✔ Test run with 0 tests passed after 0.0 seconds.", 0, "unconfirmed", "no test ran"),
    ("error: Exited with unexpected signal code 5", 1, "unconfirmed", "crashed"),
    ("", 124, "unconfirmed", "timed out"),
    ("✘ Test t() recorded an issue at AdvDraft_bbbb2222.swift:3:5: Expectation failed", 1, "unconfirmed", "no result"),
])
def test_classify(output, rc, label, reason):
    got = conf.classify_output(output, rc, "AdvDraft_aaaa1111.swift")
    assert got[0] == label and reason in got[1]


def test_draft_errors_are_attributed_by_file():
    out = "/x/AdvDraft_0123abcd.swift:5:3: error: nope\n/x/Real.swift:1:1: error: other"
    assert conf.draft_errors(out) == {"0123abcd"}


# ---------------------------------------------------------------- the step

def test_confirm_labels_and_records(cenv):
    assert conf.confirm("2026-10-02", sandbox=False) == 0
    f = by_title(cenv)
    assert f["core claim"]["confirm"]["label"] == "confirmed-red"
    assert f["app claim"]["confirm"]["label"] == "confirmed-red"
    assert f["app claim"]["confirm"]["sandboxed"] is False           # XPC host: said plainly
    assert f["dangerous draft"]["confirm"]["label"] == "unconfirmed"
    assert "lint" in f["dangerous draft"]["confirm"]["reason"]
    assert "confirm" not in f["logging"]                             # P3: not applicable
    res = confirm_results(cenv)
    assert res["confirmedRed"] == 2 and res["considered"] == 3
    latest = json.loads((cenv["state"] / "latest.json").read_text())
    assert latest["confirmedRed"] == 2
    assert [r for r in adv.read_jsonl(adv.ledger_path()) if r.get("event") == "confirm"][-1]["confirmedRed"] == 2
    doc = Path(latest["doc"]).read_text()
    assert "## Confirm" in doc and "confirmed-red" in doc
    calls = (cenv["tmp"] / "tools.log").read_text()
    assert "--disable-sandbox" in calls and "-IDEPackageSupportDisableManifestSandbox=YES" in calls
    assert "-only-testing:VideoScanTests/AdvDraft_" in calls          # by SUITE, not method
    test_line = next(l for l in calls.splitlines() if l.startswith("test "))
    assert "/confirm-wt-home" in test_line                           # scratch HOME for test runs
    assert not (adv.cache_dir() / "confirm-wt").exists()             # worktree removed
    known = adv.load_findings()
    assert sorted(r.get("confirm") for r in known.values() if r.get("confirm")) == [
        "confirmed-red", "confirmed-red", "unconfirmed"]


def test_compile_error_is_attributed_and_unconfirmed(cenv, monkeypatch):
    monkeypatch.setenv("FAKE_SWIFT_MODE", "compile-error")
    conf.confirm("2026-10-02", sandbox=False)
    assert by_title(cenv)["core claim"]["confirm"]["reason"] == "did not compile"


def test_build_broken_outside_drafts(cenv, monkeypatch):
    monkeypatch.setenv("FAKE_SWIFT_MODE", "build-broken")
    conf.confirm("2026-10-02", sandbox=False)
    assert "build failed outside the drafts" in by_title(cenv)["core claim"]["confirm"]["reason"]


def test_passing_draft_is_unconfirmed(cenv, monkeypatch):
    monkeypatch.setenv("FAKE_SWIFT_MODE", "pass")
    conf.confirm("2026-10-02", sandbox=False)
    assert by_title(cenv)["core claim"]["confirm"]["reason"].startswith("passed")


def test_watchdog_times_out_a_hung_test(cenv, monkeypatch):
    monkeypatch.setenv("FAKE_SWIFT_MODE", "hang")
    monkeypatch.setattr(conf, "PER_TEST_SECONDS", 1)
    conf.confirm("2026-10-02", sandbox=False)
    assert by_title(cenv)["core claim"]["confirm"]["reason"] == "timed out"


def test_no_app_run_builds_but_does_not_launch(cenv):
    conf.confirm("2026-10-02", sandbox=False, app_run=False)
    assert "not executed" in by_title(cenv)["app claim"]["confirm"]["reason"]
    assert "test-without-building" not in (cenv["tmp"] / "tools.log").read_text()


def test_skips_while_the_nightly_runs(cenv, monkeypatch):
    monkeypatch.setattr(conf, "busy_reason", lambda: "the 2 AM nightly is still running")
    conf.confirm("2026-10-02", sandbox=False)
    res = confirm_results(cenv)
    assert res["skipped"] == "the 2 AM nightly is still running"
    assert json.loads((cenv["state"] / "latest.json").read_text())["confirmSkipped"]
    assert not (cenv["tmp"] / "tools.log").exists()


def test_skips_after_the_deadline(cenv, monkeypatch):
    monkeypatch.setenv("VIDEOSCAN_ADV_DEADLINE", "00:00")
    conf.confirm("2026-10-02", sandbox=False)
    assert "deadline" in confirm_results(cenv)["skipped"]


def test_xcodebuild_disables_the_nested_sandboxes():
    common = conf.xcode_common(Path("/wt"), Path("/dd"))
    assert "-IDEPackageSupportDisableManifestSandbox=YES" in common
    assert "OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox" in common
    assert "-disableAutomaticPackageResolution" in common and "-derivedDataPath" in common


def test_helper_script_patch_targets_the_real_script(tmp_path):
    """embed-preview-helper.sh must keep two `swift build` calls the patch can find."""
    real = ROOT / conf.HELPER_SCRIPT
    target = tmp_path / conf.HELPER_SCRIPT
    target.parent.mkdir(parents=True)
    target.write_text(real.read_text())
    assert conf.patch_helper_script(tmp_path)
    assert target.read_text().count("swift build --disable-sandbox") == 2
    assert "--disable-sandbox" not in real.read_text()               # the repo copy is untouched


def test_deadline_is_the_next_0930(monkeypatch):
    from datetime import datetime
    monkeypatch.delenv("VIDEOSCAN_ADV_DEADLINE", raising=False)
    assert conf.set_deadline(datetime(2026, 10, 2, 5, 30)) == datetime(2026, 10, 2, 9, 30)
    # A hand run in the evening (the 10-01 dry run tripped this) gets tomorrow morning.
    assert conf.set_deadline(datetime(2026, 10, 1, 21, 56)) == datetime(2026, 10, 2, 9, 30)


def test_sandbox_wrap_uses_the_profile(tmp_path, monkeypatch):
    monkeypatch.setenv("VIDEOSCAN_ADV_SANDBOX_EXEC", "/usr/bin/sandbox-exec")
    runner = conf.Runner(tmp_path / "wt", tmp_path, sandbox=True)
    wrapped = runner.wrap(["swift", "test"])
    assert wrapped[:3] == ["/usr/bin/sandbox-exec", "-f", str(ROOT / "scripts" / "adversarial" / "redtest.sb")]
    assert any(a.startswith("CHECKOUT=") for a in wrapped) and wrapped[-2:] == ["swift", "test"]


def test_profile_denies_the_family_paths():
    profile = (ROOT / "scripts" / "adversarial" / "redtest.sb").read_text()
    for needle in ('(subpath "/Volumes")', "/Library/Application Support/VideoScan", '(param "CHECKOUT")',
                   "(deny network-outbound)", "/Pictures", "/Movies"):
        assert needle in profile


def test_nightly_still_sources_the_lifted_watchdog():
    script = (ROOT / "scripts" / "nightly_local_tests.sh").read_text()
    assert "lib/process_group_watchdog.sh" in script
    assert "run_with_process_group_watchdog() {" not in script        # one copy, in the lib
    lib = (ROOT / "scripts" / "lib" / "process_group_watchdog.sh").read_text()
    assert "run_with_process_group_watchdog() {" in lib and "start_new_session=True" in lib
