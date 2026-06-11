#!/usr/bin/env python3
"""Dossier JSONL merger.

Reads per-record JSONL delta files emitted by `dossier_batch.py
--output-jsonl <path>` workers running on the fleet (M4 + M1 + M5), and
applies them to the authoritative catalog.json on M4.

Runs as a daemon: scans the delta directory at a configurable interval,
tracks read offsets per file (so it doesn't re-apply lines), atomically
writes catalog.json. Single writer to catalog.json — workers never touch
it directly when in delta mode.

Usage:
  merge_dossier_jsonl.py --delta-dir /Volumes/Crucial2TB/dossier-deltas
                        [--interval 60]      # seconds between scans
                        [--once]             # one pass, then exit
                        [--catalog ~/Library/Application\\ Support/VideoScan/catalog.json]

State:
  /tmp/dossier-merger-offsets.json  — last-applied byte offset per JSONL file.

Safety:
  - Atomic write of catalog.json (tmp + rename, .prev backup rotated).
  - Idempotent: re-applying the same JSONL line is a no-op (same fields → same record state).
  - JSON parse errors on a single line are logged and skipped — never abort the merger.
"""

import argparse
import datetime as dt
import hashlib
import json
import os
import shutil
import sys
import time
from pathlib import Path

DEFAULT_CATALOG = Path("~/Library/Application Support/VideoScan/catalog.json").expanduser()
# Persistent location — survives reboot. The legacy /tmp path is migrated
# automatically on first run via migrate_legacy_offsets().
DEFAULT_OFFSETS = Path("~/Library/Application Support/VideoScan/dossier-merger-offsets.json").expanduser()
LEGACY_OFFSETS = Path("/tmp/dossier-merger-offsets.json")
LOG_DIR = Path("~/Library/Logs/VideoScan/dossier-merger").expanduser()


def now_iso():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def load_offsets(path: Path) -> dict[str, int]:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except Exception:
        return {}


def migrate_legacy_offsets(new_path: Path,
                           legacy_path: Path = LEGACY_OFFSETS) -> bool:
    """If a legacy `/tmp` offsets file exists and the new persistent path
    has no offsets yet, copy the legacy file into the new location.

    Rationale: pre-2026-06-07 the merger stored offsets in `/tmp` which
    macOS may wipe on reboot. The new default lives under Application
    Support and survives. This shim is idempotent and safe to call
    every run.

    Returns True if a migration actually happened (for logging). Never
    raises — a migration failure means we fall through to "no
    offsets," which triggers a full idempotent replay. That's
    safe (every JSONL line re-applied is a no-op) but the user-facing
    cost is a few extra minutes of merge work on next start.
    """
    if not legacy_path.exists():
        return False
    if new_path.exists():
        return False
    try:
        new_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(legacy_path, new_path)
        return True
    except Exception:
        return False


def save_offsets(path: Path, offsets: dict[str, int]):
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(offsets, indent=2))
    os.replace(tmp, path)


def atomic_write_catalog(catalog: dict, path: Path):
    if path.exists():
        shutil.copy2(path, path.with_suffix(".json.prev"))
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(catalog, indent=2, ensure_ascii=False))
    os.replace(tmp, path)


# ---------------------------------------------------------------------------
# Manifest writer — must stay in lock-step with the Swift master so viewers
# can verify what we wrote. The Swift side computes the manifest in
# CatalogSync.computeManifestLines (CatalogSync.swift:315):
#
#   - covers ["catalog.json", "catalog.json.prev", "POI"]
#   - POI is walked recursively, regular files only
#   - lines: "<sha256_hex>  <relpath>"  (two spaces, GNU shasum format)
#   - sorted by relpath ASC
#
# Without this step, the viewer-side rsync succeeds but the manifest
# verify fails ("sha256 mismatch: catalog.json") because the merger
# updates catalog.json without re-stamping the manifest. Symptom Rick saw:
# "MASTER OFFLINE" banner on M5/M1 even though the rsync itself worked.
#
# Verified fix 2026-06-06: with this step, viewer state transitions
# from .failed("manifest verify failed") to .synced(at:).

MANIFEST_ROOTS = ["catalog.json", "catalog.json.prev", "POI"]


