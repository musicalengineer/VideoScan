// TestDriverApp.swift
//
// SwiftUI app entry. One window. Tests are registered in the model's init.
// On launch we print a startup banner to stderr so the terminal that ran
// `swift run TestDriver` shows a marker — useful when correlating UI events
// with terminal output.

import SwiftUI

@main
struct TestDriverApp: App {
    init() {
        TermLog.log("app", "TestDriver launched — pid=\(ProcessInfo.processInfo.processIdentifier)")
        TermLog.log("app", "stderr is mirrored from every UI/model/subproc event")
        TermLog.log("app", "click \"Dump\" in the toolbar for full state any time")
    }

    var body: some Scene {
        WindowGroup("TestDriver — VideoScan") {
            ContentView()
        }
        .defaultSize(width: 1100, height: 700)
        .windowResizability(.contentMinSize)
    }
}
