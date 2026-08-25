// HallieHelperFailure.swift
// What Hallie says when her language helper lets her down (2026-08-25).
//
// Before this file both the app and the shell said "I'm having trouble
// REACHING my language helper" for every translator error — including
// the common one, where the helper answered fine and the answer failed
// strict decoding. Telling Rick the network is flaky when the model
// simply misspoke sends him to check hosts that are up. The message now
// says which of the two happened, and only the transport case suggests
// waiting; the decode case suggests rephrasing, which is the fix that
// actually works.

import Foundation

enum HallieHelperFailure {

    /// The two things Rick can do something about.
    enum Kind: Equatable {
        /// Host asleep, off-network, 5xx, model not loaded: wait / wake.
        case unreachable
        /// The helper answered but the strict decoder refused it, even
        /// after one repair retry: rephrase.
        case unusableAnswer
        /// The helper was REACHED and refused the request (HTTP 4xx):
        /// a model-name / endpoint / configuration problem, not the network
        /// and not something a moment's wait fixes (codex #671).
        case badRequest(status: Int)
    }

    static func kind(of error: Error) -> Kind {
        if let nl = error as? NLTranslatorError {
            switch nl {
            case .badResponse: return .unusableAnswer
            case .serverError(let status, _) where (400...499).contains(status):
                return .badRequest(status: status)
            default: break
            }
        }
        return .unreachable
    }

    /// Spoken/typed reply. Both cases keep the safety sentence: nothing
    /// was searched or opened.
    static func message(for error: Error) -> String {
        switch kind(of: error) {
        case .unreachable:
            return "I'm having trouble reaching my language helper just now. "
                + "I didn't search the archive or open anything; "
                + "please try that again in a moment."
        case .unusableAnswer:
            return "I heard you, but I couldn't turn that into a search I trust, "
                + "even on a second try. I didn't search the archive or open anything; "
                + "could you say it another way?"
        case .badRequest(let status):
            return "My language helper answered, but refused the request (HTTP \(status)) — "
                + "that's a setup problem on my side, like the model name or endpoint, not the network. "
                + "I didn't search the archive or open anything; please check the Hallie helper settings."
        }
    }

    static let basisLine = "No catalog query or media action was performed."
}
