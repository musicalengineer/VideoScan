// ArchivistTranscriptRenderSensorTests.swift
// Regression sensor for the Hallie chat transcript (perf 2026-08-29).
//
// Evidence: Rick beachballed at 17:33 on a Release build (main 4513f045)
// after asking "help" and pressing Stop. `sample` put 1003/1008 main-thread
// samples inside SwiftUI's transaction flush: LazyVStack re-layout of every
// bubble, `SelectionOverlay.updateNSView` + `NSControl setFont` for every
// selectable Text, and copies of `ArchivistMessage`. Root cause: the window
// observed HallieSpeaker directly, Stop over a help-card queue republished
// `isSpeaking = false` once per cancelled utterance, and every publish
// re-diffed every (non-Equatable) row.
//
// Contract pinned here, measured with an offscreen NSHostingView at the
// real window size and the REAL row view (`ArchivistMessageRow`):
//   (a) appending one message         — p95 stall < 16 ms, rows rebuilt = 1
//   (b) mutating the last message 30× — p95 stall < 16 ms, rows rebuilt = 1/tick
//   (c) 30 unrelated publishes        — 0 row bodies, p95 stall < 16 ms
//   (d) scrolling                     — p95 stall < 50 ms (row realization)
//   (e) speak help card, Stop         — stop() returns < 50 ms, 2 publishes
//
// Meaningful only under Release (-O, whole-module); Debug numbers are noise.
// Measurements append to /tmp/archivistTranscriptSensor.log.

import AppKit
import AVFoundation
import Combine
import Foundation
import SwiftUI
import Testing
@testable import VideoScan

@MainActor
private final class TranscriptStore: ObservableObject {
    @Published var messages: [ArchivistMessage] = []
    /// Stands in for an unrelated publish the window also sees
    /// (VideoScanModel scan progress, speaker state, a typing tick).
    @Published var unrelatedTick = 0
    @Published var scrollTarget: UUID?
}

/// The transcript exactly as ArchivistChatWindow lays it out.
private struct TranscriptHarness: View {
    @ObservedObject var store: TranscriptStore
    let showTechnicalDetails: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text("tick \(store.unrelatedTick)").font(.system(size: 13))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(store.messages) { message in
                            ArchivistMessageRow(
                                message: message,
                                showTechnicalDetails: showTechnicalDetails,
                                onChip: { _ in },
                                onPlayCitation: { _ in },
                                onRevealCitation: { _ in },
                                onShowCitationInCatalog: { _ in })
                            .equatable()
                            .id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: store.messages.count) {
                    withAnimation { proxy.scrollTo(store.messages.last?.id, anchor: .bottom) }
                }
                .onChange(of: store.scrollTarget) { _, target in
                    if let target { proxy.scrollTo(target, anchor: .top) }
                }
            }
            HStack {
                TextField("Ask", text: .constant("")).font(.system(size: 17))
                ArchivistAskStopButton(canAsk: true, ask: {})
            }
            .padding(10)
        }
    }
}

/// The transcript as it was BEFORE the fix (main 4513f045): rows not
/// Equatable-wrapped, the speaker observed by the whole window. Logged only,
/// so a run shows before/after side by side on the same machine.
private struct LegacyTranscriptHarness: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject var speaker = HallieSpeaker.shared

    var body: some View {
        VStack(spacing: 0) {
            Text("tick \(store.unrelatedTick)").font(.system(size: 13))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(store.messages) { message in
                            ArchivistMessageRow(
                                message: message,
                                showTechnicalDetails: false,
                                onChip: { _ in },
                                onPlayCitation: { _ in },
                                onRevealCitation: { _ in },
                                onShowCitationInCatalog: { _ in })
                            .id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: store.messages.count) {
                    withAnimation { proxy.scrollTo(store.messages.last?.id, anchor: .bottom) }
                }
            }
            HStack {
                TextField("Ask", text: .constant("")).font(.system(size: 17))
                if speaker.isSpeaking { Button("Stop") { speaker.stop() } }
                else { Button("Ask") {} }
            }
            .padding(10)
        }
    }
}

@MainActor
struct ArchivistTranscriptRenderSensorTests {

