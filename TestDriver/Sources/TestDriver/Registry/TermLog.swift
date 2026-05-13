// TermLog.swift
//
// Mirrors UI events to stderr so Rick can run `swift run TestDriver`
// in a terminal and monitor what TestDriver is doing even when the UI
// freezes / acts weird. Every meaningful event in the model + UI flows
// through `term(...)` so a single grep on the terminal output shows
// the full timeline.

import Foundation

enum TermLog {
    private static let queue = DispatchQueue(label: "com.testdriver.termlog")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Write one line to stderr with a timestamp + tag + message.
    /// Tag is something short like "ui", "model", "subproc", "test".
    static func log(_ tag: String, _ message: String) {
        let line = "[\(formatter.string(from: Date()))] [\(tag)] \(message)\n"
        queue.async {
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}
