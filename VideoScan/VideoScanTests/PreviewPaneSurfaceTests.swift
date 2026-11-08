import Testing
import Foundation
@testable import VideoScan

// The catalog preview pane's decisions (PreviewPaneSurface / PreviewPaneInfo),
// lifted out of CatalogContent.previewPlayer (C → B, 2026-11-07).
//
// Characterization: `oldChain` below is the pre-refactor view's if / else-if
// chain transcribed condition for condition (same order, same tests, with
// `selectedRecord` non-nil as it was inside that branch). The new pure
// decision must agree with it on EVERY combination of its inputs. The old
// code lived in a view body and could not be called headless; this oracle
// is how its behaviour is pinned.

@MainActor
struct PreviewPaneSurfaceTests {

    static let path = "/Volumes/V/clip.mkv"
    static let other = "/Volumes/V/other.mkv"

    // MARK: Oracle — the old chain, verbatim in shape

    // swiftlint:disable:next function_parameter_count
    static func oldChain(previewOfflineVolumeName: String?, reachable: Bool,
                         filmstripState: PreviewFilmstripState, isPlaying: Bool, hasPlayer: Bool,
                         hasPreviewImage: Bool, previewUnavailable: Bool, streamType: StreamType,
                         selectedPath: String) -> String {
        if previewOfflineVolumeName != nil || !reachable {
            return "mediaOffline"
        } else if case .ready(let stripPath, _) = filmstripState, stripPath == selectedPath {
            return "filmstrip:\(stripPath)"
        } else if case .loading(let stripPath, let done, let total) = filmstripState, stripPath == selectedPath {
            return "extracting:\(min(done + 1, max(total, 1)))/\(max(total, 1))"
        } else if isPlaying, hasPlayer {
            return "player"
        } else if hasPreviewImage {
            let play = streamType == .videoAndAudio || streamType == .videoOnly
            return "poster:\(play)"
        } else if previewUnavailable {
            return "noPreview"
        } else if streamType == .audioOnly {
            return "audioOnly"
        } else {
            return "generating"
        }
    }

    static func label(_ s: PreviewPaneSurface) -> String {
        switch s {
        case .mediaOffline: return "mediaOffline"
        case .filmstrip(let p, _): return "filmstrip:\(p)"
        case .extracting(let n, let m): return "extracting:\(n)/\(m)"
        case .player: return "player"
        case .poster(let play): return "poster:\(play)"
        case .noPreview: return "noPreview"
        case .audioOnly: return "audioOnly"
        case .generating: return "generating"
        }
    }

    static let strips: [PreviewFilmstripState] = [
        .idle,
        .loading(path: path, done: 0, total: 0),
        .loading(path: path, done: 3, total: 8),
        .loading(path: path, done: 8, total: 8),
        .loading(path: other, done: 1, total: 8),
        .ready(path: path, frames: []),
        .ready(path: other, frames: []),
    ]
    static let streams: [StreamType] = [.videoAndAudio, .videoOnly, .audioOnly, .noStreams, .ffprobeFailed]

    static func inputs(_ offline: String?, _ reachable: Bool, _ strip: PreviewFilmstripState,
                       _ playing: Bool, _ hasPlayer: Bool, _ poster: Bool, _ unavailable: Bool,
                       _ stream: StreamType) -> PreviewPaneSurface.Inputs {
        .init(path: path, streamType: stream, volumeReachable: reachable, offlineVolumeName: offline,
              filmstrip: strip, isPlaying: playing, hasPlayer: hasPlayer, hasPoster: poster,
              previewUnavailable: unavailable)
    }

    // MARK: Characterization — every combination

