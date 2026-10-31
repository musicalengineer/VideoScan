// BackgroundServiceRegistrarTests.swift — the app's launch makes no
// ServiceManagement call unless `background.service.enabled` is true
// (review 2026-10-30: "the automated proof that off means off").
//
// Dimensions: LOGIC through the `BackgroundAgentService` seam; no real
// SMAppService, no defaults read.

import Foundation
import ServiceManagement
import Testing
@testable import VideoScan

@Suite("BackgroundServiceRegistrar — off by default means no call at all")
struct BackgroundServiceRegistrarTests {

    final class FakeAgent: BackgroundAgentService {
        var registerCalls = 0
        var unregisterCalls = 0
        var status: SMAppService.Status = .notRegistered
        func register() throws { registerCalls += 1; status = .enabled }
        func unregister() throws { unregisterCalls += 1; status = .notRegistered }
    }

    @Test("disabled: the service is never even made, nothing is registered, nothing is logged")
    func disabledMakesNoCall() {
        let fake = FakeAgent()
        var made = 0
        var lines: [String] = []
        BackgroundServiceRegistrar.registerIfEnabled(enabled: false, service: { made += 1; return fake }, log: { lines.append($0) })
        #expect(made == 0, "a disabled launch must not touch ServiceManagement")
        #expect(fake.registerCalls == 0)
        #expect(lines.isEmpty, "\(lines)")
    }

    @Test("enabled: register is called once and the log says so with launchd's status")
    func enabledRegistersOnce() {
        let fake = FakeAgent()
        var lines: [String] = []
        BackgroundServiceRegistrar.registerIfEnabled(enabled: true, service: { fake }, log: { lines.append($0) })
        #expect(fake.registerCalls == 1)
        #expect(lines.count == 1)
        #expect(lines.first?.contains("registered \(BackgroundServiceRegistrar.plistName)") == true, "\(lines)")
        #expect(lines.first?.contains("enabled") == true)
    }

    @Test("the defaults key and the plist name are the documented ones")
    func names() {
        #expect(BackgroundServiceRegistrar.enabledDefaultsKey == "background.service.enabled")
        #expect(BackgroundServiceRegistrar.plistName.hasSuffix(".Background.plist"))
        #expect(BackgroundServiceRegistrar.statusWords(.requiresApproval).contains("Login Items"))
    }
}
