// MediaFileOperationOwnDetail.swift
// A job that builds its own expanded-row detail (2026-10-11). New verbs
// adopt this instead of adding another `else if let x = job as? T` branch to
// `MediaFileOperationDetail` (MediaFileOperationsWindow.swift) — the
// standing ruling "a growing switch → dispatch or data". The dispatcher asks
// this protocol last, in a plain `else`.
//
// (For Rick: ≈ a C++ virtual `detailView()` on the job, rather than a
// dynamic_cast ladder in the window.)

import SwiftUI

@MainActor
protocol MediaFileOperationOwnDetail {
    var detailView: AnyView { get }
}