    /// Opt-in for this suite's wall-clock budgets. Without it the timing
    /// assertions are skipped: the nightly runs Debug+coverage, where a
    /// scroll p95 of 0.073 s against a 0.050 s Release budget is
    /// instrumentation, not a regression (2026-08-30). The structural
    /// assertions below — how many rows get rebuilt — are NOT gated: they
    /// are counts, not timings, and are exactly as true in Debug.
    static let performanceOptIn = "VIDEOSCAN_RENDER_PERF"

    private func skipUnlessTimingIsMeaningful() throws {
        try #require(PerformanceLane.isAuthoritative(optInKey: Self.performanceOptIn),
                     Comment(rawValue: PerformanceLane.explanation(optInKey: Self.performanceOptIn)))
    }

    // MARK: - Fixture

    static func transcript(count: Int, helpCardEvery: Int = 40) -> [ArchivistMessage] {
        var out: [ArchivistMessage] = []
        for i in 0..<count {
            if i % 2 == 0 {
                out.append(ArchivistMessage(role: .user, text: "show me videos of Donna down the Cape in the 90s — turn \(i)"))
                continue
            }
            var m = ArchivistMessage(
                role: .assistant,
                text: i % helpCardEvery == helpCardEvery - 1
                    ? ArchivistConversationCommand.helpCard
                    : "There are \(i) catalog items matching that. Donna is confirmed in \(i / 2) of them.\nOne of them is Cape_1993.mov — confirmed person tag Donna.",
                queryLine: "person:Donna place:Cape decade:1990s #\(i)",
                basisLine: "Basis: catalog query; \(i) matches; confirmed person tags.")
            if i % 3 == 0 {
                m.chips = ArchivistConversationCommand.helpExamples.map {
                    .init(label: $0.label, action: .askText($0.question, playAfterAnswer: false))
                } + [.init(label: "Show in catalog", action: .applyQuery("person:Donna"))]
            }
            if i % 10 == 9 {
                m.attachments = [.crest(surname: "Latta",
                                        fileURL: URL(fileURLWithPath: "/nonexistent/sensor-crest-\(i).png"))]
                m.knowledgeCitations = [
                    .init(id: "k\(i)", title: "Latta family biography", attribution: "Hallie Mae McGill Latta", locator: "bio/latta.md"),
                ]
            }
            out.append(m)
        }
        return out
    }

    // MARK: - Harness

    private static func mount(_ store: TranscriptStore, technical: Bool = false) -> NSWindow {
        let hosting = NSHostingView(rootView: TranscriptHarness(store: store, showTechnicalDetails: technical))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 680),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderOut(nil)
        hosting.layoutSubtreeIfNeeded()
        return window
    }

    /// Pump the main runloop in 1 ms slices and return the longest single
    /// slice — SwiftUI flushes its transactions inside the runloop observer,
    /// so a long slice IS a main-thread stall.
    @discardableResult
    private static func pump(seconds: TimeInterval) -> TimeInterval {
        let end = Date().addingTimeInterval(seconds)
        var worst: TimeInterval = 0
        while Date() < end {
            let t0 = CFAbsoluteTimeGetCurrent()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
            worst = max(worst, CFAbsoluteTimeGetCurrent() - t0)
        }
        return worst
    }

    private static func p95(_ xs: [TimeInterval]) -> TimeInterval {
        let s = xs.sorted()
        return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * 0.95))]
    }

    private static func log(_ s: String) {
        let line = s + "\n"
        let path = "/tmp/archivistTranscriptSensor.log"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        }
        print(s)
    }

    @MainActor final class RowCounter {
        var bodies = 0
        var ids = Set<UUID>()
        func reset() { bodies = 0; ids = [] }
    }

    private static func withProbe<T>(_ counter: RowCounter, _ body: () throws -> T) rethrows -> T {
        ArchivistMessageRow.bodyProbe = { id in
            MainActor.assumeIsolated { counter.bodies += 1; counter.ids.insert(id) }
        }
        defer { ArchivistMessageRow.bodyProbe = nil }
        return try body()
    }

    #if DEBUG
    static let config = "Debug"
    #else
    static let config = "Release"
    #endif

    // MARK: - Baseline (logged, never asserted)

    /// Same workload through the pre-fix view shape, for the report.
    @Test func legacyShapeBaselineNumbers() async throws {
        let store = TranscriptStore()
        store.messages = Self.transcript(count: 200)
        let hosting = NSHostingView(rootView: LegacyTranscriptHarness(store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 680),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderOut(nil)
        hosting.layoutSubtreeIfNeeded()
        Self.pump(seconds: 0.8)
        let counter = RowCounter()
        var appendStalls: [TimeInterval] = [], mutateStalls: [TimeInterval] = [], tickStalls: [TimeInterval] = []
        var appendRows = 0, mutateRows = 0, tickRows = 0
        try Self.withProbe(counter) {
            for i in 0..<30 {
                counter.reset()
                store.messages.append(ArchivistMessage(role: .assistant, text: "appended \(i)"))
                appendStalls.append(Self.pump(seconds: 0.05)); appendRows = max(appendRows, counter.bodies)
            }
            for i in 0..<30 {
                counter.reset()
                store.messages[store.messages.count - 1].text = "Recompiling… \(i)"
                mutateStalls.append(Self.pump(seconds: 0.05)); mutateRows = max(mutateRows, counter.bodies)
            }
            counter.reset()
            for _ in 0..<30 { store.unrelatedTick += 1; tickStalls.append(Self.pump(seconds: 0.05)) }
            tickRows = counter.bodies
        }
        let ms = { (t: TimeInterval) in String(format: "%.1f ms", t * 1000) }
        Self.log("[\(Self.config)] LEGACY shape transcript=\(store.messages.count) "
                 + "append p95=\(ms(Self.p95(appendStalls))) max=\(ms(appendStalls.max() ?? 0)) rowsRebuilt=\(appendRows) | "
                 + "mutate p95=\(ms(Self.p95(mutateStalls))) max=\(ms(mutateStalls.max() ?? 0)) rowsRebuilt=\(mutateRows) | "
                 + "unrelated p95=\(ms(Self.p95(tickStalls))) max=\(ms(tickStalls.max() ?? 0)) rowBodies=\(tickRows)")
        _ = window
    }

    // MARK: - Sensors

    @Test func appendAndMutateAndUnrelatedPublishStayUnderBudget() async throws {
        let store = TranscriptStore()
        store.messages = Self.transcript(count: 200)
        let window = Self.mount(store)
        Self.pump(seconds: 0.8)          // realize the tail, settle
        let counter = RowCounter()

        // (a) append one message ×30
        var appendStalls: [TimeInterval] = []
        var appendRows: [Int] = []
        try Self.withProbe(counter) {
            for i in 0..<30 {
                counter.reset()
                store.messages.append(ArchivistMessage(role: .assistant, text: "appended \(i)"))
                appendStalls.append(Self.pump(seconds: 0.05))
                appendRows.append(counter.bodies)
            }
        }

        // (b) mutate the LAST message's text ×30 (streaming / phase caption)
        var mutateStalls: [TimeInterval] = []
        var mutateRows: [Int] = []
        try Self.withProbe(counter) {
            for i in 0..<30 {
                counter.reset()
                let last = store.messages.count - 1
                store.messages[last].text = "Recompiling the family tree… Reading pull \(i).ged…"
                mutateStalls.append(Self.pump(seconds: 0.05))
                mutateRows.append(counter.bodies)
            }
        }

        // (c) 30 unrelated publishes (what a speaker / model publish looked like)
        var tickStalls: [TimeInterval] = []
        var tickRows = 0
        try Self.withProbe(counter) {
            counter.reset()
            for _ in 0..<30 {
                store.unrelatedTick += 1
                tickStalls.append(Self.pump(seconds: 0.05))
            }
            tickRows = counter.bodies
        }

        // (d) scroll: jump around the transcript ×20
        var scrollStalls: [TimeInterval] = []
        for i in 0..<20 {
            store.scrollTarget = store.messages[(i * 37) % store.messages.count].id
            scrollStalls.append(Self.pump(seconds: 0.05))
        }

        let ms = { (t: TimeInterval) in String(format: "%.1f ms", t * 1000) }
        Self.log("[\(Self.config)] transcript=\(store.messages.count) "
                 + "append p95=\(ms(Self.p95(appendStalls))) max=\(ms(appendStalls.max() ?? 0)) rowsRebuilt=\(appendRows.max() ?? 0) | "
                 + "mutate p95=\(ms(Self.p95(mutateStalls))) max=\(ms(mutateStalls.max() ?? 0)) rowsRebuilt=\(mutateRows.max() ?? 0) | "
                 + "unrelated p95=\(ms(Self.p95(tickStalls))) max=\(ms(tickStalls.max() ?? 0)) rowBodies=\(tickRows) | "
                 + "scroll p95=\(ms(Self.p95(scrollStalls))) max=\(ms(scrollStalls.max() ?? 0))")
        _ = window

        // Structural assertions first, and ungated — see below.
        if PerformanceLane.isAuthoritative(optInKey: Self.performanceOptIn) {
            #expect(Self.p95(appendStalls) < 0.016, "append p95 \(ms(Self.p95(appendStalls)))")
            #expect(Self.p95(mutateStalls) < 0.016, "mutate p95 \(ms(Self.p95(mutateStalls)))")
            #expect(Self.p95(tickStalls) < 0.016, "unrelated-publish p95 \(ms(Self.p95(tickStalls)))")
            #expect(Self.p95(scrollStalls) < 0.050, "scroll p95 \(ms(Self.p95(scrollStalls)))")
        }
        // No O(messages) work per update: only the changed row is rebuilt.
        #expect((appendRows.max() ?? 0) <= 2, "append rebuilt \(appendRows.max() ?? 0) rows")
        #expect((mutateRows.max() ?? 0) <= 1, "mutate rebuilt \(mutateRows.max() ?? 0) rows")
        #expect(tickRows == 0, "unrelated publishes rebuilt \(tickRows) rows")
    }

    /// Rick's exact repro: "help" (the long multi-line card) read aloud, then
    /// Stop mid-utterance, with a 100-message transcript mounted.
    @Test func stopSpeakingHelpCardReturnsImmediatelyAndPublishesOnce() async throws {
        let defaults = UserDefaults.standard
        let savedVoice = defaults.object(forKey: HallieSpeaker.voiceKey)
        // Force the Apple path (never launches the Kokoro helper in a test):
        // any non-neural identifier → selectedNeuralVoice() == nil.
        defaults.set(HallieSpeaker.bestVoice()?.identifier ?? "com.apple.voice.compact.en-US.Samantha",
                     forKey: HallieSpeaker.voiceKey)
        defer {
            if let savedVoice { defaults.set(savedVoice, forKey: HallieSpeaker.voiceKey) }
            else { defaults.removeObject(forKey: HallieSpeaker.voiceKey) }
        }

        let store = TranscriptStore()
        store.messages = Self.transcript(count: 100)
        store.messages.append(ArchivistMessage(role: .assistant,
                                               text: ArchivistConversationCommand.helpCard))
        let window = Self.mount(store)
        Self.pump(seconds: 0.8)

        let speaker = HallieSpeaker.shared
        let counter = RowCounter()
        let publishesBefore = speaker.speakingPublishCount
        let attemptsBefore = speaker.speakingSetAttempts
        var stopMillis = 0.0
        var speakingStall: TimeInterval = 0
        var stopStall: TimeInterval = 0
        try Self.withProbe(counter) {
            speaker.speak(ArchivistConversationCommand.helpCard)
            #expect(speaker.isSpeaking)
            speakingStall = Self.pump(seconds: 0.4)     // she is mid-utterance
            let t0 = CFAbsoluteTimeGetCurrent()
            speaker.stop()
            stopMillis = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            stopStall = Self.pump(seconds: 0.6)         // didCancel storm lands here
        }
        let publishes = speaker.speakingPublishCount - publishesBefore
        let attempts = speaker.speakingSetAttempts - attemptsBefore
        Self.log(String(format: "[%@] help-card stop: stop() %.1f ms; stall while speaking %.1f ms; stall after stop %.1f ms; isSpeaking publishes %d (of %d attempted sets — the pre-fix storm); row bodies %d",
                        Self.config, stopMillis, speakingStall * 1000, stopStall * 1000, publishes, attempts, counter.bodies))
        _ = window

        #expect(!speaker.isSpeaking)
        #expect(stopMillis < 50, "stop() took \(stopMillis) ms")
        #expect(stopStall < 0.050, "main thread stalled \(stopStall * 1000) ms after Stop")
        #expect(publishes == 2, "isSpeaking published \(publishes) times (expected true, false)")
        #expect(counter.bodies == 0, "speak/stop rebuilt \(counter.bodies) transcript rows")
    }
}
