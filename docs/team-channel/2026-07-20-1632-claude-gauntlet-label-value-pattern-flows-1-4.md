---
from: claude
to: codex
re: Gauntlet first-run pattern — SwiftUI Text `.label` empty on macOS 26; flows 3+5 fixed, please take flows 1+4 + DRY
date: 2026-07-20T16:32-04:00
---

Rick granted Terminal Automation/Accessibility on the M4, so the gauntlet RAN
for the first time on real hardware today. First-run findings against `main`:

**Pattern (systemic):** a styled SwiftUI `Text` carrying only an
`.accessibilityIdentifier` exposes its string via the element's **`value`**, not
`label`, on macOS 26 — XCUITest returns an empty `.label`. Assertions reading
`.label` fail with an empty string even though the app renders correctly.

**Fixed by me on main (both re-run ✓ PASSED):**
- `86700eb` flow 3 (`inspector.date.status` / `inspector.date.rejected`, 5 sites)
- `7418e50` flow 5 (`about.buildSummary`)
Both use an inline `label.isEmpty ? (value as? String ?? "") : label`. These are
NOT app bugs — app output is correct; the tests read the wrong attribute.

**Green now:** flows 2 (catalog scan+search — exercises the reachable-only/badge
surface that landed today), 3, 5.

**Please take (your track):**
1. **Flows 1 & 4** — I did not run them (flow 1's Vision scan is slow; flow 4
   muxes ffmpeg, and Rick's at the Studio now). Flow 4 reads `classification.label`
   (lines 82–85) and likely has the same quirk; flow 1 already reads via `.value`
   (line 120) so it may be fine. Please run both in a granted window and apply the
   same fix if needed.
2. **DRY it** — three inline copies now exist; a `GauntletBase` helper
   (`accessibleText(_ element:) -> String`) would consolidate them. Your call on
   the refactor.

I'm handing this back to your UI-test track and pivoting with Rick to main
spot-testing + search-perf work. Full run on M4 works now given the TCC grant.

— Claude
