// AudioMasterFinderTests.swift — "Find Master by sound"
// (design provenance_retroactive_2026_10_26 §Phase A tests).
//   Logic     — a clip is found inside its master at the right offset; a
//               master lists its clips; the query never finds itself;
//               ranking order.
//   One engine — every verdict is exactly the pair matcher's.
//   Truth     — a negative says what was searched; too little sound and
//               another recipe are refusals, never "none found".
//   Isolation — a hash present in every content (a catalog-wide hum) is
//               skipped and the true master still ranks first.
// The corpus is rendered in Swift (SyntheticSpeech, seeded) and printed
// in-process — no file of Rick's, no ffmpeg — except the re-encode case,
// which uses the shared fixture matrix's AAC copy.

import Foundation
import Testing
@testable import VideoScanCore

enum FinderCorpus {
    static let rate = 8_000
    /// A 10-minute master and two unrelated 3-minute recordings.
    static let masterPCM = SyntheticSpeech.toInt16(SyntheticSpeech.render(seconds: 600, seed: 0x5EED_0001))
    static let master = AudioFingerprint.compute(AudioPCM(sampleRate: rate, samples: masterPCM))
    static let other1 = AudioFingerprint.compute(AudioPCM(sampleRate: rate, samples:
        SyntheticSpeech.toInt16(SyntheticSpeech.render(seconds: 180, seed: 0x5EED_0002))))
    static let other2 = AudioFingerprint.compute(AudioPCM(sampleRate: rate, samples:
        SyntheticSpeech.toInt16(SyntheticSpeech.render(seconds: 180, seed: 0x5EED_0003))))
    /// 40 s cut at 312.4 s — off the frame grid on purpose.
    static let clipStart = 312.4
    static let clip = cut(at: clipStart, seconds: 40)
    static let clip2 = cut(at: 45.0, seconds: 25)
    static let unrelated = AudioFingerprint.compute(AudioPCM(sampleRate: rate, samples:
        SyntheticSpeech.toInt16(SyntheticSpeech.render(seconds: 60, seed: 0x5EED_0099))))

    static func cut(at start: Double, seconds: Double) -> AudioFingerprint {
        let from = Int(start * Double(rate)), to = from + Int(seconds * Double(rate))
        return AudioFingerprint.compute(AudioPCM(sampleRate: rate, samples: Array(masterPCM[from..<to])))
    }

    static let masterKey = CatalogIndexFixtures.key(1)
    static let clipKey = CatalogIndexFixtures.key(2)
    static let clip2Key = CatalogIndexFixtures.key(3)

    /// master, other1, other2, clip, clip2 — the catalog as the finder sees it.
    static var catalog: [(AudioFingerprintStore.Key, AudioFingerprint)] {
        [(masterKey, master), (CatalogIndexFixtures.key(10), other1), (CatalogIndexFixtures.key(11), other2),
         (clipKey, clip), (clip2Key, clip2)]
    }

    static func index(_ entries: [(AudioFingerprintStore.Key, AudioFingerprint)] = catalog) throws -> AudioCatalogIndex {
        let rows = entries.map { ($0.0, Result<AudioFingerprint, Error>.success($0.1)) }
        return try AudioCatalogIndex.build(rows: CatalogIndexFixtures.rows(rows), expectedRows: rows.count).0
    }

    static func loader(_ entries: [(AudioFingerprintStore.Key, AudioFingerprint)] = catalog)
        -> (AudioFingerprintStore.Key) -> AudioFingerprint? {
        let map = Dictionary(entries, uniquingKeysWith: { a, _ in a })
        return { map[$0] }
    }
}

@Suite("AudioMasterFinder")
struct AudioMasterFinderTests {
    typealias C = FinderCorpus

    @Test("a 40 s clip cut at 312.4 s is found inside its master within 0.1 s")
    func clipIsFoundInsideItsMaster() throws {
        let search = AudioMasterFinder.find(query: C.clip, queryKey: C.clipKey, in: try C.index(), load: C.loader())
        guard case .found(let found, let searched, _) = search else { Issue.record("got \(search)"); return }
        #expect(searched == 4)
        let first = try #require(found.first)
        #expect(first.key == C.masterKey)
        guard case .containedInMaster(let offset) = first.match.verdict else { Issue.record("\(first.match.verdict)"); return }
        #expect(abs(offset - C.clipStart) <= 0.1, "offset \(offset)")
    }

