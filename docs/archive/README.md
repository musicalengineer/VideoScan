# Archive — retired documents

Three kinds of retirement live here. Nothing is ever deleted; git has every revision (`git log --follow -- <path>`).

1. **Removed from the tree, 2026-10-23 (context reset).** 335 files; `INDEX-2026-10-reset.md` lists each with the reason, `RETIRED.txt` is the machine-readable list the docs-links guard consults, and `git show pre-reset-2026-10-23:<path>` prints any of them.
2. **Moved into this folder, from 2026-10-31.** Kept readable in place because a core doc, a design doc or source still cites them. One line each below: what it was, why it was retired, when. A file comes back only if its topic becomes live again and the living docs cannot hold it.
3. **Moved into this folder, 2026-11-01 (consolidation to about 25 live files, DECISIONS 2026-11-01).** Each file kept its name under the same area folder; the table at the end gives, per file, what it was and where its surviving content went. `MOVED.txt` is the same list, machine-readable. A few files were one-line stubs from the 10/31 pass; they sit under `stubs/`.

## Moved 2026-10-31 (docs consolidation; Rick: "consolidate and move the rest to archived")

| Now at | Was | Why retired |
|---|---|---|
| `research/video_llm_for_family_media_2026-10-29.md` | `docs/research/` | Research note behind the video-LLM lab; its verdicts (frozen model, structured JSON → assertions, no cloud leg, environment fingerprint as context) are folded into `docs/design/models.md` and the lab design. A one-line stub stays at the old path because `docs/Purpose-and-Charter.md` and `docs/BACKLOG.md` cite it. |
| `research/family_event_learning_review_2026-10-16.md` | `docs/research/` | The 10/16 review of the outside "training guide": the learning ladder and the embedding candidates (Qwen3-VL-Embedding, DINOv3) are in `docs/design/models.md`; the Events direction it endorsed is built. Stub at the old path (`docs/design/video_llm_lab_2026_10_30.md` cites it). |
| `research/family_media_ai_training_guide.pdf` | `docs/research/` | The outside three-page PDF the 10/16 review answered; kept beside it. |
| `research/mylio_photos_technical_comparison_2026-10-16.md` | `docs/research/` | Public-documentation profile of Mylio Photos; the comparison is done (companion for photos, not a replacement). Nothing cites it. |
| `reviews/video_llm_design.md` | `docs/reviews/` | 10/29 review notes for the Fri/Sat deep dive; every open point landed (background service, v14, design doc moved under `design/`) or is a §9 ruling tracked in `docs/STATUS.md`. Stub at the old path (`docs/Purpose-and-Charter.md` cites it). |
| `reviews/dead_code_survey_2026_10_11.md` | `docs/reviews/` | A dated Periphery / unused-symbol measurement; the nightly metrics lane now reports the same numbers. Nothing cites it. |
| `ops/stability_baseline_2026_10_14.md` | `docs/ops/` | The 10/14 stability baseline; superseded by the stability call in `docs/STATUS.md` (2026-10-31), which the file itself said would happen. Nothing cites it. |

## Moved 2026-11-01 (docs consolidation; DECISIONS 2026-11-01, "about 25 live files")

`MOVED.txt` (this folder) is the machine-readable `old -> now` list; the docs-links guard follows it only for DECISIONS, STATUS and archived text, which are kept as written. `git log --follow -- <now at>` shows each file's history through the move.

| Now at | Was | What it was | Where its surviving content went |
|---|---|---|---|
| `practices/invariants/Archive.md` | `docs/practices/invariants/Archive.md` | The nightly adversarial review's invariants, one file per area (8 areas + README), read by `tools/invariants.py`. | Every area verbatim in `docs/practices/invariants.md` (one file; `tools/invariants.py` reads it); parsed identically, pinned by `tests/test_invariants_coverage.py`. |
| `practices/invariants/ArchiveAngelPromote.md` | `docs/practices/invariants/ArchiveAngelPromote.md` | The nightly adversarial review's invariants, one file per area (8 areas + README), read by `tools/invariants.py`. | Every area verbatim in `docs/practices/invariants.md` (one file; `tools/invariants.py` reads it); parsed identically, pinned by `tests/test_invariants_coverage.py`. |
| `practices/invariants/Dates.md` | `docs/practices/invariants/Dates.md` | The nightly adversarial review's invariants, one file per area (8 areas + README), read by `tools/invariants.py`. | Every area verbatim in `docs/practices/invariants.md` (one file; `tools/invariants.py` reads it); parsed identically, pinned by `tests/test_invariants_coverage.py`. |
| `practices/invariants/FamilyTree.md` | `docs/practices/invariants/FamilyTree.md` | The nightly adversarial review's invariants, one file per area (8 areas + README), read by `tools/invariants.py`. | Every area verbatim in `docs/practices/invariants.md` (one file; `tools/invariants.py` reads it); parsed identically, pinned by `tests/test_invariants_coverage.py`. |
| `practices/invariants/Genealogy.md` | `docs/practices/invariants/Genealogy.md` | The nightly adversarial review's invariants, one file per area (8 areas + README), read by `tools/invariants.py`. | Every area verbatim in `docs/practices/invariants.md` (one file; `tools/invariants.py` reads it); parsed identically, pinned by `tests/test_invariants_coverage.py`. |
| `practices/invariants/Hallie.md` | `docs/practices/invariants/Hallie.md` | The nightly adversarial review's invariants, one file per area (8 areas + README), read by `tools/invariants.py`. | Every area verbatim in `docs/practices/invariants.md` (one file; `tools/invariants.py` reads it); parsed identically, pinned by `tests/test_invariants_coverage.py`. |
| `practices/invariants/MediaOps.md` | `docs/practices/invariants/MediaOps.md` | The nightly adversarial review's invariants, one file per area (8 areas + README), read by `tools/invariants.py`. | Every area verbatim in `docs/practices/invariants.md` (one file; `tools/invariants.py` reads it); parsed identically, pinned by `tests/test_invariants_coverage.py`. |
| `practices/invariants/README.md` | `docs/practices/invariants/README.md` | The nightly adversarial review's invariants, one file per area (8 areas + README), read by `tools/invariants.py`. | Every area verbatim in `docs/practices/invariants.md` (one file; `tools/invariants.py` reads it); parsed identically, pinned by `tests/test_invariants_coverage.py`. |
| `practices/invariants/Volumes.md` | `docs/practices/invariants/Volumes.md` | The nightly adversarial review's invariants, one file per area (8 areas + README), read by `tools/invariants.py`. | Every area verbatim in `docs/practices/invariants.md` (one file; `tools/invariants.py` reads it); parsed identically, pinned by `tests/test_invariants_coverage.py`. |
