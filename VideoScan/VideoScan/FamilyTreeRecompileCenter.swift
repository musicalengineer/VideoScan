// FamilyTreeRecompileCenter.swift
// Hallie's "The family tree is on disk but needs recompiling … I can do
// that now" (live miss #8, 2026-08-29). One place that performs the
// recompile the Family Tree tab's banner button performs:
//   - through the tab's FamilyTreeLiveModel when one exists (registered
//     at init), so the orange banner clears and the tab installs the new
//     generation itself;
//   - otherwise standalone through FamilyGraphFileLoader.recompile on the
//     production store, then the shared cache is invalidated (the pointer
//     change already keys a miss; this makes it immediate).
// Either way Hallie's next load decodes the promoted generation.
//
// C++ readers: a main-thread singleton with a weak back-pointer to the
// tab's view-model; `async` methods suspend instead of blocking.

import Combine
import Foundation
import VideoScanCore

@MainActor
final class FamilyTreeRecompileCenter {
    static let shared = FamilyTreeRecompileCenter()

    enum Outcome: Equatable {
        /// A new generation was promoted; the tree is compiled again.
        case promoted
        /// Nothing was waiting on a recompile (already compiled, or no tree).
        case nothingPending
        /// The recompile ran and did not promote (a pull did not parse or
        /// the ingest was refused); the store log says why.
        case failed
    }

    private weak var liveModel: FamilyTreeLiveModel?
    private(set) var isRunning = false

    init() {}

    /// The production Family Tree tab model registers itself so the
    /// recompile runs through it (banner + install in one place).
    func register(_ model: FamilyTreeLiveModel) {
        liveModel = model
    }

    /// Recompile whatever is pending. `progress` receives the loader's
    /// phase captions ("Reading a.ged…", "Merging b.ged…", …) on the main
    /// actor. Overlapping calls: the second returns `.nothingPending`
    /// without running.
    func recompile(
        configuration: FamilyAssetConfiguration? = nil,
        store: FamilyGraphCompiledStore? = nil,
        cache: FamilyGraphSharedCache = .shared,
        progress: @escaping @MainActor (String) -> Void
    ) async -> Outcome {
        guard !isRunning else { return .nothingPending }
        isRunning = true
        defer { isRunning = false }

        // Path 1: the tab exists and shows the banner — its own recompile.
        if configuration == nil, store == nil,
           let model = liveModel, !model.needsRecompile.isEmpty {
            let phases = model.$loadPhase
                .compactMap { $0 }
                .receive(on: RunLoop.main)
                .sink { phase in progress(phase) }
            await model.recompile()
            phases.cancel()
            return model.needsRecompile.isEmpty ? .promoted : .failed
        }

        // Path 2: standalone, through the loader on the (injected or
        // production) store. Off the main actor; captions hop back.
        let configuration = configuration ?? FamilyAssetConfigurationCenter.shared.snapshot()
        let store = store ?? FamilyGraphCompiledStore.app
        let sources = cache.needsRecompile(for: configuration, store: store)
        guard !sources.isEmpty else { return .nothingPending }
        let directory = configuration.gedcomDirectory()
        let promoted = await Task.detached(priority: .userInitiated) { () -> Bool in
            var loader = FamilyGraphFileLoader(originalsDirectory: directory)
            loader.compiledStore = store
            loader.progress = { phase in
                Task { @MainActor in progress(phase) }
            }
            return loader.recompile(sources: sources) != nil
        }.value
        cache.invalidate()
        guard promoted else { return .failed }
        // A tab model that had not loaded yet (or loaded before the
        // refusal) picks the new generation up now rather than on its
        // next appearance.
        if let model = liveModel {
            await model.loadFromDisk()
        }
        return .promoted
    }
}
