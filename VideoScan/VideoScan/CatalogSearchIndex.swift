import Foundation

// MARK: - CatalogSearchIndex
//
// In-memory search accelerator for the catalog. Eliminates the
// per-keystroke cost of:
//
//   1. Lowercasing every record's searchable fields (was being repeated
//      on every character typed — for the audio transcript field
//      alone, that's potentially 5,000+ characters PER RECORD).
//   2. Concatenating fields each time.
//   3. Running per-field substring searches (one .contains() per
//      field × records × tokens).
//
// At rebuild time, every record gets a single pre-computed lowercase
// "haystack" string — the concatenation of all content-searchable
// fields. Per-keystroke, search is just:
//
//   haystack.contains(token)   // one call per record per token
//
// Year-range and field-prefix tokens (people:donna, year:1989..1995)
// still defer to the canonical `pfCatalogTokenMatches` because those
// need structural access (specific fields, not a flat haystack).
//
// Memory: ~5KB per record × 16k records ≈ 80 MB. Trivial for M4-class
// machines. The win is wall-clock: the 15k-record catalog goes from
// ~hundreds of ms per keystroke to ~10 ms.
//
// Lifecycle:
//   - Built by VideoScanModel after catalog load.
//   - Updated on dossier writeback (single-record update is cheap).
//   - Cleared on catalog reset.
//
// Correctness contract: filter(records:query:) MUST return the same
// records as pfRecordsMatchingQuery(records:, query:) using the
// catalog-narrow matcher. Pinned by CatalogSearchIndexTests.

@MainActor
final class CatalogSearchIndex {

    /// fullPath → lowercased haystack of all content-searchable fields.
    /// The fullPath key matches catalog's primary key so updates are
    /// O(1) and survive record rebuild as long as the path is stable.
    private var haystacks: [String: String] = [:]

    /// Discard the entire cache. Called on catalog reset / full reload.
    func clear() {
        haystacks.removeAll(keepingCapacity: false)
    }

    /// Build (or rebuild) the index from a record set. Replaces any
    /// existing index. O(n) over the input.
    func rebuild(records: [VideoRecord]) {
        var dict: [String: String] = [:]
        dict.reserveCapacity(records.count)
        for rec in records {
            dict[rec.fullPath] = Self.buildHaystack(rec)
        }
        self.haystacks = dict
    }

    /// One-shot update for a single record. Called after dossier
    /// writeback so the new caption/transcript/OCR text is searchable
    /// without a full rebuild.
    func update(_ rec: VideoRecord) {
        haystacks[rec.fullPath] = Self.buildHaystack(rec)
    }

    /// Drop a record from the index (purge, delete, rescan-removal).
    /// Cheap — a stale haystack returns no hits, but the caller's record
    /// list will already have dropped the record so it never reaches us.
    func remove(fullPath: String) {
        haystacks.removeValue(forKey: fullPath)
    }

    /// True if the index has a haystack for this record. Used by tests
    /// to verify rebuild coverage; not load-bearing for production.
    func hasHaystack(for fullPath: String) -> Bool {
        haystacks[fullPath] != nil
    }

    /// Filter `records` against `query`. Empty query returns all records
    /// (preserving order). Otherwise tokenizes via the canonical
    /// `pfTokenizeSearchQuery` and applies per-token AND semantics.
    func filter(records: [VideoRecord], query: String) -> [VideoRecord] {
        let tokens = Self.prepareTokens(pfTokenizeSearchQuery(query))
        if tokens.isEmpty { return records }
        return records.filter { rec in matches(rec, tokens: tokens) }
    }

    /// Count-only filter. Same semantics as `filter` but skips array
    /// allocation when only the count is needed (toolbar badge).
    func count(records: [VideoRecord], query: String) -> Int {
        let tokens = Self.prepareTokens(pfTokenizeSearchQuery(query))
        if tokens.isEmpty { return records.count }
        var n = 0
        for rec in records where matches(rec, tokens: tokens) { n += 1 }
        return n
    }

    /// Normalize substring needles ONCE per query (not per record):
    /// lowercased + NFC, matching `buildHaystack`'s normalization, so
    /// `matches` can use a byte-literal search.
    nonisolated static func prepareTokens(_ tokens: [SearchToken]) -> [SearchToken] {
        tokens.map { token in
            if case .substring(let needle) = token {
                return .substring(needle.lowercased().precomposedStringWithCanonicalMapping)
            }
            return token
        }
    }

