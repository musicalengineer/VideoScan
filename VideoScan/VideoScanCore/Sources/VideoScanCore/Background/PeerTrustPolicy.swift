// PeerTrustPolicy.swift — VideoScanCore/Background
//
// "Any process on the Mac can otherwise open a Mach service" (design §3.3):
// the helper's XPC listener checks the caller's code signature before
// accepting a connection. The Security-framework calls live in the helper
// (XPCServer.swift); the DECISION lives here, pure, so it has a test.
//
// Rule: the peer must carry one of the allowed bundle identifiers (the app,
// or the helper itself acting as the `videoscan-bg` CLI) AND be signed by
// the same leaf certificate as the helper ("VideoScan Local", DECISIONS
// 2026-10-28). A build with no certificate (ad hoc — the sensor lane signs
// with `-`) has no leaf to compare, so the identifier is the whole check and
// the log says so; that is a developer-only state.

import Foundation

public enum PeerTrustPolicy {

    public enum Decision: Equatable, Sendable {
        case accept(note: String?)
        case refuse(words: String)

        public var isAccepted: Bool {
            if case .accept = self { return true }
            return false
        }
    }

    /// - selfLeafSHA1: hex SHA-1 of the helper's own leaf certificate; nil
    ///   when ad-hoc signed.
    /// - peerIdentifier / peerLeafSHA1: the same for the connecting process,
    ///   nil when it is unsigned or the attribute could not be read.
    public static func decide(selfLeafSHA1: String?, allowedIdentifiers: Set<String>,
                              peerIdentifier: String?, peerLeafSHA1: String?, peerPID: Int32) -> Decision {
        guard let peerIdentifier else {
            return .refuse(words: "XPC peer pid \(peerPID) has no code signing identifier — refused")
        }
        guard allowedIdentifiers.contains(peerIdentifier) else {
            return .refuse(words: "XPC peer pid \(peerPID) is `\(peerIdentifier)`, not one of \(allowedIdentifiers.sorted()) — refused")
        }
        guard let selfLeafSHA1 else {
            return .accept(note: "ad-hoc build: peer `\(peerIdentifier)` pid \(peerPID) accepted on identifier alone (no certificate to compare)")
        }
        guard let peerLeafSHA1 else {
            return .refuse(words: "XPC peer `\(peerIdentifier)` pid \(peerPID) carries no certificate but this build is signed — refused")
        }
        guard peerLeafSHA1.lowercased() == selfLeafSHA1.lowercased() else {
            return .refuse(words: "XPC peer `\(peerIdentifier)` pid \(peerPID) is signed by a different certificate — refused")
        }
        return .accept(note: nil)
    }
}

/// The code-signing requirement the helper puts on every XPC connection
/// (`NSXPCConnection.setCodeSigningRequirement`, audit-token based — no pid),
/// built from the helper's OWN designated requirement with the identifier
/// clause widened to "the app or this helper". A "VideoScan Local"-signed
/// helper thereby accepts only a "VideoScan Local"-signed VideoScan (or
/// itself in CLI mode). Pure, so the string construction has a test; the
/// two-process check is Rick's spot test.
public enum PeerRequirement {
    /// nil when the helper's requirement is not certificate-based (an ad-hoc
    /// build's `cdhash H"…"`) or does not name the helper's identifier — the
    /// caller then falls back to `PeerTrustPolicy` by identifier and says so.
    public static func forPeers(helperDesignatedRequirement requirement: String,
                                helperIdentifier: String, appIdentifier: String) -> String? {
        let clause = "identifier \"\(helperIdentifier)\""
        guard !requirement.contains("cdhash"), let range = requirement.range(of: clause) else { return nil }
        return requirement.replacingCharacters(in: range, with: "(identifier \"\(appIdentifier)\" or \(clause))")
    }
}
