// ArchiveAngelListRowModel.swift
// The row model behind the Archive Angel recommendations list (Rick
// 2026-09-24, the senior-friendly redesign): ONE line of plain status words
// per file instead of a letter grade and a number — "Ready to archive", or
// "Needs …" naming what is missing — and which Promote path the row's
// button takes.
//
// PURE. Everything here is a function of a Sendable snapshot
// (`ArchiveAngelRowFacts`) taken from the catalog record + the Angel's
// evidence on the main actor, O(1) per row, OUTSIDE any view body. The
// builder is O(rows) and allocation-light (one row struct per input);
// ArchiveAngelListRowModelTests pins 10,000 rows under a time budget.
//
// Where the words come from (nothing new is judged here — every input is a
// verdict something else already made):
//   • the recommendation class (ArchiveAngelRecommendations): Needs a date,
//     Worth a look → "Needs a look";
//   • ArchiveReadiness.assess (audio verified? date state);
//   • the record's Verify Audio / Verify Video verdicts ("damaged" /
//     "broken" → repair).
//
// (For Rick: `enum` with no cases used as a namespace ≈ a C++ namespace or
// a class of static functions; an `enum` with associated values, like
// `ArchiveAngelNeed.audioRepair(note:)`, ≈ a tagged union / std::variant.)

import Foundation

// MARK: - Snapshot

/// What one row knows about its file — a value copy, safe off-main.
struct ArchiveAngelRowFacts: Sendable, Equatable, Identifiable {
    var id: UUID
    var filename: String
    var fullPath: String
    /// Uppercased extension as the scanner stores it ("MOV"); the player
    /// choice lowercases.
    var ext: String = ""
    var videoCodec: String = ""
    var audioCodec: String = ""
    var durationSeconds: Double = 0
    /// The EFFECTIVE class (batches' overlay + live refusal applied).
    var kind: ArchiveAngelRecommendationClass
    /// ArchiveReadiness's audio verdict.
    var audio: ArchiveReadiness.Audio = .noAudioTrack
    /// The record's raw Verify Audio status ("", "ok", "damaged").
    var audioVerifyStatus: String = ""
    var audioVerifyNote: String = ""
    /// ArchiveReadiness's date state.
    var date: ArchiveReadiness.DateState = .known
    /// A friendly date ("1994", "12 July 1994"), nil when undated.
    var dateLabel: String?
    /// Verify Video: "", "ok", "warning", "broken".
    var videoVerifyStatus: String = ""
    var videoVerifyNote: String = ""
    /// The scorer's printed evidence lines (ArchiveAngelEvidence.line).
    var evidenceLines: [String] = []
    /// The classifier's reasons (vouches, "3 copies — this one", …).
    var reasons: [String] = []
    /// The internal score — the sheet's grey footer only, never a row.
    var score: Int = 0
    /// Copies the classifier collapsed onto this one (1 = none).
    var copies: Int = 1
    /// Members of the catalog duplicate group (0 = no group).
    var duplicateCount: Int = 0
    var confirmedPeople: [String] = []
    /// Machine-detected / suspected names, not yet confirmed.
    var otherPeople: [String] = []
    var volumeName: String = ""
    /// Is the volume mounted right now?
    var isReachable: Bool = true
}

// MARK: - What is missing

/// One thing a file still needs before it is ready — in the order a person
/// should deal with them (repairs first: "bad audio is the one thing that
/// ruins a keeper", ArchiveReadiness).
enum ArchiveAngelNeed: Equatable, Sendable, Hashable {
    case audioRepair(note: String)
    case videoRepair(note: String)
    case date
    case audioCheck
    case look

    /// The words after "Needs " — kept short for the row.
    var fragment: String {
        switch self {
        case .audioRepair: return "audio repair"
        case .videoRepair: return "video repair"
        case .date: return "a date"
        case .audioCheck: return "audio checked"
        case .look: return "a look"
        }
    }

    /// Sort key — repairs, then the date, then checks, then a look.
    var rank: Int {
        switch self {
        case .audioRepair: return 0
        case .videoRepair: return 1
        case .date: return 2
        case .audioCheck: return 3
        case .look: return 4
        }
    }
}

enum ArchiveAngelStatusWords {

    /// What `f` still needs, ordered by `ArchiveAngelNeed.rank`. Empty for a
    /// class that is not a recommendation (the row says why instead).
    static func needs(_ f: ArchiveAngelRowFacts) -> [ArchiveAngelNeed] {
        guard f.kind.isRecommended else { return [] }
        var out: [ArchiveAngelNeed] = []
        // Audio: a damaged verdict is a repair; a verified-with-a-finding
        // ("silent audio") or never-verified track needs a listen.
        if f.audioVerifyStatus == "damaged" {
            out.append(.audioRepair(note: f.audioVerifyNote))
        } else {
            switch f.audio {
            case .notVerified, .verifiedProblem: out.append(.audioCheck)
            case .verifiedOK, .noAudioTrack: break
            }
        }
        switch f.videoVerifyStatus {
        case "broken": out.append(.videoRepair(note: f.videoVerifyNote))
        case "warning": out.append(.look)
        default: break
        }
        if f.kind == .needsDate || f.date == .undated { out.append(.date) }
        if f.kind == .worthALook, !out.contains(.look) { out.append(.look) }
        return out.sorted { $0.rank < $1.rank }
    }

