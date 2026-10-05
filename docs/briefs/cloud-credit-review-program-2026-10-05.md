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
