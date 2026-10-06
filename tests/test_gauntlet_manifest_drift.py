"""scripts/gauntlet/manifest_drift.py — the commit-time / CI-preflight check that
a NEW test file has a gauntlet stage.

2026-10-06: the away-window gauntlet exited BLOCKED in 3 s because 103 test
files added since 10/2 had no manifest assignment, and nothing had said so when
they were committed. These tests pin the check's file rules (which must match
inventory.swift's discovery) and both modes.
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = REPO / 'scripts/gauntlet/manifest_drift.py'
INVENTORY = REPO / 'scripts/gauntlet/inventory.swift'
sys.path.insert(0, str(SCRIPT.parent))
import manifest_drift as md  # noqa: E402

SWIFT_TESTING = 'import Testing\n@Suite struct NewThingTests {\n    @Test func works() {}\n}\n'
XCTEST = 'import XCTest\nfinal class OldThingTests: XCTestCase {\n    func testWorks() {}\n}\n'
HELPER = 'import Foundation\nenum FixtureBuilder { static func make() -> Int { 1 } }\n'
COMMENTED = 'import Testing\nstruct Gone {\n    // @Test func was() {}\n    // func testWas() {}\n}\n'


def write(root, rel, text):
    path = pathlib.Path(root, rel)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8')


def manifest(paths):
    return json.dumps({'assignments': [{'path': p, 'stage': 'unit'} for p in paths]})


class FileRuleTests(unittest.TestCase):
    """The candidate rules — a miss here is a test file the check never sees."""

    def test_swift_testing_and_xctest_files_under_tests_are_test_files(self):
        self.assertTrue(md.is_test_file('VideoScan/VideoScanTests/A.swift', SWIFT_TESTING))
        self.assertTrue(md.is_test_file('VideoScan/VideoScanTests/B.swift', XCTEST))
        self.assertTrue(md.is_test_file('VideoScan/VideoScanUITests/Gauntlet/C.swift', XCTEST))

    def test_helpers_commented_tests_and_non_test_paths_are_not(self):
        self.assertFalse(md.is_test_file('VideoScan/VideoScanTests/Helper.swift', HELPER))
        self.assertFalse(md.is_test_file('VideoScan/VideoScanTests/Gone.swift', COMMENTED))
        self.assertFalse(md.is_test_file('VideoScan/VideoScan/Model/Thing.swift', XCTEST))

    def test_python_and_shell_by_name(self):
        self.assertTrue(md.is_test_file('tests/test_new_tool.py', ''))
        self.assertTrue(md.is_test_file('scripts/smoke_test.sh', ''))
        self.assertFalse(md.is_test_file('tests/conftest.py', ''))
        self.assertFalse(md.is_test_file('scripts/tool.py', ''))

    def test_skipped_folders_mirror_inventory(self):
        for rel in ['tests/fixtures/test_x.py', 'venv/lib/test_y.py', 'venv-mlx/lib/test_z.py',
                    '.claude/worktrees/w/tests/test_a.py', 'build/Tests/A.swift', '.trash/test_b.py']:
            self.assertFalse(md.is_test_file(rel, SWIFT_TESTING), rel)


class AllModeTests(unittest.TestCase):

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix='drift-all-')
        self.addCleanup(shutil.rmtree, self.root)
        write(self.root, 'VideoScan/VideoScanTests/AssignedTests.swift', SWIFT_TESTING)
        write(self.root, 'VideoScan/VideoScanTests/NewTests.swift', XCTEST)
        write(self.root, 'VideoScan/VideoScanTests/Helper.swift', HELPER)
        write(self.root, 'tests/test_new_tool.py', 'def test_a():\n    pass\n')
        write(self.root, 'tests/fixtures/test_fixture.py', 'def test_a():\n    pass\n')
        write(self.root, 'venv-mlx/lib/test_torch.py', 'def test_a():\n    pass\n')
        write(self.root, md.MANIFEST, manifest(['VideoScan/VideoScanTests/AssignedTests.swift']))

    def test_reports_exactly_the_unassigned_test_files(self):
        misses = md.unassigned(md.walk_tree(self.root),
                               md.assigned_paths(pathlib.Path(self.root, md.MANIFEST).read_text()))
        self.assertEqual(misses, ['VideoScan/VideoScanTests/NewTests.swift', 'tests/test_new_tool.py'])

    def test_exit_status_and_one_line_message_with_the_fix(self):
        run = subprocess.run([sys.executable, str(SCRIPT), '--all', '--root', self.root],
                             capture_output=True, text=True)
        self.assertEqual(run.returncode, 1)
        lines = run.stderr.strip().splitlines()
        self.assertEqual(len(lines), 2)
        self.assertIn('VideoScan/VideoScanTests/NewTests.swift', lines[0])
        self.assertIn('scripts/gauntlet/manifest.json', lines[0])
        self.assertIn('inventory.swift --validate', lines[0])

    def test_passes_once_assigned(self):
        write(self.root, md.MANIFEST, manifest(['VideoScan/VideoScanTests/AssignedTests.swift',
                                                'VideoScan/VideoScanTests/NewTests.swift',
                                                'tests/test_new_tool.py']))
        self.assertEqual(md.main(['--all', '--root', self.root]), 0)

    def test_missing_manifest_fails_closed(self):
        os.remove(pathlib.Path(self.root, md.MANIFEST))
        self.assertEqual(md.main(['--all', '--root', self.root]), 1)

    @unittest.skipUnless(shutil.which('swift') and INVENTORY.exists(), 'needs swift for the parity check')
    def test_same_file_set_as_inventory_swift(self):
        out = subprocess.run(['swift', str(INVENTORY), '--discover', self.root],
                             capture_output=True, text=True, timeout=300)
        self.assertEqual(out.returncode, 0, out.stderr)
        swift = sorted(e['path'] for e in json.loads(out.stdout))
        python = sorted(p for p, text in md.walk_tree(self.root) if md.is_test_file(p, text))
        self.assertEqual(python, swift)


@unittest.skipUnless(shutil.which('git'), 'needs git')
class StagedModeTests(unittest.TestCase):

    def git(self, *args):
        subprocess.run(['git', '-C', self.root, *args], check=True, capture_output=True)

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix='drift-staged-')
        self.addCleanup(shutil.rmtree, self.root)
        self.git('init', '-q')
        self.git('config', 'user.email', 'test@example.invalid')
        self.git('config', 'user.name', 'Test')
        write(self.root, 'VideoScan/VideoScanTests/ExistingTests.swift', SWIFT_TESTING)
        write(self.root, md.MANIFEST, manifest(['VideoScan/VideoScanTests/ExistingTests.swift']))
        self.git('add', '-A')
        self.git('commit', '-qm', 'base')

    def test_new_unassigned_test_file_blocks(self):
        write(self.root, 'VideoScan/VideoScanTests/NewTests.swift', XCTEST)
        self.git('add', 'VideoScan/VideoScanTests/NewTests.swift')
        self.assertEqual(md.main(['--staged', '--root', self.root]), 1)

    def test_assignment_must_be_staged_too(self):
        write(self.root, 'VideoScan/VideoScanTests/NewTests.swift', XCTEST)
        self.git('add', 'VideoScan/VideoScanTests/NewTests.swift')
        write(self.root, md.MANIFEST, manifest(['VideoScan/VideoScanTests/ExistingTests.swift',
                                                'VideoScan/VideoScanTests/NewTests.swift']))
        # Working-tree manifest has it, the commit would not: still blocked.
        self.assertEqual(md.main(['--staged', '--root', self.root]), 1)
        self.git('add', md.MANIFEST)
        self.assertEqual(md.main(['--staged', '--root', self.root]), 0)

    def test_edits_helpers_and_unrelated_files_pass(self):
        write(self.root, 'VideoScan/VideoScanTests/ExistingTests.swift', SWIFT_TESTING + '// more\n')
        write(self.root, 'VideoScan/VideoScanTests/Helper.swift', HELPER)
        write(self.root, 'docs/notes.md', 'x\n')
        self.git('add', '-A')
        self.assertEqual(md.main(['--staged', '--root', self.root]), 0)


if __name__ == '__main__':
    unittest.main()
