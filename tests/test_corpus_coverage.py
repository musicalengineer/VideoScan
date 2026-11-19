"""scripts/corpus_coverage.py — `corpus_run.sh run coverage`: what of OUR code only the real corpus runs.

Pinned without the M4, real media, a real build or real LLVM tools:
  logic     LCOV is read into our sources' lines and functions only (not the test target,
            the corpus drivers, packages); suite / corpus / union / corpus-only / suite-only
            are counted right; the functions the suite never enters are ranked by size, and
            the ones the corpus takes further by the lines it adds;
  the run   ONE instrumented build; each lane launch and the suite collect coverage into a
            result bundle inside the run's work folder, read with xccov; the suite is the plan's own
            VideoScanTests with the corpus drivers skipped; the lanes still store their own
            runs; the work folder (bundles, views, LCOV) is gone afterwards; a side with no
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


def xccov(root, files):
    """The same spec as `lcov`, as xccov's two JSON views: (report, archive)."""
    report = {"targets": [{"name": "VideoScan.app", "files": [
        {"path": f"{root}/{rel}", "functions": [
            {"name": name, "lineNumber": start, "executionCount": count,
             "executableLines": sum(1 for n in lines if n >= start and not any(s > start and n >= s for s, _, _ in functions))}
            for start, name, count in functions]} for rel, (functions, lines) in files.items()]}]}
    archive = {f"{root}/{rel}": [{"line": n, "isExecutable": True, "executionCount": c} for n, c in sorted(lines.items())]
               + [{"line": 999, "isExecutable": False}] for rel, (functions, lines) in files.items()}
    return report, archive


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

    def test_xccov_views_read_exact_sizes_and_only_our_sources(self):
        files = {self.BALANCE: ([(1, 'Balance.f1()', 2), (6, 'closure #1 in Balance.f1()', 0)], {**span(1, 5, 2), **span(6, 7, 0)}),
                 'VideoScan/VideoScanTests/BalanceTests.swift': ([(1, 'T', 1)], span(1, 9, 1))}
        report, archive = xccov(self.ROOT, files)
        report['targets'][0]['files'][0]['functions'][0]['executableLines'] = 42        # xccov's own count wins
        cov = cc.Coverage()
        self.assertEqual(cov.read_xccov('check', report, archive, [self.ROOT]), 1)
        self.assertEqual(cov.lines[self.BALANCE], set(range(1, 8)))
        self.assertEqual(cov.hit_lines['check'][self.BALANCE], set(range(1, 6)))
        self.assertEqual(cov.hit_functions['check'], {(self.BALANCE, 1)})
        self.assertEqual(cov.sizes[(self.BALANCE, 1)], 42)
        result = cc.measure(cov, [], ['check'])
        self.assertEqual([(e['names'], e['size']) for e in result['unreached']], [(['Balance.f1()'], 42)])
        self.assertEqual(cov.read_xccov('x', {'targets': None}, ['not', 'a', 'dict'], [self.ROOT]), 0)

    def test_lines_after_a_nested_closure_go_back_to_the_enclosing_function(self):
        # Seen on the M4: a one-line closure at 128 inside checkFrameRate was credited "+4 of 1 lines".
        files = {self.BALANCE: ([(120, 'Rules.checkFrameRate(_:)', 1), (128, 'closure #1 in Rules.checkFrameRate(_:)', 1)],
                                {**span(120, 127, 1), 128: 1, **span(129, 132, 0), 140: 0})}
        report, archive = xccov(self.ROOT, files)
        sizes = {120: 12, 128: 1}                         # what xccov says: the outer owns 12 lines (120-127, 129-132), the closure 1
        for fn in report['targets'][0]['files'][0]['functions']:
            fn['executableLines'] = sizes[fn['lineNumber']]
        cov = cc.Coverage()
        cov.read_xccov('check', report, archive, [self.ROOT])
        owned = cov.owners(self.BALANCE)
        self.assertEqual(owned[128], {128})
        self.assertEqual(owned[120], set(range(120, 128)) | set(range(129, 133)))
        self.assertNotIn(140, owned[120] | owned[128], 'past both counts: no function owns it')

    def test_without_sizes_a_function_owns_up_to_the_next_start(self):
        cov = self.coverage()                              # LCOV only: no sizes
        owned = cov.owners(self.BALANCE)
        self.assertEqual((owned[1], owned[6]), (set(range(1, 6)), set(range(6, 11))))

    def test_core_unseen_by_the_corpus_is_said_and_the_app_headline_stands_apart(self):
        cov = cc.Coverage()
        r = self.ROOT
        cov.read_lcov('suite-app', lcov(r, {self.BALANCE: ([(1, '$s1f1', 1)], span(1, 4, 1))}).splitlines(True), [r])
        cov.read_lcov('suite-core', lcov(r, {self.MIXER: ([(1, '$s2f3', 1)], span(1, 6, 1))}).splitlines(True), [r])
        cov.read_lcov('check', lcov(r, {self.BALANCE: ([(1, '$s1f1', 1)], {**span(1, 2, 1), 3: 0, 4: 0})}).splitlines(True), [r])
        result = cc.measure(cov, cc.SUITE_SIDES, ['check'])
        self.assertFalse(result['core_seen'])
        self.assertEqual((result['app']['lines'], result['app']['corpus'], result['total']['lines']), (4, 2, 10))
        text = '\n'.join(cc.render(result, {}, 'a' * 40, [], 'note'))
        self.assertIn('app code alone (Core aside, 4 lines): suite 100.0% · corpus 50.0% · union 100.0%', text)
        self.assertIn('Core (6 lines) is counted for the suite', text)
        self.assertIn('NOT seen for the corpus', text)

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
        self.assertEqual(cc.demangle(['Balance.f1()'], xcrun='/nonexistent/xcrun'), {}, "xccov's names are already readable")


