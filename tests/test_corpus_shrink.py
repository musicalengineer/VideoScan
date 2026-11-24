"""scripts/corpus_shrink.py — the copies the sample dropped: planned (read only), deleted only after green.

DECISIONS 2026-11-24: "Shrinking the copy deletes a dropped file only after a run on the new sample is
green; originals are never touched." A fake M4 home in a temporary folder (corpus_run.Seal over it, as
tests/test_corpus_run.py builds one), fake media files of the planned sizes, a stored check run written
the way corpus_run stores one. The external root is a plain folder handed to the seal as proven (the
proof itself — a real volume, its UUID, its marker — is tests/test_corpus_run.py's TwoRoot tests).
No real path, no real media, no ssh.
"""
import hashlib
import json
import os
import pathlib
import stat
import sys
import tempfile
import time
import types
import unittest
from contextlib import redirect_stdout
from io import StringIO

REPO = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'scripts'))
import corpus_run as cr  # noqa: E402
import corpus_select as cs  # noqa: E402
import corpus_shrink as sh  # noqa: E402

COMMIT = 'c' * 40
STAMP = '20261125_010000'


def sha(n):
    return hashlib.sha256(f'content-{n}'.encode()).hexdigest()


def manifest_row(n, root, size=None, path=None):
    return dict(sha256=sha(n), path=path or f'/Volumes/Drive{n % 2}/folder {n}/clip {n}.mov', size=size or 100 + n,
                why='sample', root=root)


class Shrink:
    """~/corpus with the marker, the CURRENT copies on disk (internal under ~/corpus/media, external under
    <X10>/corpus/media), the sample manifest installed, and a GREEN check run over it."""

    # (n, root, in the sample)
    ROWS = [(1, 'internal', True), (2, 'internal', False), (3, 'internal', False),
            (4, 'external', True), (5, 'external', False), (6, 'external', False)]

    def __init__(self, tmp):
        self.tmp = pathlib.Path(tmp)
        self.home = self.tmp / 'home'
        self.corpus = self.home / 'corpus'
        self.corpus.mkdir(parents=True)
        (self.corpus / cr.MARKER).write_text('test data\n')
        self.mount = self.tmp / 'X10'
        (self.mount / 'corpus' / 'media').mkdir(parents=True)
        self.seal = cr.Seal(self.home, 'ricksm4')
        self.seal._external = cr.External('ok', self.mount, '01B908EE-B91C-428F-879D-3D5EEAA3E0DE')
        self.current = [manifest_row(n, root) for n, root, _ in self.ROWS]
        self.sample = [manifest_row(n, root) for n, root, keep in self.ROWS if keep]
        self.sample.append(manifest_row(9, 'ro', size=10 ** 12))
        for r in self.current:
            self.put(r)
        self.install(self.sample)
        self.out = self.tmp / 'plan'

    def media(self, root):
        return self.corpus / 'media' if root == 'internal' else self.mount / 'corpus' / 'media'

    def place(self, r):
        return self.media(r['root']) / r['path'].lstrip('/')

    def put(self, r, size=None):
        path = self.place(r)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'x' * (size if size is not None else r['size']))
        return path

    def install(self, rows):
        (self.corpus / cr.MANIFEST_V2).write_text(json.dumps(rows))
        self.sample_sha = hashlib.sha256((self.corpus / cr.MANIFEST_V2).read_bytes()).hexdigest()

    def make_plan(self):
        the_plan, counts = sh.plan(self.seal, self.current, self.sample)
        the_plan['sample_sha256'] = self.sample_sha
        self.out.mkdir(exist_ok=True)
        (self.out / sh.PLAN).write_text(json.dumps(the_plan))
        return the_plan, counts

    def store_run(self, stamp=STAMP, **override):
        """A check run as corpus_run stores it: GREEN, every sample file present, over the installed manifest."""
        report = {'lane': 'check', 'sha': COMMIT, 'stamp': stamp, 'engine_present': True, 'files': 2, 'bytes': 205,
                  'media_seconds': 1.0, 'wall_s': 1.0, 'build_s': 0, 'launches': 1, 'jobs': 1, 'limit': None,
                  'not_run_external': 0, 'not_run_ro': 0, 'manifest_sha256': self.sample_sha, 'smoke': False,
                  'problem_count': 0, 'launches_cut_short': 0,
                  'inventory': {'internal': {'present': 1}, 'external': {'present': 1}},
                  'engines': {'probe': {'OK': 2}}, 'failures': {}, 'against': None}
        report.update(override)
        run = self.corpus / 'reports' / 'check' / COMMIT / stamp
        run.mkdir(parents=True, exist_ok=True)
        (run / 'report.json').write_text(json.dumps(report))
        (run / 'outcomes.json').write_text('{}')
        return run

    def tree(self):
        """Every regular file under both media folders and the folder of originals, with its bytes."""
        out = {}
        for base in (self.corpus / 'media', self.mount / 'corpus' / 'media', self.tmp / 'originals'):
            for folder, _, names in os.walk(str(base)):
                for name in names:
                    p = os.path.join(folder, name)
                    if not os.path.islink(p):
                        out[p] = pathlib.Path(p).read_bytes()
        return out

    def apply(self, stamp=STAMP):
        return sh.apply(self.seal, self.out / sh.PLAN, stamp)


