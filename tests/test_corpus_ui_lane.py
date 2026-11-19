"""scripts/corpus_ui_lane.py — the corpus UI lane, host side.

The REAL app under XCUITest on the M4, against the corpus's sealed catalog. What can be
pinned without the M4, a window server or real media (a fake `xcodebuild` plays the build
and the UI run; the corpus is test_corpus_run's fake one):

  the run       the VideoScan-CorpusUI .xctestrun is patched with the run's paths (HOME and
                TMPDIR inside the run's work folder) and every attachment lifetime keepNever;
                `-collect-test-diagnostics never`; the result bundle and the raw output stay
                in the work folder, which is removed afterwards;
  the verdict   GREEN only when every case passed, the seam loaded and nothing moved; RED for a
                failed or skipped case, zero cases, a seam refusal, a crash report, or a change
                to the live App Support catalog, the sealed catalog or any corpus media file;
                NORUN for a ref without the plan, a VideoScan app already running (never
                stopped), or a machine that cannot start UI automation;
  privacy       nothing that reaches the summary carries a corpus name: `[corpus-ui]` lines
                must be words and numbers, a failure message that could carry a name is
                withheld, the seam's status line is validated;
  the callers   corpus_run.py `host ui` dispatches here; m4_run.sh and corpus_run.sh accept
                the lane and ship this module.
"""
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
from collections import Counter
from unittest import mock

REPO = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS = REPO / 'scripts'
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(REPO / 'tests'))
import corpus_run as cr  # noqa: E402
import corpus_ui_lane as ui  # noqa: E402
import testbed_host as th  # noqa: E402
from test_corpus_run import LaneScene, SECRET_NAMES  # noqa: E402

FAKE_UI_XCODEBUILD = r'''#!/usr/bin/env python3
# Stand-in for xcodebuild: `build-for-testing` leaves the CorpusUI .xctestrun; `test-without-building`
# plays a UI run from FAKE_UI_PLAN and the patched .xctestrun's environment.
import json, os, plistlib, sys
args = sys.argv[1:]
plan = json.load(open(os.environ["FAKE_UI_PLAN"]))
with open(plan["calls"], "a") as f:
    f.write(json.dumps({"args": args}) + "\n")
if args[0] == "build-for-testing":
    if plan.get("build_fails"):
        sys.exit(65)
    dd = args[args.index("-derivedDataPath") + 1]
    os.makedirs(dd + "/Build/Products", exist_ok=True)
    with open(dd + "/Build/Products/VideoScan_VideoScan-CorpusUI_macosx.xctestrun", "wb") as f:
        plistlib.dump({"TestConfigurations": [{"TestTargets": [
            {"BlueprintName": "VideoScanUITests", "TestBundlePath": "__TESTHOST__/VideoScanUITests.xctest",
             "EnvironmentVariables": {"KEPT": "1"}, "SystemAttachmentLifetime": "keepAlways"}]}]}, f)
    sys.exit(0)
run = plistlib.load(open(args[args.index("-xctestrun") + 1], "rb"))
target = run["TestConfigurations"][0]["TestTargets"][0]
env = target["EnvironmentVariables"]
with open(plan["calls"], "a") as f:
    f.write(json.dumps({"target": target, "exists_home": os.path.isdir(env["VS_UI_CORPUS_HOME"])}) + "\n")
if plan.get("seam"):
    open(os.path.join(env["VS_UI_CORPUS_HOME"], "corpus-ui-seam.txt"), "a").write(plan["seam"] + "\n")
if plan.get("vandal"):
    os.utime(plan["vandal"], (5, 5))
for line in plan.get("print", []):
    print(line)
for case, outcome in plan.get("cases", {}).items():
    print("Test Case '-[VideoScanUITests.CorpusUITests %s]' %s (1.234 seconds)." % (case, outcome))
sys.exit(plan.get("rc", 0))
'''

CASES = ['test1_showingCountFollowsFiltersSearchAndSelection', 'test2_mainTabsOpenAndReturnWithoutAHang', 'test3_seededMonkey',
         'test4_verifyJobPausesResumesAndStops']


