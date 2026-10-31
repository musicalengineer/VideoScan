#!/usr/bin/env python3
"""tools/data_organization.py — the map of where every fact lives (Rick, 2026-10-31):
"a PDF of the database fields and organization of the data so I can read it and know how
it is organized."

Reads the catalog READ-ONLY (an immutable URI: no lock, no journal, no write of any kind),
lists every table with its columns and row count under the group it belongs to, adds the
sidecar stores and the background helper's files, and writes
`docs/design/data_organization_<date>.md`. With `--pdf PATH` it also renders a PDF through
macOS's cupsfilter (text → PDF; no extra install). Table names, columns and counts only —
never a row's contents, so the document carries no family data.

    venv/bin/python3 tools/data_organization.py [--db PATH] [--pdf ~/Downloads/x.pdf]
"""
from __future__ import annotations

import argparse
import datetime
import re
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))
import catalog_db  # noqa: E402  (the one module allowed to name the catalog file)

CATALOG = "`{}`".format(catalog_db.DATABASE_FILE_NAME)   # the catalog's file name, never spelled here

GROUPS = [
    ("A. Identity — what a file IS (hard rule 6: identity is the whole-file SHA-256, never the path)",
     ["content", "files", "volumes", "tombstones", "pending_rows", "pending_purges", "supersessions", "av_pairs", "legacy_pair_ids"]),
    ("B. Rick's decisions — human facts, the highest rank (user_*, stars, people, places, events, archive)",
     ["user_dates", "user_places", "user_notes", "stars", "people_tags", "workflow_tags", "dispositions", "family_music",
      "backup_attestations", "events", "event_members", "event_decisions", "footage_decisions", "provenance_roles",
      "ignored_content", "ignored_content_put_back", "archive_copies", "backup_destinations"]),
    ("C. Machine observations — what engines and models found (by = engine@version, with provenance)",
     ["captions", "caption_runs", "transcripts", "inferred_dates", "dossiers", "sound_prints", "perceptual_prints",
      "footage_likeness", "footage_membership", "duplicate_groups", "duplicate_members", "media_checks", "lineage",
      "lineage_pending", "person_searches", "derived_unverified", "knowledge_sources", "row_knowledge", "regen_context",
      "provenance_assertions"]),
    ("D. Search", ["content_text_fts", "content_text_fts_config", "content_text_fts_content", "content_text_fts_data",
                   "content_text_fts_docsize", "content_text_fts_idx"]),
    ("E. Bookkeeping — generations, the ledger, imports, audits, jobs",
     ["catalog_state", "generations", "generation_history", "grdb_migrations", "ledger", "import_runs", "import_items",
      "audit_results", "quarantine", "integrity_runs", "job_markers"]),
]

SIDECARS = [
    ("`audio-fingerprints.sqlite`", "`fingerprints` — landmarks per content digest", "content digest",
     "same-footage matching; the stamp is in `sound_prints`"),
    ("`model-lab.sqlite`", "`runs` (run_id, approach_id, revision, prompt_hash, host, model_digest, git_sha, sampler_id, started_at) · "
     "`outputs` (run_id, content_digest, size_bytes, window_start_s, window_end_s, family, raw_json, schema_valid, elapsed_s) · "
     "`segments` (content_digest, engine, start_s, end_s, text) · `vectors` (content_digest, model, window_start_s, window_end_s, dims, blob)",
     "content digest + run", "append-only (triggers forbid update/delete); every model output with its model and prompt hash"),
    ("`metadata_cache.sqlite`", "`probe_cache` (path, file_size, mod_date, stream_type, duration_seconds, dates, container, codecs, "
     "resolution, frame_rate, bitrates, color_space, bit_depth, scan_type, audio channels/sample rate, …)",
     "path + size + mtime", "the ffprobe cache: a move or a touch re-probes (cheap, by design)"),
]

