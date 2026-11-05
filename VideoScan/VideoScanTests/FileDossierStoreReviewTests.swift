// FileDossierStoreReviewTests.swift — review finding on feat/file-dossier-view
// (193f4710c, 2026-11-05). RED on that commit; names the line it pins.

import Combine
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("File dossier — the store (review, red on 193f4710c)")
@MainActor
struct FileDossierStoreReviewTests {

    // FileDossierStore.swift:115 (and :64 in production): `.debounce` on the
    // change signal. A catalog that saves more often than the debounce window
    // (a batch Analyze run saves per file; every save bumps
    // `catalogMutationRevision`) never lets it fire, so an open dossier keeps
    // its pre-run lines for the length of the run. The header promises "the
    // view fills in as results land"; a throttle(latest:) would keep it.
    @Test(.timeLimit(.minutes(1)))
    func aSteadyStreamOfCommitsStillReachesTheOpenDossier() async throws {
        let subject = PassthroughSubject<Void, Never>()
        let store = FileDossierStore()
        let loader = FileDossierStoreTests.loader({ id in FileDossierStoreTests.dossier(id, "A.mov") },
                                                  changes: subject.eraseToAnyPublisher())
        await store.show(fileID: UUID(), loader: loader)
        #expect(store.reads == 1)
        for _ in 0..<10 {                       // 4 s of commits, 400 ms apart
            subject.send(())
            try await Task.sleep(for: .milliseconds(400))
        }
        #expect(store.reads >= 2, "no re-read during 4 s of steady commits: \(store.reads)")
    }

    // Coverage review 11/05 (D): FileDossierStore.swift:154-159 subscribed to
    // the FIRST loader's `changes` only; a later `show` with a different
    // loader kept listening to the old one, so the new loader's commits never
    // re-read the open dossier.
    @Test(.timeLimit(.minutes(1)))
    func aNewLoaderBringsItsOwnChangeSignal() async throws {
        let first = PassthroughSubject<Void, Never>(), second = PassthroughSubject<Void, Never>()
        let store = FileDossierStore()
        let id = UUID()
        let load: FileDossierLoader.Load = { id in FileDossierStoreTests.dossier(id, "A.mov") }
        await store.show(fileID: id, loader: FileDossierStoreTests.loader(load, changes: first.eraseToAnyPublisher()))
        await store.show(fileID: id, loader: FileDossierStoreTests.loader(load, changes: second.eraseToAnyPublisher()))
        let before = store.reads
        second.send(())
        try await Task.sleep(for: .milliseconds(600))
        #expect(store.reads > before, "the second loader's change did not re-read the dossier")
        let after = store.reads
        first.send(())
        try await Task.sleep(for: .milliseconds(1_500))
        #expect(store.reads == after, "the replaced loader's signal still drives reads")
    }
}