# The lane fake, plus: with -enableCodeCoverage a test run leaves its result bundle where it is told; the suite run
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
    '    os.makedirs(args[args.index("-resultBundlePath") + 1])\n'
    'if "VS_CORPUS_CONFIG" not in env:\n'
    '    with open(plan["calls"], "a") as f:\n'
    '        f.write(json.dumps({"suite_args": args, "suite_env": env, "suite_keys": sorted(run["TestConfigurations"][0]["TestTargets"][0])}) + "\\n")\n'
    '    sys.exit(plan.get("suite_rc", 0))\n'
    'config = json.load(open(env["VS_CORPUS_CONFIG"]))')
assert FAKE_COVERAGE_XCODEBUILD.count('-resultBundlePath') == 1 and 'enableCodeCoverage' in FAKE_COVERAGE_XCODEBUILD, \
    'the lane fake changed shape; this fake no longer extends it'

# xcrun: xccov prints a side's view (the bundle's folder names the side); llvm-profdata/llvm-cov for Core's LCOV; swift-demangle tags names.
FAKE_XCRUN = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
plan = json.load(open(os.environ["FAKE_PLAN"]))
with open(plan["calls"], "a") as f:
    f.write(json.dumps({"xcrun": args}) + "\n")
if args[0] == "xccov":
    bundle = args[-1]
    side = os.path.basename(os.path.dirname(bundle))
    path = os.path.join(plan["lcov"], side + "." + args[2].lstrip("-") + ".json")
    if not os.path.isdir(bundle) or not os.path.exists(path):
        sys.exit(1)
    sys.stdout.write(open(path).read())
