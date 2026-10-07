// CyberBrainWriter+Sources.swift
import CryptoKit
import Foundation

extension CyberBrainWriter {
    /// Prefix shared by every research source id, so readers (Hallie's
    /// "what do we know about X from research") can tell research
    /// attestations from told-me and note items without a schema change.
    public static let researchSourceIDPrefix = "source.research."
    /// The source notes start with this + the page URL (see `Citation.url`).
    public static let researchURLNotePrefix = "URL: "

    /// The web address a research source was fetched from, read back from
    /// its notes; nil for any other kind of source.
    public static func researchURL(of source: CyberBrainSource) -> String? {
        guard source.id.hasPrefix(researchSourceIDPrefix),
              let notes = source.notes, notes.hasPrefix(researchURLNotePrefix)
        else { return nil }
        let rest = notes.dropFirst(researchURLNotePrefix.count)
        let url = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first
            .map(String.init) ?? ""
        return url.isEmpty ? nil : url
    }

    /// The research source id for one cited document:
    /// `source.research.<slug(url)>.<12 hex of SHA-256(locator, title, date)>`.
    /// The URL slug stays first so the page is still visible in the id, and
    /// `researchURL(of:)` (which reads the notes) is unchanged. A source an
    /// older build wrote under the URL-only id is reused when it describes
    /// the SAME document (same locator, title and date), so passages filed
    /// before the change stay idempotent and are never duplicated.
    static func researchSourceID(for citation: Testimony.Citation, title: String,
                                 in sources: [CyberBrainSource]) -> String {
        let legacyID = researchSourceIDPrefix + slug(citation.url)
        if let legacy = sources.first(where: { $0.id == legacyID }),
           legacy.locator == citation.locator, legacy.title == title,
           legacy.sourceDate?.value == citation.sourceDate {
            return legacyID
        }
        let identity = [citation.locator ?? "", title, citation.sourceDate ?? ""].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(identity.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return legacyID + "." + digest
    }

    /// Adds the origin's source when needed, preserving existing source order.
    static func appendTestimonySource(_ testimony: Testimony, dayStamp: String, speakerLabel: String,
                                      to sources: inout [CyberBrainSource]) throws
        -> (id: String, itemPrefix: String, confidence: CyberBrainItem.Confidence) {
        let sourceID: String
        let itemPrefix: String
        let confidence: CyberBrainItem.Confidence
        switch testimony.origin {
        case .conversation:
            sourceID = appendConversationSource(speakerLabel: speakerLabel, dayStamp: dayStamp, to: &sources)
            itemPrefix = "told"
            // Recorded, attributed, NOT verified. Verification is a later,
            // human step; nothing told in conversation starts as confirmed.
            confidence = .probable
        case .familyTreeNote:
            sourceID = "source.family-tree-notes-" + slug(speakerLabel) + "." + dayStamp
            itemPrefix = "note"
            confidence = .confirmed
            if !sources.contains(where: { $0.id == sourceID }) {
                sources.append(CyberBrainSource(
                    id: sourceID,
                    type: .profileNote,
                    title: "Family Tree notes (\(speakerLabel))",
                    attribution: speakerLabel,
                    sourceDate: CyberBrainQualifiedDate(
                        value: dayStamp, precision: .day, qualifier: .exact,
                        displayText: dayStamp),
                    notes: "Written in the Family Tree inspector about a specific GEDCOM record."))
            }
        case .researchFinding:
            guard let citation = testimony.citation, !citation.url.isEmpty else {
                throw WriteError.ioFailure("a research finding needs a citation with a URL")
            }
            // One source per DOCUMENT (locator, title, date): the same page
            // confirmed twice (two excerpts) shares its record; two records
            // filed from one results page, or a record re-filed under a
            // corrected type, never do (adversarial review 2026-10-01,
            // 61c81eab — the second used to cite the first's document).
            let sourceTitle = citation.title.isEmpty ? citation.url : citation.title
            sourceID = researchSourceID(for: citation, title: sourceTitle, in: sources)
            itemPrefix = "research"
            // Rick read the page and pressed Confirmed — the owner's verdict
            // on a document, the same standing as his own tree note.
            confidence = .confirmed
            if !sources.contains(where: { $0.id == sourceID }) {
                let retrieved = dayString(citation.retrievedAt)
                sources.append(CyberBrainSource(
                    id: sourceID,
                    type: citation.sourceKind,
                    title: sourceTitle,
                    attribution: "confirmed by \(speakerLabel)",
                    sourceDate: citation.sourceDate.map {
                        CyberBrainQualifiedDate(
                            value: $0, precision: $0.count >= 10 ? .day : .year,
                            qualifier: .exact, displayText: $0)
                    },
                    locator: citation.locator,
                    notes: researchURLNotePrefix + citation.url
                        + " · Found by Research Person, retrieved \(retrieved); confirmed by \(speakerLabel) on \(dayStamp)."))
            }
        }

        return (sourceID, itemPrefix, confidence)
    }

    static func appendConversationSource(speakerLabel: String, dayStamp: String,
                                         to sources: inout [CyberBrainSource]) -> String {
        let sourceID = "source.told-by-" + slug(speakerLabel) + "." + dayStamp
        if !sources.contains(where: { $0.id == sourceID }) {
            sources.append(CyberBrainSource(
                id: sourceID,
                type: .familyWitness,
                title: "Told to Hallie by \(speakerLabel), \(dayStamp)",
                attribution: speakerLabel,
                sourceDate: CyberBrainQualifiedDate(
                    value: dayStamp, precision: .day, qualifier: .exact,
                    displayText: dayStamp),
                notes: "Recorded in conversation; not yet verified against documents."))
        }
        return sourceID
    }

    static func appendCaptionSources(_ caption: PhotoCaption, speakerLabel: String, dayStamp: String,
                                     to sources: inout [CyberBrainSource]) -> (photo: String, told: String) {
        let photoURL = URL(fileURLWithPath: caption.photoPath)
        let photoSourceID = "source.photo." + slug(
            photoURL.deletingLastPathComponent().lastPathComponent + "-" + photoURL.lastPathComponent)
        if !sources.contains(where: { $0.id == photoSourceID }) {
            sources.append(CyberBrainSource(
                id: photoSourceID,
                type: .mediaEvidence,
                title: "Photo: \(photoURL.lastPathComponent)",
                attribution: speakerLabel,
                sourceDate: nil,
                locator: photoLocator(caption.photoPath),
                notes: "A photo in the family archive, captioned in conversation. Full path when captioned: \(caption.photoPath)"))
        }
        let toldSourceID = appendConversationSource(speakerLabel: speakerLabel, dayStamp: dayStamp, to: &sources)
        return (photoSourceID, toldSourceID)
    }
}
