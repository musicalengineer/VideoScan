"""Scratch-only publication tests: no origin, no network, no real metrics writes."""
import json
import sys
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == "darwin", "macOS-only: builds with /usr/bin/swift and Xcode; the Python CI runner is Linux")
class GauntletPublishTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory(prefix='gauntlet-publish-', dir='/private/tmp')
        cls.repo = Path(cls.workspace.name)
        scripts = cls.repo / 'scripts/gauntlet'
        scripts.mkdir(parents=True)
        source = scripts / 'publish.swift'
        shutil.copy2(REPO / 'scripts/gauntlet/publish.swift', source)
        cls.binary = cls.repo / 'publisher'
        subprocess.run(['/usr/bin/swiftc', '-module-cache-path', str(cls.repo / 'swift-cache'),
                        str(source), '-o', str(cls.binary)], capture_output=True, check=True)
        # An initialized repository with no remote proves failure retention without network access.
        subprocess.run(['/usr/bin/git', 'init', str(cls.repo)], capture_output=True, check=True)

    @classmethod
    def tearDownClass(cls):
        cls.workspace.cleanup()

    def setUp(self):
        self.case = tempfile.TemporaryDirectory(prefix='case-', dir=self.repo)
        self.addCleanup(self.case.cleanup)
        self.root = Path(self.case.name)
        self.path = self.root / 'run/result.json'
        self.path.parent.mkdir()
        self.result = dict(run_id='2026-09-27-test', ts='2026-09-27T12:00:00Z', commit='a' * 40,
                           dirty=True, machine='m4', status='passed', elapsed_s=12, build_s=2,
                           roots={'catalog': '/private/SECRET/catalog.json'}, reason='SECRET family name',
                           branch='SECRET-branch', stages=[
                               dict(name='unit', status='passed', passed=2, elapsed_s=3, artifacts=['SECRET.xcresult']),
                               dict(name='ui', status='passed', elapsed_s=0, reason='SECRET')])

    def publish(self, *args):
        self.path.write_text(json.dumps(self.result))
        return subprocess.run([str(self.binary), str(self.path), *args], text=True,
                              capture_output=True, timeout=15)

    def test_dry_run_sanitizes_private_fields_and_forces_honest_ui(self):
        completed = self.publish('--dry-run')
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertNotIn('SECRET', completed.stdout)
        row = json.loads(completed.stdout)
        self.assertEqual(row['source'], 'gauntlet')
        self.assertEqual(row['status'], 'amber')          # ui not run is AMBER, never a pass (Rick 2026-11-05)
        self.assertEqual(row['ui_label'], 'UI not run (phase 2)')
        self.assertEqual(row['stages'][1]['status'], 'not_run')
        self.assertEqual(row['stages'][1]['reason'], 'phase 2')
        self.assertFalse((self.root / 'pending-metrics.jsonl').exists())

    def test_run_status_is_green_amber_red_and_old_rows_still_read(self):
        # Rick 2026-11-05: AMBER = known issues / blocked / not run; RED = a failure.
        for declared, stage, want in [('amber', 'passed', 'amber'), ('failed', 'passed', 'failed'),
                                      ('amber', 'failed', 'failed'), ('incomplete', 'blocked', 'incomplete'),
                                      ('passed', 'amber', 'amber')]:
            self.result.update(status=declared)
            self.result['stages'][0]['status'] = stage
            row = json.loads(self.publish('--dry-run').stdout)
            self.assertEqual(row['status'], want, (declared, stage))
            self.assertEqual(row['stages'][0]['status'], stage)

    def test_queue_only_is_durable_and_sanitized(self):
        completed = self.publish('--queue-only')
        self.assertEqual(completed.returncode, 1)
        queue = self.root / 'pending-metrics.jsonl'
        self.assertTrue(queue.exists())
        self.assertNotIn('SECRET', queue.read_text())
        self.assertEqual(json.loads(queue.read_text())['run_id'], self.result['run_id'])
        self.result['run_id'] = 'next-run'
        self.publish('--queue-only')
        self.assertEqual(len(queue.read_text().splitlines()), 2)

    def test_failed_git_publication_keeps_queue(self):
        completed = self.publish()
        self.assertEqual(completed.returncode, 1)
        self.assertEqual(completed.stdout.strip(), 'queued')
        self.assertEqual(json.loads((self.root / 'pending-metrics.jsonl').read_text())['source'], 'gauntlet')

    def test_invalid_identity_refused_before_queue_write(self):
        self.result['run_id'] = '../../SECRET'
        completed = self.publish('--queue-only')
        self.assertEqual(completed.returncode, 2)
        self.assertFalse((self.root / 'pending-metrics.jsonl').exists())

    def test_symlink_queue_refused_without_touching_target(self):
        target = self.root / 'untouched'
        target.write_text('sentinel')
        (self.root / 'pending-metrics.jsonl').symlink_to(target)
        completed = self.publish('--queue-only')
        self.assertEqual(completed.returncode, 2)
        self.assertEqual(target.read_text(), 'sentinel')

    def test_symlink_lock_refused_without_touching_target(self):
        target = self.root / 'untouched'
        target.write_text('sentinel')
        (self.root / 'pending-metrics.lock').symlink_to(target)
        completed = self.publish('--queue-only')
        self.assertEqual(completed.returncode, 2)
        self.assertEqual(target.read_text(), 'sentinel')
        self.assertFalse((self.root / 'pending-metrics.jsonl').exists())

    def test_a_failed_stage_publishes_why_and_which_tests(self):
        """RED 2026-11-10: "unit: failed" with 0 failed and 2 skipped, and no way to see
        which tests or why. The row now carries the runner's reason and the names."""
        self.result['status'] = 'failed'
        self.result['stages'][0].update(
            status='failed', reason='unexpected skipped tests; package: 5 known issues (withKnownIssue) — tracked, not a pass',
            failed=0, skipped=2, skipped_tests=['VideoScanTests/SoundSuite/needsFixture()', 'VideoScanTests/OtherTests/testB'],
            failed_tests=['VideoScanCoreTests.CatalogSuite/roundTrip()'], incomplete_tests=[], skipped_tests_truncated=0)
        row = json.loads(self.publish('--dry-run').stdout)
        unit = row['stages'][0]
        self.assertEqual(unit['why'], 'unexpected skipped tests; package: 5 known issues (withKnownIssue) — tracked, not a pass')
        self.assertEqual(unit['skipped_tests'], ['VideoScanTests/SoundSuite/needsFixture()', 'VideoScanTests/OtherTests/testB'])
        self.assertEqual(unit['failed_tests'], ['VideoScanCoreTests.CatalogSuite/roundTrip()'])
        self.assertNotIn('incomplete_tests', unit)
        self.assertNotIn('skipped_tests_more', unit)
        self.assertNotIn('why', {k: v for k, v in row['stages'][1].items() if v is not None})   # ui stays "phase 2"

    def test_a_reason_or_name_that_is_not_the_runners_own_shape_is_never_published(self):
        """Privacy: an error description (a path) becomes "other"; a display title or a
        path among the names is counted, never shown; the lists are capped."""
        many = [f'VideoScanTests/Suite/test{i}()' for i in range(25)]
        self.result['stages'][0].update(
            status='failed', reason='Error Domain=NSCocoa "/Users/SECRET/Movies/SECRET.mov"; test failures; package: SECRET thing',
            failed_tests=['SECRET family title with spaces', '/Users/SECRET/x.swift', 'VideoScanTests/Good/test()'],
            skipped_tests=many, skipped_tests_truncated=7)
        completed = self.publish('--dry-run')
        self.assertNotIn('SECRET', completed.stdout)
        unit = json.loads(completed.stdout)['stages'][0]
        self.assertEqual(unit['why'], 'other; test failures; package: other')
        self.assertEqual(unit['failed_tests'], ['VideoScanTests/Good/test()'])
        self.assertEqual(unit['failed_tests_more'], 2)
        self.assertEqual(unit['skipped_tests'], many[:20])
        self.assertEqual(unit['skipped_tests_more'], 5 + 7)

    def test_a_queued_row_keeps_its_names_and_counts_when_published_later(self):
        """The queue holds SANITIZED rows; publishing one later sanitizes it again."""
        self.result['stages'][0].update(status='failed', reason='test failures',
                                        failed_tests=['VideoScanTests/Good/test()', 'not a test id'])
        first = json.loads(self.publish('--dry-run').stdout)
        self.result = first                                   # what the queue would hold
        again = json.loads(self.publish('--dry-run').stdout)
        self.assertEqual(again['stages'][0]['why'], 'test failures')
        self.assertEqual(again['stages'][0]['failed_tests'], ['VideoScanTests/Good/test()'])
        self.assertEqual(again['stages'][0]['failed_tests_more'], 1)

    def test_untrusted_machine_commit_and_negative_times_are_sanitized(self):
        self.result.update(machine='SECRET-host', commit='SECRET-commit', elapsed_s=-1)
        row = json.loads(self.publish('--dry-run').stdout)
        self.assertEqual(row['machine'], 'unknown')
        self.assertNotIn('commit', row)
        self.assertEqual(row['elapsed_s'], 0)


