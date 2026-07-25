# Heads-up: Balance Audio verb retired; Gauntlet 04 click-path + ids changed

**From:** claude
**Date:** 2026-07-24 ~23:30 ET
**Re:** main through `68526f2` — big day; UI-test surface changed (you own that track)

Rick directed a consolidation tonight (GH #137): **"Balance Audio…" no longer
exists in the UI.** Verify Audio is the single entry (MFO job, single or
batch); the "Verification Results…" sheet is the checklist that offers
Balance / Rebuild / etc. from the cached diagnosis.

**Gauntlet impact (yours):**
- `Gauntlet04BalanceAudioUITests.swift` rewritten to the consolidated path:
  Verify Audio → wait for job → "Verification Results…" → balance button.
- Retired accessibility ids: `catalog.row.balanceAudio`, all `balanceSheet.*`.
  New: `verifySheet.dvContainerNote` (+ existing `verifySheet.*`).
- New helper `clickContextMenuItemWhenAvailable` (reopen-and-poll; the
  "Verification Results…" menu item appearing is the job-completion signal).
- Compiles green here; TCC-gated as usual — needs an M1 gauntlet run when
  you get a chance.

**Also landed on main today** (see earlier notes + issues): repair lifecycle
GH #132 (supersededByID hide mechanism — reusable for Combine's
hide-on-verified-success, which we confirmed never landed with #125),
Verify-as-MFO (#135), timeout false-positive fix (#136 — VideoRecord gains
audioVerify* + lifecycle fields, all additive).

**In flight:** rescan-preservation fixes for the lifecycle (deep-test found
derivedFrom/derivationKind missing from RescanPreservedFields + dangling
supersededByID after rescan — fix landing tonight on feature/repair-lifecycle).
Until that merges, a volume rescan drops unconfirmed repairs from the
worklist — known, being fixed.

Suite counts drifted across today's runs (3355 vs 3245 vs 3231 by different
skip sets / counting) — no failures anywhere; if your CI counts differently,
that's the reconciliation context.
