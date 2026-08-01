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
// Year-range tokens use a per-record precomputed Set<Int> of years
// (GH #123 PR D — pfYearsFromRecord was ~9.5 µs/record/query at 100k:
// char scan + a Calendar init + two component extractions PER RECORD,
// ≈ 950 ms per settled keystroke for "1990s"). people: tokens use a
// dedicated person inverted index (archivist perf pass 2026-08-01) —
// exact canonical semantics via containment scan over the family-scale
// name vocabulary. Remaining field-prefix tokens (transcript:, codec:,
// …) defer to the canonical matcher as residual checks over the
// index-narrowed candidate set (see QueryPlan).
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
// catalog-narrow matcher. Pinned by CatalogSearchIndexTests (and the
// year-set agreement sensor in CatalogSearchBudgetSensorTests).

@MainActor
final class CatalogSearchIndex {

    /// fullPath → lowercased haystack of all content-searchable fields.
    /// The fullPath key matches catalog's primary key so updates are
    /// O(1) and survive record rebuild as long as the path is stable.
    private var haystacks: [String: String] = [:]

    /// fullPath → every year signal on the record (path/filename-embedded
    /// years, file dates, dossier-inferred date). Precomputed at
    /// build/update time so a yearRange token ("1990s", "year:1991") is a
    /// set-membership test per record instead of a per-query
    /// `pfYearsFromRecord` walk (GH #123 finding 2: ~950 ms/pass at 100k
    /// → ~tens of ms).
    ///
    /// MUST agree with the canonical `pfCatalogTokenMatches(.yearRange)`
    /// logic — see `buildYearSet`. Memory: ~100k records × a Set of 1–5
    /// small Ints ≈ 10–15 MB. Trivial next to the haystacks.
    private var yearSets: [String: Set<Int>] = [:]

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

    /// Memo for the infix-safety gate (Rick 2026-06-29). Keyed by a
    /// whole-word needle; value is whether that needle is "fast-path
    /// eligible" — i.e. whether `wordIndex[needle]` is the COMPLETE
    /// substring-match set for that needle.
    ///
    /// Why this exists: catalog search semantics are SUBSTRING (the
    /// canonical `pfRecordFilenameOrPersonMatch` does `.contains`). The
    /// whole-word bucket `wordIndex["rick"]` holds only records where
    /// "rick" is a standalone token — it MISSES records where "rick" is an
    /// infix of "rickb"/"ricksbackups". So the bucket is the complete
    /// answer ONLY IF "rick" is not also a substring of some OTHER indexed
    /// word. We compute that lazily (scan the word set once on first use of
    /// a needle: O(W·L)) and cache the boolean (O(1) thereafter). The memo
    /// is invalidated on ANY wordIndex mutation — update() can introduce a
    /// new word that turns a previously-safe needle unsafe, so we must not
    /// keep a stale "eligible" verdict.
    private var fastPathEligibility: [String: Bool] = [:]

    /// Person inverted index (archivist perf pass, 2026-08-01):
    /// lowercased person name → fullPaths carrying it in ANY of the
    /// three lists the canonical people: matcher consults (detected,
    /// suspected, user-confirmed). people: used to be the token that
    /// sent every query down the linear path — O(records × names) with
    /// a lowercase ALLOC per name per record per query.
    ///
    /// Unlike the word index, this needs NO eligibility gate: the key
    /// set is the complete person vocabulary (family-scale — dozens),
    /// so canonical SUBSTRING semantics ("people:don" matches "donna")
    /// are answered exactly by scanning the keys for containment and
    /// unioning their buckets — microseconds.
    private var personIndex: [String: Set<String>] = [:]
    /// Reverse map (fullPath → its contributed lowercased names) so a
    /// single-record update/remove can cleanly retract old entries.
    private var personsByPath: [String: Set<String>] = [:]

