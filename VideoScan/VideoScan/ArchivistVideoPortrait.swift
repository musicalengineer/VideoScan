//
//  ArchivistVideoPortrait.swift
//  VideoScan
//
//  A LIVING portrait from short looping video clips (the outsourced
//  "librarian at her desk" loops Rick will generate from the restored
//  c.1900 photo). Rick 2026-08-17: "sure let's try it."
//
//  Drop clips beside the chosen portrait image (same folder, same stem):
//      <stem>-idle.mp4|mov       — required for video mode (breathing, blinks)
//      <stem>-listening.mp4|mov  — optional: while the input has focus
//      <stem>-thinking.mp4|mov   — optional: while a turn is in flight
//  Loops are seamless (AVPlayerLooper), muted, and cross-fade between
//  states. Missing states fall back to idle; no clips at all → the still
//  portrait (ArchivistLivingPortrait) as before. Reduce Motion → still.
//

import SwiftUI
import AVFoundation
import AVKit

/// Which loops exist next to a portrait image.
struct ArchivistPortraitLoops: Equatable {
    var idle: URL?
    var listening: URL?
    var thinking: URL?

    var hasVideo: Bool { idle != nil }

    /// Discover `<stem>-<state>.(mp4|mov|m4v)` beside `imagePath`.
    static func discover(besideImageAt imagePath: String) -> ArchivistPortraitLoops {
        let url = URL(fileURLWithPath: imagePath)
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        func find(_ state: String) -> URL? {
            for ext in ["mp4", "mov", "m4v"] {
                let c = dir.appendingPathComponent("\(stem)-\(state)").appendingPathExtension(ext)
                if FileManager.default.fileExists(atPath: c.path) { return c }
            }
            return nil
        }
        return ArchivistPortraitLoops(idle: find("idle"), listening: find("listening"), thinking: find("thinking"))
    }
}

enum ArchivistPortraitState: Equatable { case idle, listening, thinking }

/// AVPlayerLooper-backed, muted, seamless loop with a cross-fade on state
/// change. AppKit-hosted (AVPlayerLayer) so it costs nothing while hidden.
struct ArchivistVideoPortrait: NSViewRepresentable {
    let loops: ArchivistPortraitLoops
    let state: ArchivistPortraitState

    func makeNSView(context: Context) -> LoopingPlayerView {
        let v = LoopingPlayerView()
        v.play(url: url(for: state), fade: false)
        return v
    }

    func updateNSView(_ v: LoopingPlayerView, context: Context) {
        v.play(url: url(for: state), fade: true)
    }

    private func url(for state: ArchivistPortraitState) -> URL? {
        switch state {
        case .idle: return loops.idle
        case .listening: return loops.listening ?? loops.idle
        case .thinking: return loops.thinking ?? loops.idle
        }
    }
}

final class LoopingPlayerView: NSView {
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentURL: URL?
    private let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func play(url: URL?, fade: Bool) {
        guard let url, url != currentURL else { return }
        currentURL = url
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.actionAtItemEnd = .none
        let newLooper = AVPlayerLooper(player: queue, templateItem: item)
        // Cross-fade: fade the layer out, swap, fade in. Cheap and honest.
        if fade {
            CATransaction.begin()
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = 0.35; anim.toValue = 1.0; anim.duration = 0.35
            playerLayer.add(anim, forKey: "swap")
            CATransaction.commit()
        }
        playerLayer.player = queue
        player = queue
        looper = newLooper
        queue.play()
    }

    deinit { player?.pause() }
}
