#!/usr/bin/env python3
"""Red-test confirm step of the nightly adversarial review (2026-10-01).

Run by `tools/adversarial_nightly.py confirm` (launchd 05:30). Each P0–P2
finding from that night's Tier A run carries a drafted Swift Testing red test.
This step labels every one of them:

    confirmed-red  compiled, ran, and failed at an #expect / #require in the draft
    unconfirmed    with a reason: passed / did not compile / crashed / timed out /
                   threw instead of failing an expectation / lint / skipped …

How a draft runs (design §5):
  1. Static lint (lint_draft): no /Volumes, App Support, home directory,
     FamilyArchive, 00_Index, Process(, URLSession, UserDefaults.standard,
     UI automation, or absolute paths — synthetic data under
     temporaryDirectory only. A lint failure is never compiled.
  2. A fresh scratch worktree at the run's head (fixed path under
     ~/Library/Caches/VideoScan/adv-review/confirm-wt so app builds stay
     incremental in their own derivedData), each draft in its own
     AdvDraft_<fp8>.swift with its suite renamed AdvDraft_<fp8>_<Suite>
     (no clash with a real suite of the same name).
  3. Every swift / xcodebuild call runs under scripts/adversarial/redtest.sb
     (sandbox-exec) inside the process-group watchdog lifted from the 2 AM
     nightly (scripts/lib/process_group_watchdog.sh). 10 min per test, 60 min
     for all tests, nothing new after 09:30.
  4. Core drafts: `swift build --build-tests` once, then `swift test
     --skip-build --filter AdvDraft_<fp8>_<Suite>` per draft, with HOME and
     TMPDIR pointed at a scratch directory.
     App drafts: packages resolved OUTSIDE the sandbox (network), then one
     sandboxed `build-for-testing` and one batched `test-without-building
     -only-testing:VideoScanTests/<suite>` (by SUITE: method granularity runs
     zero Swift Testing tests and still says SUCCEEDED).
  5. A draft that breaks the build is attributed by file name, removed, and
     the build retried (max 3 rounds).

SANDBOX FINDINGS (measured 2026-10-01 on the M4, macOS 27 / Xcode 27):
  - sandbox-exec works and the profile's denies hold (App Support/VideoScan,
    the main checkout, outbound network all refused; temp writes allowed).
  - SwiftPM and Xcode evaluate Package.swift inside their OWN sandbox-exec,
    and a nested sandbox_apply is refused ("Operation not permitted"). So
    swift runs with --disable-sandbox and xcodebuild with
    -IDEPackageSupportDisableManifestSandbox=YES (a process-local default;
    Rick's Xcode prefs are untouched). Manifests are this repo's own.
  - Xcode's default DerivedData is the RAM disk under /Volumes, which the
    profile denies — hence an explicit -derivedDataPath in the cache dir.
  - App packages need the network, which the profile denies — hence the
    unsandboxed -resolvePackageDependencies first and
    -disableAutomaticPackageResolution inside.
  - LIMIT: the sandbox is inherited by children only. swift test's runner is
    a child (fully sandboxed). An app-hosted XCTest bundle is launched by
    testmanagerd over XPC, so APP DRAFTS RUN OUTSIDE THE PROFILE: for them
    the lint, the scratch worktree and the app's TestEnvironment diversions
    are the guard, and the doc says so per finding.

Stdlib only. Test seams (environment), besides adversarial_nightly's:
    VIDEOSCAN_ADV_SWIFT / VIDEOSCAN_ADV_XCODEBUILD   tool executables
    VIDEOSCAN_ADV_SANDBOX_EXEC                       sandbox-exec ('' = none)
    VIDEOSCAN_ADV_DEADLINE                           HH:MM (default 09:30)
    VIDEOSCAN_ADV_SKIP_BUSY_CHECK=1                  ignore a running nightly
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import time
from datetime import datetime, timedelta
from pathlib import Path

import adversarial_nightly as adv

PER_TEST_SECONDS = 600
ALL_TESTS_SECONDS = 3600
CORE_BUILD_SECONDS = 1800
APP_BUILD_SECONDS = 3600
MAX_BUILD_ROUNDS = 3
MAX_DRAFT_LINES = 400
APP_TEST_DIR = "VideoScan/VideoScanTests"
CORE_TEST_DIR = "VideoScan/VideoScanCore/Tests/VideoScanCoreTests"
CORE_PACKAGE = "VideoScan/VideoScanCore"
XCODE_PROJECT = "VideoScan/VideoScan.xcodeproj"

FORBIDDEN = [
    ("/Volumes", "names /Volumes"),
    ("applicationSupportDirectory", "reaches Application Support"),
    ("homeDirectoryForCurrentUser", "reaches the home directory"),
    ("NSHomeDirectory", "reaches the home directory"),
    ("FamilyArchive", "names the FamilyArchive"),
    ("00_Index", "names 00_Index"),
    ("Process(", "spawns a process"),
    ("posix_spawn", "spawns a process"),
    ("URLSession", "uses the network"),
    ("UserDefaults.standard", "writes real preferences"),
    ("XCUIApplication", "is a UI test"),
    ("NSWorkspace", "drives the desktop"),
    ("FileManager.default.urls(for:", "resolves a real user directory"),
    ("dlopen", "loads code"),
]
ABSOLUTE_PATH_RE = re.compile(r'"(?:~/|/(?:[A-Za-z]))')


# ---------------------------------------------------------------- lint

def lint_draft(code: str | None, test: str | None, target: str | None) -> list[str]:
    """Reasons this draft must not be compiled; [] = OK to try."""
    if not code:
        return ["no red test drafted"]
    problems = []
    if target not in ("app", "core"):
        problems.append("no `// target: app|core` line")
    if not test or "/" not in test:
        problems.append("no `// test: Suite/testName` line")
    else:
        suite, name = test.split("/", 1)
        if not re.search(rf"\bstruct\s+{re.escape(suite)}\b", code):
            problems.append(f"suite {suite} is not declared as a struct in the draft")
        if not re.search(rf"\bfunc\s+{re.escape(name)}\s*\(", code):
            problems.append(f"test {name} is not declared in the draft")
    if "import Testing" not in code or "@Test" not in code:
        problems.append("not a Swift Testing test (import Testing / @Test)")
    for needle, why in FORBIDDEN:
        if needle in code:
            problems.append(f"{why} ({needle})")
    if ABSOLUTE_PATH_RE.search(code):
        problems.append("contains an absolute path literal (use temporaryDirectory)")
    if code.count("\n") > MAX_DRAFT_LINES:
        problems.append(f"longer than {MAX_DRAFT_LINES} lines")
    return problems


def prepare_draft(code: str, fp: str, test: str) -> tuple[str, str, str]:
    """Rename the draft's suite so it cannot clash with a real one.
    Returns (code, unique suite, test name)."""
    suite, name = test.split("/", 1)
    unique = f"AdvDraft_{fp[:8]}_{suite}"
    code = re.sub(rf"\b{re.escape(suite)}\b", unique, code)
    header = (f"// Drafted by the nightly adversarial review (fp {fp[:12]}). Scratch worktree only;\n"
              f"// never committed by the tool.\n")
    return header + code, unique, name


# ---------------------------------------------------------------- result parsing

def classify_output(output: str, rc: int | None, draft_file: str) -> tuple[str, str]:
    """(label, reason) for one draft's run output."""
    if rc == 124:
        return "unconfirmed", "timed out"
    escaped = re.escape(draft_file)
    issue_lines = [l for l in output.splitlines() if re.search(rf"recorded an issue at {escaped}:\d+", l)
                   or re.search(rf"{escaped}:\d+(?::\d+)?: (?:error: )?(?:Expectation failed|Requirement failed)", l)]
    if any(re.search(r"Expectation failed|Requirement failed|#require|#expect", l) for l in issue_lines):
        return "confirmed-red", "failed at an #expect/#require in the draft"
    if issue_lines:
        return "unconfirmed", "threw an error instead of failing an expectation"
    if re.search(r"unexpected signal|Fatal error|crashed|Exited with signal|\bSIG[A-Z]+\b", output):
        return "unconfirmed", "crashed"
    ran = re.findall(r"Test run with (\d+) tests?", output)
    if ran and all(n == "0" for n in ran):
        return "unconfirmed", "no test ran (filter matched nothing)"
    if re.search(r"✔ Test run with [1-9]\d* tests?.* passed|✔ Suite .*AdvDraft_.* passed|Test Suite .* passed", output):
        return "unconfirmed", "passed (the claim did not reproduce)"
    if rc == 0:
        return "unconfirmed", "passed (the claim did not reproduce)"
    return "unconfirmed", f"no result (exit {rc})"


