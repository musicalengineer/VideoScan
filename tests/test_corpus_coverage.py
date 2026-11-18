"""scripts/corpus_coverage.py — `corpus_run.sh run coverage`: what of OUR code only the real corpus runs.

Pinned without the M4, real media, a real build or real LLVM tools:
  logic     LCOV is read into our sources' lines and functions only (not the test target,
            the corpus drivers, packages); suite / corpus / union / corpus-only / suite-only
            are counted right; the functions the suite never enters are ranked by size, and
            the ones the corpus takes further by the lines it adds;
  the run   ONE instrumented build; each lane's test host and the suite's get an
            LLVM_PROFILE_FILE inside the run's work folder; the suite is the plan's own
            VideoScanTests with the corpus drivers skipped; the lanes still store their own
            runs; the work folder (raw profiles, LCOV) is gone afterwards; a side with no
            profile is RED "not measured", never a number; Core's suite failing is said;
  privacy   nothing a caller reads back names a corpus file or path;
  scale     a 100k-line LCOV is read and compared inside a time budget;
  caller    `corpus_run.sh run coverage` ships corpus_coverage.py to the M4 and nowhere else.
"""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS = REPO / 'scripts'
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(REPO / 'tests'))
import corpus_coverage as cc  # noqa: E402
import corpus_run as cr  # noqa: E402
import testbed_host as th  # noqa: E402
from test_corpus_run import FAKE_XCODEBUILD, SECRET_NAMES, LaneScene  # noqa: E402

APP = 'VideoScan/VideoScan/'
CORE = 'VideoScan/VideoScanCore/Sources/VideoScanCore/'


def lcov(root, files):
    """files: {rel: ([(start, name, count)], {line: count})} -> LCOV text as llvm-cov writes it."""
    out = []
    for rel, (functions, lines) in files.items():
        out.append(f'SF:{root}/{rel}')
        for start, name, _ in functions:
            out.append(f'FN:{start},{name}')
        for _, name, count in functions:
            out.append(f'FNDA:{count},{name}')
        for number, count in sorted(lines.items()):
            out.append(f'DA:{number},{count}')
        out.append('end_of_record')
    return '\n'.join(out) + '\n'


def span(a, b, count):
    return {n: count for n in range(a, b + 1)}


