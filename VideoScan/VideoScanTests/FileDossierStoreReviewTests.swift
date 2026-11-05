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
}
