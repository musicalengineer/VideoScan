// FamilyTreeRollCall.swift
// ROLL CALL (Rick 2026-10-01): movie-end-credits over the Family Map — the
// walked family's names with their years and birthplaces drifting up and
// fading away, interleaved with their portraits (birth-country flags when
// there is no photo). Plays once (no loop) while the map assembles after
// Walk Tree → Show on map, and again from the map's "Roll Call" button.
// ~20–40 s (RollCall.duration); a click anywhere or Esc skips it.
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

    /// The same credits, to play again from the top.
    func replay() -> RollCallPlayback {
        RollCallPlayback(id: UUID(), entries: entries, portraits: portraits, flags: flags,
                         duration: duration, order: order, walked: walked)
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
                                    order: RollCall.Order = .oldestFirst) async -> RollCallPlayback {
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
            let entries = RollCall.build(people, options: .init(order: order)) { p in
                let documented = !(p.deathDate?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
                    || (GedcomFamilyGraph.year(in: p.birthDate).map { $0 <= thisYear - 100 } ?? false)
                return context.life(id: p.id, quick: documented ? .deceased
                                    : (p.isInnerCircle ? .livingInnerCircle : .livingPrivate))
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
                                    walked: visited.count)
        }
        // ≈ registering a cancel callback: the caller's cancel reaches the worker.
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    var title: String {
        switch order {
        case .oldestFirst: return "The family, oldest first"
        case .newestFirst: return "The family, newest first"
        case .generationOutward: return "The family, generation by generation"
        case .generationInward: return "The family, from the furthest back"
        }
    }
}

// MARK: - The overlay

struct RollCallOverlay: View {
    let playback: RollCallPlayback
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var opacity = 0.0
    @State private var columnHeight: CGFloat = 0
    @State private var finished = false

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
                } else {
                    TimelineView(.animation(paused: finished)) { timeline in
                        let elapsed = max(0, timeline.date.timeIntervalSince(start))
                        let travel = geo.size.height + columnHeight
                        let progress = min(1, elapsed / max(1, playback.duration))
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
                            .help("Skip the roll call (Esc)")
                    }
                    Spacer()
                }
                .padding(10)
            }
        }
        .opacity(opacity)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Roll call of \(playback.entries.count) family members")
        .accessibilityIdentifier("ft.rollCall")
        .onAppear {
            start = Date()
            withAnimation(.easeIn(duration: 0.6)) { opacity = 1 }
        }
        .task(id: playback.id) {
            // One showing: wait out the duration, then fade and finish. A
            // skip cancels nothing here — `finish` is idempotent.
            try? await Task.sleep(for: .seconds(playback.duration))
            if !Task.isCancelled { finish() }
        }
    }

    /// Top and bottom fade, like credits disappearing into the dark.
    private var fadeMask: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.16),
                               .init(color: .black, location: 0.84), .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
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
