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
      "backup_attestations", "events", "event_members", "event_decisions", "footage_decisions", "provenance_roles", "public_marks",
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
    version, detail, counts, _ = read_schema_detail(db_path)
    return version, {t: [c[0] for c in cols] for t, cols in detail.items()}, counts


def read_schema_detail(db_path: Path):
    """(schema version, {table: [(column, type, is_pk)]}, {table: rows}, [(child, child_col, parent, parent_col)])."""
    con = catalog_db.connect(db_path)          # READ-ONLY (mode=ro + query_only): the one door scripts use
    try:
        version = con.execute("select schema_version from catalog_state").fetchone()[0]
        names = [r[0] for r in con.execute("select name from sqlite_master where type='table' and name not like 'sqlite_%' order by name")]
        detail = {t: [(c[1], c[2] or "", bool(c[5])) for c in con.execute('pragma table_info("{}")'.format(t))] for t in names}
        counts = {t: con.execute('select count(*) from "{}"'.format(t)).fetchone()[0] for t in names}
        links = []
        for t in names:
            for fk in con.execute('pragma foreign_key_list("{}")'.format(t)):
                links.append((t, fk[3], fk[2], fk[4] or ""))
    finally:
        con.close()
    return int(version), detail, counts, links


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


GEN_START = "<!-- generated by tools/data_organization.py: start (hand-written text goes ABOVE this line) -->"
GEN_END = "<!-- generated by tools/data_organization.py: end -->"


def write_generated_section(path: Path, generated: str) -> None:
    """Rick writes the file-locations map by hand in this same file (2026-10-31); the tool
    only replaces the part between its markers, so a regeneration never clobbers his text.
    A file without markers gets the generated part appended below whatever is there."""
    body = "{}\n{}\n{}\n".format(GEN_START, generated.split("\n", 1)[1] if generated.startswith("# ") else generated, GEN_END)
    if path.is_file():
        text = path.read_text(encoding="utf-8")
        if GEN_START in text and GEN_END in text:
            head, rest = text.split(GEN_START, 1)
            _, tail = rest.split(GEN_END, 1)
            path.write_text(head + body + tail, encoding="utf-8")
            return
        path.write_text(text.rstrip("\n") + "\n\n" + body, encoding="utf-8")
        return
    path.write_text(generated.split("\n", 1)[0] + "\n\n" + body, encoding="utf-8")


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


