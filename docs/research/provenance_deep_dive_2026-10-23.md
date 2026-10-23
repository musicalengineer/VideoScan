# Provenance deep dive — review of the lightweight draft (2026-10-23)

Read-only research for Rick: the Manager's draft `docs/design/provenance_lightweight_2026_10_22.md` against the
code, the 2026-10-22 catalog backup (read-only copy) and the brief's sources, folding in Rick's 10/22 rulings
(tape year ± 6 months; tapes mostly originals, kept, shelf-numbered; videographer once per tape; one July capture
setup; every value says who asserted it). Organised under Rick's four lenses. Code claims are file:line.

## Summary

1. The draft's shape is right. Add **capture_setups** (one device chain, many tapes); move shelf number,
   generation, videographer and tape year onto the **carrier**, so Rick answers each once per tape.
2. The draft's rule "FFV1 · 720×480 · 29.97 → VHS" matches **zero** July files: every July capture is 1280×720,
   30 fps, 8-bit bt709, pcm_s32le, `Lavf61.7.100`. Infer the July batch from folder + encoder + birth date.
3. Travelling copy = `00_Index/Provenance.csv` + `Carriers.csv`, **regenerated** from the catalog like the ledger
   mirror (MediaLedger.swift:217, 246); the v3 manifest is never rewritten. CSV, not JSON or PBCore XML.
4. Every field carries its state (`inferred | confirmed | corrected | rejected`); a trigger makes re-proposing a
   rejected value impossible — the bug People tags have today (FamilyTagging.swift:80, :102).
5. Rick's time: **≈ 60 minutes** for all 142 Masters and the July batch when the app drafts per tape and he
   confirms per group (per file: 5–7 hours). Biggest free win: dvrescue's per-frame recording date on the 30 DV
   Masters.

## Ranked changes to the draft

1. **Add `capture_setups`**: name, device chain (EBU R98 shape), software + version, operator, active from/to.
   `capture_events` point at one; July = one setup typed once, one event per tape.
2. **Carrier gains** `shelf_number` (Rick-assigned, on the cassette — the human key), `generation` (default
   `Original`; `Dub`, `Print`, `unknown`), `videographer`, `tape_year` + `year_label` ("1994–95" only when needed),
   `kept`, `inspected_at`, `condition` (short list + notes), `label_text`, `label_photo_digest`.
3. **`provenance_assertions`**, one row per (subject, field, value), with the rejected-veto trigger.
4. **`carrier_spans (digest, carrier_id, capture_event_id, take, range_start_s, range_end_s)`** instead of a carrier
   column: several captures of one tape (Montana: six FFV1 files), one file over two tapes; the `event_members`
   range shape (CatalogDataSchema+Relations.swift:225–226).
5. **`file_provenance`** keeps `role`, `digitized_on`, `first_seen_on`, `superseded_by_digest`. Not "cataloged on":
   `files.catalogued_at` is never populated (CatalogDataSchema.swift:217; 0 of 16,157 rows) and must not be invented;
   use `min(scanned_at)` per digest.
6. **Fix the backfill rules** (§4). **Promote gate** hard on role + carrier-or-born-digital only; override with
   reason like the un-probeable override (PromoteToArchiveSheet.swift:26–28, 54–59); all else nudges.
7. **Ledger kinds** `carrierInspected`, `captured`, `provenanceConfirmed`, `transferSuperseded`, appended at the END
   of `MediaLedgerEvent.Kind` (MediaLedgerEvent.swift:35–88); `ledger.kind` is plain TEXT
   (CatalogDataSchema+Import.swift:341), no migration.
8. **Denormalise `Provenance.csv`** so a cousin reads one line per file. **Cut**: manifest v4, free-text-only
   condition, device chain on capture_events.

## 1. Workflow — Ingest → Identify → Confirm → Archive, and the retroactive path

Every institution runs **inspect → capture → QC → ingest → archive** (NYPL: inspection form, capture recording
`digitizationProcess{playbackDevice, timeBaseCorrector, captureSoftware.version}`, `digitizer.operator`,
`takeNumber`, MediaConch/QCTools; WGBH: inventory → vendor capture with PREMIS event sheets → fixity → QC →
vault). vrecord logs technician, version and dropped frames but **nothing about the deck**: the chain is prose
everywhere, so one typed setup line is the state of the art.

For one person:

