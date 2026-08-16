# Volume taxonomy — simplification proposal

**Status:** IMPLEMENTED on `feature/volume-role-taxonomy` (2026-08-16; role
names finalized by Rick the same day: Workspace / Backup / Cloud / Master Archive).
Proposed 2026-08-14 (evening, Rick's dinner assignment); small UI pieces
shipped same night; enum change approved by Rick 2026-08-16 and built the
same day. Awaiting codex review + merge.

## Diagnosis (as of 2026-08-14)

Volumes carried **five user-visible dimensions plus three hidden ones**, and
they leaked into each other — the same disease `mediaDisposition` had (see
`project_star_rating_canonical_scheme`):

| Then | Kind | Problem |
|---|---|---|
| `VolumePhase` | workflow progress | Called "Phase" in the catalog table, "Workflow" in the Volumes window |
| `VolumeRole` | intent | Contained `.retired`, which is not an intent — and **retirement was stored twice** (`role == .retired` vs `retiredAt != nil`, free to disagree) |
| `VolumeTrust` | condition | Fine, but shown mixed into the role chips ("Retired, Unreliable") |
| `retiredAt` (+reason, witnesses) | lifecycle event | The *real* retirement record; the backfill guard and the backup nag key on this, not on role |
| `VolumeMediaTech` | fact | Fine; already computes `isRedundant` |
| reachability | fact | Fine |
| `archivalSuitability` | **derived assessment** | Already computes exactly Rick's "safest place" concept — and is never shown |

## Principle

Same as the star-rating decision: **one owner per concern.**
Facts are derived, intent is one user choice, assessments are computed and
*displayed*, lifecycle is an event.

## Final model (implemented)

| Concern | Field | Values | Set by |
|---|---|---|---|
| **Workflow** | `VolumePhase` (UI says "Workflow") | NO CATALOG → Cataloged → Reviewed → Consolidated → Archived | app + user |
| **Role** (intent) | `VolumeRole` | see table below | user (picker) / app (System, Archive) |
| **Condition** | `VolumeTrust` | Unknown / Reliable / Aging / Unreliable | user |
| **Retired** | `retiredAt` alone | badge on any role: "Backup · Retired" | retire flow / migration |
| **Safety** | derived (`destinationPolicy`, `VolumeSafety.isSafe`) | computed | computed |

### `VolumeRole` — final table

| Case | Raw value | Meaning | In role picker? | Set by |
|---|---|---|---|---|
| `unassigned` | `Unassigned` | never classified | yes | user |
| `system` | `System` | the boot volume root (`/`, `/System/Volumes/Data`, `/Volumes/<Boot>` alias) | **no** (display-only) | migration, automatically |
| `workspace` | `Workspace` | **NEW** — everything the user actively uses: source drives, current-time media, scratch, edits, projects (**replaces** both `original` and the interim `working`); default for folder targets inside `~` (e.g. `~/Movies`) | yes | user / migration default |
| `backup` | `Backup` | a copy of something else — the delete/dup-safety role: never elected the Keep over a live file, the preferred place to delete an extra copy from | yes | user |
| `archive` | `Master Archive` | **the ONE Master Archive** (display name was "Archive") | **no** (display-only) | Initialize Master Archive only |
| `cloud` | `Cloud` | the 3-2-1 offsite/cloud leg (**renames** `lta` "Long-Term Archive" / interim `offsite`); icon = cloud | yes | user |
| ~~`original`~~ | ~~`Original`~~ | **MERGED** into `workspace` | — | — |
| ~~`retired`~~ | ~~`Retired`~~ | **REMOVED** — retirement is `retiredAt` on the target | — | — |

`VolumeRole.pickerCases` = `[unassigned, workspace, backup, cloud]`.
Every role picker/menu iterates it — never `allCases`. The Volumes editor
and the Archive sidebar menu show a display-only role for the Master Archive
and the boot volume.

## Migration (one-time, idempotent, additive; runs every launch)

Two layers:

1. **Decode** — `ScanTargetPersistence.applyPersistedRole` is the ONE role
   decoder for both persistence paths (UserDefaults `VideoScan.scanTargetRoles`
   and bundle `VolumeMetadataSnapshot.role`), backed by
   `VolumeRole.decodeLegacy` / `init(legacyRawValue:)`:
   - `"Original"` / `"Working"` → `.workspace`; `"Long-Term Archive"` / `"LTA"` / `"Offsite"` → `.cloud`; `"Archive"` → `.archive`
   - `"Retired"` → `.unassigned` **and** `retiredAt` stamped if nil
     (`lastScannedDate`, else now) with reason
     *"Marked retired before retirement had a date (migrated 2026-08-16)"*;
     an existing real stamp always wins; stamped once
   - unknown string → `.unassigned` + one log line; the target is never dropped
   - `VolumeRole`'s `Codable` init never throws on a role string
2. **Model** — `VideoScanModel.migrateVolumeRoles()` (init, after the Master
   Archive designation is known; again after bundle import):
   - boot volume root → `.system`
   - `.system` or `.unassigned` on a folder inside a home directory → `.workspace`
   - `.archive` on a target that is **not** the designated Master Archive
     (only when one *is* designated) → `pendingRoleReclassifications`, never
     silently renamed; the Volumes window shows a one-time sheet
     ("These volumes were marked Archive; only the Master Archive can be
     Archive now — pick a role for each": Workspace / Backup,
     default Workspace, "Decide later" keeps the queue)
   - with no Master Archive designated, an Archive-role target is left alone
     (it may be the one about to be initialized)

`CatalogScanTarget.isRetired` is `retiredAt != nil` again (the 06d0d809
`|| role == .retired` stopgap is gone). `reinstateVolume` no longer touches
the role. Symlinked folders inside `~/Movies` still resolve to their real
volume for reachability/space (pinned by test, unchanged).

## Safety — one definition

`VolumeSafety { role, trust, isRetired }` is what the witness-safety
resolver returns; `isSafe = !isRetired && trust != .unreliable`. A retired
disk never authorizes a destructive disposition regardless of role (codex
R1-B2). `SafeWitnessInfo`, `DestinationVolumeGroup`, `KnownCopy`,
`WitnessSample`, and the volume-status cache carry `isRetired` alongside
role/trust.

## "Safe Archive" — resolved without a new enum case

Safety is an **assessment, not an intent** — a drive doesn't stay safe by
decree, it stays safe while it is redundant, reliable, and reachable. The
computation exists (`destinationPolicy` / `archivalSuitability`); surfacing
it as a chip is still open:

> role is Master Archive/Cloud **and** mediaTech.isRedundant **and** trust ∈
> {Reliable, Unknown} **and** reachable → chip renders **"Safe Archive ✓"**

## Shipped earlier (no schema changes)

- "Phase" → **"Workflow"** in all user-facing strings (code enum unchanged)
- **Errors column hidden by default**; Show menu gains "Show Errors Column"
- Backup-time retired-volume cleanup nag (`61a87ecb`)

## Still open

1. Surface the Safe Archive chip per the rule above
2. Relabel `VolumeTrust` as "Condition" in UI