    /// Check a single record against pre-tokenized query.
    /// Fast path: substring tokens use the cached haystack. Year-range
    /// and field-prefix tokens fall through to the canonical matcher.
    ///
    /// Defensive fallback: if the record has no cached haystack (added
    /// after rebuild, or some other staleness), we build it inline and
    /// use it for this match — correctness is preserved at the cost of
    /// one extra O(record-fields) build for that record.
    func matches(_ rec: VideoRecord, tokens: [SearchToken]) -> Bool {
        var lazyHaystack: String?
        func haystack() -> String {
            if let h = lazyHaystack { return h }
            let h = haystacks[rec.fullPath] ?? Self.buildHaystack(rec)
            lazyHaystack = h
            return h
        }
        for token in tokens {
            switch token {
            case .substring(let needle):
                // needle arrives pre-lowercased + NFC via prepareTokens.
                // Byte-literal search, NOT Foundation's contains: canonical
                // Unicode comparison on multi-KB transcript haystacks was
                // 87% of main-thread time in the 2026-06-10 beachball.
                if !Self.literalContains(haystack: haystack(), needle: needle) {
                    return false
                }
            case .yearRange, .field:
                // Year ranges need inferredRecordDate / path-year
                // extraction; field-prefix tokens need specific field
                // access. Both delegate to the canonical matcher.
                if !pfCatalogTokenMatches(token, rec) {
                    return false
                }
            }
        }
        return true
    }

    // MARK: - Haystack construction
    //
    // This MUST stay aligned with the field set in
    // `pfCatalogTokenMatches` for substring tokens. If a new content
    // field becomes searchable, add it here AND there.

    /// Build a lowercased concatenation of every content-searchable
    /// field on `rec`. Fields joined with space so tokens at field
    /// boundaries don't accidentally merge.
    ///
    /// `nonisolated` because it's a pure value-extraction over a class's
    /// data — safe to call from background work that needs to construct
    /// haystacks ahead of time (e.g. preloading large catalogs).
    nonisolated static func buildHaystack(_ rec: VideoRecord) -> String {
        // Worst case dominated by audioTranscript (potentially 10k+ chars)
        // and sceneCaptions (multiple ~200-300 char descriptions). Most
        // records have <5KB total searchable text.
        var parts: [String] = []
        parts.reserveCapacity(10 + rec.sceneCaptions.count + rec.ocrText.count + rec.ocrDateCandidates.count)
        parts.append(rec.filename)
        // Rick 2026-06-15: directory and volumeName are deliberately
        // included so folder-based queries ("Cape Cod 1997", "Christmas
        // 2005") match files organized by project folder even when their
        // content fields (transcript, captions) don't mention the topic
        // verbatim. Pre-2026-06-15 these were excluded per the
        // "matt vs Matthew" concern (substring 'matt' shouldn't match
        // every file in a 'Matthew' directory). Mitigations:
        //   - Word-boundary matching for short tokens kills most of
        //     the 'matt' → 'Matthew' false positives.
        //   - AND across multiple tokens still narrows reliably.
        parts.append(rec.directory)
        parts.append(rec.volumeName)
        parts.append(contentsOf: rec.detectedPeople)
        parts.append(contentsOf: rec.suspectedPeople)
        parts.append(contentsOf: rec.confirmedByUserPeople.map { $0.name })
        for cap in rec.sceneCaptions { parts.append(cap.text) }
        if let t = rec.audioTranscript { parts.append(t) }
        for hit in rec.ocrDateCandidates { parts.append(hit.text) }
        for hit in rec.ocrText { parts.append(hit.text) }
        // NFC-normalize: macOS filenames are NFD-decomposed ("é" = e+◌́)
        // while typed queries are NFC. Both sides get NFC so the
        // byte-literal search in `matches` stays correct for accents.
        return parts.joined(separator: " ").lowercased()
            .precomposedStringWithCanonicalMapping
    }

    /// Byte-level substring search via memmem. Both sides MUST already
    /// be lowercased + NFC (see prepareTokens / buildHaystack).
    nonisolated static func literalContains(haystack: String, needle: String) -> Bool {
        if needle.isEmpty { return true }
        var h = haystack
        var n = needle
        return h.withUTF8 { hb in
            n.withUTF8 { nb in
                guard nb.count <= hb.count,
                      let hBase = hb.baseAddress,
                      let nBase = nb.baseAddress else { return false }
                return memmem(hBase, hb.count, nBase, nb.count) != nil
            }
        }
    }
}
