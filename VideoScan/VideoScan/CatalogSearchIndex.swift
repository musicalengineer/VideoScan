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

    /// Inverted word index: word → set of fullPaths whose haystack
    /// contains that word. Built alongside `haystacks`, used by
    /// `filter`/`count` as a fast pre-narrowing pass before the
    /// per-record linear matcher (Rick 2026-06-16).
    ///
    /// A "word" is a maximal run of letters or digits in the lowercased
    /// + NFC haystack. Path-decomposition (CamelCase splits via
    /// `pathTokenize`) is applied before word extraction, so
    /// `CapeCod1997` contributes the words `cape`, `cod`, `1997`.
    ///
    /// Fast-path applies when every substring token in the query is a
    /// COMPLETE WORD that exists in the index. Partial-word substrings
    /// ("elev" matching "elevator") and phrase tokens fall back to the
    /// linear scan — correctness preserved at lower speed.
    ///
    /// Memory: ~30-100K unique words × avg ~100 record refs × ~120 byte
    /// fullPath = ~50-80 MB for a 15K-record catalog. Set<String> shares
    /// the underlying fullPath storage via Swift's CoW so the total
    /// footprint is dominated by hashmap overhead, not string duplication.
    private var wordIndex: [String: Set<String>] = [:]

    /// Discard the entire cache. Called on catalog reset / full reload.
    func clear() {
        haystacks.removeAll(keepingCapacity: false)
        wordIndex.removeAll(keepingCapacity: false)
    }

    /// Build (or rebuild) the index from a record set. Replaces any
    /// existing index. O(n) over the input.
    func rebuild(records: [VideoRecord]) {
        var hs: [String: String] = [:]
        var wi: [String: Set<String>] = [:]
        hs.reserveCapacity(records.count)
        for rec in records {
            let h = Self.buildHaystack(rec)
            hs[rec.fullPath] = h
            for word in Self.extractWords(from: h) {
                wi[word, default: []].insert(rec.fullPath)
            }
        }
        self.haystacks = hs
        self.wordIndex = wi
    }

    /// One-shot update for a single record. Called after dossier
    /// writeback so the new caption/transcript/OCR text is searchable
    /// without a full rebuild. Maintains the inverted index by
    /// diffing old vs new word sets — cheaper than re-walking the
    /// haystack twice.
    func update(_ rec: VideoRecord) {
        let oldWords = haystacks[rec.fullPath].map { Self.extractWords(from: $0) } ?? []
        let newHaystack = Self.buildHaystack(rec)
        let newWords = Self.extractWords(from: newHaystack)
        haystacks[rec.fullPath] = newHaystack
        // Words that left: remove this fullPath from their bucket.
        for word in oldWords.subtracting(newWords) {
            wordIndex[word]?.remove(rec.fullPath)
            if wordIndex[word]?.isEmpty == true {
                wordIndex.removeValue(forKey: word)
            }
        }
        // Words that arrived: add this fullPath to their bucket.
        for word in newWords.subtracting(oldWords) {
            wordIndex[word, default: []].insert(rec.fullPath)
        }
    }

    /// Drop a record from the index (purge, delete, rescan-removal).
    /// Cheap — a stale haystack returns no hits, but the caller's record
    /// list will already have dropped the record so it never reaches us.
    func remove(fullPath: String) {
        if let h = haystacks[fullPath] {
            for word in Self.extractWords(from: h) {
                wordIndex[word]?.remove(fullPath)
                if wordIndex[word]?.isEmpty == true {
                    wordIndex.removeValue(forKey: word)
                }
            }
        }
        haystacks.removeValue(forKey: fullPath)
    }

    /// True if the index has a haystack for this record. Used by tests
    /// to verify rebuild coverage; not load-bearing for production.
    func hasHaystack(for fullPath: String) -> Bool {
        haystacks[fullPath] != nil
    }

    /// True if `word` is in the inverted index. Used by tests; not
    /// load-bearing for production.
    func indexedWordCount() -> Int { wordIndex.count }

    /// Filter `records` against `query`. Empty query returns all records
    /// (preserving order). Otherwise tokenizes via the canonical
    /// `pfTokenizeSearchQuery` and applies per-token AND semantics.
    ///
    /// Fast path: when every substring token is a complete word that
    /// exists in the inverted index, the candidate set is the
    /// intersection of those words' record buckets — typically a few
    /// hundred records out of 15K. Skip the per-record matcher
    /// entirely for those.
    ///
    /// Fallback: linear per-record matcher (the original behavior). Any
    /// token that can't use the index (phrase with spaces, year/field
    /// tokens, or a substring that isn't a complete word) sends the
    /// whole query down this path. Correctness is preserved at lower
    /// speed.
    func filter(records: [VideoRecord], query: String) -> [VideoRecord] {
        let tokens = Self.prepareTokens(pfTokenizeSearchQuery(query))
        if tokens.isEmpty { return records }
        if let candidatePaths = tryIndexLookup(tokens: tokens) {
            return records.filter { candidatePaths.contains($0.fullPath) }
        }
        return records.filter { rec in matches(rec, tokens: tokens) }
    }

    /// Count-only filter. Same semantics as `filter` but skips array
    /// allocation when only the count is needed (toolbar badge).
    func count(records: [VideoRecord], query: String) -> Int {
        let tokens = Self.prepareTokens(pfTokenizeSearchQuery(query))
        if tokens.isEmpty { return records.count }
        if let candidatePaths = tryIndexLookup(tokens: tokens) {
            // Intersect with the active record set (the caller may have
            // pre-filtered before invoking us).
            var n = 0
            for rec in records where candidatePaths.contains(rec.fullPath) { n += 1 }
            return n
        }
        var n = 0
        for rec in records where matches(rec, tokens: tokens) { n += 1 }
        return n
    }

    // MARK: - Inverted-index fast path

    /// Resolve the candidate set of fullPaths via the inverted word
    /// index. Returns `nil` if any token can't use the index — caller
    /// must fall back to the linear matcher to preserve substring
    /// semantics (a token like "elev" doesn't match a complete word
    /// but DOES match the haystack of records containing "elevator").
    ///
    /// Returns an empty set if every token used the index AND the
    /// intersection is empty — there are provably zero matches and the
    /// caller can short-circuit.
    private func tryIndexLookup(tokens: [SearchToken]) -> Set<String>? {
        var candidates: Set<String>?
        for token in tokens {
            // Year-range / field-prefix tokens always need structural
            // record access — bail to linear.
            guard case .substring(let needle) = token else { return nil }
            // Phrase tokens (contain whitespace after tokenizer) need
            // adjacent-word matching — index doesn't help. Bail to
            // linear so the literalContains substring path runs.
            if needle.contains(" ") { return nil }
            if needle.isEmpty { return nil }
            // Whole-word lookup. If the needle isn't a complete word in
            // the index, the user is either typing a partial word
            // ("elev") or a substring inside one ("apes" inside "capes")
            // — both require the linear matcher. Bail.
            guard let bucket = wordIndex[needle] else { return nil }
            if let existing = candidates {
                candidates = existing.intersection(bucket)
                if candidates?.isEmpty == true { return [] }
            } else {
                candidates = bucket
            }
        }
        return candidates
    }

    // MARK: - Persistence (Rick 2026-06-16)
    //
    // Save the haystack cache to disk so the index doesn't rebuild from
    // scratch on every catalog load. Only `haystacks` is persisted —
    // the inverted `wordIndex` is RECOMPUTED on load. Reasoning:
    // serializing wordIndex would multiply on-disk size by
    // (avg-words-per-record × avg-records-per-word) — for a 15K-record
    // catalog that's a 5-10× blow-up of redundant fullPath strings.
    // Rebuilding wordIndex from haystacks at load time is ~30% of the
    // full rebuild cost, so the launch wins are still ~70%.

    /// Persisted format version. Bump when the on-disk layout changes
    /// so old files force a rebuild instead of silently deserializing
    /// wrong shapes.
    nonisolated static let persistedVersion: Int = 1

    /// Default location next to the catalog:
    /// `~/Library/Application Support/VideoScan/catalog.search-index.v1.plist`
    nonisolated static func defaultPersistenceURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("VideoScan", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("catalog.search-index.v1.plist")
    }

    /// Persist the haystack cache atomically. Caller usually invokes
    /// this after `rebuild` and on app quit. Failures are non-fatal —
    /// the next launch just rebuilds from records as before.
    func saveToDisk(at url: URL = defaultPersistenceURL()) throws {
        let payload: [String: Any] = [
            "version": Self.persistedVersion,
            "savedAt": Date().timeIntervalSince1970,
            "recordCount": haystacks.count,
            "haystacks": haystacks,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: payload, format: .binary, options: 0
        )
        try data.write(to: url, options: .atomic)
    }

    /// Try to populate this index from a persisted file. Returns true
    /// on success (caller can skip `rebuild`), false on missing file /
    /// version mismatch / staleness vs catalog / parse failure.
    ///
    /// Staleness check: if `catalogModifiedAt` is provided AND the
    /// persisted index was saved BEFORE that time, the index is
    /// rejected — the catalog has changed since save and the haystacks
    /// would be out of date. Pass `nil` to skip staleness (testing).
    @discardableResult
    func loadFromDisk(
        at url: URL = defaultPersistenceURL(),
        catalogModifiedAt: Date? = nil
    ) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        guard let payload = try? PropertyListSerialization.propertyList(
            from: data, format: nil
        ) as? [String: Any] else { return false }
        guard let version = payload["version"] as? Int,
              version == Self.persistedVersion else { return false }
        guard let savedAt = payload["savedAt"] as? TimeInterval else { return false }
        if let catalogModifiedAt {
            let savedDate = Date(timeIntervalSince1970: savedAt)
            if savedDate < catalogModifiedAt { return false }
        }
        guard let hs = payload["haystacks"] as? [String: String] else { return false }

        self.haystacks = hs
        // Rebuild the inverted word index from haystacks. This is the
        // ~30% of rebuild cost we DIDN'T avoid by persisting; loading
        // is still much faster than the full record-walk + haystack
        // construction.
        var wi: [String: Set<String>] = [:]
        for (path, h) in hs {
            for word in Self.extractWords(from: h) {
                wi[word, default: []].insert(path)
            }
        }
        self.wordIndex = wi
        return true
    }

    /// Extract maximal letter/digit runs from a (presumed lowercased +
    /// NFC) haystack. These are the keys of the inverted word index.
    /// Non-alphanumeric characters (whitespace, punctuation) split words.
    /// Diacritics survive the lowercase + NFC step upstream and are
    /// preserved here so "café" and "cafe" remain distinct words —
    /// matches what the linear matcher sees.
    nonisolated static func extractWords(from haystack: String) -> Set<String> {
        var words: Set<String> = []
        var current = ""
        for ch in haystack {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                words.insert(current)
                current = ""
            }
        }
        if !current.isEmpty { words.insert(current) }
        return words
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
        parts.reserveCapacity(12 + rec.sceneCaptions.count + rec.ocrText.count + rec.ocrDateCandidates.count)
        // Filename, directory, volumeName go through pathTokenize so
        // typed queries match the way humans READ camelCase folders
        // ("CapeCod1997.iMovieProject" → "cape cod 1997 i movie project").
        // The original strings still join the haystack too so existing
        // queries that lean on the raw path form keep matching.
        parts.append(rec.filename)
        parts.append(Self.pathTokenize(rec.filename))
        parts.append(rec.directory)
        parts.append(Self.pathTokenize(rec.directory))
        parts.append(rec.volumeName)
        parts.append(Self.pathTokenize(rec.volumeName))
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

    /// Decompose a path-like string into space-separated word tokens by
    /// injecting spaces at CamelCase transitions and letter↔digit
    /// boundaries. Standard "search engine analyzer" preprocessing —
    /// makes "CapeCod1997" findable as the words `cape`, `cod`, `1997`
    /// without a smarter (and slower) word-boundary matcher.
    ///
    /// Examples:
    ///   "CapeCod1997"      → "Cape Cod 1997"
    ///   "iMovieProject"    → "i Movie Project"
    ///   "Maxtor500FW"      → "Maxtor 500FW"   (FW stays joined — all-caps suffix)
    ///   "USAFlag"          → "USA Flag"       (acronym→word split via lookahead)
    ///
    /// Pure / nonisolated so it's callable from the haystack build path
    /// without an actor hop.
    nonisolated static func pathTokenize(_ s: String) -> String {
        if s.isEmpty { return s }
        var out = ""
        out.reserveCapacity(s.count + 8)
        let chars = Array(s)
        for i in 0..<chars.count {
            let ch = chars[i]
            if i > 0 {
                let prev = chars[i - 1]
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                // CamelCase split: lowercase|digit → uppercase
                if ch.isUppercase, (prev.isLowercase || prev.isNumber) {
                    out.append(" ")
                }
                // Acronym→word split: uppercase → uppercase but next is lowercase
                // ("USAFlag" → "USA Flag"). Skip when next is nil (trailing
                // uppercase) so "FW" doesn't get split into "F W".
                else if ch.isUppercase, prev.isUppercase, let next, next.isLowercase {
                    out.append(" ")
                }
                // Letter → digit split ("Cod1997" → "Cod 1997")
                else if ch.isNumber, prev.isLetter {
                    out.append(" ")
                }
                // Digit → letter split ("500FW" → "500 FW")
                else if ch.isLetter, prev.isNumber {
                    out.append(" ")
                }
            }
            out.append(ch)
        }
        return out
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