    @Test("an AAC re-encode of a master is the same recording")
    func reencodeIsSameRecording() async throws {
        let original = try await AudioFixtureStore.shared.fingerprint("A")
        let aac = try await AudioFixtureStore.shared.fingerprint("A_aac96")
        let entries = C.catalog + [(CatalogIndexFixtures.key(20), original)]
        let search = AudioMasterFinder.find(query: aac, queryKey: CatalogIndexFixtures.key(21),
                                            in: try C.index(entries), load: C.loader(entries))
        guard case .found(let found, _, _) = search else { Issue.record("got \(search)"); return }
        #expect(found.first?.key == CatalogIndexFixtures.key(20))
        #expect(found.first?.match.verdict == .sameRecording)
    }

    @Test("the master as query lists its clips as contained in it")
    func masterQueryListsItsClips() throws {
        let search = AudioMasterFinder.find(query: C.master, queryKey: C.masterKey, in: try C.index(), load: C.loader())
        guard case .found(let found, _, _) = search else { Issue.record("got \(search)"); return }
        #expect(Set(found.map(\.key)) == [C.clipKey, C.clip2Key])
        for candidate in found {
            guard case .masterContainedInQuery = candidate.match.verdict else {
                Issue.record("\(candidate.key.contentDigest.prefix(12)): \(candidate.match.verdict)"); continue
            }
        }
    }

    @Test("every verdict is exactly the pair matcher's")
    func verdictIsExactlyThePairMatchers() throws {
        let index = try C.index()
        let load = C.loader()
        for (key, query) in C.catalog {
            guard case .found(let found, _, _) = AudioMasterFinder.find(query: query, queryKey: key, in: index, load: load) else { continue }
            for candidate in found {
                let master = try #require(load(candidate.key))
                #expect(candidate.match == AudioFingerprintMatcher.match(query: query, master: master))
            }
        }
    }

