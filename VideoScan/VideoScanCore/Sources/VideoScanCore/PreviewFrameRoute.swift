// PreviewFrameRoute.swift (VideoScanCore)
// The PURE preview-decoder route decision, lifted from the app target so
// the in-app sweep AND the planned out-of-process helper (Stage 1) decide
// "AVFoundation vs straight-to-ffmpeg" from ONE copy of the rules — the
// route drives `needsFilmstrip` in the sweep planner, so a second drifting
// copy would silently change which records get strips.
//
// Pure function of cataloged metadata (container / videoCodec /
// isLikelyUnanalyzable) — zero runtime probing, unit-testable without
// media files. The I/O side (the actual AVFoundation / ffmpeg frame rips)
// stays in the app's VideoScanModel+Thumbnail.swift. The negative cache
// (ThumbnailFailureStore) stays in the app for now — it is not part of the
// route decision.

import Foundation

// MARK: - Route decision (pure)

/// Which decoder the single-frame preview generator should use.
/// Swift's caseless-payload `enum` ≈ a C++ `enum class` — just a tag.
public enum PreviewRoute: Equatable, Sendable {
    /// AVFoundation fast path — hardware-assisted, right for the
    /// overwhelmingly common h264/hevc/prores catalog population.
    case avFoundation
    /// Straight to ffmpeg — AVFoundation would fail (or worse, grind
    /// through gigabytes of container sniffing first). Never touches
    /// an AVFoundation type.
    case ffmpegDirect
}

public enum PreviewFrameRouter {

    /// Container tokens (substring match, lowercased) AVFoundation can't
    /// open. `container` holds ffprobe's `format_long_name` — mkv files
    /// arrive as "Matroska / WebM", hence substring matching rather than
    /// exact tokens (same reason MediaOpener keys off the extension).
    /// Kept as an editable constant so new hostile containers are a
    /// one-line addition.
    public static let avfHostileContainerTokens: [String] = ["matroska", "webm"]

    /// ffprobe `codec_name` values (exact match, lowercased) that
    /// AVFoundation cannot decode — FFV1 archival essence plus the
    /// legacy/web codecs the needs-reformat work already cataloged.
    /// Exact spellings only; families with numbered variants go in
    /// `avfHostileVideoCodecPrefixes` below.
    public static let avfHostileVideoCodecs: Set<String> = [
        "ffv1",     // digitized-tape master essence
        "svq3",     // Sorenson (early QuickTime)
        "cinepak",  // 1990s Apple/SuperMac
        "vp8", "vp9", "av1"  // WebM-era; no AVF decode on macOS
    ]

    /// Codec-name PREFIXES covering numbered families: ffprobe spells
    /// Indeo as indeo2/indeo3/indeo4/indeo5 and MS-MPEG4 as
    /// msmpeg4v1/msmpeg4v2/msmpeg4 — prefix matching catches every
    /// variant without enumerating them.
    public static let avfHostileVideoCodecPrefixes: [String] = ["indeo", "msmpeg4"]

    /// The route decision. PURE — no I/O, no AVFoundation types, no
    /// logging — so it is trivially unit-testable and provably cannot
    /// touch the media file. Callers must consult this BEFORE creating
    /// any AVFoundation object (that's the whole fix: an mkv/ffv1 file
    /// must never instantiate an AVURLAsset).
    ///
    /// - Parameters:
    ///   - container: ffprobe `format_long_name` from the catalog record.
    ///   - videoCodec: ffprobe `codec_name` from the catalog record.
    ///   - likelyUnanalyzable: the record's `isLikelyUnanalyzable`
    ///     derived flag (VideoRecord+Derived.swift) — the stored
    ///     analyzer-confirmed needsReformat marker OR the CANONICAL
    ///     legacy-codec list in VideoScanCore's UnplayableLegacyCodecs.
    ///     Passing the derived flag (not raw needsReformat) keeps this
    ///     router from becoming a fourth drifting copy of that list:
    ///     the sets above stay a fast static tier for the mkv/ffv1
    ///     cases they name, and everything the canonical list knows
    ///     (svq3/qdm2/cinepak/indeo/…) routes correctly through here.
    public static func previewRoute(container: String,
                                    videoCodec: String,
                                    likelyUnanalyzable: Bool) -> PreviewRoute {
        let cont = container.lowercased()
        if avfHostileContainerTokens.contains(where: { cont.contains($0) }) {
            return .ffmpegDirect
        }
        let codec = videoCodec.lowercased().trimmingCharacters(in: .whitespaces)
        if avfHostileVideoCodecs.contains(codec) {
            return .ffmpegDirect
        }
        if avfHostileVideoCodecPrefixes.contains(where: { codec.hasPrefix($0) }) {
            return .ffmpegDirect
        }
        if likelyUnanalyzable {
            return .ffmpegDirect
        }
        return .avFoundation
    }
}
