"""scripts/corpus_select.py — the corpus as a stratified SAMPLE (DECISIONS 2026-11-24), rule by rule.

No real path: every catalog here is built from the catalog's real DDL (catalog_sqlite_fixture) or a
minimal table in a temporary folder, with made-up /Volumes paths; "readable" is a set the test hands in.
The v2 rule this file pinned until 2026-11-24 (every content under 8 GB, one large file per codec mix,
`grow` never removes) is retired by that ruling; its tests that still hold (one readable /Volumes path,
the archive last, a WAL refused, nothing into the repository, a whole-or-nothing manifest write,
counts-only output) are kept below in the new rule's terms.
"""
import hashlib
import json
import os
import pathlib
import random
import sqlite3
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from io import StringIO

REPO = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'scripts'))
sys.path.insert(0, str(REPO / 'tests'))
import corpus_select as cs  # noqa: E402
from catalog_sqlite_fixture import Catalog  # noqa: E402

GB = 1_000_000_000
H264 = ('mov,mp4,m4a,3gp,3g2,mj2', 'h264', 'aac')
PLAIN = json.dumps({'frameRate': '29.97', 'resolution': '1920x1080', 'isPlayable': 'Yes'})


def sha(n):
    return hashlib.sha256(f'content-{n}'.encode()).hexdigest()


def row(n, size, path=None, mix=H264, stream='Video+Audio', duration=60.0, probe=PLAIN, rowid=None):
    """A catalog row as catalog_evidence returns it."""
    return (rowid if rowid is not None else n, sha(n), path or f'/Volumes/A/{n}.mov', size, *mix, stream, duration, probe)


def mrow(n, size, path=None, why='v2 every content under 8 GB', root='external'):
    return dict(sha256=sha(n), path=path or f'/Volumes/A/{n}.mov', size=size, why=why, root=root)


def everything(p):
    return True


def said(args):
    buf = StringIO()
    with redirect_stdout(buf):
        code = cs.main(args)
    return code, buf.getvalue()


class Scene:
    def __init__(self, tmp):
        self.folder = pathlib.Path(tmp, 'catalog')
        self.folder.mkdir()
        self.db = Catalog(self.folder)

    def add(self, path, n, size, mix=H264, removal=None):
        rid = self.db.add(path, digest=sha(n), size=size, removal=removal)
        self.db.conn.execute("UPDATE files SET container = ?, video_codec = ?, audio_codec = ? WHERE id = ?", (*mix, rid))
        return rid

    def close(self):
        """A finished backup: closed, without the empty WAL sidecars Apple's SQLite keeps after a close."""
        path = pathlib.Path(self.db.close())
        for suffix in ('-wal', '-shm'):
            side = pathlib.Path(str(path) + suffix)
            if side.exists():
                assert suffix == '-shm' or side.stat().st_size == 0, 'a WAL with content is not a finished catalog'
                side.unlink()
        return path


def minimal_catalog(folder, rows):
    """Only the columns the v2 rule read: no stream_type / duration_s / probe_extra, no evidence tables."""
    path = pathlib.Path(folder, 'catalog.sqlite')
    conn = sqlite3.connect(str(path))
    conn.execute('CREATE TABLE files (content_digest TEXT, full_path TEXT, size_bytes INTEGER, container TEXT,'
                 ' video_codec TEXT, audio_codec TEXT, removal_state TEXT)')
    conn.executemany('INSERT INTO files VALUES (?, ?, ?, ?, ?, ?, NULL)', rows)
    conn.commit()
    conn.close()
    return path


