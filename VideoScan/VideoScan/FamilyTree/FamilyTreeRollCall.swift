// FamilyTreeRollCall.swift
// ROLL CALL (Rick 2026-10-01): movie-end-credits over the Family Map — the
// walked family's names with their years and birthplaces drifting up and
// fading away, interleaved with their portraits (birth-country flags when
// there is no photo). Plays once (no loop) while the map assembles after
// Walk Tree → Show on map, and again from the map's "Roll Call" button.
// ~20–40 s (RollCall.duration). Skip button or Esc ends it.
//
// 2026-10-04 (Rick): a click anywhere PAUSES, another click resumes; left
// paused for 4 minutes it resumes by itself. Plays once (no cycling).
// Every 3rd play is THE MIX — a seeded random handful of the family instead
// of the usual best-documented people (RollCallMix). And a second STYLE,
// "Drifting names": names, years and places surface at scattered spots,
// drift, turn and grow slowly (Ken Burns-ish), then fade as others arrive
// (RollCallDriftView). Style is chosen from the map's Roll Call menu.
//
// HOW IT STAYS CHEAP (no O(records) work in any view body):
//   • `RollCallPlayback.prepare` runs OFF the main actor: Core's
//     RollCall.build picks and orders ≤ 36 rows from the walk (dedupe,
//     privacy, line balance), and the ≤ 36 portraits are decoded to small
//     thumbnails there too. The view gets a finished value.
//   • The credits column is an Equatable view: SwiftUI skips its body on
//     every animation frame; only the `.offset` (one number) changes.
//   • Memory, worst case: 36 thumbnails × 180 × 180 px × 4 B ≈ 4.7 MB, held
//     while the overlay (or its replay cache in the sheet) lives.
//
// ANIMATION (the macOS SwiftUI gotcha in the repo notes — implicit
// animations misbehave on macOS): NO implicit animation drives the scroll.
// `TimelineView(.animation)` ≈ a display-link timer; each frame the offset
// is computed from the elapsed time, so it cannot stall, jump or loop. The
// fades are explicit `withAnimation` calls on a single opacity.
//
// REDUCE MOTION: nothing moves. The list is shown still (a scroll view, in
// case it is long), fades in, and fades out at the end of the same
// duration — "a static fading list".
//
// PRIVACY (Rick 2026-10-01: "we should refrain from showing living people
// such as me and Donna, someday we'll have a roll call but not yet"): Core
// leaves out EVERY living person by LifeStatus.privacyVerdict — the inner
// circle included — because `prepare` builds with the default options
// (`RollCall.Options.includesLivingInnerCircle` off). A future family roll
// call flips that one switch. This file draws what it is handed.
//
// (For Rick: `@Environment(\.accessibilityReduceMotion)` ≈ reading the
// system's Reduce Motion setting; `.equatable()` ≈ telling SwiftUI "this
// subview's output depends only on its == inputs, skip re-rendering it".)

import AppKit
import SwiftUI
import VideoScanCore

// MARK: - The prepared credits

/// `@unchecked Sendable`: every field is an immutable value except the
/// NSImages, which are created off-main, never mutated, and only read on
/// the main actor afterwards (≈ a const object handed between threads).
struct RollCallPlayback: Identifiable, @unchecked Sendable {
    /// A fresh id per showing, so a replay restarts the overlay.
    let id: UUID
    let entries: [RollCall.Entry]
    /// Portrait thumbnails by person id (only the rows that have one).
    let portraits: [String: NSImage]
    let flags: [String: FamilyTreeBirthFlag]
    let duration: Double
    let order: RollCall.Order
    /// How many people the walk visited (the "of N" in the header).
    let walked: Int
    /// A shuffled "mix" showing (every 3rd play), not the usual picks.
    var isMix = false

