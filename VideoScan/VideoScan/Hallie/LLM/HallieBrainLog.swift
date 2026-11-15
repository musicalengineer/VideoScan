// HallieBrainLog.swift
// Which brain, for sure — the log lines that name it (Rick, 2026-11-15:
// "log which model, for sure, is failing … what model was loaded when a
// question was asked, though more importantly when it failed, what model
// failed and, if possible why").
//
// Before this, three lines of a failed turn named no brain at all:
//   [hallie] interpretation failed reason=bad-response
//   Hallie: phrased graph/answered by template (template: model timeout; …)
//   [hallie] brain provider set to cloud          (which cloud model?)
// and the one line that did name it cut the reason at 160 characters, which
// on 2026-11-15 cut off the very year the decoder was complaining about.
//
// Everything here is a pure formatter over values the caller already holds;
// the one network read (what the answering Ollama holds in memory after a
// local failure) is injected, so tests never touch a socket.
//
// C++ analogy: a caseless `enum` is a namespace of free functions.

import Foundation
import VideoScanCore

enum HallieBrainLog {

    /// "Cloud · claude-sonnet-5-5" / "qwen3.8:27b-mlx (local)" — the same
    /// spelling on every line, so one grep finds a brain's whole day.
    static func label(provider: HallieBrainProvider, model: String) -> String {
        provider == .cloud ? "Cloud · \(model)" : "\(model) (local)"
    }

    /// The brain the settings select right now. Mirrors HallieBrainResolver:
    /// anything but "cloud" is Local, and a test host never selects Cloud.
    static func selected(
        defaults: UserDefaults = .standard,
        localModel: String? = nil,
        allowCloud: Bool = !TestHostDetection.isTestHost
    ) -> (provider: HallieBrainProvider, model: String) {
        if allowCloud, HallieBrainSettings.provider(defaults) == .cloud {
            return (.cloud, HallieBrainSettings.cloudModel(defaults))
        }
        let local = localModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (.local, local.isEmpty ? HallieBrainSettings.localModel(defaults) : local)
    }

    static func selectedLabel(
        defaults: UserDefaults = .standard,
        localModel: String? = nil,
        allowCloud: Bool = !TestHostDetection.isTestHost
    ) -> String {
        let chosen = selected(defaults: defaults, localModel: localModel, allowCloud: allowCloud)
        return label(provider: chosen.provider, model: chosen.model)
    }

    /// What the chat window shows under Settings: the model name alone for a
    /// local brain, "Cloud · <model>" for a cloud one (what leaves the Mac is
    /// never unlabelled).
    static func windowLabel(provider: HallieBrainProvider, model: String) -> String {
        provider == .cloud ? "Cloud · \(model)" : model
    }

    /// One line per question that reaches a model lane: the brain the turn
    /// will ask. Never the question (the `[hallie-mode]` line above it has
    /// that).
    static func turnLine(brain: String) -> String {
        "[hallie] turn brain=\(brain)"
    }

    /// A settings change, naming the brain that is now selected.
    static func selectionLine(brain: String) -> String {
        "[hallie] brain set to \(brain)"
    }

    /// How much of a failure's reason the OUTCOME line keeps. The decoder's
    /// complaint is up to 200 characters and is followed by an excerpt of
    /// the reply (HallieBrainDecoding.replyExcerpt); 160 cut the reply off
    /// before the offending field.
    static let reasonLimit = 600

    /// Why a brain call failed, in words. A cancellation is named as one —
    /// "The operation couldn’t be completed. (Swift.CancellationError error
    /// 1.)" says nothing about who stopped it or after how long.
    static func failureReason(_ error: any Error, afterMs ms: Int) -> String {
        if error is CancellationError {
            return "cancelled after \(ms) ms (the caller's time limit, or Stop)"
        }
        let text = error.localizedDescription
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return String(text.prefix(reasonLimit))
    }

    /// "Hallie: phrased graph/answered by template brain=… (template: model
    /// timeout; dropped 0)". `brain` is nil only when no brain was resolved.
    static func phrasedLine(
        route: String, outcome: String, composedBy: String,
        brain: String?, note: String, dropped: Int
    ) -> String {
        let named = brain.map { " brain=\($0)" } ?? ""
        return "Hallie: phrased \(route)/\(outcome) by \(composedBy)\(named) (\(note); dropped \(dropped))"
    }

    /// Who the conversation record says answered. A turn that needed no
    /// translation carries "local (no model)"; when a model then PHRASED the
    /// answer, the record names that model instead. A translated turn keeps
    /// its translator, and a template answer keeps what it had.
    static func recordedResponder(
        turn: String, composedByModel: Bool, composer: String?
    ) -> String {
        guard turn == HallieAppTurnCoordinator.localResponder, composedByModel,
              let composer, !composer.isEmpty else { return turn }
        return composer
    }

    /// After a LOCAL brain call fails: what the answering server holds in
    /// memory at that moment, so "the model was cold" and "a different model
    /// was loaded" are readable from the log. `/api/ps` answers an empty list
    /// both for "nothing loaded" and for "no answer", and the line says so.
    static func residentLine(
        host: String, wanted: String, resident: [OllamaQueryTranslator.ModelFacts]
    ) -> String {
        let prefix = "[hallie-brain] after the failure, \(host): "
        guard !resident.isEmpty else {
            return prefix + "“\(wanted)” NOT loaded; nothing in memory (or the server did not answer)"
        }
        let names = resident.map(\.name).joined(separator: ", ")
        let state = resident.contains { $0.name == wanted } ? "loaded" : "NOT loaded"
        return prefix + "“\(wanted)” \(state); in memory: \(names)"
    }
}

extension HallieAppTurnCoordinator.Dependencies {
    /// The `[hallie] turn brain=` line, when these dependencies ask a real
    /// brain (stub dependencies name none, so a test writes nothing).
    func announceTurnBrain(
        localModel: String, write: (String) -> Void = { appLog.write($0) }
    ) {
        guard let brain = selectedBrainLabel(localModel) else { return }
        write(HallieBrainLog.turnLine(brain: brain))
    }
}