class UIScene(LaneScene):
    """test_corpus_run's corpus and testbed, plus the CorpusUI plan in the testbed, a live
    App Support catalog in the fake home, and the UI stand-in for xcodebuild."""

    def __init__(self, tmp):
        super().__init__(tmp)
        (self.worktree / 'VideoScan' / 'VideoScan-CorpusUI.xctestplan').write_text('{}\n')
        self.live = self.home / 'Library' / 'Application Support' / 'VideoScan'
        (self.live / 'viewer-catalog').mkdir(parents=True)
        for name in ('catalog.sqlite', 'catalog.sqlite-wal', 'catalog.cutover', 'viewer-catalog/catalog.sqlite'):
            (self.live / name).write_text('live')
        self.ui_fake = pathlib.Path(tmp) / 'fake-ui-xcodebuild'
        self.ui_fake.write_text(FAKE_UI_XCODEBUILD)
        self.ui_fake.chmod(0o755)
        self.ui_plan_path = pathlib.Path(tmp) / 'ui-plan.json'
        self.ui_calls = pathlib.Path(tmp) / 'ui-calls.jsonl'
        self.ui_plan = dict(calls=str(self.ui_calls), seam='loaded records=3 volumes=1',
                            cases={c: 'passed' for c in CASES},
                            print=['[corpus-ui] test1 loaded bare=1 shown=3 total=3',
                                   '[corpus-ui] test3 monkey_step toggleFilter ms=420 shown=2 step=0',
                                   '[corpus-ui] test3 monkey_step search ms=980 shown=0 step=1'])
        self.running = ''
        self.errors = Counter()

    def lane(self, sha='b' * 40, stamp='20261118_230000_1', limit=None):
        self.ui_plan_path.write_text(json.dumps(self.ui_plan))
        os.environ['FAKE_UI_PLAN'] = str(self.ui_plan_path)
        return ui.UILane(cr, self.seal, sha, stamp, self.out, self.worktree, self.dd, limit=limit,
                         xcodebuild=str(self.ui_fake), ps=lambda: self.running, log_errors=lambda since: self.errors)

    def go(self, **kw):
        lane = self.lane(**kw)
        try:
            return lane.go(), lane
        finally:
            os.environ.pop('FAKE_UI_PLAN', None)

    def summary(self):
        return (self.out / 'corpus-summary.txt').read_text()

    def ui_calls_made(self):
        return [json.loads(l) for l in self.ui_calls.read_text().splitlines()] if self.ui_calls.exists() else []