HELPER_FILES = [
    ("`queue/<job-id>.json`", "a JobRequest (kind, lane, parameters, requested-by)", "atomic publish + full fsync: the app's intent survives a forced reboot"),
    ("`checkpoints/<job-id>.json`", "the last completed unit of a job", "atomic publish; regenerable"),
    ("`journal/*.jsonl`", "one line per catalog-bound observation (digest, kind, value, by, evidence)", "append-only; the app's committer applies it; refused lines kept with the reason"),
    ("`~/Library/Logs/VideoScan/background.log`", "START / OUTCOME per job, one line per file analyzed", "log"),
]

LANDINGS = [
    ("scene caption, on-screen text, burned-in date", "captioner (the 8B from step 2)", "`captions` + `caption_runs` (via the journal)"),
    ("transcript", "Whisper", "`transcripts`"),
    ("era / inferred date", "8B era contract, fused with the file's facts", "`inferred_dates` (range_start, range_end, confidence, source, reason); v14 adds provenance assertions"),
    ("dossier (per-file summary of the above)", "DossierPropagation", "`dossiers`"),
    ("sound print / picture print", "audio fingerprint engine / perceptual hash", "`sound_prints` stamp + `audio-fingerprints.sqlite`; `perceptual_prints`"),
    ("same footage / likeness / duplicates", "fingerprint matching, hashes", "`footage_likeness`, `footage_membership`, `duplicate_groups` / `duplicate_members`"),
    ("media checks", "integrity engines", "`media_checks`, `integrity_runs`"),
    ("raw model outputs, segments, vectors", "model lab, Whisper segments, embeddings", "`model-lab.sqlite` only (bulk; never the catalog)"),
    ("people presence", "face pipeline + roster + Rick's confirmations", "People stores (separate by design) + `people_tags`"),
]


def read_schema(db_path: Path) -> tuple[int, dict[str, list[str]], dict[str, int]]:
    uri = "file:{}?mode=ro&immutable=1".format(db_path)
    con = sqlite3.connect(uri, uri=True)
    try:
        version = con.execute("select schema_version from catalog_state").fetchone()[0]
        names = [r[0] for r in con.execute("select name from sqlite_master where type='table' and name not like 'sqlite_%' order by name")]
        tables = {t: [c[1] for c in con.execute('pragma table_info("{}")'.format(t))] for t in names}
        counts = {t: con.execute('select count(*) from "{}"'.format(t)).fetchone()[0] for t in names}
    finally:
        con.close()
    return int(version), tables, counts


