# swift-expert review — 2026-10-07: dossier batch split + GedcomCompiledTree codec split

Blind, idiom-level review (agent `swift-expert`, Fable) of two behaviour-preserving refactors.
Behaviour was proven separately (characterization goldens + mutations); this review grades
design quality only.

## A) Dossier batch split (Claude) — **Good** (genuine improvement, two reshuffle residues)

| # | Grade | Evidence |
|---|---|---|
| 1 Naming | B | `preflightDossierFile`, `completeDossierLane`, `DossierLoopControl` read well. `countDossierExtractionFailure` also ends the lane and logs (name undersells it); `bankVLMOnly(_:_:model:vlmModelID:)` has two unlabeled leading args. |
| 2 Types | B+ | `DossierFilePlan`, `DossierSkip`, `VLMOnlyReason` replace four copied if-chains. `SerialTranscriptOutcome` is still Bool flag soup. |
| 3 Decomposition | B | Real dedup: preflight, pause gate, lane close-out and batch summary existed twice and now exist once. Residue: `transcribeAndBankDossier` takes 10 params; `pendingWhisper` threaded by `inout` while `self.pendingWhisperTask` holds the same value. |
| 4 Concurrency | B | Same shape as before, correctly preserved. Pause gate is still a 200 ms sleep poll, now isolated in one function. |
| 6 Errors | B | Cancellation / deadline / generic ordering preserved in both paths. |
| 7 Testability | B- | `serialDossierNote`, `isUsableTranscript`, `vlmOnlyReason` are pure; goldens pin the rest. `dossierSkipReason` hits `FileManager.default` directly. |
| 8 Docs | A- | Steps header explains WHY; incident comments survived the move. |

**Next changes:** (1) a `DossierBatchContext` struct instead of threading six values through five
signatures (C++: `const BatchContext&`); (2) drop the `inout` mirror of `pendingWhisperTask`
(two pointers to one object, synced by hand); (3) one `TranscriptOutcome` enum for both paths
instead of six Bools (a tagged union instead of flags).

## B) GedcomCompiledTree codec split (codex) — **Good** (clean split; encode/decode pairing got harder to see)

| # | Grade | Evidence |
|---|---|---|
| 1 Naming | B- | Decoder names clear. Encoder `writer.people(_:)`, `writer.index(_:)` are mutating methods named like accessors; API Design Guidelines want imperative verbs. |
| 2 Types | A- | `GraphMetadata` is a value struct whose doc states its invariant. `CodecError` typed and unchanged. |
| 3 Decomposition | B | `encode` and `parsePayload` now read as the wire layout. But each section's encoder and decoder live in different files with different idioms, so a codec-8 field means hunting two files. |
| 4 Concurrency | B+ | Unchanged; race-freedom notes moved intact. |
| 6 Errors | A | All `CodecError.corrupt(...)` labels preserved. |
| 7 Testability | B+ | `readPostingTables`, `validateIdentityTable` individually callable; `readIndex` threads `clock: inout PhaseClock` only to lap once. |
| 8 Docs | B | New files have one-line headers; +Decoding should say "mirrors +Encoding section order". Binary:183 `}}` formatting slip. |

**Next changes:** (1) verb-name the Writer methods (`writePeople`, `writeIndex`; C++ `operator<<`
reads as a write); (2) colocate each section's write/read pair in one file (keep `operator<<` and
`operator>>` adjacent) so a format change is one edit in one place; (3) stop threading the clock.

## Comparison

The dossier split is the better-designed result: it removed real duplication that had already
bitten and named the decisions with value types, preserving a delicate concurrency shape. The codec
split is tidy and correct but mostly cuts a linear function into named sections, loosening the
encoder/decoder symmetry the file exists to protect.