class ShrinkCase(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.s = Shrink(self.tmp.name)

    def tearDown(self):
        for folder, dirs, names in os.walk(self.tmp.name):          # a test may leave a locked file
            for name in names:
                p = os.path.join(folder, name)
                if not os.path.islink(p) and getattr(os.lstat(p), 'st_flags', 0):
                    os.chflags(p, 0)
        self.tmp.cleanup()

    def dropped(self):
        return [r for r in self.s.current if r['sha256'] not in {x['sha256'] for x in self.s.sample}]


class PlanTests(ShrinkCase):

    def test_the_plan_lists_the_present_copies_the_sample_dropped_with_their_bytes_and_deletes_nothing(self):
        before = self.s.tree()
        the_plan, counts = self.s.make_plan()
        self.assertEqual(sorted((f['sha256'], f['root']) for f in the_plan['files']),
                         sorted((r['sha256'], r['root']) for r in self.dropped()))
        self.assertEqual({root: (c['files'], c['bytes']) for root, c in counts.items()},
                         {'internal': (2, 102 + 103), 'external': (2, 105 + 106)})
        self.assertEqual(self.s.tree(), before, 'plan-shrink deleted or changed something')

    def test_a_dropped_row_with_no_copy_or_a_copy_of_another_size_is_counted_not_listed(self):
        gone = self.dropped()[0]
        os.unlink(self.s.place(gone))
        partial = self.dropped()[2]
        self.s.put(partial, size=1)                                  # an rsync that never finished
        the_plan, counts = self.s.make_plan()
        self.assertNotIn(gone['sha256'], [f['sha256'] for f in the_plan['files']])
        self.assertNotIn(partial['sha256'], [f['sha256'] for f in the_plan['files']])
        self.assertEqual((counts['internal']['no_copy'], counts['external']['no_copy']), (1, 1))

    def test_a_place_the_sample_still_names_is_never_planned_even_under_another_digest(self):
        dropped = self.dropped()[0]
        self.s.sample.append(dict(dropped, sha256=sha(77)))           # same original path, new content
        the_plan, _ = self.s.make_plan()
        self.assertNotIn(dropped['sha256'], [f['sha256'] for f in the_plan['files']])

    def test_a_digest_the_sample_moved_to_another_root_leaves_its_old_copy_planned(self):
        moved = self.dropped()[0]                                     # internal in current
        self.s.sample.append(dict(moved, root='external', path=moved['path'] + ' moved'))
        the_plan, _ = self.s.make_plan()
        self.assertIn((moved['sha256'], 'internal'), [(f['sha256'], f['root']) for f in the_plan['files']])

    def test_with_the_external_volume_away_its_rows_are_counted_not_looked_at(self):
        self.s.seal._external = cr.External('absent', self.s.mount)
        the_plan, counts = self.s.make_plan()
        self.assertEqual({f['root'] for f in the_plan['files']}, {'internal'})
        self.assertEqual(counts['external']['not_mounted'], 2)

    def test_the_command_line_prints_counts_only_and_never_writes_into_the_repository(self):
        secret = manifest_row(2, 'internal', path='/Volumes/Secret Drive/Grandma/birthday.mov')
        self.s.current.append(dict(secret, sha256=sha(55)))
        self.s.put(dict(secret, sha256=sha(55)))
        current = self.s.tmp / 'current.json'
        current.write_text(json.dumps(self.s.current))
        sample = self.s.corpus / cr.MANIFEST_V2
        args = types.SimpleNamespace(command='plan-shrink', sample=str(sample), current=str(current), out=str(self.s.out))
        buf = StringIO()
        with redirect_stdout(buf):
            self.assertEqual(sh.main(args, seal=self.s.seal), 0)
        text = buf.getvalue()
        self.assertIn('corpus plan-shrink: internal 3 present copies no longer in the sample', text)
        self.assertIn('nothing deleted', text)
        for word in ('Secret', 'Grandma', 'birthday', 'Volumes'):
            self.assertNotIn(word, text)
        self.assertEqual(json.loads((self.s.out / sh.PLAN).read_text())['sample_sha256'], self.s.sample_sha)
        for out in (REPO / '.scratch' / 'shrink', self.s.corpus / 'media' / 'plan'):
            args.out = str(out)
            with redirect_stdout(StringIO()):
                self.assertEqual(sh.main(args, seal=self.s.seal), 2)
            self.assertFalse(out.exists())

    def test_plan_shrink_is_refused_on_any_host_but_the_m4(self):
        seal = cr.Seal(self.s.home, 'ricksultra')
        args = types.SimpleNamespace(command='plan-shrink', sample=str(self.s.corpus / cr.MANIFEST_V2), current=None,
                                     out=str(self.s.out))
        with redirect_stdout(StringIO()):
            self.assertEqual(sh.main(args, seal=seal), 2)

    def test_the_select_command_line_hands_both_steps_to_corpus_shrink(self):
        calls = []
        real = sh.main
        sh.main = lambda args, seal=None: calls.append(args.command) or 0
        try:
            self.assertEqual(cs.main(['plan-shrink', '--sample', 'x', '--out', 'y']), 0)
            self.assertEqual(cs.main(['apply-shrink', '--plan', 'x', '--after-green', STAMP]), 0)
        finally:
            sh.main = real
        self.assertEqual(calls, ['plan-shrink', 'apply-shrink'])


class ApplyRefusalTests(ShrinkCase):
    """Each condition alone refuses the whole step, and nothing is deleted."""

    def setUp(self):
        super().setUp()
        self.s.make_plan()
        self.before = self.s.tree()

    def refused(self, because, stamp=STAMP):
        with self.assertRaises(cr.Refused) as caught:
            self.s.apply(stamp)
        self.assertIn(because, str(caught.exception))
        self.assertEqual(self.s.tree(), self.before, 'a refused shrink deleted something')
        self.assertFalse((self.s.corpus / 'state' / sh.HISTORY).exists())

    def test_no_such_run(self):
        self.s.store_run()
        self.refused('no single stored check run', stamp='20991231_000000')
        self.refused('stamp', stamp='../check')

    def test_an_amber_run(self):
        self.s.store_run(against={'changed': 3, 'compared': 2})
        self.refused('verdict is AMBER')

    def test_a_red_run(self):
        self.s.store_run(failures={'probe:crash': 1})
        self.refused('verdict is RED')

    def test_a_run_with_the_external_volume_or_the_ro_share_not_mounted(self):
        self.s.store_run(not_run_external=4)
        self.refused('verdict is AMBER')
        self.s.store_run(not_run_ro=1)
        self.refused('verdict is AMBER')

    def test_a_smoke_or_limited_run(self):
        self.s.store_run(smoke=True)
        self.refused('SMOKE or --limit')
        self.s.store_run(limit=5)
        self.refused('SMOKE or --limit')

    def test_a_run_over_another_manifest_or_one_that_predates_the_record(self):
        self.s.store_run(manifest_sha256='0' * 64)
        self.refused('did not run the installed sample')
        self.s.store_run(manifest_sha256=None)
        self.refused('did not run the installed sample')

    def test_a_run_with_sample_files_missing(self):
        self.s.store_run(inventory={'internal': {'present': 1}, 'external': {'present': 1, 'missing': 1}})
        self.refused('not every sample file was present')

    def test_a_run_that_says_nothing_of_what_was_present(self):
        self.s.store_run(inventory={})
        self.refused('says nothing')

    def test_an_installed_manifest_that_is_not_the_plans_sample(self):
        self.s.store_run()
        self.s.install(self.s.current)                                # the old manifest put back
        self.refused('not the sample this plan was made for')

    def test_a_plan_that_is_not_one(self):
        self.s.store_run()
        (self.s.out / sh.PLAN).write_text('{"files": "everything"}')
        self.refused('cannot be read back')

    def test_any_host_but_the_m4(self):
        self.s.store_run()
        self.s.seal.hostname = 'ricksultra'
        self.refused('M5 Ultra')

    def test_red_first_the_green_check_reads_the_runs_own_manifest_record(self):
        # corpus_run's report carries manifest_sha256 only from this change on: a stored report cleaned by
        # clean_report must keep it, or no run could ever prove what it ran.
        cleaned = cr.clean_report({'lane': 'check', 'sha': COMMIT, 'manifest_sha256': self.s.sample_sha})
        self.assertEqual(cleaned.get('manifest_sha256'), self.s.sample_sha)
        self.assertIsNone(cr.clean_report({'lane': 'check', 'sha': COMMIT, 'manifest_sha256': '/Volumes/x'})['manifest_sha256'])


class ApplyTests(ShrinkCase):

    def setUp(self):
        super().setUp()
        self.s.make_plan()
        self.s.store_run()

    def kept(self):
        return [self.s.place(r) for r in self.s.current if r['sha256'] in {x['sha256'] for x in self.s.sample}]

    def test_after_a_green_run_exactly_the_planned_copies_go_and_the_sample_stays(self):
        kept = {str(p): p.read_bytes() for p in self.kept()}
        lines, counts = self.s.apply()
        self.assertEqual((counts['internal']['deleted'], counts['external']['deleted']), (2, 2))
        self.assertEqual((counts['internal']['bytes'], counts['external']['bytes']), (205, 211))
        self.assertEqual(self.s.tree(), kept, 'only the sample copies are left, byte for byte')
        for r in self.dropped():
            self.assertFalse(self.s.place(r).parent.exists(), 'the folder the deletion emptied is gone')
        self.assertTrue((self.s.corpus / 'media').is_dir() and (self.s.mount / 'corpus' / 'media').is_dir())
        history = [json.loads(line) for line in (self.s.corpus / 'state' / sh.HISTORY).read_text().splitlines()]
        self.assertEqual(history[-1]['counts']['internal']['deleted'], 2)
        self.assertEqual(history[-1]['after_green'], STAMP)
        self.assertNotIn('Volumes', json.dumps(history) + '\n'.join(lines))
        _, again = self.s.apply()                                    # idempotent: the second time, nothing there
        self.assertEqual((again['internal']['deleted'], again['internal']['absent']), (0, 2))

    def test_a_file_the_installed_sample_names_is_never_deleted_whatever_the_plan_says(self):
        plan = json.loads((self.s.out / sh.PLAN).read_text())
        keep = next(r for r in self.s.sample if r['root'] == 'internal')
        plan['files'].append({'sha256': keep['sha256'], 'root': 'internal', 'place': keep['path'].lstrip('/'), 'size': keep['size']})
        (self.s.out / sh.PLAN).write_text(json.dumps(plan))
        _, counts = self.s.apply()
        self.assertTrue(self.s.place(keep).is_file())
        self.assertEqual(counts['internal']['kept_in_sample'], 1)

    def edit_plan(self, entry):
        plan = json.loads((self.s.out / sh.PLAN).read_text())
        plan['files'] = [entry]
        (self.s.out / sh.PLAN).write_text(json.dumps(plan))

    def test_a_link_on_the_way_or_at_the_place_is_never_followed(self):
        original = self.s.tmp / 'originals' / 'Volumes' / 'Drive0' / 'folder 2' / 'clip 2.mov'
        original.parent.mkdir(parents=True)
        original.write_bytes(b'o' * 102)
        r = self.dropped()[0]
        folder = self.s.place(r).parent
        os.unlink(self.s.place(r))
        os.rmdir(folder)
        os.symlink(str(original.parent), str(folder))                  # the folder is a link to the original's
        _, counts = self.s.apply()
        self.assertEqual(counts['internal']['refused_link'], 1)
        self.assertEqual(original.read_bytes(), b'o' * 102, 'an original was touched')
        os.unlink(folder)
        folder.mkdir()
        os.symlink(str(original), str(self.s.place(r)))                # the place itself is a link
        self.edit_plan({'sha256': r['sha256'], 'root': 'internal', 'place': r['path'].lstrip('/'), 'size': 102})
        _, counts = self.s.apply()
        self.assertEqual(counts['internal']['refused_link'], 1)
        self.assertTrue(original.is_file() and os.path.islink(self.s.place(r)))

    def test_a_place_that_climbs_out_of_the_media_folder_is_refused(self):
        outside = self.s.corpus / 'THIS_IS_TEST_DATA.txt'
        for place in ('Volumes/../../THIS_IS_TEST_DATA.txt', '/Volumes/x', 'Volumes//x', 'etc/x', ''):
            self.edit_plan({'sha256': sha(2), 'root': 'internal', 'place': place, 'size': outside.stat().st_size})
            _, counts = self.s.apply()
            self.assertEqual(counts['internal']['refused_entry'], 1, place)
        self.assertTrue(outside.is_file())

    def test_a_second_name_a_lock_or_another_size_leaves_the_file(self):
        a, b, c, _ = self.dropped()
        os.link(str(self.s.place(a)), str(self.s.tmp / 'second name'))
        os.chflags(str(self.s.place(b)), stat.UF_IMMUTABLE)
        self.s.put(c, size=c['size'] + 1)                             # replaced after the plan was made
        _, counts = self.s.apply()
        self.assertEqual(counts['internal']['refused_second_name'], 1)
        self.assertEqual(counts['internal']['refused_locked'], 1)
        self.assertEqual(counts['external']['refused_size'], 1)
        for r in (a, b, c):
            self.assertTrue(self.s.place(r).is_file())

    def test_the_ro_root_is_never_deleted_from(self):
        self.edit_plan({'sha256': sha(9), 'root': 'ro', 'place': 'Volumes/Drive1/x.mov', 'size': 1})
        _, counts = self.s.apply()
        self.assertEqual(counts['other']['refused_root'], 1)

    def test_with_the_external_volume_away_its_files_wait_and_the_internal_ones_go(self):
        self.s.seal._external = cr.External('absent', self.s.mount)
        _, counts = self.s.apply()
        self.assertEqual((counts['internal']['deleted'], counts['external']['not_mounted']), (2, 2))
        self.assertTrue(all(self.s.place(r).is_file() for r in self.dropped() if r['root'] == 'external'))

    def test_another_volume_at_the_x10s_mount_refuses_the_whole_step_before_any_deletion(self):
        def wrong_volume():
            raise cr.Refused('refused: the volume mounted at the external root is not the adopted one')
        before = self.s.tree()
        self.s.seal.external = wrong_volume
        with self.assertRaises(cr.Refused):
            self.s.apply()
        self.assertEqual(self.s.tree(), before, 'the internal copies went before the external root was proven')


class ScaleTests(unittest.TestCase):

    def test_a_plan_over_100k_rows_is_made_inside_the_time_budget(self):
        with tempfile.TemporaryDirectory() as tmp:
            s = Shrink(tmp)
            current = [manifest_row(n, ('internal', 'external')[n % 2]) for n in range(1_000, 101_000)]
            sample = current[::8]
            t0 = time.time()
            the_plan, counts = sh.plan(s.seal, current, sample)
            took = time.time() - t0
        self.assertLess(took, 10.0, f'100k rows took {took:.1f}s')
        self.assertEqual(sum(c['no_copy'] for c in counts.values()), 100_000 - 12_500)
        self.assertEqual(the_plan['files'], [])


if __name__ == '__main__':
    unittest.main()