class ReadAndMeasureTests(unittest.TestCase):
    ROOT = '/Users/x/m4run/work'
    BALANCE = APP + 'MediaOps/Balance.swift'
    MIXER = CORE + 'Audio/Mixer.swift'

    def coverage(self):
        cov = cc.Coverage()
        r = self.ROOT
        sides = {
            # the suite enters f1 only; f2 (lines 6-10) never
            'suite-app': {self.BALANCE: ([(1, '$s1f1', 4), (6, '$s1f2', 0)], {**span(1, 5, 4), **span(6, 10, 0)}),
                          'VideoScan/VideoScanTests/BalanceTests.swift': ([(1, '$sT', 1)], span(1, 50, 1)),
                          'VideoScan/VideoScanTests/CorpusHarnessOverlay/CorpusCheckDriver.swift': ([(1, '$sD', 1)], span(1, 9, 1))},
            'suite-core': {self.MIXER: ([(1, '$s2f3', 0), (10, '$s2f4', 2)], {**span(1, 3, 0), **span(10, 12, 2)})},
            # the corpus: f2 lines 6-8, and f3 (Core, never run by Core's own suite)
            'check': {self.BALANCE: ([(1, '$s1f1', 1), (6, '$s1f2', 3)], {**span(1, 2, 1), 3: 0, 4: 0, 5: 0, **span(6, 8, 3), 9: 0, 10: 0})},
            'proof': {self.MIXER: ([(1, '$s2f3', 1), (10, '$s2f4', 0)], {**span(1, 3, 1), **span(10, 12, 0)})},
            'verbs': {self.BALANCE: ([(1, '$s1f1', 1)], span(1, 5, 1))},
        }
        for side, files in sides.items():
            text = lcov(r, files) + 'SF:/Users/x/Library/Developer/GRDB/Database.swift\nDA:1,5\nend_of_record\n'
            cov.read_lcov(side, text.splitlines(True), [r])
        return cov

    def test_only_our_sources_are_read(self):
        cov = self.coverage()
        self.assertEqual(sorted(cov.lines), sorted([self.BALANCE, self.MIXER]))
        self.assertEqual(cc.area_of(self.BALANCE), 'MediaOps')
        self.assertEqual(cc.area_of(self.MIXER), 'Core/Audio')
        self.assertEqual(cc.area_of(APP + 'ContentView.swift'), '(app root)')

    def test_suite_corpus_union_and_both_differences(self):
        result = cc.measure(self.coverage(), cc.SUITE_SIDES, cc.SUBLANES)
        t = result['total']
        self.assertEqual(t['lines'], 16)                         # 10 + 6
        self.assertEqual(t['suite'], 5 + 3)                      # Balance 1-5, Mixer 10-12
        self.assertEqual(t['corpus'], 5 + 3 + 3)                 # Balance 1-5 (verbs), 6-8, Mixer 1-3
        self.assertEqual(t['union'], 14)
        self.assertEqual(t['corpus_only'], 6)                    # Balance 6-8, Mixer 1-3
        self.assertEqual(t['suite_only'], 3)                     # Mixer 10-12
        self.assertEqual((t['functions'], t['f_suite'], t['f_corpus'], t['f_corpus_only']), (4, 2, 3, 2))
        self.assertEqual(t['union_pct'], 87.5)
        self.assertEqual(result['areas']['Core/Audio']['corpus_only'], 3)
        self.assertEqual(result['lanes']['check']['corpus_only'], 3)
        self.assertEqual(result['lanes']['verbs']['corpus_only'], 0)

    def test_functions_the_suite_never_enters_are_ranked_by_size(self):
        result = cc.measure(self.coverage(), cc.SUITE_SIDES, cc.SUBLANES)
        ranked = [(e['names'], e['size'], e['new_lines'], e['lanes']) for e in result['unreached']]
        self.assertEqual(ranked, [(['$s1f2'], 5, 3, ['check']), (['$s2f3'], 3, 3, ['proof'])])
        self.assertEqual(result['further'], [], 'f1 is entered by both and the corpus adds no line to it')

    def test_a_function_both_enter_where_the_corpus_reaches_further_is_listed(self):
        cov = cc.Coverage()
        cov.read_lcov('suite-app', lcov(self.ROOT, {self.BALANCE: ([(1, '$s1f1', 1)], {**span(1, 3, 1), **span(4, 9, 0)})}).splitlines(True), [self.ROOT])
        cov.read_lcov('check', lcov(self.ROOT, {self.BALANCE: ([(1, '$s1f1', 1)], {1: 1, **span(4, 7, 1)})}).splitlines(True), [self.ROOT])
        result = cc.measure(cov, ['suite-app'], ['check'])
        self.assertEqual([(e['names'], e['new_lines'], e['size']) for e in result['further']], [(['$s1f1'], 4, 9)])

    def test_lcov_with_end_lines_and_private_names(self):
        cov = cc.Coverage()
        text = (f'SF:{self.ROOT}/{self.BALANCE}\nFN:3,9,Balance.swift:$s1pv\nFNDA:2,Balance.swift:$s1pv\n'
                'DA:3,2\nDA:4,0\nDA:x,1\nend_of_record\n')
        self.assertEqual(cov.read_lcov('check', text.splitlines(True), [self.ROOT]), 1)
        self.assertEqual(cov.hit_functions['check'], {(self.BALANCE, 3)})
        self.assertEqual(cov.lines[self.BALANCE], {3, 4})

    def test_scale_100k_lines_inside_a_budget(self):
        files = {f'{APP}Area{n % 20}/File{n}.swift': ([(1, f'$s{n}a', 1), (250, f'$s{n}b', 0)], {**span(1, 249, 1), **span(250, 500, 0)})
                 for n in range(200)}                             # 100,000 executable lines, 400 functions
        corpus = {rel: ([(1, fn[0][1], 1), (250, fn[1][1], 1)], span(1, 500, 1)) for rel, fn in
                  ((r, f[0]) for r, f in files.items())}
        t0 = time.monotonic()
        cov = cc.Coverage()
        cov.read_lcov('suite-app', lcov(self.ROOT, files).splitlines(True), [self.ROOT])
        cov.read_lcov('check', lcov(self.ROOT, corpus).splitlines(True), [self.ROOT])
        result = cc.measure(cov, ['suite-app'], ['check'])
        elapsed = time.monotonic() - t0
        self.assertEqual(result['total']['lines'], 100_000)
        self.assertEqual(result['total']['corpus_only'], 200 * 251)
        self.assertEqual(len(result['unreached']), 200)
        self.assertLess(elapsed, 10.0, f'{elapsed:.1f}s for 100k lines')

    def test_demangle_falls_back_to_the_mangled_name(self):
        names = cc.demangle(['File.swift:$s9VideoScan3fooyyF', '$s9VideoScan3baryyF'], xcrun='/nonexistent/xcrun')
        self.assertEqual(names['File.swift:$s9VideoScan3fooyyF'], '$s9VideoScan3fooyyF')