    /// Discard the entire cache. Called on catalog reset / full reload.
    func clear() {
        haystacks.removeAll(keepingCapacity: false)
        yearSets.removeAll(keepingCapacity: false)
        wordIndex.removeAll(keepingCapacity: false)
        fastPathEligibility.removeAll(keepingCapacity: false)
        personIndex.removeAll(keepingCapacity: false)
        personsByPath.removeAll(keepingCapacity: false)
    }

    /// Build (or rebuild) the index from a record set. Replaces any
    /// existing index. O(n) over the input.
    func rebuild(records: [VideoRecord]) {
        var hs: [String: String] = [:]
        var ys: [String: Set<Int>] = [:]
        var wi: [String: Set<String>] = [:]
        var pi: [String: Set<String>] = [:]
        var pbp: [String: Set<String>] = [:]
        hs.reserveCapacity(records.count)
        ys.reserveCapacity(records.count)
        for rec in records {
            let h = Self.buildHaystack(rec)
            hs[rec.fullPath] = h
            ys[rec.fullPath] = Self.buildYearSet(rec)
            for word in Self.extractWords(from: h) {
                wi[word, default: []].insert(rec.fullPath)
            }
            let people = Self.extractPeople(from: rec)
            if !people.isEmpty {
                pbp[rec.fullPath] = people
                for name in people { pi[name, default: []].insert(rec.fullPath) }
            }
        }
        self.haystacks = hs
        self.yearSets = ys
        self.wordIndex = wi
        self.personIndex = pi
        self.personsByPath = pbp
        // Word set replaced wholesale → any cached eligibility verdict is stale.
        fastPathEligibility.removeAll(keepingCapacity: false)
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
        // Year signals can change on the same writeback (dossier
        // triangulation sets inferredRecordDate) — keep the set current.
        yearSets[rec.fullPath] = Self.buildYearSet(rec)
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
        // The word SET may have changed (added/removed keys). A newly added
        // word could make a previously-"safe" needle an infix of it, so any
        // cached eligibility verdict is now suspect — drop the whole memo.
        if oldWords != newWords {
            fastPathEligibility.removeAll(keepingCapacity: false)
        }
        // Person maintenance — a fresh confirm/reject in the Inspector
        // must be people:-searchable the moment it lands.
        let oldPeople = personsByPath[rec.fullPath] ?? []
        let newPeople = Self.extractPeople(from: rec)
        for name in oldPeople.subtracting(newPeople) {
            personIndex[name]?.remove(rec.fullPath)
            if personIndex[name]?.isEmpty == true {
                personIndex.removeValue(forKey: name)
            }
        }
        for name in newPeople.subtracting(oldPeople) {
            personIndex[name, default: []].insert(rec.fullPath)
        }
        if newPeople.isEmpty {
            personsByPath.removeValue(forKey: rec.fullPath)
        } else {
            personsByPath[rec.fullPath] = newPeople
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
        yearSets.removeValue(forKey: fullPath)
        if let people = personsByPath.removeValue(forKey: fullPath) {
            for name in people {
                personIndex[name]?.remove(fullPath)
                if personIndex[name]?.isEmpty == true {
                    personIndex.removeValue(forKey: name)
                }
            }
        }
        // Removing the last reference to a word drops it from the key set,
        // which could make a previously-ineligible needle eligible. Drop the
        // memo so the next query recomputes against the current word set.
        fastPathEligibility.removeAll(keepingCapacity: false)
    }

    /// True if the index has a haystack for this record. Used by tests
    /// to verify rebuild coverage; not load-bearing for production.
    func hasHaystack(for fullPath: String) -> Bool {
        haystacks[fullPath] != nil
    }

    /// True if `word` is in the inverted index. Used by tests; not
    /// load-bearing for production.
    func indexedWordCount() -> Int { wordIndex.count }

    /// Number of records with a cached haystack. Used by tests and
    /// logging; not load-bearing for production.
    func recordCount() -> Int { haystacks.count }

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
        let plan = makePlan(tokens: tokens)
        guard let candidates = plan.candidates else {
            return records.filter { rec in matches(rec, tokens: tokens) }
        }
        if candidates.isEmpty { return [] }
        if plan.residual.isEmpty {
            return records.filter { candidates.contains($0.fullPath) }
        }
        return records.filter { rec in
            candidates.contains(rec.fullPath) && matches(rec, tokens: plan.residual)
        }
    }

