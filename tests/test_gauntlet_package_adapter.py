"""Black-box sensors for the gauntlet's VideoScanCore package adapter (2026-10-18).

Fake `xcodebuild`, `xcrun` and `swift` on PATH; the real Runner.swift and
inventory.swift. Never builds or launches VideoScan. Pins: one package build
per run, one `swift test --skip-build` per stage with one anchored `--filter`
per suite, counts read from the console with the nightly's per-test rules,
a package failure / known issue / build failure / missing summary never lets
a stage pass, a package-only stage runs, and inventory refuses package
selectors that do not match the unblocked package assignments.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
STAGES = ['unit', 'regression', 'integration', 'performance', 'hallie', 'stress', 'ui']
PKG_DIR = 'VideoScan/VideoScanCore/Tests/VideoScanCoreTests'

FAKE = r'''import json, os, pathlib, plistlib, re, sys
args = sys.argv[1:]
config = json.loads(pathlib.Path(os.environ['FAKE_CONFIG']).read_text())
tool = pathlib.Path(sys.argv[0]).name
if tool == 'swift':
    with open(os.environ['FAKE_CALLS'] + '.swift', 'a') as f:
        f.write(json.dumps({'args': args, 'env': {k: os.environ.get(k, '') for k in ('HOME', 'TMPDIR', 'VS_UI_TEST')}}) + '\n')
    if args[0] == 'build':
        if config.get('package_build_orphan'):
            # A child that outlives the build in its process group (Codex 11/05).
            import subprocess
            subprocess.Popen(['/bin/sleep', '20'], stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        sys.exit(config.get('package_build_exit', 0))
    filters = [args[i + 1] for i, a in enumerate(args) if a == '--filter']
    stage = re.match(r'VideoScanCoreTests\\\.(\w+?)PkgTests/', filters[0]).group(1).lower()
    s = config.get('package', {}).get(stage, {})
    xclass = f'VideoScanCoreTests.{stage.title()}PkgTests'      # the stage's XCTest class, selected by its filter
    if args[1] == 'list':
        # `swift test list` as SwiftPM 6.4 really behaves: it accepts --filter
        # and IGNORES it, printing the WHOLE package (M4 gauntlet 2026-11-06,
        # regression-package-list.log: 2416 lines for a filtered stage).
        # XCTest as Module.Class/method, Swift Testing with "()"; decoys the
        # stage's filter must exclude (the other stage, another class, a
        # longer name that only the filter's trailing "/" rules out).
        if s.get('list_exit'):
            sys.exit(s['list_exit'])
        if s.get('list_orphan'):
            import subprocess
            subprocess.Popen(['/bin/sleep', '20'], stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for st in ('unit', 'regression'):
            c = config.get('package', {}).get(st, {})
            for n in range(c.get('listed_xctest', c.get('xctest', 1))):
                print(f'VideoScanCoreTests.{st.title()}PkgTests/test{n}')
            for n in range(c.get('passed', 2)):
                print(f'VideoScanCoreTests.{st}/ok{n}()')
        print('VideoScanCoreTests.UnitPkgTestsLonger/testDecoy')
        print('VideoScanCoreTests.Elsewhere/testOther')
        sys.exit(0)
    # Swift Testing's event stream (what the runner counts), written beside
    # the console the way the real library writes it: one JSON record a line.
    events = []
    def ev(kind, test_id=None, **extra):
        payload = dict(kind=kind, messages=[], **extra)
        if test_id: payload['testID'] = test_id
        events.append(dict(kind='event', version='6.4.0', payload=payload))
    def ran(name, issue=None):
        tid = f'VideoScanCoreTests.{stage}/{name}()/A.swift:1:1'
        events.insert(0, dict(kind='test', version='6.4.0', payload=dict(id=tid, kind='function', name=name + '()')))
        ev('testStarted', tid)
        if issue is not None: ev('issueRecorded', tid, issue=issue)
        ev('testEnded', tid)
    if not s.get('no_summary'):
        for n in range(s.get('passed', 2)): ran(f'ok{n}')
        for n in range(s.get('failed', 0)): ran(f'bad{n}', dict(isKnown=False, isFailure=True))
        for n in range(s.get('known', 0)): ran(f'kn{n}', dict(isKnown=True, isFailure=False))
        for name in s.get('stream_only', []): ran(name)
        ev('runEnded')
    if '--event-stream-output-path' in args:
        with open(args[args.index('--event-stream-output-path') + 1], 'w') as f:
            f.writelines(json.dumps(e) + '\n' for e in events)
    if not s.get('no_summary'):
        # XCTest first, the way `swift test --filter` runs it: the runner's
        # "Selected tests" bracket (a filtered run never says "All tests"), one
        # started/passed pair per test (anything the test body prints lands
        # between them), then the runner's own summary.
        n_x = s.get('xctest', 1)
        print("Test Suite 'Selected tests' started at 2026-11-05 14:00:00.000.")
        print("Test Suite 'VideoScanCoreTests.xctest' started at 2026-11-05 14:00:00.001.")
        if not n_x:
            for line in s.get('xctest_console', []): print(line)
        for n in range(n_x):
            print(f"Test Case '-[{xclass} test{n}]' started.")
            if n == 0:
                for line in s.get('xctest_console', []): print(line)
            print(f"Test Case '-[{xclass} test{n}]' passed (0.001 seconds).")
        print("Test Suite 'Selected tests' passed at 2026-11-05 14:00:00.100.")
        print(f"\t Executed {n_x} test{'' if n_x == 1 else 's'}, with 0 failures (0 unexpected) in 0.001 (0.001) seconds")
        print('◇ Test run started.')
    for line in s.get('console', []):
        print(line)                       # what a Swift Testing test body printed
    if not s.get('no_summary'):
        zw = '​'
        for n in range(s.get('passed', 2)):
            print(f'{zw}✔ Test ok{n}() passed after 0.001 seconds.')
        for n in range(s.get('failed', 0)):
            print(f'✘ Test bad{n}() recorded an issue at A.swift:1:1: Expectation failed: x failed after y')
            print(f'✘ Test bad{n}() failed after 0.001 seconds with 1 issue.')
        for n in range(s.get('known', 0)):
            print(f'━ Test kn{n}() recorded a known issue at A.swift:1:1: Expectation failed')
            print(f'━ Test kn{n}() passed after 0.001 seconds with 1 known issue.')
        print('✔ Test run with 3 tests in 1 suite passed after 0.1 seconds.')
    sys.exit(s.get('exit', 0))
if tool == 'xcodebuild':
    if 'build-for-testing' in args:
        root = pathlib.Path(args[args.index('-derivedDataPath') + 1]) / 'Build/Products'
        root.mkdir(parents=True)
        with (root / 'Fake.xctestrun').open('wb') as f:
            plistlib.dump({'Test': {'TestBundlePath': 'fake', 'EnvironmentVariables': {}}}, f)
        sys.exit(config.get('build_exit', 0))
    pathlib.Path(args[args.index('-resultBundlePath') + 1]).mkdir()
    sys.exit(0)
print(json.dumps(dict(passedTests=2, failedTests=0, skippedTests=0, expectedFailures=0,
                     totalTestCount=2, result='Passed')))
'''


@unittest.skipUnless(sys.platform == "darwin", "macOS-only: builds with /usr/bin/swift")
class GauntletPackageAdapterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory(prefix='gauntlet-package-', dir='/private/tmp')
        cls.repo = Path(cls.workspace.name)
        scripts = cls.repo / 'scripts/gauntlet'
        scripts.mkdir(parents=True)
        for name in ('Runner.swift', 'inventory.swift', 'publish.swift'):
            shutil.copy2(REPO / 'scripts/gauntlet' / name, scripts / name)
        cls.binary = cls.repo / 'runner'
        subprocess.run(['/usr/bin/swiftc', '-module-cache-path', str(cls.repo / 'swift-cache'),
                        str(scripts / 'Runner.swift'), '-o', str(cls.binary)], check=True, capture_output=True)
        cls.assignments = []
        app = cls.repo / 'VideoScan/VideoScanTests'
        app.mkdir(parents=True)
        pkg = cls.repo / PKG_DIR
        pkg.mkdir(parents=True)
        for stage in STAGES[:-1]:
            suite = stage.title() + 'Tests'
            path = app / (suite + '.swift')
            path.write_text(f'struct {suite} {{\n @Test func first() {{}}\n @Test func second() {{}}\n}}\n')
            cls.assignments.append(dict(path=str(path.relative_to(cls.repo)), kind='xcode', stage=stage,
                                        suites=[suite], tests=['first', 'second']))
        for stage in ('unit', 'regression'):
            suite = stage.title() + 'PkgTests'
            path = pkg / (suite + '.swift')
            path.write_text(f'struct {suite} {{\n @Test func one() {{}}\n @Test func two() {{}}\n}}\n')
            cls.assignments.append(dict(path=str(path.relative_to(cls.repo)), kind='package', stage=stage,
                                        suites=[suite], tests=['one', 'two']))
        cls.bin_dir = cls.repo / 'bin'
        cls.bin_dir.mkdir()
        for tool in ('xcodebuild', 'xcrun', 'swift'):
            path = cls.bin_dir / tool
            path.write_text('#!' + sys.executable + '\n' + FAKE)
            path.chmod(0o755)

    @classmethod
    def tearDownClass(cls):
        cls.workspace.cleanup()

    def setUp(self):
        self.case = tempfile.TemporaryDirectory(prefix='case-', dir=self.repo)
        self.addCleanup(self.case.cleanup)
        self.root = Path(self.case.name)
        stages = []
        for s in STAGES:
            entry = dict(name=s, expected_floor=2 if s != 'ui' else 1,
                         selectors=['VideoScanTests/' + s.title() + 'Tests'] if s != 'ui' else [], timeout_s=20)
            if s in ('unit', 'regression'):
                entry.update(package_selectors=['VideoScanCoreTests.' + s.title() + 'PkgTests'], package_expected_floor=2)
            stages.append(entry)
        self.manifest = dict(assignments=json.loads(json.dumps(self.assignments)), stages=stages)
        self.config = {}

    def run_runner(self, *args):
        manifest = self.root / 'manifest.json'
        manifest.write_text(json.dumps(self.manifest))
        config = self.root / 'config.json'
        config.write_text(json.dumps(self.config))
        env = os.environ.copy()
        env.update(PATH=str(self.bin_dir) + ':/usr/bin:/bin', FAKE_CONFIG=str(config),
                   FAKE_CALLS=str(self.root / 'calls.jsonl'), HOME='/private/tmp/poison-home')
        # A fresh results root per run: a test may run the runner more than once.
        self.runs = getattr(self, 'runs', 0) + 1
        results = self.root / f'results{self.runs}'
        self.completed = subprocess.run([str(self.binary), '--away', '--queue-only', '--manifest', str(manifest),
                                         '--results-root', str(results), *args],
                                        text=True, capture_output=True, env=env, timeout=90)
        found = list(results.glob('*/result.json'))
        self.result = json.loads(found[0].read_text()) if found else None
        calls = self.root / 'calls.jsonl.swift'
        self.swift_calls = [json.loads(l) for l in calls.read_text().splitlines()] if calls.exists() else []
        return self.completed

    def stage(self, name):
        return next(s for s in self.result['stages'] if s['name'] == name)

    def test_one_package_build_and_one_filtered_run_per_stage_with_isolated_env(self):
        self.run_runner()
        self.assertEqual(self.result['inventory_errors'], [], self.completed.stderr)
        builds = [c for c in self.swift_calls if c['args'][0] == 'build']
        runs = [c for c in self.swift_calls if c['args'][0] == 'test' and c['args'][1] != 'list']
        lists = [c for c in self.swift_calls if c['args'][:2] == ['test', 'list']]
        self.assertEqual(len(builds), 1)
        # One `swift test list --skip-build --filter …` per stage: the independent
        # XCTest count the console tally must agree with (Codex 2026-11-05 re-review).
        self.assertEqual(len(lists), 2)
        self.assertIn('--skip-build', lists[0]['args'])
        self.assertIn(r'VideoScanCoreTests\.UnitPkgTests/', lists[0]['args'])
        self.assertIn('--build-tests', builds[0]['args'])
        self.assertEqual(builds[0]['args'][builds[0]['args'].index('-c') + 1], 'release')
        # swift test enables testable imports itself; swift build -c release does not.
        self.assertEqual(builds[0]['args'][builds[0]['args'].index('-Xswiftc') + 1], '-enable-testing')
        self.assertEqual(len(runs), 2)
        for call in runs:
            self.assertIn('--skip-build', call['args'])
            self.assertTrue(call['env']['HOME'].startswith(str(self.root / 'results')), call['env'])
            self.assertEqual(call['env']['VS_UI_TEST'], '1')
        self.assertIn(r'VideoScanCoreTests\.UnitPkgTests/', runs[0]['args'])
        unit = self.stage('unit')
        self.assertEqual(unit['status'], 'passed', unit)
        # 2 xcode (fake summary) + 1 XCTest + 2 Swift Testing package lines.
        self.assertEqual(unit['passed'], 5)
        self.assertEqual(unit['package']['passed'], 3)
        self.assertEqual(self.stage('integration')['status'], 'passed')
        self.assertNotIn('package', self.stage('integration'))

    def test_package_failure_fails_a_stage_whose_xcode_part_passed(self):
        self.config['package'] = {'unit': {'failed': 1, 'exit': 1}}
        self.run_runner()
        unit = self.stage('unit')
        self.assertEqual(unit['status'], 'failed')
        self.assertIn('package:', unit['reason'])
        self.assertEqual(unit['failed'], 1)
        self.assertEqual(self.stage('regression')['status'], 'passed')

    def test_package_known_issue_and_missing_summary_are_not_passes(self):
        self.config['package'] = {'unit': {'known': 1}, 'regression': {'no_summary': True}}
        self.run_runner()
        self.assertEqual(self.stage('unit')['status'], 'amber')       # tracked: AMBER, not a pass
        self.assertIn('known issue', self.stage('unit')['reason'])
        self.assertEqual(self.stage('unit')['known_issues'], 1)
        self.assertEqual(self.stage('regression')['status'], 'failed')
        self.assertIn('counts unavailable', self.stage('regression')['reason'])

    def test_below_package_floor_fails(self):
        # A declared test that does not execute (floor 2, one ran). A floor set
        # above the declarations is refused at preflight instead (below).
        self.config['package'] = {'unit': {'xctest': 0, 'passed': 1}}
        self.run_runner()
        self.assertEqual(self.result['inventory_errors'], [])
        self.assertEqual(self.stage('unit')['status'], 'failed')
        self.assertIn('below expected floor 2', self.stage('unit')['reason'])

    # M4 deep gauntlet 2026-11-05 (2c8fa9777, unit-package.log 1370-1375): a
    # FamilyTree test's stdout print landed inside a concurrent test's result
    # line, so the console scraper saw 774 of 775 and called the stage RED.
    M4_SPLIT = [
        '✔ Test theMarkerInTheAppsExactShapeDecodes() passed after 0.366 seconds.',
        '✔ Test refused[family-tree] gedcom pull label=Alphasurname header=26 Aug 2026 05:07:30 '
        'file=tree-20generations.ged size=427 mtime=2026-11-05T20:58:06Z program=getmyancestors '
        'sha=f7821da7 ingest=2026-11-05T20:58:06Z generation=gen-20261105T205806-1270',
        'LinesLandWithTheirReasonAndAreNotADayFile() passed after 0.366 seconds.',
    ]

    def test_interleaved_stdout_never_loses_a_passed_test(self):
        self.config['package'] = {'unit': {'xctest': 0, 'passed': 0, 'console': self.M4_SPLIT,
                                           'stream_only': ['theMarkerInTheAppsExactShapeDecodes',
                                                           'refusedLinesLandWithTheirReasonAndAreNotADayFile']}}
        self.run_runner()
        unit = self.stage('unit')
        self.assertEqual(unit['package']['passed'], 2, unit)
        self.assertEqual(unit['package']['status'], 'passed', unit)
        runs = [c for c in self.swift_calls if c['args'][0] == 'test' and c['args'][1] != 'list']
        self.assertIn('--event-stream-output-path', runs[0]['args'])

    def test_a_printed_lookalike_result_line_is_never_counted(self):
        # The other direction: a test that prints a result-shaped line must not
        # stand in for a declared test that never ran (floor 2, one ran).
        # Codex 2026-11-05 (P1): the Swift Testing-shaped line was already
        # harmless (counts come from the stream); the XCTest-shaped one was
        # counted by the console regex, so one real function read as two.
        self.assert_ghost_is_not_counted("Test Case '-[VideoScanCoreTests.UnitPkgTests ghost]' passed (0.001 seconds).")

    def test_a_printed_swift_testing_lookalike_is_never_counted(self):
        self.assert_ghost_is_not_counted('✔ Test ghost() passed after 0.001 seconds.')

    def assert_ghost_is_not_counted(self, ghost):
        self.config['package'] = {'unit': {'xctest': 0, 'passed': 1, 'console': [ghost]}}
        self.run_runner()
        unit = self.stage('unit')
        self.assertEqual(unit['package']['passed'], 1, unit)
        self.assertEqual(unit['status'], 'failed')
        self.assertIn('below expected floor 2', unit['reason'])

    def test_an_xctest_body_cannot_forge_a_ghost_or_its_own_result(self):
        # Printed from INSIDE test0's body: a started/passed pair for a ghost
        # and a "failed" for itself. The runner's real "passed" comes last and
        # wins; the ghost never started, so it never counts. 1 XCTest + 1 Swift
        # Testing = floor 2, GREEN — and no third test.
        self.config['package'] = {'unit': {'xctest': 1, 'passed': 1, 'xctest_console': [
            "Test Case '-[VideoScanCoreTests.UnitPkgTests ghost]' started.",
            "Test Case '-[VideoScanCoreTests.UnitPkgTests ghost]' passed (0.001 seconds).",
            "Test Case '-[VideoScanCoreTests.UnitPkgTests test0]' failed (0.001 seconds)."]}}
        self.run_runner()
        unit = self.stage('unit')
        self.assertEqual(unit['package']['passed'], 2, unit)
        self.assertEqual(unit['package']['failed'], 0, unit)
        self.assertEqual(unit['status'], 'passed', unit)

    def test_a_forged_closing_bracket_and_summary_never_inflate(self):
        # Codex 2026-11-05 re-review (P1): inside the real test0, print its own
        # pass, a ghost start/pass pair, a closing bracket and "Executed 2
        # tests". The runner's real close and one-test summary follow; the
        # selected XCTest list says one. Two stories → counts unavailable, RED
        # — never "2 passed", never a floor met by a print.
        self.config['package'] = {'unit': {'xctest': 1, 'passed': 1, 'xctest_console': [
            "Test Case '-[VideoScanCoreTests.UnitPkgTests test0]' passed (0.001 seconds).",
            "Test Case '-[VideoScanCoreTests.UnitPkgTests ghost]' started.",
            "Test Case '-[VideoScanCoreTests.UnitPkgTests ghost]' passed (0.001 seconds).",
            "Test Suite 'Selected tests' passed at 2026-11-05 14:00:00.050.",
            "\t Executed 2 tests, with 0 failures (0 unexpected) in 0.001 (0.001) seconds"]}}
        self.run_runner()
        unit = self.stage('unit')
        self.assertEqual(unit['status'], 'failed', unit)
        self.assertIn('counts unavailable', unit['reason'])
        self.assertNotIn('passed', unit['package'])

    def test_a_contaminated_listing_launches_no_package_tests(self):
        # Codex 2026-11-05 re-review 2 (P2): `swift test list` left a child in
        # its process group; the runner recorded contamination and still ran
        # `swift test` in the same environment. Isolation failed: launch nothing.
        self.config['package'] = {'unit': {'list_orphan': True}}
        self.run_runner()
        calls = [c['args'][:2] for c in self.swift_calls]
        self.assertIn(['test', 'list'], calls)
        unit_runs = [c for c in self.swift_calls if c['args'][:2] != ['test', 'list'] and c['args'][0] == 'test'
                     and r'VideoScanCoreTests\.UnitPkgTests/' in c['args']]
        self.assertEqual(unit_runs, [], 'a package test ran after a contaminated listing')
        unit = self.stage('unit')
        self.assertEqual(unit['status'], 'failed', unit)
        self.assertIn('contamination', unit['reason'])
        self.assertEqual(self.result['status'], 'failed')

    def test_a_filtered_runs_selected_tests_bracket_counts_and_a_missing_list_is_red(self):
        # The fake always prints the filtered runner's "Selected tests" bracket
        # (Codex 2026-11-05 re-review P1: "All tests" only read 0 XCTest).
        self.config['package'] = {'unit': {'xctest': 2, 'passed': 1}}
        self.run_runner()
        unit = self.stage('unit')
        self.assertEqual(unit['package']['passed'], 3, unit)
        self.assertEqual(unit['status'], 'passed', unit)
        # Without the independent list there is no cross-check: unavailable, RED.
        self.config['package'] = {'unit': {'xctest': 2, 'passed': 1, 'list_exit': 1}}
        self.run_runner()
        unit = self.stage('unit')
        self.assertEqual(unit['status'], 'failed', unit)
        self.assertIn('counts unavailable', unit['reason'])
        # A list that disagrees with what ran (a selected XCTest never reported) is RED too.
        self.config['package'] = {'unit': {'xctest': 2, 'listed_xctest': 3, 'passed': 1}}
        self.run_runner()
        self.assertEqual(self.stage('unit')['status'], 'failed')
        self.assertIn('counts unavailable', self.stage('unit')['reason'])

    def test_an_unfiltered_listing_is_filtered_by_the_stages_own_selectors(self):
        # Regression, M4 gauntlet 2026-11-06 (main d87bf9828): `swift test list`
        # ignores --filter and printed the whole package, so the tally of the
        # filtered run never equalled the listing and unit, regression and
        # performance were RED "structured test counts unavailable". The
        # runner applies the stage's own --filter regexes to the listing
        # (SwiftPM's semantics: unanchored match on Module.Class/method, any
        # filter selects): the other stage's class, Elsewhere and
        # UnitPkgTestsLonger are listed but not selected.
        self.config['package'] = {'unit': {'xctest': 2, 'passed': 1}, 'regression': {'xctest': 3, 'passed': 2}}
        self.run_runner()
        listing = next(self.root.glob('results*/*/unit-package-list.log')).read_text()
        self.assertIn('VideoScanCoreTests.RegressionPkgTests/test2', listing)   # the fake is unfiltered
        self.assertIn('VideoScanCoreTests.Elsewhere/testOther', listing)
        unit, regression = self.stage('unit'), self.stage('regression')
        self.assertEqual(unit['package']['status'], 'passed', unit)
        self.assertEqual(unit['package']['passed'], 3, unit)                 # 2 XCTest + 1 Swift Testing
        self.assertEqual(regression['package']['status'], 'passed', regression)
        self.assertEqual(regression['package']['passed'], 5, regression)     # 3 XCTest + 2 Swift Testing
        # Guarantee kept: a selected XCTest the run never reported is still RED.
        self.config['package'] = {'unit': {'xctest': 2, 'listed_xctest': 3, 'passed': 1}}
        self.run_runner()
        self.assertEqual(self.stage('unit')['status'], 'failed')
        self.assertIn('counts unavailable', self.stage('unit')['reason'])

    def test_package_build_failure_never_passes_and_skips_package_runs(self):
        self.config['package_build_exit'] = 3
        self.run_runner()
        self.assertEqual(self.result['package_build_exit_code'], 3)
        self.assertEqual([c['args'][0] for c in self.swift_calls], ['build'])
        unit = self.stage('unit')
        self.assertEqual(unit['status'], 'failed')            # a build failure is RED, never AMBER
        self.assertIn('package build exit 3', unit['reason'])
        self.assertEqual(self.result['status'], 'failed')
        self.assertEqual(self.stage('integration')['status'], 'passed')

    def test_a_package_build_that_leaves_a_child_behind_is_red_not_amber(self):
        # Codex 2026-11-05 (P1): exit 125 + contamination blocked every stage
        # before runPackageSuites could say the build failed; the run was
        # AMBER, exit 0. A package build exit != 0 or contamination is RED.
        self.config['package_build_orphan'] = True
        self.run_runner()
        self.assertEqual(self.result['package_build_exit_code'], 125)
        self.assertEqual(self.result['status'], 'failed', self.result)
        self.assertEqual(self.completed.returncode, 1)
        self.assertIn('GAUNTLET FAILED', self.completed.stdout)
        self.assertIn('package build', self.result.get('reason', ''))

    def test_package_only_stage_runs(self):
        self.manifest['assignments'] = [a for a in self.manifest['assignments']
                                        if not (a['kind'] == 'xcode' and a['stage'] == 'regression')]
        self.manifest['assignments'].append(dict(self.assignments[1], blocked_reason='held back'))
        self.manifest['stages'][1]['selectors'] = []
        self.manifest['stages'][1]['blocked'] = [dict(name=self.assignments[1]['path'], reason='held back')]
        self.run_runner()
        self.assertEqual(self.result['inventory_errors'], [])
        regression = self.stage('regression')
        self.assertEqual(regression['status'], 'blocked')      # safe subset passed, one suite held back
        self.assertEqual(regression['package']['status'], 'passed')
        # Blocked-only is AMBER (Rick 2026-11-05): exit 0, the reasons counted.
        self.assertEqual(self.result['status'], 'amber')
        self.assertEqual(self.completed.returncode, 0)
        self.assertIn('1 stage blocked (1 unadapted suites)', self.result['amber_reasons'])
        self.assertEqual(regression['passed'], 3)

    def test_mismatched_package_selectors_fail_preflight(self):
        self.manifest['stages'][0]['package_selectors'] = ['VideoScanCoreTests.SomethingElse']
        self.run_runner()
        self.assertEqual(self.completed.returncode, 1)
        self.assertEqual(self.swift_calls, [])
        self.assertTrue(any('package selector/assignment mismatch: unit' in e for e in self.result['inventory_errors']))

    def test_a_floor_above_the_declarations_fails_preflight(self):
        # M4 deep gauntlet 2026-11-05 (52c3a85e7): feat/helper-owns-schedule deleted
        # 6 package + 3 app regression tests (and 7 unit) but left the floors, so
        # every M4 run was "below expected floor" while inventory said 0 errors.
        # The floor is the declaration count (resolve_floor_conflicts.py): a
        # deleted test lowers it in the same commit, or preflight says so.
        self.manifest['stages'][1]['package_expected_floor'] = 3
        self.manifest['stages'][1]['expected_floor'] = 3
        self.run_runner('--dry-run')
        self.assertNotEqual(self.completed.returncode, 0)
        self.assertIn('package_expected_floor above declaration count: regression (3 > 2', self.completed.stdout)
        self.assertIn('; expected_floor above declaration count: regression (3 > 2', self.completed.stdout)

    def test_unblocked_package_suite_without_selectors_fails_preflight(self):
        del self.manifest['stages'][1]['package_selectors']
        self.run_runner('--dry-run')
        self.assertNotEqual(self.completed.returncode, 0)
        self.assertIn('package selector/assignment mismatch: regression', self.completed.stdout)


if __name__ == '__main__':
    unittest.main()