class Rule1UniverseTests(unittest.TestCase):

    def test_live_rows_only_one_readable_volumes_path_away_from_the_archive_then_the_smallest(self):
        with tempfile.TemporaryDirectory() as tmp:
            s = Scene(tmp)
            s.add('/Volumes/FamilyArchive/1990s/a.mov', 1, 100)
            s.add('/Volumes/Z/a.mov', 1, 100)
            s.add('/Volumes/M/a.mov', 1, 100)
            s.add('/Volumes/B/unreadable.mov', 1, 100)
            s.add('/Volumes/FamilyArchive/only-here.mov', 2, 100)
            s.add('/Volumes/B/nowhere.mov', 3, 100)
            s.add('/Volumes/A/gone.mov', 4, 100, removal=('removedFromCatalog', 'x'))
            rows = cs.catalog_rows(s.close())
        readable = {'/Volumes/FamilyArchive/1990s/a.mov', '/Volumes/Z/a.mov', '/Volumes/M/a.mov',
                    '/Volumes/FamilyArchive/only-here.mov'}
        stats = {}
        picked = cs.select(rows, [], can_read=readable.__contains__, stats=stats)
        self.assertEqual(sorted((r['sha256'], r['path']) for r in picked),
                         sorted([(sha(1), '/Volumes/M/a.mov'), (sha(2), '/Volumes/FamilyArchive/only-here.mov')]))
        self.assertEqual(stats['unreadable'], 1)

    def test_a_copy_outside_volumes_never_becomes_the_chosen_path(self):
        # Review 2026-11-19 C1: "/Users/..." sorts before "/Volumes/..."
        rows = [row(1, 100, '/Users/someone/Movies/a.mov', rowid=1), row(1, 100, '/Volumes/M/a.mov', rowid=2),
                row(3, 100, '/Users/someone/only-here.mov')]
        picked = cs.select(rows, [], can_read=everything)
        self.assertEqual([r['path'] for r in picked], ['/Volumes/M/a.mov'])

    def test_a_content_the_corpus_holds_keeps_its_manifest_path_and_root_unread(self):
        # Its copy sits at the manifest path's place: another path would read `vanished`. Nothing is read.
        rows = [row(1, 100, '/Volumes/B/other copy.mov', rowid=1)]
        current = [mrow(1, 100, '/Volumes/A/the copied one.mov', root='internal')]
        picked = cs.select(rows, current, can_read=lambda p: False)
        self.assertEqual([(r['path'], r['root']) for r in picked], [('/Volumes/A/the copied one.mov', 'internal')])

    def test_a_row_without_a_size_never_reaches_the_rules_and_is_counted(self):
        stats = {}
        picked = cs.select([row(1, None, '/Volumes/A/a.mov', rowid=1), row(1, 100, '/Volumes/B/a.mov', rowid=2)], [],
                           can_read=everything, stats=stats)
        self.assertEqual([r['path'] for r in picked], ['/Volumes/B/a.mov'])
        self.assertEqual((stats['no_size'], stats['unreadable']), (1, 0))


class Rule2StratumTests(unittest.TestCase):

    def flags(self, **kw):
        args = dict(stream_type='Video+Audio', duration=60.0, probe_extra=PLAIN)
        args.update(kw)
        return cs.flags_of(**args)

    def test_a_plain_file_is_no_odd_case(self):
        self.assertEqual(self.flags(), ())

    def test_each_odd_case_from_the_catalog_column_that_states_it(self):
        cases = [
            (dict(stream_type='Video only'), ('no_audio',)),
            (dict(sound={'heardTooLittle'}), ('sound_short',)),
            (dict(probe_extra=json.dumps({'frameRate': '1.999', 'resolution': '1920x1080'})), ('odd_rate',)),
            (dict(probe_extra=json.dumps({'frameRate': '29.97', 'resolution': '1920x2'})), ('odd_size',)),
            (dict(stream_type='ffprobe failed', probe_extra=None), ('damaged',)),
            (dict(stream_type='No A/V streams', probe_extra=None), ('damaged',)),
            (dict(probe_extra=json.dumps({'frameRate': '25', 'resolution': '720x576', 'isPlayable': 'Damaged file'})), ('damaged',)),
            (dict(checks={'broken'}), ('damaged',)),
            (dict(sound={'failed'}), ('damaged',)),
            (dict(duration=4.9), ('very_short',)),
            (dict(duration=7200.5), ('very_long',)),
        ]
        for kw, want in cases:
            with self.subTest(kw=kw):
                self.assertEqual(self.flags(**kw), want)

    def test_unknown_is_not_odd(self):
        # A fact the catalog does not hold raises no flag: no duration, no probe, an audio file's picture size.
        self.assertEqual(self.flags(duration=None, probe_extra=None), ())
        self.assertEqual(self.flags(duration=0.0), ())
        self.assertEqual(self.flags(stream_type='Audio only', probe_extra=json.dumps({'resolution': '1x1'})), ())
        self.assertEqual(self.flags(probe_extra='{not json'), ())
        self.assertEqual(self.flags(probe_extra=json.dumps({'frameRate': '29.97', 'resolution': '1920x1080',
                                                            'isPlayable': 'Codec unsupported'})), (),
                         'an AVFoundation-unsupported codec is the codec stratum, not damage')

    def test_without_a_stream_type_the_codecs_say_whether_sound_is_missing(self):
        self.assertEqual(cs.flags_of(None, None, None, 'h264', ''), ('no_audio',))
        self.assertEqual(cs.flags_of(None, None, None, 'h264', 'aac'), ())

    def test_flags_split_a_codec_mix_into_its_own_strata(self):
        rows = [row(1, 10), row(2, 10, stream='Video only'), row(3, 10, duration=2.0),
                row(4, 10, mix=('avi', 'dvvideo', 'pcm_s16le'))]
        stats = {}
        picked = cs.select(rows, [], can_read=everything, stats=stats)
        self.assertEqual(stats['strata'], 4)
        self.assertEqual({tuple(r['stratum']) for r in picked},
                         {H264, H264 + ('no_audio',), H264 + ('very_short',), ('avi', 'dvvideo', 'pcm_s16le')})


