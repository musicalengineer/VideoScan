Brief: N1012-R-FamilyTree-writes | Source: main@ebcd2f09 | Wall clock: 40 | Files read: 34
Finding count: 4 (REAL 3 / NEEDS-MAC 1 / NOISE 0)
Verdict: The CyberBrain writer, research dossier, documents list and per-person refresh overlay hold up; the hole is the identity-rulings Hide button, which saves a stale in-memory copy over the rulings file, and the photo "not of" sidecar, which treats a damaged file as empty and saves over it.

Scope note: the working tree is a merge commit (da39a05f) with no content difference from origin/main (ebcd2f09). Read-only review, nothing built, nothing changed. This report is the only file written.

## Findings

### N1012-R-FamilyTree-writes-F1: Hide / Unhide saves the rulings copy loaded at tree-load time, so hand edits and the other window's rulings are overwritten
- **Severity:** P1. These are Rick's hand-curated identity rulings: notes, `verified`, `duplicateOf`, and `local:` keys that only a hand edit can create. The file header calls some of them "weeks" of research.
- **Class:** REAL. Plain Swift and Foundation, nothing that depends on macOS.
- **Symbol:** `FamilyTreeLiveModel.setRecordHidden`, VideoScan/VideoScan/FamilyTree/FamilyTreeLiveModel.swift:2358 (`var updated = identityDecisions` at :2364, `try updated.save(to: directory)` at :2380). The writer underneath is `FamilyIdentityDecisions.save(to:)`, VideoScanCore/.../FamilyIdentityDecisions.swift:255 (`Data.write(.atomic)`, whole-file replace, no backup).
- **Why it is stale:** `identityDecisions` is read from disk only at init (:596), on a tree load (:822/:853) and on a source change (:1264). A tree load runs only when `FamilyTreeView.sourceRevision` (FamilyTreeView.swift:631) changes. That value is built from the archive root, its online state, the identity-mismatch check and the read-only flag. The rulings file is not part of it. Nothing watches the file, and `setRecordHidden` never re-reads it or compares its revision before saving. `loadWithRevision` already computes a SHA-256 revision, but only the shared Hallie cache uses it.
- **Scenario A (one window, the documented workflow).** The code says in three places that "Rick edits this file by hand". The comment at FamilyTreeLiveModel.swift:2400 expects such edits to land while the app is running.
  1. The app is open with rulings {R1, R2} loaded.
  2. Rick opens the rulings file in an editor and adds R3 (for example a `local:` ruling with a note). He saves it.
  3. Back in the Family Tree, he clicks Hide on record X.
  4. `updated` = {R1, R2, X}, and that set is written over the file. R3 is gone, with no backup and no message. The tab keeps showing "saved".
- **Scenario B (two windows).** File ▸ New is still in the menu (VideoScanApp.swift:699 anchors after `.newItem`, so the `WindowGroup(id: "main")` keeps its New Window item). Each new window builds its own `ContentView` and its own `@StateObject FamilyTreeLiveModel` (ContentView.swift:16).
  1. Window 1 hides X. The file is now {…, X}.
  2. Window 2, still holding the copy from before, hides Y. The file becomes {…, Y}, and the ruling for X is erased.
  3. Window 1 still shows X hidden until the next launch, so the loss is invisible.