def render_pdf(html: str, pdf_path: Path) -> None:
    """The diagram page as a PDF — page 1 the blobs, page 2 every table (Rick: "page 1 should
    show the blobs then page two a list of data"). WebKit does the rendering
    (tools/html_to_pdf.swift, one PDF per .page), pypdf stitches them. No Chrome, no installs."""
    from pypdf import PdfReader, PdfWriter
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp) / "diagram.html"
        source.write_text(html, encoding="utf-8")
        prefix = Path(tmp) / "page"
        subprocess.run(["swift", str(REPO / "tools" / "html_to_pdf.swift"), str(source), str(prefix), "1300"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=180)
        writer = PdfWriter()
        for part in sorted(Path(tmp).glob("page-*.pdf"), key=lambda f: int(f.stem.split("-")[1])):
            for page in PdfReader(str(part)).pages:
                writer.add_page(page)
        with pdf_path.open("wb") as out:
            writer.write(out)


GROUP_COLOURS = ["#2f6fb3", "#3b8f5a", "#7a4fa8", "#b07a1f", "#6b7280"]   # identity, decisions, observations, search, bookkeeping


def render_erd(version: int, detail, counts, links, today: str) -> str:
    """One self-contained HTML page: an entity diagram of the catalog — boxes per table
    (columns, types, key marks), five colour groups, foreign-key lines, hover to light a
    table's links. Schema only: table names, columns, counts. No family data."""
    import html as H
    groups = [(title.split(" — ")[0], [t for t in ts if t in detail]) for title, ts in GROUPS]
    placed = {t for _, ts in groups for t in ts}
    left = [t for t in detail if t not in placed]
    if left:
        groups.append(("F. Not yet classified", left))
    fk_cols = {(c, cc) for c, cc, _, _ in links}
    col_w, gap_x, pad, row_h, head_h, gap_y, top = 300, 60, 40, 15, 26, 28, 70
    pos = {}
    x = pad
    max_h = 0
    for gi, (title, ts) in enumerate(groups):
        y = top
        for t in sorted(ts, key=lambda n: -counts[n]):
            n = len(detail[t])
            h = head_h + row_h * n + 8
            pos[t] = (x, y, col_w, h, gi)
            y += h + gap_y
        max_h = max(max_h, y)
        x += col_w + gap_x
    width, height = x + pad, max_h + pad
    parts = ['<svg xmlns="http://www.w3.org/2000/svg" width="{}" height="{}" viewBox="0 0 {} {}" font-family="-apple-system, system-ui, sans-serif" font-size="11">'.format(width, height, width, height)]
    for gi, (title, ts) in enumerate(groups):
        gx = pad + gi * (col_w + gap_x)
        parts.append('<text x="{}" y="{}" font-size="15" font-weight="700" fill="{}">{}</text>'.format(gx, top - 30, GROUP_COLOURS[gi % 5], H.escape(title)))
        parts.append('<text x="{}" y="{}" font-size="11" fill="#9aa4b2">{} tables</text>'.format(gx, top - 14, len(ts)))
    # edges first (under the boxes)
    for child, ccol, parent, pcol in links:
        if child not in pos or parent not in pos:
            continue
        cx, cy, cw, ch, cg = pos[child]
        px, py, pw, ph, pg = pos[parent]
        ci = next((i for i, c in enumerate(detail[child]) if c[0] == ccol), 0)
        pi = next((i for i, c in enumerate(detail[parent]) if c[0] == pcol), 0)
        y1 = cy + head_h + row_h * ci + row_h / 2
        y2 = py + head_h + row_h * pi + row_h / 2
        if px > cx:
            x1, x2 = cx + cw, px
        elif px < cx:
            x1, x2 = cx, px + pw
        else:
            x1, x2 = cx + cw, px + pw
            parts.append('<path class="edge e-{} e-{}" d="M{} {} C{} {} {} {} {} {}" fill="none" stroke="{}" stroke-width="1.2" opacity="0.45"/>'.format(
                child, parent, x1, y1, x1 + 40, y1, x2 + 40, y2, x2, y2, GROUP_COLOURS[pg % 5]))
            continue
        mx = (x1 + x2) / 2
        parts.append('<path class="edge e-{} e-{}" d="M{} {} C{} {} {} {} {} {}" fill="none" stroke="{}" stroke-width="1.2" opacity="0.45"/>'.format(
            child, parent, x1, y1, mx, y1, mx, y2, x2, y2, GROUP_COLOURS[pg % 5]))
    for t, (x, y, w, h, gi) in pos.items():
        colour = GROUP_COLOURS[gi % 5]
        parts.append('<g class="table" data-t="{}">'.format(t))
        parts.append('<rect x="{}" y="{}" width="{}" height="{}" rx="7" fill="#161b22" stroke="{}" stroke-width="1.5"/>'.format(x, y, w, h, colour))
        parts.append('<rect x="{}" y="{}" width="{}" height="{}" rx="7" fill="{}"/>'.format(x, y, w, head_h, colour))
        parts.append('<text x="{}" y="{}" fill="#fff" font-weight="700" font-size="12">{}</text>'.format(x + 8, y + 17, H.escape(t)))
        parts.append('<text x="{}" y="{}" fill="#e6edf3" font-size="10" text-anchor="end" opacity="0.85">{:,} rows</text>'.format(x + w - 8, y + 17, counts[t]))
        for i, (c, ty, pk) in enumerate(detail[t]):
            yy = y + head_h + row_h * (i + 1) - 4
            mark = "PK" if pk else ("FK" if (t, c) in fk_cols else "")
            parts.append('<text x="{}" y="{}" fill="{}" font-size="9" font-weight="700">{}</text>'.format(x + 6, yy, "#f0b429" if pk else "#8ab4f8", mark))
            parts.append('<text x="{}" y="{}" fill="#e6edf3">{}</text>'.format(x + 26, yy, H.escape(c)))
            parts.append('<text x="{}" y="{}" fill="#9aa4b2" text-anchor="end" font-size="10">{}</text>'.format(x + w - 8, yy, H.escape(ty.lower())))
        parts.append('</g>')
    parts.append('</svg>')
    svg = "\n".join(parts)
    legend = " · ".join('<span style="color:{}">■ {}</span>'.format(GROUP_COLOURS[i % 5], H.escape(title)) for i, (title, _) in enumerate(groups))
    group_counts = {title: (len(ts), sum(counts[t] for t in ts)) for title, ts in groups}
    overview = render_overview(group_counts, len(links))
    css = ("body{margin:0;background:#0d1117;color:#e6edf3;font:14px -apple-system,system-ui,sans-serif}"
           "header{position:sticky;top:0;background:#0d1117;border-bottom:1px solid #30363d;padding:12px 20px;z-index:2}"
           "header b{font-size:18px} .lg{color:#9aa4b2;margin-top:4px} .wrap{overflow:auto;padding:10px 20px}"
           ".tabs{margin-top:8px} .tabs button{font:inherit;font-weight:600;padding:6px 14px;border-radius:7px;border:1px solid #30363d;background:#161b22;color:#e6edf3;cursor:pointer;margin-right:6px}"
           ".tabs button.on{border-color:#58a6ff;outline:2px solid #58a6ff33} .page{display:none} .page.on{display:block}"
           ".table{cursor:pointer} .table.dim{opacity:.25} .edge.dim{opacity:.06} .edge.hot{opacity:1;stroke-width:2.5}"
           "@media print{body{background:#fff;color:#111} header{position:static;border:0} .tabs{display:none} .page{display:block}"
           " #p2{page-break-before:always} .wrap{overflow:visible} svg text{fill:#111} .lg{color:#444} rect[fill='#161b22']{fill:#fff}}")
    js = ('const ts=[...document.querySelectorAll(".table")],es=[...document.querySelectorAll(".edge")];'
          'ts.forEach(g=>{g.onmouseenter=()=>{const t=g.dataset.t;const near=new Set([t]);es.forEach(e=>{if(e.classList.contains("e-"+t)){e.classList.add("hot");[...e.classList].filter(c=>c.startsWith("e-")).forEach(c=>near.add(c.slice(2)))}else e.classList.add("dim")});'
          'ts.forEach(o=>{if(!near.has(o.dataset.t))o.classList.add("dim")})};g.onmouseleave=()=>{es.forEach(e=>e.classList.remove("hot","dim"));ts.forEach(o=>o.classList.remove("dim"))}});'
          'document.querySelectorAll(".tabs button").forEach(b=>b.onclick=()=>{document.querySelectorAll(".tabs button").forEach(x=>x.classList.toggle("on",x===b));document.querySelectorAll(".page").forEach(p=>p.classList.toggle("on",p.id===b.dataset.p))});')
    head = ('<!doctype html><html lang="en"><head><meta charset="utf-8"><title>VideoScan catalog — how the data is organized</title>'
            '<style>' + css + '</style></head><body><header><b>VideoScan — how the data is organized</b> &nbsp; schema ' + str(version)
            + ' · ' + str(len(detail)) + ' tables · ' + str(len(links)) + ' foreign keys · ' + H.escape(today)
            + '<div class="lg">' + legend + ' &nbsp;·&nbsp; schema only, no family data</div>'
            '<div class="tabs"><button class="on" data-p="p1">Page 1 — the big picture</button><button data-p="p2">Page 2 — every table</button></div></header>')
    page1 = '<div class="page on" id="p1"><div class="wrap">' + overview + '</div></div>'
    page2 = ('<div class="page" id="p2"><div class="wrap"><div class="lg" style="margin-bottom:8px">PK primary key · FK foreign key · hover a table to light its links</div>'
             + svg + '</div></div>')
    return head + page1 + page2 + '<script>' + js + '</script></body></html>'


def render_overview(group_counts, n_links: int) -> str:
    """Page 1: the blobs. Three homes and the roads between them; the five groups inside the catalog."""
    import html as H
    W, Hh = 1180, 640
    g = []
    g.append('<svg xmlns="http://www.w3.org/2000/svg" width="{}" height="{}" viewBox="0 0 {} {}" font-family="-apple-system, system-ui, sans-serif" font-size="13">'.format(W, Hh, W, Hh))
    def blob(x, y, w, h, colour, title, lines, big=False):
        g.append('<rect x="{}" y="{}" width="{}" height="{}" rx="16" fill="{}22" stroke="{}" stroke-width="2"/>'.format(x, y, w, h, colour, colour))
        g.append('<text x="{}" y="{}" font-size="{}" font-weight="700" fill="{}">{}</text>'.format(x + 16, y + 28, 18 if big else 15, colour, H.escape(title)))
        for i, l in enumerate(lines):
            g.append('<text x="{}" y="{}" fill="#e6edf3" font-size="12">{}</text>'.format(x + 16, y + 52 + 18 * i, H.escape(l)))
    def arrow(x1, y1, x2, y2, label, colour="#9aa4b2"):
        g.append('<path d="M{} {} C{} {} {} {} {} {}" fill="none" stroke="{}" stroke-width="2" marker-end="url(#ah)"/>'.format(x1, y1, (x1 + x2) / 2, y1, (x1 + x2) / 2, y2, x2, y2, colour))
        g.append('<text x="{}" y="{}" fill="{}" font-size="11" text-anchor="middle">{}</text>'.format((x1 + x2) / 2, (y1 + y2) / 2 - 6, colour, H.escape(label)))
    g.append('<defs><marker id="ah" markerWidth="10" markerHeight="10" refX="9" refY="5" orient="auto"><path d="M0 0 L10 5 L0 10 z" fill="#9aa4b2"/></marker></defs>')
    # the catalog: the truth, with its five groups inside
    blob(400, 40, 420, 560, "#58a6ff", catalog_db.DATABASE_FILE_NAME + " — the truth (one committer, fixity, backups, rows never deleted)", [], big=True)
    inner = [("A. Identity", GROUP_COLOURS[0], "what a file IS: content (SHA-256), files (sightings on volumes), tombstones"),
             ("B. Rick's decisions", GROUP_COLOURS[1], "user dates / places / notes, stars, people tags, events, archive — highest rank"),
             ("C. Machine observations", GROUP_COLOURS[2], "captions, transcripts, inferred dates, dossiers, prints, likeness, duplicates"),
             ("D. Search", GROUP_COLOURS[3], "full-text index over captions and transcripts"),
             ("E. Bookkeeping", GROUP_COLOURS[4], "generations, the ledger, imports, audits, job markers")]
    y = 90
    for i, (title, colour, words) in enumerate(inner):
        key = next((k for k in group_counts if k.startswith(title[:2])), None)
        n, rows = group_counts.get(key, (0, 0))
        blob(420, y, 380, 86, colour, "{}  ·  {} tables · {:,} rows".format(title, n, rows), [words[:70], words[70:140]] if len(words) > 70 else [words])
        y += 100
    # left: sources of facts
    blob(40, 60, 300, 150, "#3b8f5a", "Rick", ["decisions typed in the app:", "dates, places, people, events, archive, stars.", "Always outrank a machine observation."])
    blob(40, 250, 300, 170, "#7a4fa8", "Engines and models (the helper)", ["captioner (8B), Whisper, era contract, prints,", "fingerprint matching, integrity checks.", "Writes a JOURNAL, never the catalog."])
    blob(40, 460, 300, 140, "#b07a1f", "Media files + volumes", ["the footage itself, probed read-only:", "container, codecs, dates, DV datecode."])
    # right: sidecars and scratch
    blob(880, 60, 270, 230, "#7a4fa8", "Sidecar stores (bulk, regenerable)", ["audio-fingerprints.sqlite — landmarks", "model-lab.sqlite — every raw model", "   output, segments, vectors (append-only)", "metadata_cache.sqlite — ffprobe cache", "   (keyed by path + size + mtime)"])
    blob(880, 330, 270, 130, "#6b7280", "Helper files (in transit)", ["background/queue — job requests", "background/checkpoints — last unit done", "background/journal/*.jsonl — facts to apply"])
    blob(880, 500, 270, 100, "#6b7280", ".scratch/ (lab bench, thrown away)", ["bench runs, frames, review verdicts", "never in git, never a source of truth"])
    arrow(340, 135, 400, 160, "commit door")
    arrow(340, 335, 880, 395, "writes", "#7a4fa8")
    arrow(880, 440, 820, 330, "committer applies the journal", "#7a4fa8")
    arrow(340, 310, 880, 170, "bulk outputs", "#7a4fa8")
    arrow(340, 530, 400, 150, "scan, hash, probe")
    arrow(880, 180, 820, 300, "app reads directly", "#9aa4b2")
    g.append('<text x="{}" y="{}" fill="#9aa4b2" font-size="12">A decision always outranks an observation. An observation never supports the inference that produced it. {} foreign keys tie the tables to content and files.</text>'.format(40, Hh - 14, n_links))
    g.append('</svg>')
    return "\n".join(g)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--db", default=None, help="catalog path (default: the live catalog, opened read-only and immutable)")
    parser.add_argument("--out", default=None, help="Markdown path (default: docs/design/data_organization_<date>.md)")
    parser.add_argument("--pdf", default=None, help="also render the diagram as a PDF here (page 1 blobs, page 2 tables; WebKit)")
    parser.add_argument("--erd", default=None, help="also write an entity diagram (self-contained HTML + SVG) here")
    args = parser.parse_args(argv)
    db_path = Path(args.db).expanduser() if args.db else catalog_db.DEFAULT_DATABASE
    today = datetime.date.today().isoformat()
    version, tables, counts = read_schema(db_path)
    markdown = render_markdown(version, tables, counts, today)
    out = Path(args.out) if args.out else REPO / "docs" / "design" / "data_organization_{}.md".format(today.replace("-", "_"))
    write_generated_section(out, markdown)
    print("wrote {} ({} tables, schema {})".format(out, len(tables), version))
    if args.pdf or args.erd:
        _, detail, counts2, links = read_schema_detail(db_path)
        html = render_erd(version, detail, counts2, links, today)
        if args.erd:
            erd = Path(args.erd).expanduser()
            erd.write_text(html, encoding="utf-8")
            print("wrote {} ({} foreign keys)".format(erd, len(links)))
        if args.pdf:
            pdf = Path(args.pdf).expanduser()
            render_pdf(html, pdf)
            print("wrote {}".format(pdf))
    return 0


if __name__ == "__main__":
    sys.exit(main())