def sha256_hex_of_file(path: Path) -> str:
    """Streaming SHA-256 — matches the Swift master's 1 MB chunked reader."""
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def compute_manifest_lines(root_dir: Path) -> list[str]:
    """Mirror of Swift CatalogSync.computeManifestLines. Returns lines
    in '<hash>  <relpath>' format, sorted by relpath ascending."""
    entries: list[tuple[str, str]] = []  # (relpath, hash)
    for top in MANIFEST_ROOTS:
        url = root_dir / top
        if not url.exists():
            continue
        if url.is_dir():
            # Walk regular files only, skip hidden (matches Swift's
            # FileManager.enumerator with .skipsHiddenFiles).
            for child in sorted(url.rglob("*")):
                if child.name.startswith("."):
                    continue
                if not child.is_file():
                    continue
                rel = child.relative_to(root_dir).as_posix()
                entries.append((rel, sha256_hex_of_file(child)))
        else:
            rel = url.relative_to(root_dir).as_posix()
            entries.append((rel, sha256_hex_of_file(url)))
    entries.sort(key=lambda e: e[0])
    return [f"{h}  {rel}" for rel, h in entries]


def write_manifest(root_dir: Path) -> int:
    """Compute + atomically write manifest.sha256 next to catalog.json.
    Returns the line count for logging."""
    lines = compute_manifest_lines(root_dir)
    manifest_path = root_dir / "manifest.sha256"
    tmp = manifest_path.with_suffix(".sha256.tmp")
    tmp.write_text("\n".join(lines) + "\n")
    os.replace(tmp, manifest_path)
    return len(lines)


def read_new_deltas(delta_dir: Path, offsets: dict[str, int], log):
    """Return list of (file, parsed delta dict) for unread lines, plus updated offsets."""
    new_deltas = []
    for jsonl_file in sorted(delta_dir.glob("*.jsonl")):
        key = jsonl_file.name
        last_offset = offsets.get(key, 0)
        size = jsonl_file.stat().st_size
        if size <= last_offset:
            continue
        # Read from last offset
        with jsonl_file.open("r") as f:
            f.seek(last_offset)
            raw = f.read()
            new_end = last_offset + len(raw.encode("utf-8"))
        line_count = 0
        for line in raw.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                delta = json.loads(line)
                new_deltas.append((key, delta))
                line_count += 1
            except json.JSONDecodeError as e:
                log(f"  skip malformed line in {key}: {e}")
        if line_count:
            log(f"  {key}: read {line_count} new line(s) "
                f"(offset {last_offset} → {new_end})")
        offsets[key] = new_end
    return new_deltas, offsets


# ---------------------------------------------------------------------------
# Schema validation for incoming deltas.
#
# Rick 2026-06-07 audit identified the "buggy worker silently corrupts
# records" weakness: apply_deltas previously copied any value through
# without type-checking, so a worker emitting `dossierProcessedAt:
# "not a date"` would silently land in catalog.json and the manifest
# would re-stamp the corruption as verified. This pass type-checks each
# known field; bad fields are skipped (the rest of the delta still
# applies) and counted in the result.
#
# Known fields are validated strictly. UNKNOWN fields pass through —
# forward-compat hook so workers can introduce new dossier channels
# without a merger update. The cost of permissiveness here is bounded
# because the catalog round-trips through the Swift JSONDecoder on next
# launch and rejects truly malformed records.

# Field name → validator predicate (value → bool). None means "anything
# is allowed except outright wrong-shape JSON values" (str/dict-as-bool
# etc.) — handled by the universal `_is_sane_json_value` check.
def _is_iso_string_or_null(v):
    if v is None:
        return True
    if not isinstance(v, str):
        return False
    # ISO 8601 dates are at minimum 10 chars (YYYY-MM-DD) and start with
    # a digit. Don't try to fully parse — workers emit a few variants
    # (with/without TZ, with/without millis) and the Swift decoder is
    # the final arbiter. We just reject obviously wrong shapes (empty
    # string, non-digit start).
    if len(v) < 10 or not v[0].isdigit():
        return False
    return True


def _is_str_or_null(v):
    return v is None or isinstance(v, str)


def _is_num_or_null(v):
    return v is None or isinstance(v, (int, float)) and not isinstance(v, bool)