    /// The same credits, to play again from the top.
    func replay() -> RollCallPlayback {
        RollCallPlayback(id: UUID(), entries: entries, portraits: portraits, flags: flags,
                         duration: duration, order: order, walked: walked, isMix: isMix)
    }

    static let thumbnailPixels = 180

    /// Build the credits for one walk, OFF the main actor. `visited` are
    /// the walk's visited ordinals (the Highlight inputs' list).
    ///
    /// The inner circle is ALWAYS the tree's home people's (owner first,
    /// `defaultStarts`), never the walk's starts (QA P2-A: a walk from a
    /// selected living relative named them; a walk from a son hid Rick
    /// and Donna).
    ///
    /// Cancelling the caller cancels the detached work too (a `Task
    /// .detached` does not inherit cancellation on its own — QA P3-3); the
    /// work stops before the list and before each thumbnail decode, and a
    /// cancelled preparation returns an empty playback.
    nonisolated static func prepare(result: TreeWalk.Result, graph: GedcomFamilyGraph, visited: [Int],
                                    knowledge: FamilyTreeNotesResolver?, displayNames: [String],
                                    birthCountries: FamilyTreeBirthCountries,
                                    assets: FamilyAssetConfiguration?,
                                    ownerFamilySearchID: String? = nil,
                                    order: RollCall.Order = .oldestFirst,
                                    shuffleSeed: UInt64? = nil) async -> RollCallPlayback {
        let work = Task.detached(priority: .userInitiated) { () -> RollCallPlayback in
            let empty = RollCallPlayback(id: UUID(), entries: [], portraits: [:], flags: [:],
                                         duration: RollCall.duration(entries: 0), order: order,
                                         walked: visited.count)
            let store = assets?.makeStore()
            let hints = store?.portraitHints() ?? .none
            let now = Date()
            let home = FamilyTreeWalkCenter.defaultStarts(in: graph, ownerFamilySearchID: ownerFamilySearchID)
            let context = FamilyTreeFeatureContext(graph: graph, decorations: [:], displayNames: displayNames,
                                                   knowledge: knowledge, hints: hints, starts: home, now: now)
            if Task.isCancelled { return empty }
            let people = context.rollCallPeople(result: result, visited: visited)
            let thisYear = Calendar.current.component(.year, from: now)
            // Default options: no living person at all (the family roll
            // call switch, `includesLivingInnerCircle`, stays off).
            let entries = RollCall.build(people, options: .init(order: order, shuffleSeed: shuffleSeed)) { p in
                let documented = !(p.deathDate?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
                    || (GedcomFamilyGraph.year(in: p.birthDate).map { $0 <= thisYear - 100 } ?? false)
                // No documented death → LIVING, full stop (adversarial review
                // 2026-10-05, P2). Asking `context.life` here let
                // LifeStatus.of's inference ("a child has a recorded death")
                // presume an undated living parent deceased and name her in
                // the credits. Roll Call fails closed: only a recorded death
                // or a birth 100+ years ago counts.
                guard documented else { return p.isInnerCircle ? .livingInnerCircle : .livingPrivate }
                return context.life(id: p.id, quick: .deceased)
            }
            var portraits: [String: NSImage] = [:]
            var flags: [String: FamilyTreeBirthFlag] = [:]
            for e in entries {
                if Task.isCancelled { return empty }
                // No flag for a living person: where they were born is a
                // private detail too (QA P3-1).
                if !e.isLiving, let flag = birthCountries[e.id] { flags[e.id] = flag }
                guard e.hasPortrait, let store, let person = graph.people[e.id] else { continue }
                if let url = PersonPhotoResolver(store: store).treePhoto(for: FamilyAssetPerson(person),
                                                                       bridgedProfile: nil)?.url,
                   let cg = store.makeThumbnail(for: url, maxPixelSize: thumbnailPixels) {
                    portraits[e.id] = NSImage(cgImage: cg, size: .zero)
                }
            }
            return RollCallPlayback(id: UUID(), entries: entries, portraits: portraits, flags: flags,
                                    duration: RollCall.duration(entries: entries.count), order: order,
                                    walked: visited.count, isMix: shuffleSeed != nil)
        }
        // ≈ registering a cancel callback: the caller's cancel reaches the worker.
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    var title: String {
        if isMix { return "A few of the family, picked at random" }
        switch order {
        case .oldestFirst: return "The family, oldest first"
        case .newestFirst: return "The family, newest first"
        case .generationOutward: return "The family, generation by generation"
        case .generationInward: return "The family, from the furthest back"
        }
    }
}

// MARK: - Style and the mix counter

/// How the roll call is drawn. Persisted under `storageKey`.
enum RollCallStyle: String, CaseIterable, Sendable {
    /// Movie end-credits scrolling up (the original).
    case credits
    /// Names surfacing, drifting and fading over the map.
    case drift

    static let storageKey = "familyTree.rollCall.style"

    var label: String {
        switch self {
        case .credits: return "Credits"
        case .drift: return "Drifting names"
        }
    }
}

/// Every `every`-th play is a shuffled mix. A count, not a calendar (Rick:
/// "every 3rd time or every few days (count is easier)").
enum RollCallMix {
    static let storageKey = "familyTree.rollCall.plays"
    static let every = 3

    /// Count this play; true when it is a mix play (the 3rd, 6th, …).
    static func advance(_ defaults: UserDefaults = .standard) -> Bool {
        let plays = defaults.integer(forKey: storageKey) + 1
        defaults.set(plays, forKey: storageKey)
        return plays % every == 0
    }
}

// MARK: - The overlay

struct RollCallOverlay: View {
    let playback: RollCallPlayback
    var style: RollCallStyle = .credits
    let onFinish: () -> Void

    /// Left paused this long, the roll call resumes by itself.
    static let autoResumeAfter: TimeInterval = 4 * 60

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var opacity = 0.0
    @State private var columnHeight: CGFloat = 0
    @State private var finished = false
    /// Pause bookkeeping: total paused time so far, and when the current
    /// pause began (nil while playing). Elapsed time excludes pauses.
    @State private var pausedTotal: TimeInterval = 0
    @State private var pausedAt: Date?

    private var isPaused: Bool { pausedAt != nil }

    private var runLength: Double {
        style == .drift ? RollCallDrift.duration(entries: playback.entries.count) : playback.duration
    }

    /// Playing time at `now` — wall time minus every pause.
    private func playing(at now: Date) -> TimeInterval {
        let pausedNow = pausedAt.map { now.timeIntervalSince($0) } ?? 0
        return max(0, now.timeIntervalSince(start) - pausedTotal - pausedNow)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.84))
                if reduceMotion {
                    ScrollView(.vertical) {
                        RollCallColumn(playback: playback).equatable()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                } else if style == .drift {
                    TimelineView(.animation(paused: finished || isPaused)) { timeline in
                        RollCallDriftView(playback: playback, size: geo.size,
                                          time: playing(at: timeline.date))
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                } else {
                    TimelineView(.animation(paused: finished || isPaused)) { timeline in
                        let travel = geo.size.height + columnHeight
                        let progress = min(1, playing(at: timeline.date) / max(1, runLength))
                        RollCallColumn(playback: playback).equatable()
                            .frame(width: geo.size.width)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { columnHeight = $0 }
                            .offset(y: geo.size.height - travel * progress)
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                    .clipped()
                    .mask(fadeMask)
                }
                VStack {
                    HStack {
                        Spacer()
                        Button("Skip") { finish() }
                            .keyboardShortcut(.cancelAction)
                            .controlSize(.small)
                            .help("End the roll call (Esc)")
                    }
                    Spacer()
                    if isPaused {
                        Text("Paused — click to continue")
                            .font(.system(size: 12, design: .serif).italic())
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.bottom, 4)
                    }
                }
                .padding(10)
            }
        }
        .opacity(opacity)
        .contentShape(Rectangle())
        .onTapGesture { togglePause() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Roll call of \(playback.entries.count) family members")
        .accessibilityIdentifier("ft.rollCall")
        .onAppear {
            start = Date()
            withAnimation(.easeIn(duration: 0.6)) { opacity = 1 }
        }
        .task(id: playback.id) {
            // One showing. Polled twice a second: ends when the PLAYING time
            // (pauses excluded) reaches the run length; a pause left alone
            // for 4 minutes resumes. `finish` is idempotent.
            while !Task.isCancelled && !finished {
                try? await Task.sleep(for: .milliseconds(500))
                let now = Date()
                if let since = pausedAt {
                    if now.timeIntervalSince(since) >= Self.autoResumeAfter { togglePause() }
                } else if playing(at: now) >= runLength {
                    finish()
                }
            }
        }
    }

    /// Top and bottom fade, like credits disappearing into the dark.
    private var fadeMask: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.16),
                               .init(color: .black, location: 0.84), .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }

    private func togglePause() {
        guard !finished else { return }
        if let since = pausedAt {
            pausedTotal += Date().timeIntervalSince(since)
            pausedAt = nil
        } else {
            pausedAt = Date()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        withAnimation(.easeOut(duration: 0.5)) { opacity = 0 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(520))
            onFinish()
        }
    }
}

