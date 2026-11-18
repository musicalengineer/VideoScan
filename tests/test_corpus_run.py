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
                        "target": target["BlueprintName"], "target_keys": sorted(target)}) + "\n")
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
    say(ev="end", sha=item["sha"])
say(ev="done")
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
        self.assertEqual(sorted(p.name for p in out.iterdir()), ['corpus-summary.txt'])
        self.assertIn('refused', (out / 'corpus-summary.txt').read_text())

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
        self.assertIn('static let allowedHosts: Set<String> = ["ricksm4"]', support)
        for guard in ('getpwuid(getuid())', cr.MARKER, 'TestEnvironment.isTestHost', 'isUnder(NSHomeDirectory(), state)',
                      'isUnder(appSupport, state)', 'masterArchiveJSON == nil', '.syncedCopy(', '_exit(86)'):
            self.assertIn(guard, support, guard)
        self.assertNotIn('kill(', support)

    def test_the_drivers_never_write_an_engines_sentence_or_a_name(self):
        for name in ('CorpusDriverSupport.swift', 'CorpusCheckDriver.swift', 'CorpusProofDriver.swift'):
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
        for family_text in ('transcripts', 'captions', 'people_tags', 'tombstones'):
            self.assertEqual(conn.execute(f'SELECT count(*) FROM {family_text}').fetchone()[0], 0, family_text)
        conn.close()
        self.assertIn('GREEN 3 rows for 3 manifest files', lines[0])
        self.assertTrue((self.scene.seal.state / LATCH).is_file())

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
        self.worktree, self.dd, self.out = base / 'testbed', base / 'dd', base / 'out'
        (self.worktree / 'VideoScan' / 'VideoScanTests').mkdir(parents=True)
        (self.worktree / 'VideoScan' / 'VideoScanTests' / 'Existing.swift').write_text('// a test\n')
        if with_proof_engine:
            (self.worktree / 'VideoScan' / 'VideoScan' / 'MediaOps').mkdir(parents=True)
            (self.worktree / 'VideoScan' / 'VideoScan' / 'MediaOps' / 'BalancedCopyProof.swift').write_text('// engine\n')
        env = dict(os.environ, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t', GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@t')
        for command in (['init', '-q'], ['add', '-A'], ['commit', '-q', '-m', 'testbed']):
            subprocess.run(['git', '-C', str(self.worktree), *command], check=True, env=env)
        self.out.mkdir()
        self.fake = base / 'fake-xcodebuild'
        self.fake.write_text(FAKE_XCODEBUILD)
        self.fake.chmod(0o755)
        self.plan_path, self.calls = base / 'plan.json', base / 'calls.jsonl'
        self.plan = dict(calls=str(self.calls), engines=['probe', 'check', 'audio'], files={})
        cr.prepare(self.seal)

    def run(self, lane='check', sha='a' * 40, stamp='20261117_120000_1', **extra):
        self.plan_path.write_text(json.dumps(self.plan))
        os.environ['FAKE_PLAN'] = str(self.plan_path)
        argv = ['host', lane, '--sha', sha, '--stamp', stamp, '--out', str(self.out), '--worktree', str(self.worktree),
                '--derived-data', str(self.dd), '--bin', str(SCRIPTS / 'corpus')]
        for key, value in extra.items():
            argv += ['--' + key, str(value)]
        try:
            return cr.main(argv, seal=self.seal, xcodebuild=str(self.fake))
        finally:
            os.environ.pop('FAKE_PLAN', None)

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
        self.assertEqual(outcomes[sha_of(1)]['outcome'], 'probe=OK check=Problem audio=not_checked')
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
        (first / 'report.json').write_text(json.dumps(dict(lane='check', failures={}, engine_present=True)))
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
        self.assertEqual(record['accepted_by'], 'Grandma_.._Birthday_1988.mov')
        self.assertEqual(cr.main(['accept', 'proof', '--by', 'x'], seal=self.scene.seal), cr.EXIT_REFUSED)
        self.assertEqual(cr.main(['accept', 'check'], seal=cr.Seal(self.scene.home, 'ricksultra')), cr.EXIT_REFUSED)

    def test_the_front_door_accepts_through_ssh_with_the_helper_on_stdin(self):
        p = subprocess.run(['/bin/bash', str(SCRIPTS / 'corpus_run.sh'), 'accept', 'proof', '--dry-run'],
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertRegex(p.stdout, r'^\+ ssh ricksm4\.local python3 - accept proof --by [A-Za-z0-9_.@-]+ < \S+/scripts/corpus_run\.py\n$')


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
        for name in ('corpus_run.py', 'catalog_db.py', 'CorpusDriverSupport.swift', 'CorpusCheckDriver.swift',
                     'CorpusProofDriver.swift', 'testbed_lock.py'):
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
                       GIT_COMMITTER_EMAIL='t@t')
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
                       GIT_COMMITTER_EMAIL='t@t')
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
