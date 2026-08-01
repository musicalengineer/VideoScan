#!/usr/bin/env python3
"""Analyze a VideoScan `--audit-references` JSON dump (POI cycle 2).

Lives in tools/poi-c02/ — tools/person-eval/ (the frozen grading harness) is
deliberately untouched, same discipline as cycle 1.

Input: the JSON emitted by
    VideoScan --person-eval --engine arcface --audit-references \
        --references <dir>  > audit.json

Computes, per reference face (all offline — the embeddings in the dump are the
exact vectors production matches against):
  - detection confidence, face pixel size, raw embedding norm (from the dump)
  - mean / median pairwise cosine to the other reference faces
  - nearest-neighbor cosine (max cosine to any other face) and its label
  - single-link connected components at one or more link thresholds
    (replicates ReferenceCalibration.calibrate exactly; the dump's own
    `calibration` block is cross-checked against our recomputation)

Outputs a markdown report and, optionally, a curated refset manifest
(`--emit-manifest`) listing kept/dropped faces with reasons and the sha256 of
each source file so the set can be re-materialized and verified later
(tools/poi-c02/make_refset.py).

CANONICAL CANDIDATE (one definition, everywhere): the C2 candidate is the
Swift rule — `ReferenceCalibration.calibrate`, single-link largest component
at the dump's `referenceCalibration.minClusterLink`, with the ≥2-face
fallback — exercised via `--reference-calibration audited`. The manifest's
kept/dropped faces are taken VERBATIM from the dump's `calibration` block
(which that rule produced), and this script's own recomputation must match
exactly or it exits with an error. No second algorithm: the NN-isolate and
per-face statistics in the report are diagnostics only and never decide
curation. The emitted manifest embeds the dump's `referenceCalibration`
object as its single hashable configuration.

File-level faithfulness: a materialized folder can only drop whole FILES,
but the canonical rule drops FACES. If any kept file also contains a dropped
face, legacy loading of the materialized folder would resurrect that face and
the folder would NOT equal the candidate — the script then refuses to emit
the manifest (override with --allow-unfaithful for diagnostics only; the
manifest is marked "faithful": false and make_refset.py refuses it).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import statistics
import sys


def cosine(a: list[float], b: list[float]) -> float:
    return sum(x * y for x, y in zip(a, b))


def single_link_components(cos: list[list[float]], link: float) -> list[list[int]]:
    n = len(cos)
    parent = list(range(n))

    def find(x: int) -> int:
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for i in range(n):
        for j in range(i + 1, n):
            if cos[i][j] >= link:
                ri, rj = find(i), find(j)
                if ri != rj:
                    parent[max(ri, rj)] = min(ri, rj)
    members: dict[int, list[int]] = {}
    for i in range(n):
        members.setdefault(find(i), []).append(i)
    return sorted(members.values(), key=lambda c: (-len(c), c[0]))


def sha256_of(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("audit", type=pathlib.Path, help="JSON from --audit-references")
    parser.add_argument("--links", default="0.25,0.30,0.35,0.40",
                        help="comma-separated single-link thresholds to report")
    parser.add_argument("--isolate-cutoff", type=float, default=0.20,
                        help="report-only diagnostic flag threshold (never decides curation)")
    parser.add_argument("--markdown", type=pathlib.Path, help="write markdown report here")
    parser.add_argument("--emit-manifest", type=pathlib.Path,
                        help="write a curated refset manifest (JSON) here — kept/dropped "
                             "come verbatim from the dump's canonical calibration block")
    parser.add_argument("--refset-name", default="curated",
                        help="name recorded in the emitted manifest")
    parser.add_argument("--allow-unfaithful", action="store_true",
                        help="emit a manifest even when file-level materialization cannot "
                             "reproduce the face-level candidate (diagnostics only; "
                             "make_refset.py refuses such manifests)")
    args = parser.parse_args(argv)

    audit = json.loads(args.audit.read_text())
    faces = audit["faces"]
    if not faces:
        print("audit contains no faces", file=sys.stderr)
        return 2
    n = len(faces)
    cos = [[cosine(faces[i]["embedding"], faces[j]["embedding"]) for j in range(n)]
           for i in range(n)]

    rows = []
    for i, face in enumerate(faces):
        others = [cos[i][j] for j in range(n) if j != i]
        nn = max((j for j in range(n) if j != i), key=lambda j: cos[i][j])
        rows.append({
            "label": face["label"],
            "confidence": face["confidence"],
            "px": f"{face['faceWidthPx']}x{face['faceHeightPx']}",
            "minSidePx": min(face["faceWidthPx"], face["faceHeightPx"]),
            "rawNorm": face["rawNorm"],
            "meanCos": statistics.mean(others),
            "medianCos": statistics.median(others),
            "nnCos": cos[i][nn],
            "nnLabel": faces[nn]["label"],
            "isolate": cos[i][nn] < args.isolate_cutoff,
        })

    links = [float(x) for x in args.links.split(",") if x.strip()]
    components = {link: single_link_components(cos, link) for link in links}

    # Cross-check the dump's own calibration block (same math in Swift).
    swift = audit.get("calibration", {})
    swift_link = audit.get("referenceCalibration", {}).get("minClusterLink")
    check = ""
    if swift_link is not None:
        ours = single_link_components(cos, float(swift_link))
        ours_sizes = [len(c) for c in ours]
        match = ours_sizes == swift.get("clusterSizes")
        check = (f"Swift calibration cross-check at link {swift_link}: "
                 f"{'MATCH' if match else 'MISMATCH'} "
                 f"(python {ours_sizes} vs swift {swift.get('clusterSizes')})")

    lines = [
        f"# Reference audit — {audit['referencePath']}",
        "",
        f"Faces embedded: {n} · skipped: {len(audit.get('skipped', []))} · "
        f"largestFaceOnly: {audit['largestFaceOnly']} · "
        f"landmarkAlignment: {audit['landmarkAlignment']}",
        "",
    ]
    if check:
        lines += [check, ""]
    for skip in audit.get("skipped", []):
        lines.append(f"- skipped: `{skip['file']}` — {skip['reason']}")
    if audit.get("skipped"):
        lines.append("")
    lines += [
        "| face | conf | px | rawNorm | mean cos | median cos | NN cos | NN | flags |",
        "|---|---:|---:|---:|---:|---:|---:|---|---|",
    ]
    for row in sorted(rows, key=lambda r: r["nnCos"]):
        flags = []
        if row["isolate"]:
            flags.append("ISOLATE")
        if row["minSidePx"] < 100:
            flags.append("TINY-FACE")
        if row["confidence"] < 0.7:
            flags.append("LOW-CONF")
        lines.append(
            f"| {row['label']} | {row['confidence']:.2f} | {row['px']} | "
            f"{row['rawNorm']:.1f} | {row['meanCos']:.3f} | {row['medianCos']:.3f} | "
            f"{row['nnCos']:.3f} | {row['nnLabel']} | {', '.join(flags)} |")
    lines.append("")
    for link in links:
        sizes = [len(c) for c in components[link]]
        lines.append(f"## Components at link {link}: sizes {sizes}")
        for k, comp in enumerate(components[link]):
            labels = [faces[i]["label"] for i in comp]
            lines.append(f"- comp{k} (n={len(comp)}): {', '.join(labels)}")
        lines.append("")
    report = "\n".join(lines) + "\n"
    if args.markdown:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text(report)
    else:
        print(report)

    if args.emit_manifest:
        ref_dir = pathlib.Path(audit["referencePath"])
        config = audit.get("referenceCalibration") or {}
        swift_cal = audit.get("calibration") or {}
        if config.get("mode") != "audited" or "keptLabels" not in swift_cal:
            print("manifest requires an audit dump produced by --audit-references "
                  "(mode 'audited' with a calibration block)", file=sys.stderr)
            return 4

        # Canonical candidate = the dump's calibration block, verbatim.
        kept_labels = list(swift_cal["keptLabels"])
        dropped_labels = list(swift_cal.get("droppedLabels", []))
        fell_back = bool(swift_cal.get("fellBackToAll", False))
        label_set = {f["label"] for f in faces}
        if sorted(kept_labels + dropped_labels) != sorted(label_set):
            print("audit dump inconsistent: calibration labels != faces", file=sys.stderr)
            return 4

        # Parity cross-check: recompute the Swift rule (single-link largest
        # component at minClusterLink, ≥2-face fallback, tie-break toward the
        # earliest member) and require an exact match. One algorithm only.
        comps = single_link_components(cos, float(config["minClusterLink"]))
        if n == 1:
            # Swift passes single-reference sets through without fallback.
            our_kept, our_fell_back = sorted(label_set), False
        elif len(comps[0]) < 2:
            our_kept, our_fell_back = sorted(label_set), True
        else:
            our_kept = sorted(faces[i]["label"] for i in comps[0])
            our_fell_back = False
        if our_kept != sorted(kept_labels) or our_fell_back != fell_back:
            print(f"ALGORITHM PARITY FAILURE: python recomputation disagrees with the "
                  f"dump's calibration block at link {config['minClusterLink']} "
                  f"(python kept {len(our_kept)}, fellBack {our_fell_back}; "
                  f"swift kept {len(kept_labels)}, fellBack {fell_back})", file=sys.stderr)
            return 4

        # File-level faithfulness: materialization drops whole files, the
        # candidate drops faces. A kept file that also contains a dropped
        # face would resurrect it under legacy loading of the folder.
        kept_files = {label.rsplit("#", 1)[0] for label in kept_labels}
        dropped_files = {label.rsplit("#", 1)[0] for label in dropped_labels}
        mixed_files = sorted(kept_files & dropped_files)
        faithful = not mixed_files
        if not faithful and not args.allow_unfaithful:
            print(f"UNFAITHFUL: kept files also contain dropped faces {mixed_files}; "
                  f"a materialized folder cannot reproduce the candidate. The A/B "
                  f"candidate arm is --reference-calibration audited on the source "
                  f"folder; rerun with --allow-unfaithful only for diagnostics.",
                  file=sys.stderr)
            return 5

        nn_by_label = {r["label"]: r["nnCos"] for r in rows}
        file_hashes = {
            name: sha256_of(ref_dir / name)
            for name in sorted({f["file"] for f in faces})
            if (ref_dir / name).exists()
        }
        missing_hashes = sorted(f for f in kept_files if f not in file_hashes)
        if missing_hashes:
            print(f"kept files not hashable (missing on disk): {missing_hashes}",
                  file=sys.stderr)
            return 6

        manifest = {
            "schemaVersion": 2,
            "name": args.refset_name,
            "sourceReferencePath": audit["referencePath"],
            "algorithm": "single-link-largest-component",
            "referenceCalibration": config,
            "fellBackToAll": fell_back,
            "faithful": faithful,
            "keptFaces": sorted(kept_labels),
            "droppedFaces": [
                {"label": label,
                 "nnCos": round(nn_by_label.get(label, 0.0), 3),
                 "reason": f"outside the dominant cohesion component at link "
                           f"{config['minClusterLink']}"}
                for label in sorted(dropped_labels)],
            "keptFiles": sorted(kept_files),
            "droppedFiles": sorted(dropped_files - kept_files),
            "mixedFiles": mixed_files,
            "fileHashes": file_hashes,
        }
        args.emit_manifest.parent.mkdir(parents=True, exist_ok=True)
        args.emit_manifest.write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n")
        print(f"manifest: kept {len(manifest['keptFiles'])} files "
              f"({len(kept_labels)} faces), dropped files {manifest['droppedFiles']}, "
              f"faithful={faithful}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