# The lane fake, plus: with -enableCodeCoverage a test run leaves its profiles under <dd>/Build/ProfileData as xcodebuild does; the suite run
# (no VS_CORPUS_CONFIG) is recorded and ends; an instrumented build leaves the app's images.
FAKE_COVERAGE_XCODEBUILD = FAKE_XCODEBUILD.replace(
    '    sys.exit(0)\nrun = plistlib.load',
    '    if "-enableCodeCoverage" in args:\n'
    '        c = dd + "/Build/Products/Debug/VideoScan.app/Contents"\n'
    '        os.makedirs(c + "/MacOS", exist_ok=True); open(c + "/MacOS/VideoScan.debug.dylib", "w").write("image")\n'
    '        fw = c + "/Frameworks/VideoScanCore_-1_PackageProduct.framework"\n'
    '        os.makedirs(fw, exist_ok=True); open(fw + "/VideoScanCore_-1_PackageProduct", "w").write("image")\n'
    '    sys.exit(0)\nrun = plistlib.load').replace(
    'config = json.load(open(env["VS_CORPUS_CONFIG"]))',
    'if "-enableCodeCoverage" in args and not plan.get("no_profiles"):\n'
    '    prof = os.path.join(os.path.dirname(os.path.dirname(args[args.index("-xctestrun") + 1])), "ProfileData", "DEV")\n'
    '    os.makedirs(prof, exist_ok=True)\n'
    '    open(os.path.join(prof, "UUID-%d.profraw" % os.getpid()), "w").write("raw")\n'
    '    open(os.path.join(prof, "Coverage.profdata"), "w").write("merged")\n'
    'if "VS_CORPUS_CONFIG" not in env:\n'
    '    with open(plan["calls"], "a") as f:\n'
    '        f.write(json.dumps({"suite_args": args, "suite_env": env, "suite_keys": sorted(run["TestConfigurations"][0]["TestTargets"][0])}) + "\\n")\n'
    '    sys.exit(plan.get("suite_rc", 0))\n'
    'config = json.load(open(env["VS_CORPUS_CONFIG"]))')
assert FAKE_COVERAGE_XCODEBUILD.count('ProfileData') == 1 and 'enableCodeCoverage' in FAKE_COVERAGE_XCODEBUILD, \
    'the lane fake changed shape; this fake no longer extends it'

# xcrun: llvm-profdata merges (the output names the side), llvm-cov prints that side's LCOV, swift-demangle tags names.
FAKE_XCRUN = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
plan = json.load(open(os.environ["FAKE_PLAN"]))
with open(plan["calls"], "a") as f:
    f.write(json.dumps({"xcrun": args}) + "\n")
if args[0] == "llvm-profdata":
    open(args[args.index("-o") + 1], "w").write("merged")
elif args[0] == "llvm-cov":
    side = os.path.basename([a for a in args if a.startswith("-instr-profile=")][0]).split(".")[0]
    path = os.path.join(plan["lcov"], side + ".lcov")
    if not os.path.exists(path):
        sys.exit(1)
    sys.stdout.write(open(path).read())
elif args[0] == "swift-demangle":
    for line in sys.stdin:
        print("demangled " + line.strip())
'''

FAKE_SWIFT = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
plan = json.load(open(os.environ["FAKE_PLAN"]))
with open(plan["calls"], "a") as f:
    f.write(json.dumps({"swift": args}) + "\n")
scratch = args[args.index("--scratch-path") + 1]
os.makedirs(scratch + "/debug/codecov", exist_ok=True)
os.makedirs(scratch + "/debug/VideoScanCorePackageTests.xctest/Contents/MacOS", exist_ok=True)
open(scratch + "/debug/VideoScanCorePackageTests.xctest/Contents/MacOS/VideoScanCorePackageTests", "w").write("bin")
open(scratch + "/debug/codecov/suite-core.profraw", "w").write("raw")
sys.exit(plan.get("core_rc", 0))
'''


