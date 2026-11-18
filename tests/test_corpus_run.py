"""scripts/corpus_run.py + scripts/corpus_run.sh — the real-data corpus harness.

DECISIONS 2026-11-17: the M4 holds a curated copy of real family media and a
`.backup` of the catalog; automation runs the app's engines across it, sealed
off from the live catalog, and reports facts and counts. These tests pin what
can be pinned without the M4 and without any real media:

  the seal      refused on any host but the M4 (the Ultra by name), refused
                for a state root outside ~/corpus/state, no write outside
                ~/corpus/{state,work,reports};
  prepare       the sealed catalog holds only the manifest's rows, paths
                rewritten, every schema trigger in place, the source backup
                byte-identical afterwards; every refusal leaves no debris;
  a lane        a crash or a deadline in one file does not stop the run; the
                report is counts by stratum and by container/codec; nothing
                that reaches a summary can carry a path or a filename;
  the verdict   a lane's verdict is its diff against the baseline: a moved outcome
                word is AMBER and listed by SHA-256 prefix, a crash or a deadline
                is RED, `accept` blesses a run (who, when, which) and refuses a
                RED or partial one; a poisoned baseline is RED, never a pass;
  status        the newest run judged against the baseline as it stands now.

A fake `xcodebuild` plays the build and the in-app driver. Nothing here runs
ssh, launchctl, a real xcodebuild or ffmpeg, and nothing opens a real catalog.
"""
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS = REPO / 'scripts'
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(REPO / 'tests'))
import catalog_db  # noqa: E402
import corpus_run as cr  # noqa: E402
from catalog_sqlite_fixture import Catalog  # noqa: E402

DB = catalog_db.DATABASE_FILE_NAME
LATCH = catalog_db.LATCH_FILE_NAME

# Names a leak would show: every one of these is a path component or filename of the fake corpus.
SECRET_NAMES = ('Grandma', 'Birthday', 'Lake House', 'reel_07', 'PrivateDrive')

FAKE_XCODEBUILD = r'''#!/usr/bin/env python3
# Stand-in for xcodebuild: `build-for-testing` leaves an .xctestrun; `test-without-building`
# plays the in-app driver from the patched .xctestrun's environment and FAKE_PLAN.
import json, os, plistlib, sys
args = sys.argv[1:]
plan = json.load(open(os.environ["FAKE_PLAN"]))
with open(plan["calls"], "a") as f:
    f.write(json.dumps({"args": args, "home": os.environ.get("HOME", "")}) + "\n")
if args[0] == "build-for-testing":
    if plan.get("build_fails"):
        sys.exit(65)
    dd = args[args.index("-derivedDataPath") + 1]
    os.makedirs(dd + "/Build/Products", exist_ok=True)
    with open(dd + "/Build/Products/VideoScan_VideoScan-CI_macosx.xctestrun", "wb") as f:
        plistlib.dump({"TestConfigurations": [{"TestTargets": [
            {"BlueprintName": "VideoScanTests", "TestBundlePath": "__TESTHOST__/VideoScanTests.xctest",
             "EnvironmentVariables": {"KEPT": "1", "OS_ACTIVITY_DT_MODE": "YES"}, "SkipTestIdentifiers": ["Some/test"]}]}]}, f)
    # A newer plan file with no unit-test target (as the UI plans' are): it names VideoScanTests only in passing.
    with open(dd + "/Build/Products/VideoScan_VideoScan-UI_macosx.xctestrun", "wb") as f:
        plistlib.dump({"TestPlan": {"Note": "VideoScanTests"}, "TestConfigurations": [{"TestTargets": [
            {"BlueprintName": "VideoScanUITests", "TestBundlePath": "__TESTHOST__/VideoScanUITests.xctest"}]}]}, f)
    os.utime(dd + "/Build/Products/VideoScan_VideoScan-CI_macosx.xctestrun", (1, 1))
    sys.exit(0)
run = plistlib.load(open(args[args.index("-xctestrun") + 1], "rb"))
env = run["TestConfigurations"][0]["TestTargets"][0]["EnvironmentVariables"]
config = json.load(open(env["VS_CORPUS_CONFIG"]))
target = run["TestConfigurations"][0]["TestTargets"][0]
with open(plan["calls"], "a") as f:
    f.write(json.dumps({"driver_env": env, "pending": len(config["pending"]), "lane": config["lane"],
                        "target": target["BlueprintName"], "target_keys": sorted(target), "config": config,
                        "rows": [r[0] for r in __import__("sqlite3").connect("file:" + config["catalog"] + "?mode=ro", uri=True)
                                 .execute("SELECT full_path FROM files ORDER BY full_path")],
                        "clones_exist": all(os.path.isfile(p) for i in config["pending"] for p in [i["path"]] + (i.get("copies") or []))}) + "\n")
if plan.get("vandal"):                                   # an engine that reaches the pristine corpus (it must turn the lane RED)
    os.utime(plan["vandal"], (5, 5))
if plan.get("lock"):                                     # what Promote does to what it archives
    locked = os.path.join(config["archiveRoot"], "locked.bin")
    open(locked, "w").write("x"); os.chflags(locked, 0x2)
out = open(config["progress"], "a")
def say(**ev):
    out.write(json.dumps(ev) + "\n"); out.flush()
if plan.get("refuse"):
    say(ev="refused", why=plan["refuse"]); sys.exit(1)
if plan.get("silent"):
    sys.exit(1)
say(ev="hello", lane=config["lane"], homeSealed=True, testHost=True, archiveDesignation=False, records=len(config["pending"]))
engines = plan["engines"]
for item in config["pending"]:
    how = plan["files"].get(item["sha"], {})
    say(ev="begin", sha=item["sha"])
    say(ev="facts", sha=item["sha"], container=how.get("container", "mov,mp4,m4a,3gp,3g2,mj2"), vcodec=how.get("vcodec", "h264"),
        acodec=how.get("acodec", "aac"), duration=60.0, bytes=1)
    for engine in engines:
        if how.get("crash") == engine:
            out.write('{"ev": "engine", "sha": "cut-mid-li')        # a line cut by the crash
            out.flush(); os._exit(139)
        if how.get("timeout") == engine:
            say(ev="engine", sha=item["sha"], engine=engine, outcome="timeout", s=1.0)
            say(ev="end", sha=item["sha"], cut=True); os._exit(86)
        say(ev="engine", sha=item["sha"], engine=engine, outcome=how.get(engine, "OK"), kinds=how.get(engine + "_kinds", []), s=0.5)
    if how.get("crash") == "end":                        # every engine answered; the host dies before `end`
        os._exit(139)
    say(ev="end", sha=item["sha"])
if config["lane"] == "verbs":
    say(ev="verbs", trashFiles=plan.get("trash_files", 0), trashedByEngines=plan.get("trash_files", 0),
        strayTrashFiles=plan.get("stray", 0), records=len(config["pending"]))
say(ev="done")
'''

# Stand-in for /bin/cp: records its arguments, then copies (the tests run where `cp -c` may not clone).
FAKE_CP = r'''#!/usr/bin/env python3
import json, os, shutil, sys
with open(os.environ["FAKE_CP_CALLS"], "a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\n")
shutil.copy2(sys.argv[-2], sys.argv[-1])
'''


def sha_of(n):
    return hashlib.sha256(f'content-{n}'.encode()).hexdigest()


class CorpusScene:
    """A fake M4 home: ~/corpus with the marker, a manifest, the sha list, media files of
    the right sizes and a source backup built from the catalog's real DDL."""

    FILES = [  # (n, original path, size, stratum)
        (0, '/Volumes/PrivateDrive/Grandma/Birthday 1988.mov', 1200, 'one-sided sound'),
        (1, '/Volumes/PrivateDrive/Lake House/reel_07.MXF', 3400, 'Avid video half'),
        (2, '/Volumes/PrivateDrive/Lake House/reel_07.dv', 5600, 'codec/container combo'),
    ]

    def __init__(self, tmp, hostname='ricksm4'):
        self.home = pathlib.Path(tmp, 'home')
        self.corpus = self.home / 'corpus'
        self.corpus.mkdir(parents=True)
        (self.corpus / cr.MARKER).write_text('test data\n')
        self.seal = cr.Seal(self.home, hostname)
        self.files = list(self.FILES)
        self.write_documents()
        for n, original, size, _ in self.files:
            path = self.corpus / 'media' / original.lstrip('/')
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'x' * size)
        self.build_source()

    def write_documents(self):
        (self.corpus / cr.MANIFEST).write_text(json.dumps(
            [dict(path=o, sha256=sha_of(n), size=s, why=w) for n, o, s, w in self.files]))
        (self.corpus / cr.SHA_LIST).write_text(''.join(
            f"{sha_of(n)}  media/{o.lstrip('/')}\n" for n, o, s, w in self.files))

    def build_source(self):
        folder = self.corpus / 'source-build'
        folder.mkdir()
        db = Catalog(folder)
        for n, original, size, _ in self.files:
            db.add(original, digest=sha_of(n), size=size, transcript='family words', captions=[(1.0, 'a caption')],
                   user_date='1988' if n == 0 else None, tags=['Silent — checked'] if n == 1 else None,
                   confirmed=['A Person'])
        db.add('/Volumes/OtherDrive/copy of birthday.mov', digest=sha_of(0), size=1200)           # another copy
        db.add('/Volumes/PrivateDrive/Lake House/reel_07.dv', digest=sha_of(9), size=77,          # an older, removed row
               removal=('removedFromCatalog', 'gone'))
        for n in range(20, 30):
            db.add(f'/Volumes/OtherDrive/unrelated {n}.mp4', digest=sha_of(n), size=10 + n)
        self.pair_source(db)
        db.conn.execute("CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")     # GRDB's own, as in a real catalog
        db.conn.executemany("INSERT INTO grdb_migrations VALUES (?)", [("v1",), ("v2",)])
        db.conn.execute("UPDATE catalog_state SET master_archive = ? WHERE singleton = 1",
                        (json.dumps({'rootPath': '/Volumes/FamilyArchive/Somewhere'}),))
        path = db.close()
        self.source = self.corpus / cr.SOURCE_BACKUP
        os.replace(path, self.source)
        for leftover in folder.iterdir():
            leftover.unlink()
        folder.rmdir()
        self.source_hash = hashlib.sha256(self.source.read_bytes()).hexdigest()

    GROUP = '11111111-2222-3333-4444-555555555555'

    def pair_source(self, db):
        """Pair links as a real catalog holds them. File 1 (the Avid video half) and file 2: an
        import-era link each (an import run, its items, legacy_pair_ids) in one pair group. File 0:
        an import-era link the app later CLEARED (row_knowledge 'pair' = {}). A file that is not in
        the corpus: paired too. The run is left open — the schema refuses to insert a finished one."""
        c = db.conn
        ids = {row[1]: row[0] for row in c.execute("SELECT id, full_path FROM files WHERE removal_state IS NULL")}
        c.execute("INSERT INTO import_runs (run_id, started_at, source_sha256, source_generation, integrity_run_id, "
                  "audit_run_started_at, audit_run_finished_at, audit_generation, integrity_started_at, integrity_generation) "
                  "VALUES ('run-1', 1, ?, 3, 'integrity', 1, 2, 3, 3, 3)", ('a' * 64,))
        paired = [self.FILES[1][1], self.FILES[2][1], self.FILES[0][1], '/Volumes/OtherDrive/unrelated 20.mp4']
        for ordinal, path in enumerate(paired):
            c.execute("INSERT INTO import_items (import_run, source_file, source_ordinal, item_kind, source_key, landed_table, landed_ref) "
                      "VALUES ('run-1', 'catalog.json', ?, 'row', ?, 'files', ?)", (ordinal, ids[path], ids[path]))
            c.execute("INSERT INTO legacy_pair_ids (import_run, source_ordinal, json_row_id, paired_with_id, pair_group_id) "
                      "VALUES ('run-1', ?, ?, ?, ?)", (ordinal, ids[path], None if ordinal else ids[paired[1]],
                                                       self.GROUP if ordinal < 2 else '99999999-0000-0000-0000-00000000000%d' % ordinal))
        for value in ('{"pairGroupID": "old", "pairConfidence": "low"}', '{}'):                    # the newest word wins: cleared
            c.execute("INSERT INTO row_knowledge (file_id, field, value_json, set_at, source, generation) "
                      "VALUES (?, 'pair', ?, 5, 'app:correlate', 3)", (ids[self.FILES[0][1]], value))
        self.ids = ids

    def catalog(self):
        return sqlite3.connect(f'file:{self.seal.state / DB}?mode=ro', uri=True)


