// VideoScanModelSplitGuardTests.swift
// GH #337 — splitting VideoScanModel (docs/design/vsm_split_plan_2026_10_19.md).
//
// Two suites:
//
// 1. VideoScanModelSplitSensorTests — the §5 standing rule: no new
//    `extension VideoScanModel` and no new `@Published` on the model. The
//    ceilings below may only FALL. Every split slice that moves members off
//    the model lowers them in the same commit (never raise them to get a
//    merge through — move the new member into a store instead).
//
// 2. ObservableForwarderPatternTests — evidence for the §2 mechanism before
//    any real store relies on it: an `@Observable @MainActor` store owned by
//    an `ObservableObject` model, with the old names kept on the model as
//    computed forwarders (a pimpl with inline forwarding accessors, in C++
//    terms). It proves that (a) SwiftUI's observation sees a change made
//    INSIDE the store when a view reads it through the model's forwarder,
//    and (b) the store's will-change hook keeps the model's
//    `objectWillChange` firing exactly as the old `@Published` did, so
//    Combine-style observers of the model are unaffected.

import AppKit
import Combine
import Foundation
import Observation
import SwiftUI
import Testing
@testable import VideoScan

// MARK: - 1. Ceilings

@Suite("VideoScanModel split (#337) — extension / @Published ceilings only fall")
struct VideoScanModelSplitSensorTests {

    // CEILINGS — numbers may only fall. Measured on main @ 354a5aefa
    // (2026-10-19, slice 0): 141 declarations in 136 files, 82 @Published
    // (code only, comments stripped; the plan's 134 / ~90 were file counts
    // and a grep that included comments). Slice 1 (PreviewService) moved
    // three extension files and six @Published: 138 / 133 / 76.
    // NEXT SLICE: lower these to the new measured values in the same
    // commit that moves the members.
    static let extensionDeclarationCeiling = 138
    static let extensionFileCeiling = 133
    static let publishedCeiling = 76

    /// `extension VideoScanModel` — but not `extension VideoScanModel.Nested`
    /// (that extends a nested type, not the model).
    private static let extensionPattern = #"\bextension\s+VideoScanModel(?![\w.])"#

    private static func count(_ pattern: String, in text: String) -> Int {
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return rx.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Comment-stripped code. `scan` (not `code(of:)`): a counter only needs
    /// comments gone; a raw string elsewhere in a file must not fail it.
    private static func code(_ url: URL) -> String {
        SourceTree.scan((try? String(contentsOf: url, encoding: .utf8)) ?? "").code
    }

    @Test("no new `extension VideoScanModel` (declarations and files)")
    func extensionCountOnlyFalls() {
        #expect(SourceTree.appSources.count > 600, "the sensor must see the whole app tree")
        var declarations = 0
        var files: [String] = []
        for source in SourceTree.appSources {
            let n = Self.count(Self.extensionPattern, in: Self.code(source.url))
            if n > 0 {
                declarations += n
                files.append(source.relative)
            }
        }
        #expect(declarations > 0, "dead sensor: found no extension declarations at all")
        #expect(declarations <= Self.extensionDeclarationCeiling,
                "\(declarations) `extension VideoScanModel` declarations > ceiling \(Self.extensionDeclarationCeiling). New model behaviour goes into a store (GH #337), not a new extension.")
        #expect(files.count <= Self.extensionFileCeiling,
                "\(files.count) files extend VideoScanModel > ceiling \(Self.extensionFileCeiling).")
    }

    @Test("no new @Published on VideoScanModel")
    func publishedCountOnlyFalls() throws {
        let url = try #require(SourceTree.appSourceURL(named: "Model/VideoScanModel.swift"))
        let published = Self.count(#"@Published\b"#, in: Self.code(url))
        #expect(published > 0, "dead sensor: found no @Published on the model")
        #expect(published <= Self.publishedCeiling,
                "\(published) @Published on VideoScanModel > ceiling \(Self.publishedCeiling). New observable state goes into an @Observable store (GH #337).")
    }
}

// MARK: - 2. The forwarder + @Observable pattern

/// A value type riding in the store, like PreviewSweepSettings: nested-field
/// writes (`settings.flag = true`) must notify too.
struct ForwarderProbeSettings: Equatable {
    var flag = false
}

/// Stand-in for a real store (PreviewService, ScanStore, …).
/// `@Observable` ≈ the compiler generating per-property change hooks; the
/// `willSet` bridge mirrors what `@Published` did on the model.
@Observable @MainActor
final class ForwarderProbeStore {
    var value: Int = 0 { willSet { willChange?() } }
    var settings = ForwarderProbeSettings() { willSet { willChange?() } }
    /// Not observed — like a plain (non-@Published) `var` on the old model.
    @ObservationIgnored var bookkeeping = 0
    /// The owner's `objectWillChange.send`, wired by the owner.
    @ObservationIgnored var willChange: (() -> Void)?

    /// A mutation made inside the store, not through the forwarder.
    func bump() { value += 1 }
}

/// Stand-in for VideoScanModel: ObservableObject with forwarders.
@MainActor
final class ForwarderProbeModel: ObservableObject {
    let store = ForwarderProbeStore()
    var value: Int {
        get { store.value }
        set { store.value = newValue }
    }
    var settings: ForwarderProbeSettings {
        get { store.settings }
        set { store.settings = newValue }
    }
    init(bridge: Bool = true) {
        if bridge {
            store.willChange = { [weak self] in self?.objectWillChange.send() }
        }
    }
}