def draft_errors(build_output: str) -> set[str]:
    """fp8s of drafts the compiler blamed."""
    return set(re.findall(r"AdvDraft_([0-9a-f]{8})\.swift:\d+(?::\d+)?: error", build_output))


# ---------------------------------------------------------------- execution

def tool(env_key: str, default: str) -> str:
    return os.environ.get(env_key) or default


def busy_reason() -> str | None:
    if os.environ.get("VIDEOSCAN_ADV_SKIP_BUSY_CHECK") == "1":
        return None
    nightly = subprocess.run(["pgrep", "-f", "nightly_local_tests.sh"], capture_output=True, text=True)
    if nightly.returncode == 0 and nightly.stdout.strip():
        return "the 2 AM nightly is still running"
    ps = subprocess.run(["ps", "-axo", "comm="], capture_output=True, text=True)
    if any(line.strip() == "(VideoScan)" for line in ps.stdout.splitlines()):
        return "a (VideoScan) exit corpse exists"
    return None


_deadline: datetime | None = None


def set_deadline(now: datetime | None = None) -> datetime:
    """The NEXT HH:MM (default 09:30) after the step starts: 05:30 → 09:30 the
    same morning; a hand run at 22:00 → 09:30 tomorrow. An override of the
    current minute or earlier today means 'already past' (tests)."""
    global _deadline
    now = now or datetime.now()
    raw = os.environ.get("VIDEOSCAN_ADV_DEADLINE")
    hh, mm = (raw or "09:30").split(":")
    candidate = now.replace(hour=int(hh), minute=int(mm), second=0, microsecond=0)
    if candidate <= now and not raw:
        candidate += timedelta(days=1)
    _deadline = candidate
    return candidate


