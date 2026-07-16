// TrimThumbnailCacheTests.swift
// SCALE dimension for Trim Master (feature-test checklist item 2).
// The trim itself is a single-file operation — no O(records) iteration
// anywhere — so the scale surface is the sheet's frame cache: it must
// stay BOUNDED no matter how long the user scrubs timecodes (the memory
// budget in TrimSheet.swift's header depends on this cap).

import Testing
@testable import VideoScan

struct TrimThumbnailCacheTests {

    @Test func capIsRespectedUnderSustainedScrubbing() {
        let cache = TrimThumbnailCache<Int>(capacity: 48)
        // Simulate a long scrubbing session: 10,000 distinct timecodes.
        for i in 0..<10_000 {
            cache.insert(i, forMilliseconds: Int64(i))
        }
        #expect(cache.count == 48, "cache grew past its cap: \(cache.count)")
        // The newest entries survive; the oldest were evicted.
        #expect(cache.value(forMilliseconds: 9_999) == 9_999)
        #expect(cache.value(forMilliseconds: 0) == nil)
    }

    @Test func evictionIsOldestFirst() {
        let cache = TrimThumbnailCache<String>(capacity: 2)
        cache.insert("a", forMilliseconds: 1)
        cache.insert("b", forMilliseconds: 2)
        cache.insert("c", forMilliseconds: 3)
        #expect(cache.value(forMilliseconds: 1) == nil, "oldest must be evicted first")
        #expect(cache.value(forMilliseconds: 2) == "b")
        #expect(cache.value(forMilliseconds: 3) == "c")
    }

    @Test func reinsertingSameKeyDoesNotDoubleCount() {
        let cache = TrimThumbnailCache<String>(capacity: 3)
        cache.insert("a", forMilliseconds: 1)
        cache.insert("a2", forMilliseconds: 1)
        #expect(cache.count == 1)
        #expect(cache.value(forMilliseconds: 1) == "a2", "newest value wins")
    }

    @Test func capacityFloorIsOne() {
        let cache = TrimThumbnailCache<Int>(capacity: 0)
        cache.insert(7, forMilliseconds: 7)
        #expect(cache.count == 1, "degenerate capacity must clamp to 1, not 0")
    }

    @Test func keyRoundsToMilliseconds() {
        // 2.0004 s and 2.0 s are the same frame for any real codec —
        // they must hit the same cache entry.
        #expect(TrimThumbnailCache<Int>.key(forSeconds: 2.0004) ==
                TrimThumbnailCache<Int>.key(forSeconds: 2.0))
        #expect(TrimThumbnailCache<Int>.key(forSeconds: 2.001) !=
                TrimThumbnailCache<Int>.key(forSeconds: 2.0))
    }
}