/// Records each body evaluation and the value it saw.
@MainActor
final class ForwarderProbeRecorder {
    var evaluations = 0
    var lastSeen = -1
}

/// A view observing the MODEL (as the 73 production views do) and reading
/// the store's state through the model's forwarder.
private struct ForwarderProbeView: View {
    @ObservedObject var model: ForwarderProbeModel
    let recorder: ForwarderProbeRecorder
    var body: some View {
        recorder.evaluations += 1
        recorder.lastSeen = model.value
        return Text("\(model.value)")
    }
}

@Suite("Forwarder + @Observable store — changes reach observers (#337 §2)")
@MainActor
struct ObservableForwarderPatternTests {

    /// Thread-safe flag for observation callbacks (onChange is @Sendable).
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func tracked(_ model: ForwarderProbeModel, read: @escaping () -> Void) -> Flag {
        let flag = Flag()
        withObservationTracking { read() } onChange: { flag.set() }
        return flag
    }

    @Test("a store-internal change fires observation of the model's forwarder")
    func internalChangeFiresTracking() {
        let model = ForwarderProbeModel()
        let flag = tracked(model) { _ = model.value }
        model.store.bump()
        #expect(flag.isSet)
        #expect(model.value == 1)
    }

    @Test("a write through the forwarder fires observation too")
    func forwarderWriteFiresTracking() {
        let model = ForwarderProbeModel()
        let flag = tracked(model) { _ = model.value }
        model.value = 7
        #expect(flag.isSet)
        #expect(model.store.value == 7)
    }

    @Test("a nested field write fires observation")
    func nestedFieldWriteFiresTracking() {
        let model = ForwarderProbeModel()
        let flag = tracked(model) { _ = model.settings.flag }
        model.settings.flag = true
        #expect(flag.isSet)
        #expect(model.store.settings.flag)
    }

    @Test("an @ObservationIgnored member does not fire observation (≈ a non-@Published var)")
    func ignoredMemberIsSilent() {
        let model = ForwarderProbeModel()
        let flag = tracked(model) { _ = model.store.bookkeeping }
        model.store.bookkeeping = 3
        #expect(!flag.isSet)
    }

    @Test("the bridge fires the model's objectWillChange on every store write, like @Published")
    func bridgeFiresObjectWillChange() {
        let model = ForwarderProbeModel()
        var sends = 0
        let token = model.objectWillChange.sink { sends += 1 }
        defer { token.cancel() }
        model.store.bump()                 // inside the store
        model.value = 5                    // through the forwarder
        model.settings.flag = true         // nested field through the forwarder
        model.store.settings.flag = false  // nested field inside the store
        model.value = 5                    // same value: @Published fired anyway
        #expect(sends == 5)
        model.store.bookkeeping = 9        // ignored member: silent, like a plain var
        #expect(sends == 5)
    }

    @Test("objectWillChange fires BEFORE the value changes (willSet, like @Published)")
    func bridgeFiresBeforeTheChange() {
        let model = ForwarderProbeModel()
        var seenAtSend: [Int] = []
        let token = model.objectWillChange.sink { seenAtSend.append(model.store.value) }
        defer { token.cancel() }
        model.store.bump()
        #expect(seenAtSend == [0])
        #expect(model.value == 1)
    }

    private static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func mount(_ model: ForwarderProbeModel, _ recorder: ForwarderProbeRecorder) -> NSWindow {
        let host = NSHostingView(rootView: ForwarderProbeView(model: model, recorder: recorder))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderOut(nil)
        host.layoutSubtreeIfNeeded()
        Self.pump(0.2)
        return window
    }

    /// Re-run the body until it shows `expected` (or time out).
    private func waitForBody(_ recorder: ForwarderProbeRecorder, toSee expected: Int) {
        let end = Date().addingTimeInterval(3)
        while recorder.lastSeen != expected, Date() < end { Self.pump(0.05) }
    }

    @Test("a mounted SwiftUI view observing the model re-renders on a store-internal change")
    func hostedViewRefreshes() {
        let model = ForwarderProbeModel()
        let recorder = ForwarderProbeRecorder()
        let window = mount(model, recorder)
        defer { window.contentView = nil }
        #expect(recorder.lastSeen == 0, "the view never rendered")
        let before = recorder.evaluations
        model.store.bump()
        waitForBody(recorder, toSee: 1)
        #expect(recorder.lastSeen == 1)
        #expect(recorder.evaluations > before)
    }

    @Test("even WITHOUT the objectWillChange bridge the view re-renders (SwiftUI tracks the @Observable read)")
    func hostedViewRefreshesWithoutBridge() {
        let model = ForwarderProbeModel(bridge: false)
        let recorder = ForwarderProbeRecorder()
        let window = mount(model, recorder)
        defer { window.contentView = nil }
        #expect(recorder.lastSeen == 0, "the view never rendered")
        model.store.bump()
        waitForBody(recorder, toSee: 1)
        #expect(recorder.lastSeen == 1,
                "SwiftUI did not track an @Observable read made through an ObservableObject forwarder")
    }
}
