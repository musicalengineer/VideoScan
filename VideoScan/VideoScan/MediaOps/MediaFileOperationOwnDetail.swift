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

/// A finished row's prominent one-line answer, shown in place of the plain
/// subtitle (Find Master's "FOUND this clip in 3 recordings (10 files)",
/// 2026-10-26). `isFound` paints it green, semibold, a size up; otherwise it
/// is the ordinary secondary subtitle.
struct MediaFileOperationHeadline: Equatable, Sendable {
    let text: String
    let isFound: Bool
}

/// A job that can state its result as a headline (nil while running).
/// (For Rick: another optional virtual on the job, asked by the row.)
@MainActor
protocol MediaFileOperationHeadlineProviding {
    var headline: MediaFileOperationHeadline? { get }
}
