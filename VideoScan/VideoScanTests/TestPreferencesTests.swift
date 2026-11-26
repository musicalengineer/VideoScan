// TestPreferencesTests.swift — the regression for 2026-11-25: Rick's real
// `archivist.ollamaHosts` read "poison.invalid", left by tests whose
// snapshot/set/restore of `.standard` crossed when their suites ran in
// parallel (see TestPreferences.swift for the whole story).
//
//   LOGIC   — an override is what every read sees, and only for its scope;
//             nested scopes unwind innermost-first.
//   REGRESSION — the exact crossed interleaving (A enters, B enters, A leaves,
//             B leaves) leaves nothing behind; a poisoned-hosts override never
//             reaches the app's plist nor a suite's plist.
//   SCALE   — 200 concurrent overlapping scopes on one key unwind to nothing.
//   ISOLATION — every key here is run-unique except the hosts key, which is
//             only ever overridden in memory and only READ on disk.

import Foundation
import Testing
@testable import VideoScan

@Suite("Test preferences — overrides live in memory, never in a plist")
struct TestPreferencesTests {

    private static func argumentValue(_ key: String) -> Any? {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[key]
    }

    private static func uniqueKey(_ label: String) -> String {
        "VideoScanTests.TestPreferences.\(label).\(UUID().uuidString)"
    }

    /// The incident's shape: two tests of different suites poison the same
    /// key and their scopes cross. The old `defer` restore left the poison
    /// behind (B "restored" A's value); the stack must unwind to nothing.
    @Test func crossedScopesOnOneKeyLeaveNothingBehind() {
        let key = Self.uniqueKey("crossed")
        let a = TestPreferences.begin([key: "poison.invalid"])
        let b = TestPreferences.begin([key: "poison.invalid"])
        #expect(UserDefaults.standard.string(forKey: key) == "poison.invalid")
        a.end()
        #expect(UserDefaults.standard.string(forKey: key) == "poison.invalid", "B is still live")
        b.end()
        #expect(UserDefaults.standard.object(forKey: key) == nil, "both scopes ended: the key is gone")
        #expect(Self.argumentValue(key) == nil)
        #expect(TestPreferences.persistedAppValue(forKey: key) == nil)
    }

    /// The other crossing: different values, the outer scope ends first —
    /// the inner value stays until its own scope ends.
    @Test func crossedScopesWithDifferentValuesKeepTheLiveOne() {
        let key = Self.uniqueKey("values")
        let outer = TestPreferences.begin([key: "outer"])
        let inner = TestPreferences.begin([key: "inner"])
        outer.end()
        #expect(UserDefaults.standard.string(forKey: key) == "inner")
        inner.end()
        #expect(UserDefaults.standard.object(forKey: key) == nil)
    }

    /// The hosts key itself, as the five converted tests poison it: every
    /// reader sees the poison (the tests keep their teeth), and neither the
    /// app's plist nor a suite's plist ever holds it.
    @Test func aHostsOverrideIsReadEverywhereAndPersistedNowhere() {
        let key = OllamaEndpoints.hostsKey
        let scratch = TestPreferences.scratch("hosts")
        defer { scratch.remove() }
        let onDiskBefore = TestPreferences.persistedAppValue(forKey: key) as? String
        TestPreferences.overriding([key: "poison.invalid"]) {
            #expect(UserDefaults.standard.string(forKey: key) == "poison.invalid")
            #expect(OllamaEndpoints.resolved(from: .standard) == ["poison.invalid"])
            #expect(OllamaEndpoints.resolved(from: scratch.defaults) == ["poison.invalid"],
                    "a suite reads the argument domain too")
            #expect(scratch.persisted[key] == nil, "nothing was written to the suite's plist")
            #expect(TestPreferences.persistedAppValue(forKey: key) as? String == onDiskBefore,
                    "nothing was written to the app's plist")
        }
        #expect(TestPreferences.persistedAppValue(forKey: key) as? String == onDiskBefore)
    }

    @Test func nestedScopesUnwindInnermostFirstAcrossAwait() async {
        let key = Self.uniqueKey("nested")
        await TestPreferences.overriding([key: "outer"]) {
            await TestPreferences.overriding([key: "inner"]) {
                await Task.yield()
                #expect(UserDefaults.standard.string(forKey: key) == "inner")
            }
            #expect(UserDefaults.standard.string(forKey: key) == "outer")
        }
        #expect(UserDefaults.standard.object(forKey: key) == nil)
    }

    /// A launch argument under an override comes back when the override ends.
    @Test func anUnderlyingArgumentValueIsRestored() {
        let key = Self.uniqueKey("underlying")
        let launch = TestPreferences.begin([key: "launch-argument"])   // stands in for `-key value`
        TestPreferences.overriding([key: "override"]) {
            #expect(UserDefaults.standard.string(forKey: key) == "override")
        }
        #expect(UserDefaults.standard.string(forKey: key) == "launch-argument")
        launch.end()
        #expect(UserDefaults.standard.object(forKey: key) == nil)
    }

    /// 200 overlapping scopes on one key from concurrent tasks, each with its
    /// own value: whatever the interleaving, none is left behind.
    @Test func concurrentOverlappingScopesUnwindToNothing() async {
        let key = Self.uniqueKey("concurrent")
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    await TestPreferences.overriding([key: "v\(i)"]) {
                        await Task.yield()
                        #expect(UserDefaults.standard.string(forKey: key)?.hasPrefix("v") == true)
                    }
                }
            }
        }
        #expect(UserDefaults.standard.object(forKey: key) == nil)
        #expect(Self.argumentValue(key) == nil)
    }

    @Test func scratchSuitesAreUniqueAndRemovable() {
        let a = TestPreferences.scratch("unique"), b = TestPreferences.scratch("unique")
        defer { a.remove(); b.remove() }
        #expect(a.name != b.name)
        #expect(a.name != TestPreferences.appDomain && !TestPreferences.appDomain.isEmpty)
        a.defaults.set("x", forKey: "k")
        #expect(a.persisted["k"] as? String == "x")
        #expect(b.defaults.object(forKey: "k") == nil)
        a.remove()
        #expect(a.persisted.isEmpty)
    }
}