class Rule3QuotaTests(unittest.TestCase):

    def test_twelve_percent_rounded_up_at_least_three_and_three_or_fewer_whole(self):
        self.assertEqual([cs.quota(n) for n in (0, 1, 2, 3, 4, 25, 26, 100, 101, 1000)],
                         [0, 1, 2, 3, 3, 3, 4, 12, 13, 120])

    def test_each_stratum_takes_its_own_quota(self):
        rows = [row(n, 10 + n) for n in range(100)]
        rows += [row(500 + n, 10, mix=('mxf', 'dnxhd', '')) for n in range(2)]
        rows += [row(600 + n, 10, mix=('avi', 'dvvideo', 'pcm_s16le')) for n in range(10)]
        counts = {}
        for r in cs.select(rows, [], can_read=everything):
            counts[r['stratum'][0]] = counts.get(r['stratum'][0], 0) + 1
        self.assertEqual(counts, {H264[0]: 12, 'mxf': 2, 'avi': 3})


class Rule4SpreadTests(unittest.TestCase):

    def test_the_picks_cover_the_sizes_not_only_the_smallest(self):
        rows = [row(n, (n + 1) * GB // 10) for n in range(100)]               # 0.1 GB .. 10 GB
        sizes = sorted(r['size'] for r in cs.select(rows, [], can_read=everything))
        self.assertEqual(len(sizes), 12)
        self.assertLess(sizes[0], 1 * GB)
        self.assertLessEqual(sum(s >= cs.SPLIT_BYTES for s in sizes), 1, 'at most one large file (rule 3)')
        self.assertGreater(sizes[-1], 7 * GB, 'the picks still reach the top of the sizes')
        ranks = [s * 10 // GB - 1 for s in sizes]                            # the member's rank by size
        self.assertTrue(all(b - a >= 5 for a, b in zip(ranks, ranks[1:])), f'bunched picks: {ranks}')

    # Rick 2026-11-24: "do we really need more than 1TB?" — a file of 8 GB or more at most once per stratum.
    def test_a_stratum_takes_at_most_one_large_file(self):
        rows = [row(n, (n + 1) * GB // 10) for n in range(100)]               # 22 of them are >= 8 GB
        rows += [row(200 + n, 20 * GB + n, mix=('mov', 'prores', 'pcm_s24le')) for n in range(3)]  # all large, <= 3
        picked = cs.select(rows, [], can_read=everything)
        by = {}
        for r in picked:
            by.setdefault(r['stratum'][0], []).append(r['size'])
        self.assertLessEqual(sum(s >= cs.SPLIT_BYTES for s in by[H264[0]]), 1, by[H264[0]])
        self.assertEqual(len(by[H264[0]]), 12, 'the quota still holds')
        self.assertEqual(by['mov'], [20 * GB], 'a small stratum of large files gives its smallest one, not all three')

    def test_the_large_file_kept_is_the_one_already_copied(self):
        rows = [row(n, 9 * GB + n) for n in range(5)]
        current = [mrow(3, 9 * GB + 3, why='codec/container combo', root='external')]
        picked = cs.select(rows, current, can_read=everything)
        self.assertEqual([r['sha256'] for r in picked if r['size'] >= cs.SPLIT_BYTES], [sha(3)], 'no new copy made')

    def test_a_pinned_large_file_is_taken_and_then_no_other_large_one(self):
        rows = [row(n, 9 * GB + n) for n in range(4)] + [row(10 + n, GB) for n in range(4)]
        picked = cs.select(rows, [], can_read=everything, pins={sha(2): 'GH #1'})
        large = [r['sha256'] for r in picked if r['size'] >= cs.SPLIT_BYTES]
        self.assertEqual(large, [sha(2)])

    def test_a_volume_not_yet_picked_wins_inside_a_bin(self):
        # 3 bins of 2; in each the A-file has the smaller digest and the same distance to the middle: without
        # the volume rule all three picks would be on A.
        members = []
        for b in range(3):
            pair = sorted([sha(10 * b + 1), sha(10 * b + 2)])
            members += [cs.Candidate(pair[0], f'/Volumes/A/{b}', 100 + 2 * b, H264, 'A'),
                        cs.Candidate(pair[1], f'/Volumes/B/{b}', 100 + 2 * b, H264, 'B')]
        picks = cs.spread(members, 3)
        self.assertEqual(len(picks), 3)
        self.assertEqual({p.volume for p in picks}, {'A', 'B'})
        self.assertEqual(sorted(p.size for p in picks), [100, 102, 104], 'one per size bin')

    def test_the_same_catalog_gives_the_same_sample_whatever_the_row_order(self):
        rows = [row(n, 1000 + (n * 7919) % 5000, f'/Volumes/V{n % 3}/{n}.mov') for n in range(300)]
        first = cs.select(rows, [], can_read=everything)
        shuffled = list(rows)
        random.Random(4).shuffle(shuffled)
        self.assertEqual(cs.select(shuffled, [], can_read=everything), first)

    def test_a_size_tie_breaks_by_digest(self):
        members = [cs.Candidate(sha(n), f'/Volumes/A/{n}', 5, H264, 'A') for n in range(8)]
        self.assertEqual(cs.spread(members, 4), cs.spread(list(reversed(members)), 4))


class Rule5AlwaysTakenTests(unittest.TestCase):

    def test_a_pin_is_taken_and_counts_toward_its_strata_quota(self):
        rows = [row(n, 10 + n) for n in range(30)]                           # quota(30) = 4
        pins = {sha(29): 'GH #1 regression', sha(28): 'test_x'}
        picked = cs.select(rows, [], can_read=everything, pins=pins)
        digests = [r['sha256'] for r in picked]
        self.assertEqual(len(digests), 4)
        self.assertTrue({sha(29), sha(28)} <= set(digests))
        self.assertEqual({r['why'] for r in picked if r['sha256'] in pins}, {cs.WHY_PINNED})

    def test_a_hand_curated_row_is_always_taken_and_a_generic_one_is_not(self):
        rows = [row(n, 10 + n) for n in range(40)]
        current = [mrow(n, 10 + n, why='codec/container combo', root='internal') for n in range(30)]
        current += [mrow(n, 10 + n, why='one-sided sound', root='internal') for n in range(30, 36)]
        picked = {r['sha256']: r for r in cs.select(rows, current, can_read=everything)}
        self.assertTrue(all(sha(n) in picked for n in range(30, 36)), 'the proof lane rests on these')
        self.assertEqual({picked[sha(n)]['why'] for n in range(30, 36)}, {'one-sided sound'})
        self.assertEqual(len(picked), 6, 'six curated already pass the quota (5) of the 40: nothing generic added')

    def test_a_curated_row_whose_content_left_the_catalog_is_still_taken_from_the_manifest(self):
        current = [dict(mrow(7, 50, why='raw DV', root='internal'), stratum=['dv', 'dvvideo', 'pcm_s16le'])]
        picked = cs.select([row(1, 10)], current, can_read=everything)
        self.assertEqual({r['sha256']: r['stratum'] for r in picked}[sha(7)], ['dv', 'dvvideo', 'pcm_s16le'])

    def test_a_pin_nowhere_to_be_found_is_counted_not_guessed(self):
        stats = {}
        cs.select([row(1, 10)], [], can_read=everything, pins={sha(99): 'GH #2'}, stats=stats)
        self.assertEqual(stats['pins_not_found'], 1)

    def test_the_pins_file_holds_digests_and_reasons_only(self):
        self.assertEqual(cs.load_pins(cs.PINS), {}, 'the repository pin list (empty until a test or bug names a corpus file)')
        with tempfile.TemporaryDirectory() as tmp:
            bad = pathlib.Path(tmp, 'pins.json')
            for text in ('[]', json.dumps({'pins': [{'sha256': '/Volumes/A/a.mov'}]}), '{not json'):
                bad.write_text(text)
                with self.assertRaises(cs.Refused):
                    cs.load_pins(bad)
            bad.write_text(json.dumps({'pins': [{'sha256': sha(1).upper(), 'why': 'GH #3'}]}))
            self.assertEqual(cs.load_pins(bad), {sha(1): 'GH #3'})


class ReviewerPinTests(unittest.TestCase):

    def test_reviewer_a_pin_taken_out_of_the_pins_file_is_no_longer_always_taken(self):
        """Reviewer, 2026-11-24. A new pin is written with why `pinned` (corpus_select.py:367); `pinned` is not in
        GENERIC_WHYS (corpus_select.py:87-88), so the next select reads it as hand-curated (corpus_select.py:348)
        and takes it forever: removing it from corpus_pins.json never takes effect."""
        rows = [row(n, 10 + n) for n in range(10)]               # quota(10) = 3; the spread never takes the smallest
        self.assertNotIn(sha(0), {r['sha256'] for r in cs.select(rows, [], can_read=everything)})
        pinned = cs.select(rows, [], can_read=everything, pins={sha(0): 'GH #1'})
        self.assertIn(sha(0), {r['sha256'] for r in pinned})
        again = cs.select(rows, pinned, can_read=everything, pins={})
        self.assertNotIn(sha(0), {r['sha256'] for r in again}, 'an unpinned file is still always taken')


class ReviewerSpreadTests(unittest.TestCase):

    def test_inside_a_size_bin_a_file_already_copied_wins_so_a_newer_catalog_does_not_swap_copies(self):
        # One bin of two on the same volume: the uncopied one is nearer the bin's middle and has the smaller digest;
        # the copied one is taken all the same (a re-select over a newer catalog keeps the copy it has).
        pair = sorted([sha(1), sha(2)])
        members = [cs.Candidate(pair[0], '/Volumes/A/new', 10, H264, 'A'),
                   cs.Candidate(pair[1], '/Volumes/A/held', 10, H264, 'A', 'external')]
        self.assertEqual([c.digest for c in cs.spread(members, 1)], [pair[1]])
        self.assertEqual([c.digest for c in cs.spread([members[0], members[1]._replace(root=None)], 1)], [pair[0]],
                         'without a copy the digest decides, as before')

    def test_a_volume_not_yet_picked_still_outranks_a_copy(self):
        taken = [cs.Candidate(sha(9), '/Volumes/A/t', 1, H264, 'A')]
        members = [cs.Candidate(sha(1), '/Volumes/A/held', 10, H264, 'A', 'external'),
                   cs.Candidate(sha(2), '/Volumes/B/new', 10, H264, 'B')]
        self.assertEqual([c.volume for c in cs.spread(members + taken, 2, taken)], ['B'])


class Rule6PlaceTests(unittest.TestCase):

    def cand(self, n, size, root=None):
        return cs.Candidate(sha(n), f'/Volumes/A/{n}', size, H264, 'A', root)

    def test_small_goes_external_large_goes_internal_and_what_fits_neither_is_ro(self):
        roots = cs.place([self.cand(1, 1 * GB), self.cand(2, 9 * GB), self.cand(3, 30 * GB), self.cand(4, 50 * GB)],
                         internal_budget=40 * GB, external_budget=40 * GB)
        # smallest first: 1 GB -> ext (1); 9 GB -> int (9); 30 GB -> int (39); 50 GB -> neither
        self.assertEqual(roots, {sha(1): 'external', sha(2): 'internal', sha(3): 'internal', sha(4): 'ro'})

    def test_a_large_file_the_ssd_cannot_hold_goes_to_the_x10(self):
        roots = cs.place([self.cand(1, 30 * GB), self.cand(2, 20 * GB)], internal_budget=25 * GB, external_budget=100 * GB)
        self.assertEqual(roots, {sha(2): 'internal', sha(1): 'external'})

    def test_a_small_file_spills_to_the_ssd_before_ro(self):
        roots = cs.place([self.cand(1, 3 * GB), self.cand(2, 4 * GB)], internal_budget=10 * GB, external_budget=5 * GB)
        self.assertEqual(roots, {sha(1): 'external', sha(2): 'internal'})

    def test_a_copy_in_place_keeps_its_root_while_the_root_has_room(self):
        roots = cs.place([self.cand(1, 1 * GB, 'internal'), self.cand(2, 20 * GB, 'external'),
                          self.cand(3, 5 * GB, 'internal')], internal_budget=5 * GB, external_budget=100 * GB)
        self.assertEqual(roots, {sha(1): 'internal', sha(2): 'external', sha(3): 'external'},
                         'the second internal copy no longer fits the SSD budget: placed again')

    def test_the_budgets_are_never_passed(self):
        cands = [self.cand(n, (n % 13 + 1) * GB, ('internal', 'external', None)[n % 3]) for n in range(200)]
        roots = cs.place(cands, internal_budget=300 * GB, external_budget=500 * GB)
        used = {'internal': 0, 'external': 0}
        for c in cands:
            if roots[c.digest] in used:
                used[roots[c.digest]] += c.size
        self.assertLessEqual(used['internal'], 300 * GB)
        self.assertLessEqual(used['external'], 500 * GB)
        self.assertIn('ro', roots.values())


class MediaMatrixTests(unittest.TestCase):

    MATRIX = [('mov,mp4,m4a,3gp,3g2,mj2', 'h264', 'aac'), ('mov,mp4,m4a,3gp,3g2,mj2', 'prores', 'pcm_s24le'),
              ('matroska,webm', 'ffv1', 'pcm_s16le'), ('mxf', 'dnxhd', 'pcm_s24le'), ('avi', 'dvvideo', 'pcm_s16le')]

    def test_every_container_and_codec_mix_of_the_matrix_is_in_the_sample(self):
        rows, n = [], 0
        for k, mix in enumerate(self.MATRIX):
            for i in range(20 * (k + 1)):
                n += 1
                rows.append(row(n, 1_000 + i, mix=mix))
        picked = cs.select(rows, [], can_read=everything)
        by_mix = {}
        for r in picked:
            by_mix[tuple(r['stratum'][:3])] = by_mix.get(tuple(r['stratum'][:3]), 0) + 1
        self.assertEqual(by_mix, {mix: cs.quota(20 * (k + 1)) for k, mix in enumerate(self.MATRIX)})


class OutputTests(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = pathlib.Path(self.tmp.name, 'out')

    def tearDown(self):
        self.tmp.cleanup()

    def test_the_lists_name_only_the_copies_a_root_does_not_hold_yet(self):
        rows = [dict(sha256=sha(1), path='/Volumes/A/x y.mov', size=5, why='sample', root='external'),
                dict(sha256=sha(2), path='/Volumes/B/big.mxf', size=9 * GB, why='sample', root='internal'),
                dict(sha256=sha(3), path='/Volumes/B/held.mov', size=7, why='x', root='external'),
                dict(sha256=sha(4), path='/Volumes/B/huge.mxf', size=99 * GB, why='sample', root='ro')]
        current = [mrow(3, 7, '/Volumes/B/held.mov')]
        copying = cs.to_copy(rows, current)
        cs.write_selection(copying, self.out)
        self.assertEqual((self.out / 'v2_external.sha').read_text(), f'{sha(1)}  Volumes/A/x y.mov\n')
        self.assertEqual((self.out / 'v2_internal.files').read_text(), 'Volumes/B/big.mxf\n')
        self.assertEqual(json.loads((self.out / 'selection.json').read_text())['ro'], [[sha(4), '/Volumes/B/huge.mxf', 99 * GB]])
        self.assertFalse((self.out / 'v2_ro.files').exists(), 'ro is read in place: nothing to copy')

    def test_the_command_line_writes_the_sample_manifest_and_prints_counts_only(self):
        s = Scene(self.tmp.name)
        for n in range(30):
            s.add(f'/Volumes/Secret Drive/Grandma {n}.mov', n, 100 + n)
        path = s.close()
        current = pathlib.Path(self.tmp.name, 'current.json')
        current.write_text(json.dumps([mrow(n, 100 + n, f'/Volumes/Secret Drive/Grandma {n}.mov') for n in range(30)]))
        code, text = said(['select', '--catalog', str(path), '--current', str(current), '--out', str(self.out)])
        self.assertEqual(code, 0, text)
        rows = json.loads((self.out / 'corpus-manifest-v2.json').read_text())
        self.assertEqual(len(rows), 4)
        self.assertEqual({r['root'] for r in rows}, {'external'})
        self.assertIn('corpus select: 30 -> 4 files; 1 strata', text)
        self.assertIn('corpus select: external 30 files 0.0 GB -> 4 files 0.0 GB', text)
        self.assertIn('corpus select: external to copy 0 files', text)
        for secret in ('Secret', 'Grandma'):
            self.assertNotIn(secret, text)

    def test_an_estimate_says_so_on_every_line(self):
        s = Scene(self.tmp.name)
        s.add('/Volumes/Nowhere/a.mov', 1, 100)
        path = s.close()
        current = pathlib.Path(self.tmp.name, 'current.json')
        current.write_text('[]')
        code, text = said(['select', '--catalog', str(path), '--current', str(current), '--out', str(self.out),
                           '--assume-readable'])
        self.assertEqual(code, 0)
        self.assertTrue(all('ESTIMATE' in line for line in text.splitlines()), text)
        self.assertIn('external to copy 1 files', text)

    def test_nothing_with_a_real_path_is_written_into_the_repository(self):
        with self.assertRaises(cs.Refused):
            cs.write_selection({'external': [], 'internal': []}, REPO / '.scratch' / 'selection')
        self.assertFalse((REPO / '.scratch' / 'selection').exists())
        s = Scene(self.tmp.name)
        s.add('/Volumes/A/a.mov', 1, 100)
        path = s.close()
        current = pathlib.Path(self.tmp.name, 'current.json')
        current.write_text('[]')
        code, _ = said(['select', '--catalog', str(path), '--current', str(current), '--out', str(REPO / 'scripts')])
        self.assertEqual(code, 2)

    def test_f1_a_manifest_write_that_fails_leaves_the_manifest_as_it_was(self):
        # Codex #336 F1: --current and the written manifest may be the same file; a failed write must not cost its rows.
        s = Scene(self.tmp.name)
        s.add('/Volumes/A/old.mov', 1, 100)
        path = s.close()
        self.out.mkdir()
        manifest = self.out / 'corpus-manifest-v2.json'
        original = json.dumps([mrow(5, 1, '/Volumes/A/kept.mov', why='raw DV', root='internal')])
        manifest.write_text(original)
        real = pathlib.Path.write_text

        def failing(self, *args, **kwargs):
            if self == manifest:
                real(self, '')
                raise OSError(28, 'No space left on device')
            return real(self, *args, **kwargs)
        pathlib.Path.write_text = failing
        try:
            code = cs.main(['select', '--catalog', str(path), '--current', str(manifest), '--out', str(self.out)])
        except OSError:
            code = 1
        finally:
            pathlib.Path.write_text = real
        self.assertEqual(code, 0, 'the write goes to a new file, renamed into place')
        self.assertIn(sha(5), [r['sha256'] for r in json.loads(manifest.read_text())])


class IsolationTests(unittest.TestCase):

    def test_a_catalog_with_a_wal_beside_it_is_refused_and_the_catalog_is_never_written(self):
        with tempfile.TemporaryDirectory() as tmp:
            s = Scene(tmp)
            s.add('/Volumes/A/a.mov', 1, 5)
            path = s.close()
            before = (path.read_bytes(), sorted(os.listdir(path.parent)))
            cs.catalog_evidence(path)
            self.assertEqual((path.read_bytes(), sorted(os.listdir(path.parent))), before, 'a read left a mark')
            pathlib.Path(str(path) + '-wal').write_text('')
            with self.assertRaises(cs.Refused):
                cs.catalog_evidence(path)

    def test_the_real_schema_gives_every_odd_case_column(self):
        with tempfile.TemporaryDirectory() as tmp:
            s = Scene(tmp)
            rid = s.add('/Volumes/A/a.mov', 1, 5)
            s.db.conn.execute("UPDATE files SET stream_type = 'Video only', duration_s = 3.0, probe_extra = ? WHERE id = ?",
                              (json.dumps({'frameRate': '1.999', 'resolution': '120x90'}), rid))
            s.db.conn.execute("INSERT INTO media_checks (digest, kind, status, checked_at) VALUES (?, 'video', 'broken', 1)", (sha(1),))
            # sound_attempts comes from a later migration than the schema files the fixture reads: as the live catalog has it.
            s.db.conn.execute("CREATE TABLE IF NOT EXISTS sound_attempts (digest TEXT PRIMARY KEY, engine_version INTEGER NOT NULL, "
                              "outcome TEXT NOT NULL, attempts INTEGER NOT NULL, last_at INTEGER NOT NULL, detail TEXT)")
            s.db.conn.execute("INSERT INTO sound_attempts VALUES (?, 1, 'heardTooLittle', 1, 1, NULL)", (sha(1).upper(),))
            evidence = cs.catalog_evidence(s.close())
        self.assertEqual(evidence.missing, [], 'the catalog DDL lost a column the rule reads')
        picked = cs.select(evidence.rows, [], can_read=everything, sound=evidence.sound, checks=evidence.checks)
        self.assertEqual(picked[0]['stratum'][3:], ['no_audio', 'sound_short', 'odd_rate', 'odd_size', 'damaged', 'very_short'])

    def test_a_catalog_without_the_odd_case_columns_reads_them_as_unknown_and_says_which(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = minimal_catalog(tmp, [(sha(1), '/Volumes/A/a.mov', 100, 'mov,mp4', 'h264', 'aac')])
            current = pathlib.Path(tmp, 'current.json')
            current.write_text('[]')
            evidence = cs.catalog_evidence(path)
            code, text = said(['select', '--catalog', str(path), '--current', str(current), '--out', str(pathlib.Path(tmp, 'out'))])
        self.assertEqual(evidence.missing, ['files.stream_type', 'files.duration_s', 'files.probe_extra',
                                            'sound_attempts.outcome', 'media_checks.status'])
        self.assertEqual(code, 0)
        self.assertIn('not in this catalog (read as unknown): files.stream_type', text)

    def test_poisoned_manifest_paths_are_never_placed(self):
        current = [mrow(1, 10, '/Volumes/A/../../etc/passwd', why='raw DV', root='internal')]
        stats = {}
        picked = cs.select([], current, can_read=everything, stats=stats)
        self.assertEqual((picked, stats['pins_not_found']), ([], 1))


class ScaleTests(unittest.TestCase):

    def test_100k_rows_are_sampled_inside_the_time_budget_at_about_twelve_percent(self):
        rows = [(i, sha(i % 60_000), f'/Volumes/V{i % 7}/f{i}.mov', 1_000 + (i % 97) * 10_000_000,
                 'mov,mp4', f'c{i % 40}', 'aac', 'Video+Audio', 30.0 + i % 9, PLAIN) for i in range(100_000)]
        t0 = time.time()
        stats = {}
        picked = cs.select(rows, [mrow(1, 1)], can_read=everything, stats=stats)
        took = time.time() - t0
        self.assertLess(took, 10.0, f'100k rows took {took:.1f}s')
        self.assertEqual(stats['strata'], 40)
        self.assertEqual(len(picked), 40 * cs.quota(1_500))                 # 60,000 contents over 40 mixes
        self.assertLessEqual(sum(r['size'] for r in picked if r['root'] == 'external'), cs.EXTERNAL_BUDGET)


if __name__ == '__main__':
    unittest.main()