class SealTests(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.scene = CorpusScene(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_the_m4_with_its_marker_and_default_state_root_passes(self):
        self.assertIs(self.scene.seal.check(), self.scene.seal)
        self.assertEqual(self.scene.seal.state, self.scene.corpus / 'state')

    def test_any_host_but_the_m4_is_refused_and_the_ultra_by_name(self):
        for host in ('RicksUltra', 'ricksultra.local', 'ricksm5', 'Mac-1234', 'localhost', ''):
            with self.subTest(host=host), self.assertRaises(cr.Refused) as refused:
                cr.Seal(self.scene.home, host).check()
            self.assertIn('only on the M4', str(refused.exception))
        with self.assertRaises(cr.Refused) as refused:
            cr.Seal(self.scene.home, 'RicksUltra.local').check()
        self.assertIn("Rick's machine", str(refused.exception))
        self.assertEqual(cr.ALLOWED_HOSTS, frozenset({'ricksm4'}))

    def test_a_state_root_outside_corpus_state_is_refused(self):
        home = self.scene.home
        live = home / 'Library' / 'Application Support' / 'VideoScan'
        live.mkdir(parents=True)
        (self.scene.corpus / 'state').mkdir()
        os.symlink(live, self.scene.corpus / 'state' / 'escape')          # a symlink out of the seal
        for root in (home / 'elsewhere', self.scene.corpus, self.scene.corpus / 'work', live,
                     self.scene.corpus / 'state' / '..' / 'media', self.scene.corpus / 'state' / 'escape',
                     pathlib.Path('/Volumes/FamilyArchive/state'), pathlib.Path('/tmp')):
            with self.subTest(root=str(root)), self.assertRaises(cr.Refused):
                cr.Seal(home, 'ricksm4', root).check()
        cr.Seal(home, 'ricksm4', self.scene.corpus / 'state' / 'nested').check()     # under it: allowed

    def test_no_marker_is_not_the_corpus(self):
        (self.scene.corpus / cr.MARKER).unlink()
        with self.assertRaises(cr.Refused) as refused:
            self.scene.seal.check()
        self.assertIn(cr.MARKER, str(refused.exception))

    def test_writes_stay_inside_state_work_and_reports(self):
        seal, corpus = self.scene.seal, self.scene.corpus
        for ok in (corpus / 'state' / 'a', corpus / 'work' / 'run' / 'b', corpus / 'reports' / 'check' / 'c'):
            self.assertEqual(seal.writable(ok), ok)
        (corpus / 'work').mkdir()
        os.symlink(corpus / 'media', corpus / 'work' / 'sneak')
        for bad in (corpus / 'media' / 'Volumes' / 'x', corpus / 'live' / 'Share' / 'x', corpus / cr.MANIFEST,
                    corpus / cr.SOURCE_BACKUP, self.scene.home / 'Library' / 'Application Support' / 'VideoScan' / DB,
                    pathlib.Path('/Volumes/FamilyArchive/x'), self.scene.home / 'x', corpus / 'work' / 'sneak' / 'x'):
            with self.subTest(bad=str(bad)), self.assertRaises(cr.Refused):
                seal.writable(bad)

    def test_the_command_line_refuses_on_the_ultras_hostname_and_writes_nothing(self):
        # The real entry point, real home, the Ultra's name: whatever Mac runs this test.
        code = ("import socket, sys; socket.gethostname = lambda: 'RicksUltra.local'; "
                f"sys.path.insert(0, {str(SCRIPTS)!r}); import corpus_run; sys.exit(corpus_run.main(sys.argv[1:]))")
        out = pathlib.Path(self.tmp.name, 'out')
        out.mkdir()
        for argv in (['status'],
                     ['host', 'prepare', '--sha', 'a' * 40, '--stamp', 's', '--out', str(out), '--worktree', str(out),
                      '--derived-data', str(out), '--bin', str(SCRIPTS)],
                     ['host', 'check', '--sha', 'a' * 40, '--stamp', 's', '--out', str(out), '--worktree', str(out),
                      '--derived-data', str(out), '--bin', str(SCRIPTS)]):
            with self.subTest(argv=argv[:2]):
                p = subprocess.run([sys.executable, '-c', code, *argv], capture_output=True, text=True, timeout=60)
                self.assertEqual(p.returncode, cr.EXIT_REFUSED, p.stdout + p.stderr)
                self.assertIn("corpus: RED refused: this is ricksultra", p.stdout)
        self.assertEqual(sorted(p.name for p in out.iterdir()), [], 'on a Mac that is not the M4 the harness writes nothing at all')

    def test_main_refuses_a_non_m4_seal_before_touching_anything(self):
        seal = cr.Seal(self.scene.home, 'ricksultra')
        out = pathlib.Path(self.tmp.name, 'out')
        out.mkdir()
        code = cr.main(['host', 'prepare', '--sha', 'a' * 40, '--stamp', 's', '--out', str(out), '--worktree', str(out),
                        '--derived-data', str(out), '--bin', str(SCRIPTS)], seal=seal)
        self.assertEqual(code, cr.EXIT_REFUSED)
        self.assertFalse((self.scene.corpus / 'state').exists(), 'a refused run built state')

    def test_the_in_app_driver_carries_the_same_seal(self):
        support = (SCRIPTS / 'corpus' / 'CorpusDriverSupport.swift').read_text()
        seal = (SCRIPTS / 'corpus' / 'CorpusSeal.swift').read_text()
        self.assertIn('static let allowedHosts: Set<String> = ["ricksm4"]', seal)
        for guard in ('getpwuid(getuid())', 'TestEnvironment.isTestHost', 'CorpusSeal.refusal(input)', 'homeDirectory: NSHomeDirectory()',
                      'masterArchiveJSON == nil', '.syncedCopy(', '_exit(86)'):
            self.assertIn(guard, support, guard)
        self.assertIn(cr.MARKER, seal)
        self.assertEqual([line for line in seal.splitlines() if line.startswith('import ')], ['import Foundation'],
                         'the seal compiles by itself: SwiftSealTests runs it')
        self.assertNotIn('kill(', support + seal)
        for lane, (_, _, _, sources) in cr.LANES.items():
            self.assertEqual(sources[:2], ['CorpusSeal.swift', 'CorpusDriverSupport.swift'], lane)

    def test_the_drivers_never_write_an_engines_sentence_or_a_name(self):
        for name in ('CorpusSeal.swift', 'CorpusDriverSupport.swift', 'CorpusCheckDriver.swift', 'CorpusProofDriver.swift',
                     'CorpusVerbsDriver.swift'):
            code = '\n'.join(line for line in (SCRIPTS / 'corpus' / name).read_text().splitlines()
                             if not line.lstrip().startswith('//'))
            for leak in ('.message', 'localizedDescription', 'lastPathComponent', '.filename', '.headline', '.sentence',
                         'persistedNote', 'print(', 'NSLog', '"path"'):
                self.assertNotIn(leak, code, f'{name}: {leak}')
        proof = (SCRIPTS / 'corpus' / 'CorpusProofDriver.swift').read_text()
        self.assertIn('CorpusProofDriver.category(ofCouldNotCheck: reason)', proof, 'a category, never the sentence')
        self.assertNotIn('[reason]', proof)
        for lane, (klass, _, _, sources) in cr.LANES.items():
            self.assertIn(f'final class {klass}: XCTestCase', (SCRIPTS / 'corpus' / sources[-1]).read_text())

    def test_no_ref_tracks_the_overlay_folder_and_the_helper_never_signals(self):
        tracked = subprocess.run(['git', '-C', str(REPO), 'ls-files', '--', cr.OVERLAY_DIR], capture_output=True, text=True)
        self.assertEqual(tracked.stdout.strip(), '')
        source = (SCRIPTS / 'corpus_run.py').read_text()
        for call in ('os.kill', 'killpg', '.terminate(', '.send_signal(', 'pkill'):
            self.assertNotIn(call, source.split('"""', 2)[2], call)


class WordTests(unittest.TestCase):

    def test_a_word_cannot_carry_a_path_a_filename_or_a_sentence(self):
        self.assertEqual(cr.word('OK'), 'OK')
        self.assertEqual(cr.word('mov,mp4,m4a,3gp,3g2,mj2'), 'mov,mp4,m4a,3gp,3g2,mj2')
        self.assertEqual(cr.word('error:couldNotRead'), 'error:couldNotRead')
        for leak in ('/Users/rickb/corpus/media/Volumes/PrivateDrive/Grandma/Birthday 1988.mov', 'Birthday 1988.mov',
                     'reel_07.MXF', 'Grandma said hello', 'a/b', 'x' * 65, 'tab\there', 'new\nline', 'quote"d'):
            self.assertEqual(cr.word(leak), 'scrubbed', leak)
        self.assertEqual(cr.word(''), 'none')
        self.assertEqual(cr.word(None), 'none')
        self.assertEqual(cr.sha_prefix('ab' * 32), 'abababababab')
        self.assertEqual(cr.sha_prefix('Birthday.mov'), 'scrubbed')
        self.assertEqual(cr.stratum_word('edit list trim/long header'), 'edit_list_trim_long_header')


class PrepareTests(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.scene = CorpusScene(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_the_sealed_catalog_holds_only_the_manifests_rows_with_corpus_paths(self):
        code, lines = cr.prepare(self.scene.seal)
        self.assertEqual(code, 0)
        conn = self.scene.catalog()
        rows = conn.execute('SELECT content_digest, full_path, path_fold, directory, size_bytes, removal_state FROM files').fetchall()
        self.assertEqual(len(rows), 3)
        media = str(self.scene.corpus / 'media')
        for n, original, size, _ in self.scene.files:
            row = next(r for r in rows if r[0] == sha_of(n))
            self.assertEqual(row[1], media + original)
            self.assertEqual(row[2], media.lower() + original.lower())
            self.assertEqual(row[3], media + original.rsplit('/', 1)[0])
            self.assertEqual((row[4], row[5]), (size, None))
            self.assertEqual(os.stat(row[1]).st_size, size)
        self.assertEqual(conn.execute('SELECT count(*) FROM content').fetchone()[0], 3)
        self.assertEqual(conn.execute('SELECT master_archive FROM catalog_state').fetchone()[0], None)
        self.assertEqual(conn.execute('SELECT count(*) FROM user_dates').fetchone()[0], 1)
        self.assertEqual(conn.execute('SELECT count(*) FROM workflow_tags').fetchone()[0], 1)
        for family_text in ('transcripts', 'captions', 'people_tags', 'tombstones', 'import_runs', 'import_items', 'legacy_pair_ids'):
            self.assertEqual(conn.execute(f'SELECT count(*) FROM {family_text}').fetchone()[0], 0, family_text)
        conn.close()
        self.assertIn('GREEN 3 rows for 3 manifest files', lines[0])
        self.assertTrue((self.scene.seal.state / LATCH).is_file())

    def test_pair_links_are_carried_as_the_apps_own_row_knowledge_rows(self):
        # D. The Avid halves read as unpaired: the import evidence cannot be carried (a finished run is
        # refused, an open one names every occurrence), so each link goes in through row_knowledge.
        code, lines = cr.prepare(self.scene.seal)
        conn = self.scene.catalog()
        rows = conn.execute("SELECT f.full_path, k.field, k.value_json, k.source, k.import_run, k.digest = f.content_digest "
                            "FROM row_knowledge k JOIN files f ON f.id = k.file_id ORDER BY f.full_path").fetchall()
        conn.close()
        media = str(self.scene.corpus / 'media')
        self.assertEqual(len(rows), 2, 'one link per paired corpus file; the cleared link and the file outside the corpus are not carried')
        ids = self.scene.ids
        video, other = self.scene.FILES[1][1], self.scene.FILES[2][1]
        want = {media + video: {'pairGroupID': self.scene.GROUP, 'pairedWithID': ids[other]},
                media + other: {'pairGroupID': self.scene.GROUP}}
        for path, field, value, source, import_run, digest_matches in rows:
            self.assertEqual((field, source, import_run, digest_matches), ('pair', 'app:corpus-prepare', None, 1))
            self.assertEqual(json.loads(value), want[path])
        self.assertIn('  pair links carried: 2 (2 from the import, 0 the app\'s own) — 1 pairs with two or more halves in the corpus, '
                      '0 halves whose partner is not in the corpus', lines)
        prepared = json.loads((self.scene.seal.state / 'prepare.json').read_text())
        self.assertEqual((prepared['transform_version'], prepared['counts']['pair_links']), (cr.TRANSFORM_VERSION, 2))

    def test_the_apps_later_word_replaces_the_imports_and_a_lone_half_is_counted(self):
        src = sqlite3.connect(self.scene.source)
        ids = self.scene.ids
        src.execute("INSERT INTO row_knowledge (file_id, field, value_json, set_at, source, generation) VALUES (?, 'pair', ?, 9, 'app:correlate', 3)",
                    (ids[self.scene.FILES[2][1]], json.dumps(dict(pairGroupID='aaaaaaaa-0000-0000-0000-000000000001', pairConfidence='high'))))
        src.execute("INSERT INTO row_knowledge (file_id, field, value_json, set_at, source, generation) VALUES (?, 'pair', 'null', 9, 'app:correlate', 3)",
                    (ids[self.scene.FILES[1][1]],))
        src.commit()
        src.close()
        for leftover in self.scene.corpus.glob(cr.SOURCE_BACKUP + '-*'):
            leftover.unlink()
        _, lines = cr.prepare(self.scene.seal)
        conn = self.scene.catalog()
        rows = conn.execute("SELECT value_json FROM row_knowledge").fetchall()
        conn.close()
        self.assertEqual([json.loads(r[0]) for r in rows], [dict(pairGroupID='aaaaaaaa-0000-0000-0000-000000000001', pairConfidence='high')])
        self.assertIn("pair links carried: 1 (0 from the import, 1 the app's own) — 0 pairs with two or more halves in the corpus, "
                      "1 halves whose partner is not in the corpus", '\n'.join(lines))

    def test_a_lane_refuses_a_sealed_catalog_built_by_an_older_transform(self):
        cr.prepare(self.scene.seal)
        entries = cr.load_manifest(self.scene.seal)
        cr.sealed_state_ready(self.scene.seal, entries)
        record = self.scene.seal.state / 'prepare.json'
        for poison in (json.dumps(dict(json.loads(record.read_text()), transform_version=1)), '{not json', '[]'):
            record.write_text(poison)
            with self.assertRaises(cr.Refused) as refused:
                cr.sealed_state_ready(self.scene.seal, entries)
            self.assertIn('run `scripts/corpus_run.sh prepare`', str(refused.exception))

    def test_the_source_backup_is_never_written(self):
        cr.prepare(self.scene.seal)
        self.assertEqual(hashlib.sha256(self.scene.source.read_bytes()).hexdigest(), self.scene.source_hash)
        self.assertEqual(sorted(p.name for p in self.scene.corpus.iterdir() if p.name.startswith('catalog-source')),
                         [cr.SOURCE_BACKUP], 'a sidecar appeared beside the source backup')

    def test_every_schema_trigger_is_carried_and_still_bites(self):
        cr.prepare(self.scene.seal)
        src = sqlite3.connect(f'file:{self.scene.source}?immutable=1', uri=True)
        want = sorted(r[0] for r in src.execute("SELECT name FROM sqlite_master WHERE type = 'trigger'"))
        src.close()
        copy = pathlib.Path(self.tmp.name, 'writable-copy.sqlite')
        copy.write_bytes((self.scene.seal.state / DB).read_bytes())
        conn = sqlite3.connect(copy)
        self.assertEqual(sorted(r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type = 'trigger'")), want)
        self.assertGreater(len(want), 20)
        with self.assertRaises(sqlite3.DatabaseError) as refused:
            conn.execute('DELETE FROM files')
        self.assertIn('never deleted', str(refused.exception))
        conn.close()

    def test_the_result_is_a_sealed_snapshot_with_nothing_beside_it(self):
        cr.prepare(self.scene.seal)
        header = (self.scene.seal.state / DB).read_bytes()[:100]
        self.assertEqual((header[18], header[19]), (1, 1), 'rollback journal, not WAL: the sealed-snapshot door needs it')
        self.assertEqual(sorted(p.name for p in self.scene.seal.state.iterdir()),
                         sorted([DB, LATCH, 'prepare.json', 'home', 'caches']))
        prepared = json.loads((self.scene.seal.state / 'prepare.json').read_text())
        self.assertEqual((prepared['files'], prepared['verify']['rows'], prepared['verify']['ok']), (3, 3, 1))
        self.assertEqual(prepared['counts']['triggers'], prepared['counts']['source_triggers'])

    def test_prepare_twice_gives_the_same_catalog(self):
        cr.prepare(self.scene.seal)
        first = self.scene.catalog().execute('SELECT * FROM files ORDER BY id').fetchall()
        code, _ = cr.prepare(self.scene.seal)
        self.assertEqual(code, 0)
        self.assertEqual(self.scene.catalog().execute('SELECT * FROM files ORDER BY id').fetchall(), first)

    def refused(self, needle):
        with self.assertRaises(cr.Refused) as refused:
            cr.prepare(self.scene.seal)
        self.assertIn(needle, str(refused.exception))
        for name in SECRET_NAMES:
            self.assertNotIn(name, str(refused.exception))
        state = self.scene.seal.state
        self.assertEqual([p.name for p in state.iterdir() if p.name.startswith('building-')] if state.exists() else [], [],
                         'a refused prepare left its build folder')

    def test_a_missing_or_resized_corpus_file_is_refused_with_counts_only(self):
        (self.scene.corpus / 'media' / self.scene.files[0][1].lstrip('/')).unlink()
        (self.scene.corpus / 'media' / self.scene.files[1][1].lstrip('/')).write_bytes(b'short')
        self.refused('1 corpus files are missing and 1 are not the manifest')

    def test_a_manifest_entry_without_its_one_live_row_is_refused(self):
        self.scene.files.append((40, '/Volumes/PrivateDrive/Grandma/not in the backup.mov', 9, 'raw DV'))
        self.scene.write_documents()
        path = self.scene.corpus / 'media' / self.scene.files[-1][1].lstrip('/')
        path.write_bytes(b'x' * 9)
        self.refused('1 manifest entries do not have exactly one live row')

    def test_the_two_corpus_documents_must_agree(self):
        (self.scene.corpus / cr.SHA_LIST).write_text(f"{sha_of(0)}  media/Volumes/PrivateDrive/elsewhere.mov\n")
        self.refused('disagree on')

    def test_a_backup_with_a_wal_beside_it_is_refused(self):
        pathlib.Path(str(self.scene.source) + '-wal').write_bytes(b'')
        self.refused('not a finished backup')

    def test_a_refused_prepare_leaves_the_last_good_catalog_in_place(self):
        cr.prepare(self.scene.seal)
        before = (self.scene.seal.state / DB).read_bytes()
        (self.scene.corpus / 'media' / self.scene.files[2][1].lstrip('/')).unlink()
        self.refused('1 corpus files are missing')
        self.assertEqual((self.scene.seal.state / DB).read_bytes(), before)

    def test_verify_sees_a_file_that_went_missing_or_changed_size_after_prepare(self):
        cr.prepare(self.scene.seal)
        entries = cr.load_manifest(self.scene.seal)
        self.assertEqual(cr.verify_catalog(self.scene.seal, self.scene.seal.state / DB, entries)['ok'], 1)
        (self.scene.corpus / 'media' / self.scene.files[0][1].lstrip('/')).write_bytes(b'changed')
        (self.scene.corpus / 'media' / self.scene.files[1][1].lstrip('/')).unlink()
        verdict = cr.verify_catalog(self.scene.seal, self.scene.seal.state / DB, entries)
        self.assertEqual((verdict['ok'], verdict['size_differs'], verdict['file_missing']), (0, 1, 1))
        with self.assertRaises(cr.Refused):
            cr.sealed_state_ready(self.scene.seal, entries)


class LaneScene(CorpusScene):
    """The corpus plus a testbed worktree (a real git repo), a DerivedData folder, the
    harness's bin folder and the fake xcodebuild."""

    def __init__(self, tmp, with_proof_engine=False):
        super().__init__(tmp)
        base = pathlib.Path(tmp)
        self.worktree, self.dd, self.out = base / 'testbed', base / 'dd', self.home / 'm4run' / 'out' / '20261117_120000_1-corpus'
        (self.worktree / 'VideoScan' / 'VideoScanTests').mkdir(parents=True)
        (self.worktree / 'VideoScan' / 'VideoScanTests' / 'Existing.swift').write_text('// a test\n')
        if with_proof_engine:
            (self.worktree / 'VideoScan' / 'VideoScan' / 'MediaOps').mkdir(parents=True)
            (self.worktree / 'VideoScan' / 'VideoScan' / 'MediaOps' / 'BalancedCopyProof.swift').write_text('// engine\n')
        env = dict(os.environ, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t', GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@t')
        for command in (['init', '-q'], ['add', '-A'], ['commit', '-q', '-m', 'testbed']):
            subprocess.run(['git', '-C', str(self.worktree), *command], check=True, env=env)
        self.out.mkdir(parents=True)
        self.fake = base / 'fake-xcodebuild'
        self.fake.write_text(FAKE_XCODEBUILD)
        self.fake.chmod(0o755)
        self.plan_path, self.calls = base / 'plan.json', base / 'calls.jsonl'
        self.fake_cp, self.cp_calls = base / 'fake-cp', base / 'cp-calls.jsonl'
        self.fake_cp.write_text(FAKE_CP)
        self.fake_cp.chmod(0o755)
        self.plan = dict(calls=str(self.calls), engines=['probe', 'check', 'audio'], files={})
        cr.prepare(self.seal)

    def run(self, lane='check', sha='a' * 40, stamp='20261117_120000_1', **extra):
        self.plan_path.write_text(json.dumps(self.plan))
        os.environ['FAKE_PLAN'] = str(self.plan_path)
        os.environ['FAKE_CP_CALLS'] = str(self.cp_calls)
        argv = ['host', lane, '--sha', sha, '--stamp', stamp, '--out', str(self.out), '--worktree', str(self.worktree),
                '--derived-data', str(self.dd), '--bin', str(SCRIPTS / 'corpus')]
        for key, value in extra.items():
            argv += ['--' + key, str(value)]
        try:
            return cr.main(argv, seal=self.seal, xcodebuild=str(self.fake), cp=str(self.fake_cp))
        finally:
            os.environ.pop('FAKE_PLAN', None)
            os.environ.pop('FAKE_CP_CALLS', None)

    def report_dir(self, lane='check', sha='a' * 40, stamp='20261117_120000_1'):
        return self.seal.reports / lane / sha / stamp

    def recorded_calls(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def everything_that_leaves(self):
        """The text a caller can read back: the summary, and the stored report files."""
        texts = [(self.out / 'corpus-summary.txt').read_text()]
        for path in self.seal.reports.rglob('report.*'):
            texts.append(path.read_text())
        return '\n'.join(texts)


class LaneTests(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        # `--bin` holds the driver sources AND catalog_db.py on the host; here the two live in scripts/ and scripts/corpus/.
        self.scene = LaneScene(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_a_clean_run_is_green_and_reports_counts_by_stratum_and_format(self):
        self.scene.plan['files'] = {sha_of(1): dict(container='mxf', vcodec='dnxhd', acodec='none', check='Problem',
                                                    check_kinds=['truncation:Problem'], audio='not_checked',
                                                    audio_kinds=['noAudioStream']),
                                    sha_of(2): dict(container='dv', vcodec='dvvideo', acodec='pcm_s16le', check='Warning')}
        self.assertEqual(self.scene.run(), cr.EXIT_GREEN)
        report = json.loads((self.scene.report_dir() / 'report.json').read_text())
        self.assertEqual(report['files'], 3)
        self.assertEqual(report['engines']['check'], {'OK': 1, 'Problem': 1, 'Warning': 1})
        self.assertEqual(report['engines']['audio'], {'OK': 2, 'not_checked': 1})
        self.assertEqual(report['failures'], {})
        self.assertEqual(report['launches'], 1)
        self.assertEqual(report['by_stratum']['Avid_video_half']['check'], {'Problem': 1})
        self.assertEqual(report['by_stratum']['codec_container_combo']['files'], 1)
        self.assertEqual(report['by_format']['mxf | dnxhd | none']['audio'], {'not_checked': 1})
        self.assertEqual(report['seal']['homeSealed'], True)
        outcomes = json.loads((self.scene.report_dir() / 'outcomes.json').read_text())
        self.assertEqual(sorted(outcomes), sorted(sha_of(n) for n in range(3)))
        self.assertEqual(outcomes[sha_of(1)]['outcome'], 'probe=OK check=Problem audio=not_checked pair=not_run')
        self.assertEqual(outcomes[sha_of(1)]['check_kinds'], ['truncation:Problem'])
        summary = (self.scene.out / 'corpus-summary.txt').read_text()
        self.assertIn('corpus check: GREEN 3 files', summary)
        self.assertIn('check: OK 1, Problem 1, Warning 1', summary)
        self.assertIn('Avid_video_half (1)', summary)

    def test_the_test_host_is_launched_sealed(self):
        self.scene.run()
        calls = self.scene.recorded_calls()
        build, test, driver = calls[0], calls[1], calls[2]
        self.assertEqual(build['args'][0], 'build-for-testing')
        self.assertEqual(build['home'], os.environ.get('HOME', ''), 'the build keeps the real HOME (Metal toolchain)')
        self.assertEqual(test['args'][0], 'test-without-building')
        self.assertIn('-only-testing:VideoScanTests/CorpusCheckDriver', test['args'])
        state = str(self.scene.seal.state)
        self.assertEqual(test['home'], state + '/home')
        env = driver['driver_env']
        self.assertEqual((env['HOME'], env['CFFIXED_USER_HOME']), (state + '/home', state + '/home'))
        self.assertTrue(env['VS_CORPUS_CONFIG'].startswith(str(self.scene.seal.work_root) + '/'))
        self.assertEqual(env['KEPT'], '1', "the build's own environment entries survive the patch")
        self.assertEqual(driver['target'], 'VideoScanTests', 'the newest .xctestrun was a UI plan with no unit-test target')
        self.assertNotIn('SkipTestIdentifiers', driver['target_keys'])
        self.assertNotIn('OS_ACTIVITY_DT_MODE', env, "the engines' os_log lines name files; they stay out of the test log")
        self.assertIn('-test-timeouts-enabled', test['args'])

    def test_a_crash_in_one_file_does_not_stop_the_run(self):
        self.scene.plan['files'] = {sha_of(1): dict(crash='check')}
        self.assertEqual(self.scene.run(), cr.EXIT_RED)
        report = json.loads((self.scene.report_dir() / 'report.json').read_text())
        self.assertEqual(report['engines']['check'], {'OK': 2, 'crash': 1})
        self.assertEqual(report['engines']['probe'], {'OK': 3})
        self.assertEqual(report['engines']['audio'], {'OK': 2, 'not_run': 1})
        self.assertEqual(report['failures'], {'check:crash': 1})
        self.assertGreaterEqual(report['launches'], 2, 'the files after the crash need a second launch')
        self.assertIn('corpus check: RED 3 files', (self.scene.out / 'corpus-summary.txt').read_text())
        self.assertIn('check:crash 1 — 1 crashed or timed out: RED', (self.scene.out / 'corpus-summary.txt').read_text())

    def test_a_file_past_its_deadline_is_recorded_and_the_rest_still_run(self):
        self.scene.plan['files'] = {sha_of(0): dict(timeout='probe'), sha_of(2): dict(timeout='audio')}
        self.assertEqual(self.scene.run(deadline=7), cr.EXIT_RED)
        report = json.loads((self.scene.report_dir() / 'report.json').read_text())
        self.assertEqual(report['failures'], {'probe:timeout': 1, 'audio:timeout': 1})
        self.assertEqual(report['engines']['check'], {'OK': 2, 'not_run': 1})
        self.assertEqual(report['deadline_s'], 7)
        self.assertIn(report['launches'], (2, 3))

    def test_every_file_crashing_still_ends(self):
        self.scene.plan['files'] = {sha_of(n): dict(crash='probe') for n in range(3)}
        self.assertEqual(self.scene.run(), cr.EXIT_RED)
        report = json.loads((self.scene.report_dir() / 'report.json').read_text())
        self.assertEqual((report['engines']['probe'], report['launches']), ({'crash': 3}, 3))

    def test_a_driver_that_refuses_or_never_starts_is_red_not_a_loop(self):
        self.scene.plan['refuse'] = 'home_not_sealed'
        self.assertEqual(self.scene.run(), cr.EXIT_REFUSED)
        self.assertIn('refused by the driver: home_not_sealed', (self.scene.out / 'corpus-summary.txt').read_text())
        del self.scene.plan['refuse']
        self.scene.plan['silent'] = True
        self.assertEqual(self.scene.run(stamp='20261117_120500_1'), cr.EXIT_REFUSED)
        self.assertIn('started no file', (self.scene.out / 'corpus-summary.txt').read_text())
        self.assertEqual(sum(1 for c in self.scene.recorded_calls() if c.get('args', [''])[0] == 'test-without-building'), 2)

    def test_a_driver_that_does_not_build_is_red_and_runs_nothing(self):
        self.scene.plan['build_fails'] = True
        self.assertEqual(self.scene.run(), cr.EXIT_RED)
        self.assertIn('RED the driver did not build against aaaaaaaaa', (self.scene.out / 'corpus-summary.txt').read_text())
        self.assertFalse((self.scene.seal.reports / 'check').exists())

    def test_the_testbed_and_the_work_folder_are_left_clean(self):
        self.scene.plan['files'] = {sha_of(1): dict(crash='check')}
        self.scene.run()
        self.assertFalse((self.scene.worktree / cr.OVERLAY_DIR).exists(), 'the overlay stayed in the testbed')
        status = subprocess.run(['git', '-C', str(self.scene.worktree), 'status', '--porcelain'], capture_output=True, text=True)
        self.assertEqual(status.stdout.strip(), '')
        self.assertEqual(list(self.scene.seal.work_root.iterdir()), [], 'the run left working files')
        self.assertEqual([p.name for p in (self.scene.dd / 'Build' / 'Products').glob('corpus-*')], [])
        kept = sorted(p.name for p in self.scene.report_dir().iterdir())
        self.assertEqual(kept[:3], ['outcomes.json', 'progress-1.jsonl', 'progress-2.jsonl'])
        self.assertTrue(any(p.name.startswith('overlay-') for p in self.scene.out.iterdir()), 'the overlay is moved out, not deleted')

    def test_a_stale_overlay_from_a_dead_run_is_moved_aside_first(self):
        stale = self.scene.worktree / cr.OVERLAY_DIR
        stale.mkdir(parents=True)
        (stale / 'Old.swift').write_text('this would not compile')
        self.assertEqual(self.scene.run(), cr.EXIT_GREEN)
        self.assertFalse(stale.exists())
        self.assertEqual(len([p for p in self.scene.out.iterdir() if p.name.startswith('overlay-')]), 2)

    def test_a_ref_that_tracks_the_overlay_folder_is_refused(self):
        overlay = self.scene.worktree / cr.OVERLAY_DIR
        overlay.mkdir(parents=True)
        (overlay / 'Tracked.swift').write_text('// tracked\n')
        env = dict(os.environ, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t', GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@t')
        subprocess.run(['git', '-C', str(self.scene.worktree), 'add', '-A'], check=True, env=env)
        subprocess.run(['git', '-C', str(self.scene.worktree), 'commit', '-q', '-m', 'tracks it'], check=True, env=env)
        self.assertEqual(self.scene.run(), cr.EXIT_REFUSED)
        self.assertTrue((overlay / 'Tracked.swift').exists(), 'a tracked file was moved')

    def test_a_lane_refuses_until_prepare_has_built_the_sealed_state(self):
        (self.scene.seal.state / DB).unlink()
        self.assertEqual(self.scene.run(), cr.EXIT_REFUSED)
        self.assertIn('prepare', (self.scene.out / 'corpus-summary.txt').read_text())
        self.assertEqual(self.scene.recorded_calls(), [], 'nothing was built or launched')

    def test_limit_runs_the_first_n_files_by_content(self):
        self.assertEqual(self.scene.run(limit=2), cr.EXIT_GREEN)
        outcomes = json.loads((self.scene.report_dir() / 'outcomes.json').read_text())
        self.assertEqual(sorted(outcomes), sorted(sha_of(n) for n in range(3))[:2])

    def test_nothing_a_caller_reads_back_names_a_file_or_a_path(self):
        self.scene.plan['files'] = {
            sha_of(0): dict(check='error:/Users/x/corpus/media/Volumes/PrivateDrive/Grandma/Birthday 1988.mov',
                            check_kinds=['Lake House/reel_07.MXF'], container='Grandma Birthday.mov'),
            sha_of(1): dict(crash='audio')}
        self.scene.run()
        text = self.scene.everything_that_leaves()
        for name in SECRET_NAMES:
            self.assertNotIn(name, text, name)
            self.assertNotIn(name.replace(' ', '_'), text, name)
        self.assertIn('scrubbed', text)
        self.assertNotIn('/Volumes', text)
        self.assertNotIn(str(self.scene.corpus), text)
        self.assertNotIn('.mov', text.lower())
        summary = (self.scene.out / 'corpus-summary.txt').read_text()
        for n in range(3):
            self.assertNotIn(sha_of(n), summary, 'a check summary lists no file at all')

    def test_bad_sha_or_stamp_is_refused(self):
        self.assertEqual(self.scene.run(sha='../../etc'), cr.EXIT_REFUSED)
        self.assertEqual(self.scene.run(stamp='../x'), cr.EXIT_REFUSED)
        self.assertFalse(self.scene.seal.reports.exists())


class ProofLaneTests(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()

    def test_a_ref_without_the_engine_says_so_and_builds_nothing(self):
        scene = LaneScene(self.tmp.name)
        scene.plan['engines'] = ['balance', 'proof']
        self.assertEqual(scene.run('proof'), cr.EXIT_NORUN, 'a lane that ran nothing is NORUN, never a pass')
        self.assertEqual(json.loads((scene.out / cr.VERDICT_FILE).read_text())['verdict'], 'NORUN')
        summary = (scene.out / 'corpus-summary.txt').read_text()
        self.assertIn('corpus proof: NOT RUN at aaaaaaaaa — this ref has no balanced-copy proof engine', summary)
        self.assertEqual(scene.recorded_calls(), [])
        report = json.loads((scene.report_dir('proof') / 'report.json').read_text())
        self.assertEqual((report['engine_present'], report['files']), (False, 0))
        self.assertIn('NOT RUN', '\n'.join(cr.status(scene.seal)))

    def test_with_the_engine_it_runs_the_one_sided_files_and_lists_them_by_sha_prefix(self):
        scene = LaneScene(self.tmp.name, with_proof_engine=True)
        scene.plan['engines'] = ['balance', 'proof']
        scene.plan['files'] = {sha_of(0): dict(balance='balanced', balance_kinds=['leftOnly'], proof='same_content',
                                               proof_kinds=['metadata', 'track'], container='dv', vcodec='dvvideo',
                                               acodec='pcm_s16le')}
        self.assertEqual(scene.run('proof'), cr.EXIT_GREEN)
        report = json.loads((scene.report_dir('proof') / 'report.json').read_text())
        self.assertEqual((report['files'], report['deadline_s']), (1, 3600))
        self.assertEqual(report['engines'], {'balance': {'balanced': 1}, 'proof': {'same_content': 1}})
        calls = scene.recorded_calls()
        self.assertIn('-only-testing:VideoScanTests/CorpusProofDriver', calls[1]['args'])
        self.assertEqual((calls[2]['pending'], calls[2]['lane']), (1, 'proof'))
        summary = (scene.out / 'corpus-summary.txt').read_text()
        self.assertIn(f'{sha_of(0)[:12]} dv/dvvideo/pcm_s16le: balance=balanced proof=same_content '
                      'balance[leftOnly] proof[metadata,track] (wall balance=0s proof=0s)', summary)
        self.assertNotIn(sha_of(0), summary, 'the prefix only')
        for name in SECRET_NAMES:
            self.assertNotIn(name, summary)


class StatusTests(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.scene = LaneScene(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_status_before_and_after_the_first_run(self):
        text = '\n'.join(cr.status(self.scene.seal))
        self.assertIn('corpus: prepared', text)
        self.assertIn('3 rows, 3 files', text)
        self.assertIn('corpus check: no run yet', text)
        self.scene.run()
        text = '\n'.join(cr.status(self.scene.seal))
        self.assertIn('newest check run: 20261117_120000_1', text)
        self.assertIn('  baseline: this run (the lane has no earlier whole clean run to compare with)', text)
        self.assertIn('corpus check: GREEN 3 files', text)
        self.assertLess(text.index('  probe:'), text.index('  check:'), "engines read in the lane's order")
        self.assertLess(text.index('  check:'), text.index('  audio:'))

    def test_status_shows_what_changed_as_counts_and_transitions_only(self):
        self.scene.run()
        self.scene.plan['files'] = {sha_of(1): dict(check='Problem'), sha_of(2): dict(audio='damaged', check='Problem')}
        self.scene.run(sha='b' * 40, stamp='20261118_090000_2')
        lines = cr.status(self.scene.seal)
        text = '\n'.join(lines)
        self.assertIn('newest check run: 20261118_090000_2', text)
        self.assertIn('corpus check: AMBER 3 files', text)
        self.assertIn('against its first run (no baseline accepted yet) 20261117_120000_1 at aaaaaaaaa: 2 of 3 files changed', text)
        self.assertIn('    check: OK -> Problem x2', lines)
        self.assertIn('    audio: OK -> damaged x1', lines)
        self.assertIn(f'    {sha_of(1)[:12]} check: OK -> Problem', lines)
        self.assertIn(f'    {sha_of(2)[:12]} check: OK -> Problem; audio: OK -> damaged', lines)
        for n in range(3):
            self.assertNotIn(sha_of(n)[:13], text, 'a SHA-256 prefix only, never the whole digest')
        for name in SECRET_NAMES:
            self.assertNotIn(name, text)

    def test_status_is_refused_off_the_m4(self):
        with self.assertRaises(cr.Refused):
            cr.status(cr.Seal(self.scene.home, 'ricksultra'))

    def test_status_with_no_prepare_says_so(self):
        (self.scene.seal.state / 'prepare.json').write_text('{not json')            # poisoned
        self.assertIn('not prepared', cr.status(self.scene.seal)[0])


class BaselineTests(unittest.TestCase):
    """B. The verdict of a corpus lane is its diff against the baseline."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.scene = LaneScene(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def summary(self):
        return (self.scene.out / 'corpus-summary.txt').read_text()

    def facts(self):
        return json.loads((self.scene.out / cr.VERDICT_FILE).read_text())

    def test_the_first_run_is_its_own_baseline_and_green(self):
        self.scene.plan['files'] = {sha_of(1): dict(check='error:couldNotRead', audio='error:probeFailed')}
        self.assertEqual(self.scene.run(), cr.EXIT_GREEN, "an engine's own error word is an outcome, not a lane failure")
        self.assertIn('corpus check: GREEN 3 files', self.summary())
        self.assertIn('  baseline: this run', self.summary())
        self.assertEqual((self.facts()['verdict'], self.facts()['against']), ('GREEN', None))

    def test_a_moved_outcome_word_is_amber_and_the_file_is_listed_by_sha_prefix(self):
        self.scene.run()
        self.scene.plan['files'] = {sha_of(1): dict(check='Problem'), sha_of(2): dict(audio='damaged', check='Problem')}
        self.assertEqual(self.scene.run(sha='b' * 40, stamp='20261118_090000_2'), cr.EXIT_AMBER)
        lines = self.summary().splitlines()
        self.assertTrue(lines[0].startswith('corpus check: AMBER 3 files'), lines[0])
        self.assertIn('  against its first run (no baseline accepted yet) 20261117_120000_1 at aaaaaaaaa: 2 of 3 files changed '
                      '(new in this run 0, not in this run 0)', lines)
        self.assertIn(f'    {sha_of(1)[:12]} check: OK -> Problem', lines)
        self.assertIn(f'    {sha_of(2)[:12]} check: OK -> Problem; audio: OK -> damaged', lines)
        against = self.facts()['against']
        self.assertEqual((self.facts()['verdict'], against['changed'], against['compared']), ('AMBER', 2, 3))
        self.assertEqual(against['transitions'], {'check: OK -> Problem': 2, 'audio: OK -> damaged': 1})
        self.assertEqual(sorted(against['listed']), sorted([f'{sha_of(1)[:12]} check: OK -> Problem',
                                                            f'{sha_of(2)[:12]} check: OK -> Problem; audio: OK -> damaged']))
        leaves = self.summary() + (self.scene.out / cr.VERDICT_FILE).read_text()
        for n in range(3):
            self.assertNotIn(sha_of(n)[:13], leaves, 'only the prefix leaves the M4')
        for name in SECRET_NAMES:
            self.assertNotIn(name, leaves)
        stored = json.loads((self.scene.report_dir(sha='b' * 40, stamp='20261118_090000_2') / 'report.json').read_text())
        self.assertEqual(sorted(c[0] for c in stored['against']['changes']), sorted([sha_of(1), sha_of(2)]),
                         'the whole list stays in the report on the M4')

    def test_a_known_error_word_unchanged_is_green_and_a_change_of_kinds_alone_is_only_noted(self):
        self.scene.plan['files'] = {sha_of(0): dict(check='error:couldNotRead'), sha_of(1): dict(check_kinds=['a:Warning'])}
        self.scene.run()
        self.scene.plan['files'][sha_of(1)] = dict(check_kinds=['b:Warning'])
        self.assertEqual(self.scene.run(stamp='20261118_090000_2'), cr.EXIT_GREEN)
        self.assertIn('0 of 3 files changed', self.summary())
        self.assertIn('finding kinds moved in 1 files whose outcome words did not (not part of the verdict)', self.summary())

    def test_a_crash_or_a_deadline_is_red_whatever_the_baseline_holds(self):
        self.scene.run()
        for how, stamp in ((dict(crash='audio'), '20261118_090000_2'), (dict(timeout='check'), '20261118_100000_3')):
            self.scene.plan['files'] = {sha_of(1): how}
            self.assertEqual(self.scene.run(stamp=stamp), cr.EXIT_RED)
            self.assertTrue(self.summary().startswith('corpus check: RED 3 files'), self.summary())
            self.assertEqual(self.facts()['verdict'], 'RED')
            self.assertIn('1 files crashed an engine or ran past the deadline: RED', self.facts()['notes'])
        with self.assertRaises(cr.Refused) as refused:
            cr.accept(self.scene.seal, 'check', 'someone')
        self.assertIn('a RED run is never the baseline', str(refused.exception))
        self.assertFalse((self.scene.seal.reports / 'check' / cr.BASELINE).exists())
        # A crashed run is never the implicit baseline either: the next clean run is judged against the first.
        self.scene.plan['files'] = {}
        self.assertEqual(self.scene.run(stamp='20261118_110000_4'), cr.EXIT_GREEN)
        self.assertIn('against its first run (no baseline accepted yet) 20261117_120000_1', self.summary())
        self.assertIn('since the previous run 20261118_100000_3 at aaaaaaaaa: 1 of 3 files changed', self.summary())

    def test_accept_blesses_the_newest_run_and_records_who_when_and_which(self):
        self.scene.run()
        self.scene.plan['files'] = {sha_of(1): dict(check='Problem')}
        self.assertEqual(self.scene.run(sha='b' * 40, stamp='20261118_090000_2'), cr.EXIT_AMBER)
        lines = cr.accept(self.scene.seal, 'check', 'rickb@RicksUltra')
        self.assertRegex(lines[0], r'^corpus check: the baseline is now run 20261118_090000_2 at bbbbbbbbb \(3 files\) — accepted '
                                   r'\d{4}-\d\d-\d\d \d\d:\d\d:\d\d by rickb@RicksUltra; the lane had no accepted baseline before$')
        record = json.loads((self.scene.seal.reports / 'check' / cr.BASELINE).read_text())
        run = self.scene.report_dir(sha='b' * 40, stamp='20261118_090000_2')
        self.assertEqual((record['run'], record['sha'], record['accepted_by'], record['files']),
                         ('20261118_090000_2', 'b' * 40, 'rickb@RicksUltra', 3))
        self.assertEqual(record['outcomes_sha256'], hashlib.sha256((run / 'outcomes.json').read_bytes()).hexdigest())
        # The same run, judged now: nothing moved against the baseline it has become.
        text = '\n'.join(cr.status(self.scene.seal))
        self.assertIn('corpus check: GREEN 3 files', text)
        self.assertRegex(text, r'against its accepted baseline 20261118_090000_2 at bbbbbbbbb \(accepted \S+ by rickb@RicksUltra\): 0 of 3')
        # A later run is held to the accepted one, not to the first.
        self.scene.plan['files'] = {}
        self.assertEqual(self.scene.run(sha='c' * 40, stamp='20261119_090000_3'), cr.EXIT_AMBER)
        self.assertIn(f'    {sha_of(1)[:12]} check: Problem -> OK', self.summary().splitlines())
        self.assertEqual(self.facts()['against']['what'], 'its accepted baseline')
        again = cr.accept(self.scene.seal, 'check', 'night worker')
        self.assertIn('by night_worker; it replaces 20261118_090000_2', again[0])
        history = [json.loads(line) for line in (self.scene.seal.reports / 'check' / cr.BASELINE_LOG).read_text().splitlines()]
        self.assertEqual([h['run'] for h in history], ['20261118_090000_2', '20261119_090000_3'])
        self.assertEqual(sorted(p.name for p in (self.scene.seal.reports / 'check').iterdir() if p.is_file()),
                         [cr.BASELINE_LOG, cr.BASELINE], 'accept left a pending file')

    def test_accept_refuses_what_is_not_a_whole_clean_run(self):
        seal = self.scene.seal
        for lane, needle in (('check', 'has no run to accept'), ('verbs?', 'accept wants one of'), ('../state', 'accept wants one of')):
            with self.subTest(lane=lane), self.assertRaises(cr.Refused) as refused:
                cr.accept(seal, lane, 'x')
            self.assertIn(needle, str(refused.exception))
        self.assertEqual(self.scene.run(limit=2), cr.EXIT_GREEN)
        self.assertIn('limited to 2 files', self.summary())
        with self.assertRaises(cr.Refused) as refused:
            cr.accept(seal, 'check', 'x')
        self.assertIn('a partial run is never the baseline', str(refused.exception))
        self.scene.plan['engines'] = ['balance', 'proof']
        self.assertEqual(self.scene.run('proof'), cr.EXIT_NORUN)
        with self.assertRaises(cr.Refused) as refused:
            cr.accept(seal, 'proof', 'x')
        self.assertIn('did not run', str(refused.exception))
        with self.assertRaises(cr.Refused):
            cr.accept(cr.Seal(self.scene.home, 'ricksultra'), 'check', 'x')
        self.assertFalse(list(seal.reports.rglob(cr.BASELINE)))

    def test_a_partial_run_is_never_the_implicit_baseline(self):
        self.scene.run(limit=1)
        self.scene.plan['files'] = {sha_of(n): dict(check='Problem') for n in range(3)}
        self.assertEqual(self.scene.run(stamp='20261118_090000_2'), cr.EXIT_GREEN)
        self.assertIn('  baseline: this run', self.summary())

    def test_a_poisoned_baseline_is_red_never_a_pass_and_never_a_traceback(self):
        self.scene.run()
        cr.accept(self.scene.seal, 'check', 'x')
        record_path = self.scene.seal.reports / 'check' / cr.BASELINE
        good = record_path.read_text()
        outcomes = self.scene.report_dir() / 'outcomes.json'
        kept = outcomes.read_text()
        poisons = [('{not json', None), ('[]', None), (json.dumps(dict(run='../../state', sha='a' * 40, outcomes_sha256='0')), None),
                   (json.dumps(dict(json.loads(good), run='20990101_000000_9')), None), (good, kept.replace('"OK"', '"Problem"', 1)),
                   (good, '[1, 2]'),
                   # a record that walks back to a real run by a path: the names are a commit and a stamp, never a path
                   (json.dumps(dict(json.loads(good), run='../' + 'a' * 40 + '/20261117_120000_1')), None)]
        for n, (record, edited) in enumerate(poisons):
            with self.subTest(poison=n):
                record_path.write_text(record)
                outcomes.write_text(kept if edited is None else edited)
                self.assertEqual(self.scene.run(stamp=f'20261118_09000{n}_2'), cr.EXIT_RED)
                self.assertIn('corpus check: RED 3 files', self.summary())
                self.assertIn('baseline: the accepted baseline of check cannot be read back', self.summary())
                self.assertEqual(self.facts()['verdict'], 'RED')
                self.assertIn('RED', '\n'.join(cr.status(self.scene.seal)))
        record_path.write_text(good)
        outcomes.write_text(kept)
        self.assertEqual(self.scene.run(stamp='20261118_100000_2'), cr.EXIT_GREEN)

    def test_a_long_list_of_changes_is_capped_in_what_leaves_and_whole_in_the_report(self):
        engines = ['probe', 'check', 'audio']
        old = {sha_of(n): dict(probe='probed', check='OK', audio='healthy') for n in range(500)}
        new = {sha: dict(record, check='Problem') for sha, record in old.items()}
        first = self.scene.seal.reports / 'check' / ('a' * 40) / '20261117_120000_1'
        first.mkdir(parents=True)
        (first / 'outcomes.json').write_text(json.dumps(old))
        (first / 'report.json').write_text(json.dumps(dict(lane='check', sha='a' * 40, failures={}, engine_present=True)))
        against = cr.against_baseline(self.scene.seal, 'check', new, engines)
        self.assertEqual((against['changed'], len(against['listed']), against['listed_more'], len(against['changes'])),
                         (500, cr.LISTED, 500 - cr.LISTED, 500))
        text = cr.against_lines(against)
        self.assertLess(len(text), cr.LISTED + 6)
        self.assertIn(f'    … +{500 - cr.LISTED} more files (the whole list is in the run\'s report.json on the M4)', text)

    def test_the_command_line_accepts_and_scrubs_the_name(self):
        self.scene.run()
        code = cr.main(['accept', 'check', '--by', 'Grandma/../Birthday 1988.mov'], seal=self.scene.seal)
        self.assertEqual(code, cr.EXIT_GREEN)
        record = json.loads((self.scene.seal.reports / 'check' / cr.BASELINE).read_text())
        self.assertEqual(record['accepted_by'], 'Grandma____Birthday_1988_mov', 'nothing shaped like a file name')
        self.assertEqual(cr.main(['accept', 'proof', '--by', 'x'], seal=self.scene.seal), cr.EXIT_REFUSED)
        self.assertEqual(cr.main(['accept', 'check'], seal=cr.Seal(self.scene.home, 'ricksultra')), cr.EXIT_REFUSED)

    def test_the_front_door_accepts_through_ssh_with_the_helper_on_stdin(self):
        p = subprocess.run(['/bin/bash', str(SCRIPTS / 'corpus_run.sh'), 'accept', 'proof', '--dry-run'],
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertRegex(p.stdout, r'^\+ ssh ricksm4\.local python3 - accept proof --by [A-Za-z0-9_.@-]+ < \S+/scripts/corpus_run\.py\n$')


VERBS = ['group', 'trash_copy', 'dedupe', 'trash_last', 'purge', 'set_aside', 'promote', 'intact']


class VerbsLaneTests(unittest.TestCase):
    """C. The destructive verbs run on clones under the run's work folder; ~/corpus/media is proven untouched."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.scene = LaneScene(self.tmp.name)
        self.scene.plan['engines'] = VERBS
        self.media = self.scene.corpus / 'media'
        self.before = {p: (p.stat().st_size, p.stat().st_mtime_ns, p.read_bytes()) for p in self.media.rglob('*') if p.is_file()}

    def tearDown(self):
        self.tmp.cleanup()

    def summary(self):
        return (self.scene.out / 'corpus-summary.txt').read_text()

    def driver_call(self):
        return next(c for c in self.scene.recorded_calls() if 'driver_env' in c)

    def test_the_sample_is_cloned_and_the_catalog_names_only_the_clones(self):
        self.assertEqual(self.scene.run('verbs'), cr.EXIT_GREEN, self.summary())
        work = self.scene.seal.work_root / '20261117_120000_1-verbs'
        call = self.driver_call()
        config = call['config']
        self.assertEqual(config['lane'], 'verbs')
        for key in ('volRoot', 'archiveRoot', 'scratch', 'catalog', 'progress'):
            self.assertTrue(config[key].startswith(str(work) + '/'), key)
        roles = sorted(item['role'] for item in config['pending'])
        self.assertEqual(roles, ['dup', 'purge', 'set_aside'])
        vol = config['volRoot']
        for item in config['pending']:
            self.assertTrue(item['path'].startswith(vol + '/Volumes/PrivateDrive/'), 'a clone keeps its place under the volume folder')
            self.assertEqual(len(item['copies']), cr.VERBS_COPIES if item['role'] == 'dup' else 0)
            for copy in item['copies']:
                self.assertTrue(copy.startswith(vol + '/Copies/copy'))
        self.assertEqual(call['rows'], sorted(item['path'] for item in config['pending']), 'the catalog names the clones and nothing else')
        self.assertTrue(call['clones_exist'])
        self.assertNotIn(str(self.media), json.dumps(config['pending']), 'no engine is handed a path under ~/corpus/media')
        # The test host's HOME is inside the run: nothing an engine remembers outlives it.
        self.assertEqual(call['driver_env']['HOME'], str(work / 'home'))
        self.assertTrue(call['driver_env']['TMPDIR'].startswith(str(work) + '/'), "the engines' Trash is under TMPDIR")
        self.assertIn('-only-testing:VideoScanTests/CorpusVerbsDriver', self.scene.recorded_calls()[1]['args'])

    def test_every_clone_is_cp_c_from_media_into_the_work_folder(self):
        self.scene.run('verbs')
        calls = [json.loads(line) for line in self.scene.cp_calls.read_text().splitlines()]
        self.assertEqual(len(calls), 3 + cr.VERBS_COPIES)
        for args in calls:
            self.assertEqual(args[:2], ['-c', '-p'], 'a clone (copy-on-write), times kept')
            self.assertTrue(args[2].startswith(str(self.media) + '/'))
            self.assertTrue(args[3].startswith(str(self.scene.seal.work_root) + '/'))

    def test_media_is_untouched_the_work_folder_is_gone_and_the_report_is_counts(self):
        self.scene.plan['files'] = {sha_of(0): dict(group='grouped', dedupe='trashed:1', trash_last='only_copy_warned:held',
                                                    intact='in_trash_intact:2,intact:1'),
                                    sha_of(1): dict(purge='purged,rescan:stayed_removed', intact='intact:1'),
                                    sha_of(2): dict(set_aside='set_aside,rescan:came_back', intact='intact:1')}
        self.scene.plan['trash_files'] = 2
        self.assertEqual(self.scene.run('verbs'), cr.EXIT_GREEN, self.summary())
        after = {p: (p.stat().st_size, p.stat().st_mtime_ns, p.read_bytes()) for p in self.media.rglob('*') if p.is_file()}
        self.assertEqual(after, self.before)
        self.assertEqual(list(self.scene.seal.work_root.iterdir()), [], 'the run left its clones behind')
        text = self.summary()
        self.assertIn('corpus verbs: GREEN 3 files', text)
        self.assertIn('corpus media sweep (size, mtime, flags, links and inode of 3 files, before and after): 0 changed, file count +0 — untouched', text)
        self.assertIn(f'clones: {3 + cr.VERBS_COPIES} (roles: dup 1, purge 1, set_aside 1)', text)
        self.assertIn("the run's own Trash folder (under its work folder; never the Finder Trash): 2 files, the engines reported moving 2; "
                      "files found in the app's own test-host Trash outside the run: 0", text)
        self.assertIn('  by role:', text)
        self.assertIn('    set_aside (1): ', text)
        self.assertNotIn('by container', text)
        report = json.loads((self.scene.report_dir('verbs') / 'report.json').read_text())
        self.assertEqual(report['engines']['purge'], {'purged,rescan:stayed_removed': 1, 'OK': 2})
        self.assertEqual(report['media'], dict(swept=3, changed=0, files_delta=0))
        self.assertRegex(text, r'(?m)^    [0-9a-f]{12} (dup|purge|set_aside): group=')
        self.assertIn('set_aside=set_aside,rescan:came_back', text)
        leaves = self.scene.everything_that_leaves() + (self.scene.out / cr.VERDICT_FILE).read_text()
        for name in SECRET_NAMES:
            self.assertNotIn(name, leaves)
        self.assertNotIn('/Volumes', leaves)
        self.assertNotIn(str(self.scene.corpus), leaves)

    def test_an_engine_that_touches_the_pristine_corpus_turns_the_lane_red(self):
        victim = self.media / self.scene.files[1][1].lstrip('/')
        self.scene.plan['vandal'] = str(victim)
        self.assertEqual(self.scene.run('verbs'), cr.EXIT_RED)
        text = self.summary()
        self.assertIn('corpus verbs: RED 3 files', text)
        self.assertIn('1 changed, file count +0 — RED: ~/corpus/media was touched', text)
        self.assertEqual(json.loads((self.scene.out / cr.VERDICT_FILE).read_text())['verdict'], 'RED')
        with self.assertRaises(cr.Refused):
            cr.accept(self.scene.seal, 'verbs', 'x')

    def test_a_clone_that_left_the_run_through_the_apps_own_trash_call_is_red(self):
        self.scene.plan['stray'] = 1
        self.assertEqual(self.scene.run('verbs'), cr.EXIT_RED)
        self.assertIn("files found in the app's own test-host Trash outside the run: 1", self.summary())
        self.assertIn('trash:LOST_outside_the_run 1', self.summary())

    def test_a_file_added_under_media_is_seen_by_the_sweep(self):
        entries = cr.load_manifest(self.scene.seal)
        before = cr.media_sweep(self.scene.seal, entries)
        (self.media / 'Volumes' / 'PrivateDrive' / 'stray.bin').write_bytes(b'x')
        after = cr.media_sweep(self.scene.seal, entries)
        self.assertEqual(after['files'][0] - before['files'][0], 1)
        (self.media / self.scene.files[0][1].lstrip('/')).unlink()
        self.assertEqual(cr.media_sweep(self.scene.seal, entries)[sha_of(0)], (-1, -1))
        # What size and mtime cannot see: a second name for the file (a hard link out of media), and its flags.
        victim = self.media / self.scene.files[1][1].lstrip('/')
        seen = cr.media_sweep(self.scene.seal, entries)[sha_of(1)]
        os.link(victim, pathlib.Path(self.tmp.name, 'second-name'))
        self.assertNotEqual(cr.media_sweep(self.scene.seal, entries)[sha_of(1)], seen, 'a hard link to a corpus file went unseen')
        os.unlink(pathlib.Path(self.tmp.name, 'second-name'))
        self.assertEqual(cr.media_sweep(self.scene.seal, entries)[sha_of(1)], seen)
        if sys.platform == 'darwin':
            os.chflags(victim, 0x2)
            self.assertNotEqual(cr.media_sweep(self.scene.seal, entries)[sha_of(1)], seen, 'a changed file flag went unseen')
            os.chflags(victim, 0)

    def test_a_lost_or_changed_clone_is_red(self):
        for word, stamp in (('LOST:1,intact:2', '20261118_090000_2'), ('MISMATCH:1', '20261118_100000_3')):
            self.scene.plan['files'] = {sha_of(0): dict(intact=word)}
            self.assertEqual(self.scene.run('verbs', stamp=stamp), cr.EXIT_RED)
            self.assertIn('corpus verbs: RED 3 files', self.summary())
            self.assertIn(f'intact:{word} 1', self.summary())

    def test_a_clone_is_only_ever_made_from_media_into_this_runs_work_folder(self):
        seal = self.scene.seal
        lane = cr.VerbsLane(seal, 'verbs', 'a' * 40, 's1', self.scene.out, self.scene.worktree, self.scene.dd,
                            SCRIPTS / 'corpus', cp=str(self.scene.fake_cp))
        os.environ['FAKE_CP_CALLS'] = str(self.scene.cp_calls)
        try:
            source = self.media / self.scene.files[0][1].lstrip('/')
            seal.mkdir(lane.work)
            os.symlink(self.media, lane.work / 'sneak')
            for bad_source, bad_dest in ((source, self.media / 'Volumes' / 'PrivateDrive' / 'copy.mov'),
                                         (source, self.scene.home / 'elsewhere.mov'),
                                         (source, lane.work / 'sneak' / 'Volumes' / 'copy.mov'),
                                         (source, self.scene.corpus / cr.SOURCE_BACKUP),
                                         (self.scene.corpus / cr.SOURCE_BACKUP, lane.work / 'vol' / 'x'),
                                         (lane.work / 'vol' / 'a', source)):
                with self.subTest(dest=str(bad_dest)), self.assertRaises(cr.Refused):
                    lane.clone(bad_source, bad_dest)
            self.assertFalse(self.scene.cp_calls.exists(), 'a refused clone ran cp')
            lane.clone(source, lane.work / 'vol' / 'ok.mov')
            self.assertEqual((lane.work / 'vol' / 'ok.mov').read_bytes(), source.read_bytes())
        finally:
            os.environ.pop('FAKE_CP_CALLS', None)

    def test_too_little_free_space_refuses_before_any_clone(self):
        real = cr.shutil.disk_usage
        cr.shutil.disk_usage = lambda path: type('U', (), dict(free=cr.VERBS_FREE_FLOOR - 1, total=1, used=1))()
        try:
            self.assertEqual(self.scene.run('verbs'), cr.EXIT_REFUSED)
        finally:
            cr.shutil.disk_usage = real
        self.assertIn('GB free on the M4', self.summary())
        self.assertFalse(self.scene.cp_calls.exists())
        self.assertEqual(list(self.scene.seal.work_root.iterdir()), [])

    @unittest.skipUnless(sys.platform == 'darwin', 'the user immutable flag is a macOS file flag')
    def test_what_promote_locked_is_unlocked_inside_the_work_folder_and_removed(self):
        self.scene.plan['lock'] = True
        self.assertEqual(self.scene.run('verbs'), cr.EXIT_GREEN, self.summary())
        self.assertEqual(list(self.scene.seal.work_root.iterdir()), [], 'a locked file kept the work folder alive')
        self.assertNotIn('could NOT be removed', self.summary())

    def test_the_sample_is_deterministic_stratified_and_sized_to_fit(self):
        entries = [cr.Entry(sha_of(n), f'/Volumes/V/{n}', size, f'stratum {n % 7}', pathlib.Path(f'/x/{n}'))
                   for n, size in enumerate([10 + n for n in range(60)])]
        entries.append(cr.Entry(sha_of(900), '/Volumes/V/big', cr.VERBS_MAX_FILE + 1, 'stratum 0', pathlib.Path('/x/big')))
        entries.append(cr.Entry(sha_of(901), '/Volumes/V/empty', 0, 'stratum 0', pathlib.Path('/x/empty')))
        sample = cr.verbs_sample(entries, 20)
        self.assertEqual(sample, cr.verbs_sample(list(reversed(entries)), 20), 'the same sample whatever the order given')
        self.assertEqual(len(sample), 20)
        self.assertEqual(len({e.stratum for e, _ in sample}), 7, 'every stratum is in it')
        self.assertEqual({role: sum(1 for _, r in sample if r == role) for role in cr.VERBS_ROLES},
                         dict(dup=5, purge=5, set_aside=5, promote=5))
        self.assertNotIn(sha_of(900), [e.sha for e, _ in sample], 'a file over the size cap is never sampled')
        self.assertNotIn(sha_of(901), [e.sha for e, _ in sample])
        heavy = [cr.Entry(sha_of(n), f'/Volumes/V/{n}', cr.VERBS_MAX_FILE, 's', pathlib.Path(f'/x/{n}')) for n in range(20)]
        promoted = sum(e.size for e, role in cr.verbs_sample(heavy, 20) if role == 'promote')
        self.assertLessEqual(promoted, cr.VERBS_PROMOTE_BYTES, 'Promote makes real copies: capped')
        self.assertGreater(promoted, 0)
        big = [cr.Entry(sha_of(n), f'/Volumes/V/{n}', 100 + n, f's{n % 40}', pathlib.Path(f'/x/{n}')) for n in range(100_000)]
        t0 = time.monotonic()
        self.assertEqual(len(cr.verbs_sample(big, 20)), 20)
        self.assertLess(time.monotonic() - t0, 5.0)

    def test_the_verbs_driver_carries_its_own_seal_and_never_reaches_the_finder_trash(self):
        driver = (SCRIPTS / 'corpus' / 'CorpusVerbsDriver.swift').read_text()
        code = '\n'.join(line for line in driver.splitlines() if not line.lstrip().startswith('//'))
        for guard in ('CorpusRun.open(lane: "verbs")', 'TestEnvironment.isTestHost',
                      'guard mkdir(trash, 0o755) == 0, CorpusRun.isUnder(trash, config.work), VerbsStage.isEmptyFolder(trash)',
                      'hooks.trashItem = { url in try VerbsTrash.move(url, into: trash, work: work) }',
                      'fileOperation: { url in _ = try VerbsTrash.move(url, into: trash, work: work) }',
                      'guard CorpusRun.isUnder(url.path, work), CorpusRun.isUnder(trash, work), VerbsStage.isRealFolder(trash)',
                      'VerbsStage.digests(in: MediaTrash.testHostTrash.path).files', '"strayTrashFiles": stray',
                      'CorpusRun.isUnder(archive, CorpusRun.realHome() + "/corpus/work")', 'refuse("archive_root_outside_corpus_work")',
                      'refuse("trash_not_in_the_run")', 'refuse("a_verbs_file_is_not_a_clone")', 'CorpusRun.isUnder(root, run.config.work)',
                      'DeleteDuplicatesJob(model: model, volumePath: vol, hooks: hooks, planRoot: planRoot)', 'model.catalogTrashPlan(for: [row])', 'model.trashSelectedRecords([row], confirmed: confirmed,',
                      'model.purgeRecords(ids:', 'model.removeFromCatalog(recordIDs:', 'PromoteToArchiveJob(plan: plan, model: model)',
                      'model.initializeMasterArchive(at: URL(fileURLWithPath: archive'):
            self.assertIn(guard, code, guard)
        self.assertLess(code.index('refuse("trash_not_in_the_run")'), code.index('trashSelectedRecords'), 'the Trash is proven before any verb')
        self.assertLess(code.index('refuse("archive_root_outside_corpus_work")'), code.index('initializeMasterArchive'))
        self.assertEqual(code.count('trashSelectedRecords('), 1, 'one call, and it carries the file-operation seam')
        self.assertEqual(code.count('DeleteDuplicatesJob('), 1)
        for never in ('trashItem(', 'removeItem', 'unlink(', 'FamilyArchive', '/Volumes', 'hooks: .live', 'MediaTrash.move', 'mediaRoot', '.note',
                      'kill('):
            self.assertNotIn(never, code, never)
        self.assertIn('info.st_nlink == 1', code, 'a file with a second name is never unlocked')

    def test_verbs_runs_through_the_same_front_door_and_baseline(self):
        p = subprocess.run(['/bin/bash', str(SCRIPTS / 'corpus_run.sh'), 'run', 'verbs', '--ref', 'HEAD', '--dry-run'],
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('<string>verbs</string>', p.stdout)
        self.assertRegex(p.stdout, r'install .*CorpusVerbsDriver\.swift -> ricksm4\.local:')
        self.assertEqual(subprocess.run(['/bin/bash', str(SCRIPTS / 'm4_run.sh'), 'corpus', '--corpus-lane', 'verbs', '--host', 'ultra',
                                         '--dry-run'], capture_output=True, text=True, timeout=60).returncode, 2)
        self.scene.plan['files'] = {sha_of(1): dict(purge='purged,rescan:stayed_removed')}
        self.scene.run('verbs')
        self.scene.plan['files'] = {sha_of(1): dict(purge='purged,rescan:came_back')}
        self.assertEqual(self.scene.run('verbs', stamp='20261118_090000_2'), cr.EXIT_AMBER)
        self.assertIn(f'    {sha_of(1)[:12]} purge: purged,rescan:stayed_removed -> purged,rescan:came_back', self.summary().splitlines())
        self.assertIn('the baseline is now run 20261118_090000_2', cr.accept(self.scene.seal, 'verbs', 'x')[0])


class HousekeepingTests(unittest.TestCase):
    """E2. At the start of a lane: old stored runs go (never the baseline, never a RED run), and so do work folders a dead run left."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.scene = LaneScene(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def stored(self):
        return sorted(p.parent.name for p in (self.scene.seal.reports / 'check').glob('*/*/report.json'))

    def test_the_newest_runs_the_baseline_and_every_red_run_stay(self):
        real, cr.KEEP_RUNS = cr.KEEP_RUNS, 2
        try:
            self.scene.run(stamp='20261117_120000_1')                                    # the (implicit) baseline
            self.scene.plan['files'] = {sha_of(1): dict(crash='check')}
            self.scene.run(sha='b' * 40, stamp='20261117_130000_2')                      # RED
            self.scene.plan['files'] = {}
            for n in range(3, 8):
                self.scene.run(sha=('c' if n < 6 else 'd') * 40, stamp=f'20261117_1{n}0000_{n}')
            # Each run prunes at its start: when run 7 started, the stored runs were 1..6.
            self.assertEqual(self.stored(), ['20261117_120000_1', '20261117_130000_2', '20261117_150000_5',
                                             '20261117_160000_6', '20261117_170000_7'])
            self.assertFalse((self.scene.seal.reports / 'check' / ('c' * 40) / '20261117_130000_3').exists())
            self.assertIn('housekeeping: 1 old check runs removed from the reports', (self.scene.out / 'corpus-summary.txt').read_text())
            cr.accept(self.scene.seal, 'check', 'x')                                     # run 7 is the baseline now
            for n in range(8, 12):
                self.scene.run(sha='e' * 40, stamp=f'20261118_1{n - 8}0000_{n}')
            self.assertIn('20261117_170000_7', self.stored(), 'the accepted baseline was pruned')
            self.assertIn('20261117_130000_2', self.stored(), 'the RED run was pruned')
            self.assertNotIn('20261117_120000_1', self.stored(), 'the old implicit baseline is an ordinary run once another is accepted')
        finally:
            cr.KEEP_RUNS = real

    def test_nothing_is_pruned_while_the_baseline_cannot_be_read_back(self):
        for n in range(1, 5):
            self.scene.run(stamp=f'20261117_1{n}0000_{n}')
        (self.scene.seal.reports / 'check' / cr.BASELINE).write_text('{not json')
        self.assertEqual(cr.prune(self.scene.seal, 'check', keep=1), [])
        self.assertEqual(len(self.stored()), 4)

    def test_a_work_folder_a_dead_run_left_is_removed_and_a_live_one_is_not(self):
        seal = self.scene.seal
        dead, live = seal.work_root / '20261101_000000_1-verbs', seal.work_root / '20261117_235900_2-proof'
        for folder in (dead, live):
            (folder / 'archive').mkdir(parents=True)
            (folder / 'archive' / 'file.bin').write_text('x')
        if sys.platform == 'darwin':
            os.chflags(dead / 'archive' / 'file.bin', 0x2)                               # what Promote locked
        outside = pathlib.Path(self.tmp.name, 'outside')
        outside.mkdir()
        (outside / 'keep.txt').write_text('keep')
        os.symlink(outside, seal.work_root / 'link')
        old = time.time() - cr.STALE_WORK_SECONDS - 60
        os.utime(dead, (old, old))
        os.utime(seal.work_root / 'link', (old, old), follow_symlinks=False)
        lines = cr.prune(seal, 'check')
        self.assertEqual(lines, ['  housekeeping: 1 work folders left by runs that died were removed'])
        self.assertFalse(dead.exists())
        self.assertTrue((live / 'archive' / 'file.bin').exists())
        self.assertEqual((outside / 'keep.txt').read_text(), 'keep', 'a symlink in the work folder was followed')


class PairEngineTests(unittest.TestCase):
    """D. `check` reports the pair link; an engine the baseline never had is not a change."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.scene = LaneScene(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_the_check_lane_has_a_pair_engine_and_the_driver_reads_the_apps_own_link(self):
        self.assertEqual(cr.LANES['check'][1], ['probe', 'check', 'audio', 'pair'])
        driver = (SCRIPTS / 'corpus' / 'CorpusCheckDriver.swift').read_text()
        for needle in ('await run.engine(item, "pair")', 'record.pairGroupID', 'record.pairedWith', 'CatalogPairGroups.isHalf(record)',
                       'record.soundPresenceContext.soundPartnerName', '"paired_partner_in_corpus"', '"paired_partner_absent"', '"unpaired"'):
            self.assertIn(needle, driver, needle)

    def test_a_new_engine_is_not_a_change_against_a_baseline_that_never_ran_it(self):
        self.scene.run()                                                             # the baseline: three engines
        self.assertEqual(json.loads((self.scene.report_dir() / 'outcomes.json').read_text())[sha_of(0)].get('pair'), 'not_run')
        stored = self.scene.report_dir() / 'outcomes.json'
        old = json.loads(stored.read_text())
        for record in old.values():                                                  # as a run from before the pair engine stored it
            record.pop('pair', None)
            record.pop('pair_kinds', None)
        stored.write_text(json.dumps(old))
        self.scene.plan['engines'] = ['probe', 'check', 'audio', 'pair']
        self.scene.plan['files'] = {sha_of(n): dict(pair='paired_partner_in_corpus' if n == 1 else 'unpaired',
                                                    pair_kinds=['not_counted_as_a_half']) for n in range(3)}
        self.assertEqual(self.scene.run(stamp='20261118_090000_2'), cr.EXIT_GREEN)
        self.assertIn('0 of 3 files changed', (self.scene.out / 'corpus-summary.txt').read_text())
        # First real testbed run, 2026-11-18: "finding kinds moved in 234 files" — every file, only because the
        # new engine has kinds and the baseline had no such engine.
        self.assertNotIn('finding kinds moved', (self.scene.out / 'corpus-summary.txt').read_text())
        self.assertIn('  pair: unpaired 2, paired_partner_in_corpus 1', (self.scene.out / 'corpus-summary.txt').read_text())
        # Once a run with the engine is the baseline, a moved pair word IS a change.
        cr.accept(self.scene.seal, 'check', 'x')
        self.scene.plan['files'] = {sha_of(1): dict(pair='unpaired')}
        self.assertEqual(self.scene.run(stamp='20261118_100000_3'), cr.EXIT_AMBER)
        self.assertIn(f'    {sha_of(1)[:12]} pair: paired_partner_in_corpus -> unpaired', (self.scene.out / 'corpus-summary.txt').read_text().splitlines())


SEAL_MAIN = r"""
import Foundation
struct Case: Decodable { let hostname, realHome, configPath, lane, home, appSupport: String; let isTestHost: Bool }
let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
for c in cases {
    var reads = 0
    let loaded = CorpusSeal.loadConfig(hostname: c.hostname, realHome: c.realHome, configPath: c.configPath,
                                       read: { reads += 1; return FileManager.default.contents(atPath: $0) })
    var word = loaded.refusal
    if word == nil {
        word = CorpusSeal.refusal(CorpusSealInput(hostname: c.hostname, realHome: c.realHome, configPath: c.configPath, lane: c.lane,
                                                  config: loaded.config, homeDirectory: c.home, applicationSupport: c.appSupport,
                                                  isTestHost: c.isTestHost))
    }
    let proven = loaded.config.map { CorpusSeal.progressIsProven($0, realHome: c.realHome) } ?? false
    print("\(word ?? "ok")|\(reads)|\(proven)")
}
"""


@unittest.skipUnless(shutil.which('swiftc'), 'needs the Swift compiler')
class SwiftSealTests(unittest.TestCase):
    """Codex #311 F9: the in-app seal pinned by BEHAVIOUR. scripts/corpus/CorpusSeal.swift (Foundation only) is
    compiled beside a small main and asked about real folders — symlinks included."""

    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        main = pathlib.Path(cls.build.name, 'main.swift')
        main.write_text(SEAL_MAIN)
        cls.binary = pathlib.Path(cls.build.name, 'seal')
        done = subprocess.run(['swiftc', '-o', str(cls.binary), str(SCRIPTS / 'corpus' / 'CorpusSeal.swift'), str(main)],
                              capture_output=True, text=True, timeout=600)
        if done.returncode != 0:
            raise AssertionError('CorpusSeal.swift does not compile by itself:\n' + done.stdout + done.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = pathlib.Path(os.path.realpath(self.tmp.name), 'home')
        self.corpus = self.home / 'corpus'
        self.run_dir = self.corpus / 'work' / 'run1-verbs'
        for folder in (self.corpus / 'state' / 'home', self.corpus / 'media' / 'Volumes' / 'V', self.run_dir / 'vol', self.run_dir / 'home',
                       self.run_dir / 'archive', self.run_dir / 'scratch', self.corpus / 'live'):
            folder.mkdir(parents=True)
        (self.corpus / cr.MARKER).write_text('test data\n')
        (self.corpus / 'media' / 'Volumes' / 'V' / 'a.mov').write_text('x')
        (self.run_dir / 'vol' / 'a.mov').write_text('x')
        (self.run_dir / 'progress.jsonl').write_text('')
        (self.corpus / 'state' / 'catalog.sqlite').write_text('db')

    def tearDown(self):
        self.tmp.cleanup()

    def config(self, **changes):
        value = dict(lane='verbs', corpusRoot=str(self.corpus), stateRoot=str(self.corpus / 'state'),
                     catalog=str(self.corpus / 'state' / 'catalog.sqlite'), mediaRoot=str(self.corpus / 'media'),
                     work=str(self.run_dir), progress=str(self.run_dir / 'progress.jsonl'), deadlineSeconds=60,
                     pending=[dict(sha='a' * 64, path=str(self.run_dir / 'vol' / 'a.mov'), role='dup', copies=[])],
                     volRoot=str(self.run_dir / 'vol'), archiveRoot=str(self.run_dir / 'archive'), scratch=str(self.run_dir / 'scratch'))
        value.update(changes)
        return value

    def ask(self, *cases):
        rows = []
        for n, case in enumerate(cases):
            path = pathlib.Path(case.pop('config_at', self.run_dir / f'config-{n}.json'))
            if 'config' in case:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps(case.pop('config')))
            row = dict(hostname='RicksM4.local', realHome=str(self.home), configPath=str(path), lane='verbs',
                       home=str(self.run_dir / 'home'), appSupport=str(self.run_dir / 'home' / 'Library' / 'Application Support'),
                       isTestHost=True)
            row.update(case)
            rows.append(row)
        cases_file = pathlib.Path(self.tmp.name, 'cases.json')
        cases_file.write_text(json.dumps(rows))
        done = subprocess.run([str(self.binary), str(cases_file)], capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.facts = [line.split('|') for line in done.stdout.split()]       # [word, config reads, progress proven]
        return [fact[0] for fact in self.facts]

    def test_the_seal_holds_on_the_m4_and_refuses_every_other_mac(self):
        answers = self.ask(dict(config=self.config()), dict(config=self.config(), hostname='RicksUltra'),
                           dict(config=self.config(), hostname='ricksm4x.local'), dict(config=self.config(), hostname=''),
                           dict(config=self.config(), isTestHost=False), dict(config=self.config(), lane='check'))
        self.assertEqual(answers, ['ok', 'not_the_m4', 'not_the_m4', 'not_the_m4', 'not_a_test_host', 'config_is_for_another_lane'])

    def test_a_check_lane_config_over_media_holds_and_a_home_outside_the_seal_does_not(self):
        check = self.config(lane='check', pending=[dict(sha='a' * 64, path=str(self.corpus / 'media' / 'Volumes' / 'V' / 'a.mov'))],
                            volRoot=None, archiveRoot=None, scratch=None)
        state_home = str(self.corpus / 'state' / 'home')
        answers = self.ask(dict(config=check, lane='check', home=state_home, appSupport=state_home + '/Library/Application Support'),
                           dict(config=check, lane='check', home=str(self.home), appSupport=str(self.home / 'Library' / 'Application Support')),
                           dict(config=check, lane='check', home=state_home, appSupport=str(self.home / 'Library' / 'Application Support')),
                           dict(config=dict(check, pending=[dict(sha='a' * 64, path=str(self.home / 'elsewhere.mov'))]), lane='check',
                                home=state_home, appSupport=state_home + '/Library/Application Support'))
        self.assertEqual(answers, ['ok', 'home_not_sealed', 'home_not_sealed', 'a_file_is_outside_the_corpus'])

    def test_no_marker_is_refused(self):
        (self.corpus / cr.MARKER).unlink()
        self.assertEqual(self.ask(dict(config=self.config())), ['no_test_data_marker'])

    def test_a_corpus_folder_that_is_an_alias_is_refused(self):
        # Codex #311 F1: with work -> media, a path "under work" is a path in the pristine corpus.
        shutil.move(str(self.corpus / 'work'), str(self.corpus / 'work-real'))
        os.symlink(self.corpus / 'media', self.corpus / 'work')
        config = self.config(work=str(self.corpus / 'work' / 'Volumes'), progress=str(self.corpus / 'work' / 'Volumes' / 'p.jsonl'))
        self.assertEqual(self.ask(dict(config=config, config_at=self.corpus / 'work-real' / 'c.json')), ['a_corpus_folder_is_an_alias'])
        os.unlink(self.corpus / 'work')
        shutil.move(str(self.corpus / 'work-real'), str(self.corpus / 'work'))
        shutil.move(str(self.corpus / 'state'), str(self.home / 'state-elsewhere'))
        os.symlink(self.home / 'state-elsewhere', self.corpus / 'state')
        self.assertEqual(self.ask(dict(config=self.config())), ['a_corpus_folder_is_an_alias'])

    def test_the_runs_folders_must_be_inside_the_run_by_real_containment(self):
        evil = self.corpus / 'work-evil'                                   # a prefix match is not containment
        (evil / 'archive').mkdir(parents=True)
        sibling = self.corpus / 'work' / 'run1-verbs-evil'                 # beside the run, sharing its name as a prefix
        (sibling / 'archive').mkdir(parents=True)
        os.symlink(self.corpus / 'media', self.run_dir / 'sneak')          # a link inside the run, out to the pristine copies
        os.symlink(self.home, self.run_dir / 'up')
        outside = pathlib.Path(self.tmp.name, 'outside')
        outside.mkdir()
        answers = self.ask(
            dict(config=self.config(archiveRoot=str(evil / 'archive'))),
            dict(config=self.config(archiveRoot=str(sibling / 'archive'))),
            dict(config=self.config(archiveRoot=str(self.run_dir / 'sneak' / 'Volumes'))),
            dict(config=self.config(archiveRoot='/Volumes/FamilyArchive')),
            dict(config=self.config(archiveRoot=str(self.run_dir / '..' / '..' / 'media'))),
            dict(config=self.config(scratch=str(self.run_dir / 'up' / 'Library'))),
            dict(config=self.config(volRoot=str(self.corpus / 'work'))),
            dict(config=self.config(work=str(self.corpus / 'work'), progress=str(self.run_dir / 'progress.jsonl'))),
            dict(config=self.config(work=str(outside), progress=str(outside / 'p'))),
            dict(config=self.config(pending=[dict(sha='a' * 64, path=str(self.run_dir / 'vol' / 'a.mov'),
                                                  copies=[str(self.corpus / 'media' / 'Volumes' / 'V' / 'a.mov')])])),
            dict(config=self.config(catalog=str(self.home / 'Library' / 'Application Support' / 'VideoScan' / 'catalog.sqlite'))),
            dict(config=self.config(), home=str(self.run_dir / 'sneak'), appSupport=str(self.run_dir / 'home')),
            dict(config=self.config(), config_at=outside / 'config.json'))
        self.assertEqual(answers, ['a_verbs_folder_is_outside_the_run'] * 7 + ['work_outside_the_corpus'] * 2
                         + ['a_file_is_outside_the_corpus', 'state_root_outside_the_corpus', 'home_not_sealed', 'config_outside_the_corpus'])

    def test_nothing_is_read_before_the_gate_holds(self):
        # Codex #313 F6: on the wrong Mac, without the marker, or with a config outside ~/corpus/work, the
        # config file is not even opened (it could be made to name any file — a live catalog).
        live = self.home / 'Library' / 'Application Support' / 'VideoScan' / 'catalog.sqlite'
        live.parent.mkdir(parents=True)
        live.write_text('the live catalog')
        answers = self.ask(dict(config=self.config(), hostname='RicksUltra'), dict(config_at=live, hostname='RicksUltra'),
                           dict(config_at=live), dict(config_at=self.corpus / 'work'), dict(config=self.config()))
        self.assertEqual(answers, ['not_the_m4', 'not_the_m4', 'config_outside_the_corpus', 'config_outside_the_corpus', 'ok'])
        self.assertEqual([fact[1] for fact in self.facts], ['0', '0', '0', '0', '1'])
        (self.corpus / cr.MARKER).unlink()
        self.ask(dict(config=self.config()))
        self.assertEqual(self.facts, [['no_test_data_marker', '0', 'false']])
        support = (SCRIPTS / 'corpus' / 'CorpusDriverSupport.swift').read_text()
        self.assertIn('CorpusSeal.loadConfig(hostname: hostname(), realHome: realHome(), configPath: configPath,', support)
        self.assertEqual(support.count('FileManager.default.contents(atPath:'), 1, 'the one read of the config is the gated one')

    def test_a_path_with_dot_dot_through_a_link_is_never_the_path_checked(self):
        # Codex #313 F1: `run/jump/../victim` with jump -> media/Volumes is media/victim when opened,
        # and was run/victim when checked.
        os.symlink(self.corpus / 'media' / 'Volumes', self.run_dir / 'jump')
        victim = self.corpus / 'media' / 'victim'
        victim.write_text('pristine')
        dotted = str(self.run_dir / 'jump') + '/../victim'
        answers = self.ask(dict(config=self.config(progress=dotted)),
                           dict(config=self.config(archiveRoot=str(self.run_dir) + '/jump/../archive')),
                           dict(config=self.config(scratch=str(self.run_dir) + '/scratch/../scratch')),
                           dict(config=self.config(work=str(self.run_dir) + '/../run1-verbs')),
                           dict(config=self.config(), home=str(self.run_dir) + '/jump/../home'),
                           dict(config=self.config(pending=[dict(sha='a' * 64, path=str(self.run_dir) + '/jump/../vol/a.mov', copies=[])])))
        self.assertEqual(answers, ['work_outside_the_corpus', 'a_verbs_folder_is_outside_the_run', 'a_verbs_folder_is_outside_the_run',
                                   'work_outside_the_corpus', 'home_not_sealed', 'a_file_is_outside_the_corpus'])
        self.assertEqual(self.facts[0][2], 'false', 'a refusal must not be written to such a progress file')
        self.assertEqual(victim.read_text(), 'pristine')

    def test_the_progress_file_is_this_runs_own(self):
        # Codex #313 F7: another run's progress file is not this run's; and a refusal is written to the
        # progress file only when that file is proven to be inside this run.
        other = self.corpus / 'work' / 'run2-check'
        other.mkdir()
        (other / 'progress.jsonl').write_text('')
        os.symlink(self.corpus / 'live', self.run_dir / 'to-live')
        answers = self.ask(dict(config=self.config(progress=str(other / 'progress.jsonl'))),
                           dict(config=self.config(progress=str(self.run_dir))),
                           dict(config=self.config(progress=str(self.run_dir / 'to-live' / 'p.jsonl'))),
                           dict(config=self.config(), lane='check'), dict(config=self.config()))
        self.assertEqual(answers, ['work_outside_the_corpus', 'work_outside_the_corpus', 'work_outside_the_corpus',
                                   'config_is_for_another_lane', 'ok'])
        self.assertEqual([fact[2] for fact in self.facts], ['false', 'false', 'false', 'true', 'true'])

    def test_a_catalog_that_is_a_link_to_a_live_one_is_refused(self):
        live = self.home / 'Library' / 'Application Support' / 'VideoScan'
        live.mkdir(parents=True)
        (live / 'catalog.sqlite').write_text('the live catalog')
        os.unlink(self.corpus / 'state' / 'catalog.sqlite')
        os.symlink(live / 'catalog.sqlite', self.corpus / 'state' / 'catalog.sqlite')
        self.assertEqual(self.ask(dict(config=self.config())), ['state_root_outside_the_corpus'])


class CodexRoundTests(unittest.TestCase):
    """Codex #311 (block, 9 findings): each finding's path, closed. Each test was seen red with its fix taken back out."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.scene = LaneScene(self.tmp.name)
        self.media = self.scene.corpus / 'media'
        self.snapshot = {p: p.read_bytes() for p in self.media.rglob('*') if p.is_file()}

    def tearDown(self):
        self.tmp.cleanup()

    def assert_media_untouched(self):
        self.assertEqual({p: p.read_bytes() for p in self.media.rglob('*') if p.is_file()}, self.snapshot)

    def summary(self):
        return (self.scene.out / 'corpus-summary.txt').read_text()

    # F1 — a writable root that is an alias of the pristine copies

    def test_f1_a_work_folder_that_points_into_media_is_refused_and_nothing_there_is_removed(self):
        corpus, seal = self.scene.corpus, self.scene.seal
        shutil.rmtree(corpus / 'work', ignore_errors=True)
        os.symlink(self.media, corpus / 'work')
        old = time.time() - cr.STALE_WORK_SECONDS - 600
        for folder in self.media.iterdir():
            os.utime(folder, (old, old))                                    # "a work folder a dead run left"
        with self.assertRaises(cr.Refused) as refused:
            seal.check()
        self.assertIn('~/corpus/work is a symlink', str(refused.exception))
        with self.assertRaises(cr.Refused):
            seal.writable(corpus / 'work' / 'Volumes' / 'x')
        with self.assertRaises(cr.Refused):
            cr.prune(seal, 'check')
        self.assertEqual(self.scene.run(), cr.EXIT_REFUSED)
        self.assertEqual(self.scene.run('verbs'), cr.EXIT_REFUSED)
        self.assert_media_untouched()

    def test_f1_state_or_reports_as_an_alias_is_refused_too(self):
        corpus = self.scene.corpus
        for name in ('state', 'reports'):
            with self.subTest(name=name):
                real = corpus / name
                moved = corpus / (name + '-real')
                if real.exists():
                    shutil.move(str(real), str(moved))
                os.symlink(self.media, real)
                with self.assertRaises(cr.Refused):
                    self.scene.seal.check()
                with self.assertRaises(cr.Refused):
                    self.scene.seal.writable(real / 'x.json')
                os.unlink(real)
                if moved.exists():
                    shutil.move(str(moved), str(real))
        self.scene.seal.check()
        self.assert_media_untouched()

    # F2 — writes that did not go through the seal

    def test_f2_an_out_file_that_is_a_symlink_to_a_corpus_file_is_never_written_through(self):
        victim = self.media / self.scene.files[0][1].lstrip('/')
        outside = pathlib.Path(self.tmp.name, 'precious.txt')
        outside.write_text('precious')
        for target in (victim, outside):
            for name in ('corpus-summary.txt', cr.VERDICT_FILE):
                with self.subTest(target=target.name, name=name):
                    link = self.scene.out / name
                    if link.is_symlink() or link.exists():
                        link.unlink()
                    os.symlink(target, link)
                    self.assertIn(self.scene.run(stamp=f'2026111{len(name)}_{target.stat().st_ino % 100000}_1'), (cr.EXIT_REFUSED, cr.EXIT_RED))
                    link.unlink()
        self.assert_media_untouched()
        self.assertEqual(outside.read_text(), 'precious')
        (self.scene.seal.state / DB).unlink()                               # a refusal's own summary line, same door
        (self.scene.out / 'corpus-summary.txt').unlink()
        os.symlink(victim, self.scene.out / 'corpus-summary.txt')
        self.assertEqual(self.scene.run(stamp='20261119_000000_9'), cr.EXIT_REFUSED)
        self.assert_media_untouched()

    def test_f2_a_testbed_whose_test_folder_is_a_symlink_gets_no_driver_sources(self):
        tests_dir = self.scene.worktree / 'VideoScan' / 'VideoScanTests'
        shutil.move(str(tests_dir), str(self.scene.worktree / 'VideoScan' / 'RealTests'))
        target = self.media / 'Volumes' / 'PrivateDrive'
        os.symlink(target, tests_dir)
        before = sorted(p.name for p in target.iterdir())
        self.assertEqual(self.scene.run(), cr.EXIT_REFUSED)
        self.assertIn("the testbed's test folder is not a folder of the testbed", self.summary())
        self.assertEqual(sorted(p.name for p in target.iterdir()), before, 'driver sources were copied into the corpus')
        self.assertEqual(self.scene.recorded_calls(), [], 'nothing was built')

    def test_f2_the_patched_test_run_file_is_a_new_file_never_a_link(self):
        self.scene.run()
        products = self.scene.dd / 'Build' / 'Products'
        precious = pathlib.Path(self.tmp.name, 'precious.plist')
        precious.write_text('precious')
        os.symlink(precious, products / 'corpus-20261118_090000_2-1.xctestrun')
        self.assertEqual(self.scene.run(stamp='20261118_090000_2'), cr.EXIT_REFUSED)
        self.assertEqual(precious.read_text(), 'precious')
        with self.assertRaises(FileExistsError):
            cr.patch_xctestrun(next(products.glob('VideoScan_VideoScan-CI*.xctestrun')), precious, {})

    # F3 — unlocking through a second name

    @unittest.skipUnless(sys.platform == 'darwin', 'the user immutable flag is a macOS file flag')
    def test_f3_a_locked_file_with_a_second_name_is_never_unlocked(self):
        victim = self.media / self.scene.files[0][1].lstrip('/')
        work = self.scene.seal.work_root / '20261101_000000_1-verbs'
        (work / 'archive').mkdir(parents=True)
        own = work / 'archive' / 'own.bin'
        own.write_text('x')
        os.link(victim, work / 'archive' / 'hardlink.mov')                  # the same inode as the pristine file
        os.chflags(victim, 0x2)
        os.chflags(own, 0x2)
        try:
            cr._unlock_tree(str(work))
            self.assertTrue(os.lstat(victim).st_flags & 0x2, 'the pristine file was unlocked through its second name')
            self.assertFalse(os.lstat(own).st_flags & 0x2, "the run's own file stays locked")
        finally:
            os.chflags(victim, 0)
            os.unlink(work / 'archive' / 'hardlink.mov')

    # F4 — reading back through a link

    def test_f4_a_sealed_catalog_that_is_a_link_is_refused_before_it_is_opened(self):
        live = self.scene.home / 'Library' / 'Application Support' / 'VideoScan'
        live.mkdir(parents=True)
        shutil.copy(self.scene.seal.state / DB, live / DB)
        (self.scene.seal.state / DB).unlink()
        os.symlink(live / DB, self.scene.seal.state / DB)
        opened = []
        real = catalog_db.connect
        catalog_db.connect = lambda path, *a, **k: opened.append(str(path)) or real(path, *a, **k)
        try:
            with self.assertRaises(cr.Refused) as refused:
                cr.sealed_state_ready(self.scene.seal, cr.load_manifest(self.scene.seal))
            self.assertEqual(self.scene.run(), cr.EXIT_REFUSED)
        finally:
            catalog_db.connect = real
        self.assertEqual(opened, [], 'the live catalog was opened before the refusal')
        self.assertIn('resolves outside the folder it belongs to', str(refused.exception))

    def test_f4_a_run_or_an_outcomes_file_that_is_a_link_is_not_a_run_and_never_a_baseline(self):
        self.scene.run()
        cr.accept(self.scene.seal, 'check', 'x')
        run = self.scene.report_dir()
        elsewhere = pathlib.Path(self.tmp.name, 'elsewhere')
        shutil.copytree(run, elsewhere)
        record = self.scene.seal.reports / 'check' / cr.BASELINE
        good = record.read_text()
        # (a) the outcomes file is a link to one outside the reports
        (run / 'outcomes.json').unlink()
        os.symlink(elsewhere / 'outcomes.json', run / 'outcomes.json')
        self.assertEqual(cr.lane_runs(self.scene.seal, 'check'), [])
        self.assertEqual(self.scene.run(stamp='20261118_090000_2'), cr.EXIT_RED)
        self.assertIn('the accepted baseline of check cannot be read back', self.summary())
        # (b) the run folder itself is a link
        shutil.rmtree(run)
        os.symlink(elsewhere, run)
        record.write_text(good)
        self.assertNotIn(run, cr.lane_runs(self.scene.seal, 'check'))
        self.assertEqual(self.scene.run(stamp='20261118_100000_3'), cr.EXIT_RED)
        with self.assertRaises(cr.Refused):
            self.scene.seal.contained(run / 'outcomes.json', self.scene.seal.reports / 'check')

    # F6 — a host that dies after its last answer

    def test_f6_a_file_that_began_and_never_ended_is_red_even_when_every_engine_answered(self):
        self.scene.plan['engines'] = ['probe', 'check', 'audio', 'pair']
        self.scene.plan['files'] = {sha_of(1): dict(crash='end')}
        self.assertEqual(self.scene.run(), cr.EXIT_RED)
        report = json.loads((self.scene.report_dir() / 'report.json').read_text())
        self.assertEqual(report['failures'], {'end:crash': 1})
        self.assertIn('corpus check: RED 3 files', self.summary())
        with self.assertRaises(cr.Refused):
            cr.accept(self.scene.seal, 'check', 'x')
        results = {'a': {}}
        cr.settle([dict(ev='begin', sha='a'), dict(ev='engine', sha='a', engine='probe', outcome='probed')], ['probe'], results)
        self.assertTrue(results['a'].get('unfinished'))

    # F7 — housekeeping removes only what is named like a run

    def test_f7_an_old_folder_in_work_that_is_not_a_runs_is_left_alone(self):
        seal = self.scene.seal
        old = time.time() - cr.STALE_WORK_SECONDS - 60
        names = ['keep-me-not-a-run', 'notes', '20261101_000000_1', '20261101_000000_1-unknownlane', 'x-check.bak']
        for name in names + ['20261101_000000_1-check']:
            (seal.work_root / name).mkdir(parents=True)
            (seal.work_root / name / 'f').write_text('x')
            os.utime(seal.work_root / name, (old, old))
        cr.prune(seal, 'check')
        self.assertEqual(sorted(p.name for p in seal.work_root.iterdir()), sorted(names))

    # F8 — what may leave

    def test_f8_a_poisoned_baseline_cannot_put_a_name_into_what_leaves(self):
        self.scene.run()
        stored = self.scene.report_dir() / 'outcomes.json'
        poisoned = json.loads(stored.read_text())
        poisoned[sha_of(0)]['check'] = '/Volumes/PrivateDrive/Grandma/Birthday 1988.mov'
        poisoned[sha_of(1)]['audio'] = 'Birthday_1988.mov'
        stored.write_text(json.dumps(poisoned))
        self.assertEqual(self.scene.run(stamp='20261118_090000_2'), cr.EXIT_AMBER)
        leaves = self.scene.everything_that_leaves() + (self.scene.out / cr.VERDICT_FILE).read_text() + '\n'.join(cr.status(self.scene.seal))
        for name in SECRET_NAMES + ('.mov', '/Volumes'):
            self.assertNotIn(name, leaves, name)
        self.assertIn('check: scrubbed -> OK', leaves)

    def test_f8_a_whole_digest_is_not_a_word_and_who_is_never_a_file_name(self):
        digest = sha_of(0)
        for text in (digest, digest.upper(), digest[:40], 'x' + digest[:30], digest[:24]):
            self.assertEqual(cr.word(text), 'scrubbed', text)
        self.assertEqual(cr.word(digest[:12]), digest[:12], 'the 12-hex prefix is the one form that leaves')
        self.assertEqual(cr.word('paired_partner_in_corpus'), 'paired_partner_in_corpus')
        self.assertEqual(cr.who_word('Birthday.mov'), 'Birthday_mov')
        self.assertEqual(cr.who_word(digest), 'scrubbed')
        self.assertEqual(cr.who_word('rickb@RicksUltra'), 'rickb@RicksUltra')
        seal_swift = (SCRIPTS / 'corpus' / 'CorpusDriverSupport.swift').read_text()
        self.assertIn('spaced.count <= 64', seal_swift)

    def test_f8_what_sqlite_says_stays_on_the_m4(self):
        src = sqlite3.connect(self.scene.source)
        src.execute("CREATE TRIGGER says_a_name BEFORE INSERT ON user_dates BEGIN SELECT RAISE(ABORT, 'Birthday_1988.mov'); END")
        src.commit()
        src.close()
        for leftover in self.scene.corpus.glob(cr.SOURCE_BACKUP + '-*'):
            leftover.unlink()
        with self.assertRaises(cr.Refused) as refused:
            cr.prepare(self.scene.seal)
        self.assertNotIn('Birthday', str(refused.exception))
        self.assertIn('IntegrityError', str(refused.exception))


class CodexClosingTests(unittest.TestCase):
    """Codex #313, the closing pass (block; F3, F5, F6, F7, F9 closed for the class; nine findings on what
    was left). Each test was seen red with its fix taken back out. The Swift ones are in SwiftSealTests."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.scene = LaneScene(self.tmp.name)
        self.media = self.scene.corpus / 'media'
        self.victim = self.media / self.scene.files[0][1].lstrip('/')
        self.pristine = self.victim.read_bytes()

    def tearDown(self):
        self.tmp.cleanup()

    def summary(self):
        return (self.scene.out / 'corpus-summary.txt').read_text()

    def test_2_a_build_or_test_log_that_is_a_link_is_never_appended_to(self):
        for name in ('corpus-build.log', 'corpus-test.log'):
            with self.subTest(name=name):
                os.symlink(self.victim, self.scene.out / name)
                self.assertEqual(self.scene.run(), cr.EXIT_REFUSED)
                self.assertEqual(self.victim.read_bytes(), self.pristine, 'a lane log was appended to a corpus file')
                (self.scene.out / name).unlink()
        self.assertEqual(self.scene.run(), cr.EXIT_GREEN)

    def test_3_an_out_file_with_a_second_name_is_never_emptied(self):
        for name in ('corpus-summary.txt', cr.VERDICT_FILE, 'corpus-build.log'):
            with self.subTest(name=name):
                target = self.scene.out / name
                if target.exists():
                    target.unlink()
                os.link(self.victim, target)                                # the same inode as the pristine file
                self.assertIn(self.scene.run(stamp='20261118_090000_2'), (cr.EXIT_REFUSED, cr.EXIT_RED))
                self.assertEqual(self.victim.read_bytes(), self.pristine, 'a corpus file was emptied through its second name')
                target.unlink()

    def test_3_the_out_folder_is_a_run_folder_under_m4run_out_and_nothing_else(self):
        seal = self.scene.seal
        elsewhere = pathlib.Path(self.tmp.name, 'Documents')
        elsewhere.mkdir()
        link = seal.out_root / 'linked-run'
        os.symlink(elsewhere, link)
        nested = self.scene.out / 'deeper'
        nested.mkdir()
        for out in (elsewhere, link, nested, seal.out_root, seal.corpus / 'work', self.media, self.scene.home):
            with self.subTest(out=str(out)):
                with self.assertRaises(cr.Refused):
                    seal.out_folder(out)
                with self.assertRaises(cr.Refused):
                    seal.out_write(out, 'corpus-summary.txt', 'x')
        self.assertEqual(sorted(p.name for p in elsewhere.iterdir()), [])
        inside_a_testbed_run = self.scene.out / 'corpus-check'                # what `m4_run.sh testbed` gives a corpus lane
        inside_a_testbed_run.mkdir()
        self.assertEqual(seal.out_folder(inside_a_testbed_run), inside_a_testbed_run)
        os.symlink(elsewhere, self.scene.out / 'corpus-proof')
        with self.assertRaises(cr.Refused):
            seal.out_folder(self.scene.out / 'corpus-proof')
        for name in ('../escape.txt', 'a/b', '', '..'):
            with self.assertRaises(cr.Refused):
                seal.out_write(self.scene.out, name, 'x')
        argv = ['host', 'check', '--sha', 'a' * 40, '--stamp', 's1', '--out', str(elsewhere), '--worktree', str(self.scene.worktree),
                '--derived-data', str(self.scene.dd), '--bin', str(SCRIPTS / 'corpus')]
        self.assertEqual(cr.main(argv, seal=seal, xcodebuild=str(self.scene.fake)), cr.EXIT_REFUSED)
        self.assertEqual(sorted(p.name for p in elsewhere.iterdir()), [], 'a lane wrote into a folder that is not its run folder')

    def test_4_a_work_folder_that_is_already_there_is_not_this_runs(self):
        # Whatever a run finds in its work folder it put there itself: the folder is made new, or the run refuses.
        seeded = self.scene.seal.work_root / '20261117_120000_1-verbs'
        (seeded / 'scratch').mkdir(parents=True)
        os.symlink(self.media, seeded / 'scratch' / 'ledger-verbs')
        self.assertEqual(self.scene.run('verbs'), cr.EXIT_REFUSED)
        self.assertIn("a work folder with this run's name is already there", self.summary())
        self.assertTrue((seeded / 'scratch' / 'ledger-verbs').is_symlink(), "a folder that was not the run's was removed")
        self.assertEqual(self.scene.recorded_calls(), [])
        driver = (SCRIPTS / 'corpus' / 'CorpusVerbsDriver.swift').read_text()
        for guard in ('VerbsStage.isEmptyFolder(scratch), VerbsStage.isEmptyFolder(archive)', 'refuse("a_verbs_folder_is_not_empty")',
                      'guard mkdir(path, 0o755) == 0, CorpusRun.isUnder(path, scratch), CorpusRun.isUnder(path, run.config.work)',
                      'guard mkdir(plans, 0o755) == 0, CorpusRun.isUnder(plans, run.config.work)'):
            self.assertIn(guard, driver, guard)
        self.assertLess(driver.index('refuse("a_verbs_folder_is_not_empty")'), driver.index('stage.makeModel("verbs")'))

    def test_5_a_lane_folder_or_a_record_that_is_a_link_is_never_read_back(self):
        self.scene.run()
        cr.accept(self.scene.seal, 'check', 'x')
        reports = self.scene.seal.reports
        outside = pathlib.Path(self.tmp.name, 'outside-reports')
        shutil.copytree(reports / 'check', outside)
        record = (reports / 'check' / cr.BASELINE).read_text()
        # (a) reports/check itself is a link to a folder elsewhere that holds valid-looking runs
        shutil.rmtree(reports / 'check')
        os.symlink(outside, reports / 'check')
        self.assertEqual(cr.lane_runs(self.scene.seal, 'check'), [])
        self.assertIn('corpus check: no run yet', cr.status(self.scene.seal))
        os.unlink(reports / 'check')
        shutil.copytree(outside, reports / 'check')
        self.assertEqual(len(cr.lane_runs(self.scene.seal, 'check')), 1)
        # (b) the baseline record is a link to a file elsewhere (here: one that would parse)
        elsewhere = pathlib.Path(self.tmp.name, 'elsewhere.json')
        elsewhere.write_text(record)
        (reports / 'check' / cr.BASELINE).unlink()
        os.symlink(elsewhere, reports / 'check' / cr.BASELINE)
        run, _, problem = cr.baseline_of(self.scene.seal, 'check')
        self.assertEqual(run, None)
        self.assertIn('cannot be read back', problem)
        # (c) prepare.json is a link
        prepared = self.scene.seal.state / 'prepare.json'
        kept = pathlib.Path(self.tmp.name, 'prepare-elsewhere.json')
        shutil.move(str(prepared), str(kept))
        os.symlink(kept, prepared)
        with self.assertRaises(cr.Refused):
            cr.sealed_state_ready(self.scene.seal, cr.load_manifest(self.scene.seal))
        self.assertIn('not prepared', cr.status(self.scene.seal)[0])

    def test_8_status_prints_a_stored_report_as_words_and_numbers_only(self):
        self.scene.run()
        stored = self.scene.report_dir() / 'report.json'
        good = json.loads(stored.read_text())
        poisoned = dict(good, engines=dict(good['engines'], check={'/Volumes/PrivateDrive/Grandma/Birthday 1988.mov': 1, 'OK': 2},
                                           audio={sha_of(0): 3}),
                        failures={'check:Grandma said hello': 1}, files='Lake House', bytes='reel_07', wall_s=[1],
                        seal=dict(homeSealed='Birthday', testHost=True, archiveDesignation=False, records='reel_07.MXF'))
        stored.write_text(json.dumps(poisoned))
        text = '\n'.join(cr.status(self.scene.seal))
        for name in SECRET_NAMES + ('.mov', '/Volumes', sha_of(0), 'reel_07'):
            self.assertNotIn(name, text, name)
        self.assertIn('check: OK 2, scrubbed 1', text)
        for junk in ('[]', '"text"', json.dumps(dict(good, lane='../../etc')), json.dumps(dict(good, sha='Birthday.mov')), '{not json'):
            stored.write_text(junk)
            text = '\n'.join(cr.status(self.scene.seal))
            self.assertIn('RED its report cannot be read back', text)
            for name in SECRET_NAMES:
                self.assertNotIn(name, text)

    def test_9_a_baseline_row_that_is_not_a_record_is_never_an_unchanged_file(self):
        engines = ['check']
        delta = cr.diff({'a': 'not a record', 'b': {'check': 'OK'}}, {'a': {'check': 'OK'}, 'b': {'check': 'OK'}}, engines)
        self.assertEqual((delta['compared'], delta['changed']), (1, 0), 'a malformed row was counted as compared and unchanged')
        self.scene.run()
        cr.accept(self.scene.seal, 'check', 'x')
        stored = self.scene.report_dir() / 'outcomes.json'
        rows = json.loads(stored.read_text())
        rows[sha_of(0)] = 'not a record'
        stored.write_text(json.dumps(rows))
        record = self.scene.seal.reports / 'check' / cr.BASELINE
        accepted = json.loads(record.read_text())
        accepted['outcomes_sha256'] = hashlib.sha256(stored.read_bytes()).hexdigest()       # even "re-accepted" by hand
        record.write_text(json.dumps(accepted))
        self.assertEqual(self.scene.run(stamp='20261118_090000_2'), cr.EXIT_RED)
        self.assertIn('the accepted baseline of check cannot be read back', self.summary())
        record.unlink()                                                                    # and never the implicit baseline
        self.assertEqual(cr.baseline_of(self.scene.seal, 'check', exclude=self.scene.report_dir(stamp='20261118_090000_2'))[0], None)
        with self.assertRaises(cr.Refused):
            cr.accept(self.scene.seal, 'check', 'x') if cr.lane_runs(self.scene.seal, 'check')[-1] == self.scene.report_dir() else (_ for _ in ()).throw(cr.Refused('x'))


class ScaleTests(unittest.TestCase):

    def test_diff_and_report_over_100k_files_stay_inside_the_budget(self):
        engines = ['probe', 'check', 'audio']
        words = ['OK', 'Warning', 'Problem']
        old = {sha_of(n): dict(stratum='s%d' % (n % 12), probe='probed', check=words[n % 3], audio='healthy',
                               container='mov', vcodec='h264', acodec='aac', size=1, duration=1.0) for n in range(100_000)}
        new = {sha: dict(record, check=words[(i + (i % 10 == 0)) % 3]) for i, (sha, record) in enumerate(old.items())}
        with tempfile.TemporaryDirectory() as tmp:
            scene = CorpusScene(tmp)
            lane = cr.Lane(scene.seal, 'check', 'c' * 40, 's', pathlib.Path(tmp), pathlib.Path(tmp), pathlib.Path(tmp),
                           pathlib.Path(tmp))
            t0 = time.monotonic()
            delta = cr.diff(old, new, engines)
            report = lane.report(new, {}, 1.0)
            text = cr.render(report)
            elapsed = time.monotonic() - t0
        self.assertEqual((delta['compared'], delta['changed']), (100_000, 10_000))
        self.assertEqual(len(delta['moved']), 10_000)
        self.assertEqual(report['files'], 100_000)
        self.assertEqual(sum(report['engines']['check'].values()), 100_000)
        self.assertLess(len(text), 40, 'the summary is a table, not a list of files')
        self.assertLess(elapsed, 5.0, f'{elapsed:.2f}s for 100k files')

    def test_settle_ignores_a_cut_line_and_unknown_files(self):
        results = {'a': {}, 'b': {}}
        events = [dict(ev='begin', sha='zzz'), dict(ev='begin', sha='a'),
                  dict(ev='engine', sha='a', engine='probe', outcome='probed'), dict(ev='end', sha='a'),
                  dict(ev='begin', sha='b')]
        settled, refusal = cr.settle(events, ['probe', 'check'], results)
        self.assertEqual((settled, refusal), (2, None))
        self.assertEqual((results['a']['probe'], results['a']['check']), ('probed', 'not_run'))
        self.assertEqual((results['b']['probe'], results['b']['check']), ('crash', 'not_run'))


class CallerTests(unittest.TestCase):
    """The front door (scripts/corpus_run.sh) and the lane hook in scripts/m4_run.sh: --dry-run only."""

    def run_sh(self, script, *args):
        return subprocess.run(['/bin/bash', str(SCRIPTS / script), *args], capture_output=True, text=True, timeout=60)

    def test_run_check_ships_the_harness_and_never_runs_on_the_ultra(self):
        sha = subprocess.run(['git', '-C', str(REPO), 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
        p = self.run_sh('corpus_run.sh', 'run', 'check', '--ref', 'HEAD', '--deadline', '120', '--limit', '5', '--dry-run')
        self.assertEqual(p.returncode, 0, p.stderr)
        out = p.stdout
        self.assertIn('m4_run: corpus on M4', out)
        self.assertIn(f'push -q ricksm4.local:dev/VideoScan {sha}:refs/m4run/{sha}', out)
        for name in ('corpus_run.py', 'catalog_db.py', 'CorpusSeal.swift', 'CorpusDriverSupport.swift', 'CorpusCheckDriver.swift',
                     'CorpusProofDriver.swift', 'CorpusVerbsDriver.swift', 'testbed_lock.py'):
            self.assertRegex(out, rf'install .*{name} -> ricksm4\.local:.*/m4run/bin/\d{{8}}_\d{{6}}_\d+/{name}')
        for arg in ('__host', 'corpus', sha, '--corpus-lane', 'check', '--deadline', '120', '--limit', '5'):
            self.assertIn(f'<string>{arg}</string>', out)
        self.assertIn("refused unless the hostname is the M4's and the state root is under ~/corpus/state", out)
        self.assertIn('/m4run/lock', out)
        self.assertNotIn('ultrarun', out)

    def test_prepare_and_status_dry_runs(self):
        p = self.run_sh('corpus_run.sh', 'prepare', '--dry-run')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('<string>prepare</string>', p.stdout)
        p = self.run_sh('corpus_run.sh', 'status', '--dry-run')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('/m4run/lock', p.stdout)
        self.assertIn('ssh ricksm4.local python3 - status', p.stdout)

    def test_usage_errors_exit_2(self):
        for args in ([], ['bogus'], ['run'], ['run', 'delete'], ['accept'], ['accept', 'everything'], ['accept', 'check', 'extra'],
                     ['run', 'check', '--deadline', 'soon', '--dry-run'],
                     ['run', 'check', '--host', 'ultra', '--dry-run'], ['run', 'check', '--only', 'X', '--dry-run']):
            with self.subTest(args=args):
                self.assertEqual(self.run_sh('corpus_run.sh', *args).returncode, 2, args)

    def test_the_corpus_lane_is_m4_only_in_the_runner_itself(self):
        for args in (['corpus', '--corpus-lane', 'check', '--host', 'ultra', '--dry-run'],
                     ['corpus', '--dry-run'], ['corpus', '--corpus-lane', 'trash', '--dry-run'],
                     ['ui', '--corpus-lane', 'check', '--dry-run'], ['deep', '--limit', '3', '--dry-run'],
                     ['__host', 'corpus', 'a' * 40, 's1', '--host', 'ultra', '--corpus-lane', 'check'],
                     ['__host', 'corpus', 'a' * 40, 's1', '--host', 'm4']):
            with self.subTest(args=args):
                p = self.run_sh('m4_run.sh', *args)
                self.assertEqual(p.returncode, 2, (args, p.stdout, p.stderr))

    def test_the_host_side_of_a_corpus_lane_does_nothing_on_a_mac_that_is_not_the_m4(self):
        # Codex #311 F5: `--host m4` is a label. `__host corpus|testbed … --host m4` on the Ultra used to
        # reach the worktree checkout and the run folder before corpus_run.py's own guard said no.
        with tempfile.TemporaryDirectory() as home:
            for name in ('RicksUltra', 'ricksm5', ''):
                env = dict(os.environ, HOME=home, PATH=f"{as_the_m4(home, name)}:{os.environ['PATH']}")
                for args in (['__host', 'corpus', 'a' * 40, 's1', '--host', 'm4', '--corpus-lane', 'check'],
                             ['__host', 'corpus', 'a' * 40, 's1', '--host', 'm4', '--corpus-lane', 'verbs'],
                             ['__host', 'testbed', 'a' * 40, 's1', '--host', 'm4']):
                    p = subprocess.run(['/bin/bash', str(SCRIPTS / 'm4_run.sh'), *args], capture_output=True, text=True, env=env, timeout=60)
                    self.assertEqual(p.returncode, 2, (name, args, p.stderr))
                    self.assertIn('this Mac is not the M4', p.stderr)
            self.assertEqual(sorted(os.listdir(home)), ['hostname-tools'], 'a refused host-side run created something')
        self.assertIn('runs only on the M4', self.run_sh('m4_run.sh', 'corpus', '--corpus-lane', 'check', '--host', 'ultra').stderr)

    def test_the_scripts_name_no_credential_and_no_catalog_file(self):
        for name in ('corpus_run.sh', 'corpus_run.py'):
            text = (SCRIPTS / name).read_text()
            for word in ('share.credentials', 'password', 'smb://'):
                self.assertNotIn(word, text, f'{name}: {word}')
        self.assertNotIn('catalog.sqlite', (SCRIPTS / 'corpus_run.sh').read_text())


STUB_HELPER = r'''#!/usr/bin/env python3
# Stand-in for corpus_run.py on the host: records its argv, writes the summary, exits as told.
import json, os, sys
args = sys.argv[1:]
out = args[args.index("--out") + 1]
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "helper-calls.jsonl"), "a") as f:
    f.write(json.dumps({"args": args, "lock_fd": os.path.exists("/dev/fd/9")}) + "\n")
code = int(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "helper-exit")).read())
if code != 99:
    open(os.path.join(out, "corpus-summary.txt"), "w").write("corpus check: counts only\n")
sys.exit(code)
'''


def as_the_m4(folder, name='RicksM4'):
    """A folder holding a stand-in `hostname` that answers as the M4 (or as `name`): first on a test's PATH."""
    tools = pathlib.Path(folder, 'hostname-tools')
    tools.mkdir(exist_ok=True)
    (tools / 'hostname').write_text(f'#!/bin/sh\necho {name}\n')
    (tools / 'hostname').chmod(0o755)
    return tools


class HostHookTests(unittest.TestCase):
    """`m4_run.sh __host corpus` in a fake HOME with a stub helper beside the runner (as on the
    host, where both are installed in <root>/bin/<stamp>/): under the lock, after the checkout,
    it hands over with the run's facts, and maps the helper's exit to GREEN / AMBER / RED."""

    def host(self, code, stamp):
        with tempfile.TemporaryDirectory() as home:
            root, bin_dir = pathlib.Path(home, 'm4run'), pathlib.Path(home, 'bin')
            work = root / 'work'
            work.mkdir(parents=True)
            bin_dir.mkdir()
            for name in ('m4_run.sh', 'm4_run_summary.py', 'testbed_lock.py'):
                (bin_dir / name).write_bytes((SCRIPTS / name).read_bytes())
            (bin_dir / 'corpus_run.py').write_text(STUB_HELPER)
            (bin_dir / 'helper-exit').write_text(str(code))
            env = dict(os.environ, HOME=home, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t', GIT_COMMITTER_NAME='t',
                       GIT_COMMITTER_EMAIL='t@t', PATH=f"{as_the_m4(home)}:{os.environ['PATH']}")
            (work / 'file').write_text('x')
            for command in (['init', '-q'], ['add', '-A'], ['commit', '-q', '-m', 'testbed']):
                subprocess.run(['git', '-C', str(work), *command], check=True, env=env)
            sha = subprocess.run(['git', '-C', str(work), 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
            p = subprocess.run(['/bin/bash', str(bin_dir / 'm4_run.sh'), '__host', 'corpus', sha, stamp, '--host', 'm4',
                                '--corpus-lane', 'check', '--deadline', '90', '--limit', '4'],
                               capture_output=True, text=True, env=env, timeout=120)
            log = (root / f'out/{stamp}-corpus/run.log').read_text()
            calls = [json.loads(line) for line in (bin_dir / 'helper-calls.jsonl').read_text().splitlines()]
            probe = subprocess.run([sys.executable, str(SCRIPTS / 'testbed_lock.py'), 'probe', str(root / 'lock')],
                                   capture_output=True, text=True, timeout=20).stdout.strip()
            return p.returncode, log, calls, probe, sha, root

    def test_green_hands_over_the_runs_facts_under_the_lock(self):
        rc, log, calls, probe, sha, root = self.host(0, 'h0')
        self.assertEqual(rc, 0, log)
        self.assertIn(f'START', log)
        self.assertIn('lane=corpus corpus-lane=check', log)
        self.assertIn('OUTCOME GREEN', log)
        self.assertIn('corpus check: counts only', log)
        args = calls[0]['args']
        self.assertEqual(args[:2], ['host', 'check'])
        for flag, value in (('--sha', sha), ('--stamp', 'h0'), ('--out', str(root / 'out/h0-corpus')),
                            ('--worktree', str(root / 'work')), ('--deadline', '90'), ('--limit', '4')):
            self.assertEqual(args[args.index(flag) + 1], value, flag)
        self.assertTrue(calls[0]['lock_fd'], 'the helper must inherit the testbed lock (fd 9)')
        self.assertEqual(probe, 'FREE')

    def test_amber_and_red_follow_the_helpers_exit(self):
        rc, log, _, probe, _, _ = self.host(3, 'h3')
        self.assertEqual(rc, 0, log)
        self.assertIn('OUTCOME AMBER', log)
        for code in (1, 2):
            rc, log, _, probe, _, _ = self.host(code, f'h{code}')
            self.assertEqual(rc, 1, log)
            self.assertIn('OUTCOME RED', log)
            self.assertEqual(probe, 'FREE')
        rc, log, _, probe, _, _ = self.host(4, 'h4')
        self.assertEqual(rc, 1, log)
        self.assertRegex(log, r'(?m)^OUTCOME NORUN .* lane=corpus sha=\w+ — corpus check: this ref has no engine for the lane$')

    def test_a_corpus_run_leaves_latest_suite_alone_and_status_still_shows_the_suite(self):
        # main's suite lane keeps <root>/latest-suite so `status` shows the last suite verdict
        # after a later run of another lane: a corpus run repoints `latest` only.
        with tempfile.TemporaryDirectory() as home:
            root, bin_dir = pathlib.Path(home, 'm4run'), pathlib.Path(home, 'bin')
            work, suite_out = root / 'work', root / 'out' / 'old-suite'
            work.mkdir(parents=True)
            suite_out.mkdir(parents=True)
            bin_dir.mkdir()
            (suite_out / 'run.log').write_text('START then lane=suite sha=abc\nOUTCOME GREEN then lane=suite sha=abc\n')
            (suite_out / 'summary.txt').write_text('suite: GREEN app 9 passed\n')
            os.symlink(suite_out, root / 'latest-suite')
            os.symlink(suite_out, root / 'latest')
            for name in ('m4_run.sh', 'm4_run_summary.py', 'testbed_lock.py'):
                (bin_dir / name).write_bytes((SCRIPTS / name).read_bytes())
            (bin_dir / 'corpus_run.py').write_text(STUB_HELPER)
            (bin_dir / 'helper-exit').write_text('0')
            env = dict(os.environ, HOME=home, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t', GIT_COMMITTER_NAME='t',
                       GIT_COMMITTER_EMAIL='t@t', PATH=f"{as_the_m4(home)}:{os.environ['PATH']}")
            (work / 'file').write_text('x')
            for command in (['init', '-q'], ['add', '-A'], ['commit', '-q', '-m', 'testbed']):
                subprocess.run(['git', '-C', str(work), *command], check=True, env=env)
            sha = subprocess.run(['git', '-C', str(work), 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
            p = subprocess.run(['/bin/bash', str(bin_dir / 'm4_run.sh'), '__host', 'corpus', sha, 'c1', '--host', 'm4',
                                '--corpus-lane', 'check'], capture_output=True, text=True, env=env, timeout=120)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(os.readlink(root / 'latest-suite'), str(suite_out), 'a corpus run overwrote latest-suite')
            self.assertEqual(os.readlink(root / 'latest'), str(root / 'out/c1-corpus'))
            dry = subprocess.run(['/bin/bash', str(SCRIPTS / 'm4_run.sh'), 'status', '--dry-run'], capture_output=True,
                                 text=True, env=env, timeout=60).stdout
            snippet = dry.split("+ ssh ricksm4.local <<'SH'", 1)[1].split('\n  SH', 1)[0]
            snippet = '\n'.join(line[4:] if line.startswith('    ') else line for line in snippet.splitlines())
            out = subprocess.run(['/bin/bash', '-s'], input=snippet, capture_output=True, text=True, env=env, timeout=30).stdout
            self.assertIn('lane=corpus corpus-lane=check', out)
            self.assertIn('corpus check: counts only', out)
            self.assertIn(f'last suite run: {suite_out}', out)
            self.assertIn('suite: GREEN app 9 passed', out)

    def test_a_helper_that_dies_without_a_summary_is_red_and_says_so(self):
        rc, log, _, _, _, _ = self.host(99, 'h99')
        self.assertEqual(rc, 1, log)
        self.assertIn('RED no summary was written', log)


if __name__ == '__main__':
    unittest.main()