def render_markdown(version: int, tables: dict[str, list[str]], counts: dict[str, int], today: str) -> str:
    placed = {t for _, ts in GROUPS for t in ts}
    groups = list(GROUPS)
    left = [t for t in tables if t not in placed]
    if left:
        groups.append(("F. Not yet classified — classify in tools/data_organization.py", left))
    out = ["# VideoScan — how the data is organized (schema {}, {})\n".format(version, today),
           "*Rick's ask (2026-10-31): \"a PDF of the database fields and organization of the data so I can read it and know how it is "
           "organized.\" Generated by `tools/data_organization.py` from the live catalog read-only — table names, columns and row counts "
           "only, no family data. Regenerate after a migration.*\n",
           "## The three homes, in one paragraph\n",
           "**1. " + CATALOG + "** (App Support) is the truth: every file's identity, every decision Rick made, and every machine "
           "observation that has earned a seat — one committer, fixity, backups, rows never deleted. **2. Sidecar stores the engines "
           "own** (`audio-fingerprints.sqlite`, `model-lab.sqlite`, `metadata_cache.sqlite`) hold bulk, regenerable material the app "
           "reads directly. **3. The background helper's files** (`background/queue`, `checkpoints`, `journal/*.jsonl`) carry work in "
           "transit; the app's committer applies the journal into the catalog. `.scratch/` is the lab bench and is throwaway.\n",
           "**Vocabulary.** A fact Rick set is a **decision** (`user_*`, stars, people tags, events, archive). A fact a machine produced "
           "is an **observation** — Rick's own word in the service design — carrying `provenance` / `source` (which engine, which model "
           "and prompt hash, when). A decision always outranks an observation; an observation never supports the inference that produced it.\n",
           "## 1. " + CATALOG + " — {} tables\n".format(len(tables))]
    for title, ts in groups:
        out.append("### {}\n".format(title))
        out.append("| Table | Rows | Columns |\n|---|---|---|")
        for t in ts:
            if t in tables:
                out.append("| `{}` | {:,} | {} |".format(t, counts[t], ", ".join(tables[t])))
        out.append("")
    out.append("## 2. Sidecar stores (App Support; the app reads them directly; regenerable)\n")
    out.append("| Store | Tables / columns | Keyed by | Notes |\n|---|---|---|---|")
    for row in SIDECARS:
        out.append("| " + " | ".join(row) + " |")
    out.append("| perceptual prints | `perceptual_prints` lives IN the catalog | content digest | picture prints for same footage across transfers |")
    out.append("")
    out.append("## 3. The background helper's files (`~/Library/Application Support/VideoScan/background/`)\n")
    out.append("| Path | Holds | Durability |\n|---|---|---|")
    for row in HELPER_FILES:
        out.append("| " + " | ".join(row) + " |")
    out.append("")
    out.append("## 4. Where each kind of machine observation lands\n")
    out.append("| Observation | Produced by | Lands in |\n|---|---|---|")
    for row in LANDINGS:
        out.append("| " + " | ".join(row) + " |")
    out.append("")
    out.append("## 5. Rules that shape the layout\n")
    out.append("- Identity is the whole-file SHA-256 (`content.digest`); `files` rows are sightings of that content on a volume at a path.\n"
               "- Rows are never deleted: a removal is a `tombstones` row with a state; `pending_purges` and `pending_rows` are the committer's in-flight sets.\n"
               "- Human facts carry `conflict` for two copies that disagree; the app shows the conflict, never picks.\n"
               "- Every machine row carries `provenance` or `source`; `caption_runs` records which model captioned which digest when.\n"
               "- `derived_unverified` is the quarantine for machine facts imported from the old JSON catalog that no engine has re-verified: visible, not trusted.\n"
               "- Schema changes are additive, through a migration (`grdb_migrations`), and Rick approves them.\n")
    return "\n".join(out)


def to_plain_text(markdown: str) -> str:
    text = re.sub(r"`", "", markdown)
    text = re.sub(r"\*\*|\*", "", text)
    lines = []
    for line in text.splitlines():
        if line.startswith("|---"):
            continue
        if line.startswith("|"):
            cells = [c.strip() for c in line.strip("|").split("|")]
            lines.append("  " + "  |  ".join(cells))
        else:
            lines.append(line)
    return "\n".join(lines)


def render_pdf(text: str, pdf_path: Path) -> None:
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as handle:
        handle.write(text)
        source = handle.name
    with pdf_path.open("wb") as out:
        subprocess.run(["cupsfilter", "-i", "text/plain", "-o", "cpi=12", "-o", "lpi=7", "-o", "page-left=36", "-o", "page-right=36", source],
                       stdout=out, stderr=subprocess.DEVNULL, check=True)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--db", default=None, help="catalog path (default: the live catalog, opened read-only and immutable)")
    parser.add_argument("--out", default=None, help="Markdown path (default: docs/design/data_organization_<date>.md)")
    parser.add_argument("--pdf", default=None, help="also render a PDF here (macOS cupsfilter)")
    args = parser.parse_args(argv)
    db_path = Path(args.db).expanduser() if args.db else catalog_db.DEFAULT_DATABASE
    today = datetime.date.today().isoformat()
    version, tables, counts = read_schema(db_path)
    markdown = render_markdown(version, tables, counts, today)
    out = Path(args.out) if args.out else REPO / "docs" / "design" / "data_organization_{}.md".format(today.replace("-", "_"))
    out.write_text(markdown, encoding="utf-8")
    print("wrote {} ({} tables, schema {})".format(out, len(tables), version))
    if args.pdf:
        pdf = Path(args.pdf).expanduser()
        render_pdf(to_plain_text(markdown), pdf)
        print("wrote {}".format(pdf))
    return 0


if __name__ == "__main__":
    sys.exit(main())
