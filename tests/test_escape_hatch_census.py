"""scripts/escape_hatch_census.py — the holes in the Swift 6 proof, counted (stage 2).

Pins: comments and strings do not count (a `// Swift 6:` justification is not
a hatch); every kind is matched by its real spelling; counts are per target;
per-file deltas against the previous census; no swiftlint = RED, never a
silent 0; the state round-trips. Synthetic trees only.
"""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))
spec = importlib.util.spec_from_file_location("escape_hatch_census", REPO / "scripts/escape_hatch_census.py")
ehc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ehc)

SAMPLE = '''
// Swift 6: nonisolated(unsafe) because the buffer is written by disjoint chunks.
nonisolated(unsafe) var buffer = [Int]()
final class Box: @unchecked Sendable { let p: UnsafeMutablePointer<Int>; let q: UnsafeRawBufferPointer }
let s = "nonisolated(unsafe) in a string does not count, nor does @unchecked Sendable or try!"
func f() { MainActor.assumeIsolated { } ; _ = lock.withLockUnchecked { $0 } ; _ = unsafeBitCast(1, to: Int.self) }
let x = try! decode(); let y = z as! Int; let ok = !flag; let ne = a != b
/* a block comment with as! and try! inside */
'''


def tree(d: Path, files: dict) -> Path:
    for rel, text in files.items():
        p = d / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    return d


class Counting(unittest.TestCase):
    def test_every_kind_by_its_real_spelling_and_nothing_from_comments_or_strings(self):
        counts = ehc.count_file(SAMPLE)
        self.assertEqual(counts, {"nonisolated(unsafe)": 1, "@unchecked Sendable": 1, "assumeIsolated": 1,
                                  "unchecked-lock": 1, "Unsafe*Pointer": 2, "unsafeBitCast": 1, "try!": 1, "as!": 1})

    def test_per_target_totals_and_fixtures_and_checkouts_are_skipped(self):
        with tempfile.TemporaryDirectory() as d:
            d = tree(Path(d), {
                "VideoScan/VideoScan/A.swift": "let a = try! f()\n",
                "VideoScan/VideoScanTests/T.swift": "let b = x as! Int\nlet c = y as! Int\n",
                "VideoScan/VideoScanTests/Fixtures/F.swift": "let z = try! g()\n",
                "VideoScan/VideoScanCore/Sources/VideoScanCore/C.swift": "final class K: @unchecked Sendable {}\n",
                "VideoScan/VideoScanCore/.build/checkouts/GRDB.swift/G.swift": "let g = try! h()\n",
                "VideoScan/VideoScanCore/Tests/VideoScanCoreTests/CT.swift": "// nothing\n",
            })
            cur = ehc.census(d, swiftlint=None, with_force_unwrap=False)
        self.assertEqual(cur["total"], 4)
        self.assertEqual({k: v["total"] for k, v in cur["targets"].items()},
                         {"app": 1, "app tests": 2, "Core": 1, "Core tests": 0})
        self.assertEqual(cur["kinds"]["try!"], 1, ".build checkouts and Fixtures do not count")
        self.assertEqual(cur["targets"]["app tests"]["per_file"], {"VideoScan/VideoScanTests/T.swift": {"as!": 2}})
        self.assertEqual(cur["red"], [], "four targets with files, force-unwrap deliberately off")

    def test_a_target_with_no_files_is_red(self):
        with tempfile.TemporaryDirectory() as d:
            d = tree(Path(d), {"VideoScan/VideoScan/A.swift": "let a = 1\n"})
            cur = ehc.census(d, swiftlint=None, with_force_unwrap=False)
        self.assertEqual(len(cur["red"]), 3, cur["red"])

    def test_no_swiftlint_is_red_not_a_silent_zero(self):
        with tempfile.TemporaryDirectory() as d:
            d = tree(Path(d), {"VideoScan/VideoScan/A.swift": "let a = x!\n", "VideoScan/VideoScanTests/T.swift": "",
                               "VideoScan/VideoScanCore/Sources/S.swift": "", "VideoScan/VideoScanCore/Tests/T.swift": ""})
            cur = ehc.census(d, swiftlint="/nonexistent/swiftlint", with_force_unwrap=True)
        self.assertTrue(any("swiftlint not found" in r for r in cur["red"]), cur["red"])
        self.assertEqual(cur["kinds"]["force-unwrap"], 0)
        self.assertIn("RED", ehc.summary_line(cur))


class Deltas(unittest.TestCase):
    def _census(self, d: Path, text: str):
        tree(d, {"VideoScan/VideoScan/A.swift": text, "VideoScan/VideoScanTests/T.swift": "",
                 "VideoScan/VideoScanCore/Sources/S.swift": "", "VideoScan/VideoScanCore/Tests/T.swift": ""})
        return ehc.census(d, swiftlint=None, with_force_unwrap=False)

    def test_per_file_deltas_against_the_previous_census(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            prev = self._census(d, "let a = try! f()\nlet b = try! g()\n")
            cur = self._census(d, "let a = try! f()\nfinal class K: @unchecked Sendable {}\n")
        moved = ehc.deltas(prev, cur)
        self.assertEqual(moved, [("app", "VideoScan/VideoScan/A.swift", "@unchecked Sendable", 0, 1),
                                 ("app", "VideoScan/VideoScan/A.swift", "try!", 2, 1)])
        line = ehc.summary_line(cur, prev)
        self.assertIn("Δ +1/−1 vs", line)
        self.assertEqual(ehc.deltas(None, cur), [])
        self.assertIn("no previous census", ehc.summary_line(cur))

    def test_state_round_trips_through_the_cli(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            tree(d, {"VideoScan/VideoScan/A.swift": "let a = try! f()\n", "VideoScan/VideoScanTests/T.swift": "",
                     "VideoScan/VideoScanCore/Sources/S.swift": "", "VideoScan/VideoScanCore/Tests/T.swift": ""})
            state = d / "state/census.json"
            import contextlib, io
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = ehc.main(["--repo", str(d), "--state", str(state), "--no-force-unwrap"])
            self.assertEqual(rc, 1, "--no-force-unwrap is RED by design")
            saved = json.loads(state.read_text())
            self.assertEqual(saved["total"], 1)
            (d / "VideoScan/VideoScan/A.swift").write_text("let a = try! f()\nlet b = try! g()\n")
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                ehc.main(["--repo", str(d), "--state", str(state), "--no-force-unwrap", "--deltas"])
            out = buf.getvalue()
            self.assertIn("Δ +1/−0", out)
            self.assertIn("+ app: VideoScan/VideoScan/A.swift [try!] 1 → 2", out)


class RealTree(unittest.TestCase):
    def test_the_real_tree_has_four_targets_with_files(self):
        """A sensor on the layout the census assumes (app / app tests / Core / Core tests)."""
        for _, rel in ehc.TARGETS:
            self.assertTrue(any((REPO / rel).rglob("*.swift")), rel)


if __name__ == "__main__":
    unittest.main()