| Step | Where | Writes |
|---|---|---|
| **Inspect** (new, once per cassette, 60 s) | Carriers list | `carriers`: shelf, label, format, generation, videographer, condition; ledger `carrierInspected` |
| **Ingest** | scan, unchanged, no gate | facts + SHA-256 |
| **Identify** | Triage ▸ Needs provenance | machine drafts (§4) as `inferred` assertions; capture event from birth time / name clock + the active setup |
| **Confirm** | Provenance sheet, grouped by tape | Confirm tape = every field on it `confirmed` in one click; ledger `captured`, `provenanceConfirmed` |
| **Archive** | Promote | **require** role and carrier-or-born-digital; **nudge** setup, videographer, condition, description; regenerate the `00_Index` CSVs |

Hard from day one: the per-tape confirm makes it cheap. The **retroactive path** is the same Identify → Confirm
with richer evidence (§4), ranked by payoff (§3). A later re-capture (the kept tapes allow a native 10-bit 4:2:2
capture; the July masters are not that) is a second capture event on the same carrier.

**Records (schema v13, additive after v12, GRDBCatalogRepository.swift:400–414)**: `capture_setups`, `carriers`,
`capture_events (carrier, setup, captured_at, take, signal_notes)`, `carrier_spans`, `file_provenance`,
`provenance_assertions`. `knowledge_sources` stays closed (CatalogDataSchema+Knowledge.swift:21–27). No institution supports one file
spanning two tapes (NYPL: one object per bag); allow it in spans, never as `Preservation`.

**Words the records use (verbatim)** — PBCore `instantiationPhysical`: `VHS`, `Hi8`, `Video8`, `Digital8`,
`MiniDV`, `DV`, `Betamax`, `DVD`, `8mm film`, `Super 8mm film`, `Audio cassette` (no `VHS-C`/`S-VHS`; NYPL's
subtype goes in `format_detail`). PBCore `instantiationGenerations`: `Original`, `Dub`, `Duplicate`,
`Preservation`, `Copy: Access`, `Proxy file`, `Master: production` (edit), `Work tapes` (shown "Test") — there is
no "Preservation master". PBCore `dateType`: `created`, `digitized`, `ingested`; relations `Is Format Of`, `Is
Clone Of`, `Is Replaced By`. PREMIS `eventType`: `capture` (PREMIS has no "digitization"), `creation`,
`ingestion`, `fixity check`, `migration`, `deletion`; `eventOutcome` `success | warning | fail`. Device chain in
EBU R98 CodingHistory shape, one line per stage, `key=value`, free text after `T=`:
`A=ANALOGUE,M=stereo,T=<deck>; VHS; SP` / `A=FFV1,F=48000,W=32,T=<capture device>; ffmpeg Lavf61.7.100; 1280x720p30`.

