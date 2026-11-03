// BackgroundHelperBundleSensorTests.swift — VideoScan Background builds on its
// own and looks like itself (Rick 2026-11-03): a shared "VideoScan Background"
// scheme builds the helper target alone (no app), and the helper's icon is its
// own teal set, not the app's — so Activity Monitor, Login Items and Full Disk
// Access tell the two apart.
//
// SENSOR (source scan): reads the scheme, the project file and the icon set.

import Foundation
import Testing

@Suite("VideoScan Background — SENSOR: its own scheme and its own icon")
struct BackgroundHelperBundleSensorTests {
    static let projectRoot: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    @Test func schemeBuildsTheHelperAlone() throws {
        let scheme = try String(contentsOf: Self.projectRoot.appendingPathComponent(
            "VideoScan.xcodeproj/xcshareddata/xcschemes/VideoScan Background.xcscheme"), encoding: .utf8)
        #expect(scheme.contains("BuildableName = \"VideoScan Background.app\""))
        #expect(!scheme.contains("BuildableName = \"VideoScan.app\""), "the scheme must not build the app")
    }

    @Test func helperHasItsOwnIcon() throws {
        let project = try String(contentsOf: Self.projectRoot.appendingPathComponent("VideoScan.xcodeproj/project.pbxproj"), encoding: .utf8)
        let helperConfigs = SigningIdentitySensorTests.configurations(for: "Rick-Breen.VideoScan.Background", in: project)
        #expect(helperConfigs.count == 2)
        for body in helperConfigs {
            #expect(body.contains("ASSETCATALOG_COMPILER_APPICON_NAME = BackgroundIcon;"))
        }
        let fm = FileManager.default
        let mine = Self.projectRoot.appendingPathComponent("VideoScanBackground/Assets.xcassets/BackgroundIcon.appiconset")
        let apps = Self.projectRoot.appendingPathComponent("VideoScan/Assets.xcassets/AppIcon.appiconset")
        let pngs = try fm.contentsOfDirectory(atPath: apps.path).filter { $0.hasSuffix(".png") }.sorted()
        #expect(pngs.count == 10)
        for name in pngs {
            let a = try Data(contentsOf: apps.appendingPathComponent(name))
            let b = try Data(contentsOf: mine.appendingPathComponent(name))
            #expect(a != b, "\(name): the helper's icon must differ from the app's")
        }
    }
}
