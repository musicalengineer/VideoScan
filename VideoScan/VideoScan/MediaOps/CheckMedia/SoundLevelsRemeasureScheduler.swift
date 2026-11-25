// SoundLevelsRemeasureScheduler.swift — Re-measure Sound Levels runs by
// itself ONCE, unattended, in the away window (GH #516; DECISIONS 2026-11-25:
// "re-measured in the background … best overnight").
//
// One sentence: on the master at launch the scheduler makes sure the marker
// exists (that moment is the cutoff — SoundLevelsRemeasure.swift), then every
// 5 minutes, while the pre-fix walk is unfinished or a card withdrawn for an
// absent drive can be measured because that drive is connected now (the
// app's own signal, `VolumeReachability.isVolumeReachable`), it starts THE job (rule 4: the same
// `startSoundLevelsRemeasure` Tidy Catalog's Run calls) in the away window
// (03:30–11:00, DailyFileCheckPolicy's) or after 15 min idle, never while
// the catalog cannot be written, a scan runs or the job already runs; one
// unattended start per day slot, so a run Rick stopped stays stopped until
// the next night.
//
// State: `SoundLevelsRemeasureScheduler`, a small @MainActor feature store
// (rule 12: no VideoScanModel extension) owned by VideoScanApp, attached on
// the master only and never on a test host. Its `tick()` is the whole engine;
// tests drive it through `SoundLevelsRemeasureEnvironment`'s closures.
//
// Cost: tick() is O(1) outside the window; inside it (and not yet started
// this slot) one < 1 KB marker read and, once walked, one O(records) pass
// over the Sound rows (`autoRunDue`, ~ms at 100k) every 5 minutes. Memory: a few small values.
//
// (For Rick: a struct of closures ≈ a C++ struct of std::function members.)

import Foundation
import VideoScanCore

/// The pure rule: start, wait, or skip (busy).
enum SoundLevelsRemeasurePolicy {

    enum Decision: Equatable {
        case start
        case wait
        case skip(String)
    }

    /// `due` is asked LAST (it walks the records): only inside the window,
    /// and only when this slot has not had its start.
    static func decide(now: Date, due: () -> Bool, busy: String?, idleSeconds: TimeInterval,
                       lastStarted: Date?, calendar: Calendar = .current) -> Decision {
        let slot = DailyFileCheckPolicy.slot(atOrBefore: now, calendar: calendar)
        if let lastStarted, lastStarted >= slot { return .wait }
        guard DailyFileCheckPolicy.inAwayWindow(now, calendar: calendar)
                || idleSeconds >= DailyFileCheckPolicy.idleFor else { return .wait }
        guard due() else { return .wait }
        if let busy { return .skip(busy) }
        return .start
    }
}

struct SoundLevelsRemeasureEnvironment {
    var now: () -> Date = { Date() }
    /// The pre-fix walk is unfinished, or a card waiting for its drive can be
    /// measured now (`SoundLevelsRemeasureItem.autoRunDue`). O(records).
    var isDue: () -> Bool = { false }
    /// Make the marker (the cutoff) if there is none — at attach.
    var ensureMarker: () -> Void = {}
    var busy: () -> String? = { nil }
    var idleSeconds: () -> TimeInterval = { 0 }
    /// Start THE job; false when it was refused.
    var start: () -> Bool = { false }
    var note: (String) -> Void = { _ in }
    var calendar: Calendar = .current
}

extension SoundLevelsRemeasureEnvironment {

