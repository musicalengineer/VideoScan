// TestDriverApp.swift
//
// SwiftUI app entry. One window. Tests are registered in the model's init.

import SwiftUI

@main
struct TestDriverApp: App {
    var body: some Scene {
        WindowGroup("TestDriver — VideoScan") {
            ContentView()
        }
        .defaultSize(width: 1100, height: 700)
    }
}
