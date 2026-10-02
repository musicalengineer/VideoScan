# Documentation reorganization — September 16, 2026

**Status:** reorganized; awaiting Claude's independent review.
**Source snapshot:** `59ca9468c01e0068501206c63698286c10f4e8b7`.
Rick requested removal of obsolete chatter and completed handoffs, consolidation
by theme, and a final review by Claude.

## What changed

The tracked docs inventory falls from **300 files to 83**: 222 originals
retired and five new guides/index records added. This count includes existing
datasets and the dashboard; they are retained, not treated as expendable prose.

| Retired group | Files | Where useful material now lives |
|---|---:|---|
| July 15–25 Markdown team-channel messages | 145 | [Channel guide](team-channel/README.md); durable design/evaluation material in the theme guides |
| Recognition designs, experiments, research and April handoffs | 32 | [Facial recognition](facial-recognition.md) |
| Hallie overviews, plans and duplicate topic notes | 17 | [Hallie](hallie.md) |
| Archive, promotion, copy, cleanup and volume plans | 19 | [Media archive](media-archive.md) |
| Other superseded assessments, prototype notes and handoffs | 9 | [Development](development.md), [testing](testing.md), and Hallie's settled vitals policy |

The theme guides preserve original filenames and revision provenance. Focused
specs remain when their exact schemas, algorithms, installation provenance or
unresolved evidence would be diluted by a summary. Recent code reviews,
incident evidence, datasets, model artifacts and operational scripts remain.

The [main index](README.md) is now organized by subject. Channel chatter has a
seven-day maximum, with 2–3 days preferred. No scheduled deletion job was added.

## Recovery and historical citations

Every retired original is locally recoverable, byte-for-byte, under:

```text
.trash/docs-cleanup-20260916/docs/<original-relative-path>
.trash/docs-cleanup-20260916/manifest.json
```

The manifest records original path, replacement guide, reason, source commit
and SHA-256. All 222 moved originals were checked against both the source
snapshot and their manifest hashes. `.trash` is ignored and local; it is not
required for recovery from the shared Git history.

For example, inspect an original without modifying the checkout:

```sh
git show 59ca9468c01e0068501206c63698286c10f4e8b7:docs/donna-recipe-v1.md
```

Use the same snapshot for old filenames in source comments, fixture notes,
experiment metadata and historical prose. Those are dated provenance, not
instructions to create new documents at the retired paths. Active Markdown
links and fixture reading guidance were redirected to the owning themes.

### Exact experiment evidence

`docs/poi-cycles/metrics.jsonl` is unchanged. Its `evidence` values name the
original files/anchors. Read those historical paths at the source snapshot:

- [C1 and C4 ledger](https://github.com/musicalengineer/VideoScan/blob/59ca9468c01e0068501206c63698286c10f4e8b7/docs/poi-cycles/ledger.md).
- [C2 formal grade](https://github.com/musicalengineer/VideoScan/blob/59ca9468c01e0068501206c63698286c10f4e8b7/docs/team-channel/2026-07-18-2105-codex-poi-c02-grade-fail-c03.md).
- [C3 formal grade](https://github.com/musicalengineer/VideoScan/blob/59ca9468c01e0068501206c63698286c10f4e8b7/docs/team-channel/2026-07-19-1351-codex-c03-grade-pass.md).
- [C5 formal grade](https://github.com/musicalengineer/VideoScan/blob/59ca9468c01e0068501206c63698286c10f4e8b7/docs/team-channel/2026-07-20-1417-codex-task-result-poi-cycle-5-independent-formal-grade-1a0fc0e6.md).

These pinned links locate historical evidence; they are not a new accuracy
assessment or a claim that old command-line switches still work.

## Team transport and reconstruction boundary

The SQLite mailbox and Engineering Room transcripts were not pruned. The docs
retention rule does not silently apply to those stores.

Engineering Room's `control-plane.mjs` imports Markdown channel files other
than `README.md`. Retiring the old files means a **fresh database no longer
imports those 145 historical messages**. Existing imported rows remain.
Do not put an ordinary summary `.md` in the channel directory: it would be
interpreted as a new message. For deliberate historical reconstruction, use
the old Git snapshot in an isolated checkout/database.

`tools/engineering-room/config/control-plane-reconstruction.json` is unchanged.
Its source paths are provenance strings, not file reads. Its raw-content hash
controls seed deduplication, so rewriting those strings could replay old seed
work. The source comments and fixture provenance that mention retired files
also remain unchanged; no runtime design-document reads were found.

## Validation and Claude review

Documentation checks cover local Markdown link targets, recovery hashes,
retirement scope, whitespace, and unchanged executable/data files. No app,
UI test, media operation or recognition evaluation was launched for this pass.
A pre-existing architecture link to missing `unit_tests.md` now points to
[testing](testing.md).

Claude should review:

1. Whether each theme retained the useful decisions and unresolved contracts;
   compare any doubtful summary with the source snapshot or local manifest.
2. Current versus proposed/historical labels, especially native recipe defaults,
   evaluator any-hit versus confirmed-presence grades, Hallie's invalidated
   two-turn pilot, and archive dry-run-only pruning.
3. Focused specs retained versus consolidated: restore anything whose detailed
   contract is still needed in daily implementation.
4. The intentional fresh-database reconstruction change and pinned historical
   metric evidence above.
5. Current review status: the September 15 directory-durability finding remains
   open; consolidation does not close it or certify a green application suite.
