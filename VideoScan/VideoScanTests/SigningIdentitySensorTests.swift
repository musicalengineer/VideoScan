// SigningIdentitySensorTests.swift — the app and VideoScan Background are
// signed by a team (regression, #415, 2026-11-03). Signed with the team-less
// "VideoScan Local", launchd pinned the helper to its cdhash and killed every
// rebuilt helper at spawn ("Launch Constraint Violation", exit 78) while
// SMAppService still said enabled. With a team ID the constraint survives
// rebuilds (DECISIONS 2026-11-03). Red on main before the change: no
// DEVELOPMENT_TEAM, identity "VideoScan Local".
//
// SENSOR (source scan): reads the Xcode project file, nothing runs.
// C++ reading: a static_assert over the build configuration.

import Foundation
import Testing

@Suite("Signing — SENSOR: the app and its helper carry a team ID")
struct SigningIdentitySensorTests {
    static let project: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("VideoScan.xcodeproj/project.pbxproj")

    /// Each XCBuildConfiguration body that builds `bundleID`.
    static func configurations(for bundleID: String, in text: String) -> [Substring] {
        text.components(separatedBy: "isa = XCBuildConfiguration;").dropFirst()
            .map { $0.prefix(while: { $0 != "}" }) }
            .filter { $0.contains("PRODUCT_BUNDLE_IDENTIFIER = \"\(bundleID)\";") }
    }

    @Test func appAndHelperAreTeamSigned() throws {
        let text = try String(contentsOf: Self.project, encoding: .utf8)
        for id in ["Rick-Breen.VideoScan", "Rick-Breen.VideoScan.Background"] {
            let configs = Self.configurations(for: id, in: text)
            #expect(configs.count == 2, "\(id): Debug and Release, found \(configs.count)")
            for body in configs {
                #expect(body.contains("DEVELOPMENT_TEAM = V9SVEQF26M;"), "\(id) is signed by Rick's team (#415)")
                #expect(body.contains("\"CODE_SIGN_IDENTITY[sdk=macosx*]\" = \"Apple Development\";"), Comment(rawValue: id))
                #expect(!body.contains("VideoScan Local"), "\(id): a team-less identity brings back #415")
            }
        }
    }
}
