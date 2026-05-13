// main.swift
//
// Entry point. Dispatches to either CLI mode or the SwiftUI app based on
// argv. This pattern requires removing @main from TestDriverApp (it now
// gets called explicitly via .main()).
//
// Same shape as VideoScan/main.swift — one binary, two surfaces.

import Foundation

if CommandLine.arguments.contains("--cli") {
    // Run CLI mode synchronously and exit.
    let args = Array(CommandLine.arguments.dropFirst())
    let exitCode = await CLI.run(arguments: args)
    exit(exitCode)
}

TestDriverApp.main()
