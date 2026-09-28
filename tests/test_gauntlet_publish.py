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
        self.assertEqual(row['status'], 'incomplete')
        self.assertEqual(row['ui_label'], 'UI not run (phase 2)')
        self.assertEqual(row['stages'][1]['status'], 'not_run')
        self.assertEqual(row['stages'][1]['reason'], 'phase 2')
        self.assertFalse((self.root / 'pending-metrics.jsonl').exists())

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
const predicate = html.match(/const isTestRunRow = .*;/)[0];
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
        duration = output['charts']['chart-gauntlet-duration']['data']['datasets']
        self.assertEqual(next(d for d in duration if d['label'] == 'unit')['data'], [12])
        self.assertEqual(next(d for d in duration if d['label'] == 'ui')['data'], [None])
        self.assertEqual(next(d for d in duration if 'total' in d['label'])['data'], [30])
        outcomes = output['charts']['chart-gauntlet-outcome']['data']['datasets']
        self.assertEqual(next(d for d in outcomes if d['label'] == 'passed stages')['data'], [0])
        self.assertEqual(next(d for d in outcomes if 'not run' in d['label'])['data'], [2])


if __name__ == '__main__':
    unittest.main()