    /// The running app. Every read is O(1) or O(jobs) (plus the marker file).
    @MainActor
    static func live(model: VideoScanModel, center: MediaFileOperationsCenter) -> SoundLevelsRemeasureEnvironment {
        var env = SoundLevelsRemeasureEnvironment()
        let catalogFile = model.catalogStore.fileLocation
        env.isDue = { [weak model] in
            guard let model else { return false }
            // An unreadable marker is due (the job replaces it).
            guard let marker = try? SoundLevelsRemeasureMarker.load(catalogFile: catalogFile) else { return true }
            return SoundLevelsRemeasureItem.autoRunDue(model.records, marker: marker,
                                                       isOnline: { VolumeReachability.isVolumeReachable(path: $0) })
        }
        env.ensureMarker = { [weak model] in
            let loaded = SoundLevelsRemeasureMarker.loadOrCreate(catalogFile: catalogFile, now: Date())
            guard loaded.created, !loaded.replaced else { return }
            do {
                try loaded.marker.save(catalogFile: catalogFile)
                model?.log("\(SoundLevelsRemeasureJob.title): cards checked before now are measured again once (#516) — cutoff recorded")
            } catch {
                model?.log("\(SoundLevelsRemeasureJob.title): the marker could not be written (\(error.localizedDescription)); the job will record its cutoff when it starts")
            }
        }
        env.busy = { [weak model, weak center] in
            guard let model, let center else { return "the app is shutting down" }
            return DailyFileCheckScheduler.busyReason(
                readOnly: model.isReadOnly, unavailable: model.catalogUnavailableWords, writeHold: model.catalogStore.writeHold,
                scanning: model.isScanning, updating: false,
                checker: center.jobs.first { $0.state.isActive && $0 is SoundLevelsRemeasureJob }?.title)
        }
        env.idleSeconds = { DailyFileCheckEnvironment.systemIdleSeconds() }
        env.start = { [weak model, weak center] in
            guard let model, let center else { return false }
            // Background origin: the MFO window is not brought forward at 03:30.
            return !center.startSoundLevelsRemeasure(model: model).wasRefused
        }
        env.note = { [weak model] line in
            let text = "\(SoundLevelsRemeasureJob.title): " + line
            model?.log(text)
            appLog.write("[remeasure-sound] " + text)
        }
        return env
    }
}

@MainActor
final class SoundLevelsRemeasureScheduler {

    private(set) var env: SoundLevelsRemeasureEnvironment
    private(set) var lastStarted: Date?
    private var saidWaiting: String?
    private var loop: Task<Void, Never>?

    init(env: SoundLevelsRemeasureEnvironment = SoundLevelsRemeasureEnvironment()) {
        self.env = env
    }

    static let onWords = "by itself — from 03:30 in the away window (until 11:00) or after 15 min idle, at most once a night, "
        + "until every Verify report card saved before the fix has been measured again, and again when a drive whose cards "
        + "wait for it is connected; Catalog ▸ Tidy Catalog… runs it by hand"

    /// Idempotent: a second window's onAppear does not start a second loop.
    func attach(_ env: SoundLevelsRemeasureEnvironment, firstLookAfter: TimeInterval = 180) {
        guard loop == nil else { return }
        self.env = env
        env.ensureMarker()
        env.note(Self.onWords)
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(firstLookAfter))
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                try? await Task.sleep(for: .seconds(DailyFileCheckPolicy.tickEvery))
            }
        }
    }

    func detach() {
        loop?.cancel()
        loop = nil
    }

    /// One look. Returns what it decided (tests read it).
    @discardableResult
    func tick() -> SoundLevelsRemeasurePolicy.Decision {
        let now = env.now()
        let decision = SoundLevelsRemeasurePolicy.decide(now: now, due: env.isDue, busy: env.busy(),
                                                         idleSeconds: env.idleSeconds(), lastStarted: lastStarted,
                                                         calendar: env.calendar)
        switch decision {
        case .wait:
            saidWaiting = nil
        case .skip(let busy):
            let words = "due, waiting: \(busy)"
            if words != saidWaiting { env.note(words) }
            saidWaiting = words
        case .start:
            saidWaiting = nil
            lastStarted = now
            env.note("starting by itself (the background re-measure)")
            if !env.start() { env.note("refused to start — see its row in Media File Operations") }
        }
        return decision
    }
}
