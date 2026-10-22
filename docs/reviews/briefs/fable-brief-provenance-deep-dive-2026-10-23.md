# Fable brief: provenance deep dive (for 2026-10-23; Rick asked for this)

**Read-only.** Do not edit code, the catalog, or anything under /Volumes. Do not open the live catalog
database; if you need data, ask the Manager for a `.backup` copy. Write one file only: your report at
`docs/research/provenance_deep_dive_2026-10-23.md`.

## The goal (Rick's words)
Every master in the family archive knows its story — which tape it came from, when and how it was
digitized, what kind of copy it is — and VideoScan walks him through **Ingest → Identify → Confirm → Archive**
so that story is captured once. Retroactively, for what's already digitized: **extrapolate** provenance from
metadata → **identify / correlate / confirm** → **archive**.

## Read first
1. `docs/design/provenance_lightweight_2026_10_22.md` — the Manager's draft (records, workflow, backfill, phases, 4 open questions).
2. `docs/project_goals.md` — Rick's goals.
3. Code facts already gathered (verify, don't re-derive): Promote = `VideoScan/VideoScan/Archive/PromoteToArchiveSheet.swift`,
   `PromoteToArchiveJob.swift`, `PromoteToArchiveJob+Steps.swift`; manifest = `Archive/MasterArchive.swift:170` (v3);
   ledger = `VideoScanCore/Sources/VideoScanCore/MediaLedgerEvent.swift`, `VideoScan/Archive/MediaLedger.swift`;
   per-content user metadata keyed by SHA-256 = `VideoScanCore/.../Store/CatalogDataSchema+Knowledge.swift`;
   schema v12 migrations = `Store/GRDBCatalogRepository.swift:348-407`; field contract =
   `docs/design/catalog_contract_freeze_2026_10_17.md`.

## External sources (cite what you use)
- https://github.com/amiaopensource/open-workflows — especially *Living Will for Home Movies*, vrecord,
  analog-inspection, NYPL / WGBH ingest workflows.
- PBCore (instantiations, generations), PREMIS (events, agents), OAIS PDI (provenance), BagIt, FADGI video
  digitization guidance, BWF CodingHistory as a device-chain precedent.

## Questions to answer
1. **Vocabulary.** Which PBCore/PREMIS terms and controlled values should we borrow verbatim (format names,
   generation/role names, event types) so an archivist reading our sidecar recognises them? Propose the exact lists.
2. **Records.** Critique the three-table draft (carriers, capture_events, file_provenance). What's missing that
   a small archive regrets later (e.g. tape condition, playback deck, TBC on/off, capture software version, operator,
   multiple captures of one tape, one file spanning two tapes)? What should be cut?
3. **The archive copy.** What should `00_Index/Provenance.csv` (or a BagIt-style alternative) contain so the archive
   is understandable with no app — the "living will" test? CSV vs JSON vs PBCore XML, and why.
4. **Workflow.** How do NYPL / WGBH / vrecord stage capture → ingest → QC → archive, and which steps fit a one-person
   family archive? Where exactly should the app require provenance (Promote gate) and where only nudge?
5. **Backfill.** Rules for inferring provenance from what we have (folder names, file birth dates, ffprobe facts:
   codec/frame/rate/field order, MKV tags, probe_extra make/model/encoder, SHA-256 matches to archived Masters).
   What is safe to infer, what must Rick confirm, and how to show the evidence.
6. **Risks.** Anything in the draft that would put existing catalog rows or the archive's existing `00_Index`
   files at risk. (Ground rule: additive tables only; never rewrite the v3 manifest; archived files are read-only.)

## Report shape
≤ 2,000 words. Start with a 5-line summary and a ranked list of changes to the Manager's draft.
Every code claim with file:line; every external claim with a link.