class UILaneTests(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.scene = UIScene(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def assertNoSecrets(self, text):
        for name in SECRET_NAMES:
            self.assertNotIn(name, text)
        self.assertNotIn('/corpus/', text)

    def test_a_clean_run_is_green_isolated_and_leaves_no_work_folder(self):
        code, lane = self.scene.go()
        self.assertEqual(code, cr.EXIT_GREEN, self.scene.summary())
        text = self.scene.summary()
        self.assertTrue(text.startswith('corpus ui: GREEN at bbbbbbbbb — 4 cases: 4 passed, 0 failed, 0 skipped'), text)
        self.assertIn('seam: loaded records=3 volumes=1', text)
        self.assertIn('isolation: live App Support catalog files 4 unchanged · sealed catalog unchanged · corpus media 3 unchanged', text)
        self.assertIn('crash reports from VideoScan since the start: 0', text)
        self.assertIn('monkey steps done: 2, slowest 980 ms — search 1, toggleFilter 1', text)
        self.assertIn('test1 loaded bare=1 shown=3 total=3', text)
        self.assertNoSecrets(text)
        self.assertFalse(lane.work.exists(), 'the run work folder (the app HOME and its caches) must go')
        calls = self.scene.ui_calls_made()
        test = next(c for c in calls if 'args' in c and c['args'][0] == 'test-without-building')['args']
        self.assertIn('-collect-test-diagnostics', test)
        self.assertEqual(test[test.index('-collect-test-diagnostics') + 1], 'never')
        self.assertIn('-only-testing:VideoScanUITests/CorpusUITests', test)
        bundle = test[test.index('-resultBundlePath') + 1]
        self.assertTrue(bundle.startswith(str(lane.work) + '/'), 'the result bundle stays in the work folder')
        target = next(c for c in calls if 'target' in c)
        self.assertTrue(target['exists_home'])
        env = target['target']['EnvironmentVariables']
        self.assertEqual(env['KEPT'], '1')
        for key in ('VS_UI_CORPUS_HOME', 'VS_UI_CORPUS_TMP'):
            self.assertTrue(env[key].startswith(str(self.scene.seal.work_root) + '/'), key)
        self.assertEqual(env['VS_UI_CORPUS_CATALOG'], str(self.scene.seal.state / 'catalog.sqlite'))
        self.assertEqual((env['VS_UI_CORPUS'], env['VS_GAUNTLET']), ('1', '1'))
        self.assertEqual(env['VS_UI_CORPUS_SEED'], str(int('b' * 8, 16)))
        self.assertEqual(env['VS_UI_CORPUS_STEPS'], str(ui.MONKEY_STEPS))
        self.assertEqual(target['target']['TestingEnvironmentVariables']['VS_UI_CORPUS'], '1')
        for key in ('SystemAttachmentLifetime', 'UserAttachmentLifetime'):
            self.assertEqual(target['target'][key], 'keepNever')
        self.assertEqual(list(self.scene.dd.glob('Build/Products/corpus-*')), [], 'the patched test-run file is moved out')

    def test_limit_sets_the_monkey_steps(self):
        self.scene.go(limit=7)
        env = next(c for c in self.scene.ui_calls_made() if 'target' in c)['target']['EnvironmentVariables']
        self.assertEqual(env['VS_UI_CORPUS_STEPS'], '7')
        self.assertIn('monkey: seed 3149642683, 7 steps', self.scene.summary())

    def test_a_failed_case_is_red_and_a_message_that_could_name_a_file_is_withheld(self):
        self.scene.ui_plan['cases'][CASES[0]] = 'failed'
        self.scene.ui_plan['print'] = [
            '/x/CorpusUITests.swift:88: error: -[VideoScanUITests.CorpusUITests test1_showingCountFollowsFiltersSearchAndSelection] '
            ': XCTAssertEqual failed: ("12") is not equal to ("13") - The files table lists 12 rows; the box says 13.',
            '/x/CorpusUITests.swift:90: error: -[VideoScanUITests.CorpusUITests test1_showingCountFollowsFiltersSearchAndSelection] '
            ': Failed to click "Grandma Birthday 1988.mov" StaticText',
            '/x/CorpusUITests.swift:91: error: -[VideoScanUITests.CorpusUITests test1_showingCountFollowsFiltersSearchAndSelection] '
            ': No match for /Volumes/PrivateDrive/Lake House']
        code, _ = self.scene.go()
        self.assertEqual(code, cr.EXIT_RED)
        text = self.scene.summary()
        self.assertTrue(text.startswith('corpus ui: RED'))
        self.assertIn('failure: test1_showingCountFollowsFiltersSearchAndSelection line 88: XCTAssertEqual failed: '
                      '("12") is not equal to ("13") - The files table lists 12 rows; the box says 13.', text.replace('\n  ', '\n'))
        self.assertEqual(text.count('(message withheld)'), 2)
        self.assertNoSecrets(text)

    def test_zero_cases_or_a_skipped_case_is_red(self):
        self.scene.ui_plan['cases'] = {}
        self.assertEqual(self.scene.go()[0], cr.EXIT_RED)
        self.scene.ui_plan['cases'] = {CASES[0]: 'passed', CASES[1]: 'skipped'}
        self.assertEqual(self.scene.go(stamp='20261118_230000_2')[0], cr.EXIT_RED)

    def test_a_touched_corpus_file_is_red(self):
        self.scene.ui_plan['vandal'] = str(next(self.scene.seal.media.rglob('*.dv')))
        code, _ = self.scene.go()
        self.assertEqual(code, cr.EXIT_RED)
        self.assertIn('corpus media 3 CHANGED 1', self.scene.summary())

    def test_a_touched_live_catalog_file_is_red_and_named_by_its_app_file_name(self):
        self.scene.ui_plan['vandal'] = str(self.scene.live / 'catalog.sqlite-wal')
        code, _ = self.scene.go()
        self.assertEqual(code, cr.EXIT_RED)
        self.assertIn('live App Support catalog files 4 CHANGED: catalog_sqlite-wal', self.scene.summary())

    def test_a_touched_sealed_catalog_is_red(self):
        self.scene.ui_plan['vandal'] = str(self.scene.seal.state / 'catalog.cutover')
        self.assertEqual(self.scene.go()[0], cr.EXIT_RED)
        self.assertIn('sealed catalog CHANGED', self.scene.summary())

    def test_a_seam_refusal_is_red_and_a_status_line_that_is_not_words_is_dropped(self):
        self.scene.ui_plan['seam'] = 'refused home_not_sealed'
        self.assertEqual(self.scene.go()[0], cr.EXIT_RED)
        self.assertIn('seam: refused home_not_sealed', self.scene.summary())
        self.scene.ui_plan['seam'] = 'loaded records=3 volumes=1 /Volumes/PrivateDrive'
        self.scene.go(stamp='20261118_230000_3')
        self.assertIn('seam: no status line', self.scene.summary())

    def test_a_crash_report_is_red(self):
        reports = self.scene.home / 'Library' / 'Logs' / 'DiagnosticReports'
        reports.mkdir(parents=True)
        self.scene.ui_plan['print'] = []
        original = ui.crash_reports_since
        with mock.patch.object(ui, 'crash_reports_since', side_effect=lambda home, t0: (
                (reports / 'VideoScan-2026-11-18.ips').write_text('x'), original(home, t0))[1]):
            code, _ = self.scene.go()
        self.assertEqual(code, cr.EXIT_RED)
        self.assertIn('crash reports from VideoScan since the start: 1', self.scene.summary())

    def test_unified_log_errors_are_counted_by_subsystem_and_category_only(self):
        self.scene.errors = Counter({'Rick-Breen.VideoScan:shutdown:Error': 2})
        code, _ = self.scene.go()
        self.assertEqual(code, cr.EXIT_GREEN)
        self.assertIn('unified-log errors/faults from VideoScan: Rick-Breen_VideoScan:shutdown:Error x2', self.scene.summary())

    def test_a_running_videoscan_is_norun_and_nothing_is_built_or_stopped(self):
        self.scene.running = '/Applications/VideoScan.app/Contents/MacOS/VideoScan\n/usr/bin/ssh\n'
        code, lane = self.scene.go()
        self.assertEqual(code, cr.EXIT_NORUN)
        self.assertIn('a VideoScan app is running on the M4', self.scene.summary())
        self.assertEqual(self.scene.ui_calls_made(), [])
        self.assertFalse(lane.work.exists())

    def test_a_ref_without_the_plan_is_norun(self):
        (self.scene.worktree / 'VideoScan' / 'VideoScan-CorpusUI.xctestplan').unlink()
        self.assertEqual(self.scene.go()[0], cr.EXIT_NORUN)
        self.assertIn('no corpus UI plan', self.scene.summary())

    def test_a_machine_that_cannot_start_ui_automation_is_norun(self):
        self.scene.ui_plan.update(cases={}, seam='', rc=65,
                                  print=['Testing failed: Timed out while enabling automation mode.'])
        self.assertEqual(self.scene.go()[0], cr.EXIT_NORUN)
        self.assertIn('UI automation could not start on the M4', self.scene.summary())

    def test_cases_that_all_failed_at_the_automation_gate_are_norun_not_red(self):
        self.scene.ui_plan.update(cases={c: 'failed' for c in CASES}, seam='', rc=65,
                                  print=['/x/CorpusUITests.swift:300: error: -[VideoScanUITests.CorpusUITests test1_x] : '
                                         'Failed to initialize for UI testing: Timed out while enabling automation mode.'])
        self.assertEqual(self.scene.go()[0], cr.EXIT_NORUN)
        self.assertIn('UI automation could not start on the M4', self.scene.summary())

    def test_a_failed_build_is_red_and_runs_nothing(self):
        self.scene.ui_plan['build_fails'] = True
        self.assertEqual(self.scene.go()[0], cr.EXIT_RED)
        self.assertEqual([c['args'][0] for c in self.scene.ui_calls_made()], ['build-for-testing'])

    def test_corpus_ui_lines_that_are_not_words_and_numbers_are_dropped(self):
        self.scene.ui_plan['print'] = ['[corpus-ui] test1 loaded total=3 /Volumes/PrivateDrive/Grandma',
                                       '[corpus-ui] test1 step Birthday 1988.mov ms=3',
                                       'noise [corpus-ui] test2 tabs count=6']
        self.scene.go()
        text = self.scene.summary()
        self.assertIn('test2 tabs count=6', text)
        self.assertNoSecrets(text)

    def test_the_seal_refuses_another_mac_before_anything_runs(self):
        seal = cr.Seal(self.scene.home, 'RicksUltra')
        lane = ui.UILane(cr, seal, 'b' * 40, '20261118_230000_9', self.scene.out, self.scene.worktree, self.scene.dd,
                         xcodebuild=str(self.scene.ui_fake), ps=lambda: '', log_errors=lambda s: Counter())
        with self.assertRaises(cr.Refused):
            lane.go()
        self.assertEqual(self.scene.ui_calls_made(), [])


class UILanePureTests(unittest.TestCase):

    def test_safe_text(self):
        self.assertTrue(ui.safe_text('XCTAssertEqual failed: (12) is not equal to (13) - the box says 13'))
        self.assertTrue(ui.safe_text('XCTAssertEqual failed: ("12") is not equal to ("1,013")'))
        for bad in ('Click "Grandma" StaticText', 'is not equal to ("x")', 'path /Volumes/X', 'reel_07.MXF missing', 'x' * 241):
            self.assertFalse(ui.safe_text(bad), bad)

    def test_running_videoscan_counts_any_build(self):
        self.assertEqual(ui.running_videoscan('/a/VideoScan.app/Contents/MacOS/VideoScan\n'
                                              '/b/DD/Build/Products/Debug/VideoScan.app/Contents/MacOS/VideoScan\n'
                                              '/Applications/VideoScan Background.app/Contents/MacOS/VideoScanBackground\n'), 2)
        self.assertEqual(ui.running_videoscan(''), 0)

    def test_seed_is_the_commit_prefix(self):
        self.assertEqual(ui.seed_for('0000002a' + 'f' * 32), 42)


class UICallerTests(unittest.TestCase):

    def run_sh(self, script, *args):
        return subprocess.run(['/bin/bash', str(SCRIPTS / script), *args], capture_output=True, text=True, timeout=60)

    def test_corpus_run_sh_run_ui_ships_the_lane_module(self):
        p = self.run_sh('corpus_run.sh', 'run', 'ui', '--ref', 'HEAD', '--limit', '30', '--dry-run')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertRegex(p.stdout, r'install .*corpus_ui_lane\.py -> ricksm4\.local:.*/m4run/bin/\d{8}_\d{6}_\d+/corpus_ui_lane\.py')
        for arg in ('--corpus-lane', 'ui', '--limit', '30'):
            self.assertIn(f'<string>{arg}</string>', p.stdout)

    def test_the_ui_lane_is_m4_only(self):
        self.assertEqual(self.run_sh('m4_run.sh', 'corpus', '--corpus-lane', 'ui', '--host', 'ultra', '--dry-run').returncode, 2)

    def test_corpus_run_dispatches_host_ui_to_the_lane(self):
        with tempfile.TemporaryDirectory() as tmp:
            scene = UIScene(tmp)
            scene.ui_plan_path.write_text(json.dumps(scene.ui_plan))
            argv = ['host', 'ui', '--sha', 'c' * 40, '--stamp', '20261118_230000_5', '--out', str(scene.out),
                    '--worktree', str(scene.worktree), '--derived-data', str(scene.dd), '--bin', str(SCRIPTS)]
            with mock.patch.dict(os.environ, {'FAKE_UI_PLAN': str(scene.ui_plan_path)}), \
                    mock.patch.object(ui, 'running_videoscan', return_value=0), \
                    mock.patch.object(ui, 'unified_log_errors', return_value=Counter()):
                code = cr.main(argv, seal=scene.seal, xcodebuild=str(scene.ui_fake))
            self.assertEqual(code, cr.EXIT_GREEN, scene.summary())

    def test_a_dead_ui_run_leaves_a_work_folder_the_housekeeping_knows(self):
        self.assertIsNotNone(cr._RUN_WORK.fullmatch('20261118_230000_1-ui'))
        self.assertIsNotNone(th.RUN_WORK.fullmatch('20261118_230000_1-ui'))


if __name__ == '__main__':
    unittest.main()
