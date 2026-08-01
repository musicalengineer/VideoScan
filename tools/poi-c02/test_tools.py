import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


make_refset = load("make_refset")
sweep = load("threshold_sweep")


class MaterializerSafetyTests(unittest.TestCase):
    def manifest(self, root, digest):
        return {"schemaVersion": 2, "faithful": True, "name": "t",
                "sourceReferencePath": str(root), "keptFiles": ["a.jpg"],
                "fileHashes": {"a.jpg": digest}}

    def test_hash_mismatch_writes_nothing(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td); source = root / "source"; source.mkdir()
            (source / "a.jpg").write_bytes(b"actual")
            manifest = root / "m.json"
            manifest.write_text(json.dumps(self.manifest(source, "0" * 64)))
            target = root / "target"
            self.assertEqual(make_refset.main([str(manifest), str(target)]), 3)
            self.assertFalse(target.exists())
            self.assertEqual(list(root.glob(".target.staging-*")), [])

    def test_dirty_target_is_unchanged(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td); source = root / "source"; source.mkdir()
            src = source / "a.jpg"; src.write_bytes(b"actual")
            manifest = root / "m.json"
            manifest.write_text(json.dumps(self.manifest(source, make_refset.sha256_of(src))))
            target = root / "target"; target.mkdir()
            sentinel = target / "user.txt"; sentinel.write_bytes(b"keep")
            self.assertEqual(make_refset.main([str(manifest), str(target)]), 2)
            self.assertEqual(sentinel.read_bytes(), b"keep")
            self.assertEqual(sorted(p.name for p in target.iterdir()), ["user.txt"])


class SweepProvenanceTests(unittest.TestCase):
    def test_content_hashes_change_when_same_size_content_changes(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td); refs = root / "refs"; refs.mkdir()
            f = refs / "a.jpg"; f.write_bytes(b"AAAA")
            first = sweep.refs_fingerprint(refs)
            f.write_bytes(b"BBBB")
            self.assertNotEqual(first, sweep.refs_fingerprint(refs))

    def test_cache_requires_exact_full_provenance(self):
        with tempfile.TemporaryDirectory() as td:
            out = pathlib.Path(td) / "clip.json"
            base = {"appSha256": "a", "referencesFingerprint": "r",
                    "armFlags": ["--reference-calibration", "audited"],
                    "corpusFingerprint": "c", "frameStep": 10,
                    "baseThreshold": 0.4}
            out.write_text(json.dumps({"provenance": base, "result": {"hits": 1}}))
            self.assertEqual(sweep.run_clip(["app"], base, out, False), {"hits": 1})
            for key, value in [("appSha256", "b"), ("referencesFingerprint", "x"),
                               ("armFlags", []), ("corpusFingerprint", "z"),
                               ("frameStep", 11), ("baseThreshold", 0.41)]:
                changed = dict(base); changed[key] = value
                with mock.patch.object(sweep.subprocess, "run", side_effect=RuntimeError("rerun")):
                    with self.assertRaises(RuntimeError):
                        sweep.run_clip(["app"], changed, out, False)

    def test_explicit_legacy_gets_no_audited_flags(self):
        cmd = sweep.build_command(pathlib.Path("app"), pathlib.Path("v"), "refs",
                                  0.4, 10, ["--reference-calibration", "legacy"])
        self.assertIn("--threshold", cmd)
        self.assertNotIn("--calibration-threshold", cmd)
        with self.assertRaises(SystemExit):
            sweep.build_command(pathlib.Path("app"), pathlib.Path("v"), "refs", 0.4, 10,
                                ["--reference-calibration", "legacy", "--calibration-link", "0.3"])


if __name__ == "__main__":
    unittest.main()
