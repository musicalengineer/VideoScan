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

    /// The bundled launchd plist (Rick 2026-11-04; launchd.plist(5)): kept
    /// alive by launchd — restart on a crash or an error exit, stay down after
    /// a clean exit 0 — and not classed Background/Standard, which throttle CPU
    /// and I/O; the priority comes from the worker's utility QoS.
    @Test("SENSOR: the bundled plist carries KeepAlive {SuccessfulExit false, Crashed true}, RunAtLoad, Interactive, a throttle")
    func plistKeepAliveKeys() throws {
        let url = Self.projectRoot.appendingPathComponent("VideoScanBackground/Rick-Breen.VideoScan.Background.plist")
        let plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        let keepAlive = try #require(plist["KeepAlive"] as? [String: Bool], "KeepAlive must be the dictionary form (true would restart after exit 0)")
        #expect(keepAlive == ["SuccessfulExit": false, "Crashed": true])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["ProcessType"] as? String == "Interactive")
        #expect(plist["ThrottleInterval"] as? Int == 10)
        #expect(plist["ExitTimeOut"] as? Int == 30)
        #expect(plist["Nice"] == nil && plist["LowPriorityIO"] == nil, "no CPU / I/O throttle beyond QoS (tuning point)")
        #expect(plist["EnableTransactions"] == nil, "with it, an idle helper is SIGKILLed on stop")
        #expect(plist["BundleProgram"] as? String == "Contents/Library/LoginItems/VideoScan Background.app/Contents/MacOS/VideoScan Background")
    }
}
