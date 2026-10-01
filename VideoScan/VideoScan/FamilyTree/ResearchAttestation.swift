// ResearchAttestation.swift
// "Tell Hallie": a CONFIRMED research finding (plus Rick's lore) becomes a
// CyberBrain testimony through the same writer telling mode and the Family
// Tree notes pane use — one attributed item, one source record with the
// URL and retrieval date, confidence `confirmed` because the owner read the
// page and said so. Unreviewed / plausible / wrong findings never reach
// the writer; the caller filters and this builder refuses anyway.
//
// 2026-10-01 (GH #230): the source locator now follows the finding's kind.
// A record Rick FILED points at the filed document
// (`People/<folder>/Documents/<file>`); census and Discovery findings carry
// no locator (Discovery responses are never cached — their terms — and the
// census finding's URL is the public results page, not a cached page); the
// older sources keep pointing at their cached page.

import Foundation
import VideoScanCore

enum ResearchAttestation {

    enum AttestationError: Error, LocalizedError, Equatable {
        case notConfirmed(String)
        case alreadyTold(String)

        var errorDescription: String? {
            switch self {
            case .notConfirmed(let title): return "\"\(title)\" is not confirmed"
            case .alreadyTold(let title): return "\"\(title)\" was already told to Hallie"
            }
        }
    }

    /// The testimony for one confirmed finding. Pure.
    static func testimony(for finding: ResearchFinding,
                          subject: ResearchSubject,
                          speakerName: String,
                          date: Date) throws -> CyberBrainWriter.Testimony {
        guard finding.verdict == .confirmed else {
            throw AttestationError.notConfirmed(finding.title)
        }
        guard finding.toldItemID == nil else {
            throw AttestationError.alreadyTold(finding.title)
        }
        return CyberBrainWriter.Testimony(
            subjectName: subject.name,
            subjectAliases: subject.alternateNames,
            speakerName: speakerName,
            text: finding.attestationText,
            kind: kind(for: finding),
            date: date,
            origin: .researchFinding,
            gedcomPersonID: subject.gedcomPersonID,
            citation: CyberBrainWriter.Testimony.Citation(
                title: citationTitle(for: finding),
                url: finding.url,
                locator: locator(for: finding, subject: subject),
                sourceDate: finding.date,
                sourceKind: finding.source.cyberBrainSourceKind,
                retrievedAt: finding.retrievedAt))
    }

    /// Archive-relative path the CyberBrain source points at, or nil.
    static func locator(for finding: ResearchFinding, subject: ResearchSubject) -> String? {
        switch finding.source {
        case .recordFinder:
            return finding.documentPath
        case .irishCensus, .tnaDiscovery:
            return nil
        case .chroniclingAmerica, .findAGrave, .wikipedia, .wikidata, .web:
            return ResearchStore.relativeCachePath(key: subject.key, pageURL: finding.url)
        }
    }

    /// Newspaper, grave, census, catalogue and filed records are events in
    /// a life; encyclopedia and web pages read as biography.
    static func kind(for finding: ResearchFinding) -> CyberBrainItem.Kind {
        switch finding.source {
        case .chroniclingAmerica, .findAGrave, .irishCensus, .tnaDiscovery, .recordFinder: return .event
        case .wikipedia, .wikidata, .web: return .biography
        }
    }

    /// "Berkshire County Eagle, 1875-05-12" — the title Hallie cites.
    static func citationTitle(for finding: ResearchFinding) -> String {
        let base = finding.title.isEmpty ? finding.source.label : finding.title
        if let date = finding.date, !date.isEmpty, !base.contains(date) {
            return "\(base), \(date)"
        }
        return base
    }
}