    /// Count-only filter. Same semantics as `filter` but skips array
    /// allocation when only the count is needed (toolbar badge).
    func count(records: [VideoRecord], query: String) -> Int {
        let tokens = Self.prepareTokens(pfTokenizeSearchQuery(query))
        if tokens.isEmpty { return records.count }
        let plan = makePlan(tokens: tokens)
        guard let candidates = plan.candidates else {
            var n = 0
            for rec in records where matches(rec, tokens: tokens) { n += 1 }
            return n
        }
        if candidates.isEmpty { return 0 }
        var n = 0
        // Intersect with the active record set (the caller may have
        // pre-filtered before invoking us).
        for rec in records where candidates.contains(rec.fullPath) {
            if plan.residual.isEmpty || matches(rec, tokens: plan.residual) { n += 1 }
        }
        return n
    }

    // MARK: - Inverted-index fast path

    /// Query plan (archivist perf pass, 2026-08-01). Replaces the old
    /// all-or-nothing `tryIndexLookup`: instead of bailing the WHOLE
    /// query to the linear matcher when any one token can't use an
    /// index, index-capable tokens narrow to a candidate set and the
    /// rest (`residual`) are verified per-record on that (usually tiny)
    /// subset. AND semantics are preserved exactly; the correctness
    /// contract vs the canonical matcher is pinned by the agreement
    /// sensors in CatalogSearchIndexTests / PersonIndexTests.
    ///
    /// `candidates == nil` means no token could use an index — caller
    /// runs the original full linear scan. `candidates == []` means an
    /// indexed token PROVED zero matches; caller short-circuits.
    private struct QueryPlan {
        var candidates: Set<String>?
        var residual: [SearchToken] = []
    }

    private func makePlan(tokens: [SearchToken]) -> QueryPlan {
        var plan = QueryPlan()

        func narrow(with bucket: Set<String>) {
            if let existing = plan.candidates {
                plan.candidates = existing.intersection(bucket)
            } else {
                plan.candidates = bucket
            }
        }

        for token in tokens {
            if case .some(true) = plan.candidates?.isEmpty {
                // Provably zero matches — no need to classify the rest.
                return QueryPlan(candidates: [], residual: [])
            }
            switch token {
            case .field(let name, let value) where name == .people:
                // Person index answers people: tokens EXACTLY (see the
                // personIndex doc) — including "no such person" as a
                // provably-empty bucket.
                narrow(with: personCandidates(needle: value.lowercased()))
            case .substring(let needle):
                // Whole-word lookup with the infix-safety gate
                // (Rick 2026-06-29): a word bucket is the COMPLETE
                // substring-match set only if the needle is not also an
                // infix of some OTHER indexed word ("rick" inside
                // "rickb"). Phrases, partial words, and infix-unsafe
                // needles go to the residual linear check instead of
                // (as before) sinking the whole query.
                if !needle.isEmpty, !needle.contains(" "),
                   let bucket = wordIndex[needle], isFastPathEligible(needle) {
                    narrow(with: bucket)
                } else {
                    plan.residual.append(token)
                }
            default:
                // yearRange + other field tokens: cheap per-record checks
                // (cached year sets / direct field reads) on the narrowed
                // candidate set.
                plan.residual.append(token)
            }
        }
        return plan
    }

