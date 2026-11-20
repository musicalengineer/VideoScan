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
import testbed_host as th  # noqa: E402
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
    if plan.get("build_touch"):                          # a file of the corpus changes while the build runs (Codex #336 F2)
        path, data = plan["build_touch"]
        open(path, "w").write(data)
    dd = args[args.index("-derivedDataPath") + 1]
    os.makedirs(dd + "/Build/Products", exist_ok=True)
    with open(dd + "/Build/Products/VideoScan_VideoScan-CI_macosx.xctestrun", "wb") as f:
        plistlib.dump({"TestConfigurations": [{"TestTargets": [
            {"BlueprintName": "VideoScanTests", "TestHostPath": "__TESTROOT__/Debug/VideoScan.app",
             "TestBundlePath": "__TESTHOST__/Contents/PlugIns/VideoScanTests.xctest",
             "EnvironmentVariables": {"KEPT": "1", "OS_ACTIVITY_DT_MODE": "YES"}, "SkipTestIdentifiers": ["Some/test"]}]}]}, f)
    # A newer plan file with no unit-test target (as the UI plans' are): it names VideoScanTests only in passing.
    with open(dd + "/Build/Products/VideoScan_VideoScan-UI_macosx.xctestrun", "wb") as f:
        plistlib.dump({"TestPlan": {"Note": "VideoScanTests"}, "TestConfigurations": [{"TestTargets": [
            {"BlueprintName": "VideoScanUITests", "TestBundlePath": "__TESTHOST__/VideoScanUITests.xctest"}]}]}, f)
    os.utime(dd + "/Build/Products/VideoScan_VideoScan-CI_macosx.xctestrun", (1, 1))
    binary = dd + "/Build/Products/Debug/VideoScan.app/Contents/PlugIns/VideoScanTests.xctest/Contents/MacOS"
    os.makedirs(binary, exist_ok=True)
    overlay = os.path.join(os.getcwd(), "VideoScan/VideoScanTests/CorpusHarnessOverlay")
    with open(binary + "/VideoScanTests", "w") as f:     # the test binary: what was compiled into it
        f.write("built " + ",".join(sorted(os.listdir(overlay))) if os.path.isdir(overlay) else "built without drivers")
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
                        "clones_exist": all(os.path.isfile(p) for i in config["pending"] for p in [i["path"]] + (i.get("copies") or [])),
                        "work_files": sorted(os.listdir(config["work"]))}) + "\n")
if plan.get("remove") and os.path.lexists(plan["remove"]):   # the world changes under the run (Codex #331 F2)
    os.remove(plan["remove"])
if plan.get("vandal"):                                   # an engine that reaches the pristine corpus (it must turn the lane RED)
    os.utime(plan["vandal"], (5, 5))
if plan.get("litter"):                                   # what a balancing engine leaves when the host dies mid-copy
    open(os.path.join(config["work"], plan["litter"] + "-" + str(len(os.listdir(config["work"])))), "w").write("partial")
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
# `jobs` files in flight (CorpusPool): each group of `jobs` begins together and its lines interleave, engine by
# engine, as N concurrent files' do. jobs = 1 is one file after another — the serial driver's exact order.
jobs = max(1, int(config.get("jobs") or 1))
pending = config["pending"]
for first in range(0, len(pending), jobs):
    group = pending[first:first + jobs]
    for item in group:
        how = plan["files"].get(item["sha"], {})
        say(ev="begin", sha=item["sha"])
        say(ev="facts", sha=item["sha"], container=how.get("container", "mov,mp4,m4a,3gp,3g2,mj2"), vcodec=how.get("vcodec", "h264"),
            acodec=how.get("acodec", "aac"), duration=60.0, bytes=1)
    for engine in engines:
        for item in group:
            how = plan["files"].get(item["sha"], {})
            if how.get("together_only") and jobs == 1:          # a fault only files in flight together cause
                how = {}
            if how.get("crash") == engine:
                out.write('{"ev": "engine", "sha": "cut-mid-li')        # a line cut by the crash
                out.flush(); os._exit(139)
            if how.get("timeout") == engine:
                say(ev="engine", sha=item["sha"], engine=engine, outcome="timeout", s=1.0)
                say(ev="end", sha=item["sha"], cut=True); os._exit(86)
            say(ev="engine", sha=item["sha"], engine=engine, outcome=how.get(engine, "OK"), kinds=how.get(engine + "_kinds", []), s=0.5)
    for item in group:
        if plan["files"].get(item["sha"], {}).get("crash") == "end":    # every engine answered; the host dies before `end`
            os._exit(139)
        say(ev="end", sha=item["sha"])
if config["lane"] == "verbs":
    say(ev="verbs", trashFiles=plan.get("trash_files", 0), trashedByEngines=plan.get("trash_files", 0),
        strayTrashFiles=plan.get("stray", 0), receiptsInRun=plan.get("receipts", [0, 0])[0],
        receiptsOutsideTheRun=plan.get("receipts", [0, 0])[1], records=len(config["pending"]))
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
        self.registered = {}
        self.seal.hasher = self.fake_hash
        self.files = list(self.FILES)
        self.write_documents()
        for n, original, size, _ in self.files:
            self.put(self.corpus / 'media' / original.lstrip('/'), b'x' * size, sha_of(n))
        self.build_source()

    def put(self, path, data, sha):
        """Write a fake media file that STANDS FOR the content `sha` (its bytes, as written, hash to it)."""
        path = pathlib.Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        self.registered[os.path.realpath(path)] = (hashlib.sha256(data).hexdigest(), sha)

    def fake_hash(self, path, size):
        """The real read (size, stability, no link), then: the bytes the scene wrote stand for their manifest
        SHA-256; any other bytes are what they are (a tampered file is mismatched)."""
        got = cr.sha256_file(path, size)
        if got is None:
            return None
        real, written = got[0], self.registered.get(os.path.realpath(path))
        return ((written[1] if written and written[0] == real else real),) + got[1:]

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
        cr.sealed_state_ready(self.scene.seal, entries, cr.current_states(self.scene.seal, entries))
        record = self.scene.seal.state / 'prepare.json'
        for poison in (json.dumps(dict(json.loads(record.read_text()), transform_version=1)), '{not json', '[]'):
            record.write_text(poison)
            with self.assertRaises(cr.Refused) as refused:
                cr.sealed_state_ready(self.scene.seal, entries, cr.current_states(self.scene.seal, entries))
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
                         sorted([DB, LATCH, 'prepare.json', 'home', 'caches', cr.LEDGER]))
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

    def test_a_missing_or_resized_corpus_file_is_missing_never_a_refusal(self):
        # DECISIONS 2026-11-19, the wish list: a file not there yet, or not whole yet, is `missing`.
        (self.scene.corpus / 'media' / self.scene.files[0][1].lstrip('/')).unlink()
        (self.scene.corpus / 'media' / self.scene.files[1][1].lstrip('/')).write_bytes(b'short')
        code, lines = cr.prepare(self.scene.seal)
        self.assertEqual(code, cr.EXIT_GREEN, lines)
        self.assertIn('GREEN 1 rows for 3 manifest files', lines[0])
        self.assertIn('  files: internal present 1 · missing 2', lines)

    def test_a_manifest_entry_without_its_one_live_row_is_refused(self):
        self.scene.files.append((40, '/Volumes/PrivateDrive/Grandma/not in the backup.mov', 9, 'raw DV'))
        self.scene.write_documents()
        self.scene.put(self.scene.corpus / 'media' / self.scene.files[-1][1].lstrip('/'), b'x' * 9, sha_of(40))
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
        (self.scene.corpus / 'media' / self.scene.files[2][1].lstrip('/')).unlink()   # the set changes: a rebuild is due
        pathlib.Path(str(self.scene.source) + '-wal').write_bytes(b'')                    # and the backup is not a finished one
        self.refused('not a finished backup')
        self.assertEqual((self.scene.seal.state / DB).read_bytes(), before)

    def test_a_file_that_went_away_or_changed_after_ingest_is_vanished_or_changed(self):
        cr.prepare(self.scene.seal)
        entries = cr.load_manifest(self.scene.seal)
        self.assertEqual(cr.verify_catalog(self.scene.seal, self.scene.seal.state / DB, entries)['ok'], 1)
        (self.scene.corpus / 'media' / self.scene.files[0][1].lstrip('/')).write_bytes(b'changed')
        (self.scene.corpus / 'media' / self.scene.files[1][1].lstrip('/')).unlink()
        states = cr.current_states(self.scene.seal, entries)
        self.assertEqual(sorted(states.values()), ['changed', 'present', 'vanished'])
        cr.sealed_state_ready(self.scene.seal, entries, states)            # the catalog still stands: only the present file runs


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

    def run(self, lane='check', sha='a' * 40, stamp='20261117_120000_1', jobs=1, **extra):
        """jobs=1 (one file at a time, the serial order every older test pinned) unless a test asks for N;
        jobs=None leaves the flag off: the host's own default."""
        self.plan_path.write_text(json.dumps(self.plan))
        os.environ['FAKE_PLAN'] = str(self.plan_path)
        os.environ['FAKE_CP_CALLS'] = str(self.cp_calls)
        argv = ['host', lane, '--sha', sha, '--stamp', stamp, '--out', str(self.out), '--worktree', str(self.worktree),
                '--derived-data', str(self.dd), '--bin', str(SCRIPTS / 'corpus')]
        if jobs is not None:
            argv += ['--jobs', str(jobs)]
        for key, value in extra.items():
            argv += ['--' + key] + ([str(value)] if value != '' else [])
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
        (first / 'report.json').write_text(json.dumps(dict(lane='check', sha='a' * 40, failures={}, engine_present=True, files=500)))
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
                      'guard mkdir(trash, 0o755) == 0, CorpusRun.inRun(trash, config.work), VerbsStage.isEmptyFolder(trash)',
                      'hooks.trashItem = { url in try VerbsTrash.move(url, into: trash, work: work) }',
                      'fileOperation: { url in _ = try VerbsTrash.move(url, into: trash, work: work) }',
                      'guard CorpusRun.inRun(url.path, work), CorpusRun.inRun(trash, work), VerbsStage.isRealFolder(trash)',
                      'VerbsStage.digests(in: MediaTrash.testHostTrash.path).files', '"strayTrashFiles": stray',
                      'CorpusRun.inRun(archive, CorpusRun.realHome() + "/corpus/work")', 'refuse("archive_root_outside_corpus_work")',
                      'refuse("trash_not_in_the_run")', 'refuse("a_verbs_file_is_not_a_clone")', 'CorpusRun.inRun(root, run.config.work)',
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
struct Case: Decodable { let hostname, realHome, configPath, lane, home, appSupport: String; let isTestHost: Bool
                     let afterOpen: [[String]]? }
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
    let first = loaded.config?.pending.first?.path ?? "/"
    let atOpen = CorpusSeal.external(realHome: c.realHome)
    for op in c.afterOpen ?? [] {            // the world changes between the open and the next engine (Codex #331-#333)
        switch op[0] {
        case "move": try FileManager.default.moveItem(atPath: op[1], toPath: op[2])
        case "remove": try FileManager.default.removeItem(atPath: op[1])
        case "symlink": try FileManager.default.createSymbolicLink(atPath: op[2], withDestinationPath: op[1])
        case "write": try Data(op[2].utf8).write(to: URL(fileURLWithPath: op[1]))
        default:
            let task = Process()
            task.executableURL = URL(fileURLWithPath: op[1])
            task.arguments = Array(op.dropFirst(2))
            try task.run()
            task.waitUntilExit()
        }
    }
    let folders = loaded.config.map { CorpusSeal.runFoldersOnHome($0, realHome: c.realHome) } ?? false
    print("\(word ?? "ok")|\(reads)|\(proven)|\(atOpen.word)|\(CorpusSeal.mayOpen(first, realHome: c.realHome, atOpen: atOpen))|\(folders)")
}
"""


_SEAL_BUILD = []


def seal_binary():
    """CorpusSeal.swift compiled beside SEAL_MAIN, once per test process."""
    if not _SEAL_BUILD:
        build = tempfile.TemporaryDirectory()
        main = pathlib.Path(build.name, 'main.swift')
        main.write_text(SEAL_MAIN)
        binary = pathlib.Path(build.name, 'seal')
        done = subprocess.run(['swiftc', '-o', str(binary), str(SCRIPTS / 'corpus' / 'CorpusSeal.swift'), str(main)],
                              capture_output=True, text=True, timeout=600)
        if done.returncode != 0:
            raise AssertionError('CorpusSeal.swift does not compile by itself:\n' + done.stdout + done.stderr)
        _SEAL_BUILD.extend([build, binary])
    return _SEAL_BUILD[1]


@unittest.skipUnless(shutil.which('swiftc'), 'needs the Swift compiler')
class SwiftSealTests(unittest.TestCase):
    """Codex #311 F9: the in-app seal pinned by BEHAVIOUR. scripts/corpus/CorpusSeal.swift (Foundation only) is
    compiled beside a small main and asked about real folders — symlinks included."""

    @classmethod
    def setUpClass(cls):
        cls.binary = seal_binary()

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
        self.facts = [line.split('|')[:3] for line in done.stdout.split()]   # [word, config reads, progress proven]
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
            self.assertFalse(cr.remove_tree(self.scene.seal, work), 'a tree holding a locked second name cannot go whole')
            self.assertTrue(os.lstat(victim).st_flags & 0x2, 'the pristine file was unlocked through its second name')
            self.assertFalse(os.path.lexists(own), "the run's own locked file was not unlocked and removed")
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
                cr.sealed_state_ready(self.scene.seal, cr.load_manifest(self.scene.seal), cr.current_states(self.scene.seal, cr.load_manifest(self.scene.seal)))
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
                mark = self.scene.dd / cr.BUILD_MARK
                if mark.exists():
                    mark.unlink()                                           # a build happens, so its log is opened
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
                      'guard mkdir(path, 0o755) == 0, CorpusRun.inRun(path, scratch), CorpusRun.inRun(path, run.config.work)',
                      'guard CorpusRun.inRun(scratch, run.config.work), mkdir(plans, 0o755) == 0, CorpusRun.inRun(plans, run.config.work)'):
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
            cr.sealed_state_ready(self.scene.seal, cr.load_manifest(self.scene.seal), cr.current_states(self.scene.seal, cr.load_manifest(self.scene.seal)))
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
            for name in ('m4_run.sh', 'm4_run_summary.py', 'testbed_lock.py', 'testbed_host.py'):
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
            for name in ('m4_run.sh', 'm4_run_summary.py', 'testbed_lock.py', 'testbed_host.py'):
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
        self.assertIn('corpus check: RED the harness stopped (rc=99; see corpus.log on the M4)', log)


# Stand-in for corpus_run.py that misbehaves on purpose (Codex #315-3): it lays its summary down as a
# LINK to a private file, writes a summary line that names a file, or both, then exits as told.
ROGUE_HELPER = r"""#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
out = args[args.index("--out") + 1]
here = os.path.dirname(os.path.abspath(__file__))
mode = open(os.path.join(here, "rogue-mode")).read().split()
summary = os.path.join(out, "corpus-summary.txt")
if "link" in mode:
    os.symlink(os.path.join(here, "private.txt"), summary)
if "name" in mode:
    open(summary, "w").write("corpus check: GREEN 3 files\n  Grandma Birthday 1988.mov: OK\n  check: OK 3\n")
if "prompt" in mode:
    print("corpus: RED refused: macOS is waiting for permission to read the external volume (a privacy prompt on the "
          "M4's screen; the probe got no answer in 20 s). Grandma Birthday 1988.mov", file=sys.stderr)
if "denied" in mode:
    print("corpus: RED refused: macOS does not let this Python read the external volume (Operation not permitted).",
          file=sys.stderr)