def past_deadline() -> bool:
    return datetime.now() >= (_deadline or set_deadline())


class Runner:
    """sandbox-exec + the nightly's process-group watchdog around one command."""

    def __init__(self, worktree: Path, logs: Path, sandbox: bool):
        self.worktree = worktree
        self.logs = logs
        self.sandbox = sandbox
        own = adv.TOOLS.parent   # the tool's own checkout, not the repository under review
        self.lib = own / "scripts" / "lib" / "process_group_watchdog.sh"
        self.profile = own / "scripts" / "adversarial" / "redtest.sb"
        self.scratch_home = worktree.parent / f"{worktree.name}-home"
        (self.scratch_home / "tmp").mkdir(parents=True, exist_ok=True)

    def wrap(self, command: list[str]) -> list[str]:
        sandbox_exec = os.environ.get("VIDEOSCAN_ADV_SANDBOX_EXEC", "/usr/bin/sandbox-exec")
        if not self.sandbox or not sandbox_exec:
            return command
        return [sandbox_exec, "-f", str(self.profile), "-D", f"HOME={Path.home()}",
                "-D", f"CHECKOUT={Path.home() / 'dev' / 'VideoScan'}", *command]

    def run(self, name: str, command: list[str], timeout: int, scratch_env: bool = False) -> tuple[int, str]:
        log = self.logs / f"{name}.log"
        env = dict(os.environ)
        if scratch_env:
            # The isolated HOME-like scratch: anything a test resolves from
            # HOME/TMPDIR lands here, not in Rick's home.
            env.update({"HOME": str(self.scratch_home), "TMPDIR": str(self.scratch_home / "tmp") + "/",
                        "CFFIXED_USER_HOME": str(self.scratch_home)})
        wrapper = ["bash", "-c", 'source "$1"; shift; run_with_process_group_watchdog "$@"', "_",
                   str(self.lib), str(timeout), "10", str(log), *self.wrap(command)]
        result = subprocess.run(wrapper, cwd=self.worktree, env=env, stdin=subprocess.DEVNULL,
                                capture_output=True, text=True)
        output = log.read_text(errors="replace") if log.exists() else ""
        return result.returncode, output + result.stderr