def _is_caption_list(v):
    """List of {timestamp, text} dicts (with optional extra keys)."""
    if not isinstance(v, list):
        return False
    for item in v:
        if not isinstance(item, dict):
            return False
        if "timestamp" not in item or "text" not in item:
            return False
        if not isinstance(item["timestamp"], (int, float)):
            return False
        if not isinstance(item["text"], str):
            return False
    return True


DOSSIER_FIELD_VALIDATORS = {
    "sceneCaptions":         _is_caption_list,
    "sceneCaptionModel":     _is_str_or_null,
    "sceneCaptionDate":      _is_iso_string_or_null,
    "audioTranscript":       _is_str_or_null,
    "audioTranscriptModel":  _is_str_or_null,
    "audioTranscriptDate":   _is_iso_string_or_null,
    "ocrDateCandidates":     _is_caption_list,
    "ocrText":               _is_caption_list,
    "inferredRecordDate":    _is_iso_string_or_null,
    "inferredDateConfidence": _is_num_or_null,
    "dossierProcessedAt":    _is_iso_string_or_null,
    "dossierProcessedBy":    _is_str_or_null,
}


def validate_delta_fields(fields: dict, log=None) -> tuple[dict, list[tuple[str, str]]]:
    """Filter `fields` to those that pass schema validation.

    Returns (kept_fields, rejected) where `rejected` is a list of
    (field_name, reason) tuples for the caller to log/quarantine.
    Unknown field names pass through unchanged — forward-compat for
    future dossier channels.
    """
    kept = {}
    rejected: list[tuple[str, str]] = []
    for k, v in fields.items():
        validator = DOSSIER_FIELD_VALIDATORS.get(k)
        if validator is None:
            # Unknown field — accept (forward-compat). The Swift
            # decoder is the final type gate.
            kept[k] = v
            continue
        if validator(v):
            kept[k] = v
        else:
            type_name = type(v).__name__
            rejected.append((k, f"schema reject: {type_name} not valid for {k}"))
    return kept, rejected


