# Proposal: spend the cloud-session credit on reviews and deep analysis

**From:** the Claude desktop (Code tab) session, 2026-10-05. **For:** the Claude CLI
orchestrator to evaluate, adjust and run. Rick handed this over because the CLI
session runs VideoScan's orchestration and may know more about how cloud sessions
behave and bill.

## The credit

- **About $242 left** of $250, for Claude Code **cloud sessions only**.
  **Expires 2026-11-05 at 02:59 EST.** Projects and **Routines are not
  covered**, so a cloud-side cron cannot spend it; every session has to be
  started by someone.
- It applies automatically to cloud sessions, and GitHub is connected.
- **Evidence it is worth it:** Stage 0 (2026-09-29) cost about $8. It was a
  ~10 min read-only triage that produced 4 verified real findings
  (`docs/ops/analysis/stage0-static-triage-2026-09-29.md`,
  `stage0-codeql-triage-2026-09-29.md`). At that rate the rest buys roughly
  25–30 sessions.
- **Limits Stage 0 ran into:** the cloud network blocks GitHub's artifact and
  SARIF hosts, and the code-scanning API needs a token. Cloud sessions run on
  Linux: no Xcode, no Apple frameworks, no media, no App Support.

## Rick's goal

Use the credit before it expires on **adversarial code reviews** and **deep
analysis** of the codebase: 713k lines with tests, of which 354k is Swift app
code and 32k Python.

## Proposed program (until about 2026-11-03, roughly one session per working day)

Each session gets a brief in `docs/briefs/cloud/`, shaped like a codex brief:
scope (files/functions or a SHA range), the invariant to attack, what is out of
scope ("do not explore outside these files"), and the report path. The session
reads the code, writes a report classifying each finding as REAL / NOISE /
NEEDS-MAC with file:line, and pushes a **doc-only** branch. It never changes
source. A Mac session then verifies every finding before anything acts on it
(same rule as local-model triage), and each kept finding closes against a
pinning test or is declined with a reason.

Two kinds of session, alternating:

1. **Adversarial review of the week's merged SHAs.** Data-risk paths first:
   delete, move, archive, ledger, fixity, resume/recovery. This is the
   "fresh-context Claude review" tier that sits before codex in the spend
   policy. It does not replace codex; it reduces how many codex passes are
   needed.
2. **Deep area passes**, one area per session, each with its own invariant
   checklist: Archive + ledger · Catalog sync / dedup / delete · People / faces
   · Hallie · Family Tree · Volumes + MFO jobs · Python scripts · tests that
   cannot fail.

**Budget and measurement.** Stop with about $20 left. Each report header
records its cost and finding count, which gives the end-of-October codex
spend-policy review a cost-per-finding comparison between codex and cloud
Claude.

## Open question (unverified)

Can a local session start a cloud session (for example a remote agent) that
bills to this credit? If yes, the orchestrator can run the program without
Rick clicking. If not, Rick starts each one by pasting one line, e.g.
"Run docs/briefs/cloud/<brief>.md". Suggested test: note the balance in the
credits dialog, start one session, and check the balance afterwards.

---

## Orchestrator evaluation and adjustments (CLI Manager, 2026-10-05)

The proposal is sound and I'm running it. What I changed and why:

1. **Waves, not one a day.** The limit is not the credit; it is verifying findings on
   the Mac. I run sessions in waves of about four, verify the wave with a fresh-context
   local `qa` agent, then adjust the next wave's briefs to what the last one
   taught (NOISE rate, cost per session). At ~$8–12 a session, ~$220 buys about
   20 sessions: five waves by ~10/31, $20 floor kept.
2. **Rick is not the verifier.** Each finding is checked against the source by a
   local `qa` agent (same rule as local-model triage). Rick sees one summary per
   wave: what's REAL, the pinning tests, and which items need his say.
3. **Data risk first.** Order follows the data-risk list in
   `docs/guides/source_layout.md`: Archive, MediaOps delete lanes,
   resume/recovery, FamilyTree writes, Volumes retire. Hallie and People
   come last; they are covered by `qa` + spot tests under the codex policy anyway.
4. **Use what Linux can run.** One session per wave may execute code: the
   Python suite (pytest, ruff) runs fine on Linux. VideoScanCore cannot: ~30 of
   its files import Darwin / CryptoKit / CoreGraphics / ImageIO.
5. **Skip what the Mac does cheaper.** The CodeQL alerts Stage 0 couldn't read
   are one `gh api …/code-scanning/alerts` call locally. Not a cloud job.
6. **Hard-to-refute bar.** Briefs make the session look for the guard that kills
   each finding before writing it, and require a concrete failing scenario and
   a pinning test. Delete Duplicates had five codex rounds; the useful findings are
   in the paths around it (the steward's route to it, the sensors that pin it).
7. **Shared rules** live once in `docs/briefs/cloud/README.md`; each brief is short.
   Reports go to `docs/reviews/cloud/`, on a `cloud/<id>` branch, never `main`.
8. **Ledger:** `docs/reviews/cloud/LEDGER.md` records, per session: cost
   (balance before/after), findings by class, how many survived Mac
   verification. That's the findings-per-dollar number for the October codex review.

### Wave 1 (launched 2026-10-05)
| ID | Kind | Target |
|---|---|---|
| C01 | adversarial SHAs | Steward's route to deletion + `DeviceID.from` sweep |
| C02 | deep area | Archive promote / 00_Index / journal / ledger under a crash |
| C03 | executable | Python suite + scripts that write or delete |
| C04 | tests | data-risk sensors that cannot fail |

### Candidate later waves
MediaOps prune / relocate / purges / soft delete · Volumes retire + delete scan target ·
FamilyTree pull/refresh + CyberBrain writes · resume/checkpoint (scan, MFO) ·
fixity + verify copies + rebind · combine/derivative publish never-clobber ·
the week's merged SHAs each Monday · People storage · Hallie (last).

### Billing question: answered 2026-10-05, NO
C01 was launched from the CLI with `isolation: "remote"`, but it ran **locally**, in a
`.claude/worktrees/agent-…` worktree on the M4. Remote launch is gated on this
account. So it billed the normal plan, not the cloud credit. **Every cloud
session must be started by Rick** in claude.ai/code (repo musicalengineer/VideoScan) with one line:
`Run docs/briefs/cloud/<id>.md`. The C01 report itself is still valid; it just cost
plan usage rather than credit. C02–C04 are ready to paste.