def resolve_app_packages(worktree: Path, derived: Path, logs: Path) -> tuple[int, str]:
    """Outside the sandbox on purpose: package resolution needs the network."""
    log = logs / "app-resolve.log"
    command = [tool("VIDEOSCAN_ADV_XCODEBUILD", "/usr/bin/xcodebuild"), "-resolvePackageDependencies",
               "-project", str(worktree / XCODE_PROJECT), "-scheme", "VideoScan",
               "-derivedDataPath", str(derived)]
    with open(log, "w") as handle:
        try:
            rc = subprocess.run(command, cwd=worktree, stdout=handle, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL, timeout=900).returncode
        except subprocess.TimeoutExpired:
            rc = 124
    return rc, log.read_text(errors="replace")


def xcode_common(worktree: Path, derived: Path) -> list[str]:
    return ["-project", str(worktree / XCODE_PROJECT), "-scheme", "VideoScan", "-configuration", "Debug",
            "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", str(derived),
            "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile",
            "-IDEPackageSupportDisableManifestSandbox=YES", "-skipMacroValidation",
            "-skipPackagePluginValidation", "-skip-testing:VideoScanUITests",
            # Same signing settings as the 2 AM nightly (scripts/nightly_local_tests.sh).
            "ENABLE_TESTABILITY=YES", "ONLY_ACTIVE_ARCH=YES",
            "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_ENTITLEMENTS="]


# ---------------------------------------------------------------- the step

def confirm(date: str, sandbox: bool = True, app_run: bool = True) -> int:
    started = time.monotonic()
    set_deadline()
    current = os.nice(0)
    if current < 10:          # same as the LaunchAgent's Nice 10 when run by hand; children inherit
        os.nice(10 - current)
    rdir = adv.run_dir(date)
    findings_file = rdir / "findings.json"
    adv.log_line("START", f"confirm {date} sandbox={sandbox} app_run={app_run}")
    if not findings_file.exists():
        adv.log_line("OUTCOME", f"confirm {date}: no Tier A findings file — nothing to confirm")
        return 0
    findings = json.loads(findings_file.read_text())
    busy = busy_reason()
    if busy or past_deadline():
        reason = busy or "past the 09:30 deadline"
        return record(date, findings, {}, started, skipped=reason)

    results: dict[str, dict] = {}
    candidates = []
    for f in findings:
        if f["severity"] not in ("P0", "P1", "P2"):
            continue
        if f.get("dup"):   # labelled in record(); results are keyed by fp, shared with the original
            continue
        problems = lint_draft(f.get("redTest"), f.get("test"), f.get("target"))
        if problems:
            results[f["fp"]] = {"label": "unconfirmed", "reason": "lint: " + "; ".join(problems)}
            continue
        if f["fp"] in {c["fp"] for c in candidates}:
            continue
        candidates.append(f)
    if not candidates:
        return record(date, findings, results, started)

    head = next((r.get("head") for r in reversed(adv.read_jsonl(adv.ledger_path()))
                 if r.get("event") == "run" and r.get("date") == date and r.get("head")), None)
    if not head:
        for f in candidates:
            results[f["fp"]] = {"label": "unconfirmed", "reason": "no run head in the ledger"}
        return record(date, findings, results, started)

    worktree = adv.cache_dir() / "confirm-wt"
    logs = rdir / "confirm-logs"
    logs.mkdir(parents=True, exist_ok=True)
    if worktree.exists():
        adv.remove_worktree(worktree)
    try:
        adv.cache_dir().mkdir(parents=True, exist_ok=True)
        adv.git("worktree", "add", "--detach", "--force", str(worktree), head)
        runner = Runner(worktree, logs, sandbox)
        drafts = {"core": [], "app": []}
        for f in candidates:
            code, suite, name = prepare_draft(f["redTest"], f["fp"], f["test"])
            folder = CORE_TEST_DIR if f["target"] == "core" else APP_TEST_DIR
            path = worktree / folder / f"AdvDraft_{f['fp'][:8]}.swift"
            path.write_text(code)
            drafts[f["target"]].append({"f": f, "suite": suite, "name": name, "path": path})
        test_budget = [ALL_TESTS_SECONDS]
        if drafts["core"]:
            run_core(runner, worktree, drafts["core"], results, test_budget)
        if drafts["app"]:
            run_app(runner, worktree, drafts["app"], results, test_budget, logs, app_run)
    except Exception as error:  # a broken confirm is reported, never silent
        for f in candidates:
            results.setdefault(f["fp"], {"label": "unconfirmed",
                                         "reason": f"confirm step error: {type(error).__name__}: {error}"})
    finally:
        adv.remove_worktree(worktree)
        shutil.rmtree(worktree.parent / f"{worktree.name}-home", ignore_errors=True)
    return record(date, findings, results, started)


