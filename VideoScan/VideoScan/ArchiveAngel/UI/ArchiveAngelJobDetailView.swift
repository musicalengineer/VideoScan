// ArchiveAngelJobDetailView.swift
// The Media File Operations window's plug-in point for an Archive Angel job
// (public surface): the window asks "is this job an Angel's?" by building
// one of these — a failable init, nil for any other kind — and never names
// ArchiveAngelJob or ArchiveAngelDetailView itself. Consolidation S2.
//
// (For Rick: `init?` is a constructor that can return nil ≈ a factory
// returning a null pointer, here "not my job type".)

import SwiftUI

struct ArchiveAngelJobDetailView: View {
    private let job: ArchiveAngelJob

    init?(job: any MediaFileOperationJob) {
        guard let angel = job as? ArchiveAngelJob else { return nil }
        self.job = angel
    }

    var body: some View {
        ArchiveAngelDetailView(job: job)
    }
}
