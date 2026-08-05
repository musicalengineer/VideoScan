import importlib.util
import json
import sys
import unittest
from unittest import mock
import zipfile
from pathlib import Path
from tempfile import TemporaryDirectory


SCRIPT = Path(__file__).parents[1] / "tools/person-eval/build_synthetic_identity_corpus.py"
SPEC = importlib.util.spec_from_file_location("build_synthetic_identity_corpus", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class SyntheticIdentityCorpusTests(unittest.TestCase):
    def media(self, count=25):
        return [
            MODULE.IdentityMedia(
                identity=f"identity-{index:02d}",
                demographic_group="Caucasian",
                dataset_sex="female",
                dataset_age=25 if index % 2 == 0 else 50,
                references=(f"/refs/{index}/a.png", f"/refs/{index}/c.png"),
                query_image=f"/images/{index}/b.png",
                query_mp4=f"/media/{index}.mp4",
                query_mkv=f"/media/{index}.mkv",
            )
            for index in range(count)
        ]

    def test_default_shape_is_100_balanced_cases(self):
        cases = MODULE.build_cases(self.media())
        MODULE.validate_cases(cases, 25)
        self.assertEqual(len(cases), 100)
        self.assertEqual(sum(c["expectedTargetPresent"] for c in cases), 50)
        self.assertEqual({c["transport"] for c in cases}, {"avfoundation-mp4", "ffmpeg-mkv"})

    def test_each_semantic_pair_has_both_decoder_routes(self):
        cases = MODULE.build_cases(self.media())
        grouped = {}
        for case in cases:
            key = (case["referenceIdentity"], case["queryIdentity"], case["expectedTargetPresent"])
            grouped.setdefault(key, set()).add(case["transport"])
        self.assertEqual(len(grouped), 50)
        self.assertTrue(all(routes == {"avfoundation-mp4", "ffmpeg-mkv"} for routes in grouped.values()))

    def test_negative_pairs_never_share_identity(self):
        cases = MODULE.build_cases(self.media())
        negatives = [case for case in cases if not case["expectedTargetPresent"]]
        self.assertTrue(all(c["referenceIdentity"] != c["queryIdentity"] for c in negatives))

    def test_manifest_paths_are_portable_relative_paths(self):
        cases = MODULE.build_cases(self.media())
        # The synthetic builder emits corpus-relative paths in production;
        # build_cases must preserve them rather than resolving against a host.
        portable = [
            MODULE.IdentityMedia(
                identity="identity-a",
                demographic_group="Caucasian",
                dataset_sex="female",
                dataset_age=25,
                references=("identities/a/ref-1.png", "identities/a/ref-2.png"),
                query_image="identities/a/query.png",
                query_mp4="media/a.mp4",
                query_mkv="media/a.mkv",
            ),
            MODULE.IdentityMedia(
                identity="identity-b",
                demographic_group="Caucasian",
                dataset_sex="female",
                dataset_age=50,
                references=("identities/b/ref-1.png", "identities/b/ref-2.png"),
                query_image="identities/b/query.png",
                query_mp4="media/b.mp4",
                query_mkv="media/b.mkv",
            ),
        ]
        emitted = MODULE.build_cases(portable)
        self.assertTrue(all(not Path(c["video"]).is_absolute() for c in emitted))
        self.assertTrue(all(not Path(p).is_absolute() for c in emitted for p in c["references"]))

    def test_filter_uses_publisher_metadata_without_ancestry_inference(self):
        entries = [
            MODULE.ZipEntry(
                f"ControlFace10k/Caucasian/female/25/identity-a/r2_g0_a25_o{o}_x.png",
                8, 0, 1, 1, o,
            )
            for o in (3, 4, 5)
        ] + [
            MODULE.ZipEntry(
                f"ControlFace10k/Caucasian/male/25/identity-b/r2_g1_a25_o{o}_x.png",
                8, 0, 1, 1, o,
            )
            for o in (3, 4, 5)
        ]
        groups = MODULE.grouped_identities(entries, "Caucasian", "female", {25, 50})
        self.assertEqual(set(groups), {"identity-a"})

    def test_parse_real_zip_central_directory_layout(self):
        with TemporaryDirectory() as temp:
            archive = Path(temp) / "small.zip"
            with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zf:
                zf.writestr("a/one.png", b"one")
                zf.writestr("b/two.png", b"two")
            data = archive.read_bytes()
            end = data.rfind(b"PK\x05\x06")
            eocd = __import__("struct").unpack_from("<4s4H2LH", data, end)
            entries = MODULE.parse_central_directory(data[eocd[6] : eocd[6] + eocd[5]])
            self.assertEqual([entry.name for entry in entries], ["a/one.png", "b/two.png"])

    def test_range_reader_rejects_server_that_ignores_range(self):
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = b"012345"  # requested five bytes, got six
        with mock.patch.object(MODULE.urllib.request, "urlopen", return_value=response):
            with self.assertRaisesRegex(RuntimeError, "HTTP range mismatch"):
                MODULE._range("https://example.invalid/archive.zip", 0, 4)

    def test_calibration_layout_is_portable_and_balanced(self):
        with TemporaryDirectory() as temp:
            root = Path(temp)
            media = self.media(count=2)
            MODULE.materialize_calibration_layout(root, media)
            for item in media:
                run = root / "runs" / item.identity
                links = list(run.rglob("*"))
                symlinks = [path for path in links if path.is_symlink()]
                self.assertEqual(len(symlinks), 6)
                self.assertTrue(all(not Path(path.readlink()).is_absolute() for path in symlinks))
                self.assertEqual(len(list((run / "corpus" / "Donna").iterdir())), 2)
                self.assertEqual(len(list((run / "corpus" / "NotDonna").iterdir())), 2)


if __name__ == "__main__":
    unittest.main()