- **Guards checked:** `identityRulingsUnsaved` only covers the read-only case. The SAVE FIRST ordering (codex #1710) only covers a failed save. Neither one re-reads the file. `FamilyAssetStore` reads the revision but never writes. No lock exists, and none would help here because the stale copy lives in each model.
- **Smallest pinning test** (`FamilyTreeLiveModel` tests with an injected temp originals directory and `.readWrite` access):
  1. Load a tree that has record X (with an FSID) and a rulings file holding {R1}.
  2. Write {R1, R3} to `FamilyIdentityDecisions.fileURL(in: dir)` from the test, without going through the model.
  3. Call `setRecordHidden(true, personID: X)`.
  4. Reload the file and expect it to contain R3. This fails today: the file holds {R1, X}.
  - Variant: two models on the same directory. Hide X in the first, then Y in the second, and expect both on disk.
- **Fix shape (Mac, after Rick's go):** do the read-modify-write against the disk. Re-read with `loadWithRevision` and apply the one change to that copy. Refuse when the file is `"unreadable"`, which also closes N1009-D-Core-F1. Then adopt what was saved as `identityDecisions`.

### N1012-R-FamilyTree-writes-F2: a damaged photo "not of" sidecar is read as empty, and the next exclusion overwrites it
- **Severity:** P2. This is the same class as N1009-D-Core-F1, and the Manager may raise it to P1. Each sidecar holds rulings that a photo does NOT show certain people (who noted it, when, and the caption). Losing them puts the photo back on the wrong person's card.
- **Class:** REAL. Foundation only.
- **Symbol:** `FamilyAssetStore.excludePhoto`, VideoScan/VideoScan/FamilyTree/FamilyAssetStore.swift:1046. The load at :1066–1068 is `(try? Data(contentsOf:)).flatMap { try? decode } ?? PhotoExclusion(notOf: [])`. The save at :1079 is `Data.write(.atomic)` with no backup and no refusal.
- **Writers:** Hallie's photo-caption mode. "That's not X in this photo" goes through `HallieAppTurnCoordinator.excludePhoto` (HallieAppTurnCoordinator.swift:445–450) and `HallieAppTurnCoordinator+PhotoCaption.swift:102`.
- **Scenario:**
  1. A photo's sidecar lists notOf [A, B]. It then fails to decode: a hand edit leaves a trailing comma, a sync tool writes a conflict copy over it, the external volume damages a block, or a date is written with fractional seconds (`.iso8601` rejects those).
  2. The read side (`photoExclusions`, :1022) quietly returns [] as well, so nothing tells Rick.
  3. In a later conversation Rick tells Hallie the photo is not of C. The sidecar is rewritten as notOf [C]. The rulings for A and B are erased for good.
  - The read side also caps the sidecar at 64 KB, but the write side never checks size.
- **Guard looked for:** the caller, the viewer guard and the symlink/directory checks were all checked. None of them refuses an unreadable existing sidecar. Compare `PersonFactOverlayStore.loadForUpdate` and `readDocumentSidecar`, which both refuse in exactly this case.
- **Smallest pinning test** (`FamilyAssetStore` tests, temp root):
  1. Put a verified PNG at `People/P/photo.png`.
  2. Write `"{ not json"` to `exclusionSidecarURL(for: photo)`.
  3. Call `excludePhoto(photo, from: "@I3@")`.
  4. Expect it to throw, or expect the original bytes to survive as a set-aside sibling. Today the file holds only `@I3@`.
- **Fix shape:** the same as the overlay. If the file exists but cannot be read or decoded, set it aside with a `.bad-<ts>` rename and refuse. Publish through `AtomicFilePublish`.

### N1012-R-FamilyTree-writes-F3: lore typed on a search finding is silently dropped when a re-run removes that finding
- **Severity:** P2. Rick's own words are lost. They were never saved, and the pane never says so.
- **Class:** REAL. Model logic only, so it can be tested without a Mac.
- **Symbol:** `ResearchPersonModel.commitLore`, VideoScan/VideoScan/FamilyTree/ResearchPersonSheet.swift:204. The early `return` at :215 when the finding is not on disk, followed by `forgetLoreEdit(id)` at :229. Related: `ResearchPersonModel.run` at :120 does not commit edited drafts, and `ResearchDossier.merge(fresh:)` (ResearchPerson.swift:484) keeps a finding missing from the fresh results only when `holdsRicksWork` is true, which checks the lore ON DISK.
- **Scenario:**
  1. A bare search hit (unreviewed, empty lore on disk) is on screen.
  2. Rick types lore into its field and does not press Return. The draft is in `loreDrafts`/`editedLore` only.
  3. He clicks Run or Run (fresh). The source does not return that hit this time, which web results routinely do.
  4. `merge` drops the finding, because its disk lore is empty, and the row disappears.
  5. Later, Tell Hallie calls `commitLore` for every edited id (:268). The mutate closure finds no finding and returns. `update` sees no change, so `saved == true`, `theirs == nil`, and `forgetLoreEdit` discards the words.
  6. No error and no conflict appear. The log says nothing.
- **Guard looked for:** I checked the lore compare-and-swap (`loreBase`), the conflict path, and the rule that drafts follow the disk. All of them assume the finding still exists, and none commits before a run.
- **Smallest pinning test** (`ResearchPersonTests`, stub source):
  1. Run once with the source returning finding F, then call `editLore("words", for: F.id)`.
  2. Switch the stub to return nothing, then call `run()` and wait for it.
  3. Call `tellHallie()`.
  4. Expect `dossier.json` to contain "words" on F (kept), or `errorMessage != nil` with the draft still held. Today neither holds.
- **Fix shape:** commit edited drafts at the start of `run`, or make `merge` keep any finding whose id is in `editedLore`. In `commitLore`, a missing finding should be refused with a message, not treated as saved.

### N1012-R-FamilyTree-writes-F4: lore is committed on Return only, so closing the sheet drops the typed text
- **Severity:** P3.
- **Class:** NEEDS-MAC. It depends on whether macOS SwiftUI fires `onSubmit` when a `TextField` loses focus or its sheet is dismissed.
- **Symbol:** `ResearchFindingRow.body`, ResearchPersonSheet.swift:576. Only `.onSubmit(onCommitLore)` is attached. The model doc at :37 says "committed on submit/blur", but no blur hook exists. `ResearchPersonSheet.body` calls `.onDisappear { model.cancel() }` (:368), and `cancel()` does not commit.
- **Scenario:**
  1. Rick types lore into a field.
  2. He clicks Close or presses Esc (`.cancelAction`).
  3. The model is the sheet's `@StateObject` and goes away with it, so the text is gone. The field never showed it as unsaved.
- **Pinning test:**
  1. Unit level: after `editLore` with no submit, a "commit pending drafts on close" call such as `model.closing()` should leave the lore on disk. That method does not exist today, which is the finding.
  2. On the Mac, a UI test types into the field, clicks Close, reopens the sheet and checks that the lore is there.

## Guards checked that held
- **CyberBrainWriter.**
  - Every durable writer (`record` for testimony and captions, both `setPronunciation`s, and `correct` in CyberBrainCorrections.swift:294) runs load, change and save under `withRootLock`. That is one NSLock per root path, with symlinks resolved.
  - `prepareRoot` passes through every loader error except `missingArchive`, so a corrupt archive is never replaced.
  - `save` writes a temp file, fsyncs it, probe-loads it through the strict loader, takes a backup, renames, and fsyncs the directory.
  - An idempotent repeat writes nothing.
  - Cross-process writers (the `hallie --remember` shell) are not coordinated. The comment says this is known and accepted, and the shell writes nothing by default.
- **FamilyTreeLiveModel notes.** `addNote`, `recordTestimony`, `cyberBrainRecorder` and `correctNote` all go through the locked writer. `correctNote` refuses when the row no longer maps to the person it was read for, and it logs START and OUTCOME. The view clears the draft only after a save succeeds (FamilyTreeView.swift:1830–1835), and correction errors are shown (FamilyTreeNoteCorrectionUI.swift:250).
- **ResearchStore.update.** It takes a per-key lock, re-reads from disk, refuses when `loadDossier` throws (damaged file), skips unchanged writes, retires dossiers to `.trash`, and publishes through `AtomicFilePublish` with fullFsync. Every pane and filer write goes through it. The direct `loadDossier` calls are reads or refusal checks.
- **ResearchPersonModel.mutate** applies changes to the copy on disk, never to the pane's copy, and on failure re-reads and shows the error. The lore compare-and-swap and its conflict UI hold whenever the finding still exists.
- **ResearchAttestation** refuses unconfirmed, already-told and untranscribed findings before anything is written.
- **FamilyAssetStore+Documents.** `documents.json` is read, changed and written under `sidecarLock`. An unreadable list throws `sidecarUnreadable` and is never treated as empty. Writes go through `AtomicFilePublish` with fullFsync. Rollback moves files to `.trash` and never deletes.
- **FamilySearch pull and refresh** never replace or edit an existing tree file.
  - `install` copies to a new timestamped name.
  - `installMerged`/`installRefreshed` stage the file, check the generation, then rename `.partial` to a fresh name. `moveItem` will not overwrite.
  - The merge keeps the current graph's pointer space, so notes and rulings keyed by GEDCOM pointer or FSID stay attached.
  - The base is read fail-closed against the compiled manifest.
  - Hand-curated data (CyberBrain, rulings, dossiers, documents, overlays) lives outside the GEDCOM files, so a pull cannot touch it.
- **PersonFactOverlayStore** (per-person refresh). `update`/`save` refuse an unreadable overlay and set it aside by rename. Writes go through `AtomicFilePublish` with fullFsync, and errors reach the sheet and the audit lines.
  - `update` has no lock. A race would need an Apply in one window and an Undo in another landing within the same few milliseconds of fsync. I could not build a realistic scenario, so it is not filed.
- **HalliePronunciationLexicon.setFileEntry** sets a malformed file aside before writing.

## Not covered
- `RecordFinderFiling.swift`: only skimmed (the prepare refusal on an unreadable dossier and `restoreDossier`'s on-disk compare-and-swap). The full multi-write transaction and its rollback ordering against CyberBrain were not re-traced. It has had several codex rounds.
- `FamilyKinshipOverlay`, `TreeIdentityCenter`/`TreeIdentityDeriver`, `CouplePortrait`, `FamilyTreeMemories`: not opened.
- Leads outside the named scope, same shape as F1 and F2:
  - `FamilyTreeBookmarks.load` reads an unreadable file as empty, and `save` uses a whole-file `.atomic` from an in-memory copy (FamilyTreeBookmarks.swift:83–109). Its comment calls bookmarks a convenience layer.
  - `recordPhotoChoice` (FamilyAssetStore.swift:1475) uses `.atomic` without fsync. It replaces the whole file by design, so only durability is at stake.
- `recordPronunciationLive`: a CyberBrain write that succeeds followed by a failed `keepPhonemesInFile` reports an error for a write that did land. Not traced to the UI.
- Callees followed: `CyberBrainWriter+RootLock`, `CyberBrainCorrections.correct` (lock and save lines), `CyberBrainLoader.load` (missing-file test), `GedcomFamilyGraph.merge(with:)`, `PersonFactOverlayStore`, `FamilyIdentityDecisions` (load, revision, save), `HallieAppTurnCoordinator` (excludePhoto, testimony and pronunciation closures), `HallieShellCLI` (recordTestimony), `HalliePronunciationLexicon.setFileEntry`, `FamilyTreeView` (sourceRevision, saveDraftNote), `VideoScanApp` (window and menu setup), `AtomicFilePublishSensorTests` (bans only `replaceItemAt`; `.atomic` is accepted repo policy).