elif args[0] == "llvm-profdata":
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
            'suite-app': {balance: ([(1, 'Balance.f1()', 4), (6, 'Balance.f2()', 0)], {**span(1, 5, 4), **span(6, 10, 0)})},
            'suite-core': {mixer: ([(1, '$s2f3', 0), (10, '$s2f4', 2)], {**span(1, 3, 0), **span(10, 12, 2)})},
            'check': {balance: ([(1, 'Balance.f1()', 0), (6, 'Balance.f2()', 3)], {**span(1, 5, 0), **span(6, 8, 3), 9: 0, 10: 0})},
            'proof': {mixer: ([(1, '$s2f3', 1)], span(1, 3, 1))},
            'verbs': {balance: ([(1, 'Balance.f1()', 1)], span(1, 5, 1))},
        }
        for side, spec in self.sides.items():
            if side == 'suite-core':
                (self.lcov_dir / 'suite-core.lcov').write_text(lcov(root, spec))
                continue
            report, archive = xccov(root, spec)
            (self.lcov_dir / f'{side}.report.json').write_text(json.dumps(report))
            (self.lcov_dir / f'{side}.archive.json').write_text(json.dumps(archive))

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
        self.assertIn('1. Balance.f2()  [MediaOps Balance.swift:6; 5 lines; check]', summary)
        self.assertIn('2. demangled $s2f3  [Core/Audio Mixer.swift:1; 3 lines; proof]', summary)
        report = self.scene.seal.reports / 'coverage' / ('a' * 40) / '20261118_150000_1'
        stored = json.loads((report / 'coverage.json').read_text())
        self.assertEqual(stored['total']['corpus_only'], 6)
        self.assertEqual(stored['unreached'][0]['name'], 'Balance.f2()')
        self.assertEqual((report / 'coverage.txt').read_text(), summary)

    def test_one_instrumented_build_and_every_test_host_profiled_inside_the_work_folder(self):
        self.scene.run_coverage()
        calls = self.scene.recorded_calls()
        builds = [c['args'] for c in calls if c.get('args', [''])[0] == 'build-for-testing']
        self.assertEqual(len(builds), 1, 'ONE instrumented build; the other lanes reuse it (corpus_run.BUILD_MARK)')
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
        self.assertIn(f'{work}/raw/suite-app/result-1.xcresult', [t[t.index('-resultBundlePath') + 1] for t in tests])
        for lane in ('check', 'proof', 'verbs'):
            self.assertIn(f'{work}/raw/{lane}/result-1.xcresult', [t[t.index('-resultBundlePath') + 1] for t in tests])
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
        views = [c['xcrun'] for c in calls if c.get('xcrun', [''])[0] == 'xccov']
        self.assertEqual(sorted({v[2] for v in views}), ['--archive', '--report'])
        self.assertEqual(len(views), 8, 'two views of each of four result bundles')
        exports = [c['xcrun'] for c in calls if c.get('xcrun', [''])[0] == 'llvm-cov']
        self.assertEqual(len(exports), 1, "only Core's own suite goes through llvm-cov")
        self.assertTrue(exports[0][-1].endswith('VideoScanCorePackageTests'))

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
        self.assertIn('check: no result bundle was written', summary)
        self.assertIn('check: no coverage from its test host — stopped before the rest', summary)
        calls = self.scene.recorded_calls()
        self.assertEqual(sorted({c['lane'] for c in calls if 'driver_env' in c}), ['check'], 'proof and verbs were not run for nothing')
        self.assertFalse(any('suite_args' in c or 'swift' in c for c in calls), 'neither suite was run for nothing')
        self.assertNotIn('%', summary.split('\n')[0])
        self.assertFalse((self.scene.seal.reports / 'coverage').exists())
        self.assertEqual(list(self.scene.seal.work_root.iterdir()), [])

    def test_a_view_xccov_cannot_give_is_not_measured_and_stops_at_once(self):
        (self.scene.lcov_dir / 'check.archive.json').unlink()
        self.assertEqual(self.scene.run_coverage(), cr.EXIT_RED)
        self.assertIn('check: xccov could not read a result bundle (archive)', self.scene.summary())
        self.assertFalse(any('suite_args' in c for c in self.scene.recorded_calls()))

    def test_a_suite_bundle_without_our_sources_is_not_measured(self):
        (self.scene.lcov_dir / 'suite-app.archive.json').write_text(json.dumps({'/elsewhere/Package/X.swift': []}))
        self.assertEqual(self.scene.run_coverage(), cr.EXIT_RED)
        self.assertIn('suite-app: its result bundles hold no coverage of our sources', self.scene.summary())

    def test_core_export_failing_is_said(self):
        (self.scene.lcov_dir / 'suite-core.lcov').unlink()
        self.assertEqual(self.scene.run_coverage(), cr.EXIT_GREEN)
        self.assertIn('suite-core: llvm-cov could not export', self.scene.summary())

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