def apply_deltas(catalog: dict, deltas: list, log):
    """Apply parsed delta dicts to catalog records. Returns count applied.

    Schema-validates each delta's fields per DOSSIER_FIELD_VALIDATORS.
    Invalid fields are skipped (with a logged reason); the rest of the
    delta still applies. A delta whose every field is rejected counts
    as schema-rejected (not applied)."""
    by_path = {r["fullPath"]: r for r in catalog["records"]}
    applied = 0
    skipped_no_record = 0
    schema_rejected_fields = 0
    schema_rejected_whole_deltas = 0
    for _, delta in deltas:
        path = delta.get("fullPath")
        fields = delta.get("fields", {})
        if not path or not fields:
            continue
        rec = by_path.get(path)
        if not rec:
            skipped_no_record += 1
            continue
        kept, rejected = validate_delta_fields(fields, log=log)
        if rejected:
            for k, reason in rejected:
                log(f"  schema-reject {path} field={k}: {reason}")
                schema_rejected_fields += 1
        if not kept:
            # Every field was rejected — nothing to apply.
            schema_rejected_whole_deltas += 1
            continue
        for k, v in kept.items():
            rec[k] = v
        applied += 1
    if skipped_no_record:
        log(f"  skipped {skipped_no_record} delta(s) with no matching catalog record")
    if schema_rejected_fields:
        log(f"  schema rejected {schema_rejected_fields} field(s) " +
            f"across {schema_rejected_whole_deltas} fully-rejected delta(s)")
    return applied


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--delta-dir", required=True,
                    help="Directory containing per-worker *.jsonl files.")
    ap.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    ap.add_argument("--offsets", type=Path, default=DEFAULT_OFFSETS,
                    help="Where to track per-file read offsets between runs.")
    ap.add_argument("--interval", type=int, default=60,
                    help="Seconds between scans in daemon mode (default: 60).")
    ap.add_argument("--once", action="store_true",
                    help="One pass then exit (for cron-style scheduling).")
    args = ap.parse_args()

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    logpath = LOG_DIR / f"merger_{dt.datetime.now().strftime('%Y%m%d_%H%M%S')}.log"
    logf = open(logpath, "w")

    def log(msg):
        line = f"[{now_iso()}] {msg}"
        print(line)
        logf.write(line + "\n")
        logf.flush()

    delta_dir = Path(args.delta_dir)
    log(f"=== merger start ===")
    log(f"delta_dir: {delta_dir}")
    log(f"catalog:   {args.catalog}")
    log(f"offsets:   {args.offsets}")
    log(f"interval:  {args.interval}s ({'once' if args.once else 'daemon'})")

    # One-shot migration: if the legacy `/tmp` offsets file exists and
    # the persistent path doesn't, copy it over so the merger picks up
    # where the previous /tmp-based run left off (instead of replaying
    # from byte 0). Idempotent and silent when there's nothing to do.
    if migrate_legacy_offsets(args.offsets):
        log(f"  migrated legacy offsets {LEGACY_OFFSETS} → {args.offsets}")

    if not delta_dir.exists():
        delta_dir.mkdir(parents=True, exist_ok=True)
        log(f"created delta dir")

    # Periodic bundle metadata extraction. Rick 2026-06-09: we agreed
    # this should be automatic rather than button-driven — the operation
    # is read-only, fast, idempotent (skips records with an existing
    # inferredRecordDate). Runs once at merger startup, then every
    # BUNDLE_EXTRACT_EVERY_CYCLES cycles thereafter (default 360 ×
    # 60s = ~6 hours). Provenance lives in the bundle-meta.jsonl
    # delta file for forensic lookup; we deliberately don't add a
    # Swift catalog field for it (keeps Codable surface stable).
    bundle_extractor = Path(__file__).resolve().parent / "extract_bundle_metadata.py"
    BUNDLE_EXTRACT_EVERY_CYCLES = 360
    cycle = 0

    def run_bundle_extract():
        """Shell out to the bundle metadata extractor. Failures are
        logged but never crash the merger — bundle metadata is a
        belt-and-suspenders source, not load-bearing."""
        if not bundle_extractor.exists():
            return
        try:
            import subprocess
            t0 = time.time()
            result = subprocess.run(
                [sys.executable, str(bundle_extractor)],
                capture_output=True, text=True, timeout=1800,  # 30-min cap
            )
            # Surface the last 3 lines of script output (contains
            # the "wrote N delta(s)" summary).
            tail = "\n    ".join(result.stdout.strip().splitlines()[-3:])
            log(f"  bundle-extract done in {time.time() - t0:.1f}s:\n    {tail}")
        except Exception as e:
            log(f"  bundle-extract failed: {e} — continuing")

    # Run once at startup so a fresh merger immediately has bundle
    # data available rather than waiting 6 hours for the first cycle.
    log("  initial bundle-meta extraction (runs on startup + every "
        f"{BUNDLE_EXTRACT_EVERY_CYCLES * args.interval / 3600:.1f}h)")
    run_bundle_extract()

    while True:
        cycle += 1
        offsets = load_offsets(args.offsets)
        deltas, offsets = read_new_deltas(delta_dir, offsets, log)
        if deltas:
            try:
                catalog = json.loads(args.catalog.read_text())
            except Exception as e:
                log(f"ERROR reading catalog: {e} — will retry next cycle")
                if args.once:
                    break
                time.sleep(args.interval)
                continue
            applied = apply_deltas(catalog, deltas, log)
            if applied:
                atomic_write_catalog(catalog, args.catalog)
                save_offsets(args.offsets, offsets)
                # Re-stamp manifest.sha256 so viewers can verify the
                # freshly-written catalog. Otherwise the rsync succeeds
                # but verifyManifest fails on the sha256 mismatch and
                # the viewer shows "MASTER OFFLINE".
                try:
                    n_lines = write_manifest(args.catalog.parent)
                    log(f"  applied {applied} delta(s) → catalog.json; manifest re-stamped ({n_lines} files)")
                except Exception as e:
                    log(f"  applied {applied} delta(s) → catalog.json; manifest re-stamp FAILED: {e}")
            else:
                log(f"  no applicable deltas (read {len(deltas)})")
                save_offsets(args.offsets, offsets)
        else:
            log(f"  no new deltas")
        if args.once:
            break
        # Periodic re-extract — catches newly mounted volumes (e.g. Rick
        # plugs in an old drive) without requiring a merger restart.
        if cycle % BUNDLE_EXTRACT_EVERY_CYCLES == 0:
            log(f"  periodic bundle-meta extraction (cycle {cycle})")
            run_bundle_extract()
        time.sleep(args.interval)

    log(f"=== merger stop ===")
    logf.close()


if __name__ == "__main__":
    sys.exit(main() or 0)