sys.exit(int(mode[0]))
"""

PRIVATE = 'Grandma said the Lake House secret'


class CodexRound3Tests(unittest.TestCase):
    """Codex #315 (round 3, block, 6 findings). Each test was seen RED with its fix taken back out."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = pathlib.Path(os.path.realpath(self.tmp.name), 'home')
        self.root = self.home / 'm4run'
        self.bin_dir = self.home / 'bin'
        self.work = self.root / 'work'
        self.work.mkdir(parents=True)
        self.bin_dir.mkdir()
        for name in ('m4_run.sh', 'm4_run_summary.py', 'testbed_lock.py', 'testbed_host.py'):
            (self.bin_dir / name).write_bytes((SCRIPTS / name).read_bytes())
        (self.bin_dir / 'corpus_run.py').write_text(ROGUE_HELPER)
        (self.bin_dir / 'private.txt').write_text(PRIVATE + '\n')
        self.victim = self.home / 'pristine.mov'
        self.victim.write_bytes(b'pristine bytes')
        self.env = dict(os.environ, HOME=str(self.home), GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t', GIT_COMMITTER_NAME='t',
                        GIT_COMMITTER_EMAIL='t@t', PATH=f"{as_the_m4(self.home)}:{os.environ['PATH']}")
        (self.work / 'file').write_text('x')
        for command in (['init', '-q'], ['add', '-A'], ['commit', '-q', '-m', 'testbed']):
            subprocess.run(['git', '-C', str(self.work), *command], check=True, env=self.env)
        self.sha = subprocess.run(['git', '-C', str(self.work), 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()

    def tearDown(self):
        self.tmp.cleanup()

    def host(self, stamp, mode='0'):
        (self.bin_dir / 'rogue-mode').write_text(mode)
        return subprocess.run(['/bin/bash', str(self.bin_dir / 'm4_run.sh'), '__host', 'corpus', self.sha, stamp, '--host', 'm4',
                               '--corpus-lane', 'check'], capture_output=True, text=True, env=self.env, timeout=120)

    def status(self):
        dry = subprocess.run(['/bin/bash', str(SCRIPTS / 'm4_run.sh'), 'status', '--dry-run'], capture_output=True, text=True,
                             env=self.env, timeout=60).stdout
        snippet = dry.split("+ ssh ricksm4.local <<'SH'", 1)[1].split('\n  SH', 1)[0]
        snippet = '\n'.join(line[4:] if line.startswith('    ') else line for line in snippet.splitlines())
        return subprocess.run(['/bin/bash', '-s'], input=snippet, capture_output=True, text=True, env=self.env, timeout=60).stdout

    # 1 — persistent writers

    def test_1_a_persistent_file_that_is_a_second_name_of_a_corpus_file_is_never_written(self):
        scene = CorpusScene(self.tmp.name + '/scene')
        media = scene.corpus / 'media' / scene.files[0][1].lstrip('/')
        before = media.read_bytes()
        scene.seal.mkdir(scene.seal.state)
        os.link(media, scene.seal.state / 'prepare.json')                 # a hard link: no symlink to see
        with self.assertRaises(cr.Refused) as refused:
            cr.prepare(scene.seal)
        self.assertIn('second name', str(refused.exception))
        self.assertEqual(media.read_bytes(), before)
        (scene.seal.state / 'prepare.json').unlink()
        os.symlink(media, scene.seal.state / 'prepare.json')
        with self.assertRaises(cr.Refused):
            cr.prepare(scene.seal)
        self.assertEqual(media.read_bytes(), before)

    def test_1_the_baseline_history_is_never_appended_through_a_second_name(self):
        scene = LaneScene(self.tmp.name + '/lane')
        media = scene.corpus / 'media' / scene.files[1][1].lstrip('/')
        before = media.read_bytes()
        scene.run()
        os.link(media, scene.seal.reports / 'check' / cr.BASELINE_LOG)
        with self.assertRaises(cr.Refused):
            cr.accept(scene.seal, 'check', 'x')
        self.assertEqual(media.read_bytes(), before)
        for writer in (lambda p: scene.seal.write_text(p, 'x'), lambda p: scene.seal.write_json(p, {'a': 1})):
            target = scene.seal.reports / 'check' / 'some.json'
            os.link(media, target)
            with self.assertRaises(cr.Refused):
                writer(target)
            target.unlink()
        self.assertEqual(media.read_bytes(), before)

    # 2 — the shell's own writes

    def test_2_a_run_folder_that_is_already_there_is_never_written_into(self):
        for how in ('symlink', 'hardlink'):
            with self.subTest(how=how):
                stamp = 'pre' + how
                out = self.root / 'out' / f'{stamp}-corpus'
                out.mkdir(parents=True)
                for name in ('run.log', 'summary.txt'):
                    (os.symlink if how == 'symlink' else os.link)(self.victim, out / name)
                p = self.host(stamp)
                self.assertEqual(p.returncode, 4, p.stderr)
                self.assertIn('a run folder is made new, never reused', p.stderr)
                self.assertEqual(self.victim.read_bytes(), b'pristine bytes', 'the shell truncated a file it did not make')

    def test_2_an_aliased_m4run_or_out_folder_is_refused_by_the_shell_and_by_the_seal(self):
        elsewhere = self.home / 'Documents'
        elsewhere.mkdir()
        os.symlink(elsewhere, self.root / 'out')
        p = self.host('alias1')
        self.assertEqual(p.returncode, 4, p.stderr)
        self.assertIn('symlink', p.stderr)
        self.assertEqual(sorted(os.listdir(elsewhere)), [])
        seal = cr.Seal(self.home, 'ricksm4')
        (elsewhere / 'run1-corpus').mkdir()
        with self.assertRaises(cr.Refused) as refused:
            seal.out_folder(self.root / 'out' / 'run1-corpus')
        self.assertIn('~/m4run or ~/m4run/out', str(refused.exception))
        os.unlink(self.root / 'out')
        real_root = self.home / 'm4run-real'
        shutil.move(str(self.root), str(real_root))
        os.symlink(real_root, self.root)
        p = self.host('alias2')
        self.assertEqual(p.returncode, 4, p.stderr)

    def test_2_the_bounded_runner_never_appends_its_log_through_a_link(self):
        text = (SCRIPTS / 'm4_run.sh').read_text()
        function = text[text.index('run_bounded() {'):text.index('\n}\n', text.index('run_bounded() {')) + 3]
        for how in ('symlink', 'hardlink'):
            with self.subTest(how=how):
                log = self.home / f'{how}.log'
                (os.symlink if how == 'symlink' else os.link)(self.victim, log)
                script = function + f'\nrun_bounded 30 {log} {self.home} /bin/echo appended\n'
                p = subprocess.run(['/bin/bash', '-c', script], capture_output=True, text=True, env=self.env, timeout=60)
                self.assertEqual(p.returncode, 125, p.stdout + p.stderr)
                self.assertEqual(self.victim.read_bytes(), b'pristine bytes')
                log.unlink()

    # 3 — reading a summary back

    def test_3_a_refusing_helpers_linked_summary_is_never_read_back(self):
        p = self.host('leak1', '2 link')
        self.assertEqual(p.returncode, 1, p.stderr)
        out = self.root / 'out' / 'leak1-corpus'
        text = (out / 'run.log').read_text() + (out / 'summary.txt').read_text() + self.status()
        self.assertNotIn(PRIVATE, text)
        self.assertIn('corpus check: RED refused by the harness (rc=2', text)

    def test_3_a_privacy_refusal_is_named_in_fixed_words_in_the_summary_and_status(self):
        # Night of 11/19: the summary said only "the reason is in corpus.log on the M4"; the fix
        # (click Allow, or grant the interpreter) was one ssh away. Fixed words only: no log text is copied.
        for stamp, mode, want in (('tcc1', '2 prompt', 'waiting for a privacy prompt on its screen'),
                                  ('tcc2', '2 denied', 'macOS denied this Python access')):
            with self.subTest(mode=mode):
                p = self.host(stamp, mode)
                self.assertEqual(p.returncode, 1, p.stderr)
                summary = (self.root / 'out' / f'{stamp}-corpus' / 'summary.txt').read_text()
                status = self.status()
                text = summary + status
                self.assertIn('corpus check: RED refused by the harness (rc=2', summary)
                self.assertIn(want, summary)
                self.assertIn('Removable Volumes', summary)
                self.assertIn(want, status)
                self.assertNotIn('Birthday', text)
        p = self.host('tcc3', '2')
        summary = (self.root / 'out' / 'tcc3-corpus' / 'summary.txt').read_text()
        self.assertNotIn('privacy', summary)

    def test_3_a_summary_that_is_a_link_or_names_a_file_is_withheld_even_when_the_helper_finished(self):
        p = self.host('leak2', '0 link')
        text = (self.root / 'out' / 'leak2-corpus' / 'summary.txt').read_text() + self.status()
        self.assertNotIn(PRIVATE, text)
        self.assertIn('(withheld: not a file of this run)', text)
        p = self.host('leak3', '0 name')
        self.assertEqual(p.returncode, 0, p.stderr)
        text = (self.root / 'out' / 'leak3-corpus' / 'summary.txt').read_text() + self.status()
        self.assertNotIn('Birthday', text)
        self.assertIn('(a line was withheld: it did not read as counts and words)', text)
        self.assertIn('  check: OK 3', text)

    def test_3_status_never_prints_a_file_it_cannot_prove(self):
        self.host('s1', '0')
        out = self.root / 'out' / 's1-corpus'
        (out / 'summary.txt').unlink()
        os.symlink(self.bin_dir / 'private.txt', out / 'summary.txt')
        with open(out / 'run.log', 'a') as f:
            f.write('OUTCOME GREEN 2026-11-18 01:00:00 lane=corpus sha=abc — /Volumes/PrivateDrive/Grandma/Birthday 1988.mov\n')
        text = self.status()
        self.assertNotIn(PRIVATE, text)
        self.assertNotIn('Birthday', text)
        self.assertIn('lane=corpus corpus-lane=check sha=' + self.sha, text, 'a commit id after sha= is not a digest')
        probe = self.home / 'probe.txt'
        probe.write_text('\n'.join(['digest ' + 'ab' * 32, 'sha=' + 'ab' * 32, 'part ' + 'ab' * 15, 'commit sha=' + 'a' * 40,
                                    'count 1234567']) + '\n')
        self.assertEqual(th.show(str(probe)), ['(a line was withheld: it did not read as counts and words)'] * 3
                         + ['commit sha=' + 'a' * 40, 'count 1234567'])
        private = self.bin_dir / 'private.txt'
        second = self.home / 'second-name.txt'
        os.link(private, second)                                        # a summary that is a second name of a private file
        self.assertEqual(th.show(str(second)), ['(withheld: not a plain file of this run)'])
        self.assertEqual(th.show(str(private), under=str(self.home)), ['(withheld: not a file of this run)'])

    # 4 — where the engines put their deletion receipts

    def test_4_the_lane_says_where_the_engines_receipts_went_and_moves_nothing(self):
        # Codex #315-4: Move to Trash and Delete Duplicates write a receipt into a folder the engines choose
        # (under a test host, the system temporary folder). They take no folder for it, and the lane does not
        # change an engine (MediaOps is data-risk): it records each receipt's place as a word and a count.
        scene = LaneScene(self.tmp.name + '/receipts')
        scene.plan['engines'] = VERBS
        scene.plan['files'] = {sha_of(0): dict(trash_copy='only_copy_warned:moved', trash_copy_kinds=['receipt_outside_the_run'],
                                               dedupe='skipped:2', dedupe_kinds=['receipt_outside_the_run'])}
        scene.plan['receipts'] = [0, 3]
        self.assertEqual(scene.run('verbs'), cr.EXIT_GREEN)
        summary = (scene.out / 'corpus-summary.txt').read_text()
        self.assertIn('deletion receipts the engines wrote: 0 inside the run, 3 outside it (the system temporary folder on the M4: '
                      'the engines take no folder for a receipt; recorded, not moved)', summary)
        self.assertIn('trash_copy[receipt_outside_the_run]', summary)
        driver = (SCRIPTS / 'corpus' / 'CorpusVerbsDriver.swift').read_text()
        for pin in ('lastReceipt = receiptWord(result.receipt)', 'let jobReceipt = receiptWord(job.receiptURL)',
                    '"receiptsOutsideTheRun": stage.receiptsOutsideTheRun', 'kinds: word.hasPrefix("refused:") ? [] : [lastReceipt]'):
            self.assertIn(pin, driver, pin)
        self.assertNotIn('DeletionReceipt(', driver, 'the lane makes no receipt of its own and moves none')



# ── v2: the corpus on two roots (DECISIONS 2026-11-19) ─────────────────────

class Volume:
    """A real APFS disk image attached at a folder of a temporary directory: the external root's stand-in.
    Real so the seal's questions (is it a mount, which volume UUID) are answered by macOS, not told."""

    def __init__(self, folder, name='X10'):
        self.folder = pathlib.Path(os.path.realpath(folder))
        self.image = str(self.folder / f'{name}.dmg')
        self.mount = self.folder / name
        made = subprocess.run(['hdiutil', 'create', '-size', '32m', '-fs', 'APFS', '-volname', 'corpustest', '-quiet', self.image],
                              capture_output=True, text=True, timeout=120)
        if made.returncode != 0:
            raise AssertionError('hdiutil could not make a disk image: ' + made.stderr)
        self.attach()

    def attach(self):
        self.mount.mkdir(exist_ok=True)
        done = subprocess.run(['hdiutil', 'attach', '-nobrowse', '-noverify', '-quiet', '-mountpoint', str(self.mount), self.image],
                              capture_output=True, text=True, timeout=120)
        if done.returncode != 0 or not os.path.ismount(str(self.mount)):
            raise AssertionError('hdiutil could not attach the disk image: ' + done.stderr)

    def detach(self):
        subprocess.run(['hdiutil', 'detach', '-force', '-quiet', str(self.mount)], capture_output=True, timeout=120)

    def uuid(self):
        return cr.diskutil_volume_uuid(str(self.mount))

    def empty(self):
        for child in self.mount.iterdir():
            if child.name.startswith('.'):
                continue
            shutil.rmtree(child) if child.is_dir() and not child.is_symlink() else child.unlink()


class TwoRootScene(LaneScene):
    """A v1 corpus (LaneScene's three files) that `grow()` makes v2: one large file more on the
    internal root and two on the external volume (a real disk image), the v2 manifest and lists,
    the source backup v2, the volume adopted, `prepare` run again."""

    V2_INTERNAL = [(10, '/Volumes/PrivateDrive/Lake House/reel_07 big.mxf', 9100, 'v2 large, one per container and codecs')]
    V2_EXTERNAL = [(11, '/Volumes/OtherDrive/Grandma/clip 1.mp4', 700, 'v2 every content under 8 GB'),
                   (12, '/Volumes/OtherDrive/Birthday/clip 2.mov', 800, 'v2 every content under 8 GB')]

    def __init__(self, tmp, volume, **kwargs):
        self.volume = volume
        super().__init__(tmp, **kwargs)
        self.seal.volumes = volume.folder

    def build_source(self):
        kept = self.files
        self.files = kept + self.V2_INTERNAL + self.V2_EXTERNAL     # the v2 backup is newer: it has every row
        try:
            super().build_source()
        finally:
            self.files = kept

    def ext_path(self, original):
        return self.volume.mount / 'corpus' / 'media' / original.lstrip('/')

    def grow(self, adopt=True, prepare=True):
        os.replace(self.source, self.corpus / cr.SOURCE_BACKUP_V2)
        shutil.copyfile(self.corpus / cr.SOURCE_BACKUP_V2, self.source)           # v1's backup stays where it was
        rows = [dict(sha256=sha_of(n), path=o, size=s, why=w, root='internal') for n, o, s, w in self.files]
        rows += [dict(sha256=sha_of(n), path=o, size=s, why=w, root='internal') for n, o, s, w in self.V2_INTERNAL]
        rows += [dict(sha256=sha_of(n), path=o, size=s, why=w, root='external') for n, o, s, w in self.V2_EXTERNAL]
        (self.corpus / cr.MANIFEST_V2).write_text(json.dumps(rows))
        (self.corpus / cr.SHA_LIST_V2_INTERNAL).write_text(''.join(f"{sha_of(n)}  {o.lstrip('/')}\n" for n, o, s, w in self.V2_INTERNAL))
        for n, o, s, w in self.V2_INTERNAL:
            self.put(self.corpus / 'media' / o.lstrip('/'), b'y' * s, sha_of(n))
        mount = self.volume.mount
        (mount / cr.MARKER).write_text('test data\n')
        (mount / 'corpus').mkdir(exist_ok=True)
        (mount / 'corpus' / cr.SHA_LIST_V2_EXTERNAL).write_text(''.join(f"{sha_of(n)}  {o.lstrip('/')}\n" for n, o, s, w in self.V2_EXTERNAL))
        for n, o, s, w in self.V2_EXTERNAL:
            self.put(self.ext_path(o), b'z' * s, sha_of(n))
        (mount / 'corpus' / 'media').mkdir(parents=True, exist_ok=True)
        if adopt:
            cr.adopt_volume(self.seal, str(mount), 'tester@test')
        if prepare:
            self.seal._external = None
            cr.prepare(self.seal)


@unittest.skipUnless(shutil.which('hdiutil'), 'needs hdiutil (macOS) for a real volume')
class TwoRootTestCase(unittest.TestCase):
    """One disk image for the class, emptied after each test."""

    @classmethod
    def setUpClass(cls):
        cls.volume_dir = tempfile.TemporaryDirectory()
        cls.volume = Volume(cls.volume_dir.name)

    @classmethod
    def tearDownClass(cls):
        cls.volume.detach()
        cls.volume_dir.cleanup()

    def setUp(self):
        if not os.path.ismount(str(self.volume.mount)):
            self.volume.attach()
        self.volume.empty()
        self.tmp = tempfile.TemporaryDirectory()
        self.scene = TwoRootScene(self.tmp.name, self.volume, **self.scene_options())

    def scene_options(self):
        return {}

    def tearDown(self):
        if not os.path.ismount(str(self.volume.mount)):
            self.volume.attach()
        self.volume.empty()
        self.tmp.cleanup()

    def summary(self):
        return (self.scene.out / 'corpus-summary.txt').read_text()

    def driver_config(self):
        return [c for c in self.scene.recorded_calls() if 'config' in c][-1]['config']


class TwoRootPrepareTests(TwoRootTestCase):

    def test_one_sealed_catalog_over_both_roots_each_row_at_its_copy(self):
        self.scene.grow()
        rows = dict(self.scene.catalog().execute('SELECT content_digest, full_path FROM files').fetchall())
        self.assertEqual(len(rows), 6)
        for n, original, _, _ in self.scene.files + self.scene.V2_INTERNAL:
            self.assertEqual(rows[sha_of(n)], str(self.scene.corpus / 'media') + original)
        for n, original, _, _ in self.scene.V2_EXTERNAL:
            self.assertEqual(rows[sha_of(n)], str(self.volume.mount / 'corpus' / 'media') + original)
        prepared = json.loads((self.scene.seal.state / 'prepare.json').read_text())
        self.assertEqual((prepared['manifest'], prepared['inventory']['internal']['present'], prepared['inventory']['external']['present']),
                         (cr.MANIFEST_V2, 4, 2))
        entries = cr.load_manifest(self.scene.seal)
        self.assertEqual(sorted(e.root for e in entries), ['external'] * 2 + ['internal'] * 4)

    def test_prepare_runs_with_the_volume_away_and_takes_its_files_when_it_is_back(self):
        self.scene.grow(prepare=False)
        self.volume.detach()
        self.scene.seal._external = None
        code, lines = cr.prepare(self.scene.seal)
        self.assertEqual(code, cr.EXIT_GREEN, lines)
        self.assertIn('GREEN 4 rows for 6 manifest files', lines[0])
        self.assertIn('  external volume NOT MOUNTED: its 2 files were not looked at', lines)
        self.volume.attach()
        self.scene.seal._external = None
        code, lines = cr.prepare(self.scene.seal)
        self.assertIn('GREEN 6 rows for 6 manifest files', lines[0])
        self.assertIn('  files: internal present 4 · missing 0 | external present 2 · missing 0', lines)

    def test_the_lists_must_agree_with_the_manifest_on_both_roots(self):
        self.scene.grow(prepare=False)
        (self.volume.mount / 'corpus' / cr.SHA_LIST_V2_EXTERNAL).write_text(f"{sha_of(11)}  Volumes/OtherDrive/elsewhere.mp4\n")
        with self.assertRaises(cr.Refused) as refused:
            cr.prepare(self.scene.seal)
        self.assertIn('disagree on', str(refused.exception))

    def test_a_v2_manifest_with_external_files_and_no_adopted_volume_is_refused(self):
        self.scene.grow(adopt=False, prepare=False)
        with self.assertRaises(cr.Refused) as refused:
            cr.prepare(self.scene.seal)
        self.assertIn('adopt-volume', str(refused.exception))


class AdoptVolumeTests(TwoRootTestCase):

    def test_adopt_pins_the_volume_uuid_once_and_never_replaces_it(self):
        self.scene.grow(adopt=False, prepare=False)
        lines = cr.adopt_volume(self.scene.seal, str(self.volume.mount), 'rickb@RicksUltra')
        pin = json.loads((self.scene.corpus / cr.VOLUME_PIN).read_text())
        self.assertEqual((pin['mount'], pin['volume_uuid']), (str(self.volume.mount), self.volume.uuid()))
        self.assertRegex(pin['volume_uuid'], cr._UUID)
        self.assertIn(self.volume.uuid(), lines[0])
        with self.assertRaises(cr.Refused) as refused:
            cr.adopt_volume(self.scene.seal, str(self.volume.mount), 'x')
        self.assertIn('already adopted', str(refused.exception))
        self.assertTrue(self.scene.seal.pristine(self.scene.corpus / cr.VOLUME_PIN), 'the record is a corpus document')

    def test_adopt_refuses_what_is_not_a_marked_volume_mounted_directly_in_volumes(self):
        self.scene.grow(adopt=False, prepare=False)
        plain = self.volume.folder / 'Plain'
        (plain / 'corpus' / 'media').mkdir(parents=True, exist_ok=True)
        (plain / cr.MARKER).write_text('test data\n')
        os.symlink(self.volume.mount, self.volume.folder / 'Alias')
        try:
            for mount, why in ((str(plain), 'nothing is mounted'), (str(self.volume.folder / 'Alias'), 'not through a link'),
                               (str(self.volume.mount) + '/corpus', 'directly in /Volumes'), ('/', 'directly in /Volumes')):
                with self.subTest(mount=mount), self.assertRaises(cr.Refused) as refused:
                    cr.adopt_volume(self.scene.seal, mount, 'x')
                self.assertIn(why, str(refused.exception))
            (self.volume.mount / cr.MARKER).unlink()
            with self.assertRaises(cr.Refused) as refused:
                cr.adopt_volume(self.scene.seal, str(self.volume.mount), 'x')
            self.assertIn('not marked as test data', str(refused.exception))
            self.assertFalse(os.path.lexists(self.scene.corpus / cr.VOLUME_PIN))
        finally:
            os.unlink(self.volume.folder / 'Alias')
            shutil.rmtree(plain)

    def test_adopt_is_refused_off_the_m4(self):
        self.scene.grow(adopt=False, prepare=False)
        with self.assertRaises(cr.Refused):
            cr.adopt_volume(cr.Seal(self.scene.home, 'RicksUltra'), str(self.volume.mount), 'x')
        self.assertFalse(os.path.lexists(self.scene.corpus / cr.VOLUME_PIN))

    def test_the_front_door_adopts_through_ssh_with_the_helper_on_stdin(self):
        done = subprocess.run(['bash', str(SCRIPTS / 'corpus_run.sh'), 'adopt-volume', '/Volumes/crucial10_testdata', '--dry-run'],
                              capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertRegex(done.stdout, r'\+ ssh ricksm4\.local python3 - adopt-volume /Volumes/crucial10_testdata --by \S+ < \S+corpus_run\.py')
        for bad in ('/Volumes/a b', '/Users/x', '/Volumes/../etc', ''):
            done = subprocess.run(['bash', str(SCRIPTS / 'corpus_run.sh'), 'adopt-volume', bad, '--dry-run'],
                                  capture_output=True, text=True, timeout=60)
            self.assertEqual(done.returncode, 2, bad)


class ExternalSealTests(TwoRootTestCase):
    """The external root is accepted only mounted at the adopted path, not through a link, marked, and the adopted volume."""

    def pin(self, **changes):
        path = self.scene.corpus / cr.VOLUME_PIN
        value = dict(json.loads(path.read_text()), **changes)
        path.write_text(json.dumps(value))
        self.scene.seal._external = None

    def state(self):
        self.scene.seal._external = None
        try:
            return self.scene.seal.external().state
        except cr.Refused as refused:
            return str(refused)

    def test_the_states_of_the_external_root(self):
        self.scene.grow(prepare=False)
        self.assertEqual(self.state(), 'ok')
        self.pin(volume_uuid='00000000-0000-0000-0000-000000000000')
        self.assertIn('not the adopted one', self.state())
        self.pin(volume_uuid=self.volume.uuid())
        (self.volume.mount / cr.MARKER).unlink()
        self.assertIn('carries no THIS_IS_TEST_DATA.txt', self.state())
        (self.volume.mount / cr.MARKER).write_text('test data\n')
        os.symlink(self.volume.mount, self.volume.folder / 'Alias')
        try:
            self.pin(mount=str(self.volume.folder / 'Alias'))
            self.assertIn('through a link', self.state())
        finally:
            os.unlink(self.volume.folder / 'Alias')
        (self.volume.folder / 'Plain').mkdir()
        try:
            self.pin(mount=str(self.volume.folder / 'Plain'))
            self.assertEqual(self.state(), 'absent', 'a plain folder at the mount point is not the volume')
        finally:
            (self.volume.folder / 'Plain').rmdir()
        self.pin(mount=str(self.volume.folder / 'Gone'))
        self.assertEqual(self.state(), 'absent')
        (self.scene.corpus / cr.VOLUME_PIN).unlink()
        self.assertEqual(self.state(), 'none')

    def test_a_pin_that_is_a_link_or_not_one_volume_stops_everything(self):
        self.scene.grow(prepare=False)
        path = self.scene.corpus / cr.VOLUME_PIN
        good = path.read_text()
        for poison in ('{not json', '[]', json.dumps(dict(mount='relative', volume_uuid=self.volume.uuid())),
                       json.dumps(dict(mount='/Volumes/x/../y', volume_uuid=self.volume.uuid())),
                       json.dumps(dict(mount='/Volumes/x', volume_uuid='nope'))):
            path.write_text(poison)
            with self.subTest(poison=poison), self.assertRaises(cr.Refused):
                self.scene.seal.check()
        path.unlink()
        elsewhere = pathlib.Path(self.tmp.name, 'pin.json')
        elsewhere.write_text(good)
        os.symlink(elsewhere, path)
        with self.assertRaises(cr.Refused):
            self.scene.seal.check()

    def test_nothing_is_ever_written_on_the_external_volume_mounted_or_not(self):
        self.scene.grow(prepare=False)
        seal = self.scene.seal
        for target in (self.volume.mount / 'x', self.ext_media() / 'Volumes' / 'x', self.volume.mount):
            with self.subTest(target=str(target)), self.assertRaises(cr.Refused):
                seal.writable(target)
            self.assertTrue(seal.pristine(target))
        os.symlink(self.volume.mount, seal.work_root / 'to-x10') if seal.work_root.is_dir() else None
        seal.work_root.mkdir(parents=True, exist_ok=True)
        if not os.path.lexists(seal.work_root / 'to-x10'):
            os.symlink(self.volume.mount, seal.work_root / 'to-x10')
        with self.assertRaises(cr.Refused):
            seal.writable(seal.work_root / 'to-x10' / 'corpus')
        self.volume.detach()
        with self.assertRaises(cr.Refused):
            seal.writable(self.volume.mount / 'corpus' / 'media' / 'x')

    def ext_media(self):
        return self.volume.mount / 'corpus' / 'media'


class TwoRootLaneTests(TwoRootTestCase):

    def test_check_runs_every_file_on_both_roots(self):
        self.scene.grow()
        self.assertEqual(self.scene.run('check'), cr.EXIT_GREEN, self.summary())
        config = self.driver_config()
        paths = sorted(item['path'] for item in config['pending'])
        self.assertEqual(len(paths), 6)
        self.assertEqual(sum(1 for p in paths if p.startswith(str(self.volume.mount) + '/corpus/media/')), 2)
        self.assertIn('corpus check: GREEN 6 files', self.summary())
        self.assertNotIn('NOT MOUNTED', self.summary())

    def test_v1_outcomes_still_diff_cleanly_and_the_v2_files_are_new(self):
        self.assertEqual(self.scene.run('check', stamp='20261117_120000_1'), cr.EXIT_GREEN)
        cr.accept(self.scene.seal, 'check', 'x')
        self.scene.grow()
        self.assertEqual(self.scene.run('check', stamp='20261119_120000_2'), cr.EXIT_GREEN, self.summary())
        self.assertIn('0 of 3 files changed (new in this run 3, not in this run 0)', self.summary())

    def test_with_the_volume_away_the_internal_files_run_and_the_rest_are_said_not_run_amber(self):
        self.assertEqual(self.scene.run('check', stamp='20261117_120000_1'), cr.EXIT_GREEN)
        cr.accept(self.scene.seal, 'check', 'x')
        self.scene.grow()
        self.volume.detach()
        self.scene.seal._external = None
        self.assertEqual(self.scene.run('check', stamp='20261119_120000_2'), cr.EXIT_AMBER, self.summary())
        self.assertEqual(len(self.driver_config()['pending']), 4)
        self.assertIn('corpus check: AMBER 4 files', self.summary())
        self.assertIn('external volume NOT MOUNTED: 2 files on it NOT RUN — AMBER', self.summary())
        facts = json.loads((self.scene.out / cr.VERDICT_FILE).read_text())
        self.assertEqual(facts['verdict'], 'AMBER')
        self.assertIn('2 files NOT RUN: the external volume is not mounted', facts['notes'])
        with self.assertRaises(cr.Refused) as refused:
            cr.accept(self.scene.seal, 'check', 'x')
        self.assertIn('a partial run is never the baseline', str(refused.exception))
        status = '\n'.join(cr.status(self.scene.seal))
        self.assertIn('the external volume is NOT MOUNTED', status)
        self.assertIn('2 files on it NOT RUN', status)

    def test_a_run_without_the_external_volume_is_never_the_implicit_baseline(self):
        self.scene.grow()
        self.volume.detach()
        self.scene.seal._external = None
        self.assertEqual(self.scene.run('check', stamp='20261119_120000_1'), cr.EXIT_AMBER)
        self.volume.attach()
        self.scene.seal._external = None
        self.assertEqual(self.scene.run('check', stamp='20261119_120000_2'), cr.EXIT_GREEN, self.summary())
        self.assertIn('baseline: this run', self.summary())

    def test_another_volume_at_the_mount_point_is_refused_and_nothing_runs(self):
        self.scene.grow()
        pin = self.scene.corpus / cr.VOLUME_PIN
        pin.write_text(json.dumps(dict(json.loads(pin.read_text()), volume_uuid='11111111-2222-3333-4444-555555555555')))
        self.scene.seal._external = None
        self.assertEqual(self.scene.run('check'), cr.EXIT_REFUSED)
        self.assertIn('not the adopted one', self.summary())
        self.assertEqual([c for c in self.scene.recorded_calls() if 'config' in c], [])

    def test_verbs_clones_only_from_the_internal_root_and_sweeps_both(self):
        self.scene.grow()
        self.scene.plan['engines'] = VERBS
        self.assertEqual(self.scene.run('verbs'), cr.EXIT_GREEN, self.summary())
        for args in [json.loads(line) for line in self.scene.cp_calls.read_text().splitlines()]:
            self.assertTrue(args[2].startswith(str(self.scene.corpus / 'media') + '/'), 'a clone from the external volume')
        self.assertIn('media sweep (size, mtime, flags, links and inode of 6 files', self.summary())
        self.scene.plan['vandal'] = str(self.scene.ext_path(self.scene.V2_EXTERNAL[0][1]))
        self.assertEqual(self.scene.run('verbs', stamp='20261119_130000_2'), cr.EXIT_RED, self.summary())
        self.assertIn('RED: ~/corpus/media was touched', self.summary())


class ProofChoiceTests(TwoRootTestCase):
    """The proof lane takes v1's one-sided stratum and what the newest whole check run heard as one-sided, capped."""

    def scene_options(self):
        return dict(with_proof_engine=True)

    def check_run(self, stamp, kinds, limit=None):
        self.scene.plan['engines'] = ['probe', 'check', 'audio', 'pair']
        self.scene.plan['files'] = {sha: dict(audio='ok_with_findings', audio_kinds=k) for sha, k in kinds.items()}
        extra = dict(limit=limit) if limit else {}
        self.scene.run('check', stamp=stamp, **extra)

    def proof_pending(self, stamp):
        self.scene.plan['engines'] = ['balance', 'proof']
        self.scene.plan['files'] = {}
        code = self.scene.run('proof', stamp=stamp)
        return code, sorted(item['sha'] for item in self.driver_config()['pending'])

    def test_one_sided_files_come_from_the_check_run_and_mono_does_not(self):
        self.scene.grow()
        code, pending = self.proof_pending('20261119_100000_1')
        self.assertEqual((code, pending), (cr.EXIT_GREEN, [sha_of(0)]), 'no check run yet: the stratum alone')
        self.assertIn('files: 1 of the one-sided-sound stratum + 0 the check run none heard one-sided', self.summary())
        self.check_run('20261119_110000_2', {sha_of(11): ['channelImbalance:leftOnly'], sha_of(10): ['channelImbalance:rightOnly'],
                                             sha_of(2): ['channelImbalance:mono'], sha_of(1): ['silentAudio']})
        code, pending = self.proof_pending('20261119_120000_3')
        self.assertEqual(pending, sorted([sha_of(0), sha_of(11), sha_of(10)]))
        self.assertIn('+ 2 the check run 20261119_110000_2 heard one-sided — 3 taken (cap 40)', self.summary())

    def test_a_limited_check_run_is_not_asked_and_the_cap_holds(self):
        self.scene.grow()
        self.check_run('20261119_110000_1', {sha_of(11): ['channelImbalance:leftOnly']})
        self.check_run('20261119_110000_2', {}, limit=2)
        original = cr.PROOF_CAP
        try:
            cr.proof_files.__defaults__ = (2,)
            _, pending = self.proof_pending('20261119_120000_3')
        finally:
            cr.proof_files.__defaults__ = (original,)
        self.assertEqual(pending, sorted([sha_of(0), sha_of(11)]), 'the whole run is read, not the newer limited one')
        self.assertIn('— 2 taken (cap 2)', self.summary())

    def test_the_proof_lane_refuses_to_take_the_disk_past_95_percent(self):
        self.scene.grow()
        real = cr.shutil.disk_usage
        cr.shutil.disk_usage = lambda path: type('U', (), dict(total=100 * 10**9, used=95 * 10**9, free=5 * 10**9 + 1000))()     # the largest file (1200 B) would pass 95%
        try:
            self.scene.plan['engines'] = ['balance', 'proof']
            self.assertEqual(self.scene.run('proof'), cr.EXIT_REFUSED)
        finally:
            cr.shutil.disk_usage = real
        self.assertIn('a run stops short of 95% used', self.summary())
        self.assertEqual([c for c in self.scene.recorded_calls() if 'config' in c], [])


class TwoRootScaleTests(unittest.TestCase):

    def test_a_100k_file_manifest_over_two_roots_loads_and_checks_inside_the_budget(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = pathlib.Path(os.path.realpath(tmp), 'home')
            corpus = home / 'corpus'
            corpus.mkdir(parents=True)
            (corpus / cr.MARKER).write_text('test data\n')
            (corpus / cr.VOLUME_PIN).write_text(json.dumps(dict(mount='/Volumes/NotHere', volume_uuid='0' * 8 + '-0000-0000-0000-' + '0' * 12)))
            rows = [dict(sha256=sha_of(i), path=f'/Volumes/D{i % 9}/f{i}.mov', size=i, why='v2', root='external' if i % 2 else 'internal')
                    for i in range(100_000)]
            (corpus / cr.MANIFEST_V2).write_text(json.dumps(rows))
            (corpus / cr.SHA_LIST).write_text('')
            (corpus / cr.SHA_LIST_V2_INTERNAL).write_text(''.join(f"{r['sha256']}  {r['path'][1:]}\n" for r in rows if r['root'] == 'internal'))
            seal = cr.Seal(home, 'ricksm4')
            t0 = time.time()
            entries = cr.load_manifest(seal)
            self.assertEqual(seal.external().state, 'absent')
            internal = [e for e in entries if e.root == 'internal']
            self.assertEqual(cr.check_sha_list(seal, internal, seal.external()), 0)
            took = time.time() - t0
            self.assertEqual(len(entries), 100_000)
            self.assertLess(took, 10.0, f'{took:.1f}s')



@unittest.skipUnless(shutil.which('swiftc') and shutil.which('hdiutil'), 'needs the Swift compiler and hdiutil')
class SwiftExternalSealTests(TwoRootTestCase):
    """The in-app seal's external root (CorpusSeal.external) asked about the same real volume as Python's
    `Seal.external`, case by case: the two must give the same answer."""

    PYTHON_TO_SWIFT = {'ok': 'ok', 'absent': 'absent', 'none': 'none', 'not the adopted one': 'external_volume_is_not_the_adopted_one',
                       'carries no THIS_IS_TEST_DATA.txt': 'external_volume_has_no_marker',
                       'through a link': 'external_volume_through_a_link',
                       'is not the record': 'external_volume_pin_unreadable'}

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.binary = seal_binary()

    def python_word(self):
        seal = cr.Seal(self.scene.home, 'ricksm4')
        try:
            state = seal.external().state
        except cr.Refused as refused:
            state = next(k for k in self.PYTHON_TO_SWIFT if k in str(refused))
        return self.PYTHON_TO_SWIFT[state]

    def ask(self, pending, after_open=None, lane='check', config_lane='check', run=None):
        """The Swift seal over a check-lane config whose one file is `pending`: (refusal word, external word)."""
        run = run or self.scene.seal.work_root / 'run1-check'
        run.mkdir(parents=True, exist_ok=True)
        if not (run / 'progress.jsonl').exists():
            (run / 'progress.jsonl').write_text('')
        state = self.scene.seal.state
        (state / 'home').mkdir(parents=True, exist_ok=True)
        config = dict(lane=config_lane, corpusRoot=str(self.scene.corpus), stateRoot=str(state), catalog=str(state / DB),
                      mediaRoot=str(self.scene.corpus / 'media'), work=str(run), progress=str(run / 'progress.jsonl'),
                      deadlineSeconds=60, pending=[dict(sha='a' * 64, path=str(pending))])
        (run / 'config.json').write_text(json.dumps(config))
        home = str(state / 'home')
        cases = pathlib.Path(self.tmp.name, 'cases.json')
        cases.write_text(json.dumps([dict(hostname='RicksM4.local', realHome=str(self.scene.home), configPath=str(run / 'config.json'),
                                          lane=lane, home=home, appSupport=home + '/Library/Application Support', isTestHost=True,
                                          afterOpen=after_open)]))
        done = subprocess.run([str(self.binary), str(cases)], capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr)
        fact = done.stdout.split()[0].split('|')
        self.may_open, self.proven, self.folders_home = fact[4], fact[2], fact[5]
        return fact[0], fact[3]

    def test_f2_the_volume_is_proven_again_at_each_file_not_once_per_run(self):
        # Codex #331 F2: proven at open, then the marker goes (or another volume is put there) before the next file.
        self.scene.grow(prepare=False)
        external_file = self.scene.ext_path(self.scene.V2_EXTERNAL[0][1])
        internal_file = self.scene.corpus / 'media' / self.scene.files[0][1].lstrip('/')
        marker = self.volume.mount / cr.MARKER
        self.assertEqual(self.ask(external_file), ('ok', 'ok'))
        self.assertEqual(self.may_open, 'true')
        self.assertEqual(self.ask(external_file, after_open=[['remove', str(marker)]]), ('ok', 'ok'), 'proven at open')
        self.assertEqual(self.may_open, 'false', 'an external file was allowed after the marker went')
        marker.write_text('test data\n')
        self.ask(internal_file, after_open=[['remove', str(marker)]])
        self.assertEqual(self.may_open, 'true', 'an internal file does not depend on the external volume')
        marker.write_text('test data\n')
        other = json.dumps(dict(json.loads((self.scene.corpus / cr.VOLUME_PIN).read_text()),
                                volume_uuid='00000000-0000-0000-0000-000000000000'))
        pin_path = str(self.scene.corpus / cr.VOLUME_PIN)
        self.assertEqual(self.ask(external_file, after_open=[['remove', pin_path], ['write', pin_path, other]]), ('ok', 'ok'),
                         'proven at open')
        self.assertEqual(self.may_open, 'false', 'an external file was allowed once the volume was not the adopted one')

    def test_r2_f3_a_pin_that_disappears_after_the_run_opened_never_lets_an_external_file_through(self):
        # Codex #332 F3: proven at open; the pin moved aside before the next engine -> external() is .none.
        self.scene.grow(prepare=False)
        external_file = self.scene.ext_path(self.scene.V2_EXTERNAL[0][1])
        internal_file = self.scene.corpus / 'media' / self.scene.files[0][1].lstrip('/')
        aside = pathlib.Path(self.tmp.name, 'pin-aside.json')
        pin_path = str(self.scene.corpus / cr.VOLUME_PIN)
        self.ask(external_file, after_open=[['move', pin_path, str(aside)]])
        self.assertEqual(self.may_open, 'false', 'an external file was opened after its proof went away')
        os.replace(aside, self.scene.corpus / cr.VOLUME_PIN)
        self.ask(internal_file, after_open=[['move', pin_path, str(aside)]])
        self.assertEqual(self.may_open, 'true', 'an internal file does not depend on the external volume')
        os.replace(aside, self.scene.corpus / cr.VOLUME_PIN)
        self.ask(pathlib.Path('/Volumes/SomethingElse/x.mov'))
        self.assertEqual(self.may_open, 'false', 'a path the run was never given a root for is never opened')
        support = (SCRIPTS / 'corpus' / 'CorpusDriverSupport.swift').read_text()
        self.assertIn('CorpusSeal.mayOpen(item.path, realHome: CorpusRun.realHome(), atOpen: external)', support)

    def test_r3_f3_an_internal_root_aliased_to_the_volume_after_open_is_not_internal(self):
        # Codex #333 F3: ~/corpus/media replaced by a link to <M>/corpus/media and the marker moved aside.
        self.scene.grow(prepare=False)
        external_file = self.scene.ext_path(self.scene.V2_EXTERNAL[0][1])
        media = str(self.scene.corpus / 'media')
        aside = str(pathlib.Path(self.tmp.name, 'media-aside'))
        marker = str(self.volume.mount / cr.MARKER)
        try:
            self.assertEqual(self.ask(external_file, after_open=[['move', media, aside], ['symlink', str(self.volume.mount / 'corpus' / 'media'), media],
                                                                 ['move', marker, marker + '.aside']]), ('ok', 'ok'))
            self.assertEqual(self.may_open, 'false', 'an external file passed as internal through an aliased root')
        finally:
            if os.path.islink(media):
                os.unlink(media)
            if os.path.exists(aside):
                os.replace(aside, media)
            if os.path.exists(marker + '.aside'):
                os.replace(marker + '.aside', marker)

    def test_r3_f3_an_internal_root_aliased_elsewhere_on_the_home_volume_after_open_is_not_internal(self):
        self.scene.grow(prepare=False)
        internal_file = self.scene.corpus / 'media' / self.scene.files[0][1].lstrip('/')
        media = str(self.scene.corpus / 'media')
        aside = str(pathlib.Path(self.tmp.name, 'media-aside'))
        elsewhere = pathlib.Path(self.tmp.name, 'not-the-corpus')
        (elsewhere / internal_file.relative_to(self.scene.corpus / 'media')).parent.mkdir(parents=True)
        (elsewhere / internal_file.relative_to(self.scene.corpus / 'media')).write_bytes(b'not a corpus copy')
        try:
            self.assertEqual(self.ask(internal_file, after_open=[['move', media, aside], ['symlink', str(elsewhere), media]]), ('ok', 'ok'))
            self.assertEqual(self.may_open, 'false', 'a file outside the corpus passed as internal through an aliased root')
        finally:
            if os.path.islink(media):
                os.unlink(media)
            if os.path.exists(aside):
                os.replace(aside, media)

    def test_r3_f3_a_volume_mounted_inside_corpus_media_is_not_internal(self):
        # The folders are themselves, but a volume is mounted INSIDE ~/corpus/media: its files are not internal copies.
        self.scene.grow(prepare=False)
        inside = self.scene.corpus / 'media' / 'Volumes' / 'Mounted'
        inside.mkdir(parents=True)
        on_it = inside / self.scene.ext_path(self.scene.V2_EXTERNAL[0][1]).relative_to(self.volume.mount)
        try:
            self.ask(on_it, after_open=[['exec', '/usr/bin/hdiutil', 'detach', '-force', '-quiet', str(self.volume.mount)],
                                        ['exec', '/usr/bin/hdiutil', 'attach', '-nobrowse', '-noverify', '-quiet', '-mountpoint', str(inside),
                                         self.volume.image]])
            self.assertTrue(on_it.is_file(), 'the volume is mounted inside ~/corpus/media now')
            self.assertEqual(self.may_open, 'false', 'a file on another volume passed as an internal copy')
            answer, _ = self.ask(on_it)
            self.assertEqual(answer, 'a_file_is_outside_the_corpus', 'refused at open too')
        finally:
            subprocess.run(['hdiutil', 'detach', '-force', '-quiet', str(inside)], capture_output=True, timeout=120)
            self.volume.attach()

    def test_r3_f4_another_volume_adopted_at_the_same_mount_after_open_is_not_the_one_proven(self):
        # Codex #333 F4: proven on volume A at M; after open, A goes, B (marked, same paths) is mounted at M and adopted.
        self.scene.grow(prepare=False)
        external_file = self.scene.ext_path(self.scene.V2_EXTERNAL[0][1])
        other = Volume(self.tmp.name, name='B')
        try:
            (other.mount / cr.MARKER).write_text('test data\n')
            twin = other.mount / external_file.relative_to(self.volume.mount)
            twin.parent.mkdir(parents=True)
            twin.write_bytes(b'z')
            b_uuid = other.uuid()
            other.detach()
            pin_path = str(self.scene.corpus / cr.VOLUME_PIN)
            pin_b = json.dumps(dict(mount=str(self.volume.mount), volume_uuid=b_uuid))
            self.assertEqual(self.ask(external_file, after_open=[
                ['exec', '/usr/bin/hdiutil', 'detach', '-force', '-quiet', str(self.volume.mount)],
                ['exec', '/usr/bin/hdiutil', 'attach', '-nobrowse', '-noverify', '-quiet', '-mountpoint', str(self.volume.mount), other.image],
                ['remove', pin_path], ['write', pin_path, pin_b]]), ('ok', 'ok'), 'proven on A at open')
            self.assertEqual(cr.diskutil_volume_uuid(str(self.volume.mount)), b_uuid, 'B is mounted at M now')
            self.assertEqual(self.may_open, 'false', 'a file on B passed on the proof made for A')
        finally:
            subprocess.run(['hdiutil', 'detach', '-force', '-quiet', str(self.volume.mount)], capture_output=True, timeout=120)
            self.volume.attach()

    def test_r3_f2_a_run_folder_on_another_volume_is_never_written_even_to_refuse(self):
        # Codex #333 F2: a volume mounted at ~/corpus/work/R holding the config and a one-name progress file.
        self.scene.grow(prepare=False)
        other = Volume(self.tmp.name, name='R-vol')
        run = self.scene.seal.work_root / 'R-check'
        try:
            other.detach()
            run.mkdir(parents=True)
            done = subprocess.run(['hdiutil', 'attach', '-nobrowse', '-noverify', '-quiet', '-mountpoint', str(run), other.image],
                                  capture_output=True, text=True, timeout=120)
            self.assertEqual(done.returncode, 0, done.stderr)
            internal_file = self.scene.corpus / 'media' / self.scene.files[0][1].lstrip('/')
            answer, _ = self.ask(internal_file, run=run, lane='check', config_lane='proof')
            self.assertNotEqual(answer, 'ok')
            self.assertEqual(self.proven, 'false', 'a refusal may be written to a progress file on another volume')
            answer, _ = self.ask(internal_file, run=run)
            self.assertEqual(answer, 'a_writable_path_is_on_another_volume')
            support = (SCRIPTS / 'corpus' / 'CorpusDriverSupport.swift').read_text()
            self.assertIn('info.st_dev == CorpusSeal.homeDevice(realHome: CorpusRun.realHome())',
                          support[support.index('final class CorpusProgress'):support.index('final class CorpusRun')])
        finally:
            subprocess.run(['hdiutil', 'detach', '-force', '-quiet', str(run)], capture_output=True, timeout=120)

    def test_r4_f1_an_extra_copy_on_a_volume_mounted_in_the_run_is_refused(self):
        # Codex #334 F1: a verbs copy at <run>/vol/Copies/copy2 that is a mount; the primary file on the home volume.
        self.scene.grow(prepare=False)
        other = Volume(self.tmp.name, name='copies')
        run = self.scene.seal.work_root / 'run1-verbs'
        for folder in ('vol/Copies/copy2', 'home', 'archive', 'scratch'):
            (run / folder).mkdir(parents=True, exist_ok=True)
        (run / 'vol' / 'a.mov').write_text('x')
        (run / 'progress.jsonl').write_text('')
        try:
            other.detach()
            copy2 = run / 'vol' / 'Copies' / 'copy2'
            done = subprocess.run(['hdiutil', 'attach', '-nobrowse', '-noverify', '-quiet', '-mountpoint', str(copy2), other.image],
                                  capture_output=True, text=True, timeout=120)
            self.assertEqual(done.returncode, 0, done.stderr)
            (copy2 / 'a.mov').write_text('x')
            state = self.scene.seal.state
            config = dict(lane='verbs', corpusRoot=str(self.scene.corpus), stateRoot=str(state), catalog=str(state / DB),
                          mediaRoot=str(self.scene.corpus / 'media'), work=str(run), progress=str(run / 'progress.jsonl'),
                          deadlineSeconds=60, pending=[dict(sha='a' * 64, path=str(run / 'vol' / 'a.mov'), role='dup', copies=[str(copy2 / 'a.mov')])],
                          volRoot=str(run / 'vol'), archiveRoot=str(run / 'archive'), scratch=str(run / 'scratch'))
            (run / 'config.json').write_text(json.dumps(config))
            cases = pathlib.Path(self.tmp.name, 'cases.json')
            cases.write_text(json.dumps([dict(hostname='RicksM4.local', realHome=str(self.scene.home), configPath=str(run / 'config.json'),
                                              lane='verbs', home=str(run / 'home'), appSupport=str(run / 'home' / 'Library' / 'Application Support'),
                                              isTestHost=True, afterOpen=None)]))
            done = subprocess.run([str(self.binary), str(cases)], capture_output=True, text=True, timeout=60)
            self.assertEqual(done.stdout.split()[0].split('|')[0], 'a_file_is_outside_the_corpus')
            self.assertEqual((copy2 / 'a.mov').read_text(), 'x')
            verbs = (SCRIPTS / 'corpus' / 'CorpusVerbsDriver.swift').read_text()
            trash = verbs[verbs.index('enum VerbsTrash'):verbs.index('final class CorpusVerbsDriver')]
            self.assertIn('CorpusRun.inRun(url.path, work)', trash)
            self.assertNotIn('CorpusRun.isUnder(', verbs, 'a run-folder check without the home-volume test')
        finally:
            subprocess.run(['hdiutil', 'detach', '-force', '-quiet', str(run / 'vol' / 'Copies' / 'copy2')], capture_output=True, timeout=120)

    def test_r4_f2_a_volume_mounted_over_the_run_folder_after_open_stops_every_engine(self):
        # Codex #334 F2: the run's work folder replaced by a mount between engines: no engine runs, no write lands there.
        self.scene.grow(prepare=False)
        internal_file = self.scene.corpus / 'media' / self.scene.files[0][1].lstrip('/')
        other = Volume(self.tmp.name, name='over-run')
        run = self.scene.seal.work_root / 'run1-check'
        try:
            other.detach()
            self.assertEqual(self.ask(internal_file), ('ok', 'ok'))
            self.assertEqual(self.folders_home, 'true')
            self.ask(internal_file, after_open=[['exec', '/usr/bin/hdiutil', 'attach', '-nobrowse', '-noverify', '-quiet', '-mountpoint',
                                                 str(run), other.image]])
            self.assertTrue(os.path.ismount(str(run)))
            self.assertEqual(self.folders_home, 'false', "the run's folder on another volume was still its own")
            support = (SCRIPTS / 'corpus' / 'CorpusDriverSupport.swift').read_text()
            body = support[support.index('    func engine('):]
            self.assertLess(body.index('CorpusSeal.runFoldersOnHome(config, realHome: CorpusRun.realHome())'), body.index('try await body()'))
            proof = (SCRIPTS / 'corpus' / 'CorpusProofDriver.swift').read_text()
            self.assertNotIn('CorpusRun.isUnder(', proof)
            removal = proof[:proof.index('try? FileManager.default.removeItem(at: balanced)')]
            self.assertIn('if CorpusRun.inRun(balanced.path, run.config.work) {', removal[-200:])
        finally:
            subprocess.run(['hdiutil', 'detach', '-force', '-quiet', str(run)], capture_output=True, timeout=120)

    def test_r4_f4_a_corpus_folder_that_is_a_link_is_refused_by_the_in_app_gate(self):
        self.scene.grow(prepare=False)
        internal_file = self.scene.corpus / 'media' / self.scene.files[0][1].lstrip('/')
        real = pathlib.Path(self.tmp.name, 'corpus-real')
        os.replace(self.scene.corpus, real)
        os.symlink(real, self.scene.corpus)
        try:
            answer, _ = self.ask(internal_file)
            self.assertEqual(answer, 'a_corpus_folder_is_an_alias')
        finally:
            os.unlink(self.scene.corpus)
            os.replace(real, self.scene.corpus)

    def test_r5_f4_an_external_item_exposed_as_a_link_into_media_after_unplug_is_not_internal(self):
        # Codex #335 F4: proven at open; unplugged between engines, exposing <M>/corpus/media -> ~/corpus/media.
        self.scene.grow(prepare=False)
        external_file = self.scene.ext_path(self.scene.V2_EXTERNAL[0][1])
        relative = external_file.relative_to(self.volume.mount / 'corpus' / 'media')
        twin = self.scene.corpus / 'media' / relative
        twin.parent.mkdir(parents=True, exist_ok=True)
        twin.write_bytes(b'an internal file at the same place')
        mount = str(self.volume.mount)
        try:
            self.assertEqual(self.ask(external_file, after_open=[
                ['exec', '/usr/bin/hdiutil', 'detach', '-force', '-quiet', mount],
                ['exec', '/bin/mkdir', '-p', mount + '/corpus'],
                ['symlink', str(self.scene.corpus / 'media'), mount + '/corpus/media']]), ('ok', 'ok'), 'proven at open')
            self.assertEqual(self.may_open, 'false', 'an external item ran through a link into ~/corpus/media')
            verbs = (SCRIPTS / 'corpus' / 'CorpusSeal.swift').read_text()
            body = verbs[verbs.index('static func mayOpen('):]
            self.assertLess(body.index('path.hasPrefix(mount + "/")'), body.index('onHomeVolume(path, realHome: realHome)'),
                            'the item is judged by where it was GIVEN (the adopted mount) before anything is resolved')
        finally:
            if os.path.islink(mount + '/corpus/media'):
                os.unlink(mount + '/corpus/media')
            if os.path.isdir(mount + '/corpus') and not os.path.ismount(mount):
                os.rmdir(mount + '/corpus')
            self.volume.attach()

    def test_r5_f2_f3_the_verbs_stages_check_before_they_make_and_never_unlock_across_a_volume(self):
        verbs = (SCRIPTS / 'corpus' / 'CorpusVerbsDriver.swift').read_text()
        model = verbs[verbs.index('func makeModel('):verbs.index('let model = VideoScanModel()')]
        self.assertLess(model.index('CorpusRun.inRun(scratch, run.config.work)'), model.index('mkdir(path'))
        dedupe = verbs[verbs.index('func dedupe('):verbs.index('let planRoot')]
        self.assertLess(dedupe.index('CorpusRun.inRun(scratch, run.config.work)'), dedupe.index('mkdir(plans'))
        unlock = verbs[verbs.index('nonisolated static func unlock('):]
        self.assertIn('walker.skipDescendants()', unlock)
        self.assertLess(unlock.index('info.st_dev == home'), unlock.index('lchflags('))

    def test_f3_a_progress_file_that_is_a_second_name_of_the_pin_is_refused_and_the_pin_unchanged(self):
        self.scene.grow(prepare=False)
        run = self.scene.seal.work_root / 'run1-check'
        run.mkdir(parents=True, exist_ok=True)
        pin = self.scene.corpus / cr.VOLUME_PIN
        before = pin.read_bytes()
        os.link(pin, run / 'progress.jsonl')
        state = self.scene.seal.state
        (state / 'home').mkdir(parents=True, exist_ok=True)
        config = dict(lane='check', corpusRoot=str(self.scene.corpus), stateRoot=str(state), catalog=str(state / DB),
                      mediaRoot=str(self.scene.corpus / 'media'), work=str(run), progress=str(run / 'progress.jsonl'),
                      deadlineSeconds=60, pending=[dict(sha='a' * 64, path=str(self.scene.corpus / 'media' / self.scene.files[0][1].lstrip('/')))])
        (run / 'config.json').write_text(json.dumps(config))
        home = str(state / 'home')
        cases = pathlib.Path(self.tmp.name, 'cases.json')
        cases.write_text(json.dumps([dict(hostname='RicksM4.local', realHome=str(self.scene.home), configPath=str(run / 'config.json'),
                                          lane='check', home=home, appSupport=home + '/Library/Application Support', isTestHost=True)]))
        done = subprocess.run([str(self.binary), str(cases)], capture_output=True, text=True, timeout=60)
        fact = done.stdout.split()[0].split('|')
        self.assertNotEqual(fact[0], 'ok')
        self.assertEqual(fact[2], 'false', 'a refusal may not be written to a progress file with a second name')
        self.assertEqual(pin.read_bytes(), before)
        support = (SCRIPTS / 'corpus' / 'CorpusDriverSupport.swift').read_text()
        self.assertIn('info.st_nlink == 1', support[support.index('final class CorpusProgress'):support.index('final class CorpusRun')])

    def pin(self, **changes):
        path = self.scene.corpus / cr.VOLUME_PIN
        path.write_text(json.dumps(dict(json.loads(path.read_text()), **changes)))

    def test_swift_and_python_give_the_same_answer_about_the_external_root(self):
        self.scene.grow(prepare=False)
        self.scene.home = pathlib.Path(os.path.realpath(self.scene.home))
        external_file = self.scene.ext_path(self.scene.V2_EXTERNAL[0][1])
        internal_file = self.scene.corpus / 'media' / self.scene.files[0][1].lstrip('/')
        seen = []

        def both(name, pending, refusal):
            answer, swift = self.ask(pending)
            seen.append(name)
            with self.subTest(case=name):
                self.assertEqual(swift, self.python_word(), name)
                self.assertEqual(answer, refusal, name)

        both('proven', external_file, 'ok')
        both('proven, an internal file', internal_file, 'ok')
        self.pin(volume_uuid='00000000-0000-0000-0000-000000000000')
        both('another volume', internal_file, 'external_volume_is_not_the_adopted_one')
        self.pin(volume_uuid=self.volume.uuid().lower())
        both('the pinned uuid in lower case', external_file, 'ok')
        (self.volume.mount / cr.MARKER).unlink()
        both('no marker', internal_file, 'external_volume_has_no_marker')
        (self.volume.mount / cr.MARKER).mkdir()
        both('a marker that is a folder', internal_file, 'external_volume_has_no_marker')
        (self.volume.mount / cr.MARKER).rmdir()
        (self.volume.mount / cr.MARKER).write_text('test data\n')
        os.symlink(self.volume.mount, self.volume.folder / 'Alias')
        try:
            self.pin(mount=str(self.volume.folder / 'Alias'))
            both('through a link', internal_file, 'external_volume_through_a_link')
        finally:
            os.unlink(self.volume.folder / 'Alias')
        (self.volume.folder / 'Plain' / 'corpus' / 'media').mkdir(parents=True)
        try:
            self.pin(mount=str(self.volume.folder / 'Plain'))
            both('a plain folder at the mount point', internal_file, 'ok')
            both('a plain folder: its "external" file is not run', self.volume.folder / 'Plain' / 'corpus' / 'media' / 'x.mov',
                 'a_file_is_outside_the_corpus')
        finally:
            shutil.rmtree(self.volume.folder / 'Plain')
        self.pin(mount=str(self.volume.mount))
        self.volume.detach()
        both('unplugged', internal_file, 'ok')
        both('unplugged: its file is not run', external_file, 'a_file_is_outside_the_corpus')
        self.volume.attach()
        good = (self.scene.corpus / cr.VOLUME_PIN).read_text()
        for poison in ('{not json', json.dumps(dict(mount='/Volumes/x/../y', volume_uuid=self.volume.uuid())),
                       json.dumps(dict(mount='/Volumes//x', volume_uuid=self.volume.uuid())),
                       json.dumps(dict(mount='//Volumes/x', volume_uuid=self.volume.uuid())),       # Codex #331 F4
                       json.dumps(dict(mount=str(self.volume.mount), volume_uuid='nope'))):
            (self.scene.corpus / cr.VOLUME_PIN).write_text(poison)
            both('a poisoned pin ' + poison[:20], internal_file, 'external_volume_pin_unreadable')
        (self.scene.corpus / cr.VOLUME_PIN).write_text(good)
        os.link(self.scene.corpus / cr.VOLUME_PIN, pathlib.Path(self.tmp.name, 'second-name.json'))   # Codex #331 F3
        both('a pin with a second name', internal_file, 'external_volume_pin_unreadable')
        os.unlink(pathlib.Path(self.tmp.name, 'second-name.json'))
        (self.scene.corpus / cr.VOLUME_PIN).unlink()
        both('nothing adopted', internal_file, 'ok')
        both('nothing adopted: no external file', external_file, 'a_file_is_outside_the_corpus')
        self.assertEqual(len(seen), 19)

    def test_the_driver_lets_a_row_name_the_adopted_volume_and_runs_a_file_there_only_when_proven(self):
        support = (SCRIPTS / 'corpus' / 'CorpusDriverSupport.swift').read_text()
        self.assertIn('[config.mediaRoot] + (external.mount.map { [$0 + "/corpus/media"] } ?? [])', support)
        self.assertIn('external: CorpusSeal.external(realHome: realHome())', support)
        check = (SCRIPTS / 'corpus' / 'CorpusCheckDriver.swift').read_text()
        self.assertIn('"channelImbalance:" + CorpusWords.caseName(side)', check)
        self.assertTrue({'channelImbalance:leftOnly', 'channelImbalance:rightOnly'} <= cr.ONE_SIDED_KINDS)



class RemountCase(TwoRootTestCase):
    """The adopted test volume moved to where an attack would put it, and put back."""

    def stale(self, name):
        folder = self.scene.seal.work_root / name
        folder.mkdir(parents=True)
        (folder / 'vol').mkdir()
        (folder / 'vol' / 'clone.mov').write_bytes(b'c' * 10)
        old = time.time() - 10 * 3600
        os.utime(folder, (old, old))
        return folder

    def remount_inside(self, folder):
        """The adopted volume, unmounted from its place and mounted inside `folder`; a locked sentinel on it."""
        self.volume.detach()
        inner = folder / 'x10'
        inner.mkdir()
        done = subprocess.run(['hdiutil', 'attach', '-nobrowse', '-noverify', '-quiet', '-mountpoint', str(inner), self.volume.image],
                              capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr)
        sentinel = inner / 'corpus' / 'media' / 'sentinel.mov'
        sentinel.write_bytes(b'a corpus copy')
        os.chflags(sentinel, 0x2)                                          # UF_IMMUTABLE, as Promote leaves what it archives
        return inner, sentinel

    def put_back(self, inner, sentinel):
        if os.path.lexists(sentinel):
            os.chflags(sentinel, 0)
            sentinel.unlink()
        subprocess.run(['hdiutil', 'detach', '-force', '-quiet', str(inner)], capture_output=True, timeout=120)
        self.volume.attach()


class CodexRound331Tests(RemountCase):
    """Codex #331 (block, 5 findings) on 431753b90..682ce86f4: each finding as its reproduction."""

    # F1 (P0): a deletion never crosses into another volume, wherever that volume is mounted.

    def test_f1_pruning_a_dead_work_folder_never_reaches_a_volume_mounted_inside_it(self):
        self.scene.grow()
        folder = self.stale('20261101_000000_1-proof')
        inner, sentinel = self.remount_inside(folder)
        old = time.time() - 10 * 3600
        os.utime(folder, (old, old))                                       # the mount point's mkdir made it look new
        try:
            self.scene.seal._external = None
            lines = cr.prune(self.scene.seal, 'check')
            self.assertEqual(sentinel.read_bytes(), b'a corpus copy')
            self.assertTrue(os.lstat(sentinel).st_flags & 0x2, 'a lock on the other volume was cleared')
            self.assertTrue((folder / 'vol' / 'clone.mov').exists(), 'a tree with a mount in it is refused whole')
            self.assertIn('could not be removed', '\n'.join(lines))
        finally:
            self.put_back(inner, sentinel)

    def test_f1_a_runs_own_work_folder_with_a_volume_mounted_inside_is_left_whole(self):
        self.scene.grow()
        lane = cr.Lane(self.scene.seal, 'check', 'a' * 40, '20261119_150000_9', self.scene.out, self.scene.worktree,
                       self.scene.dd, SCRIPTS / 'corpus')
        lane.work.mkdir(parents=True)
        (lane.work / 'vol').mkdir()
        (lane.work / 'vol' / 'clone.mov').write_bytes(b'c')
        inner, sentinel = self.remount_inside(lane.work)
        try:
            lane.remove_work()
            self.assertEqual(sentinel.read_bytes(), b'a corpus copy')
            self.assertTrue(os.lstat(sentinel).st_flags & 0x2)
            self.assertIn('could NOT be removed whole', '\n'.join(lane.lines))
        finally:
            self.put_back(inner, sentinel)

    def test_f1_every_tree_the_harness_removes_goes_through_the_one_bounded_removal(self):
        for name in ('corpus_run.py', 'corpus_coverage.py'):
            text = (SCRIPTS / name).read_text()
            self.assertNotIn('shutil.rmtree(', text, f'{name} removes a tree without the device bound')
        self.assertGreaterEqual((SCRIPTS / 'corpus_run.py').read_text().count('remove_tree('), 5)
        self.assertIn('remove_tree(', (SCRIPTS / 'corpus_coverage.py').read_text())

    # F2 (P1): the external root is proven again before each launch (Python) and before each engine (Swift).

    def test_f2_a_volume_that_loses_its_marker_between_launches_stops_the_run(self):
        self.scene.grow()
        self.scene.plan['files'] = {sha_of(0): dict(crash='probe')}          # the host dies: the lane launches again
        self.scene.plan['remove'] = str(self.volume.mount / cr.MARKER)
        self.assertEqual(self.scene.run('check'), cr.EXIT_REFUSED, self.summary())
        self.assertIn('carries no THIS_IS_TEST_DATA.txt', self.summary())
        self.assertEqual(len([c for c in self.scene.recorded_calls() if 'config' in c]), 1, 'a second launch ran on stale proof')

    def test_f2_a_file_the_driver_found_unproven_is_not_run_amber_and_never_a_baseline(self):
        self.scene.grow()
        gone = 'external_volume_not_proven'
        self.scene.plan['files'] = {sha_of(11): dict(probe=gone, check=gone, audio=gone, pair=gone)}
        self.assertEqual(self.scene.run('check'), cr.EXIT_AMBER, self.summary())
        self.assertIn('1 files on it NOT RUN', self.summary())
        with self.assertRaises(cr.Refused):
            cr.accept(self.scene.seal, 'check', 'x')

    def test_f2_the_driver_asks_the_seal_before_every_engine(self):
        support = (SCRIPTS / 'corpus' / 'CorpusDriverSupport.swift').read_text()
        body = support[support.index('    func engine('):]
        self.assertLess(body.index('CorpusSeal.mayOpen(item.path, realHome: CorpusRun.realHome(), atOpen: external)'),
                        body.index('try await body()'))

    # F3 (P1): a pin or a progress file with a second name is refused before anything is written.

    def test_f3_a_pin_with_a_second_name_is_refused_by_python(self):
        self.scene.grow(prepare=False)
        work = self.scene.seal.work_root / 'r-check'
        work.mkdir(parents=True)
        os.link(self.scene.corpus / cr.VOLUME_PIN, work / 'progress.jsonl')
        with self.assertRaises(cr.Refused):
            self.scene.seal.check()

    # F4 (P2): Python and Swift agree on a pin's spelling (covered beside Swift in SwiftExternalSealTests).

    def test_f4_a_doubled_leading_slash_is_not_a_plain_mount(self):
        self.scene.grow(prepare=False)
        pin = self.scene.corpus / cr.VOLUME_PIN
        pin.write_text(json.dumps(dict(json.loads(pin.read_text()), mount='//Volumes/OfflineTest')))
        with self.assertRaises(cr.Refused):
            self.scene.seal.check()

    # F5 (P2): proof reads the newest WHOLE check run: a run without the external volume is not one.

    def test_f5_a_check_run_without_the_volume_never_displaces_the_whole_one(self):
        self.scene.plan['engines'] = ['probe', 'check', 'audio', 'pair']
        self.scene.grow()
        self.scene.plan['files'] = {sha_of(11): dict(audio='ok_with_findings', audio_kinds=['channelImbalance:leftOnly'])}
        self.scene.run('check', stamp='20261119_100000_1')
        self.volume.detach()
        self.scene.seal._external = None
        self.scene.plan['files'] = {}
        self.assertEqual(self.scene.run('check', stamp='20261119_110000_2'), cr.EXIT_AMBER)
        self.volume.attach()
        self.scene.seal._external = None
        chosen, picked = cr.proof_files(self.scene.seal, cr.load_manifest(self.scene.seal))
        self.assertEqual(picked['check_run'], '20261119_100000_1')
        self.assertIn(sha_of(11), [e.sha for e in chosen])



class CodexRound332Tests(RemountCase):
    """Codex #332 (closing pass on the #331 fixes; block, 3 findings): each as its reproduction."""

    def test_r2_f1_collecting_the_progress_files_never_moves_a_folder_or_crosses_a_volume(self):
        self.scene.grow()
        lane = cr.Lane(self.scene.seal, 'check', 'a' * 40, '20261119_160000_9', self.scene.out, self.scene.worktree,
                       self.scene.dd, SCRIPTS / 'corpus')
        lane.work.mkdir(parents=True)
        (lane.work / 'progress-1.jsonl').write_text('{"ev": "done"}\n')
        self.volume.detach()
        inner = lane.work / 'progress-mounted'
        inner.mkdir()
        done = subprocess.run(['hdiutil', 'attach', '-nobrowse', '-noverify', '-quiet', '-mountpoint', str(inner), self.volume.image],
                              capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr)
        sentinel = inner / 'corpus' / 'media' / 'sentinel.mov'
        sentinel.write_bytes(b'a corpus copy')
        try:
            lane.collect_progress()
            self.assertEqual(sentinel.read_bytes(), b'a corpus copy', 'a folder on another volume was moved (copied, then deleted)')
            self.assertTrue((lane.report_dir / 'progress-1.jsonl').is_file(), "the run's own progress file is kept with its report")
            self.assertFalse((lane.report_dir / 'progress-mounted').exists())
        finally:
            if os.path.lexists(sentinel):
                sentinel.unlink()
            subprocess.run(['hdiutil', 'detach', '-force', '-quiet', str(inner)], capture_output=True, timeout=120)
            self.volume.attach()

    def test_r2_f2_a_volume_mounted_over_corpus_work_is_refused_and_nothing_on_it_is_removed(self):
        self.scene.grow()
        work = self.scene.seal.work_root
        work.mkdir(parents=True, exist_ok=True)
        self.volume.detach()
        done = subprocess.run(['hdiutil', 'attach', '-nobrowse', '-noverify', '-quiet', '-mountpoint', str(work), self.volume.image],
                              capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr)
        old = work / '20261101_000000_1-check'
        sentinel = old / 'sentinel.mov'
        try:
            old.mkdir()
            sentinel.write_bytes(b'a corpus copy')
            os.chflags(sentinel, 0x2)
            aged = time.time() - 10 * 3600
            os.utime(old, (aged, aged))
            with self.assertRaises(cr.Refused):
                self.scene.seal.check()
            with self.assertRaises(cr.Refused):
                cr.prune(self.scene.seal, 'check')
            try:
                removed = cr.remove_tree(self.scene.seal, old)
            except cr.Refused:
                removed = False                                             # the write door refuses it first (Codex #333 F1)
            self.assertFalse(removed, 'a tree off the home volume was removed')
            self.assertEqual(sentinel.read_bytes(), b'a corpus copy')
            self.assertTrue(os.lstat(sentinel).st_flags & 0x2, 'a lock on the other volume was cleared')
        finally:
            if os.path.lexists(sentinel):
                os.chflags(sentinel, 0)
                sentinel.unlink()
            if old.exists():
                old.rmdir()
            subprocess.run(['hdiutil', 'detach', '-force', '-quiet', str(work)], capture_output=True, timeout=120)
            self.volume.attach()

    def test_r2_the_harness_moves_no_folder_and_copies_nothing_across_a_volume(self):
        text = (SCRIPTS / 'corpus_run.py').read_text()
        self.assertNotIn('shutil.move(', text, 'shutil.move copies a tree across volumes and deletes the source')



class CodexRound333Tests(RemountCase):
    """Codex #333 (closing pass 2; block, 4 findings): the Python halves, each as its reproduction."""

    def test_r3_f1_accept_never_writes_onto_a_volume_mounted_inside_reports(self):
        self.scene.grow()
        self.assertEqual(self.scene.run('check'), cr.EXIT_GREEN, self.summary())
        reports = self.scene.seal.reports / 'check'
        mount = self.volume.mount
        shutil.copytree(reports, mount / 'check-copy', symlinks=True)
        (mount / 'check-copy' / cr.BASELINE).write_text('sentinel\n')
        os.replace(reports, self.scene.seal.reports / 'check-home')
        reports.mkdir()
        self.volume.detach()
        done = subprocess.run(['hdiutil', 'attach', '-nobrowse', '-noverify', '-quiet', '-mountpoint', str(reports), self.volume.image],
                              capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr)
        inner = reports / 'check-copy'
        try:
            for child in list(inner.iterdir()):                             # the stored run where accept looks for it
                os.rename(child, reports / child.name)
            before = sorted(p.name for p in reports.iterdir())
            with self.assertRaises(cr.Refused):
                cr.accept(self.scene.seal, 'check', 'x')
            self.assertEqual((reports / cr.BASELINE).read_text(), 'sentinel\n', 'the baseline on the other volume was replaced')
            self.assertEqual(sorted(p.name for p in reports.iterdir()), before, 'accept left a file on the other volume')
            with self.assertRaises(cr.Refused):
                self.scene.seal.writable(reports / 'x')
        finally:
            subprocess.run(['hdiutil', 'detach', '-force', '-quiet', str(reports)], capture_output=True, timeout=120)
            reports.rmdir()
            os.replace(self.scene.seal.reports / 'check-home', reports)
            self.volume.attach()

    def test_r3_f1_the_lanes_out_folder_must_be_on_the_home_volume_too(self):
        self.scene.grow()
        self.volume.detach()
        out = self.scene.out
        done = subprocess.run(['hdiutil', 'attach', '-nobrowse', '-noverify', '-quiet', '-mountpoint', str(out), self.volume.image],
                              capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr)
        try:
            with self.assertRaises(cr.Refused):
                self.scene.seal.out_folder(out)
        finally:
            subprocess.run(['hdiutil', 'detach', '-force', '-quiet', str(out)], capture_output=True, timeout=120)
            self.volume.attach()

    def test_r3_f3_an_internal_copy_on_a_volume_mounted_inside_media_does_not_verify(self):
        # The internal copies' folder with a volume mounted over it, holding same-sized files: not the corpus.
        self.scene.grow()
        folder = self.scene.corpus / 'media' / 'Volumes' / 'PrivateDrive' / 'Grandma'
        stand_in = self.volume.mount / 'stand-in'
        shutil.copytree(folder, stand_in)
        self.volume.detach()
        done = subprocess.run(['hdiutil', 'attach', '-nobrowse', '-noverify', '-quiet', '-mountpoint', str(folder), self.volume.image],
                              capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr)
        try:
            for child in (folder / 'stand-in').iterdir():
                os.rename(child, folder / child.name)
            self.scene.seal._external = None
            entries = cr.load_manifest(self.scene.seal)
            held = [e for e in entries if e.sha in set(cr.prepared_record(self.scene.seal)['built_over'])]
            verdict = cr.verify_catalog(self.scene.seal, self.scene.seal.state / DB, held,
                                        checked=[e.sha for e in held if e.root == 'internal'])
            self.assertEqual((verdict['ok'], verdict['outside_corpus']), (0, 1))
            states = cr.current_states(self.scene.seal, entries, [e.sha for e in entries if e.root == 'external'])
            self.assertEqual(states[sha_of(0)], 'changed', 'another volume\'s file is another inode: never present, never run')
        finally:
            subprocess.run(['hdiutil', 'detach', '-force', '-quiet', str(folder)], capture_output=True, timeout=120)
            self.volume.attach()

    def test_r3_f4_the_lane_holds_the_volume_it_proved_not_one_adopted_later_at_the_same_mount(self):
        self.scene.grow()
        lane = cr.Lane(self.scene.seal, 'check', 'a' * 40, '20261119_170000_9', self.scene.out, self.scene.worktree,
                       self.scene.dd, SCRIPTS / 'corpus')
        entries = cr.load_manifest(self.scene.seal)
        lane.proven_uuid = self.scene.seal.external().uuid
        self.assertRegex(lane.proven_uuid or '', cr._UUID)
        pin = self.scene.corpus / cr.VOLUME_PIN
        b_uuid = '22222222-3333-4444-5555-666666666666'
        pin.write_text(json.dumps(dict(json.loads(pin.read_text()), volume_uuid=b_uuid)))
        self.scene.seal.volume_uuid = lambda mount: b_uuid                  # B mounted at the same path and adopted
        results = {e.sha: {} for e in entries}
        with self.assertRaises(cr.Refused) as refused:
            lane.reprove([e for e in entries], results)
        self.assertIn('changed during the run', str(refused.exception))



class CodexRound334Tests(RemountCase):
    """Codex #334 (closing pass 3; fix, 4 findings): the Python halves."""

    def lane(self, stamp='20261119_180000_9'):
        return cr.Lane(self.scene.seal, 'check', 'a' * 40, stamp, self.scene.out, self.scene.worktree, self.scene.dd, SCRIPTS / 'corpus')

    def test_r4_f3_the_overlay_is_never_laid_on_a_volume_mounted_in_the_testbed(self):
        self.scene.grow()
        tests_folder = self.scene.worktree / 'VideoScan' / 'VideoScanTests'
        self.volume.detach()
        done = subprocess.run(['hdiutil', 'attach', '-nobrowse', '-noverify', '-quiet', '-mountpoint', str(tests_folder), self.volume.image],
                              capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr)
        try:
            before = sorted(p.name for p in tests_folder.iterdir())
            with self.assertRaises(cr.Refused):
                self.lane().install_overlay()
            self.assertEqual(sorted(p.name for p in tests_folder.iterdir()), before, 'the overlay landed on another volume')
        finally:
            subprocess.run(['hdiutil', 'detach', '-force', '-quiet', str(tests_folder)], capture_output=True, timeout=120)
            self.volume.attach()

    def test_r4_f3_the_patched_test_run_file_is_never_written_on_a_volume_mounted_under_derived_data(self):
        self.scene.grow()
        products = self.scene.dd / 'Build' / 'Products'
        products.mkdir(parents=True, exist_ok=True)
        self.volume.detach()
        done = subprocess.run(['hdiutil', 'attach', '-nobrowse', '-noverify', '-quiet', '-mountpoint', str(products), self.volume.image],
                              capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr)
        try:
            xctestrun = products / 'VideoScan_VideoScan-CI_macosx.xctestrun'
            with open(xctestrun, 'wb') as f:
                plistlib.dump({"TestConfigurations": [{"TestTargets": [{"BlueprintName": "VideoScanTests", "TestBundlePath": "x"}]}]}, f)
            lane = self.lane()
            self.scene.seal.mkdir(lane.work)
            before = sorted(p.name for p in products.iterdir())
            with self.assertRaises(cr.Refused):
                lane.launch(cr.load_manifest(self.scene.seal)[:1], self.scene.seal.state / DB, xctestrun)
            self.assertEqual(sorted(p.name for p in products.iterdir()), before, 'a patched file was written on another volume')
        finally:
            subprocess.run(['hdiutil', 'detach', '-force', '-quiet', str(products)], capture_output=True, timeout=120)
            self.volume.attach()

    def test_r4_f4_a_corpus_that_is_a_link_is_refused_before_anything_and_no_pin_is_made(self):
        self.scene.grow(adopt=False, prepare=False)
        real = pathlib.Path(self.tmp.name, 'corpus-real')
        os.replace(self.scene.corpus, real)
        os.symlink(real, self.scene.corpus)
        try:
            with self.assertRaises(cr.Refused):
                self.scene.seal.check()
            with self.assertRaises(cr.Refused):
                cr.adopt_volume(self.scene.seal, str(self.volume.mount), 'x')
            self.assertFalse(os.path.lexists(real / cr.VOLUME_PIN))
        finally:
            os.unlink(self.scene.corpus)
            os.replace(real, self.scene.corpus)



class CodexRound335Tests(RemountCase):
    """Codex #335 (closing pass 4; block, 4 P1 + 1 P2): the Python halves."""

    def test_r5_f1_the_build_is_refused_when_its_derived_data_is_on_another_volume(self):
        self.scene.grow()
        products = self.scene.dd / 'Build' / 'Products'
        products.mkdir(parents=True, exist_ok=True)
        self.volume.detach()
        done = subprocess.run(['hdiutil', 'attach', '-nobrowse', '-noverify', '-quiet', '-mountpoint', str(products), self.volume.image],
                              capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr)
        try:
            before = sorted(p.name for p in products.iterdir())
            self.scene.plan_path.write_text(json.dumps(self.scene.plan))
            os.environ['FAKE_PLAN'] = str(self.scene.plan_path)
            lane = cr.Lane(self.scene.seal, 'check', 'a' * 40, '20261119_190000_9', self.scene.out, self.scene.worktree,
                           self.scene.dd, SCRIPTS / 'corpus', xcodebuild=str(self.scene.fake))
            with self.assertRaises(cr.Refused):
                lane.build()
            self.assertEqual([c for c in self.scene.recorded_calls() if c.get('args', [''])[0] == 'build-for-testing'], [])
            self.assertEqual(sorted(p.name for p in products.iterdir()), before)
        finally:
            os.environ.pop('FAKE_PLAN', None)
            subprocess.run(['hdiutil', 'detach', '-force', '-quiet', str(products)], capture_output=True, timeout=120)
            self.volume.attach()

    def test_r5_f5_a_clone_is_never_made_from_a_volume_mounted_inside_media(self):
        self.scene.grow()
        folder = self.scene.corpus / 'media' / 'Volumes' / 'PrivateDrive' / 'Grandma'
        (self.volume.mount / 'stand-in').mkdir()
        for child in folder.iterdir():
            shutil.copy2(child, self.volume.mount / 'stand-in' / child.name)
        self.volume.detach()
        done = subprocess.run(['hdiutil', 'attach', '-nobrowse', '-noverify', '-quiet', '-mountpoint', str(folder), self.volume.image],
                              capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr)
        try:
            source = next((folder / 'stand-in').iterdir())
            lane = cr.VerbsLane(self.scene.seal, 'verbs', 'a' * 40, '20261119_190000_8', self.scene.out, self.scene.worktree,
                                self.scene.dd, SCRIPTS / 'corpus', cp=str(self.scene.fake_cp))
            self.scene.seal.mkdir(lane.work)
            os.environ['FAKE_CP_CALLS'] = str(self.scene.cp_calls)
            with self.assertRaises(cr.Refused):
                lane.clone(source, lane.vol / 'x.mov')
            self.assertFalse(self.scene.cp_calls.exists(), 'cp was handed a file on another volume')
        finally:
            os.environ.pop('FAKE_CP_CALLS', None)
            subprocess.run(['hdiutil', 'detach', '-force', '-quiet', str(folder)], capture_output=True, timeout=120)
            self.volume.attach()



class WishListTests(unittest.TestCase):
    """DECISIONS 2026-11-19: the manifest is the wish list; each run uses what has arrived and been proven."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.scene = LaneScene(self.tmp.name)                 # prepared over all three files
        self.hashed = []
        real = self.scene.seal.hasher
        self.scene.seal.hasher = lambda path, size: (self.hashed.append(str(path)), real(path, size))[1]

    def tearDown(self):
        self.tmp.cleanup()

    def media(self, n):
        return self.scene.corpus / 'media' / self.scene.files[n][1].lstrip('/')

    def never_arrived(self, n):
        """File n not copied yet: no file, and no ledger record (it was never proven)."""
        os.unlink(self.media(n))
        ledger = cr.Ledger.load(self.scene.seal)
        ledger.files.pop(sha_of(n), None)
        ledger.save()

    def summary(self):
        return (self.scene.out / 'corpus-summary.txt').read_text()

    def fresh(self, stamp='20261119_120000_1'):
        self.scene.out = self.scene.home / 'm4run' / 'out' / f'{stamp}-corpus'
        self.scene.out.mkdir(parents=True, exist_ok=True)

    def test_ingest_is_once_cheap_when_nothing_is_new_and_only_new_files_are_hashed(self):
        code, lines = cr.prepare(self.scene.seal)
        self.assertEqual((code, self.hashed), (cr.EXIT_GREEN, []), 'a second prepare read a file again')
        self.assertIn('nothing new, the sealed catalog is as it was', lines[0])
        self.never_arrived(2)
        cr.prepare(self.scene.seal)
        self.scene.put(self.media(2), b'x' * self.scene.files[2][2], sha_of(2))     # the copy arrives
        _, lines = cr.prepare(self.scene.seal)
        self.assertEqual(self.hashed, [str(self.media(2))])
        self.assertIn('the sealed catalog rebuilt', lines[0])
        self.assertIn('  files: internal present 3 · missing 0', lines)

    def test_a_partial_copy_is_never_hashed_and_reads_missing(self):
        self.never_arrived(1)
        cr.prepare(self.scene.seal)
        self.media(1).write_bytes(b'x' * 10)                                         # a copy cut short
        _, lines = cr.prepare(self.scene.seal)
        self.assertEqual(self.hashed, [])
        self.assertIn('  files: internal present 2 · missing 1', lines)

    def test_bytes_that_are_not_the_manifests_are_mismatched_named_never_run_and_amber(self):
        self.never_arrived(0)
        cr.prepare(self.scene.seal)
        self.media(0).write_bytes(b'q' * self.scene.files[0][2])                    # the right size, the wrong bytes
        code, lines = cr.prepare(self.scene.seal)
        self.assertEqual(code, cr.EXIT_AMBER)
        self.assertIn(f'  mismatched (AMBER): {sha_of(0)[:12]}', lines)
        self.fresh()
        self.assertEqual(self.scene.run('check'), cr.EXIT_AMBER, self.summary())
        config = [c for c in self.scene.recorded_calls() if 'config' in c][-1]['config']
        self.assertNotIn(sha_of(0), [i['sha'] for i in config['pending']])
        self.assertIn(f'  mismatched (AMBER): {sha_of(0)[:12]}', self.summary())
        self.assertNotIn('Grandma', self.summary())

    def test_vanished_and_changed_are_amber_and_named_and_prepare_proves_a_touched_file_again(self):
        self.fresh()
        os.unlink(self.media(1))
        os.utime(self.media(2), (1, 1))                                              # same bytes, new mtime
        self.assertEqual(self.scene.run('check'), cr.EXIT_AMBER, self.summary())
        self.assertIn(f'  vanished (AMBER): {sha_of(1)[:12]}', self.summary())
        self.assertIn(f'  changed (AMBER): {sha_of(2)[:12]}', self.summary())
        self.assertIn('  files: internal present 1 · missing 0 · vanished 1 · changed 1', self.summary())
        _, lines = cr.prepare(self.scene.seal)
        self.assertEqual(self.hashed, [str(self.media(2))])
        self.assertIn('  files: internal present 2 · missing 0 · vanished 1', lines)

    def test_missing_never_moves_the_verdict_a_run_with_missing_may_be_accepted_and_new_files_are_counted(self):
        self.never_arrived(2)
        cr.prepare(self.scene.seal)
        self.fresh('20261119_120000_1')
        self.assertEqual(self.scene.run('check', stamp='20261119_120000_1'), cr.EXIT_GREEN, self.summary())
        self.assertIn('  files: internal present 2 · missing 1', self.summary())
        cr.accept(self.scene.seal, 'check', 'x')                                    # the baseline is per file
        self.scene.put(self.media(2), b'x' * self.scene.files[2][2], sha_of(2))
        cr.prepare(self.scene.seal)
        self.fresh('20261119_130000_2')
        self.assertEqual(self.scene.run('check', stamp='20261119_130000_2'), cr.EXIT_GREEN, self.summary())
        self.assertIn('0 of 2 files changed (new in this run 1, not in this run 0)', self.summary())

    def test_a_ledger_that_cannot_be_read_back_stops_prepare_and_lanes(self):
        (self.scene.seal.state / cr.LEDGER).write_text('{"version": 1, "files": {"nope": {}}}')
        with self.assertRaises(cr.Refused) as refused:
            cr.prepare(self.scene.seal)
        self.assertIn('cannot be read back', str(refused.exception))
        self.fresh()
        self.assertEqual(self.scene.run('check'), cr.EXIT_REFUSED)

    def test_a_file_ingested_after_the_last_prepare_waits_for_the_next(self):
        entries = cr.load_manifest(self.scene.seal)
        ledger = cr.Ledger.load(self.scene.seal)
        states = cr.classify(entries, ledger, built_over=[e.sha for e in entries if e.sha != sha_of(1)])
        self.assertEqual(states[sha_of(1)], 'missing')


class WishListScaleTests(unittest.TestCase):

    def test_classifying_100k_files_against_the_ledger_stays_inside_the_budget(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = pathlib.Path(tmp)
            entries = [cr.Entry(sha_of(i), f'/Volumes/D/f{i}.mov', 10, 'v2', folder / f'f{i}.mov') for i in range(100_000)]
            seal = cr.Seal(folder / 'home', 'ricksm4')
            ledger = cr.Ledger(seal, {sha_of(i): dict(root='internal', size=10, mtime_ns=1, status='ok') for i in range(0, 100_000, 2)})
            t0 = time.time()
            states = cr.classify(entries, ledger, built_over=list(ledger.files))
            took = time.time() - t0
            self.assertEqual(Counter_of(states.values()), {'missing': 50_000, 'vanished': 50_000})
            self.assertLess(took, 10.0, f'{took:.1f}s')


def Counter_of(values):
    out = {}
    for v in values:
        out[v] = out.get(v, 0) + 1
    return out



class SmokeLaneTests(unittest.TestCase):
    """DECISIONS 2026-11-19: `run <lane> --smoke` — a small stratified subset; SMOKE; never a baseline."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.scene = LaneScene(self.tmp.name, with_proof_engine=True)

    def tearDown(self):
        self.tmp.cleanup()

    def summary(self):
        return (self.scene.out / 'corpus-summary.txt').read_text()

    def pending(self):
        return [c for c in self.scene.recorded_calls() if 'config' in c][-1]['config']['pending']

    def test_the_subset_is_one_file_per_stratum_and_codec_mix_dealt_round_robin_and_deterministic(self):
        def e(n, stratum, size):
            return cr.Entry(sha_of(n), f'/Volumes/D/{n}.mov', size, stratum, pathlib.Path(f'/x/{n}.mov'))
        entries = [e(1, 'a', 30), e(2, 'a', 10), e(3, 'a', 20), e(4, 'b', 5), e(5, 'b', 50), e(6, 'c', 7)]
        codecs = {sha_of(1): ('mov', 'h264', 'aac'), sha_of(2): ('mov', 'h264', 'aac'), sha_of(3): ('mxf', 'dnxhd', ''),
                  sha_of(4): ('avi', 'dv', 'pcm'), sha_of(5): ('avi', 'dv', 'pcm'), sha_of(6): ('mkv', 'ffv1', 'pcm')}
        picked = cr.smoke_sample(entries, codecs)
        self.assertEqual(sorted(x.sha for x in picked), sorted([sha_of(2), sha_of(3), sha_of(4), sha_of(6)]))
        self.assertEqual([x.sha for x in cr.smoke_sample(entries, codecs, cap=3)], sorted([sha_of(2), sha_of(4), sha_of(6)]),
                         'round-robin: every stratum before a second mix of one')
        self.assertEqual(cr.smoke_sample(list(reversed(entries)), codecs), picked)

    def test_a_smoke_run_is_labelled_never_accepted_and_never_the_implicit_baseline(self):
        self.assertEqual(self.scene.run('check', stamp='20261119_100000_1', smoke=''), cr.EXIT_GREEN, self.summary())
        self.assertTrue(self.summary().startswith('corpus check SMOKE: GREEN'))
        self.assertIn(cr.SMOKE_NOTE, self.summary())
        facts = json.loads((self.scene.out / cr.VERDICT_FILE).read_text())
        self.assertTrue(facts['smoke'])
        with self.assertRaises(cr.Refused) as refused:
            cr.accept(self.scene.seal, 'check', 'x')
        self.assertIn('SMOKE', str(refused.exception))
        self.assertEqual(self.scene.run('check', stamp='20261119_110000_2'), cr.EXIT_GREEN)
        self.assertIn('baseline: this run', self.summary(), 'a smoke run became the implicit baseline')

    def test_proof_takes_two_and_verbs_one_file_per_role(self):
        self.scene.plan['engines'] = ['balance', 'proof']
        self.scene.run('proof', stamp='20261119_100000_1', smoke='')
        self.assertLessEqual(len(self.pending()), cr.SMOKE_PROOF)
        self.scene.plan['engines'] = VERBS
        self.assertEqual(self.scene.run('verbs', stamp='20261119_100000_2', smoke=''), cr.EXIT_GREEN, self.summary())
        self.assertEqual(sorted(i['role'] for i in self.pending()), ['dup', 'purge', 'set_aside'],
                         'every role the three-file corpus can fill, once')

    def test_a_smoke_run_works_with_files_missing(self):
        os.unlink(self.scene.corpus / 'media' / self.scene.files[2][1].lstrip('/'))
        ledger = cr.Ledger.load(self.scene.seal)
        ledger.files.pop(sha_of(2))
        ledger.save()
        cr.prepare(self.scene.seal)
        self.assertEqual(self.scene.run('check', smoke=''), cr.EXIT_GREEN, self.summary())
        self.assertIn('  files: internal present 2 · missing 1', self.summary())
        self.assertEqual(len(self.pending()), 2)

    def test_smoke_is_refused_for_coverage(self):
        self.assertEqual(self.scene.run('coverage', smoke=''), cr.EXIT_REFUSED)



class OneBuildTests(unittest.TestCase):
    """Charter §7 / Rick 2026-11-19: one build per commit — the gauntlet's build-for-testing once, then
    test-without-building per lane, each lane with its own patched copy of the .xctestrun."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.scene = LaneScene(self.tmp.name, with_proof_engine=True)

    def tearDown(self):
        self.tmp.cleanup()

    def builds(self):
        return [c for c in self.scene.recorded_calls() if c.get('args', [''])[0] == 'build-for-testing']

    def lane_run(self, lane, stamp, **extra):
        self.scene.plan['engines'] = {'check': ['probe', 'check', 'audio', 'pair'], 'proof': ['balance', 'proof'], 'verbs': VERBS}[lane]
        return self.scene.run(lane, stamp=stamp, **extra)

    def test_check_proof_and_verbs_at_one_commit_build_once_and_each_runs_its_own_test_run_file(self):
        for lane, stamp in (('check', '20261119_100000_1'), ('proof', '20261119_100000_2'), ('verbs', '20261119_100000_3')):
            self.assertIn(self.lane_run(lane, stamp), (cr.EXIT_GREEN, cr.EXIT_AMBER))
        self.assertEqual(len(self.builds()), 1, 'the same commit was built more than once')
        tests = [c for c in self.scene.recorded_calls() if c.get('args', [''])[0] == 'test-without-building']
        self.assertEqual([next(a for a in c['args'] if a.startswith('-only-testing:')) for c in tests],
                         ['-only-testing:VideoScanTests/CorpusCheckDriver', '-only-testing:VideoScanTests/CorpusProofDriver',
                          '-only-testing:VideoScanTests/CorpusVerbsDriver'])
        patched = [c['args'][c['args'].index('-xctestrun') + 1] for c in tests]
        self.assertEqual(len(set(patched)), 3, 'each lane patches its own copy')
        self.assertIn('the build reused: same commit, same drivers', (self.scene.out / 'corpus-summary.txt').read_text())
        binary = next((self.scene.dd / 'Build' / 'Products').rglob('VideoScanTests.xctest/Contents/MacOS/VideoScanTests'))
        self.assertEqual(binary.read_text(), 'built ' + ','.join(sorted(cr.ALL_DRIVERS)), 'one build holds the driver of every lane')

    def test_another_commit_another_build_into_the_folder_or_changed_drivers_build_again(self):
        self.lane_run('check', '20261119_100000_1')
        self.lane_run('check', '20261119_100000_2', sha='b' * 40)
        self.assertEqual(len(self.builds()), 2, 'another commit')
        binary = next((self.scene.dd / 'Build' / 'Products').rglob('VideoScanTests.xctest/Contents/MacOS/VideoScanTests'))
        binary.write_text('built without drivers')                         # the ui lane (or the sensor lane) built here since
        self.lane_run('check', '20261119_100000_3', sha='b' * 40)
        self.assertEqual(len(self.builds()), 3, 'a build into the same folder since')
        self.lane_run('check', '20261119_100000_4', sha='b' * 40)
        self.assertEqual(len(self.builds()), 3, 'and then reused')

    def test_a_mark_that_is_a_link_or_is_poisoned_is_never_trusted(self):
        self.lane_run('check', '20261119_100000_1')
        mark = self.scene.dd / cr.BUILD_MARK
        record = mark.read_text()
        elsewhere = pathlib.Path(self.tmp.name, 'mark.json')
        elsewhere.write_text(record)
        mark.unlink()
        os.symlink(elsewhere, mark)
        self.lane_run('check', '20261119_100000_2')
        self.assertEqual(len(self.builds()), 2)
        self.assertTrue(mark.is_symlink() or json.loads(mark.read_text()) is not None)



class CodexRound336Tests(unittest.TestCase):
    """Codex #336 (fix, 8 findings) on 79cae6ca0..dd23fc494: the corpus_run halves, each as its reproduction."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.scene = LaneScene(self.tmp.name, with_proof_engine=True)

    def tearDown(self):
        self.tmp.cleanup()

    def media(self, n):
        return self.scene.corpus / 'media' / self.scene.files[n][1].lstrip('/')

    def summary(self):
        return (self.scene.out / 'corpus-summary.txt').read_text()

    def pending(self):
        return [i['sha'] for i in [c for c in self.scene.recorded_calls() if 'config' in c][-1]['config']['pending']]

    def test_f2_a_file_changed_while_the_lane_built_is_excluded_and_reported_changed(self):
        size = self.scene.files[1][2]
        self.scene.plan['build_touch'] = [str(self.media(1)), 'q' * size]
        self.assertEqual(self.scene.run('check'), cr.EXIT_AMBER, self.summary())
        self.assertNotIn(sha_of(1), self.pending())
        self.assertIn(f'  changed (AMBER): {sha_of(1)[:12]}', self.summary())

    def test_f3_a_same_size_same_mtime_replacement_is_a_new_file_and_is_hashed_again(self):
        path = self.media(0)
        before = os.stat(path)
        fresh = path.with_name('replacement.tmp')
        fresh.write_bytes(b'r' * before.st_size)
        os.utime(fresh, ns=(before.st_atime_ns, before.st_mtime_ns))
        os.replace(fresh, path)                                         # rsync's temp-then-rename: a new inode
        entries = cr.load_manifest(self.scene.seal)
        self.assertEqual(cr.current_states(self.scene.seal, entries)[sha_of(0)], 'changed')
        _, lines = cr.prepare(self.scene.seal)
        self.assertIn(f'  mismatched (AMBER): {sha_of(0)[:12]}', lines)

    def test_f4_reuse_checks_the_build_the_lane_will_launch_not_another(self):
        self.scene.plan['engines'] = ['probe', 'check', 'audio', 'pair']
        self.scene.run('check', stamp='20261119_100000_1')
        products = self.scene.dd / 'Build' / 'Products'
        foreign = products / 'Release' / 'VideoScan.app' / 'Contents' / 'PlugIns' / 'VideoScanTests.xctest' / 'Contents' / 'MacOS'
        foreign.mkdir(parents=True)
        (foreign / 'VideoScanTests').write_text('a foreign Release build')
        with open(products / 'VideoScan_Foreign_macosx.xctestrun', 'wb') as f:
            plistlib.dump({"TestConfigurations": [{"TestTargets": [{"BlueprintName": "VideoScanTests", "TestHostPath": "__TESTROOT__/Release/VideoScan.app",
                                                                    "TestBundlePath": "__TESTHOST__/Contents/PlugIns/VideoScanTests.xctest"}]}]}, f)
        self.scene.run('check', stamp='20261119_100000_2')
        builds = [c for c in self.scene.recorded_calls() if c.get('args', [''])[0] == 'build-for-testing']
        self.assertEqual(len(builds), 2, 'a build the mark does not describe was launched')

    def test_f5_a_source_backup_replaced_during_prepare_never_passes_as_the_one_built_from(self):
        cr.prepare(self.scene.seal)
        before = (self.scene.seal.state / DB).read_bytes()
        os.unlink(self.media(2))                                       # the set changes: prepare rebuilds
        real = cr.build_catalog

        def swap(seal, source, entries, dest):
            counts = real(seal, source, entries, dest)
            os.utime(source, (1, 1))                                    # a new backup put in place meanwhile
            return counts
        cr.build_catalog = swap
        try:
            with self.assertRaises(cr.Refused) as refused:
                cr.prepare(self.scene.seal)
        finally:
            cr.build_catalog = real
        self.assertIn('changed during prepare', str(refused.exception))
        self.assertEqual((self.scene.seal.state / DB).read_bytes(), before)
        _, lines = cr.prepare(self.scene.seal)
        self.assertIn('the sealed catalog rebuilt', lines[0])

    def test_f6_nothing_present_yet_is_a_report_not_a_refusal(self):
        ledger = cr.Ledger.load(self.scene.seal)
        for n in range(3):
            os.unlink(self.media(n))
            ledger.files.pop(sha_of(n))
        ledger.save()
        cr.prepare(self.scene.seal)
        self.assertEqual(self.scene.run('check'), cr.EXIT_GREEN, self.summary())
        self.assertIn('corpus check: GREEN 0 files', self.summary())
        self.assertIn('  files: internal present 0 · missing 3', self.summary())

    def test_f6_the_sole_file_vanished_is_amber_and_named(self):
        ledger = cr.Ledger.load(self.scene.seal)
        for n in (1, 2):
            os.unlink(self.media(n))
            ledger.files.pop(sha_of(n))
        ledger.save()
        cr.prepare(self.scene.seal)
        os.unlink(self.media(0))
        self.assertEqual(self.scene.run('check'), cr.EXIT_AMBER, self.summary())
        self.assertIn(f'  vanished (AMBER): {sha_of(0)[:12]}', self.summary())

    def test_f7_a_smoke_run_says_smoke_on_every_verdict_path(self):
        self.scene.plan['build_fails'] = True
        self.assertEqual(self.scene.run('check', smoke=''), cr.EXIT_RED)
        self.assertTrue(self.summary().startswith('corpus check SMOKE: RED'), self.summary())
        lines = cr.head_lines(dict(lane='proof', sha='a' * 40, engine_present=False, smoke=True, engines={}), None)
        self.assertTrue(lines[0].startswith('corpus proof SMOKE: NOT RUN'), lines[0])


# ── The access probe: the macOS privacy prompt on the headless M4 (2026-11-19 incident) ─────

SLEEPER = [sys.executable, '-c', 'import time; time.sleep(5)']   # past every injected timeout; gone soon after


class AccessProbeTests(unittest.TestCase):
    """`access_probe` alone, over plain temporary folders: a child that never answers, a read
    refused, a readable volume. The timeout is injected small: every test is well under a second."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.mount = pathlib.Path(self.tmp.name, 'X10')
        (self.mount / 'corpus' / 'media' / 'Volumes' / 'Drive').mkdir(parents=True)
        (self.mount / cr.MARKER).write_text('test data\n')
        self.media = self.mount / 'corpus' / 'media' / 'Volumes' / 'Drive' / 'clip.mp4'
        self.media.write_bytes(b'z' * 200)
        self.interpreter = os.path.realpath(sys.executable)

    def tearDown(self):
        for path in (self.mount, self.mount / cr.MARKER, self.media):
            if path.exists():
                path.chmod(0o755 if path.is_dir() else 0o644)
        self.tmp.cleanup()

    def patch_command(self, command):
        saved = cr.access_probe_command
        cr.access_probe_command = lambda mount: command
        self.addCleanup(setattr, cr, 'access_probe_command', saved)

    def test_a_child_that_never_answers_is_refused_within_the_timeout_and_names_the_interpreter(self):
        self.patch_command(SLEEPER)
        t0 = time.monotonic()
        with self.assertRaises(cr.Refused) as refused:
            cr.access_probe(str(self.mount), timeout=0.4)
        took = time.monotonic() - t0
        self.assertLess(took, 3.0, 'the probe waited for its child instead of refusing at the timeout')
        message = str(refused.exception)
        for words in ('macOS is waiting for permission to read the external volume', 'Click Allow on the M4',
                      'Full Disk Access', self.interpreter, 'per interpreter path', 'Cellar', 'Nothing ran.'):
            self.assertIn(words, message)

    def test_the_timeout_is_the_module_constant_when_none_is_given(self):
        self.patch_command(SLEEPER)
        saved = cr.ACCESS_PROBE_TIMEOUT_S
        cr.ACCESS_PROBE_TIMEOUT_S = 0.3
        self.addCleanup(setattr, cr, 'ACCESS_PROBE_TIMEOUT_S', saved)
        t0 = time.monotonic()
        with self.assertRaises(cr.Refused):
            cr.access_probe(str(self.mount))
        self.assertLess(time.monotonic() - t0, 3.0)
        self.assertEqual(saved, 20.0, 'the M4 waits 20 s for a readable volume')

    def test_a_child_refused_with_eperm_is_refused_without_waiting(self):
        self.patch_command([sys.executable, '-c', 'import errno; raise PermissionError(errno.EPERM, "no")'])
        with self.assertRaises(cr.Refused):        # a child that dies of it (exit 1) is refused too, as a failed probe
            cr.access_probe(str(self.mount), timeout=5)
        self.patch_command([sys.executable, '-c', f'import sys; sys.exit({cr.ACCESS_PROBE_DENIED})'])
        with self.assertRaises(cr.Refused) as refused:
            cr.access_probe(str(self.mount), timeout=5)
        message = str(refused.exception)
        self.assertIn('does not let this Python read the external volume', message)
        self.assertNotIn('waiting', message)
        for words in (self.interpreter, 'per interpreter path', 'Nothing ran.'):
            self.assertIn(words, message)

    @unittest.skipIf(os.geteuid() == 0, 'root reads through file modes')
    def test_the_real_child_reports_a_refused_read_of_the_volume_the_marker_or_a_media_file(self):
        for locked in (self.media, self.mount / cr.MARKER, self.mount):
            with self.subTest(locked=locked.name):
                locked.chmod(0)
                try:
                    with self.assertRaises(cr.Refused) as refused:
                        cr.access_probe(str(self.mount), timeout=10)
                    self.assertIn('does not let this Python read', str(refused.exception))
                finally:
                    locked.chmod(0o755 if locked.is_dir() else 0o644)

    def test_a_readable_volume_passes_and_what_is_missing_is_the_seals_to_judge(self):
        cr.access_probe(str(self.mount), timeout=10)
        self.media.unlink()
        (self.mount / cr.MARKER).unlink()
        cr.access_probe(str(self.mount), timeout=10)        # the seal says "carries no marker", not the probe

    def test_the_child_is_this_interpreter(self):
        command = cr.access_probe_command('/Volumes/X')
        self.assertEqual((command[0], command[-1]), (sys.executable, '/Volumes/X'))


class AccessProbeSealTests(TwoRootTestCase):
    """The probe in its place: `Seal.external`, before the first read of the external root, so
    `prepare` and every lane are refused (rc 2, the lock released) instead of hanging."""

    def hang(self):
        saved = cr.access_probe_command
        cr.access_probe_command = lambda mount: SLEEPER
        self.addCleanup(setattr, cr, 'access_probe_command', saved)
        self.scene.seal.access_probe = lambda mount: cr.access_probe(mount, timeout=0.4)
        self.scene.seal._external = None
        self.scene.seal._readable = set()

    def test_prepare_is_refused_rc2_when_the_external_volume_does_not_answer(self):
        self.scene.grow(prepare=False)
        self.hang()
        before = (self.scene.seal.state / 'prepare.json').read_bytes()
        t0 = time.monotonic()
        code = self.scene.run('prepare')
        self.assertLess(time.monotonic() - t0, 10.0)
        self.assertEqual(code, cr.EXIT_REFUSED)
        summary = self.summary()
        self.assertIn('corpus: RED refused: macOS is waiting for permission to read the external volume', summary)
        self.assertIn(os.path.realpath(sys.executable), summary)
        self.assertEqual((self.scene.seal.state / 'prepare.json').read_bytes(), before, 'a refused prepare changed the state')

    def test_a_lane_is_refused_rc2_and_launches_nothing(self):
        self.scene.grow()
        self.hang()
        code = self.scene.run('check')
        self.assertEqual(code, cr.EXIT_REFUSED)
        self.assertIn('macOS is waiting for permission', self.summary())
        self.assertEqual([c for c in self.scene.recorded_calls() if 'config' in c], [], 'a refused lane launched the driver')

    def test_a_readable_volume_is_probed_once_per_process_and_the_run_proceeds(self):
        self.scene.grow(prepare=False)
        asked = []
        self.scene.seal.access_probe = lambda mount: (asked.append(mount), cr.access_probe(mount))
        self.scene.seal._external, self.scene.seal._readable = None, set()
        code, lines = cr.prepare(self.scene.seal)
        self.assertEqual(code, cr.EXIT_GREEN, lines)
        self.scene.seal._external = None                    # the re-proof before each launch
        self.assertEqual(self.scene.seal.external().state, 'ok')
        self.assertEqual(asked, [str(self.volume.mount)], 'the probe runs once per mount per process')

    def test_the_internal_root_alone_never_probes(self):
        self.scene.grow(prepare=False)
        self.volume.detach()
        self.hang()
        self.assertEqual(self.scene.seal.external().state, 'absent')


# ── N files in flight (Rick 2026-11-20: "2 hour testbeds in serial is not performant design … N == 1 does not
# sound good"). The config carries `jobs`; the driver walks the pending files through CorpusPool (N at a time,
# each file under its own deadline); a launch with N > 1 in flight never convicts a file of a crash or a
# timeout: every file it left unfinished is run again ALONE, and only a launch of one file at a time convicts.

class ManyFileScene(LaneScene):
    """Twelve files: enough for three groups of four in flight."""
    MORE = range(40, 49)                                 # contents no other row of the scene's source catalog uses
    FILES = LaneScene.FILES + [(n, f'/Volumes/PrivateDrive/Tapes/tape {n}.mov', 1000 + n, 'codec/container combo') for n in MORE]


def launches_of(scene):
    """Each test-host launch's config, in order."""
    return [c['config'] for c in scene.recorded_calls() if 'config' in c]


def progress_events(scene, lane='check', stamp='20261117_120000_1'):
    """(launch number, event) for every line of every launch's progress file, in order."""
    out = []
    for path in sorted(scene.report_dir(lane, stamp=stamp).glob('progress-*.jsonl'), key=lambda p: int(p.stem.split('-')[1])):
        for line in path.read_text().splitlines():
            try:
                out.append((int(path.stem.split('-')[1]), json.loads(line)))
            except ValueError:
                pass
    return out


class ParallelLaneTests(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.scene = ManyFileScene(self.tmp.name)
        self.shas = sorted(sha_of(n) for n, _, _, _ in ManyFileScene.FILES)     # the order the lane gives them: by content

    def tearDown(self):
        self.tmp.cleanup()

    def outcomes(self, stamp='20261117_120000_1'):
        return json.loads((self.scene.report_dir(stamp=stamp) / 'outcomes.json').read_text())

    def test_n_comes_through_the_config_and_the_default_is_the_hosts(self):
        self.assertEqual(self.scene.run(jobs=4), cr.EXIT_GREEN)
        self.assertEqual([c['jobs'] for c in launches_of(self.scene)], [4])
        report = json.loads((self.scene.report_dir() / 'report.json').read_text())
        self.assertEqual(report['jobs'], 4)
        self.assertIn('1 launch(es), 4 files at a time, per-file deadline 300s', (self.scene.out / 'corpus-summary.txt').read_text())
        self.assertEqual(self.scene.run(stamp='20261117_130000_2', jobs=None), cr.EXIT_GREEN)
        self.assertEqual(launches_of(self.scene)[-1]['jobs'], min(cr.default_jobs(), 12), 'never more in flight than files to run')
        # Half the host's logical cores (Rick 2026-11-20: M4 16 -> 8, Ultra 30 -> 15), never under one, never past JOBS_MAX.
        self.assertEqual([cr.default_jobs(c) for c in (None, 1, 2, 3, 16, 30, 128)], [1, 1, 1, 1, 8, 15, cr.JOBS_MAX])
        self.assertEqual(cr.JOBS_MAX, 32)

    def test_a_poisoned_n_is_refused_before_anything_runs(self):
        for bad in (0, -3, cr.JOBS_MAX + 1):
            self.assertEqual(self.scene.run(jobs=bad), cr.EXIT_REFUSED, bad)
        self.assertIn('--jobs', (self.scene.out / 'corpus-summary.txt').read_text())
        self.assertEqual(self.scene.recorded_calls(), [], 'nothing was built or launched')

    def test_one_at_a_time_is_the_serial_order_and_n_at_a_time_gives_the_same_records(self):
        self.assertEqual(self.scene.run(jobs=1), cr.EXIT_GREEN)
        order = [(ev['ev'], ev['sha']) for _, ev in progress_events(self.scene) if ev.get('ev') in ('begin', 'end')]
        pending = [i['sha'] for i in launches_of(self.scene)[0]['pending']]
        self.assertEqual(order, [(word, sha) for sha in pending for word in ('begin', 'end')], 'N=1: one file, then the next')
        serial = self.outcomes()
        self.assertEqual(self.scene.run(stamp='20261117_130000_2', jobs=4), cr.EXIT_GREEN)
        self.assertEqual(self.outcomes('20261117_130000_2'), serial, 'the same record for every file, whatever N')
        events = [ev for _, ev in progress_events(self.scene, stamp='20261117_130000_2')]
        firsts = [ev['ev'] for ev in events if ev.get('ev') in ('begin', 'end')][:4]
        self.assertEqual(firsts, ['begin'] * 4, 'four files were in flight together')

    def test_n_in_flight_every_file_gets_exactly_one_record_per_engine(self):
        self.assertEqual(self.scene.run(jobs=4), cr.EXIT_GREEN)
        events = [ev for _, ev in progress_events(self.scene)]
        for sha in self.shas:
            mine = [ev for ev in events if ev.get('sha') == sha]
            self.assertEqual([ev['ev'] for ev in mine].count('begin'), 1)
            self.assertEqual([ev['ev'] for ev in mine].count('end'), 1)
            self.assertEqual(sorted(ev['engine'] for ev in mine if ev['ev'] == 'engine'), sorted(self.scene.plan['engines']))
        outcomes = self.outcomes()
        self.assertEqual(sorted(outcomes), sorted(self.shas))
        self.assertTrue(all(r['outcome'] == 'probe=OK check=OK audio=OK pair=not_run' for r in outcomes.values()))

    def test_a_crash_with_others_in_flight_convicts_only_the_file_that_crashes_alone(self):
        self.scene.plan['files'] = {self.shas[5]: dict(crash='check')}
        self.assertEqual(self.scene.run(jobs=4), cr.EXIT_RED)
        report = json.loads((self.scene.report_dir() / 'report.json').read_text())
        self.assertEqual(report['engines']['check'], {'OK': 11, 'crash': 1})
        self.assertEqual(report['engines']['audio'], {'OK': 11, 'not_run': 1})
        self.assertEqual(report['failures'], {'check:crash': 1}, 'the three files in flight beside it are not crashes')
        self.assertEqual(self.outcomes()[self.shas[5]]['check'], 'crash')
        launches = launches_of(self.scene)
        # 1: all twelve, four at a time — dies in the second group. 2: that group ALONE, one at a time — 4 ends,
        # 5 crashes (convicted). 3: the two left of the group, alone. 4: the last group, four at a time again.
        self.assertEqual([(len(c['pending']), c['jobs']) for c in launches], [(12, 4), (4, 1), (2, 1), (4, 4)])
        self.assertEqual([i['sha'] for i in launches[1]['pending']], [i['sha'] for i in launches[0]['pending']][4:8])

    def test_a_relaunch_resumes_without_a_duplicate_or_a_gap(self):
        self.scene.plan['engines'] = list(cr.LANES['check'][1])       # every engine answers: file 9 dies only before `end`
        self.scene.plan['files'] = {self.shas[5]: dict(crash='check'), self.shas[9]: dict(crash='end')}
        self.scene.run(jobs=4)
        clean = [(n, ev['sha']) for n, ev in progress_events(self.scene) if ev.get('ev') == 'end' and not ev.get('cut')]
        ended = Counter_of(sha for _, sha in clean)
        self.assertEqual(sorted(ended), sorted(set(self.shas) - {self.shas[5], self.shas[9]}), 'every other file ended')
        self.assertEqual(set(ended.values()), {1}, 'no file that ended was run again')
        ended_in = {sha: n for n, sha in clean}
        launches = launches_of(self.scene)
        for n, config in enumerate(launches, 1):
            for item in config['pending']:
                self.assertGreaterEqual(ended_in.get(item['sha'], n), n, 'a file that had ended was given to a later launch')
        self.assertEqual([(len(c['pending']), c['jobs']) for c in launches], [(12, 4), (4, 1), (2, 1), (4, 4), (3, 1), (2, 1)])
        self.assertEqual(sorted(self.outcomes()), sorted(self.shas), 'one record per file: no gap, no duplicate')
        self.assertTrue(self.outcomes()[self.shas[9]].get('unfinished'), 'the file that never ended, run alone, is RED')

    def test_a_deadline_with_others_in_flight_is_judged_again_alone(self):
        self.scene.plan['files'] = {self.shas[2]: dict(timeout='audio')}
        self.assertEqual(self.scene.run(jobs=4, deadline=7), cr.EXIT_RED)
        report = json.loads((self.scene.report_dir() / 'report.json').read_text())
        self.assertEqual(report['failures'], {'audio:timeout': 1})
        self.assertEqual(report['engines']['probe'], {'OK': 12})
        self.assertEqual(report['engines']['audio'], {'OK': 11, 'timeout': 1})
        launches = launches_of(self.scene)
        self.assertEqual({c['deadlineSeconds'] for c in launches}, {7}, 'each file has the same deadline of its own')
        self.assertEqual(launches[1]['jobs'], 1, 'the cut file and the three beside it are run again one at a time')

    def test_every_file_crashing_in_parallel_still_ends(self):
        self.scene.plan['files'] = {sha: dict(crash='probe') for sha in self.shas}
        self.assertEqual(self.scene.run(jobs=4), cr.EXIT_RED)
        report = json.loads((self.scene.report_dir() / 'report.json').read_text())
        self.assertEqual(report['engines']['probe'], {'crash': 12})
        self.assertEqual(report['launches'], 3 + 12, 'three groups, then each file alone: bounded, never a loop')

    def test_the_verbs_lane_stays_one_batch(self):
        scene = self.scene
        scene.plan['engines'] = list(cr.LANES['verbs'][1])
        scene.run('verbs', jobs=4)
        self.assertEqual({c['jobs'] for c in launches_of(scene)}, {1}, 'the verbs act on the sample together: never split')

    def test_the_proof_lane_takes_as_many_at_a_time_as_the_disk_holds_copies_for(self):
        GB = 1 << 30
        # 100 GB disk, 30 GB free: the run may use 25 GB (it stops short of 95% used).
        self.assertEqual(cr.proof_width(30 * GB, 100 * GB, [6 * GB, 10 * GB, 2 * GB, 8 * GB], 4), 3, '10+8+6 fit; +2 does not')
        self.assertEqual(cr.proof_width(30 * GB, 100 * GB, [1 * GB] * 9, 8), 8)
        self.assertEqual(cr.proof_width(30 * GB, 100 * GB, [20 * GB, 20 * GB], 1), 1)
        with self.assertRaises(cr.Refused):
            cr.proof_width(30 * GB, 100 * GB, [26 * GB], 4)
        scene = LaneScene(pathlib.Path(self.tmp.name, 'proof').as_posix(), with_proof_engine=True)
        scene.plan['engines'] = ['balance', 'proof']
        scene.plan['files'] = {sha_of(0): dict(balance='balanced', proof='same_content')}
        self.assertEqual(scene.run('proof', jobs=4), cr.EXIT_GREEN)
        self.assertEqual([c['jobs'] for c in launches_of(scene)], [1], 'one one-sided file: one at a time')

    def test_settle_in_a_launch_of_n_convicts_no_one_and_names_the_files_to_run_alone(self):
        events = [dict(ev='begin', sha='a'), dict(ev='begin', sha='b'), dict(ev='begin', sha='c'),
                  dict(ev='engine', sha='a', engine='probe', outcome='probed'), dict(ev='end', sha='a'),
                  dict(ev='engine', sha='b', engine='probe', outcome='timeout'), dict(ev='end', sha='b', cut=True)]
        results = {'a': {}, 'b': {}, 'c': {}}
        alone = set()
        settled, refusal = cr.settle(events, ['probe'], results, width=3, alone=alone)
        self.assertEqual((settled, refusal, alone), (1, None, {'b', 'c'}))
        self.assertEqual(results['a']['probe'], 'probed')
        self.assertFalse(results['b'].get('settled') or results['c'].get('settled'), 'not convicted in a launch of three')
        results = {'a': {}, 'b': {}, 'c': {}}
        self.assertEqual(cr.settle(events, ['probe'], results), (3, None), 'one at a time: convicted, as before')
        self.assertEqual((results['b']['probe'], results['c']['probe']), ('timeout', 'crash'))


class ReviewFixTests(unittest.TestCase):
    """Review of 327576126 (2026-11-20): a launch of N that died is counted and said, never absorbed; the proof
    lane's leftovers are swept before a relaunch and its width counts what the balancing engine needs."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.scene = ManyFileScene(self.tmp.name)
        self.shas = sorted(sha_of(n) for n, _, _, _ in ManyFileScene.FILES)

    def tearDown(self):
        self.tmp.cleanup()

    def report(self):
        return json.loads((self.scene.report_dir() / 'report.json').read_text())

    def test_a_launch_of_n_that_died_is_said_in_the_report_with_the_files_run_again_alone(self):
        self.scene.plan['engines'] = list(cr.LANES['check'][1])
        self.scene.plan['files'] = {self.shas[5]: dict(crash='check')}
        self.scene.run(jobs=4)
        report = self.report()
        self.assertEqual(report.get('launches_cut_short'), 1, 'one launch of four died with files in flight')
        self.assertEqual(report.get('run_again_alone'), 4, 'the four files it left unfinished were run again alone')
        summary = (self.scene.out / 'corpus-summary.txt').read_text()
        self.assertIn('1 launch of 4 cut short; 4 files run again alone (1 failed alone)', summary)
        self.assertIn('RED', summary.splitlines()[0], 'a file that crashes alone is still RED')

    def test_a_crash_only_files_in_flight_together_cause_is_amber_never_green(self):
        self.scene.plan['engines'] = list(cr.LANES['check'][1])
        self.scene.plan['files'] = {self.shas[5]: dict(crash='check', together_only=True)}
        self.assertEqual(self.scene.run(jobs=4), cr.EXIT_AMBER)
        report = self.report()
        self.assertEqual((report['launches_cut_short'], report['run_again_alone'], report['failures']), (1, 4, {}))
        summary = (self.scene.out / 'corpus-summary.txt').read_text()
        self.assertTrue(summary.startswith('corpus check: AMBER 12 files'), summary.splitlines()[0])
        self.assertIn('1 launch of 4 cut short; 4 files run again alone (none failed alone) — AMBER', summary)
        self.assertEqual(cr.clean_report(report)['launches_cut_short'], 1, 'status reads it back')
        self.assertEqual(self.scene.run(stamp='20261117_130000_2', jobs=1), cr.EXIT_GREEN, 'one at a time it never happens')
        self.assertEqual(json.loads((self.scene.report_dir(stamp='20261117_130000_2') / 'report.json').read_text())
                         ['launches_cut_short'], 0)

    def test_a_run_with_a_launch_cut_short_is_never_the_baseline_implicit_or_accepted(self):
        self.scene.plan['engines'] = list(cr.LANES['check'][1])
        self.scene.plan['files'] = {self.shas[5]: dict(crash='check', together_only=True)}
        self.assertEqual(self.scene.run(jobs=4), cr.EXIT_AMBER)
        with self.assertRaises(cr.Refused) as refused:
            cr.accept(self.scene.seal, 'check', 'x')
        self.assertIn('a launch of files in flight together was cut short', str(refused.exception))
        self.assertIsNone(cr.baseline_of(self.scene.seal, 'check')[0], 'never the implicit baseline either')
        self.assertEqual(self.scene.run(stamp='20261117_130000_2', jobs=1), cr.EXIT_GREEN)
        self.assertEqual(cr.baseline_of(self.scene.seal, 'check')[0].name, '20261117_130000_2', 'a clean run is')

    def test_what_a_dead_launch_left_in_the_work_folder_is_swept_before_the_next(self):
        self.scene.plan['litter'] = 'balanced-copy.partial'
        self.scene.plan['files'] = {self.shas[5]: dict(crash='check')}
        self.scene.run(jobs=4)
        listings = [c['work_files'] for c in self.scene.recorded_calls() if 'work_files' in c]
        self.assertGreater(len(listings), 1)
        for listing in listings:
            leftovers = [name for name in listing if name.startswith('balanced-copy')]
            self.assertEqual(leftovers, [], 'a launch began beside an earlier launch\'s partial copy')

    def test_the_sweep_takes_only_the_runs_own_loose_files(self):
        work = self.scene.seal.work_root / 'run-sweep'
        self.scene.seal.mkdir(work / 'tmp')
        for name in ('config-1.json', 'progress-1.jsonl', 'abc_balanced.mov', 'abc.partial'):
            (work / name).write_text('x')
        (work / 'linked').symlink_to(self.scene.corpus / cr.MARKER)
        twin = work / 'second-name'
        os.link(str(self.scene.corpus / cr.MARKER), str(twin))
        cr.sweep_work(self.scene.seal, work)
        self.assertEqual(sorted(p.name for p in work.iterdir()),
                         ['config-1.json', 'linked', 'progress-1.jsonl', 'second-name', 'tmp'])
        self.assertTrue((self.scene.corpus / cr.MARKER).exists(), 'a corpus document is never reached through a link or a second name')

    def test_the_verbs_batch_is_begun_on_one_clock_and_the_run_is_plainly_sendable(self):
        verbs = (SCRIPTS / 'corpus' / 'CorpusVerbsDriver.swift').read_text()
        self.assertIn('run.begin(stage.items)', verbs)
        self.assertNotIn('for item in stage.items { run.begin(item) }', verbs)
        support = (SCRIPTS / 'corpus' / 'CorpusDriverSupport.swift').read_text()
        self.assertIn('deadline.arm(shas: items.map(\\.sha), seconds: config.deadlineSeconds)', support)
        self.assertIn('final class CorpusRun: Sendable {', support, 'every member is Sendable: no @unchecked')

    def test_the_proof_width_counts_what_the_balancing_engine_needs_not_the_source_size(self):
        MB = 1 << 20
        self.assertEqual(cr.proof_need(100 * MB, 60.0), 100 * MB + 12_000_000 + 64 * MB)     # BalanceAudioFix.requiredFreeBytes
        self.assertEqual(cr.proof_need(100 * MB, -5.0), 100 * MB + 64 * MB)
        scene = LaneScene(pathlib.Path(self.tmp.name, 'proof').as_posix(), with_proof_engine=True)
        scene.plan['engines'] = ['balance', 'proof']
        real = cr.shutil.disk_usage
        floor = 100 * 10**9 * (1 - cr.TRANSIENT_CEILING)
        cr.shutil.disk_usage = lambda path: type('U', (), dict(total=100 * 10**9, used=0, free=int(floor) + 10 * MB))()
        try:
            self.assertEqual(scene.run('proof'), cr.EXIT_REFUSED, 'a 1,200-byte file still needs the 64 MB cushion')
        finally:
            cr.shutil.disk_usage = real
        self.assertIn('a run stops short of 95% used', (scene.out / 'corpus-summary.txt').read_text())


class ParallelScaleTests(unittest.TestCase):

    def test_settle_over_100k_interleaved_events_stays_inside_the_budget(self):
        engines = ['probe', 'check', 'audio', 'pair']
        shas = [f'{n:064x}' for n in range(20_000)]
        events = []
        for first in range(0, len(shas), 8):                 # eight in flight, lines interleaved engine by engine
            group = shas[first:first + 8]
            events += [dict(ev='begin', sha=s) for s in group]
            events += [dict(ev='engine', sha=s, engine=e, outcome='OK', kinds=[], s=0.1) for e in engines for s in group]
            events += [dict(ev='end', sha=s) for s in group]
        results = {s: {} for s in shas}
        t0 = time.monotonic()
        settled, _ = cr.settle(events, engines, results, width=8, alone=set())
        elapsed = time.monotonic() - t0
        self.assertEqual((len(events), settled), (120_000, 20_000))
        self.assertTrue(all(r['audio'] == 'OK' for r in results.values()))
        self.assertLess(elapsed, 5.0, f'{elapsed:.2f}s for 120k lines')


POOL_MAIN = r"""
import Foundation
struct Step: Decodable, Sendable { let sha: String; let seconds: Double }
struct Plan: Decodable { let width: Int; let deadline: Double; let progress: String; let items: [Step] }
final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    init(_ path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)!
    }
    func write(_ event: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        lock.lock(); defer { lock.unlock() }
        handle.write(data); handle.write(Data("\n".utf8))
    }
}
final class Gauge: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private(set) var peak = 0
    func enter() { lock.lock(); now += 1; peak = max(peak, now); lock.unlock() }
    func leave() { lock.lock(); now -= 1; lock.unlock() }
}
func main() async throws {
    let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    let lines = Lines(plan.progress), gauge = Gauge(), seconds = plan.deadline
    let deadline = CorpusDeadline(write: { lines.write($0) }, halt: { _exit(86) })
    let started = Date()
    // As CorpusRun.begin / engine / end do it, around the pool.
    await CorpusPool.each(plan.items, width: plan.width) { step in
        lines.write(["ev": "begin", "sha": step.sha])
        deadline.arm(sha: step.sha, seconds: seconds)
        gauge.enter()
        deadline.entering(sha: step.sha, "work")
        try? await Task.sleep(nanoseconds: UInt64(step.seconds * 1_000_000_000))
        lines.write(["ev": "engine", "sha": step.sha, "engine": "work", "outcome": "OK"])
        gauge.leave()
        deadline.disarm(sha: step.sha)
        lines.write(["ev": "end", "sha": step.sha])
    }
    print("\(gauge.peak) \(Date().timeIntervalSince(started))")
}
try await main()
"""


_POOL_BUILD = []


def pool_binary():
    """CorpusPool.swift (Foundation only) compiled in Swift 6 mode beside POOL_MAIN, once per test process."""
    if not _POOL_BUILD:
        build = tempfile.TemporaryDirectory()
        main = pathlib.Path(build.name, 'main.swift')
        main.write_text(POOL_MAIN)
        binary = pathlib.Path(build.name, 'pool')
        done = subprocess.run(['swiftc', '-swift-version', '6', '-o', str(binary), str(SCRIPTS / 'corpus' / 'CorpusPool.swift'),
                               str(main)], capture_output=True, text=True, timeout=600)
        if done.returncode != 0:
            raise AssertionError('CorpusPool.swift does not compile by itself in Swift 6 mode:\n' + done.stdout + done.stderr)
        _POOL_BUILD.extend([build, binary])
    return _POOL_BUILD[1]


POOL_REVIEW_MAIN = r"""
import Foundation
final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var n = 0
    func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
func cancelled(width: Int) async -> Int {
    let started = Box()
    let walk = Task {
        await CorpusPool.each(Array(0..<12), width: width) { _ in
            started.bump()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
    try? await Task.sleep(nanoseconds: 300_000_000)
    walk.cancel()
    await walk.value
    return started.count
}
func main() async {
    print("cancel1=\(await cancelled(width: 1)) cancel2=\(await cancelled(width: 2))")
    // One batch (the verbs lane's whole sample), armed on ONE clock even with a pause inside the call's caller.
    let cut = Box(), halted = Box()
    let deadline = CorpusDeadline(write: { if $0["cut"] != nil { cut.add($0["sha"] as? String ?? "?") } },
                                  halt: { halted.bump() })
    deadline.arm(shas: ["x", "y", "z"], seconds: 1.6)
    deadline.entering("purge")
    while halted.count == 0 { try? await Task.sleep(nanoseconds: 50_000_000) }
    print("batch=\(cut.all.sorted().joined(separator: ","))")
}
await main()
"""


@unittest.skipUnless(shutil.which('swiftc'), 'needs the Swift compiler')
class SwiftPoolReviewTests(unittest.TestCase):
    """Review of 327576126: the pool stops starting files once cancelled; a batch is armed on one clock."""

    def test_a_cancelled_walk_starts_no_more_files_and_a_batch_is_cut_whole(self):
        with tempfile.TemporaryDirectory() as tmp:
            main = pathlib.Path(tmp, 'main.swift')
            main.write_text(POOL_REVIEW_MAIN)
            binary = pathlib.Path(tmp, 'review')
            done = subprocess.run(['swiftc', '-swift-version', '6', '-o', str(binary), str(SCRIPTS / 'corpus' / 'CorpusPool.swift'),
                                   str(main)], capture_output=True, text=True, timeout=600)
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
            ran = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
        facts = dict(part.split('=') for part in ran.stdout.split())
        self.assertLessEqual(int(facts['cancel1']), 2, 'one at a time: no file begins after the cancel')
        self.assertLessEqual(int(facts['cancel2']), 4, 'two at a time: no file begins after the cancel')
        self.assertEqual(facts['batch'], 'x,y,z', 'the whole batch is cut by one tick, never part of it')


@unittest.skipUnless(shutil.which('swiftc'), 'needs the Swift compiler')
class SwiftPoolTests(unittest.TestCase):
    """The in-app pool and per-file deadline pinned by BEHAVIOUR: scripts/corpus/CorpusPool.swift compiled by
    itself and given files that take a known time."""

    @classmethod
    def setUpClass(cls):
        cls.binary = pool_binary()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()

    def pool(self, width, steps, deadline=60.0):
        progress = pathlib.Path(self.tmp.name, f'progress-{width}-{len(steps)}.jsonl')
        plan = pathlib.Path(self.tmp.name, 'plan.json')
        plan.write_text(json.dumps(dict(width=width, deadline=deadline, progress=str(progress),
                                        items=[dict(sha=s, seconds=t) for s, t in steps])))
        t0 = time.monotonic()
        done = subprocess.run([str(self.binary), str(plan)], capture_output=True, text=True, timeout=60)
        wall = time.monotonic() - t0
        events = [json.loads(line) for line in progress.read_text().splitlines()]
        return done, events, wall

    def test_one_at_a_time_is_the_given_order(self):
        steps = [(f'f{n}', 0.02) for n in range(6)]
        done, events, _ = self.pool(1, steps)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual([(e['ev'], e['sha']) for e in events],
                         [(w, s) for s, _ in steps for w in ('begin', 'engine', 'end')])
        self.assertEqual(done.stdout.split()[0], '1')

    def test_n_in_flight_never_more_and_every_file_exactly_once(self):
        steps = [(f'f{n:02d}', 0.3) for n in range(12)]
        done, events, wall = self.pool(4, steps)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.split()[0], '4', 'four in flight at the peak, never five')
        for sha, _ in steps:
            self.assertEqual([e['ev'] for e in events if e['sha'] == sha], ['begin', 'engine', 'end'], sha)
        self.assertLess(float(done.stdout.split()[1]), 12 * 0.3 / 2, 'twelve 0.3 s files four at a time took ~0.9 s, not 3.6 s')

    def test_a_width_below_one_is_one_at_a_time(self):
        done, events, _ = self.pool(0, [('a', 0.01), ('b', 0.01)])
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual([e['ev'] for e in events], ['begin', 'engine', 'end'] * 2)

    def test_the_deadline_is_each_files_own_not_the_launchs(self):
        # Six 0.9 s files two at a time: the launch takes ~2.7 s, past a 2 s deadline; no FILE is past it.
        done, events, _ = self.pool(2, [(f'f{n}', 0.9) for n in range(6)], deadline=2.0)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertNotIn('timeout', json.dumps(events))
        self.assertEqual(sum(1 for e in events if e['ev'] == 'end'), 6)

    def test_the_file_past_its_deadline_is_cut_alone_and_the_host_exits(self):
        done, events, wall = self.pool(3, [('slow', 8.0), ('a', 0.2), ('b', 0.2), ('c', 0.2)], deadline=1.5)
        self.assertEqual(done.returncode, 86)
        self.assertLess(wall, 5.0, 'cut at its deadline, not at the end of its 8 s')
        cut = [e for e in events if e.get('outcome') == 'timeout' or e.get('cut')]
        self.assertEqual(cut, [dict(ev='engine', sha='slow', engine='work', outcome='timeout', s=cut[0]['s']),
                               dict(ev='end', sha='slow', cut=True)])
        self.assertGreaterEqual(cut[0]['s'], 1.5)
        for sha in ('a', 'b', 'c'):
            self.assertEqual([e['ev'] for e in events if e['sha'] == sha], ['begin', 'engine', 'end'], 'the others ran clean')

    def test_two_files_past_their_deadlines_at_once_are_both_cut(self):
        done, events, _ = self.pool(2, [('x', 8.0), ('y', 8.0)], deadline=1.0)
        self.assertEqual(done.returncode, 86)
        self.assertEqual(sorted(e['sha'] for e in events if e.get('cut')), ['x', 'y'])


class ParallelDriverSourceTests(unittest.TestCase):
    """The drivers go through the pool; the pool is laid over the testbed with them."""

    def test_check_and_proof_walk_their_files_through_the_pool_and_verbs_stays_one_batch(self):
        for name in ('CorpusCheckDriver.swift', 'CorpusProofDriver.swift'):
            text = (SCRIPTS / 'corpus' / name).read_text()
            self.assertIn('await run.each', text, name)
            self.assertNotIn('for item in run.config.pending', text, name)
        self.assertIn('CorpusPool.swift', cr.ALL_DRIVERS)
        for lane, (_, _, _, sources) in cr.LANES.items():
            self.assertIn('CorpusPool.swift', sources, lane)
        support = (SCRIPTS / 'corpus' / 'CorpusDriverSupport.swift').read_text()
        self.assertIn('deadline.entering(sha: item.sha, name)', support, 'the deadline is told WHICH file is in which engine')


if __name__ == '__main__':
    unittest.main()
