// MediaFileOperationsCenterReference.swift
// A way for a view to CALL the Media File Operations center without
// SUBSCRIBING to it.
//
// `@EnvironmentObject var center: MediaFileOperationsCenter` does two
// things at once: it hands the view the object AND registers the view as a
// listener on the object's `objectWillChange` — every publish re-runs the
// view's body. (C++ analogy: taking the reference also calls
// `center.addObserver(this)`, and there's no way to opt out.) The center
// re-broadcasts every running job's progress, throttled to 4 Hz, so any
// view holding it that way re-renders four times a second while a job
// runs.
//
// That is right for views that SHOW jobs (the MFO window, the Archive
// tab's progress), and wrong for views that only START one from a button.
// CatalogView was the second kind, and its 4 Hz re-render kept collapsing
// the toolbar's "Delete Duplicates on Volume…" submenu (Rick 2026-09-22).
//
// An environment VALUE holding a class reference gives the reference
// without the subscription: SwiftUI compares environment values by
// identity, and the center instance never changes, so nothing re-renders.
// Injected once at the main window by VideoScanApp, next to the
// `.environmentObject(fileOpsCenter)` the job-showing views still use.

import SwiftUI

private struct MediaFileOperationsCenterReferenceKey: EnvironmentKey {
    /// nil until VideoScanApp injects the app's one center. A view that
    /// finds nil here is running outside the app's window (a preview or a
    /// test host) and must refuse loudly rather than start nothing
    /// silently — see `CatalogView.startFileOperation`.
    static let defaultValue: MediaFileOperationsCenter? = nil
}

extension EnvironmentValues {
    /// The app's Media File Operations center, NON-observing: reading it
    /// does not re-render the view when jobs publish progress. Use
    /// `@EnvironmentObject` instead when the view displays job state.
    var mediaFileOperationsCenterReference: MediaFileOperationsCenter? {
        get { self[MediaFileOperationsCenterReferenceKey.self] }
        set { self[MediaFileOperationsCenterReferenceKey.self] = newValue }
    }
}
