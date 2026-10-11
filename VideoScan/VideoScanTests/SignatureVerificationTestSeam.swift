// SignatureVerificationTestSeam.swift
// TEST TARGET ONLY. `SignatureVerification.quarantineAndDelete` (quarantine
// + outright unlink, no production caller) was removed on 2026-10-11 (GH
// #143, tab-charter audit T5): the app is Trash only. The verifier suites
// that pin its IDENTITY checks (a rewrite in quarantine, an occupied
// original path, a Stop after the rename, a cleanup failure) still need the
// two steps back to back, so they compose them here and name the disposal
// they test. `.permanent` stays spellable only through `deleteQuarantined`'s
// explicit argument; the default is `.trash`.

import Foundation
@testable import VideoScan

extension SignatureVerification {
    /// Steps (a) and (b) back to back with an explicit disposal.
    static func quarantineThenDispose(_ proof: VerifiedDuplicate, disposal: Disposal,
                                      hooks: Hooks) -> DeletionResult {
        switch quarantine(proof, hooks: hooks) {
        case .quarantined(let ticket): return deleteQuarantined(ticket, disposal: disposal, hooks: hooks)
        case .refused(let failure): return .refused(failure)
        case .failed(let reason): return .failed(reason)
        case .retainedQuarantine(let path, let reason): return .retainedQuarantine(path: path, reason: reason)
        }
    }
}