@unittest.skipUnless(sys.platform == "darwin", "macOS-only: builds with /usr/bin/swift and Xcode; the Python CI runner is Linux")
class GauntletDashboardTests(unittest.TestCase):
    def test_dashboard_separates_nightly_and_keeps_blocked_stage_duration(self):
        harness = r"""
const fs = require('fs');
const html = fs.readFileSync(process.argv[1], 'utf8');
const predicate = html.match(/const isTestRunRow = .*;/)[0] + '\n' + html.match(/function gauntletWord.*/)[0];
const start = html.indexOf('  const gauntletRows =');
const end = html.indexOf('  // Dedicated catalog-search', start);
const allTdRows = [{source:'gauntlet', schemaVersion:1, status:'incomplete', machine:'m4',
  ts:'2026-09-27T12:00:00Z', elapsed_s:30, stages:[
    {name:'unit', status:'blocked', elapsed_s:12},
    {name:'ui', status:'not_run', elapsed_s:0}]}];
const elements = new Map();
const document = {getElementById(id) {
  if (!elements.has(id)) elements.set(id, {id, textContent:'', classList:{add(){}}});
  return elements.get(id);
}};
const charts = {};
function Chart(element, value) { charts[element.id] = value; }
const lineStyle = () => ({});
const chartDefaults = {plugins:{}};
const dateLabels = rows => rows.map(r => r.ts);
eval(predicate + '\n' + html.slice(start,end) + '\n' +
  'console.log(JSON.stringify({nightly:isTestRunRow(allTdRows[0]),charts,label:document.getElementById("gauntlet-status").textContent}));');
"""
        completed = subprocess.run(['node', '-e', harness, str(REPO / 'docs/index.html')],
                                   text=True, capture_output=True, check=True, timeout=10)
        output = json.loads(completed.stdout)
        self.assertFalse(output['nightly'])
        self.assertIn('UI not run (phase 2)', output['label'])
        self.assertIn('Latest: incomplete (before AMBER)', output['label'])   # an old row still reads
        duration = output['charts']['chart-gauntlet-duration']['data']['datasets']
        self.assertEqual(next(d for d in duration if d['label'] == 'unit')['data'], [12])
        self.assertEqual(next(d for d in duration if d['label'] == 'ui')['data'], [None])
        self.assertEqual(next(d for d in duration if 'total' in d['label'])['data'], [30])
        outcomes = output['charts']['chart-gauntlet-outcome']['data']['datasets']
        self.assertEqual(next(d for d in outcomes if d['label'] == 'passed stages')['data'], [0])
        self.assertEqual(next(d for d in outcomes if 'not run' in d['label'])['data'], [2])

    def test_dashboard_names_the_run_green_amber_red(self):
        # Rick 2026-11-05: known issues / blocked / ui not run are AMBER, a failure is RED.
        harness = r"""
const html = require('fs').readFileSync(process.argv[1], 'utf8');
eval(html.match(/function gauntletWord.*/)[0]);
console.log(JSON.stringify(['passed', 'amber', 'failed', 'incomplete', undefined].map(gauntletWord)));
"""
        completed = subprocess.run(['node', '-e', harness, str(REPO / 'docs/index.html')],
                                   text=True, capture_output=True, check=True, timeout=10)
        self.assertEqual(json.loads(completed.stdout),
                         ['GREEN', 'AMBER', 'RED', 'incomplete (before AMBER)', 'incomplete'])


if __name__ == '__main__':
    unittest.main()