// MARK: - Drifting names

/// The pure timing/placement of the drift style (unit-testable): entry `i`
/// surfaces at `i × interval`, lives `life` seconds, and fades in and out.
enum RollCallDrift {
    static let life: Double = 11
    /// Seconds between arrivals: ~2 s, tightened for long lists so a run
    /// stays near a minute and a half at most.
    static func interval(entries: Int) -> Double {
        guard entries > 0 else { return 2 }
        return min(2.2, max(1.4, 75 / Double(entries)))
    }
    static func duration(entries: Int) -> Double {
        guard entries > 0 else { return 0 }
        return Double(entries - 1) * interval(entries: entries) + life + 0.5
    }
    /// 0 before arrival and after leaving; eases in over the first quarter
    /// and out over the last third.
    static func opacity(age: Double) -> Double {
        guard age > 0, age < life else { return 0 }
        let p = age / life
        let fadeIn = min(1, p / 0.25)
        let fadeOut = min(1, (1 - p) / 0.33)
        let v = min(fadeIn, fadeOut)
        return v * v * (3 - 2 * v)          // smoothstep
    }
    /// Where entry `i` surfaces, as fractions of the canvas — a golden-ratio
    /// scatter so neighbours in time land apart in space.
    static func anchor(_ i: Int) -> CGPoint {
        func frac(_ x: Double) -> Double { x - x.rounded(.down) }
        return CGPoint(x: 0.18 + 0.64 * frac(0.5 + Double(i) * 0.618_034),
                       y: 0.18 + 0.64 * frac(0.27 + Double(i) * 0.754_878))
    }
}

