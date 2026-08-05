#!/usr/bin/env python3
"""Build a privacy-safe, identity-labelled synthetic face test corpus.

The source is ControlFace10K (CC-BY-4.0).  The tool reads the remote ZIP
directory and downloads only the selected entries with HTTP range requests;
it never needs the 3.14 GB archive in full.

For N identities the emitted generic manifest contains 4N cases:

* same identity, MP4
* same identity, MKV/FFV1
* different identity, MP4
* different identity, MKV/FFV1

With the default N=25 this is a balanced 100-case identity benchmark and a
50-file decoder-route media corpus.  Every synthetic clip is also a valid
hard negative when evaluated against Donna.  It is never a Donna positive.
"""

from __future__ import annotations

import argparse
import binascii
import json
import os
import re
import struct
import subprocess
import urllib.request
import zlib
from dataclasses import asdict, dataclass
from pathlib import Path
from random import Random
from typing import Iterable


DATASET_REVISION = "a03589de1a9e028b2d16fa1eb0e019a6930e817c"
DATASET_URL = (
    "https://huggingface.co/datasets/HuMInGameLab/ControlFace10K/"
    f"resolve/{DATASET_REVISION}/controlface10k.zip"
)
DATASET_PAGE = "https://huggingface.co/datasets/HuMInGameLab/ControlFace10K"
DATASET_LICENSE = "CC-BY-4.0"
DEFAULT_OUTPUT = Path("output/person-eval-private/controlface100")


@dataclass(frozen=True)
class ZipEntry:
    name: str
    compression: int
    crc32: int
    compressed_size: int
    uncompressed_size: int
    local_offset: int


@dataclass(frozen=True)
class IdentityMedia:
    identity: str
    demographic_group: str
    dataset_sex: str
    dataset_age: int
    references: tuple[str, str]
    query_image: str
    query_mp4: str
    query_mkv: str


def _range(url: str, start: int, end: int) -> bytes:
    request = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end}"})
    with urllib.request.urlopen(request, timeout=60) as response:
        expected = end - start + 1
        # Read one byte beyond the promised range so a server silently
        # ignoring Range cannot make this process ingest the 3.14 GB archive.
        payload = response.read(expected + 1)
        if len(payload) != expected:
            raise RuntimeError(
                f"HTTP range mismatch for {start}-{end}: received {len(payload)} bytes"
            )
        return payload


def resolve_archive(url: str) -> tuple[str, int]:
    request = urllib.request.Request(url, method="HEAD")
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.url, int(response.headers["Content-Length"])


def parse_central_directory(data: bytes) -> list[ZipEntry]:
    entries: list[ZipEntry] = []
    offset = 0
    header = struct.Struct("<4s6H3L5H2L")
    while offset + header.size <= len(data):
        fields = header.unpack_from(data, offset)
        if fields[0] != b"PK\x01\x02":
            break
        compression = fields[4]
        crc32 = fields[7]
        compressed_size = fields[8]
        uncompressed_size = fields[9]
        name_length, extra_length, comment_length = fields[10:13]
        local_offset = fields[16]
        name_start = offset + header.size
        name = data[name_start : name_start + name_length].decode("utf-8")
        entries.append(
            ZipEntry(
                name=name,
                compression=compression,
                crc32=crc32,
                compressed_size=compressed_size,
                uncompressed_size=uncompressed_size,
                local_offset=local_offset,
            )
        )
        offset = name_start + name_length + extra_length + comment_length
    return entries


def fetch_directory(url: str) -> tuple[str, int, list[ZipEntry]]:
    resolved, archive_size = resolve_archive(url)
    tail_size = min(65_557, archive_size)
    tail = _range(resolved, archive_size - tail_size, archive_size - 1)
    eocd_offset = tail.rfind(b"PK\x05\x06")
    if eocd_offset < 0:
        raise RuntimeError("ZIP end-of-central-directory record not found")
    eocd = struct.unpack_from("<4s4H2LH", tail, eocd_offset)
    central_size, central_offset = eocd[5], eocd[6]
    central = _range(resolved, central_offset, central_offset + central_size - 1)
    entries = parse_central_directory(central)
    if len(entries) != eocd[4]:
        raise RuntimeError(f"ZIP directory count mismatch: {len(entries)} != {eocd[4]}")
    return resolved, archive_size, entries


