# VideoScan

macOS app (Swift 6 language mode throughout — Core and app — on the Swift 6.4 toolchain; SwiftUI, macOS 15+) that finds every family media file on every drive, tells the truth about each one, helps Rick date and repair it, promotes the keepers into a read-only archive filed by decade, lets excess copies go safely, knows who is in the footage and how the family is related, and answers plain questions about all of it. Workflow spine: **INGEST → MANAGE → ARCHIVE** (the shape of PBCore/PREMIS at family scale). ~790K lines of Swift, ~14,000 tests, one developer plus agents since March 2026.

Read first: `docs/Purpose-and-Charter.md` (Rick's purpose, workflow and process expectations, in his words), `docs/ARCHITECTURE.md` (how it is built), `docs/STATUS.md` (what is in flight), `docs/PROCESS.md` (how work moves). `docs/DECISIONS.md` is settled; do not relitigate it.

## Who owns what
- **Rick** (director): workflow and UI/UX, checked against Apple HIG and best-in-class apps; product and archival policy; anything irreversible against real data.
- **Claude**: implementation, data models, algorithms, code quality, tests. For module-internal design (schema, algorithms, concurrency, storage) research the domain's best practice, propose with trade-offs, then proceed. Do not ask Rick to pick internals; he weighs in after.
- **Codex**: independent adversarial reviewer for data-risk paths; helps with tests. One command: `tools/codex_review.py`. Scope rules in `docs/PROCESS.md` §Review.

## Hard rules
1. **Integrity first.** A shown fact comes from evidence (stat, SHA-256, fixity, decode), never from a field that was once written. An unverified fact in the UI is a P0.
2. **Never lose media.** Trash, never unlink; prove the surviving copy by full hash at the moment of removal; refuse rather than guess; never auto-delete; the archive volume is protected at one choke point. Rows are never deleted; a removal marker records state.
3. **Archived means fixed.** Only Rick changes an archived name or date, through Update…; background jobs add metadata only.
4. **One engine per action.** A verb may have buttons in several tabs; it has one code path, one proof, one log line.
5. **Long work is an MFO job**: progress, Pause/Stop, START/OUTCOME through the one log sink. Nothing runs silently. No O(records) work in SwiftUI view bodies.
6. **Identity is whole-file SHA-256**, never the path. Writes go through the one commit door; schema changes are additive, through a migration, and Rick approves them.
7. **Every bug fix ships a regression test seen red before the fix** (red/green table in the commit). Severe bugs also get a production-shape test on a `.backup` copy and a seat in the gauntlet regression stage.
8. **Every feature ships tests on five dimensions** where they apply: logic · scale (100k rows + time budget) · media matrix (mp4/h264, mov/prores, mkv/ffv1+pcm, mxf, avi/dv) · isolation (poisoned state) · sensor — plus a **truth** test for anything that shows a fact, and for catalog writers: an edit inside the debounce window, during a write hold, across a role flip, then relaunch.
9. **"Done" means** `scripts/run_sensors.sh` is GREEN, the suites you touched are green, and the counts are quoted (a zero-test run is red; a lane that prints no number is red). Red is fixed now, never left for the nightly. Out-of-scope work becomes an issue, never an edit.
10. **Data-risk code** (`Archive/`, the delete/prune/relocate parts of `MediaOps/`, FamilyTree writers, `ArchiveAngel/Promote/`, volume retire; map in `docs/ARCHITECTURE.md` §Data-risk) follows the `safety-critical` skill and gets a scoped Codex pass before merge.
11. **`~/dev/VideoScan` is Rick's checkout.** Never switch its branch, leave it dirty, or build into its DerivedData. Agents work in a `git worktree` with their own `-derivedDataPath`. Never force-push or rewrite main. Never delete; move to `.trash/`.
12. **No new `extension VideoScanModel`.** New state lives in a feature store behind a seam (`#337`).
13. **Privacy.** No family media or App Support data in git; nothing of living immediate family (pixels, audio) goes to a cloud model.

## Ideas, rulings, state: where they go (not here, not in memory)
- An **idea** → one line in `docs/BACKLOG.md` (or a GH issue labelled `idea`), then back to the task. Rick thinks out loud; parking is the correct response, not a design.
- A **ruling** → one dated line in `docs/DECISIONS.md`.
- **What is in flight / next** → `docs/STATUS.md`, rewritten, never appended.
- A **rule that must survive `/clear`** → a change to this file or `docs/PROCESS.md`, reviewed by Rick. Memory files are not a rulebook.
- **Briefs, research, review transcripts** → `.scratch/` (ignored). A review verdict Rick wants kept goes in `docs/reviews/<area>.md`, overwritten, not multiplied. Design docs are written after Rick says "design it", into `docs/design/`, and retired to `docs/archive/` when built.

## Build and test
- App: `VideoScan/VideoScan.xcodeproj`, scheme `VideoScan` (Debug) / `VideoScan-Release`. Core: `VideoScan/VideoScanCore` (`swift test --package-path <abs>`). Python tooling: `venv/` (3.14), `venv-mlx/`.
- **Debug** for iteration (5–15 s incremental); **Release** for gauntlet, TestDriver, perf, demos, nightly.
- Pre-merge: `scripts/run_sensors.sh --derived-data <your dd>` (~550 tests, ~70 s). Catalog work: `scripts/run_catalog_tests.sh`. Full suite and gauntlet run on the fleet in Rick's away window (`docs/PROCESS.md` §Machines), never on his machine while he works.
- Truth on disk: `~/Library/Application Support/VideoScan/catalog.sqlite` (one committer; copy it only with sqlite `.backup`). Logs: `~/Library/Logs/VideoScan/{videoscan,catalog}.log`.
- ffmpeg/ffprobe from Homebrew (`Brewfile`). Dev bring-up on a clean Mac: `scripts/install_dev_tools.sh`.

## Command shape (every permission prompt interrupts Rick)
The matcher reads the command's first token. Never `cd X && …`; never lead with `VAR=`, `for`/`if`/`while`/`until`, `time`, `sleep`, `date;`, or a subshell. Use `git -C <path>`, `xcodebuild -project <abs> -derivedDataPath <abs>`, `swift test --package-path <abs>`, or one `python3 - <<'PY'` heredoc. Never pipe a build or test into `tail`/`head` (it masks the exit status; redirect to a log). Prefer Read/Grep/Glob over cat/grep/find. A prompt means an allowlist gap: add the pattern to `.claude/settings.json`; `deny` outranks `allow`. Never `pkill`/`kill` a process on Rick's machines without asking.

## Working with Rick
Direct and terse; push back when he is wrong; one question at a time; 🔴 at the top for anything blocking. Give a one-line C++ analogy where a Swift idiom is non-obvious. Rick builds and spot-tests the app himself: say Debug or Release and why. Say what you did, not how hard it was.
**Machine names (Rick, 2026-10-26):** when Rick says **"M5"** he means the **M5 Ultra Mac Studio** (hostname `RicksUltra`, his dev machine from 10/27). "M4" is the M4 Max Studio (`RicksM4`, the headless test host after the move). The M5 Pro MacBook is "the laptop", "M5 Pro" or "M5 MBP" (`ricksm5.local`; scripts still label it `M5`, e.g. `nightly_rota.json`). When writing, say "M5 Ultra" or "M5 Pro", never a bare "M5".