/// One frame of the drift: only the few names alive at `time` are drawn.
/// Each floats up a little, wanders sideways, turns a few degrees and grows
/// ~12% over its life — slow enough to read.
struct RollCallDriftView: View {
    let playback: RollCallPlayback
    let size: CGSize
    let time: Double

    var body: some View {
        let n = playback.entries.count
        let gap = RollCallDrift.interval(entries: n)
        // Only the window of entries that can be alive now: O(visible).
        let first = max(0, Int(((time - RollCallDrift.life) / gap).rounded(.down)))
        let last = min(n - 1, Int((time / gap).rounded(.down)))
        ZStack {
            if first <= last {
                ForEach(first...last, id: \.self) { i in
                    floater(i, age: time - Double(i) * gap)
                }
            }
            if time < 6 {
                VStack(spacing: 4) {
                    Text("Roll Call").font(.system(size: 26, weight: .semibold, design: .serif))
                    Text(playback.title).font(.system(size: 13, design: .serif).italic())
                        .foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)
                .opacity(RollCallDrift.opacity(age: time * (RollCallDrift.life / 6)))
            }
        }
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder private func floater(_ i: Int, age: Double) -> some View {
        let e = playback.entries[i]
        let p = max(0, min(1, age / RollCallDrift.life))
        let a = RollCallDrift.anchor(i)
        let side: Double = i % 2 == 0 ? 1 : -1
        HStack(spacing: 14) {
            if let portrait = playback.portraits[e.id] {
                Image(nsImage: portrait)
                    .resizable().scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(TreeWalkPalette.color(e.line).opacity(0.8), lineWidth: 1.5))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(e.name).font(.system(size: 22, weight: .medium, design: .serif))
                let detail = [e.years, e.place].compactMap { $0 }.joined(separator: " · ")
                if !detail.isEmpty {
                    HStack(spacing: 6) {
                        if playback.portraits[e.id] == nil, let flag = playback.flags[e.id] {
                            Text(flag.emoji).font(.system(size: 13))
                        }
                        Text(detail).font(.system(size: 13, design: .serif))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .fixedSize()
        .scaleEffect(0.94 + 0.12 * p)
        .rotationEffect(.degrees(side * (-3 + 6 * p)))
        .opacity(RollCallDrift.opacity(age: age))
        .position(x: size.width * a.x + side * 40 * (p - 0.5),
                  y: size.height * a.y - 36 * p)
    }
}

/// The credits themselves. Equatable on the playback id, so a frame of the
/// scroll re-evaluates the offset only, never these rows.
struct RollCallColumn: View, Equatable {
    let playback: RollCallPlayback

    static func == (a: RollCallColumn, b: RollCallColumn) -> Bool { a.playback.id == b.playback.id }

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text("Roll Call")
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                Text(playback.title)
                    .font(.system(size: 13, design: .serif).italic())
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.bottom, 18)
            ForEach(Array(playback.entries.enumerated()), id: \.element.id) { index, entry in
                row(entry, portraitOnLeft: index % 2 == 0)
            }
            Text(playback.walked > playback.entries.count
                 ? "…and \((playback.walked - playback.entries.count).formatted()) more on the tree, and all those whose names we have yet to learn."
                 : "…and all those whose names we have yet to learn.")
                .font(.system(size: 13, design: .serif).italic())
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(.top, 18)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
    }

    @ViewBuilder private func row(_ e: RollCall.Entry, portraitOnLeft: Bool) -> some View {
        let portrait = playback.portraits[e.id]
        HStack(spacing: 18) {
            if let portrait, portraitOnLeft { picture(portrait, line: e.line) }
            VStack(spacing: 3) {
                Text(e.name)
                    .font(.system(size: 20, weight: .medium, design: .serif))
                    .multilineTextAlignment(.center)
                HStack(spacing: 6) {
                    if portrait == nil, let flag = playback.flags[e.id] {
                        Text(flag.emoji).font(.system(size: 13)).accessibilityLabel(flag.accessibilityLabel)
                    }
                    Text(detail(e))
                        .font(.system(size: 12.5, design: .serif))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
            if let portrait, !portraitOnLeft { picture(portrait, line: e.line) }
        }
        .frame(maxWidth: 560)
    }

    private func picture(_ image: NSImage, line: TreeWalk.Line) -> some View {
        Image(nsImage: image)
            .resizable().scaledToFill()
            .frame(width: 72, height: 72)
            .clipShape(Circle())
            .overlay(Circle().stroke(TreeWalkPalette.color(line).opacity(0.8), lineWidth: 1.5))
    }

    private func detail(_ e: RollCall.Entry) -> String {
        [e.years, e.place].compactMap { $0 }.joined(separator: " · ")
    }
}