    /// The row's words: "Ready to archive", "Needs a date",
    /// "Needs a date and audio checked", "Needs audio repair, a date and
    /// more"; a non-recommended class says what it is.
    static func words(kind: ArchiveAngelRecommendationClass, needs: [ArchiveAngelNeed]) -> String {
        switch kind {
        case .ready, .needsDate, .worthALook:
            switch needs.count {
            case 0: return kind == .ready ? "Ready to archive" : "Needs a look"
            case 1: return "Needs " + needs[0].fragment
            case 2: return "Needs " + needs[0].fragment + " and " + needs[1].fragment
            default: return "Needs " + needs[0].fragment + ", " + needs[1].fragment + " and more"
            }
        case .notNow: return "Not recommended right now"
        case .excluded: return "Left out of the archive list"
        case .anotherCopy: return "Another copy is the one to keep"
        case .prepared: return "Prepared — waiting for your review"
        case .promoted: return "Already in the archive"
        }
    }

    static func words(_ f: ArchiveAngelRowFacts) -> String { words(kind: f.kind, needs: needs(f)) }

    /// Ready means: the Angel says Ready AND nothing is missing.
    static func isReady(kind: ArchiveAngelRecommendationClass, needs: [ArchiveAngelNeed]) -> Bool {
        kind == .ready && needs.isEmpty
    }
}

// MARK: - Which Promote

/// The row's Promote button: a Ready file goes straight to the ordinary
/// Promote to Archive sheet (VideoScanModel.requestPromote — the same path
/// as the catalog's context menu, with its gates: read-only viewer, Master
/// Archive identity, FamilyArchive protection, byte-verify, MFO job); a file
/// that needs work goes to Archive Angel's Prepare for that ONE record
/// (verifies audio, makes companions, then the review sheet and Promote).
/// Neither adds a file-mutation path.
enum ArchiveAngelPromoteRoute: Equatable, Sendable {
    case direct
    case prepare
    case unavailable(String)

    static func route(kind: ArchiveAngelRecommendationClass, needs: [ArchiveAngelNeed]) -> ArchiveAngelPromoteRoute {
        if ArchiveAngelStatusWords.isReady(kind: kind, needs: needs) { return .direct }
        switch kind {
        case .ready, .needsDate, .worthALook: return .prepare
        case .prepared: return .unavailable("It is already prepared — review its batch below.")
        case .promoted: return .unavailable("It is already in the archive.")
        case .notNow, .excluded, .anotherCopy: return .unavailable("Archive Angel does not recommend it right now.")
        }
    }

    var buttonTitle: String {
        switch self {
        case .direct: return "Promote to Archive"
        case .prepare: return "Prepare to Archive"
        case .unavailable: return "Promote to Archive"
        }
    }

    var help: String {
        switch self {
        case .direct:
            return "Ready: opens Promote to Archive for this file — copied into the Master Archive, checked byte for byte, logged. The original is never moved or changed."
        case .prepare:
            return "Not ready yet: Archive Angel prepares this one file first (checks the sound, makes the archive copies it needs), then asks you to review it before anything is promoted."
        case .unavailable(let why):
            return why
        }
    }
}

// MARK: - Row

struct ArchiveAngelListRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let filename: String
    let path: String
    let statusWords: String
    let isReady: Bool
    let needs: [ArchiveAngelNeed]
    let route: ArchiveAngelPromoteRoute
    let isReachable: Bool
}

enum ArchiveAngelListRowBuilder {

    /// One row per snapshot, same order. O(n); ~200 B per row.
    static func rows(_ facts: [ArchiveAngelRowFacts]) -> [ArchiveAngelListRow] {
        var out: [ArchiveAngelListRow] = []
        out.reserveCapacity(facts.count)
        for f in facts { out.append(row(f)) }
        return out
    }

    static func row(_ f: ArchiveAngelRowFacts) -> ArchiveAngelListRow {
        let needs = ArchiveAngelStatusWords.needs(f)
        return ArchiveAngelListRow(
            id: f.id, filename: f.filename, path: f.fullPath,
            statusWords: ArchiveAngelStatusWords.words(kind: f.kind, needs: needs),
            isReady: ArchiveAngelStatusWords.isReady(kind: f.kind, needs: needs),
            needs: needs,
            route: ArchiveAngelPromoteRoute.route(kind: f.kind, needs: needs),
            isReachable: f.isReachable)
    }
}