def extract_entry(url: str, entry: ZipEntry) -> bytes:
    local = _range(url, entry.local_offset, entry.local_offset + 29)
    fields = struct.unpack("<4s5H3L2H", local)
    if fields[0] != b"PK\x03\x04":
        raise RuntimeError(f"Bad local ZIP header for {entry.name}")
    name_length, extra_length = fields[9], fields[10]
    data_start = entry.local_offset + 30 + name_length + extra_length
    compressed = _range(url, data_start, data_start + entry.compressed_size - 1)
    if entry.compression == 0:
        payload = compressed
    elif entry.compression == 8:
        payload = zlib.decompress(compressed, -zlib.MAX_WBITS)
    else:
        raise RuntimeError(f"Unsupported ZIP compression {entry.compression}")
    if len(payload) != entry.uncompressed_size:
        raise RuntimeError(f"Size mismatch for {entry.name}")
    if binascii.crc32(payload) & 0xFFFFFFFF != entry.crc32:
        raise RuntimeError(f"CRC mismatch for {entry.name}")
    return payload


def grouped_identities(
    entries: Iterable[ZipEntry], demographic_group: str, dataset_sex: str, ages: set[int]
) -> dict[str, list[ZipEntry]]:
    pattern = re.compile(
        rf"^ControlFace10k/{re.escape(demographic_group)}/"
        rf"{re.escape(dataset_sex)}/(\d+)/(?P<identity>identity-[^/]+)/.*\.png$"
    )
    groups: dict[str, list[ZipEntry]] = {}
    for entry in entries:
        match = pattern.match(entry.name)
        if not match or int(match.group(1)) not in ages:
            continue
        groups.setdefault(match.group("identity"), []).append(entry)
    return {key: sorted(value, key=lambda e: e.name) for key, value in groups.items() if len(value) >= 3}


def choose_identities(groups: dict[str, list[ZipEntry]], count: int, seed: int) -> list[str]:
    candidates = sorted(groups)
    if len(candidates) < count:
        raise RuntimeError(f"Need {count} identities, found {len(candidates)}")
    return sorted(Random(seed).sample(candidates, count))


def _write_bytes(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)


def render_video(image: Path, output: Path, ffmpeg: str, transport: str) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    common = [
        ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
        "-loop", "1", "-framerate", "30", "-i", str(image),
        "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
        "-t", "12", "-shortest",
        "-vf", "scale=640:360:force_original_aspect_ratio=decrease,"
               "pad=640:360:(ow-iw)/2:(oh-ih)/2,format=yuv420p",
    ]
    if transport == "avfoundation-mp4":
        codec = ["-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-c:a", "aac"]
    elif transport == "ffmpeg-mkv":
        codec = ["-c:v", "ffv1", "-level", "3", "-c:a", "pcm_s16le"]
    else:
        raise ValueError(f"Unknown transport {transport}")
    subprocess.run(common + codec + [str(output)], check=True)


def build_cases(media: list[IdentityMedia]) -> list[dict]:
    cases: list[dict] = []
    for index, item in enumerate(media):
        different = media[(index + 1) % len(media)]
        for transport, suffix in (("avfoundation-mp4", "mp4"), ("ffmpeg-mkv", "mkv")):
            cases.append(
                {
                    "id": f"same-{index:02d}-{suffix}",
                    "referenceIdentity": item.identity,
                    "queryIdentity": item.identity,
                    "references": list(item.references),
                    "video": item.query_mp4 if suffix == "mp4" else item.query_mkv,
                    "transport": transport,
                    "expectedTargetPresent": True,
                }
            )
            cases.append(
                {
                    "id": f"different-{index:02d}-{suffix}",
                    "referenceIdentity": item.identity,
                    "queryIdentity": different.identity,
                    "references": list(item.references),
                    "video": different.query_mp4 if suffix == "mp4" else different.query_mkv,
                    "transport": transport,
                    "expectedTargetPresent": False,
                }
            )
    return cases


def validate_cases(cases: list[dict], identity_count: int) -> None:
    expected = identity_count * 4
    if len(cases) != expected or len({case["id"] for case in cases}) != expected:
        raise RuntimeError("Case-count or unique-ID invariant failed")
    positives = [case for case in cases if case["expectedTargetPresent"]]
    negatives = [case for case in cases if not case["expectedTargetPresent"]]
    if len(positives) != expected // 2 or len(negatives) != expected // 2:
        raise RuntimeError("Benchmark is not balanced")
    if any(case["referenceIdentity"] != case["queryIdentity"] for case in positives):
        raise RuntimeError("Positive identity mismatch")
    if any(case["referenceIdentity"] == case["queryIdentity"] for case in negatives):
        raise RuntimeError("Negative identity collision")


