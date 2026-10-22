# Provenance, lightweight — design draft for Rick's markup (2026-10-22)

**In one sentence (Rick's words):** every master in the archive knows its story —
which tape it came from, when and how it was digitized, and what kind of copy it is —
and the app walks me through Ingest → Identify → Confirm → Archive so that story is
captured once, by me, not reconstructed later.

Borrowed, not adopted: the *shape* of PBCore (one tape, many files, each with a role)
and PREMIS (a dated event log with who/what did it). We implement neither standard in full.

## What exists today (so we don't duplicate it)

- **Event log = the media ledger** (`MediaLedger.swift`, mirrored to `00_Index/media-ledger.jsonl`
  on every Promote). It already records `archived`, `dateSet`, `placeSet`… This is our PREMIS half.
- **Per-content user metadata** is already keyed by SHA-256 (`user_dates`, `user_notes`,
  `workflow_tags`, `people_tags` … in `CatalogDataSchema+Knowledge.swift`). Provenance follows the same rule.
- **Promote** asks for a name and a date only; the manifest (`Archive_Inventory_Manifest.csv`, v3)
  has no source/carrier/role columns.
- **Missing entirely:** tape (carrier), capture event, file role. `tapeName` in `probe_extra` is the Avid
  tape *name*, not a physical-tape record.

## The records (schema v13, additive only)

| Table | Keyed by | Fields | Borrowed from |
|---|---|---|---|
| `carriers` — the physical tape/film/disc | UUID | format (VHS, VHS-C, S-VHS, Hi8, Video8, MiniDV, Betamax, 8mm film, Super 8, audio cassette, other), label text (as written on it), shelf number (what you write on the cassette), condition, notes | PBCore physical instantiation |
| `capture_events` — one digitizing session | UUID → carrier | captured on (date, or range), device chain (one line: "JVC HR-S9911U → TBC → Blackmagic UltraStudio → vrecord FFV1/MKV"), who, notes ("dropouts at 12:40") | PREMIS event + BWF coding history |
| `file_provenance` — one row per content | SHA-256 | role (preservation master · viewing copy · edit · test · born digital · unknown), carrier, capture event, **inferred / confirmed**, evidence (why the app guessed it) | PBCore generation |

Cut on purpose: a separate "asset/work" level. For home video one tape ≈ one asset; the events on it
are already covered by dates, places, people and notes.

**Born-digital files** (iPhone, digital camcorder files) have no tape: role = born digital, and the
"device chain" is the camera make/model already in `probe_extra`.

## The workflow

| Step | Where | What happens |
|---|---|---|
| **Ingest** | scan / import — unchanged, no gate | technical facts + SHA-256, as today |
| **Identify** | Triage ▸ new filter **Needs provenance** (derived, like *Cleaned*) | video files with no confirmed provenance, newest captures first. The app drafts carrier, capture date, role, with the evidence shown |
| **Confirm** | a **Provenance sheet**, grouped by proposed tape | filmstrip for each file (just merged), the drafts, editable; *Confirm tape* marks all its files confirmed. Ledger events `captured`, `provenanceConfirmed` |
| **Archive** | Promote | refuses a file whose role/carrier isn't confirmed — with an **"Archive with provenance unknown"** override that requires a reason and is logged (same pattern as "Promote undated"). Manifest v4 adds `role, carrier_id, carrier_label, carrier_format, captured_on, device_chain`; `00_Index/Carriers.csv` lists the tapes |

## Backfill (the July VHS batch, and the 198 existing Masters)

Same Identify → Confirm path; the drafts just lean on more evidence:

- **carrier**: one per capture folder (`Cape-1993`, `Christmas1994`, `Montana`…), label = folder name until you edit it
- **captured on**: file birth time (Jul 2–17, 2026)
- **format**: FFV1 · 720×480 · 29.97 → "VHS (NTSC)", marked inferred
- **role**: biggest FFV1/MKV in the folder = preservation master; `P216_*`, `_prob4` = test; `.vs.edit` = edit
- **link to the archive**: SHA-256 match to an existing Master → that Master inherits the confirmed provenance

Adding provenance to an **already-archived** Master is adding metadata, not changing its name, date
or bytes — allowed by the archived-is-read-only rule. 🔴 But it means **rewriting manifest rows
in `00_Index`** for those Masters (v3 → v4). That needs your OK; the alternative is a separate
`00_Index/Provenance.csv` keyed by SHA-256 that leaves the v3 manifest untouched.

## Phases

1. Schema v13 + Needs-provenance filter + Provenance sheet + July backfill drafts. *(Rick confirms ~15 tapes.)*
2. Promote gate + manifest v4 (or Provenance.csv) + `Carriers.csv`. Codex pass — this writes the archive index.
3. Capture-time help: "New captures" nudge, a viewing proxy (H.264) made at ingest so big FFV1 files are
   easy to skim and click-to-time playback works in-app.

## References to read before building (Rick found the index, 10/22)

[amiaopensource/open-workflows](https://github.com/amiaopensource/open-workflows) — AMIA's curated list
of A/V archiving workflows (CC0). The entries that matter to us:

- **Living Will for Home Movies** — provenance, ownership and stewardship for exactly our kind of collection.
- **vrecord** — AMIA's open-source analog capture tool (FFV1/MKV + capture log + QCTools report): the model for phase 3.
- **analog-inspection** (sibling repo) — tape inspection templates: what to record about a carrier before capture.
- **Capturing and Archiving MiniDV Tapes on macOS**, **The Video Guide** — device-chain and format vocabulary.
- **NYPL media-ingest / WGBH ingest** — how real archives stage Ingest → Archive.
- **QCTools, MediaConch** — post-capture QC; a later phase, not this one.

## Questions for Rick

1. Manifest: rewrite to v4, or add a separate `Provenance.csv`? *(I lean Provenance.csv: never rewrite the archive's main index for an additive feature.)*
2. Is the role list right? (preservation master · viewing copy · edit · test · born digital · unknown)
3. Should the Promote gate be hard (refuse, override with reason) or soft (warn only) for the first month?
4. Device chain for July: what deck, TBC and capture card/software did you use? One line is enough; it applies to the whole batch.
