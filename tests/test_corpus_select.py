"""scripts/corpus_select.py — the v2 corpus choice, rule by rule, on a synthetic catalog.

No real path: every catalog here is built from the catalog's real DDL (catalog_sqlite_fixture)
in a temporary folder, with made-up /Volumes paths; "readable" is a set the test hands in.
"""
import hashlib
import json
import os
import pathlib
import sys
import tempfile
import time
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'scripts'))
sys.path.insert(0, str(REPO / 'tests'))
import corpus_select as cs  # noqa: E402
from catalog_sqlite_fixture import Catalog  # noqa: E402

GB = 1_000_000_000


def sha(n):
    return hashlib.sha256(f'content-{n}'.encode()).hexdigest()


class Scene:
    def __init__(self, tmp):
        self.folder = pathlib.Path(tmp, 'catalog')
        self.folder.mkdir()
        self.db = Catalog(self.folder)

    def add(self, path, n, size, container='mov,mp4', vcodec='h264', acodec='aac', removal=None):
        rid = self.db.add(path, digest=sha(n), size=size, removal=removal)
        self.db.conn.execute("UPDATE files SET container = ?, video_codec = ?, audio_codec = ? WHERE id = ?",
                             (container, vcodec, acodec, rid))
        return rid

    def rows(self):
        return cs.catalog_rows(self.close())

    def close(self):
        """A finished backup: closed, and (as CorpusScene does) without the empty WAL sidecars Apple's
        SQLite keeps after a close (persistent WAL) — a real `.backup` copy has none."""
        path = pathlib.Path(self.db.close())
        for suffix in ('-wal', '-shm'):
            side = pathlib.Path(str(path) + suffix)
            if side.exists():
                assert suffix == '-shm' or side.stat().st_size == 0, 'a WAL with content is not a finished catalog'
                side.unlink()
        return path


