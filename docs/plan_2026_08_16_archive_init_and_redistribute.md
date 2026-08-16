# Runbook — 2026-08-16: initialize archive → skim catalog → redistribute

Rick's stated goals (8/15 evening): 1) initialize the Master Archive on the
FamilyArchive RAID and promote some files; 2) skim the catalog — delete
junk/dups, retire old catalog data via the Backup menu; 3) redistribute
(migrate) working-set media to the SanDisk. Codex on testing + Hallie Mae.

Precondition: rebuild the app from main first (tonight's catalog-safety
fixes; the old build hashes ~300 MB on the main thread per save).

## 0. Morning check (Claude, before Rick is up ~11:30)
- Full unit suite green on merged main (run started 8/15 21:15, log in scratchpad).
- Overnight feature branch `feature/master-archive` builds, tests green → codex review → merge.
- `scripts/working_set_candidates.py --top-gb 500` report ready (see §3).

## 1. Initialize the Master Archive (Rick + Claude, ~15 min)
1. Volumes window → FamilyArchive → right-click → **Initialize as Master Archive…** (or File ▸ Archive ▸ Initialize Master Archive… → pick `/Volumes/FamilyArchive`).
2. Confirm: creates `Breen_Family_Archive/00_Index/{Archive_Inventory_Manifest.csv, README_Naming_and_Layout.txt}`, `10_Photos/`, `20_Audio/`, `30_Video/`; sets role Archive; adds as scan target.
3. Check the chip: **Master Archive** + **Safe Archive ✓** (RAID-5, reliable, online).
4. Test the negative path first on purpose? No — do it before step 1: right-click a file → Promote → expect *"You need to designate a volume as the master archive."* + button.
5. Promote a handful: the 2005 Rick-and-Matt podcast (dated), a Donna ★★★ clip (dated by OCR), one Undated. Verify: files land in `30_Video/2000-2009/2005/…`, manifest rows appended, inspector shows Master copy ✓ / Reveal, sha256 matches (`shasum -a 256`).

## 2. Skim the catalog (Rick, with the app; Claude watching logs)
Order matters — cheapest, most reversible first:
1. **Backup menu → Back Up Catalog…** (timestamped bundle) — the safety net for everything below.
2. **Retire old catalog data**: the retired-volume cleanup nag / Volumes → RicksBackups + LACIE500(500USB) → delete catalog for target. Expect footer 81,438 → ~8,760. Beachball watch: this is a big in-place mutation + save; tonight's fixes should hold. If it still stalls, that's `saveCatalogNow()` (18 UI callers) — known follow-up.
3. **Delete junk**: Delete Confirmed Junk… (permanent or trash — recommend Trash first pass). Remember TimsGermanVideo: "unplayable" ≠ junk; verify before permanent.
4. **Dups**: re-run duplicate analysis AFTER step 2 (retired shelf drives no longer elect themselves "Keep" — the 8/14 blocker). Byte-verified deletion only (codex-hardened tonight, c9eb3027/6d973f36/c16d937a).
5. Back up again.

## 3. Redistribute to SanDisk (Rick decides scope; Claude runs Migrate)
No search telemetry exists yet, so "frequently used" is approximated from catalog signals: ★≥2, confirmed people tags, POI/Find-and-Tag hits, dossier-processed, notes present, reachable and not junk. `scripts/working_set_candidates.py` (read-only on catalog.json) ranks and totals GB per source volume so the migration can be sized to the SanDisk.
- Follow-up feature (cheap, honest signal from tomorrow on): stamp `lastAccessedAt`/`accessCount` on preview/play/reveal so next time this is measured, not guessed.
- Migration = existing **Migrate** (Relocate queue) per source root → SanDisk; provenance recorded as relocate journey events; Projects (RAID reserve) as temp if needed.

## 4. Open decisions to confirm with Rick tomorrow
- Promote ⇒ ★★★ (taken: yes). Copy-not-move (taken: yes). Warn-not-block on undated (taken).
- Which SanDisk/Crucial gets what: working set vs. overflow.
- #380 fail-open/closed; #367 POI-vs-GEDCOM.