    @Test("a query that is in the index never matches itself")
    func ownDigestIsNeverACandidate() throws {
        let index = try C.index()
        for (key, query) in C.catalog {
            let search = AudioMasterFinder.find(query: query, queryKey: key, in: index, load: C.loader())
            if case .found(let found, _, _) = search { #expect(!found.contains { $0.key == key }) }
            let own = index.ordinal(of: key)
            #expect(!AudioMasterFinder.candidates(query: query, excluding: own, in: index).contains { $0.ordinal == own })
        }
    }

    @Test("an unrelated query says what was searched — never found([])")
    func unrelatedQueryReportsWhatWasSearched() throws {
        let index = try C.index()
        let search = AudioMasterFinder.find(query: C.unrelated, queryKey: CatalogIndexFixtures.key(99), in: index, load: C.loader())
        #expect(search == .noneFound(searched: index.documents.count, unreadable: []))
        // In the index itself: searched excludes its own content (N − 1).
        let withIt = C.catalog + [(CatalogIndexFixtures.key(99), C.unrelated)]
        let index2 = try C.index(withIt)
        #expect(AudioMasterFinder.find(query: C.unrelated, queryKey: CatalogIndexFixtures.key(99), in: index2,
                                       load: C.loader(withIt)) == .noneFound(searched: index2.documents.count - 1, unreadable: []))
    }

    @Test("a candidate whose print cannot be read is reported, never a plain negative (rule 1)")
    func unloadableCandidateIsNotANegative() throws {
        let index = try C.index()
        let full = C.loader()
        let search = AudioMasterFinder.find(query: C.clip, queryKey: C.clipKey, in: index,
                                            load: { $0 == C.masterKey ? nil : full($0) })
        #expect(search != .noneFound(searched: 4, unreadable: []))
        #expect(search == .noneFound(searched: 4, unreadable: [
            AudioMasterUnreadable(key: C.masterKey, reason: "not in the sound-print file")]))
        // A loader that THROWS is recorded with its error, not rethrown.
        struct Broken: Error, CustomStringConvertible { var description: String { "disk went away" } }
        let thrown = AudioMasterFinder.find(query: C.clip, queryKey: C.clipKey, in: index,
                                            load: { key -> AudioFingerprint? in
                                                if key == C.masterKey { throw Broken() }
                                                return full(key)
                                            })
        #expect(thrown == .noneFound(searched: 4, unreadable: [AudioMasterUnreadable(key: C.masterKey, reason: "disk went away")]))
    }

    @Test("a 12-landmark query is refused for too little sound")
    func tooLittleSoundIsRefusedNotNoneFound() throws {
        let tiny = AudioFingerprint(sampleRate: 8_000, hopSamples: 512, frameSize: 1_024, durationSeconds: 3,
                                    hashes: Array(C.clip.hashes.prefix(12)), times: Array(C.clip.times.prefix(12)))
        #expect(AudioMasterFinder.find(query: tiny, queryKey: CatalogIndexFixtures.key(50), in: try C.index(),
                                       load: C.loader()) == .refused(.tooLittleSound(landmarks: 12)))
    }

    @Test("a print from another recipe is refused")
    func otherRecipeQueryIsRefused() throws {
        let foreign = AudioFingerprint(recipeID: 0x1234_5678, sampleRate: 8_000, hopSamples: 512, frameSize: 1_024,
                                       durationSeconds: C.clip.durationSeconds, hashes: C.clip.hashes, times: C.clip.times)
        let index = try C.index()
        #expect(AudioMasterFinder.find(query: foreign, queryKey: CatalogIndexFixtures.key(51), in: index, load: C.loader())
                == .refused(.otherRecipe(query: 0x1234_5678, index: index.recipeID)))
    }

    @Test("a hash present in every content is skipped and the true master still ranks first")
    func catalogWideHumIsCappedAndClipStillFound() throws {
        // 200 contents, each carrying the clip's most common hash 3× at
        // random frames (> maxPostingsPerHash catalog-wide), plus noise.
        let hum = try #require(Dictionary(C.clip.hashes.map { ($0, 1) }, uniquingKeysWith: +).max { $0.value < $1.value }).key
        var entries = C.catalog
        for i in 0..<200 {
            let noise = CatalogIndexFixtures.randomPrint(count: 60, seed: UInt64(1_000 + i))
            let hashes = noise.hashes + [hum, hum, hum]
            let times = noise.times + [UInt32(i * 7), UInt32(i * 11), UInt32(i * 13)]
            entries.append((CatalogIndexFixtures.key(300 + i), AudioFingerprint(
                sampleRate: 8_000, hopSamples: 512, frameSize: 1_024, durationSeconds: 300, hashes: hashes, times: times)))
        }
        let index = try C.index(entries)
        #expect(index.postingCount(of: hum) > AudioMasterFinderPolicy.default.maxPostingsPerHash)
        let search = AudioMasterFinder.find(query: C.clip, queryKey: C.clipKey, in: index, load: C.loader(entries))
        guard case .found(let found, _, _) = search else { Issue.record("got \(search)"); return }
        #expect(found.first?.key == C.masterKey)
    }

    @Test("ranking: same › contained › contains › overlap › inconclusive; ties by coverage")
    func rankingOrder() {
        func candidate(_ n: Int, _ verdict: AudioMatchVerdict, coverage: Double) -> AudioMasterCandidate {
            let evidence = AudioMatchEvidence(matchedLandmarks: 100, coverage: coverage, overlapSeconds: 10, spanSeconds: 10,
                                              offsetSeconds: 0, queryDurationSeconds: 10, masterDurationSeconds: 10)
            return AudioMasterCandidate(key: CatalogIndexFixtures.key(n), match: AudioMatch(
                evidence: evidence, verdict: verdict, queryLandmarks: 100, masterLandmarks: 100,
                spanStartInMasterSeconds: 0, spanEndInMasterSeconds: 10), votes: 10)
        }
        let shuffled = [
            candidate(1, .inconclusive(reason: .bothIncomplete), coverage: 0.9),
            candidate(2, .overlap(offsetSeconds: 1, seconds: 8), coverage: 0.9),
            candidate(3, .masterContainedInQuery(offsetSeconds: 2), coverage: 0.9),
            candidate(4, .containedInMaster(offsetSeconds: 3), coverage: 0.6),
            candidate(5, .containedInMaster(offsetSeconds: 3), coverage: 0.95),
            candidate(6, .sameRecording, coverage: 0.7),
        ]
        #expect(AudioMasterFinder.rank(shuffled).map(\.key) == [6, 5, 4, 3, 2, 1].map { CatalogIndexFixtures.key($0) })
    }
}