class SelectRuleTests(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.s = Scene(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_1_live_rows_only_and_never_a_content_already_in_the_corpus(self):
        self.s.add('/Volumes/A/live.mov', 1, 100)
        self.s.add('/Volumes/A/gone.mov', 2, 100, removal=('removedFromCatalog', 'x'))
        self.s.add('/Volumes/A/in-v1.mov', 3, 100)
        picked = cs.select(self.s.rows(), [sha(3).upper()], can_read=lambda p: True)
        self.assertEqual([p[0] for p in picked['external']], [sha(1)])
        self.assertEqual(picked['internal'], [])

    def test_2_one_readable_path_per_digest_away_from_the_archive_then_the_smallest_path(self):
        self.s.add('/Volumes/FamilyArchive/1990s/a.mov', 1, 100)
        self.s.add('/Volumes/Z/a.mov', 1, 100)
        self.s.add('/Volumes/M/a.mov', 1, 100)
        self.s.add('/Volumes/B/unreadable.mov', 1, 100)
        self.s.add('/Volumes/FamilyArchive/only-here.mov', 2, 100)
        self.s.add('/Volumes/B/nowhere.mov', 3, 100)
        readable = {'/Volumes/FamilyArchive/1990s/a.mov', '/Volumes/Z/a.mov', '/Volumes/M/a.mov',
                    '/Volumes/FamilyArchive/only-here.mov'}
        picked = cs.select(self.s.rows(), [], can_read=readable.__contains__)
        self.assertEqual(sorted(picked['external']),
                         sorted([(sha(1), '/Volumes/M/a.mov', 100), (sha(2), '/Volumes/FamilyArchive/only-here.mov', 100)]))

    def test_3_under_8_gb_is_external_and_8_gb_exactly_is_large(self):
        self.s.add('/Volumes/A/under.mov', 1, cs.SPLIT_BYTES - 1)
        self.s.add('/Volumes/A/at.mov', 2, cs.SPLIT_BYTES)
        picked = cs.select(self.s.rows(), [], can_read=lambda p: True)
        self.assertEqual([p[0] for p in picked['external']], [sha(1)])
        self.assertEqual([p[0] for p in picked['internal']], [sha(2)])

    def test_4_the_smallest_of_each_stratum_smallest_first_until_the_budget(self):
        # The media matrix as strata: each (container, video, audio) mix is its own.
        matrix = [('mov,mp4', 'h264', 'aac'), ('mov,mp4', 'prores', 'pcm_s24le'), ('matroska,webm', 'ffv1', 'pcm_s16le'),
                  ('mxf', 'dnxhd', ''), ('avi', 'dvvideo', 'pcm_s16le')]
        n = 0
        for k, (container, v, a) in enumerate(matrix):
            for extra in (3, 1, 2):                                   # the stratum's smallest is +1
                n += 1
                self.s.add(f'/Volumes/A/{k}-{extra}.mov', n, 40 * GB + k * GB + extra, container, v, a)
        picked = cs.select(self.s.rows(), [], can_read=lambda p: True)
        sizes = [p[2] for p in picked['internal']]
        # One each, the stratum's smallest (+1), smallest stratum first: 40+41+42+43+44 = 210 GB fits 250 GB.
        self.assertEqual(sizes, [(40 + k) * GB + 1 for k in range(5)])
        self.assertEqual(picked['external'], [])

    def test_4_the_budget_stops_at_the_first_file_that_would_pass_it(self):
        for k in range(10):
            self.s.add(f'/Volumes/A/{k}.mov', k, 60 * GB + k, 'mov,mp4', f'codec{k}', 'aac')
        picked = cs.select(self.s.rows(), [], can_read=lambda p: True)
        self.assertEqual(len(picked['internal']), 4)                   # 4 x 60 GB = 240 GB; a fifth passes 250
        self.assertLessEqual(sum(p[2] for p in picked['internal']), cs.INTERNAL_BUDGET)

    def test_4_a_size_tie_in_a_stratum_goes_to_the_digest_seen_first_in_the_catalog(self):
        self.s.add('/Volumes/A/later.mov', 9, 20 * GB)
        self.s.add('/Volumes/A/a-first-by-path.mov', 1, 20 * GB)
        picked = cs.select(self.s.rows(), [], can_read=lambda p: True)
        self.assertEqual([p[0] for p in picked['internal']], [sha(9)])


class OutputTests(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = pathlib.Path(self.tmp.name, 'out')

    def tearDown(self):
        self.tmp.cleanup()

    def test_the_lists_name_each_copy_under_its_roots_media_folder(self):
        picked = {'external': [(sha(1), '/Volumes/A/x y.mov', 5)], 'internal': [(sha(2), '/Volumes/B/big.mxf', 9 * GB)]}
        cs.write_selection(picked, self.out)
        self.assertEqual((self.out / 'v2_external.sha').read_text(), f'{sha(1)}  Volumes/A/x y.mov\n')
        self.assertEqual((self.out / 'v2_internal.files').read_text(), 'Volumes/B/big.mxf\n')
        self.assertEqual(json.loads((self.out / 'selection.json').read_text())['internal'], [[sha(2), '/Volumes/B/big.mxf', 9 * GB]])

    def test_the_manifest_is_v1_then_v2_each_with_its_root_and_never_one_content_twice(self):
        v1 = [dict(sha256=sha(0).upper(), path='/Volumes/A/v1.mov', size=3, why='one-sided sound')]
        sel = {'internal': [[sha(2), '/Volumes/B/big.mxf', 9 * GB]], 'external': [[sha(1), '/Volumes/A/x.mov', 5]]}
        rows = cs.manifest(v1, sel)
        self.assertEqual([(r['sha256'], r['root'], r['why']) for r in rows],
                         [(sha(0), 'internal', 'one-sided sound'), (sha(2), 'internal', cs.WHY_INTERNAL),
                          (sha(1), 'external', cs.WHY_EXTERNAL)])
        with self.assertRaises(cs.Refused):
            cs.manifest(v1, {'external': [[sha(0), '/Volumes/A/again.mov', 3]]})
        with self.assertRaises(cs.Refused):
            cs.manifest([], {'external': [[sha(1), '/Users/someone/x.mov', 3]]})

    def test_nothing_with_a_real_path_is_written_into_the_repository(self):
        with self.assertRaises(cs.Refused):
            cs.write_selection({'external': [], 'internal': []}, REPO / '.scratch' / 'selection')
        self.assertFalse((REPO / '.scratch' / 'selection').exists())
        self.assertEqual(cs.main(['manifest', '--v1', '/nonexistent', '--selection', '/nonexistent',
                                  '--out', str(REPO / 'corpus-manifest-v2.json')]), 2)


class IsolationTests(unittest.TestCase):

    def test_a_catalog_with_a_wal_beside_it_is_refused_and_the_catalog_is_never_written(self):
        with tempfile.TemporaryDirectory() as tmp:
            s = Scene(tmp)
            s.add('/Volumes/A/a.mov', 1, 5)
            path = s.close()
            before = (path.read_bytes(), sorted(os.listdir(path.parent)))
            cs.catalog_rows(path)
            self.assertEqual((path.read_bytes(), sorted(os.listdir(path.parent))), before, 'a read left a mark')
            pathlib.Path(str(path) + '-wal').write_text('')
            with self.assertRaises(cs.Refused):
                cs.catalog_rows(path)

    def test_the_command_line_prints_counts_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            s = Scene(tmp)
            media = pathlib.Path(tmp, 'Volumes', 'Secret Drive')
            media.mkdir(parents=True)
            s.add('/Volumes/Secret Drive/Grandma.mov', 1, 5)
            path = s.close()
            exclude = pathlib.Path(tmp, 'v1.json')
            exclude.write_text('[]')
            from io import StringIO
            from contextlib import redirect_stdout
            said = StringIO()
            with redirect_stdout(said):
                self.assertEqual(cs.main(['select', '--catalog', str(path), '--exclude', str(exclude),
                                          '--out', str(pathlib.Path(tmp, 'out'))]), 0)
            self.assertNotIn('Secret', said.getvalue())
            self.assertNotIn('Grandma', said.getvalue())
            self.assertIn('external 0 files', said.getvalue())          # not readable here: not chosen


class ScaleTests(unittest.TestCase):

    def test_100k_rows_are_chosen_inside_the_budget(self):
        rows = [(i, sha(i % 60_000), f'/Volumes/V{i % 7}/f{i}.mov', (i % 97) * 10_000_000,
                 'mov,mp4', f'c{i % 40}', 'aac') for i in range(100_000)]
        rows += [(100_000 + k, sha(70_000 + k), f'/Volumes/L/{k}.mxf', cs.SPLIT_BYTES + k * GB, 'mxf', f'c{k}', '')
                 for k in range(50)]
        t0 = time.time()
        picked = cs.select(rows, [sha(1)], can_read=lambda p: True)
        took = time.time() - t0
        self.assertLess(took, 5.0, f'100k rows took {took:.1f}s')
        self.assertEqual(len(picked['external']), 59_999)
        self.assertLessEqual(sum(p[2] for p in picked['internal']), cs.INTERNAL_BUDGET)



class GrowTests(unittest.TestCase):
    """DECISIONS 2026-11-19: the manifest is a wish list that grows; nothing ingested is ever removed."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.s = Scene(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_new_digests_are_appended_and_nothing_is_ever_removed(self):
        self.s.add('/Volumes/A/old.mov', 1, 100)
        self.s.add('/Volumes/A/new.mov', 2, 200)
        current = [dict(sha256=sha(1), path='/Volumes/A/old.mov', size=100, why=cs.WHY_EXTERNAL, root='external'),
                   dict(sha256=sha(9), path='/Volumes/Gone/x.mov', size=5, why='one-sided sound', root='internal')]  # gone from the newer catalog
        rows = self.s.rows()
        grown, picked = cs.grow(rows, current, can_read=lambda p: True)
        self.assertEqual(grown[:2], current, 'the current rows are kept as they were, first')
        self.assertEqual([(r['sha256'], r['root']) for r in grown[2:]], [(sha(2), 'external')])
        self.assertEqual(picked['external'], [(sha(2), '/Volumes/A/new.mov', 200)])
        again, picked = cs.grow(rows, grown, can_read=lambda p: True)
        self.assertEqual((again, picked), (grown, {'external': [], 'internal': []}), 'grown twice: nothing new')

    def test_a_stratum_already_in_the_corpus_is_covered_and_the_budget_is_what_is_left(self):
        self.s.add('/Volumes/A/big-old.mxf', 1, 200 * GB, 'mxf', 'dnxhd', '')
        self.s.add('/Volumes/A/big-same-mix.mxf', 2, 100 * GB, 'mxf', 'dnxhd', '')
        self.s.add('/Volumes/A/big-new-mix.mov', 3, 40 * GB, 'mov,mp4', 'prores', 'pcm_s24le')
        self.s.add('/Volumes/A/big-too-much.mkv', 4, 60 * GB, 'matroska', 'ffv1', 'flac')
        current = [dict(sha256=sha(1), path='/Volumes/A/big-old.mxf', size=200 * GB, why=cs.WHY_INTERNAL, root='internal')]
        _, picked = cs.grow(self.s.rows(), current, can_read=lambda p: True)
        self.assertEqual([p[0] for p in picked['internal']], [sha(3)], 'covered mix skipped; 60 GB would pass the 50 GB left')

    def test_the_command_line_writes_the_whole_manifest_and_only_the_new_copy_lists(self):
        self.s.add('/Volumes/A/old.mov', 1, 100)
        path = self.s.db.close()
        for side in ('-wal', '-shm'):
            if os.path.exists(str(path) + side):
                os.unlink(str(path) + side)
        manifest = pathlib.Path(self.tmp.name, 'm.json')
        manifest.write_text(json.dumps([dict(sha256=sha(5), path='/Volumes/A/kept.mov', size=1, why='x', root='internal')]))
        out = pathlib.Path(self.tmp.name, 'out')
        self.assertEqual(cs.main(['grow', '--catalog', str(path), '--manifest', str(manifest), '--out', str(out)]), 0)
        grown = json.loads((out / 'corpus-manifest-v2.json').read_text())
        self.assertEqual(grown[0]['sha256'], sha(5))
        self.assertEqual((out / 'v2_external.sha').read_text(), '', 'not readable here: nothing new to copy')



class GrowWriteTests(unittest.TestCase):

    def test_f1_a_grow_that_fails_while_writing_leaves_the_manifest_as_it_was(self):
        # Codex #336 F1: --manifest and --out may name the same file; a failed write must not cost its rows.
        with tempfile.TemporaryDirectory() as tmp:
            s = Scene(tmp)
            s.add('/Volumes/A/old.mov', 1, 100)
            path = s.db.close()
            for side in ('-wal', '-shm'):
                if os.path.exists(str(path) + side):
                    os.unlink(str(path) + side)
            out = pathlib.Path(tmp, 'out')
            out.mkdir()
            manifest = out / 'corpus-manifest-v2.json'
            original = json.dumps([dict(sha256=sha(5), path='/Volumes/A/kept.mov', size=1, why='x', root='internal')])
            manifest.write_text(original)
            real = pathlib.Path.write_text

            def failing(self, *args, **kwargs):
                if self == manifest:
                    real(self, '')                                        # opened and truncated, then the disk is full
                    raise OSError(28, 'No space left on device')
                return real(self, *args, **kwargs)
            pathlib.Path.write_text = failing
            try:
                code = cs.main(['grow', '--catalog', str(path), '--manifest', str(manifest), '--out', str(out)])
            except OSError:
                code = 1
            finally:
                pathlib.Path.write_text = real
            self.assertEqual(json.loads(manifest.read_text()), json.loads(original), 'the manifest lost rows')
            self.assertEqual(code, 0, 'the write goes to a new file, renamed into place: the failing truncation never happens')


if __name__ == '__main__':
    unittest.main()
