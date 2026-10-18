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
        sys.exit(config.get('package_build_exit', 0))
    filters = [args[i + 1] for i, a in enumerate(args) if a == '--filter']
    stage = re.match(r'VideoScanCoreTests\\\.(\w+?)PkgTests/', filters[0]).group(1).lower()
    s = config.get('package', {}).get(stage, {})
    if not s.get('no_summary'):
        for n in range(s.get('xctest', 1)):
            print(f"Test Case '-[VideoScanCoreTests.X test{n}]' passed (0.001 seconds).")
        print('\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.001) seconds')
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
        self.completed = subprocess.run([str(self.binary), '--away', '--queue-only', '--manifest', str(manifest),
                                         '--results-root', str(self.root / 'results'), *args],
                                        text=True, capture_output=True, env=env, timeout=90)
        found = list((self.root / 'results').glob('*/result.json'))
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
        runs = [c for c in self.swift_calls if c['args'][0] == 'test']
        self.assertEqual(len(builds), 1)
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
        self.assertEqual(self.stage('unit')['status'], 'failed')
        self.assertIn('known issue', self.stage('unit')['reason'])
        self.assertEqual(self.stage('unit')['known_issues'], 1)
        self.assertEqual(self.stage('regression')['status'], 'failed')
        self.assertIn('counts unavailable', self.stage('regression')['reason'])

    def test_below_package_floor_fails(self):
        self.manifest['stages'][0]['package_expected_floor'] = 9
        self.run_runner()
        self.assertEqual(self.stage('unit')['status'], 'failed')
        self.assertIn('below expected floor 9', self.stage('unit')['reason'])

    def test_package_build_failure_never_passes_and_skips_package_runs(self):
        self.config['package_build_exit'] = 3
        self.run_runner()
        self.assertEqual(self.result['package_build_exit_code'], 3)
        self.assertEqual([c['args'][0] for c in self.swift_calls], ['build'])
        unit = self.stage('unit')
        self.assertNotEqual(unit['status'], 'passed')
        self.assertIn('package build exit 3', unit['reason'])
        self.assertEqual(self.stage('integration')['status'], 'passed')

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
        self.assertEqual(regression['passed'], 3)

    def test_mismatched_package_selectors_fail_preflight(self):
        self.manifest['stages'][0]['package_selectors'] = ['VideoScanCoreTests.SomethingElse']
        self.run_runner()
        self.assertEqual(self.completed.returncode, 1)
        self.assertEqual(self.swift_calls, [])
        self.assertTrue(any('package selector/assignment mismatch: unit' in e for e in self.result['inventory_errors']))

    def test_unblocked_package_suite_without_selectors_fails_preflight(self):
        del self.manifest['stages'][1]['package_selectors']
        self.run_runner('--dry-run')
        self.assertNotEqual(self.completed.returncode, 0)
        self.assertIn('package selector/assignment mismatch: regression', self.completed.stdout)


if __name__ == '__main__':
    unittest.main()
