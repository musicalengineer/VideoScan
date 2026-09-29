import Foundation
import Testing
@testable import VideoScan

/// 2026-09-29 (Rick: "Hallie's voice regressed after the upgrade"): launched
/// from Xcode 27 the app carries MTL_DEBUG_LAYER=1, the Kokoro engine
/// inherited it, and Metal's validation layer aborted it on every sentence
/// ("setBytes … bytes argument cannot be nil", exit 6) — Hallie fell back to
/// Apple speech. Reproduced by hand: the same engine and text exit -6 with
/// MTL_DEBUG_LAYER=1 and write the WAV without it.
@Suite("Hallie neural voice — the engine gets an allowlisted environment, never Xcode's debug switches")
struct HallieNeuralWorkerEnvironmentTests {

    /// The variables Xcode 27 really injected into the running app on
    /// 2026-09-29 (a sample of the ~30): none may reach the engine.
    @Test func onlyTheAllowlistReachesTheEngine() {
        let parent = [
            "MTL_DEBUG_LAYER": "1", "MTL_DEBUG_LAYER_VALIDATE_LOAD_ACTIONS": "0",
            "DYLD_INSERT_LIBRARIES": "/Applications/Xcode.app/…/libViewDebuggerSupport.dylib",
            "DYLD_FRAMEWORK_PATH": "/x", "DYLD_LIBRARY_PATH": "/x",
            "CA_ASSERT_MAIN_THREAD_TRANSACTIONS": "1", "CA_DEBUG_TRANSACTIONS": "1",
            "COREAI_CAPTURE_ENABLED": "1", "LLVM_PROFILE_FILE": "/x", "MallocNanoZone": "0",
            "SQLITE_ENABLE_THREAD_ASSERTIONS": "1", "NSUnbufferedIO": "YES",
            "OS_LOG_DT_HOOK_MODE": "0x07", "SWIFT_BACKTRACE": "enable=no",
            "__XCODE_BUILT_PRODUCTS_DIR_PATHS": "/x", "__XPC_DYLD_LIBRARY_PATH": "/x",
            "HOME": "/Users/test", "PATH": "/usr/bin", "TMPDIR": "/tmp/x/", "LANG": "en_US.UTF-8",
            "USER": "test", "__CF_USER_TEXT_ENCODING": "0x1F5:0x0:0x0",
        ]
        let env = HallieNeuralSpeech.workerEnvironment(parent)
        #expect(env == ["HOME": "/Users/test", "PATH": "/usr/bin", "TMPDIR": "/tmp/x/", "LANG": "en_US.UTF-8",
                        "USER": "test", "__CF_USER_TEXT_ENCODING": "0x1F5:0x0:0x0"])
    }

    @Test func aMissingTmpdirGetsTheSystemOne() {
        let env = HallieNeuralSpeech.workerEnvironment(["HOME": "/Users/test"])
        #expect(env["HOME"] == "/Users/test")
        #expect(env["TMPDIR"] == NSTemporaryDirectory())
        #expect(env.count == 2)
    }

    /// SENSOR: every engine launch in HallieNeuralSpeech.swift sets its
    /// environment through workerEnvironment() — a new launch site that
    /// forgets would silently bring the Apple-speech fallback back.
    @Test func everyEngineLaunchUsesTheFilteredEnvironment() throws {
        let source = try String(contentsOf: Self.sourceURL("VideoScan/HallieNeuralSpeech.swift"), encoding: .utf8)
        let launches = source.components(separatedBy: "Process()").count - 1
        let filtered = source.components(separatedBy: "process.environment = HallieNeuralSpeech.workerEnvironment()").count - 1
        #expect(launches >= 2, "expected the worker and the legacy helper launches")
        #expect(filtered == launches, "\(launches) Process() launches, \(filtered) with the filtered environment")
    }

    private static func sourceURL(_ relative: String) -> URL {
        // …/VideoScan/VideoScanTests/<this file> → …/VideoScan/<relative>
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relative)
    }
}
