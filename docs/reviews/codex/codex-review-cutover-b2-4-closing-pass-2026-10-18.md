# Codex review — Cutover B2.4 closing pass

- Range: `49cb7794a..4a91fdb7f`
- Credits spent: unavailable (metering not exposed)
- Tokens: 81719
- Finding count: 2
- Verdict: block — the reported examples are addressed, but both findings remain OPEN in narrower cases.
- Run: 2026-10-18T04:58:25Z (cycle #106, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (metering not exposed) | Finding count: 2

Verdict: block — the reported examples are addressed, but both findings remain OPEN in narrower cases.

1. **B2.3 `placeRecord` curation loss — OPEN, P1.** Different/unknown-digest replacement now retains the old row. However, same-digest inheritance [keeps a nonempty heir’s conflicting value](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/CatalogReplacedRecord.swift:43), then [removes and purges the old record](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/VideoScanModel+CatalogPurge.swift:84) without first journaling its pending edits. The claim that those values remain in catalog history is therefore false for unsaved edits.

   **Failure scenario:** edit the old row’s music annotation, then before debounce land a same-digest heir carrying a different nonempty music annotation; the old edit disappears from memory and never reaches `row_knowledge`, while the replacement log says only “family music.”

2. **B2.3 order-dependent shared sets — OPEN, P1.** The reported independent tag additions and attestation remove/add cases are fixed. However, [attestation deletion matches the database key without the label](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository+LivePending.swift:142), while insertion overwrites that key’s label and clears its conflict flag.

   **Failure scenario:** copies A/B share one attestation; A removes it while B changes its label; A→B preserves the renamed attestation, but B→A deletes it, with no conflict indication.

   Replaying the extracted production SQL in SQLite `:memory:` confirmed those different outcomes.

No additional P1 findings. All listed files and tests were read; remaining scoped files: **read, no findings**. The supplied tests cover neither scenario above. Swift/app tests were not executed under the no-files constraint; no files were written.

**The accepted-edit durability guarantee is refuted:** replacement can discard an accepted edit during normal execution, and attestation commit order can erase another accepted change—without a crash or “Quit and lose N.”

## Brief

# Codex brief: cutover B2.4 closing pass (2026-10-18 night; data-risk)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~500 words.

**Your B2.3 pass:** `docs/reviews/codex/codex-review-cutover-b2-3-veto-explicit-purge-2026-10-18.md` (open: shared sets order-dependent; placeRecord purges a replaced row's curation). **The fix:** merge of `7039683c6`, range `49cb7794a..4a91fdb7f`. Files under `VideoScan/`: Core `VideoScanCore/Sources/VideoScanCore/Commit/CatalogSetDelta.swift`, `Commit/CatalogCommitBody.swift` (`writeSetDeltas`, `settleSets`), `Commit/CatalogCommit.swift`, `Store/GRDBCatalogRepository+LivePending.swift` (`writeTagsDelta`, `writeAttestationsDelta`), `Store/GRDBCatalogRepository+Live.swift`, `Import/CatalogRecordDTO.swift` (`attestationRows`); app `VideoScan/Catalog/CatalogCommitBaseline.swift`, `Catalog/VideoScanModel+CatalogPurge.swift` (`placeRecord`), `Catalog/CatalogReplacedRecord.swift`, `MediaOps/VideoScanModel+RemovalMarker.swift` (`replacedAtPath`); tests `VideoScanTests/CatalogCutoverB24Tests.swift`, Core `Tests/VideoScanCoreTests/Store/CatalogCommitB24Tests.swift`.

**Do only this:** (1) your two B2.3 findings: CLOSED (file:line) or OPEN. (2) at most TWO new P1 findings with a one-line failure scenario. Confirm or refute, finally: after the flip, an edit accepted by the app is never lost except by a crash inside the 2 s debounce or an explicit 'Quit and lose N'.
**Do not explore outside the files listed above and their tests.**