def build_rounds(runner: Runner, drafts: list[dict], results: dict, build) -> list[dict]:
    """Build; blame + drop drafts that break it; retry. Returns drafts that compiled."""
    live = list(drafts)
    for round_no in range(1, MAX_BUILD_ROUNDS + 1):
        if not live:
            return []
        rc, output = build(round_no)
        if rc == 0:
            return live
        blamed = draft_errors(output)
        if rc == 124:
            for d in live:
                results[d["f"]["fp"]] = {"label": "unconfirmed", "reason": "build timed out"}
            return []
        if not blamed:
            for d in live:
                results[d["f"]["fp"]] = {"label": "unconfirmed",
                                         "reason": f"build failed outside the drafts (exit {rc}, round {round_no})"}
            return []
        for d in [d for d in live if d["f"]["fp"][:8] in blamed]:
            results[d["f"]["fp"]] = {"label": "unconfirmed", "reason": "did not compile"}
            d["path"].unlink(missing_ok=True)
        live = [d for d in live if d["f"]["fp"][:8] not in blamed]
    for d in live:
        results[d["f"]["fp"]] = {"label": "unconfirmed", "reason": "build still failing after retries"}
    return []


def run_core(runner: Runner, worktree: Path, drafts: list[dict], results: dict, budget: list[int]) -> None:
    swift = tool("VIDEOSCAN_ADV_SWIFT", "/usr/bin/swift")
    package = str(worktree / CORE_PACKAGE)

    def build(round_no: int):
        return runner.run(f"core-build-{round_no}", [swift, "build", "--disable-sandbox", "--build-tests",
                                                     "--package-path", package], CORE_BUILD_SECONDS)

    for d in build_rounds(runner, drafts, results, build):
        if budget[0] <= 0 or past_deadline():
            results[d["f"]["fp"]] = {"label": "unconfirmed", "reason": "skipped — test time budget or deadline"}
            continue
        limit = min(PER_TEST_SECONDS, budget[0])
        began = time.monotonic()
        rc, output = runner.run(f"core-test-{d['f']['fp'][:8]}",
                                [swift, "test", "--disable-sandbox", "--skip-build", "--package-path", package,
                                 "--filter", d["suite"]], limit, scratch_env=True)
        budget[0] -= int(time.monotonic() - began)
        label, reason = classify_output(output, rc, d["path"].name)
        results[d["f"]["fp"]] = {"label": label, "reason": reason, "sandboxed": runner.sandbox}


def run_app(runner: Runner, worktree: Path, drafts: list[dict], results: dict, budget: list[int],
            logs: Path, app_run: bool) -> None:
    xcodebuild = tool("VIDEOSCAN_ADV_XCODEBUILD", "/usr/bin/xcodebuild")
    derived = adv.cache_dir() / "DerivedData"
    rc, _ = resolve_app_packages(worktree, derived, logs)
    if rc != 0:
        for d in drafts:
            results[d["f"]["fp"]] = {"label": "unconfirmed", "reason": f"package resolution failed (exit {rc})"}
        return

    def build(round_no: int):
        return runner.run(f"app-build-{round_no}", [xcodebuild, "build-for-testing",
                                                    *xcode_common(worktree, derived)], APP_BUILD_SECONDS)

    compiled = build_rounds(runner, drafts, results, build)
    if not compiled:
        return
    if not app_run:
        for d in compiled:
            results[d["f"]["fp"]] = {"label": "unconfirmed",
                                     "reason": "compiled; app-hosted run not executed (--no-app-run)"}
        return
    if budget[0] <= 0 or past_deadline():
        for d in compiled:
            results[d["f"]["fp"]] = {"label": "unconfirmed", "reason": "skipped — test time budget or deadline"}
        return
    only = [f"-only-testing:VideoScanTests/{d['suite']}" for d in compiled]
    limit = min(PER_TEST_SECONDS * len(compiled), budget[0])
    began = time.monotonic()
    rc, output = runner.run("app-test", [xcodebuild, "test-without-building", *xcode_common(worktree, derived),
                                         *only], limit)
    budget[0] -= int(time.monotonic() - began)
    for d in compiled:
        if rc == 124:
            label, reason = "unconfirmed", "timed out (batched app run)"
        else:
            label, reason = classify_output(per_suite(output, d), None if rc else 0, d["path"].name)
        results[d["f"]["fp"]] = {"label": label, "reason": reason,
                                 "sandboxed": False,  # XPC-launched test host: outside the profile
                                 "note": "app-hosted: ran outside sandbox-exec (testmanagerd/XPC)"}