    @Test func decideMatchesTheOldChainOnEveryCombination() {
        var checked = 0
        for offline in [nil, "Tapes"] as [String?] {
            for reachable in [true, false] {
                for strip in Self.strips {
                    for playing in [true, false] {
                        for hasPlayer in [true, false] {
                            for poster in [true, false] {
                                for unavailable in [true, false] {
                                    for stream in Self.streams {
                                        let new = Self.label(PreviewPaneSurface.decide(
                                            Self.inputs(offline, reachable, strip, playing, hasPlayer,
                                                        poster, unavailable, stream)))
                                        let old = Self.oldChain(
                                            previewOfflineVolumeName: offline, reachable: reachable,
                                            filmstripState: strip, isPlaying: playing, hasPlayer: hasPlayer,
                                            hasPreviewImage: poster, previewUnavailable: unavailable,
                                            streamType: stream, selectedPath: Self.path)
                                        if new != old {
                                            Issue.record("offline=\(String(describing: offline)) reachable=\(reachable) strip=\(strip) playing=\(playing) player=\(hasPlayer) poster=\(poster) unavailable=\(unavailable) stream=\(stream): new \(new), old \(old)")
                                        }
                                        checked += 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(checked == 2 * 2 * 7 * 2 * 2 * 2 * 2 * 5)
    }

    // MARK: The rules, one by one (readable pins)

    @Test func offlineWinsOverEverything() {
        let i = Self.inputs("Tapes", true, .ready(path: Self.path, frames: []), true, true, true, false, .videoAndAudio)
        #expect(Self.label(PreviewPaneSurface.decide(i)) == "mediaOffline")
        let unmounted = Self.inputs(nil, false, .idle, true, true, true, false, .videoAndAudio)
        #expect(Self.label(PreviewPaneSurface.decide(unmounted)) == "mediaOffline")
    }

    @Test func aStripForAnotherRowIsNeverShown() {
        let i = Self.inputs(nil, true, .ready(path: Self.other, frames: []), false, false, true, false, .videoAndAudio)
        #expect(Self.label(PreviewPaneSurface.decide(i)) == "poster:true")
    }

    @Test func extractingCountsFromOneAndNeverPastTheTotal() {
        func strip(_ state: PreviewFilmstripState) -> String {
            PreviewPaneSurface.filmstrip(state, forPath: Self.path).map(Self.label) ?? "none"
        }
        #expect(strip(.loading(path: Self.path, done: 0, total: 0)) == "extracting:1/1")
        #expect(strip(.loading(path: Self.path, done: 3, total: 8)) == "extracting:4/8")
        #expect(strip(.loading(path: Self.path, done: 8, total: 8)) == "extracting:8/8")
        #expect(strip(.idle) == "none")
    }

    /// Reviewer guard (2026-11-07): the oracle above compares labels only
    /// and every strip it builds is empty, so a `frames: []` slip in
    /// `filmstrip(_:forPath:)` would stay green there. The ready surface
    /// must carry the strip's frames through untouched.
    @Test func readyStripFramesReachTheSurface() {
        let frame = PreviewFilmstrip.Frame(offsetSeconds: 0.5, image: PreviewTestImages.twoTone())
        let i = Self.inputs(nil, true, .ready(path: Self.path, frames: [frame, frame]),
                            false, false, false, false, .videoAndAudio)
        guard case .filmstrip(let path, let frames) = PreviewPaneSurface.decide(i) else {
            Issue.record("expected .filmstrip, got \(Self.label(PreviewPaneSurface.decide(i)))")
            return
        }
        #expect(path == Self.path)
        #expect(frames.count == 2)
        #expect(frames.first?.offsetSeconds == 0.5)
    }

    @Test func playingWithoutAPlayerFallsThroughToThePoster() {
        let i = Self.inputs(nil, true, .idle, true, false, true, false, .videoOnly)
        #expect(Self.label(PreviewPaneSurface.decide(i)) == "poster:true")
    }

    @Test func posterHasAPlayButtonOnlyWithAPicture() {
        #expect(PreviewPaneSurface.hasPicture(.videoAndAudio))
        #expect(PreviewPaneSurface.hasPicture(.videoOnly))
        #expect(!PreviewPaneSurface.hasPicture(.audioOnly))
        #expect(!PreviewPaneSurface.hasPicture(.noStreams))
        #expect(!PreviewPaneSurface.hasPicture(.ffprobeFailed))
    }

    @Test func noPreviewOutranksAudioOnlyAndTheSpinner() {
        #expect(Self.label(PreviewPaneSurface.decide(Self.inputs(nil, true, .idle, false, false, false, true, .audioOnly))) == "noPreview")
        #expect(Self.label(PreviewPaneSurface.decide(Self.inputs(nil, true, .idle, false, false, false, false, .audioOnly))) == "audioOnly")
        #expect(Self.label(PreviewPaneSurface.decide(Self.inputs(nil, true, .idle, false, false, false, false, .videoAndAudio))) == "generating")
    }

    /// The media matrix through the play decision the poster leads to:
    /// mkv/ffv1 takes the filmstrip, the AVFoundation-readable families the
    /// player — the surface's play button feeds exactly this route.
    @Test func mediaMatrixRoutesThePlayButton() {
        let rows: [(container: String, codec: String, action: PreviewPlayAction)] = [
            ("MPEG-4 Part 14", "h264", .avPlayer),
            ("QuickTime / MOV", "prores", .avPlayer),
            ("Matroska / WebM", "ffv1", .filmstrip),
            ("MXF (Material eXchange Format)", "mpeg2video", .avPlayer),
            ("AVI (Audio Video Interleaved)", "dvvideo", .avPlayer),
        ]
        for row in rows {
            let route = PreviewFrameRouter.previewRoute(container: row.container, videoCodec: row.codec,
                                                        likelyUnanalyzable: false)
            #expect(PreviewPlayAction.forRoute(route) == row.action, "\(row.container) / \(row.codec)")
        }
    }

    // MARK: Info column

    @Test func selectionCountOnlyWhenSomethingIsSelected() {
        #expect(PreviewPaneInfo.selectionCount(0) == nil)
        #expect(PreviewPaneInfo.selectionCount(3) == "3 selected")
    }

    @Test func codecLineMatchesTheOldExpression() {
        func old(_ v: String, _ a: String) -> String? {
            let parts = [v.isEmpty ? nil : "Video: \(v)", a.isEmpty ? nil : "Audio: \(a)"].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: "   ")
        }
        for (v, a) in [("", ""), ("h264", ""), ("", "aac"), ("ffv1", "pcm_s24le")] {
            #expect(PreviewPaneInfo.codecLine(videoCodec: v, audioCodec: a) == old(v, a))
        }
        #expect(PreviewPaneInfo.codecLine(videoCodec: "dvvideo", audioCodec: "pcm_s16le") == "Video: dvvideo   Audio: pcm_s16le")
    }

    @Test func peopleLineConfirmedPlainDetectedStarredNoDoubles() {
        #expect(PreviewPaneInfo.peopleLine(confirmed: [], detected: []) == nil)
        #expect(PreviewPaneInfo.peopleLine(confirmed: ["Ann"], detected: ["ann", "Bob"]) == "People: Ann, Bob*")
        #expect(PreviewPaneInfo.peopleLine(confirmed: [], detected: ["Cy"]) == "People: Cy*")
    }

    @Test func stopShowsForThePlayerOrThisRowsStrip() {
        #expect(PreviewPaneInfo.showsStop(isPlaying: true, filmstrip: .idle, path: Self.path))
        #expect(PreviewPaneInfo.showsStop(isPlaying: false, filmstrip: .loading(path: Self.path, done: 0, total: 4), path: Self.path))
        #expect(!PreviewPaneInfo.showsStop(isPlaying: false, filmstrip: .ready(path: Self.other, frames: []), path: Self.path))
        #expect(!PreviewPaneInfo.showsStop(isPlaying: false, filmstrip: .idle, path: Self.path))
    }

    // MARK: Sensor — the view goes through the decision

    @Test func thePreviewPaneSwitchesOnTheDecision() throws {
        let helpers = try SourceTree.appCode(named: "CatalogHelpers.swift")
        #expect(helpers.contains("switch PreviewPaneSurface.decide("), "the centre no longer reads the one decision")
        #expect(helpers.contains("PreviewPaneInfo.showsStop("), "the Stop button no longer reads the one rule")
        #expect(!helpers.contains("case .ready(let stripPath"), "a second filmstrip decision came back in the view")
    }
}
