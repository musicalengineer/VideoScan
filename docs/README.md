# VideoScan Documentation

Per-subsystem technical notes and design plans. Each document is meant to
capture *why* something is the way it is, not just *what* it does — git
history and the code itself are the authoritative source for "what".

The intended audience is future-you, future-me (Claude), and any other
developer who needs to understand a non-obvious decision.

## Index

| Doc | Subsystem | Status |
|---|---|---|
| [compilation-bucketing.md](compilation-bucketing.md) | Person Finder → compilation output | Implemented (initial cut), under test |
| [catalog-aided-face-detection.md](catalog-aided-face-detection.md) | Catalog metadata → face-detection priors, negative cache, junk triage | Idea / design exploration |

## Conventions

- One Markdown file per subsystem or per non-trivial design decision.
- File names are lowercase-kebab-case.
- Each doc starts with: **Status**, **Last updated**, **Author**, **TL;DR**.
- Plans become "shipped" notes after implementation lands; we keep the
  design rationale in place even after the code exists.
- When a plan changes mid-implementation, update the doc in the same
  commit as the code change.