def per_suite(output: str, draft: dict) -> str:
    """Lines of a batched xcodebuild run that belong to one draft."""
    keys = (draft["suite"], draft["path"].name, draft["name"])
    lines = [l for l in output.splitlines() if any(k in l for k in keys)]
    return "\n".join(lines)


# ---------------------------------------------------------------- record

def record(date: str, findings: list[dict], results: dict, started: float, skipped: str | None = None) -> int:
    wall = round(time.monotonic() - started, 1)
    for f in findings:
        if f["severity"] not in ("P0", "P1", "P2"):
            continue
        if f.get("dup") and f["dup"] != "same run":
            f["confirm"] = {"label": "unconfirmed", "reason": f"duplicate ({f['dup']}) — not re-run"}
            continue
        f["confirm"] = results.get(f["fp"]) or (
            {"label": "unconfirmed", "reason": f"skipped — {skipped}"} if skipped
            else {"label": "unconfirmed", "reason": "not run"})
    fresh = [f for f in findings if f.get("confirm") and not f.get("dup")]   # dups were labelled before
    confirmed = sum(1 for f in fresh if f["confirm"]["label"] == "confirmed-red")
    considered = len(fresh)
    rdir = adv.run_dir(date)
    adv.write_atomic(rdir / "findings.json", json.dumps(findings, indent=2, ensure_ascii=False) + "\n")
    adv.write_atomic(rdir / "confirm.json", json.dumps(
        {"date": date, "skipped": skipped, "confirmedRed": confirmed, "considered": considered,
         "wallSeconds": wall, "results": {f["fp"]: f.get("confirm") for f in findings if f.get("confirm")}},
        indent=2, ensure_ascii=False) + "\n")
    with adv.state_lock("findings"):
        known = adv.load_findings()
        for f in findings:
            if f.get("confirm") and f["fp"] in known and not f.get("dup"):
                known[f["fp"]]["confirm"] = f["confirm"]["label"]
                known[f["fp"]]["confirmReason"] = f["confirm"]["reason"]
        adv.save_findings(known)
    adv.append_jsonl(adv.ledger_path(), {"event": "confirm", "date": date, "confirmedRed": confirmed,
                                         "considered": considered, "skipped": skipped, "wallSeconds": wall,
                                         "at": adv.now_local()})
    latest = adv.read_json(adv.latest_path(), {})
    if isinstance(latest, dict) and latest.get("date") == date:
        latest.update({"confirmedRed": None if skipped else confirmed, "confirmConsidered": considered,
                       "confirmSkipped": skipped})
        adv.write_latest(latest)
    doc = rdir / f"{date}.md"
    if doc.exists():
        lines = ["", f"## Confirm ({adv.now_local()})", ""]
        lines.append(f"Skipped: {skipped}." if skipped else
                     f"{confirmed} of {considered} P0–P2 findings confirmed-red; wall {wall:.0f} s.")
        for f in findings:
            c = f.get("confirm")
            if c:
                extra = f" — {c['note']}" if c.get("note") else ""
                lines.append(f"- {f['severity']} `{f['fp'][:12]}` {f['title']}: **{c['label']}** ({c['reason']}){extra}")
        with open(doc, "a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
    adv.log_line("OUTCOME", f"confirm {date} " + (f"skipped: {skipped}" if skipped else
                                                    f"confirmed-red={confirmed} of {considered}") + f" wall={wall}s")
    return 0
