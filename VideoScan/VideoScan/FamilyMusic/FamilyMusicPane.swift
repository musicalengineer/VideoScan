// FamilyMusicPane.swift
// Archive tab → Music (Rick 2026-09-23): a simple, folder-like list of the
// family's own music — title (or filename), who is playing, year, length,
// audio/video glyph, an "archived" seal when a verified Master Archive copy
// exists — with a play control on every row.
//
//   * Audio plays IN PLACE (one AVPlayer, one recording at a time; click
//     again to stop). AVPlayer streams from disk — worst-case memory is
//     AVFoundation's own read-ahead buffer for ONE file, a few MB, never
//     the whole recording.
//   * Video (and audio AVFoundation can't play, e.g. an Avid MXF audio
//     essence) opens in the app's usual player — MediaOpener, the same
//     QuickTime/VLC routing the Archive timeline cards use.
//   * Offline files are dimmed, say "offline", and cannot be played.
//
// The rows are a value snapshot (FamilyMusicItem) from the memoized
// ArchiveCategorySnapshot; the only per-render work is a cached volume
// reachability lookup per row (~25 rows, no disk I/O).
//
// Large text: nothing here truncates — titles and performers wrap.

import AVFoundation
import Combine
import SwiftUI

// MARK: - Inline audio player

/// Owns the single in-place AVPlayer. `@MainActor` ≈ "this must run on the
/// UI thread" — SwiftUI reads `playingID` to draw the stop glyph.
/// `ObservableObject` + `@Published` ≈ a subject that notifies its views
/// when a member changes (the observer pattern, built in).
@MainActor
final class FamilyMusicPlayer: ObservableObject {
    @Published private(set) var playingID: UUID?
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?

    /// Play `url` for row `id`; the same row again stops it. Starting a new
    /// row stops the old one first — never two recordings at once.
    func toggle(_ id: UUID, url: URL) {
        if playingID == id { stop(); return }
        stop()
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        // End of the recording → back to the play glyph. The notification
        // arrives on the main queue; assumeIsolated states that to the
        // compiler (≈ an assert that we are on the UI thread).
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        player = p
        playingID = id
        p.play()
    }

    func stop() {
        player?.pause()
        player = nil
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = nil
        playingID = nil
    }
}

// MARK: - The pane

struct FamilyMusicPane: View {
    /// Shelf rows, already narrowed by the tab's search field.
    let items: [FamilyMusicItem]
    let isSearching: Bool
    /// Hand the row to the app's usual player (MediaOpener).
    let openExternally: (UUID) -> Void
    let contextMenu: (UUID) -> AnyView

    @StateObject private var player = FamilyMusicPlayer()

    var body: some View {
        Group {
            if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            row(item)
                            Divider().padding(.leading, 64)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        // Leaving the list (another sidebar row, another tab) stops the music.
        .onDisappear { player.stop() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.system(size: 43))
                .foregroundColor(.secondary)
            Text(isSearching ? "No matches" : "No family music yet")
                .font(.headline)
                .foregroundColor(.secondary)
            Text(isSearching
                 ? "Try a different search term."
                 : "In the Catalog, right-click a recording and choose Mark as Family Music…")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ item: FamilyMusicItem) -> some View {
        let online = VolumeReachability.isVolumeReachable(path: item.fullPath)
        let route = FamilyMusicPlayback.route(for: item, isOnline: online,
                                              isViewer: ViewerModeCenter.shared.isViewer)
        let isPlaying = player.playingID == item.id
        return HStack(alignment: .top, spacing: 14) {
            playButton(item, route: route, isPlaying: isPlaying)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 17, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)   // wrap, never truncate
                if let performer = item.performer {
                    Text(performer)
                        .font(.system(size: 15))
                        .foregroundStyle(.blue)
                        .fixedSize(horizontal: false, vertical: true)
                }
                metaLine(item, online: online)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .opacity(online ? 1 : 0.55)
        .background(isPlaying ? Color.accentColor.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .help(item.fullPath)
        .contextMenu { contextMenu(item.id) }
        .accessibilityElement(children: .combine)
    }

    private func playButton(_ item: FamilyMusicItem, route: FamilyMusicPlayRoute, isPlaying: Bool) -> some View {
        Button {
            switch route {
            case .inlineAudio(let url): player.toggle(item.id, url: url)
            case .externalPlayer:       player.stop(); openExternally(item.id)
            case .offline:              break
            }
        } label: {
            Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(route == .offline ? Color.secondary : Color.accentColor)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .disabled(route == .offline)
        .help(playHelp(route, isPlaying: isPlaying))
        .accessibilityLabel(isPlaying ? "Stop" : "Play \(item.title)")
    }

    private func playHelp(_ route: FamilyMusicPlayRoute, isPlaying: Bool) -> String {
        switch route {
        case .inlineAudio:    return isPlaying ? "Stop" : "Play this recording here"
        case .externalPlayer: return "Open in the player (QuickTime or VLC)"
        case .offline:        return "The drive with this file is not connected"
        }
    }

    /// Glyph · year · length · archived seal · offline.
    private func metaLine(_ item: FamilyMusicItem, online: Bool) -> some View {
        HStack(spacing: 8) {
            Label(item.isVideo ? "Video" : "Audio",
                  systemImage: item.isVideo ? "film" : "waveform")
            if let y = item.year {
                Text(String(y))
            }
            if !item.lengthText.isEmpty {
                Text(item.lengthText).monospacedDigit()
            }
            if item.isArchived {
                Label("archived", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .help("Byte-verified in the Master Archive")
            }
            if !online {
                Text("offline")
                    .foregroundStyle(.orange)
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
    }
}