def materialize_calibration_layout(output_root: Path, media: list[IdentityMedia]) -> None:
    """Create one RecipeCalibrationCLI gallery/corpus per synthetic identity."""
    for index, item in enumerate(media):
        different = media[(index + 1) % len(media)]
        run_root = output_root / "runs" / item.identity
        links = {
            run_root / "gallery" / "synthetic" / "reference-0.png": output_root / item.references[0],
            run_root / "gallery" / "synthetic" / "reference-1.png": output_root / item.references[1],
            run_root / "corpus" / "Donna" / "query.mp4": output_root / item.query_mp4,
            run_root / "corpus" / "Donna" / "query.mkv": output_root / item.query_mkv,
            run_root / "corpus" / "NotDonna" / "query.mp4": output_root / different.query_mp4,
            run_root / "corpus" / "NotDonna" / "query.mkv": output_root / different.query_mkv,
        }
        for link, target in links.items():
            link.parent.mkdir(parents=True, exist_ok=True)
            if link.is_symlink() or link.exists():
                link.unlink()
            link.symlink_to(os.path.relpath(target, start=link.parent))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--identity-count", type=int, default=25)
    parser.add_argument("--seed", type=int, default=1959)
    parser.add_argument("--demographic-group", default="Caucasian")
    parser.add_argument("--dataset-sex", default="female")
    parser.add_argument("--ages", default="25,50")
    parser.add_argument("--ffmpeg", default="/opt/homebrew/bin/ffmpeg")
    parser.add_argument("--accept-license", action="store_true")
    parser.add_argument("--skip-video-render", action="store_true")
    args = parser.parse_args()

    if not args.accept_license:
        parser.error("ControlFace10K is CC-BY-4.0; rerun with --accept-license")
    output_root = args.output.resolve()
    ages = {int(value) for value in args.ages.split(",")}
    resolved, archive_size, entries = fetch_directory(DATASET_URL)
    groups = grouped_identities(entries, args.demographic_group, args.dataset_sex, ages)
    selected = choose_identities(groups, args.identity_count, args.seed)

    media: list[IdentityMedia] = []
    for identity in selected:
        source_entries = groups[identity][:3]
        identity_dir = output_root / "identities" / identity
        local_images: list[Path] = []
        for pose_index, entry in enumerate(source_entries):
            destination = identity_dir / f"pose-{pose_index}.png"
            if not destination.exists():
                _write_bytes(destination, extract_entry(resolved, entry))
            local_images.append(destination.resolve())
        references = (
            str(local_images[0].relative_to(output_root)),
            str(local_images[2].relative_to(output_root)),
        )
        query = local_images[1]
        mp4 = output_root / "media" / f"{identity}.mp4"
        mkv = output_root / "media" / f"{identity}.mkv"
        if not args.skip_video_render:
            if not mp4.exists():
                render_video(query, mp4, args.ffmpeg, "avfoundation-mp4")
            if not mkv.exists():
                render_video(query, mkv, args.ffmpeg, "ffmpeg-mkv")
        age_match = re.search(r"_a(\d+)_", source_entries[0].name)
        media.append(
            IdentityMedia(
                identity=identity,
                demographic_group=args.demographic_group,
                dataset_sex=args.dataset_sex,
                dataset_age=int(age_match.group(1)) if age_match else -1,
                references=references,
                query_image=str(query.relative_to(output_root)),
                query_mp4=str(mp4.relative_to(output_root)),
                query_mkv=str(mkv.relative_to(output_root)),
            )
        )

    cases = build_cases(media)
    validate_cases(cases, args.identity_count)
    materialize_calibration_layout(output_root, media)
    provenance = {
        "dataset": "ControlFace10K",
        "datasetURL": DATASET_PAGE,
        "archiveURL": DATASET_URL,
        "datasetRevision": DATASET_REVISION,
        "license": DATASET_LICENSE,
        "attribution": (
            "ControlFace10K by Kassi Nzalasse, Rishav Raj, Eli Laird, "
            "and Corey Clark; SIG: A Synthetic Identity Generation Pipeline "
            "for Generating Evaluation Datasets for Face Recognition (2024)."
        ),
        "archiveSizeBytes": archive_size,
        "selectionSeed": args.seed,
        "publisherDemographicGroup": args.demographic_group,
        "publisherSexLabel": args.dataset_sex,
        "publisherAgeLabels": sorted(ages),
        "ancestryInferencePerformed": False,
        "appearanceSelectionPerformed": False,
        "note": "Synthetic people are Donna hard negatives. Same-identity cases validate generic machinery only.",
    }
    manifest = {
        "schemaVersion": 1,
        "suite": "ControlFace100 synthetic identity and decoder-route benchmark",
        "provenance": provenance,
        "identities": [asdict(item) for item in media],
        "cases": cases,
    }
    output_root.mkdir(parents=True, exist_ok=True)
    (output_root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (output_root / "ATTRIBUTION.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print(f"Wrote {len(cases)} cases from {len(media)} synthetic identities to {output_root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