    /// Union the buckets of every indexed person name CONTAINING the
    /// needle — canonical substring semantics over a vocabulary small
    /// enough (family-scale) that the key scan is microseconds.
    private func personCandidates(needle: String) -> Set<String> {
        guard !needle.isEmpty else { return [] }
        var out: Set<String> = []
        for (name, bucket) in personIndex where name.contains(needle) {
            out.formUnion(bucket)
        }
        return out
    }

    /// Person-name vocabulary with record counts, most-tagged first.
    /// Archivist autocomplete/hints; later, translator prompt seeding.
    func knownPeople() -> [(name: String, count: Int)] {
        personIndex
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    /// Is `needle` (which is known to be a wordIndex key) safe to answer
    /// purely from its own whole-word bucket? True iff `needle` is NOT a
    /// proper substring (infix) of any OTHER indexed word — only then is
    /// `wordIndex[needle]` provably the COMPLETE substring-match set for the
    /// needle, so the fast path matches the canonical SUBSTRING matcher.
    ///
    /// Lazy + memoized: first use of a given needle pays O(W·L) to scan the
    /// word set once; the boolean is cached so repeated queries (the common
    /// case) are O(1). The memo is dropped on any wordIndex mutation
    /// (rebuild/clear/update/remove/load) so a verdict never goes stale.
    ///
    /// `needle` is lowercased + NFC (via prepareTokens) and so are the
    /// wordIndex keys (via extractWords over the normalized haystack), so the
    /// byte-literal `memmem` containment is the correct comparison.
    private func isFastPathEligible(_ needle: String) -> Bool {
        if let cached = fastPathEligibility[needle] { return cached }
        var eligible = true
        for other in wordIndex.keys {
            // A word longer than `needle` is the only kind that can strictly
            // contain it; skip the equal key and anything too short cheaply.
            if other.utf8.count <= needle.utf8.count { continue }
            if Self.literalContains(haystack: other, needle: needle) {
                eligible = false
                break
            }
        }
        fastPathEligibility[needle] = eligible
        return eligible
    }

    // MARK: - Persistence (Rick 2026-06-16)
    //
    // Save the haystack + year caches to disk so the index doesn't
    // rebuild from scratch on every catalog load. The inverted
    // `wordIndex` is RECOMPUTED on load. Reasoning: serializing
    // wordIndex would multiply on-disk size by
    // (avg-words-per-record × avg-records-per-word) — for a 15K-record
    // catalog that's a 5-10× blow-up of redundant fullPath strings.
    // Rebuilding wordIndex from haystacks at load time is ~30% of the
    // full rebuild cost, so the launch wins are still ~70%.
    //
    // GH #123 poisoning fix (2026-07-19): unit-test runs used to
    // overwrite the user's real index file with a 0-record one
    // (VideoScanModel.init had no test-host guard), and loadFromDisk
    // happily accepted the empty file — every search then rebuilt
    // haystacks inline per record per query: 5.4 s per settled
    // keystroke at 103k records. Two independent defenses now:
    //   1. defaultPersistenceURL() diverts test hosts to a per-process
    //      temp dir (same seam as POIStorage.storeDir /
    //      PersistentLog.logDir) — a test run CANNOT touch the real
    //      plist through any default-path caller.
    //   2. loadFromDisk rejects a persisted index whose record count is
    //      grossly inconsistent with the live catalog — the existing
    //      poison (or any future corruption) is inert: reject → rebuild.

    /// Persisted format version. Bump when the on-disk layout changes
    /// so old files force a rebuild instead of silently deserializing
    /// wrong shapes. v2 (2026-07-19): per-record year sets persisted
    /// alongside haystacks (GH #123 PR D). v3 (2026-07-23): tags +
    /// userNotes joined the haystack field set — a v2 file's haystacks
    /// predate them (and predate the notes → userNotes migration that
    /// runs the same launch), so v2 is rejected → one rebuild, then
    /// saved back as v4. v4 (2026-08-01): per-record person names
    /// persisted so the person index (archivist perf pass) survives
    /// relaunch without a record walk.
    /// NOT a semantic layout change; the bump exists
    /// purely to force that one refresh.
    nonisolated static let persistedVersion: Int = 4

    /// Default location next to the catalog:
    /// `~/Library/Application Support/VideoScan/catalog.search-index.v1.plist`
    ///
    /// Test hosts (unit AND UI — TestEnvironment.isTestHost covers both)
    /// are diverted to a per-process temp dir so no test run can ever
    /// read or overwrite the user's real search index
    /// (settings-pollution class; same pattern as POIStorage.storeDir /
    /// PersistentLog.logDir). This is THE seam that stopped the GH #123
    /// index poisoning — keep every persistence caller on this default.
    nonisolated static func defaultPersistenceURL() -> URL {
        if TestEnvironment.isTestHost {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "VideoScanTestSearchIndex-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("catalog.search-index.v1.plist")
        }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("VideoScan", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("catalog.search-index.v1.plist")
    }

    /// Persist the haystack + year caches atomically. Caller usually
    /// invokes this after `rebuild` and on app quit. Failures are
    /// non-fatal — the next launch just rebuilds from records as before.
    func saveToDisk(at url: URL = defaultPersistenceURL()) throws {
        // Plists can't hold Set<Int>/Set<String> — flatten to arrays.
        var yearArrays: [String: [Int]] = [:]
        yearArrays.reserveCapacity(yearSets.count)
        for (path, ys) in yearSets { yearArrays[path] = Array(ys) }
        var peopleArrays: [String: [String]] = [:]
        peopleArrays.reserveCapacity(personsByPath.count)
        for (path, names) in personsByPath { peopleArrays[path] = Array(names) }
        let payload: [String: Any] = [
            "version": Self.persistedVersion,
            "savedAt": Date().timeIntervalSince1970,
            "recordCount": haystacks.count,
            "haystacks": haystacks,
            "years": yearArrays,
            "people": peopleArrays,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: payload, format: .binary, options: 0
        )
        try data.write(to: url, options: .atomic)
    }

    /// Try to populate this index from a persisted file. Returns true
    /// on success (caller can skip `rebuild`), false on missing file /
    /// version mismatch / staleness vs catalog / record-count sanity
    /// failure / parse failure.
    ///
    /// Staleness check: if `catalogModifiedAt` is provided AND the
    /// persisted index was saved BEFORE that time, the index is
    /// rejected — the catalog has changed since save and the haystacks
    /// would be out of date. Pass `nil` to skip staleness (testing).
    ///
    /// Sanity check (GH #123): if `expectedRecordCount` is provided and
    /// > 0, a persisted index whose record count is grossly inconsistent
    /// with the live catalog is rejected — in particular the
    /// 0-records-for-a-non-empty-catalog poison, but also any count
    /// outside [50%, 200%] of the catalog. A rejected index costs one
    /// rebuild; an accepted poison costs seconds of inline haystack
    /// construction on EVERY query. Pass `nil` to skip (tests that
    /// exercise other paths).
    @discardableResult
    func loadFromDisk(
        at url: URL = defaultPersistenceURL(),
        catalogModifiedAt: Date? = nil,
        expectedRecordCount: Int? = nil
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
        guard let yearArrays = payload["years"] as? [String: [Int]] else { return false }
        // Person index (v4). The key must EXIST in a v4 file (an empty
        // dictionary is a legal value for a people-less catalog). A
        // missing key means truncation/corruption — and under QueryPlan
        // an empty person index is a PROVABLY-ZERO answer for every
        // people: query, so accepting it would silently blank person
        // search. Reject BEFORE mutating self → one rebuild
        // (codex finding, channel #71).
        guard let peopleArrays = payload["people"] as? [String: [String]] else { return false }
        // Record-count sanity (GH #123): measured against the ACTUAL
        // haystack dictionary, not the self-reported "recordCount"
        // field — never trust a possibly-corrupt file's claim about
        // itself.
        if let expected = expectedRecordCount, expected > 0 {
            let n = hs.count
            if n == 0 { return false }                    // the observed poison
            if n < (expected + 1) / 2 { return false }    // grossly under
            if n > expected * 2 { return false }          // grossly over / stale
        }

        self.haystacks = hs
        var ys: [String: Set<Int>] = [:]
        ys.reserveCapacity(yearArrays.count)
        for (path, arr) in yearArrays { ys[path] = Set(arr) }
        self.yearSets = ys
        var pbp: [String: Set<String>] = [:]
        var pi: [String: Set<String>] = [:]
        pbp.reserveCapacity(peopleArrays.count)
        for (path, names) in peopleArrays where !names.isEmpty {
            let set = Set(names)
            pbp[path] = set
            for name in set { pi[name, default: []].insert(path) }
        }
        self.personsByPath = pbp
        self.personIndex = pi
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
        // Fresh word set from disk → discard any eligibility verdicts.
        fastPathEligibility.removeAll(keepingCapacity: false)
        return true
    }

    /// Lowercased person names from the THREE lists the canonical
    /// people: matcher consults — full names kept whole ("dad breen"
    /// stays one key; needle containment handles word-level hits),
    /// mirroring pfFieldTokenMatches(.people)'s `$0.lowercased()
    /// .contains(n)` comparison exactly.
    nonisolated static func extractPeople(from rec: VideoRecord) -> Set<String> {
        var names: Set<String> = []
        for name in rec.detectedPeople {
            let key = name.lowercased()
            if !key.isEmpty { names.insert(key) }
        }
        for name in rec.suspectedPeople {
            let key = name.lowercased()
            if !key.isEmpty { names.insert(key) }
        }
        for tag in rec.confirmedByUserPeople {
            let key = tag.name.lowercased()
            if !key.isEmpty { names.insert(key) }
        }
        return names
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
    /// Fast paths: substring tokens use the cached haystack; yearRange
    /// tokens use the cached year set. Field-prefix tokens fall through
    /// to the canonical matcher (they need specific field access).
    ///
    /// Defensive fallback: if the record has no cached haystack / year
    /// set (added after rebuild, or some other staleness), we build it
    /// inline and use it for this match — correctness is preserved at
    /// the cost of one extra O(record-fields) build for that record.
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
            case .yearRange(let range):
                // GH #123 PR D: set-membership on the precomputed year
                // set instead of re-deriving years per record per query.
                // Agreement with the canonical pfCatalogTokenMatches is
                // pinned by CatalogSearchBudgetSensorTests.
                let years = yearSets[rec.fullPath] ?? Self.buildYearSet(rec)
                if !years.contains(where: { range.contains($0) }) {
                    return false
                }
            case .field:
                // Field-prefix tokens need specific field access —
                // delegate to the canonical matcher.
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
        // Workflow tags + user notes (2026-07-23) — human signal, so
        // they're plain-searchable. Machine `notes` deliberately stays
        // OUT, exactly as before (field-prefix-only via note:). Aligned
        // with pfCatalogTokenMatches' substring branch — correctness
        // contract.
        parts.append(contentsOf: rec.tags)
        if !rec.userNotes.isEmpty { parts.append(rec.userNotes) }
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

    /// Every year signal the canonical yearRange matcher consults, as
    /// one Set: path/filename-embedded years + file dates (both via
    /// `pfYearsFromRecord`) + the dossier-inferred record date. MUST
    /// stay in lock-step with `pfCatalogTokenMatches`'s `.yearRange`
    /// branch — `pfYearsFromRecord` remains the canonical reference;
    /// this is a build-time cache of it (GH #123 PR D).
    nonisolated static func buildYearSet(_ rec: VideoRecord) -> Set<Int> {
        var years = pfYearsFromRecord(rec)
        if let inf = rec.inferredRecordDate {
            years.insert(pfGregorianCalendar.component(.year, from: inf))
        }
        return years
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
