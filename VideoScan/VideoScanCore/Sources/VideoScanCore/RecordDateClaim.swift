// RecordDateClaim.swift
// One file's date CLAIM for its recording (codex final review F2, rules v13):
// the evidence's precedence — a person's date, then a camera's stamp, then
// the dossier, then a year in the name — with confidence and precision behind
// it. A recording's year is its STRONGEST claim, never a vote: importing a
// thousand copies of a weak stamp adds nothing, and no number of transcoder
// stamps outvotes what Rick typed. `<` = "the stronger claim first", so `min`
// over a recording's members is its date; ties fall to the earliest year
// (deterministic).
//
// Neutral home (2026-09-27, GH #201 CI fix): the Archive Angel's coverage pass
// (`ArchiveAngelEvent.DateClaim` is a typealias of this) and the footage-group
// date sharing in VideoScanModel+DateInference both order claims this way.
// Keeping the type here stops the date code from reaching into the Angel's
// internals (ArchiveAngelBoundarySensorTests INBOUND ratchet).
//
// (For Rick: a POD with `operator<` for std::min_element.)

import Foundation

public struct RecordDateClaim: Comparable, Sendable, Equatable {
    public var sourceRank: Int        // 0 user · 1 camera/container stamp · 2 dossier · 3 filename
    public var confidenceMilli: Int   // higher = stronger
    public var precisionRank: Int     // 0 day … 3 decade (finer = stronger)
    public var year: Int

    /// `demoteSoftwareStamps` (GH #201, footage-group date sharing): a stamp
    /// with no camera behind it (≤ 0.85 — an export's or a transcoder's)
    /// ranks with the filename, BELOW the dossier: a copy date must not
    /// out-claim what the footage itself says. The Angel's coverage pass
    /// keeps the default (unchanged behaviour).
    public init?(_ r: RecordDateResolution, demoteSoftwareStamps: Bool = false) {
        guard let year = r.year else { return nil }
        switch r.source {
        case .userDate: sourceRank = 0
        case .embedded:
            sourceRank = demoteSoftwareStamps
                && r.confidence <= RecordDateResolver.embeddedConfidenceUnknownOrigin ? 3 : 1
        case .inferred: sourceRank = 2
        case .filename: sourceRank = 3
        case .none: return nil
        }
        confidenceMilli = Int((r.confidence * 1000).rounded())
        precisionRank = r.precision.rawValue
        self.year = year
    }

    public static func < (a: RecordDateClaim, b: RecordDateClaim) -> Bool {
        if a.sourceRank != b.sourceRank { return a.sourceRank < b.sourceRank }
        if a.confidenceMilli != b.confidenceMilli { return a.confidenceMilli > b.confidenceMilli }
        if a.precisionRank != b.precisionRank { return a.precisionRank < b.precisionRank }
        return a.year < b.year
    }
}
