"""Black-box gauntlet control-plane sensors; never builds or launches VideoScan."""
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


class GauntletRunnerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory(prefix='gauntlet-control-', dir='/private/tmp')
        cls.repo = Path(cls.workspace.name)
        scripts = cls.repo / 'scripts/gauntlet'
        scripts.mkdir(parents=True)
        for name in ('Runner.swift', 'inventory.swift', 'publish.swift'):
            shutil.copy2(REPO / 'scripts/gauntlet' / name, scripts / name)
        cls.binary = cls.repo / 'runner'
        subprocess.run(['/usr/bin/swiftc', '-module-cache-path', str(cls.repo / 'swift-cache'),
                        str(scripts / 'Runner.swift'), '-o', str(cls.binary)], check=True, capture_output=True)
        cls.assignments = []
        source_dir = cls.repo / 'VideoScan/VideoScanTests'
        source_dir.mkdir(parents=True)
        for stage in STAGES[:-1]:
            suite = stage.title() + 'Tests'
            path = source_dir / (suite + '.swift')
            path.write_text(f'struct {suite} {{\n @Test func first() {{}}\n @Test func second() {{}}\n}}\n')
            cls.assignments.append(dict(path=str(path.relative_to(cls.repo)), kind='xcode', stage=stage,
                                        suites=[suite], tests=['first', 'second']))
        cls.bin_dir = cls.repo / 'bin'
        cls.bin_dir.mkdir()
        fake = '''import json, os, pathlib, plistlib, subprocess, sys, time
args = sys.argv[1:]
config = json.loads(pathlib.Path(os.environ['FAKE_CONFIG']).read_text())
if pathlib.Path(sys.argv[0]).name == 'xcodebuild':
    with open(os.environ['FAKE_CALLS'], 'a') as f:
        f.write(json.dumps({'args': args, 'env': dict(os.environ)}) + '\\n')
    if 'build-for-testing' in args:
        root = pathlib.Path(args[args.index('-derivedDataPath')+1]) / 'Build/Products'
        root.mkdir(parents=True)
        with (root / 'Fake.xctestrun').open('wb') as f:
            plistlib.dump({'Test': {'TestBundlePath': 'fake', 'EnvironmentVariables': {}}}, f)
        sys.exit(config.get('build_exit', 0))
    bundle = pathlib.Path(args[args.index('-resultBundlePath')+1])
    bundle.mkdir()
    stage = bundle.stem
    if config.get(stage, {}).get('descendant'):
        child = subprocess.Popen(['/bin/sleep', '30'])
        pathlib.Path(os.environ['FAKE_CALLS'] + '.child').write_text(str(child.pid))
    time.sleep(config.get(stage, {}).get('sleep', 0))
    sys.exit(config.get(stage, {}).get('exit', 0))
else:
    stage = pathlib.Path(args[args.index('--path')+1]).stem
    settings = config.get(stage, {})
    if settings.get('malformed'):
        print('{}')
    else:
        passed, failed, skipped = (settings.get(k, d) for k,d in [('passed',2),('failed',0),('skipped',0)])
        print(json.dumps(dict(passedTests=passed, failedTests=failed, skippedTests=skipped,
                             totalTestCount=passed+failed+skipped, result='Failed' if failed else 'Passed')))
'''
        for tool in ('xcodebuild', 'xcrun'):
            path = cls.bin_dir / tool
            path.write_text('#!' + sys.executable + '\n' + fake)
            path.chmod(0o755)

    @classmethod
    def tearDownClass(cls):
        cls.workspace.cleanup()

    def setUp(self):
        self.case = tempfile.TemporaryDirectory(prefix='case-', dir=self.repo)
        self.addCleanup(self.case.cleanup)
        self.root = Path(self.case.name)
        self.manifest = dict(assignments=self.assignments, stages=[dict(
            name=s, expected_floor=2 if s != 'ui' else 1,
            selectors=['VideoScanTests/' + s.title() + 'Tests'] if s != 'ui' else [],
            timeout_s=20) for s in STAGES])
        self.config = {}

    def run_runner(self, *args, environment=None, results=None):
        manifest = self.root / 'manifest.json'
        manifest.write_text(json.dumps(self.manifest))
        config = self.root / 'config.json'
        config.write_text(json.dumps(self.config))
        env = os.environ.copy()
        env.update(PATH=str(self.bin_dir) + ':/usr/bin:/bin', FAKE_CONFIG=str(config),
                   FAKE_CALLS=str(self.root / 'calls.jsonl'))
        env.update(environment or {})
        self.completed = subprocess.run([str(self.binary), '--away', '--queue-only', '--manifest', str(manifest),
                                         '--results-root', str(results or self.root / 'results'), *args],
                                        text=True, capture_output=True, env=env, timeout=90)
        found = list((self.root / 'results').glob('*/result.json'))
        self.result = json.loads(found[0].read_text()) if found else None
        call_file = self.root / 'calls.jsonl'
        self.calls = [json.loads(line) for line in call_file.read_text().splitlines()] if call_file.exists() else []
        return self.completed

    def stage(self, name):
        return next(s for s in self.result['stages'] if s['name'] == name)

    def test_failure_preserves_exit_and_continues_using_one_build(self):
        self.config['unit'] = {'exit': 17}
        self.run_runner()
        self.assertEqual(self.completed.returncode, 1)
        self.assertEqual(self.stage('unit')['exit_code'], 17)
        self.assertEqual(self.stage('unit')['status'], 'failed')
        self.assertEqual(self.stage('stress')['status'], 'passed')
        self.assertEqual(sum('build-for-testing' in c['args'] for c in self.calls), 1)
        stage_calls = [c for c in self.calls if 'test-without-building' in c['args']]
        self.assertEqual(len(stage_calls), 6)
        self.assertEqual(len({c['args'][c['args'].index('-resultBundlePath') + 1] for c in stage_calls}), 6)
        self.assertTrue(all(s['elapsed_s'] >= 0 for s in self.result['stages']))

    def test_zero_and_below_floor_fail(self):
        self.config.update(unit={'passed': 0}, regression={'passed': 1})
        self.run_runner()
        for stage in ('unit', 'regression'):
            self.assertEqual(self.stage(stage)['status'], 'failed')
            self.assertIn('below expected floor', self.stage(stage)['reason'])
        self.assertEqual(self.stage('integration')['status'], 'passed')

    def test_unassigned_test_fails_before_build(self):
        self.manifest['assignments'] = self.assignments[1:]
        self.run_runner()
        self.assertEqual(self.completed.returncode, 1)
        self.assertEqual(self.calls, [])
        self.assertTrue(any('unassigned' in e for e in self.result['inventory_errors']))

    def test_ui_not_run_cannot_be_reported_as_pass(self):
        self.run_runner()
        self.assertEqual(self.result['status'], 'incomplete')
        self.assertEqual(self.stage('ui')['status'], 'not_run')
        self.assertEqual(self.stage('ui')['reason'], 'phase 2')
        self.assertNotEqual(self.completed.returncode, 0)
        self.assertIn('UI not run (phase 2)', self.completed.stdout)
        self.assertNotIn('GAUNTLET PASSED', self.completed.stdout)
        self.assertEqual(len(self.completed.stdout.splitlines()), 1)

    def test_dry_run_prints_plan_without_building_or_writing_results(self):
        self.run_runner('--dry-run')
        self.assertEqual(self.completed.returncode, 0, self.completed.stdout + self.completed.stderr)
        self.assertEqual(self.calls, [])
        self.assertIsNone(self.result)
        self.assertIn('Build: ONE xcodebuild build-for-testing', self.completed.stdout)
        self.assertIn('UI not run (phase 2)', self.completed.stdout)

    def test_symlink_results_root_refused_before_build(self):
        target = self.root / 'outside'
        target.mkdir()
        link = self.root / 'escape'
        link.symlink_to(target, target_is_directory=True)
        self.run_runner(results=link / 'runs')
        self.assertNotEqual(self.completed.returncode, 0)
        self.assertEqual(self.calls, [])
        self.assertEqual(list(target.iterdir()), [])
        self.assertRegex(self.completed.stderr, 'symlink|write allowlist refused')

    def test_poisoned_home_and_roots_replaced_in_child_and_xctestrun(self):
        cache_keys = ['CLANG_MODULE_CACHE_PATH', 'SWIFT_MODULECACHE_PATH',
                      'SWIFTPM_MODULECACHE_OVERRIDE', 'XDG_CACHE_HOME']
        self.run_runner('--only', 'unit', environment={
            'HOME': '/private/tmp/poison-home', 'CFFIXED_USER_HOME': '/private/tmp/poison-home',
            'VS_GAUNTLET_CATALOG_ROOT': '/private/tmp/poison-catalog', 'VS_UI_TEST': '0',
            **{key: '/private/tmp/poison-cache' for key in cache_keys}})
        self.assertEqual(self.stage('unit')['status'], 'passed')
        for call in self.calls:
            self.assertEqual(call['env']['VS_UI_TEST'], '1')
            self.assertTrue(call['env']['HOME'].startswith(str(self.root / 'results')))
            self.assertEqual(call['env']['VS_GAUNTLET_CATALOG_ROOT'], self.result['roots']['catalog'])
            for key in cache_keys:
                self.assertEqual(call['env'][key], self.result['roots']['caches'])
        import plistlib
        path = next((self.root / 'results').glob('*/DerivedData/Build/Products/*.xctestrun'))
        env = plistlib.loads(path.read_bytes())['Test']['EnvironmentVariables']
        self.assertEqual(env['HOME'], self.result['roots']['home'])
        self.assertEqual(env['VS_UI_TEST'], '1')

    def test_missing_structured_counts_and_skips_fail(self):
        self.config.update(unit={'malformed': True}, regression={'skipped': 1})
        self.run_runner()
        self.assertEqual(self.stage('unit')['status'], 'failed')
        self.assertIn('counts unavailable', self.stage('unit')['reason'])
        self.assertEqual(self.stage('regression')['status'], 'failed')
        self.assertIn('skipped', self.stage('regression')['reason'])

    def test_build_failure_blocks_stages_and_records_code(self):
        self.config['build_exit'] = 23
        self.run_runner()
        self.assertEqual(self.result['build_exit_code'], 23)
        self.assertEqual(self.stage('unit')['status'], 'blocked')
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.result['status'], 'failed')


    def test_exited_leader_with_live_descendant_blocks_next_stage(self):
        self.config['unit'] = {'descendant': True}
        try:
            self.run_runner()
            self.assertEqual(self.stage('unit')['status'], 'failed')
            self.assertEqual(self.stage('unit')['exit_code'], 125)
            self.assertIn('contamination', self.stage('unit')['reason'])
            self.assertEqual(self.stage('regression')['status'], 'blocked')
        finally:
            child_file = self.root / 'calls.jsonl.child'
            if child_file.exists():
                try:
                    os.kill(int(child_file.read_text()), 9)
                except ProcessLookupError:
                    pass

    def test_timeout_preserves_124_and_cannot_pass(self):
        self.config['unit'] = {'sleep': 5}
        self.manifest['stages'][0]['timeout_s'] = 1
        self.run_runner('--only', 'unit')
        self.assertEqual(self.stage('unit')['exit_code'], 124)
        self.assertEqual(self.stage('unit')['status'], 'failed')
        self.assertEqual(self.result['status'], 'failed')

    def test_omitted_blocked_assignment_projection_fails_preflight(self):
        self.manifest['assignments'] = json.loads(json.dumps(self.assignments))
        self.manifest['assignments'][0]['blocked_reason'] = 'fixture adapter pending'
        self.manifest['stages'][0]['selectors'] = []
        self.run_runner()
        self.assertEqual(self.completed.returncode, 1)
        self.assertEqual(self.calls, [])
        self.assertTrue(any('blocked' in e for e in self.result['inventory_errors']))


if __name__ == '__main__':
    unittest.main()
