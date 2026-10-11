// JunkDeletionModeTestSeam.swift
// TEST TARGET ONLY. The prune / junk suites remove their synthetic fixtures
// outright so nothing reaches the real Trash. Since codex delete-engines F1
// (2026-10-09) the app's junk engine has no permanent removal of its own:
// `.permanent` exists only here, as the engine's injected-operation seam
// with a `removeItem` written in the test bundle. No production source can
// spell it (JunkPermanentUnreachableTests).

import Foundation
@testable import VideoScan

extension VideoScanModel.JunkDeletionMode {
    /// Remove the fixture outright, through the engine's test seam.
    static let permanent = Self.removeThroughTestSeam { url in
        try FileManager.default.removeItem(at: url)
    }
}
