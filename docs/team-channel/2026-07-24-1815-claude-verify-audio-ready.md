# feature/verify-audio ready for Rick's spot-test — schema heads-up

**From:** claude
**Date:** 2026-07-24 ~18:15 ET
**Re:** GH #128 Verify Audio — implemented, tested, QA'd; NOT yet merged

Heads-up before this merges, since you're near VideoRecord with #125 work:

- **VideoRecord gains three additive fields**: `audioVerifyStatus` (""/"ok"/"damaged"),
  `audioVerifyNote`, `audioVerifyDate`. Same additive-Codable pattern as
  tags/userNotes (a769988): decodeIfPresent + encode-only-when-non-empty,
  never-verified records round-trip byte-identical. All five maintenance
  sites updated; byte-identity goldens extended.
- **"Verify Audio" added to `UserNotesMigration.journeyStampVerbs`** (lock-step
  rule from a769988).
- `notes:` field token now also matches `audioVerifyNote`. CatalogSearchIndex
  haystack/persisted version UNTOUCHED (no rebuild on this one).
- Damaged rows: `audioVerifyNote` always begins "Damaged audio — " (sensor
  test pins it) so `notes:damaged` batch-finds them.
- New MFO kind `.rebuildAudio` (RebuildAudioJob: -c:v copy, audio→pcm_s16le,
  `<stem>_RepairedAudio.mov` beside source, catalog insertion w/ provenance).

Pipeline: feature-dev → testing (72 tests) → qa (MERGE AFTER FIXES) →
2 data-safety fixes + 8 more tests → full suite **3167/0 green**.
QA deferred findings filed as #129 (cancel-before-start, shared w/ Balance),
#130 (.vs-partial crash-orphan sweep, repo-wide), #131 (verify-audio follow-ups).

Branch sits at `d890b6f` (worktree .claude/worktrees/verify-audio), awaiting
Rick's spot-test, then ff-merge to main per policy. If #125 work touches
VideoRecord Codable, rebase after this lands to pick up the five-site pattern.

Also FYI: earlier today tags-and-usernotes merged (see 14:30 note) and
JustPatsHouse.mov recovered via lossless m2v+aiff mux to CrucialX10.
