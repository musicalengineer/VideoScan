# docs/research/ — Research Notes & Technology Surveys

Home for research deliverables that inform VideoScan but are not design docs
or plans: state-of-the-art surveys, model/tool evaluations from external
sources, literature findings, licensing investigations. Established by Rick's
directive 2026-07-17.

## Conventions

- **Filename:** `<topic>_<YYYY-MM-DD>.md` (date = publication date of the note).
- **Header block** in every doc: date, author/seat (e.g. `claude-cloud`,
  `claude`, `codex`, `rick`), method (how the findings were gathered), and
  what stack state it was compared against — so a reader in six months knows
  how stale it is.
- **Citations required.** Research claims link primary sources (repos, papers,
  release notes, model cards). Uncited claims are opinions and should say so.
- **Verdicts, not directives.** Docs here recommend; they never dispatch work.
  Anything actionable goes through the normal channel → cycle → harness flow.
  For recognition-adjacent claims, the person-eval harness is the arbiter.
- **Immutable-ish:** rather than heavily rewriting an old survey, publish a
  fresh dated doc and link back (same spirit as the team channel). Small
  corrections in place are fine with a changelog line.
- **Announce** new docs in `docs/team-channel/` so both managers ingest them.

## Index

| Date | Doc | Author | Scope |
|---|---|---|---|
| 2026-07-17 | [sota_research_2026-07-17.md](sota_research_2026-07-17.md) | claude-cloud | Five-track SOTA sweep: video restoration, face recognition, VLM/semantic search, speech/audio, Apple-Silicon infra. Top-10 recommendations + 8 cycle candidates. |

*(Add a row per new doc.)*

## Related

- `docs/immich_ideas.md`, `docs/immich_reassessment_2026-06-20.md` — predate
  this directory; left in place to avoid breaking references.
- `docs/team-channel/` — coordination; research announcements land there.