class CoverageScene(LaneScene):

    def __init__(self, tmp):
        super().__init__(tmp, with_proof_engine=True)
        base = pathlib.Path(tmp)
        self.fake.write_text(FAKE_COVERAGE_XCODEBUILD)
        self.xcrun, self.swift, self.lcov_dir = base / 'fake-xcrun', base / 'fake-swift', base / 'lcov'
        for path, text in ((self.xcrun, FAKE_XCRUN), (self.swift, FAKE_SWIFT)):
            path.write_text(text)
            path.chmod(0o755)
        self.lcov_dir.mkdir()
        self.plan['lcov'] = str(self.lcov_dir)
        self.plan['engines'] = ['probe']
        root = str(self.worktree)
        balance, mixer = APP + 'MediaOps/Balance.swift', CORE + 'Audio/Mixer.swift'
        self.sides = {
            'suite-app': lcov(root, {balance: ([(1, '$s1f1', 4), (6, '$s1f2', 0)], {**span(1, 5, 4), **span(6, 10, 0)})}),
            'suite-core': lcov(root, {mixer: ([(1, '$s2f3', 0), (10, '$s2f4', 2)], {**span(1, 3, 0), **span(10, 12, 2)})}),
            'check': lcov(root, {balance: ([(6, '$s1f2', 3)], span(6, 8, 3))}),
            'proof': lcov(root, {mixer: ([(1, '$s2f3', 1)], span(1, 3, 1))}),
            'verbs': lcov(root, {balance: ([(1, '$s1f1', 1)], span(1, 5, 1))}),
        }
        for side, text in self.sides.items():
            (self.lcov_dir / f'{side}.lcov').write_text(text)

    def run_coverage(self, **extra):
        self.plan_path.write_text(json.dumps(self.plan))
        os.environ['FAKE_PLAN'] = str(self.plan_path)
        os.environ['FAKE_CP_CALLS'] = str(self.cp_calls)
        argv = ['host', 'coverage', '--sha', 'a' * 40, '--stamp', '20261118_150000_1', '--out', str(self.out),
                '--worktree', str(self.worktree), '--derived-data', str(self.dd), '--bin', str(SCRIPTS / 'corpus')]
        for key, value in extra.items():
            argv += ['--' + key, str(value)]
        try:
            return cr.main(argv, seal=self.seal, xcodebuild=str(self.fake), cp=str(self.fake_cp),
                           xcrun=str(self.xcrun), swift=str(self.swift))
        finally:
            os.environ.pop('FAKE_PLAN', None)
            os.environ.pop('FAKE_CP_CALLS', None)

    def summary(self):
        return (self.out / 'corpus-summary.txt').read_text()


