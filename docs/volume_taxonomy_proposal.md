# Volume taxonomy — simplification proposal

**Status:** proposed 2026-08-14 (evening, Rick's dinner assignment). Small
UI pieces shipped same night; the enum change awaits Rick + codex sign-off.

## Diagnosis

Volumes currently carry **five user-visible dimensions plus three hidden
ones**, and they leak into each other — the same disease `mediaDisposition`
had (see `project_star_rating_canonical_scheme`):

| Today | Kind | Problem |
|---|---|---|
| `VolumePhase` | workflow progress | Called "Phase" in the catalog table, "Workflow" in the Volumes window |
| `VolumeRole` | intent | Contains `.retired`, which is not an intent — and **retirement is stored twice** (`role == .retired` vs `retiredAt != nil`, free to disagree) |
| `VolumeTrust` | condition | Fine, but shown mixed into the role chips ("Retired, Unreliable") |
| `retiredAt` (+reason, witnesses) | lifecycle event | The *real* retirement record; the backfill guard and the new backup nag key on this, not on role |
| `VolumeMediaTech` | fact | Fine; already computes `isRedundant` |
| reachability | fact | Fine |
| `archivalSuitability` | **derived assessment** | Already computes exactly Rick's "safest place" concept — and is never shown |

## Principle

Same as the star-rating decision: **one owner per concern.**
Facts are derived, intent is one user choice, assessments are computed and
*displayed*, lifecycle is an event.

## Proposed model

| Concern | Field | Values | Set by |
|---|---|---|---|
| **Workflow** | `VolumePhase` (rename UI only) | NO CATALOG → Cataloged → Reviewed → Consolidated → Archived | app + user |
| **Role** (intent) | `VolumeRole` minus `.retired` | Unassigned / System / Original / Backup / Archive / Long-Term Archive | user |
| **Condition** | `VolumeTrust` | Unknown / Reliable / Aging / Unreliable | user |
| **Retired** | `retiredAt` alone | badge on any role: "Backup · Retired" | retire flow |
| **Safety** | derived | see below | computed |

Migration: one pass maps `role == .retired` → keep the *prior* role if
recoverable else `.unassigned`, and ensures `retiredAt` is set. Additive,
tiny, but it is a schema touch → codex review + Rick approval first.

## "Safe Archive" — Rick's ask, resolved without a new enum case

Safety is an **assessment, not an intent** — a drive doesn't stay safe by
decree, it stays safe while it is redundant, reliable, and reachable. The
computation already exists (`archivalSuitability`). Surface it:

> role is Archive/LTA **and** mediaTech.isRedundant **and** trust ∈
> {Reliable, Unknown} **and** reachable → chip renders **"Safe Archive ✓"**

FamilyArchive (RAID-5, reliable, online) qualifies today. If a member drive
dies or trust drops to Aging, the chip downgrades itself — which is exactly
the honesty you want from the word "safe". A hand-set "Safe Archive" role
would keep saying safe after the hardware stopped being safe.

## Shipped tonight (no schema changes)

- "Phase" → **"Workflow"** in all user-facing strings (code enum unchanged)
- **Errors column hidden by default**; Show menu gains "Show Errors Column"
  (a column toggle that deliberately never filters rows)
- Backup-time retired-volume cleanup nag (earlier commit `61a87ecb`)

## Next (needs sign-off)

1. Remove `.retired` from `VolumeRole` + migration (codex: schema review)
2. Render retirement as a badge from `retiredAt`; stop showing it as a role
3. Surface the Safe Archive chip per the rule above
4. Relabel `VolumeTrust` as "Condition" in UI
