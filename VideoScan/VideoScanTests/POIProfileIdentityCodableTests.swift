// POIProfileIdentityCodableTests.swift
// CODABLE + ISOLATION dimensions for the POI identity-metadata feature
// (feature-test checklist items 1 & 4).
//
// POIProfile gained sex / hairColor / eyeColor / identityNotes in 2026-07.
// profile.json is Rick's on-disk persistence format, so the contract cuts
// both ways:
//   • OLD json (no new keys) must decode with nils — no migration step
//   • json with an unknown enum rawValue (a future palette addition read
//     by an older build) must degrade that FIELD to nil, never brick the
//     whole profile load
//   • a profile with the new fields UNSET must encode with NO new keys,
//     so older readers see byte-compatible json
//
// ISOLATION (settings-pollution class): every file this suite touches
// lives in a per-test temp dir. POIProfile.save()/load()/listAll() are
// hard-wired to ~/Library/Application Support/VideoScan/POI/ and are
// deliberately NOT exercised — nothing here may read or write real App
// Support or UserDefaults.

import Testing
import Foundation
@testable import VideoScan

struct POIProfileIdentityCodableTests {

    private func date(_ y: Int, _ m: Int = 6, _ d: Int = 15) -> Date {
        var dc = DateComponents()
        dc.year = y; dc.month = m; dc.day = d; dc.hour = 12
        dc.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: dc) ?? .distantPast
    }

    /// Fresh scratch dir under the system temp root — never App Support.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_poi_codable_\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Round trip with everything set

    @Test func roundTripThroughTempFilePreservesAllIdentityFields() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = POIProfile(
            name: "Donna", referencePath: dir.path,
            birthdate: date(1959), deathdate: nil,
            sex: .female, hairColor: .blonde, eyeColor: .blue,
            identityNotes: "long golden hair, big smile"
        )

        let url = dir.appendingPathComponent("profile.json")
        try JSONEncoder().encode(original).write(to: url)
        let decoded = try JSONDecoder().decode(
            POIProfile.self, from: Data(contentsOf: url))

        // POIProfile is Equatable — one comparison covers every field,
        // old and new (≈ operator== over all members).
        #expect(decoded == original)
        // And pin the new fields individually so a future Equatable
        // change can't silently hollow out the assertion above.
        #expect(decoded.sex == .female)
        #expect(decoded.hairColor == .blonde)
        #expect(decoded.eyeColor == .blue)
        #expect(decoded.identityNotes == "long golden hair, big smile")
    }

    // MARK: - Legacy json (pre-feature) decodes with nils

    @Test func legacyJSONWithoutNewKeysDecodesWithNilIdentityFields() throws {
        // The minimal shape a pre-2026-07 profile.json could have.
        let legacy = """
        {"name": "Grandpa", "referencePath": "/old/path"}
        """
        let p = try JSONDecoder().decode(
            POIProfile.self, from: Data(legacy.utf8))
        #expect(p.name == "Grandpa")
        #expect(p.sex == nil)
        #expect(p.hairColor == nil)
        #expect(p.eyeColor == nil)
        #expect(p.identityNotes == nil)
        // Pre-existing defaulting behavior still intact alongside.
        #expect(p.engine == RecognitionEngine.vision.rawValue)
        #expect(p.birthdate == nil)
    }

    // MARK: - Unknown enum rawValue degrades to nil, never throws

    @Test func unknownEnumRawValuesDegradeToNilNotThrow() throws {
        // A future build writes a palette color this build doesn't know.
        // The load must succeed with those FIELDS nil ("a bad color must
        // never brick a profile load" — PersonFinderTypes.swift).
        let futuristic = """
        {
            "name": "Timmy",
            "referencePath": "/p",
            "sex": "purple",
            "hairColor": "purple",
            "eyeColor": "purple"
        }
        """
        let p = try JSONDecoder().decode(
            POIProfile.self, from: Data(futuristic.utf8))
        #expect(p.name == "Timmy")
        #expect(p.sex == nil)
        #expect(p.hairColor == nil)
        #expect(p.eyeColor == nil)
    }

    @Test func badRawValueInOneFieldDoesNotDropTheOthers() throws {
        // Fields degrade independently: a bad hairColor must not take
        // a valid sex or eyeColor down with it.
        let mixed = """
        {
            "name": "Donna",
            "referencePath": "/p",
            "sex": "female",
            "hairColor": "chartreuse",
            "eyeColor": "blue"
        }
        """
        let p = try JSONDecoder().decode(
            POIProfile.self, from: Data(mixed.utf8))
        #expect(p.sex == .female)
        #expect(p.hairColor == nil)
        #expect(p.eyeColor == .blue)
    }

    // MARK: - Unset fields emit NO new keys (old readers unaffected)

    @Test func encodingProfileWithUnsetIdentityFieldsEmitsNoNewKeys() throws {
        let plain = POIProfile(name: "Old Timer", referencePath: "/p")
        let data = try JSONEncoder().encode(plain)
        let obj = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["sex", "hairColor", "eyeColor", "identityNotes"] {
            #expect(obj[key] == nil,
                    "unset field '\(key)' leaked into json — old readers would see an unexpected key")
        }
    }

    @Test func encodingProfileWithSetIdentityFieldsEmitsRawValues() throws {
        let p = POIProfile(
            name: "Donna", referencePath: "/p",
            sex: .female, hairColor: .blonde, eyeColor: .blue,
            identityNotes: "notes"
        )
        let data = try JSONEncoder().encode(p)
        let obj = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Raw string values are the persistence format — renaming an
        // enum case is a format change (see PersonFinderTypes.swift).
        #expect(obj["sex"] as? String == "female")
        #expect(obj["hairColor"] as? String == "blonde")
        #expect(obj["eyeColor"] as? String == "blue")
        #expect(obj["identityNotes"] as? String == "notes")
    }

    // MARK: - Old-reader simulation: set fields survive a legacy rewrite

    @Test func legacyDecodeReEncodeDoesNotInventIdentityKeys() throws {
        // Simulates an older-profile load → save cycle in the new build:
        // decoding legacy json and re-encoding it must not conjure the
        // new keys out of thin air.
        let legacy = """
        {"name": "Grandpa", "referencePath": "/old/path"}
        """
        let p = try JSONDecoder().decode(
            POIProfile.self, from: Data(legacy.utf8))
        let data = try JSONEncoder().encode(p)
        let obj = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["sex", "hairColor", "eyeColor", "identityNotes"] {
            #expect(obj[key] == nil)
        }
    }
}