class CoverageRunTests(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.scene = CoverageScene(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_measured_the_numbers_and_the_ranked_functions(self):
        self.assertEqual(self.scene.run_coverage(), cr.EXIT_GREEN)
        summary = self.scene.summary()
        self.assertIn('corpus coverage: MEASURED at aaaaaaaaa', summary)
        self.assertRegex(summary, r'union +lines 87\.5%')
        self.assertIn('+6 lines, +2 functions only the corpus runs', summary)
        self.assertIn('the suite alone runs 3 lines the corpus never reaches', summary)
        self.assertIn('1. demangled $s1f2  [MediaOps Balance.swift:6; 5 lines; check]', summary)
        self.assertIn('2. demangled $s2f3  [Core/Audio Mixer.swift:1; 3 lines; proof]', summary)
        report = self.scene.seal.reports / 'coverage' / ('a' * 40) / '20261118_150000_1'
        stored = json.loads((report / 'coverage.json').read_text())
        self.assertEqual(stored['total']['corpus_only'], 6)
        self.assertEqual(stored['unreached'][0]['name'], 'demangled $s1f2')
        self.assertEqual((report / 'coverage.txt').read_text(), summary)

    def test_one_instrumented_build_and_every_test_host_profiled_inside_the_work_folder(self):
        self.scene.run_coverage()
        calls = self.scene.recorded_calls()
        builds = [c['args'] for c in calls if c.get('args', [''])[0] == 'build-for-testing']
        self.assertEqual(len(builds), 3, 'each lane builds (incrementally) into the same DerivedData')
        for args in builds:
            self.assertIn('-enableCodeCoverage', args)
            self.assertEqual(args[args.index('-derivedDataPath') + 1], str(self.scene.dd) + '-coverage',
                             "never the lanes' own DerivedData: an instrumented build would cost them a rebuild")
        work = str(self.scene.seal.work_root / '20261118_150000_1-coverage')
        lanes = [c for c in calls if 'driver_env' in c]
        self.assertEqual(sorted({c['lane'] for c in lanes}), ['check', 'proof', 'verbs'])
        tests = [c['args'] for c in calls if c.get('args', [''])[0] == 'test-without-building']
        self.assertEqual(len(tests), 4, 'three lanes and the suite')
        for args in tests:
            self.assertIn('-enableCodeCoverage', args)
            bundle = args[args.index('-resultBundlePath') + 1]
            self.assertTrue(bundle.startswith(str(self.scene.seal.work_root) + '/'), 'result bundles go with the work folders')
        self.assertTrue(any(a == f'{work}/suite-app.xcresult' for t in tests for a in t))
        profile_data = self.scene.dd.parent / (self.scene.dd.name + '-coverage') / 'Build' / 'ProfileData'
        self.assertEqual([p for p in profile_data.rglob('*') if p.is_file()], [], 'every profile was moved out of the cache')
        suite = [c for c in calls if 'suite_args' in c]
        self.assertEqual(len(suite), 1)
        args, env = suite[0]['suite_args'], suite[0]['suite_env']
        self.assertNotIn('VS_CORPUS_CONFIG', env)
        self.assertNotIn('HOME', env, 'the suite runs in the plan environment, not the sealed corpus home')
        self.assertIn('SkipTestIdentifiers', suite[0]['suite_keys'], "the plan's own test lists stay")
        self.assertIn('-only-testing:VideoScanTests', args)
        for driver in cc.DRIVER_CLASSES:
            self.assertIn(f'-skip-testing:VideoScanTests/{driver}', args)
        core = [c['swift'] for c in calls if 'swift' in c]
        self.assertEqual(core[0][:2], ['test', '--package-path'])
        self.assertIn('--enable-code-coverage', core[0])
        exports = [c['xcrun'] for c in calls if c.get('xcrun', [''])[0] == 'llvm-cov']
        self.assertEqual(len(exports), 5)
        app_export = [a for a in exports if 'suite-app.profdata' in ' '.join(a)][0]
        self.assertTrue(app_export[4].endswith('VideoScan.debug.dylib'), app_export)
        self.assertEqual(app_export[5], '-object')
        self.assertTrue(app_export[6].endswith('VideoScanCore_-1_PackageProduct'), app_export)
        self.assertFalse(any('VideoScanTests' in a for a in app_export), 'the test bundle is not our code to count')

    def test_the_lanes_store_their_own_runs_and_the_work_folder_goes(self):
        self.scene.run_coverage()
        for lane in ('check', 'proof', 'verbs'):
            self.assertTrue((self.scene.seal.reports / lane / ('a' * 40) / '20261118_150000_1' / 'report.json').is_file(), lane)
            self.assertTrue((self.scene.out / f'corpus-{lane}' / 'corpus-summary.txt').is_file(), lane)
        self.assertEqual(list(self.scene.seal.work_root.iterdir()), [], 'raw profiles or LCOV were left behind')
        self.assertFalse((self.scene.worktree / cr.OVERLAY_DIR).exists())
        self.assertIn('corpus check: GREEN', self.scene.summary())

    def test_a_side_with_no_profile_is_not_measured(self):
        self.scene.plan['no_profiles'] = True
        self.assertEqual(self.scene.run_coverage(), cr.EXIT_RED)
        summary = self.scene.summary()
        self.assertIn('corpus coverage: RED not measured', summary)
        self.assertIn('check: its test host wrote no profile — stopped before the rest', summary)
        calls = self.scene.recorded_calls()
        self.assertEqual(sorted({c['lane'] for c in calls if 'driver_env' in c}), ['check'], 'proof and verbs were not run for nothing')
        self.assertFalse(any('suite_args' in c or 'swift' in c for c in calls), 'neither suite was run for nothing')
        self.assertNotIn('%', summary.split('\n')[0])
        self.assertFalse((self.scene.seal.reports / 'coverage').exists())
        self.assertEqual(list(self.scene.seal.work_root.iterdir()), [])

    def test_an_export_that_fails_is_not_measured(self):
        (self.scene.lcov_dir / 'check.lcov').unlink()
        self.assertEqual(self.scene.run_coverage(), cr.EXIT_RED)
        self.assertIn('check: llvm-cov could not export', self.scene.summary())

    def test_failing_suites_still_measure_and_say_so(self):
        self.scene.plan.update(suite_rc=65, core_rc=1)
        self.assertEqual(self.scene.run_coverage(), cr.EXIT_GREEN)
        self.assertIn('app tests exit 65 (some failed; coverage still read); Core tests exit 1', self.scene.summary())

    def test_cores_suite_missing_is_said_not_hidden(self):
        (self.scene.lcov_dir / 'suite-core.lcov').unlink()
        self.assertEqual(self.scene.run_coverage(), cr.EXIT_GREEN)
        self.assertIn("Core's own suite NOT counted", self.scene.summary())

    def test_nothing_a_caller_reads_back_names_a_corpus_file_or_path(self):
        self.scene.run_coverage()
        texts = [self.scene.summary()] + [p.read_text() for p in self.scene.seal.reports.rglob('coverage.*')]
        text = '\n'.join(texts)
        for name in SECRET_NAMES:
            self.assertNotIn(name, text, name)
            self.assertNotIn(name.replace(' ', '_'), text, name)
        self.assertNotIn(str(self.scene.corpus), text)
        self.assertNotIn(str(self.scene.worktree), text, 'our sources are named repo-relative')
        self.assertNotIn('/Volumes', text)

    def test_the_seal_still_holds(self):
        scene = self.scene
        scene.seal = cr.Seal(scene.home, 'RicksUltra')
        self.assertEqual(scene.run_coverage(), cr.EXIT_REFUSED)
        self.assertEqual(scene.recorded_calls(), [], 'nothing was built on a Mac that is not the M4')

    def test_profiles_are_moved_out_of_the_cache_fresh_ones_only_never_a_link(self):
        seal = self.scene.seal
        data = pathlib.Path(self.tmp.name) / 'dd-x' / 'Build' / 'ProfileData' / 'DEV'
        data.mkdir(parents=True)
        old, fresh, other = data / 'old.profraw', data / 'new.profraw', data / 'notes.txt'
        for path in (old, fresh, other):
            path.write_text('x')
        os.utime(old, (1, 1))
        outside = pathlib.Path(self.tmp.name) / 'elsewhere.profraw'
        outside.write_text('not ours')
        (data / 'link.profraw').symlink_to(outside)
        dest = seal.mkdir(seal.work_root / 'r-coverage' / 'raw' / 'check')
        self.assertEqual(cr.collect_profiles(seal, data.parent.parent.parent, time.time() - 60, dest, 'launch1'), 1)
        self.assertEqual([p.name for p in dest.iterdir()], ['launch1-DEV-new.profraw'])
        self.assertFalse(fresh.exists())
        self.assertTrue(old.exists() and other.exists() and outside.exists())

    def test_the_m4_cleanup_knows_a_dead_coverage_runs_work_folder(self):
        self.assertTrue(th.RUN_WORK.match('20261118_150000_1-coverage'))
        self.assertTrue(cr._RUN_WORK.fullmatch('20261118_150000_1-coverage'))
        self.assertFalse(th.CORPUS_OUT.match('corpus-coverage'))


class CoverageCallerTests(unittest.TestCase):

    def test_run_coverage_ships_the_module_and_is_m4_only(self):
        p = subprocess.run(['/bin/bash', str(SCRIPTS / 'corpus_run.sh'), 'run', 'coverage', '--ref', 'HEAD', '--dry-run'],
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertRegex(p.stdout, r'install .*corpus_coverage\.py -> ricksm4\.local:.*/m4run/bin/\d{8}_\d{6}_\d+/corpus_coverage\.py')
        self.assertIn('<string>coverage</string>', p.stdout)
        p = subprocess.run(['/bin/bash', str(SCRIPTS / 'm4_run.sh'), 'corpus', '--corpus-lane', 'coverage', '--host', 'ultra',
                            '--dry-run'], capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 2)
        self.assertIn('runs only on the M4', p.stderr)


if __name__ == '__main__':
    unittest.main()