**The archive copy.** Never rewrite the v3 manifest (MasterArchive.swift:21–50, 263–281; append at
PromoteToArchiveJob+Steps.swift:623). Regenerate derived files whole, temp + rename (`MediaLedger.mirrorFile`,
MediaLedger.swift:246), under `ArchiveIndexLock` (MasterArchive.swift:780): `Provenance.csv` (one row per archived
file, tape words inline — columns in §2), `Carriers.csv` (`shelf_number, format, generation, label_text,
tape_year, videographer, kept, condition, inspected_at, captured_on, setup_name, files`), `Provenance_README.txt`
(the Living Will's stewardship page: who shot these, who cares for them, what the family wants). CSV because
the manifest is CSV and Numbers and `grep` read it; PBCore XML is a later export button; BagIt allows a CSV tag
file, but LC itself uses `bag-info.txt` for bookkeeping, and bagging an 8 TB live archive is the wrong tool.

**Capture QC (phase 3, a Promote nudge).** `Cape-1993-archive.mkv` carries the VCR's on-screen display ("12:00AM
THU", "SP", counter) for the whole capture — display left on, fixable only by re-capture; `Cape_Cod_Etc_1994.mkv`
does not. The camcorder's own "JUN 24 1993" stamp is dating evidence. Check: OCR sampled corner frames; text
stable across >80 % of samples with clock/`SP`/`LP`/counter shapes = **deck OSD** → "re-capture with display off";
date-shaped text changing between stretches = **camcorder stamp** → `ocrDate` caption (Knowledge.swift:260). Also
flag a runtime at a round limit (3600 s), black/silent head and tail, PTS gaps.

## 2. UI and representation

**A record shows three lines**: *Event* — one date plus a confidence word, chosen Rick › device clock › camera
clock › tape year ± 6 months › folder year › inferred, and the stretch's description; *Tape* — "Shelf 07 · VHS ·
Cape Cod 1994 · shot by …"; *Ingest* — "digitized 2026-07-05 (July setup) · first seen 2026-07-20". Stretches use
`event_members.range_start_s/end_s` (42 members today, all whole-file).

**Inferred vs confirmed**: inferred values grey italic with a dotted underline and the evidence one click away
("folder Cape-1993 · encoder Lavf61.7.100 · born Jul 2"); confirmed in normal weight; corrected with ✎; rejected
hidden behind a "ruled out" disclosure. The Confirm-tape button turns the whole group normal. Same convention the
inspector already uses for inferred vs user dates (`inferred_dates` beside `user_dates`, Knowledge.swift:58, 385).

**Per-field state** — `provenance_assertions(subject_kind, subject_id, field, value, state, by, at, confidence,
evidence_json)`, states modelled on `people_tags.kind` (Knowledge.swift:135): `inferred` (machine, confidence,
evidence) · `confirmed` · `corrected` (old value kept) · `rejected`. Trigger: `BEFORE INSERT WHEN NEW.state =
'inferred' AND EXISTS (rejected row, same subject, field, value) → RAISE(IGNORE)`, so the veto holds by
construction. Today `VideoScanModel+FamilyTagging.swift:80` and `:102` append detected/suspected names without
reading `rejectedPeople`; the veto exists only on `VideoScanModel+PeopleTags.swift:185`. Display = latest human
row, else inferred.

**`Provenance.csv`** columns: `sha256, archive_relpath, role, role_by, generation, carrier_shelf, carrier_by,
carrier_label, carrier_format, tape_year, year_by, videographer, videographer_by, event_date, event_date_by,
event_description, digitized_on, device_chain, software, operator, take, span_start_s, span_end_s, first_seen_on,
superseded_by, ruled_out` — `_by` is `rick 2026-10-25` or `machine 0.6`; `ruled_out` lists rejected values
("format≠Hi8").

## 3. Assisting the user — answer once, apply to many

Confirm **per tape**, never per file: one tape row carries format, generation, videographer, year and setup for
every span on it. Propagate by digest automatically (24 of 142 Masters have another live copy; 3,398 video
digests do), by footage group as a suggestion (inferred-date sources already say `footage-shared from <id>`), by
tape as a year range. A description typed on one stretch is offered to byte-identical copies and footage
siblings. **Payoff order**: 142 Masters → 1940s–80s archive folders (26 files) → the rest by footage-group size.

| Group | Rick's work | Min |
|---|---|---|
| July setup | one device-chain line | 2 |
| 10 July tapes | shelf, label, year, videographer, generation, pick the master | 15 |
| DV Masters (≈10–15 tapes, grouped by capture date) | shelf, label, videographer; dates from `rdt` | 20 |
| Born digital (≈53) | glance, confirm all | 5 |
| App-made FFV1 + ProRes/DNxHD (41) | role per folder; 16 unrecorded parents | 12 |
| Other (5) | role | 3 |
| **Total** | | **≈57** |

Event descriptions are optional: ~30 s per stretch, ranked by payoff, over weeks.

## 4. Machine-assisted extrapolation

Archive Masters in the backup: 143 rows (142 `import`, 1 `promote`), 142 digests.

| Class | n | Evidence | Safe to infer | Rick confirms |
|---|---|---|---|---|
| DV captures (`dvvideo`; `DV/DVCPRO - NTSC`, `Avid DV25…`) | 30 | 18 have `creation_time` = **capture** date | `MiniDV`, `digitized_on`; shoot date and stretches from dvrescue per-frame `rdt` ("Recorded Date Time") and `rec_start`/`rec_end` | shelf, videographer |
| Born digital (Apple; hevc/h264) | 26 (+27 without make) | `creation_time` = **shot** date | `Original`, event date ("device clock"), no carrier | confirm all |
| July VHS (`Converted_VHS_Tapes_2026/<tape>/`) | 14 Masters, 20 files, 10 folders | folder; `Lavf61.7.100`, 1280×720p30; born Jul 2–18 | carrier per folder, July setup, `digitized_on` | label, year, videographer, which file is master |
| App-made FFV1 (`.vs.preserve`, Angel) | 17 | `lineage` (16 of 18 rows `unrecorded`) | `Preservation` derived; inherit carrier | parent |
| ProRes/DNxHD | 24 | Avid/FCP encoders | `Master: production` | source tape |
| Other | 5 | — | — | role |

Rules (all written as `inferred` with evidence): tape = folder, label = folder name; `tape_year` from a 4-digit
year in path or name (1,725 of 8,399 live video paths), else the ruled first-event year; `YYYY-MM-DD_HH-MM-SS.mkv`
names are the capture clock (Montana); `P216*`, `NV12*`, `_prob*`, `.vs.edit` mark tests/edits **as hints only** —
one `NV12.mkv` is a 19-minute real capture, so longest duration decides; dvrescue `rdt` = event date per stretch
("camera clock", drift warning). **Never infer** generation beyond the default, videographer, condition or
descriptions.

**Superseded transfers — worked example.** `Clip 03.dv` (digest `a7010c01…`): raw DV 720×480/29.97, 3603.6 s,
timecode 00:40:40:00, born 2008-11-13 (iMovie, old Mac Pro), soft VHS-like picture, three byte-identical copies,
none archived, no dates (backup confirms). Its project sibling, captured the same week, is an archived Master
dated 1998 (known). Drafts: `digitized_on` 2008-11-13; setup "2008 Mac Pro, DV camcorder pass-through"; carrier =
unknown analog tape; `tape_year` 1997–99 at 0.3 ("sibling capture session"); role `Original`. Rick's "if we have
a newer re-digitized version, why promote the old one?" is answered by the rule: a transfer is **superseded** only
when (1) same content is **proven** by sound print, perceptual match or `rdt` overlap — never by folder or name;
(2) the newer transfer is better by a stated criterion (native resolution, bit depth, complete runtime, fewer
dropouts); (3) the newer one is confirmed and archived. Here (1) fails: Find Similar Footage grouped Clip 03 only
with its own copies, and contact sheets of both July Cape candidates show none of its scenes (July spans
1984–95). Not superseded; probably the only digital copy of a 1997–99 tape → promote as `Original`, carrier
unknown, override reason logged. When supersession **is** proven: span both files to one carrier (two capture
events), set `superseded_by_digest` + reason, ledger `transferSuperseded`, PBCore `Is Replaced By`. The older file
keeps its row and relationship and becomes an extra-copy candidate for Cleanup under the full-hash rules — never
a provenance-time delete.

## Risks

Manifest v4 breaks the v3 ruling and readers (MasterArchive.swift:281, 803–890) — derived CSVs instead. Tags inside
archived MKVs are forbidden (user-immutable flag, PromoteToArchiveJob+Steps.swift:707) — sidecars only. Back-filling
`files.catalogued_at` violates "unknown stays unknown". `events.kind` is `('event','person','other')`
(CatalogFolderKindSchema.swift:36) — tapes are `carriers`. Ledger `contentKey` may be sampled (MediaLedgerEvent.swift:191)
— spans and assertions key by whole-file SHA-256 only.

## Sources

AMIA open-workflows https://github.com/amiaopensource/open-workflows · Living Will
http://www.centerforhomemovies.org/wp-content/uploads/2017/09/HMLivingWill_form.pdf · vrecord
https://github.com/amiaopensource/vrecord/blob/main/Resources/Documentation/analog_digitization.md ·
analog-inspection https://github.com/amiaopensource/analog-inspection · NYPL ami-metadata
https://github.com/NYPL-Research/ami-metadata · WGBH
https://blog.americanarchive.org/2017/04/12/pbs-newshour-digitization-project-update-ingest-and-digital-preservation-workflows/
· MiniDV on macOS https://leolabs.org/blog/capture-minidv-on-macos · dvrescue schema
https://mediaarea.net/dvrescue/dvrescue.xsd · PBCore generations
https://pbcore.org/pbcore-controlled-vocabularies/instantiationgenerations-vocabulary/ · PBCore physical video
https://pbcore.org/pbcore-controlled-vocabularies/instantiationphysical-video-vocabulary/ · PBCore dateType
https://pbcore.org/pbcore-controlled-vocabularies/datetype-vocabulary/ · PBCore relationType
https://pbcore.org/pbcore-controlled-vocabularies/instantiationrelationtype-vocabulary/ · PREMIS eventType
https://id.loc.gov/vocabulary/preservation/eventType.html · OAIS PDI
https://interparestrust.org/terminology/citations/374 · BagIt https://www.rfc-editor.org/rfc/rfc8493 · LC formats
https://www.loc.gov/preservation/resources/rfs/moving.html · IASA-TC 06 https://www.iasa-web.org/tc06 · EBU R98
https://tech.ebu.ch/docs/r/r098.pdf · MediaConch https://mediaarea.net/MediaConch
