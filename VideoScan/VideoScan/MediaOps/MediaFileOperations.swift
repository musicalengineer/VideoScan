import Combine
import Foundation
import os

// MARK: - Media File Operations (phase 1)
//
// ONE non-modal window hosts every file-by-file operation — combine,
// compare, extract-frames, and future verbs — with parallel background
// processing, per-job cancel (and pause where the operation supports
// it). This file is the model layer:
//
//   - `MediaFileOperationKind`  — which verb a row represents (badge).
//   - `MediaFileOperationState` — running / cancelling / finished /
//     failed / cancelled, with a summary or message payload.
//   - `MediaFileOperationJob`   — the protocol every operation job
//     conforms to so the window's list can render them uniformly.
//   - `MediaFileOperationsCenter` — the app-level registry that owns
//     the jobs, hands out per-volume read gates, and is what the quit
//     guard consults.
//   - `MediaVolumeGatePolicy`   — PURE slot policy (how many compares
//     may read a volume at once, by media tech). No I/O — unit-testable
//     without touching real volumes.
//
// Phase 1 deliberately leaves the existing Combine queue on its own
// machinery (`CombineJobStatus` rows driven by DashboardState): the
// window renders combine rows in their own section alongside new-style
// jobs. Visual unity first, type unity later.

/// File-scope logger — detached job tasks log through this.
private let fileOpsLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                category: "fileOps")

// MARK: - Kind

/// Which verb a job performs. Drives the colored badge capsule in the
/// operations window ("Combine" green, "Compare" blue, "Faces" orange,
/// "Frames" purple).
/// One job kind's look in the operations window and its log wording.
/// Plain values — the SwiftUI Color is made from `fill` in the window file.
struct MediaFileOperationKindStyle: Equatable {
    struct RGB: Equatable {
        let red, green, blue: Double
        init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }
    let badge: String
    let logVerb: String
    let fill: RGB
}

enum MediaFileOperationKind: String, CaseIterable {
    case combine
    case compare
    /// Vision-scored best-portrait-frames rip ("Extract Facial
    /// Frames…"). The case name predates the verb split — kept as
    /// `.extract` so persisted/test references don't churn; only the
    /// badge text changed.
    case extract
    /// ffmpeg-only frame export ("Extract Frames…") — every frame, or
    /// sampled every-Nth / N-per-second. No Vision involved.
    case ripFrames
    /// "Reformat and Analyze" — transcode a legacy-codec source
    /// (svq3, qdm2, cinepak, etc.) into modern H.264/AAC mp4 with
    /// conventional ffmpeg filters (bwdif deinterlace, hqdn3d
    /// denoise). Auto-catalogs the output and queues it for analyze.
    /// Rick 2026-06-14: lets the analyzer reach files AVFoundation
    /// can't decode (Apple deprecated svq3/qdm2/etc. in macOS 10.15).
    case reformat
    /// "Analyze This File" — runs the orchestrator's VLM + Whisper
    /// pipeline on a single record. Rick 2026-06-14: Media File
    /// Operations window owns per-file operations; the Analyze
    /// Dashboard owns batch volume-wide operations. Watching one
    /// file's analyze tick along belongs here.
    case analyze
    /// "Transcode" — two-preset faithful conversion to ProRes 422 HQ
    /// (Editing) or HEVC 10-bit (Archival). Rick 2026-06-14 (Pass C):
    /// produces FCP-editable copies and archive-grade copies without
    /// leaving VideoScan. Unlike Reformat, NO deinterlace/denoise and
    /// NO auto-queue Analyze.
    case transcode
    /// "Clean Up Video" — applies a named CleanupRecipe (v1: VHS Quick
    /// Clean single-pass ffmpeg filtergraph) and writes
    /// `<stem>_cleaned.mov` (ProRes LT, audio copied) BESIDE the
    /// original, which is never modified. Rick 2026-07-07.
    case cleanup
    /// "Trim Master…" — cuts static/garbage off the head and tail of an
    /// archival capture with a pure ffmpeg STREAM COPY (no re-encode,
    /// zero quality loss) and writes `<stem>_trimmed.<same ext>` BESIDE
    /// the original, which is never modified. Rick 2026-07-16.
    case trim
    /// "Balance Audio" — fixes one-sided (left/right-only) or mono
    /// audio by duplicating the live channel to both sides; video
    /// stream-copied, `<stem>_balanced.<ext>` beside the original,
    /// which is never modified. GH #116, Rick 2026-07.
    case balanceAudio
    /// "Rebuild Audio Track" — the Verify Audio repair (GH #128):
    /// video stream-copied, audio re-encoded to pcm_s16le in a .mov,
    /// `<stem>_RepairedAudio.mov` beside the original, which is never
    /// modified. Rick 2026-07-24.
    case rebuildAudio
    /// "Verify Audio" — the diagnosis itself as a job (GH #135, Rick
    /// 2026-07-24): the levels pass decodes the whole audio track
    /// (minutes on long tapes), so it runs HERE, never in a modal
    /// sheet over the catalog. Single- and multi-select both dispatch
    /// these; the results sheet presents the already-computed
    /// diagnosis afterwards without re-running anything.
    case verifyAudio
    /// "Verify Video" — Verify Audio's picture-side sibling (Rick
    /// 2026-09-23): header facts + packet samples + a full decode, then
    /// a plain-words OK / Warning / Broken verdict with a recommendation.
    /// Read-only on media; verdict persisted on the record. Its row
    /// expands to the reasons (VerifyVideoDetailView). VerifyVideoJob.
    case verifyVideo
    /// "Check Media…" (Rick 2026-10-07) — the catalog's one examination
    /// verb: a quick tier (header, packet samples, short frame windows)
    /// and an optional full tier (the Verify Video decode with signal
    /// filters + the Verify Audio levels pass). One row for the whole
    /// selection; per-file report cards in its detail. CheckMediaJob.
    case checkMedia
    /// "Find & Tag" — runs a per-person detector recipe (Donna Recipe,
    /// docs/find-and-tag-design.md) over selected records and writes
    /// MACHINE-tier person tags (detected "Donna*" / suspected
    /// "Donna?"); confirmed stays human-only. v1 bridges to the python
    /// recipe engine via ProcessRunner; Swift-native engine to follow
    /// behind the same job. Rick 2026-08-02.
    case findPerson
    /// "Promote to Archive" — verified byte-for-byte copy of one or more
    /// records into the Master Archive tree (spec §5): copy → streamed
    /// sha256 of source and destination → rename into place → manifest
    /// row → linked catalog record. Never a move; never a re-encode.
    /// docs/archive_promotion_workflow.md, Rick 2026-08-15.
    case promote
    // (`assessCopies` — the Promote Helper's "Assess Copies for Archive…"
    // row — was retired in Archive Angel consolidation S4, 2026-09-22; its
    // read-only successor is Archive Angel ▸ Show Copies…, a sheet, not a
    // job. The kind was never persisted: no Codable, no saved plan, no
    // defaults key named it.)
    /// "Verify Archive Copies" — the manifest-driven fixity audit +
    /// recovery pass (GH #167, 2026-08-20): re-read every Master
    /// Archive copy end to end, compare its SHA-256 against the
    /// 00_Index manifest, restore `archiveFixity` on a match and flag
    /// a mismatch LOUDLY (never restored — potential corruption).
    /// Read-only on media; catalog writes only. VerifyArchiveCopiesJob.
    case verifyArchive
    /// "Archive Angel" — Stage 1 of the autonomous promoter (Rick
    /// 2026-09-09, docs/archive_angel_design.md): walks the catalog for
    /// important-but-unarchived videos, prepares companions in a buffer
    /// on the fast SSD, and stops for review. Never touches the archive
    /// itself — Stage 2 hands the selected rows to Promote.
    case archiveAngel
    /// "Delete Duplicates" — the verified removal of extra copies on one
    /// volume as a job (Rick 2026-09-20: "MFO window should show DELETE in
    /// clear high contrast color, with progress 2 of N, 3 of N deleted,
    /// and clicking on the row reveals a list of files"). Every file
    /// deleted is read in full against its keeper's whole-file digest at
    /// the moment of deletion; the keeper is read at most once ever.
    /// Pause/Resume between pairs, a saved plan for resume after a quit.
    /// DeleteDuplicatesJob.
    case deleteDuplicates
    /// "Archived — what next?" → "Move N to Trash" as a job (Rick
    /// 2026-09-20: "the app blocks when post-promote delete of big files").
    /// Every copy is proven identical to its archive copy (read in full,
    /// or trusted on its promotion stamp) and both are re-checked the
    /// instant before the move; one file at a time, Pause/Stop between
    /// files, held copies named in the row. PruneApplyJob.
    case pruneCopies
    /// "Find Similar Footage" (Rick 2026-09-23, docs/design/find_original_design.md):
    /// walks the catalog METADATA — no media is read — and records which
    /// files are probably the same footage (copies, re-encodes, transcodes,
    /// exports). Pause/Stop between phases and apply slices.
    /// FindSimilarFootageJob.
    case findSimilarFootage
    /// "Bind Fixity to Volume" (2026-09-23, codex #1707): re-read every
    /// file on one volume whose stored whole-file digest predates volume
    /// identity, in full, with before/after identity checks on the same
    /// opened file, and re-store it bound to the volume's persistent UUID.
    /// Read-only on media; catalog writes only. BindFixityToVolumeJob.
    case bindFixity
    /// "Lock files already in the archive (one-time)…" (Rick 2026-09-27):
    /// walks the archive manifest's rows and sets the macOS user-immutable
    /// flag on each archived file promoted before locking existed.
    /// Metadata only — no media is read. ArchiveLockJob.
    case lockArchive
    /// "Compare Footage…" (Footage Spectrum trial, 2026-10-03): 2–8 chosen
    /// videos read once each by scripts/footage_spectrum.py and shown as
    /// colour-over-time strips on one time line in the Footage Spectrum
    /// window. Read-only on media; output only under
    /// ~/Library/Caches/VideoScan/spectrum. FootageSpectrumJob.
    case compareFootage
    /// "Fingerprint Pictures…" (GH #293, 2026-10-07): computes and KEEPS the
    /// 32-frame perceptual fingerprint of every video without one, archived
    /// files first. Read-only on media; writes only the catalog field.
    /// PerceptualFingerprintBackfillJob.
    case fingerprintBackfill

    /// How this kind presents itself — badge text, log verb and badge
    /// fill — as ONE value per kind (2026-10-07). These used to be three
    /// parallel exhaustive switches that each grew a branch per new verb;
    /// now one switch does, still with no `default`, so a new kind cannot
    /// compile without all three. Badge: small caps in the row (`.extract`
    /// says "Faces" since the verb split; DELETE / TRASH are upper-case on
    /// purpose — the destructive rows must be unmistakable). Log verb: the
    /// lowercase verb in the videoscan.log START/OUTCOME lines, matching
    /// the older ad-hoc lines so greps over old logs keep working. Fill:
    /// hand-darkened hues that carry white small-caps text (Rick
    /// 2026-07-31), pairwise distinct (the nightly sensor).
    var style: MediaFileOperationKindStyle {
        switch self {
        // Forest green — Combine's original green, darkened.
        case .combine: return .init(badge: "Combine", logVerb: "combine", fill: .init(0.10, 0.45, 0.16))
        // Cobalt — Compare's blue.
        case .compare: return .init(badge: "Compare", logVerb: "compare", fill: .init(0.08, 0.32, 0.72))
        // Burnt orange — Extract/Faces' orange.
        case .extract: return .init(badge: "Faces", logVerb: "extract faces", fill: .init(0.75, 0.42, 0.00))
        // Deep purple — Frames' purple.
        case .ripFrames: return .init(badge: "Frames", logVerb: "extract frames", fill: .init(0.44, 0.22, 0.65))
        // Crimson — Reformat's red.
        case .reformat: return .init(badge: "Reformat", logVerb: "reformat", fill: .init(0.70, 0.14, 0.16))
        // Dark cyan (blue-leaning) — Analyze. Sits between compare's
        // cobalt and cleanup's teal; the blue cast keeps it apart.
        case .analyze: return .init(badge: "Analyze", logVerb: "analyze", fill: .init(0.00, 0.42, 0.58))
        // Pass C — Transcode's mint matches the workspaceActive tint
        // (mint hammer icon in the catalog filename column), so the user
        // reads "transcode → workspace" as the same visual lineage.
        // Dark sea-green keeps the mint family, green-leaning.
        case .transcode: return .init(badge: "Transcode", logVerb: "transcode", fill: .init(0.00, 0.52, 0.36))
        // Clean Up shares transcode's derivative-producing nature but
        // gets its own hue so the two verbs read apart at a glance —
        // balanced teal between transcode's green and analyze's blue.
        case .cleanup: return .init(badge: "Clean Up", logVerb: "cleanup", fill: .init(0.00, 0.44, 0.46))
        // Trim is the third derivative-producing verb — indigo keeps it
        // distinct from transcode's mint and cleanup's teal.
        case .trim: return .init(badge: "Trim", logVerb: "trim", fill: .init(0.32, 0.31, 0.75))
        // Balance Audio — raspberry keeps pink's identity but darker;
        // distinct from the other derivative-producing verbs. GH #116.
        case .balanceAudio: return .init(badge: "Balance", logVerb: "balance audio", fill: .init(0.72, 0.16, 0.40))
        // Rebuild Audio Track (Verify Audio's repair, GH #128) — dark
        // brown keeps the audio-repair pair (raspberry/brown) adjacent
        // but distinguishable.
        case .rebuildAudio: return .init(badge: "Rebuild", logVerb: "rebuild audio", fill: .init(0.47, 0.32, 0.20))
        // Verify Audio (the diagnosis as a job, GH #135) — dark goldenrod
        // keeps the yellow "checking" semantics; reads apart from its
        // brown repair sibling and from extract's burnt orange.
        case .verifyAudio: return .init(badge: "Verify", logVerb: "verify audio", fill: .init(0.72, 0.53, 0.04))
        // Verify Video (2026-09-23) — dark olive: the picture-side sibling
        // of Verify Audio's goldenrod (same "checking" family, Δ ≈ 0.31
        // from it), apart from combine's forest green and promote's bronze.
        case .verifyVideo: return .init(badge: "Verify Video", logVerb: "verify video", fill: .init(0.42, 0.45, 0.05))
        // Check Media (2026-10-07) — dark moss: the same "checking" family
        // as the two Verify fills, Δ ≈ 0.20 from every other fill.
        case .checkMedia: return .init(badge: "Check", logVerb: "check media", fill: .init(0.25, 0.35, 0.00))
        // Find & Tag (per-person recipe, 2026-08-02) — dark slate blue,
        // distinct from trim's indigo and compare's cobalt; passes the
        // white-text contrast sensor like the rest of the 2026-07-31
        // legibility palette.
        case .findPerson: return .init(badge: "Find", logVerb: "find person", fill: .init(0.28, 0.24, 0.50))
        // Promote to Archive (2026-08-15) — deep archival bronze: warm
        // like the retire/archivebox family, darker than rebuild's brown,
        // and clearly apart from extract's burnt orange.
        case .promote: return .init(badge: "Promote", logVerb: "promote", fill: .init(0.55, 0.36, 0.10))
        // Verify Archive Copies (GH #167, 2026-08-20) — steel slate:
        // cooler and grayer than trim's indigo and findPerson's slate
        // blue; reads as "the auditor", apart from verifyAudio's
        // goldenrod despite sharing the verb.
        case .verifyArchive: return .init(badge: "Fixity", logVerb: "verify archive", fill: .init(0.36, 0.42, 0.60))
        // Archive Angel (2026-09-09) — deep violet: the proposer that
        // precedes Promote's bronze (the retired assessCopies' plum it once
        // stood apart from went with the Promote Helper, S4).
        case .archiveAngel: return .init(badge: "Angel", logVerb: "archive angel", fill: .init(0.70, 0.30, 0.05))   // dark amber — the Angel's orange; Δ≥0.14 from every other fill (nightly sensor 9/10)
        // Delete Duplicates (2026-09-20) — Rick asked for "DELETE in clear
        // high contrast color": white on a strong, saturated red. System
        // `.red` fails the white-text legibility sensor (contrast < 3), so
        // this is red darkened just enough — contrast vs white ≈ 5.6, Δ
        // from Reformat's crimson ≈ 0.17, and still unmistakably RED.
        case .deleteDuplicates: return .init(badge: "DELETE", logVerb: "delete duplicates", fill: .init(0.82, 0.04, 0.06))
        // "Move to Trash" (2026-09-20) — oxblood: the other destructive
        // row, unmistakably red beside DELETE's brighter red (Δ ≈ 0.26)
        // and apart from Reformat's crimson (Δ ≈ 0.14); contrast vs white
        // ≈ 8.9.
        case .pruneCopies: return .init(badge: "TRASH", logVerb: "trash copies", fill: .init(0.58, 0.06, 0.16))
        // Find Similar Footage (2026-09-23) — graphite: a metadata walk,
        // not a media verb. Δ ≥ 0.19 from every other fill (nearest:
        // Rebuild's brown), contrast vs white ≈ 8.5.
        case .findSimilarFootage: return .init(badge: "Footage", logVerb: "find similar footage", fill: .init(0.30, 0.30, 0.30))
        // Bind Fixity to Volume (2026-09-23) — deep violet: a slow full
        // read that only rewrites catalog stamps. Δ ≥ 0.29 from every
        // other fill (nearest: Frames' purple), contrast vs white ≈ 7.
        case .bindFixity: return .init(badge: "Bind", logVerb: "bind fixity", fill: .init(0.55, 0.00, 0.80))
        // Lock files already in the archive (2026-09-27) — deep navy slate: "the vault".
        // Δ ≥ 0.22 from every other fill; contrast vs white ≈ 13.
        case .lockArchive: return .init(badge: "Lock", logVerb: "lock archive files", fill: .init(0.10, 0.20, 0.30))
        // Compare Footage / Footage Spectrum (2026-10-03) — plum: a reading
        // verb like Compare's cobalt, but its own family. Δ ≥ 0.22 from every
        // other fill (nearest: Balance's raspberry), contrast vs white ≈ 9.
        case .compareFootage: return .init(badge: "Spectrum", logVerb: "compare footage", fill: .init(0.50, 0.10, 0.45))
        // Fingerprint Pictures (GH #293, 2026-10-07) — deep ultramarine: a
        // reading verb that only writes catalog notes. Δ ≥ 0.35 from every
        // other fill (nearest: Lock's navy slate), contrast vs white ≈ 14.7.
        case .fingerprintBackfill: return .init(badge: "Fingerprint", logVerb: "fingerprint pictures", fill: .init(0.00, 0.00, 0.58))
        }
    }

    /// Badge text — rendered in small caps by the row view.
    var badgeText: String { style.badge }

    /// Lowercase verb for the videoscan.log START/OUTCOME summary lines.
    var logVerb: String { style.logVerb }
}

// MARK: - State

/// Lifecycle of one operation job.
/// (≈ a C++ tagged union / std::variant — `finished` and `failed`
/// carry a payload string.)
enum MediaFileOperationState: Equatable {
    case running
    /// Cancel was requested; the job's task is still unwinding
    /// (ffmpeg child being terminated, hash loop draining).
    case cancelling
    /// Done — `summary` is the one-line result ("Exact duplicates").
    case finished(summary: String)
    case failed(message: String)
    case cancelled

    /// True while the job still owns live work (running or unwinding).
    var isActive: Bool {
        switch self {
        case .running, .cancelling: return true
        case .finished, .failed, .cancelled: return false
        }
    }

    /// True once the user has asked for this job to stop (unwinding or
    /// already settled). Rick 2026-08-26: a job whose cancel was
    /// requested NEVER ends `.failed` — every conformer's `finish(failed:)`
    /// consults this and diverts to its cancelled terminal instead, so a
    /// SIGTERM'd ffmpeg's non-zero exit (or any typed error thrown while
    /// the Task unwinds) can't repaint a user's Stop as a red Failed.
    /// Deliberately NOT `Task.isCancelled`: the stall watchdogs cancel the
    /// Task too, and a stall must still render Failed with its reason.
    var cancelWasRequested: Bool {
        switch self {
        case .cancelling, .cancelled: return true
        case .running, .finished, .failed: return false
        }
    }

    // MARK: Presentation (pure)

    /// Colour token for a state badge — resolved to a SwiftUI `Color` in
    /// the window, kept symbolic here so the mapping is testable without
    /// SwiftUI. (≈ C++: an enum class the view layer switches on.)
    enum BadgeTint: Equatable {
        case green, red, blue, orange, secondary
    }

    /// What the operations window draws for a state: label text, SF
    /// Symbol (nil for the running states, which show a progress bar
    /// instead), and tint. Cancelled is deliberately NOT red and NOT an
    /// X-in-octagon — Rick 2026-08-26: "if I cancel any MFO verb/job it
    /// shouldn't say 'Failed' with a red x but 'Cancelled' maybe with a
    /// blue x or a square." Failed keeps the red X so a genuine failure
    /// still reads as one.
    struct Badge: Equatable {
        let label: String
        let symbol: String?
        let tint: BadgeTint
    }

    var badge: Badge {
        switch self {
        case .running:
            return Badge(label: "Running", symbol: nil, tint: .secondary)
        case .cancelling:
            return Badge(label: "Cancelling…", symbol: nil, tint: .orange)
        case .finished:
            return Badge(label: "Done", symbol: "checkmark.circle.fill", tint: .green)
        case .failed:
            return Badge(label: "Failed", symbol: "xmark.circle.fill", tint: .red)
        case .cancelled:
            return Badge(label: "Cancelled", symbol: "stop.circle.fill", tint: .blue)
        }
    }
}

// MARK: - First terminal cause (stored-state jobs)

/// The FIRST terminal cause a stored-state job saw — a set-once ledger
/// shared by every job that runs a stall watchdog (Balance, Cleanup,
/// FindPerson, Rebuild, Reformat, Trim, Transcode).
///
/// Why (codex gate 2026-08-26): the watchdog records its reason and
/// cancels the Task while `state` stays `.running`. If the user clicked
/// Stop before the run epilogue, `cancel()` flipped `state` to
/// `.cancelling` and `finish(failed: stallReason)`'s cancel diversion
/// (06b8ce2f) repainted a KNOWN stall as "Cancelled". Ordering must be
/// explicit: whichever event lands first owns the terminal.
///
///   - watchdog:   `record(.stall(reason:))` then cancel the Task
///   - user Stop:  `record(.cancel)` — refused (returns false) after a
///                 stall, so `state` never leaves `.running` for it
///   - finish(failed:) diverts to Cancelled ONLY when `isCancel`
///   - every cancelled-terminal path re-checks `stallReason` first
///
/// ≈ C++: a tiny value-type state machine member with set-once
/// semantics enforced by `record`; `first` is an `std::optional<variant>`.
struct MFOTerminalCause: Equatable {
    enum Kind: Equatable {
        case stall(reason: String)
        case cancel
    }

    private(set) var first: Kind?

    /// Records `kind` only when nothing was recorded before. Returns
    /// whether it won.
    @discardableResult
    mutating func record(_ kind: Kind) -> Bool {
        guard first == nil else { return false }
        first = kind
        return true
    }

    var stallReason: String? {
        if case .stall(let reason)? = first { return reason }
        return nil
    }
    var isStall: Bool { stallReason != nil }
    var isCancel: Bool { first == .cancel }
}

// MARK: - Duration clock (pure)

/// PURE duration math for the operations window's row clock — no I/O
/// and no `Date()` of its own (callers inject `now`), so tests can
/// evaluate it at any simulated wall-clock time.
///
/// Semantics (regression fix 2026-07-07):
///   - active job   → live elapsed, `now − startedAt` (keeps ticking)
///   - terminal job → frozen run duration, `finishedAt − startedAt`
/// A terminal job missing its stamp (shouldn't happen — conformers
/// stamp at the transition) falls back to `now`, i.e. best effort.
enum MediaFileOperationClock {

    static func duration(state: MediaFileOperationState,
                         startedAt: Date,
                         finishedAt: Date?,
                         at now: Date) -> TimeInterval {
        if state.isActive {
            return max(0, now.timeIntervalSince(startedAt))
        }
        return max(0, (finishedAt ?? now).timeIntervalSince(startedAt))
    }

    /// Formatted duration for a row: "5s" / "5m 12s" / "1h 5m" — same
    /// shape as the combine section's formatter so the two sections in
    /// the operations window read alike.
    static func text(state: MediaFileOperationState,
                     startedAt: Date,
                     finishedAt: Date?,
                     at now: Date) -> String {
        format(duration(state: state, startedAt: startedAt,
                        finishedAt: finishedAt, at: now))
    }

    /// Convenience for the row view — pulls the three fields off the
    /// job existential.
    @MainActor
    static func text(for job: any MediaFileOperationJob, at now: Date) -> String {
        text(state: job.state, startedAt: job.startedAt,
             finishedAt: job.finishedAt, at: now)
    }

    static func format(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

// MARK: - Job protocol

/// One row in the Media File Operations window. Conformers are
/// observable classes; the row view subscribes to `objectWillChange`
/// so live progress re-renders.
///
/// The `where` clauses pin the associated types so the window can hold
/// heterogeneous jobs as `any MediaFileOperationJob` and still call
/// `objectWillChange` / key by `id` on the existential.
/// (≈ C++: an abstract base class with a change-notification signal,
/// rather than a template.)
@MainActor
protocol MediaFileOperationJob: AnyObject, ObservableObject, Identifiable
where ObjectWillChangePublisher == ObservableObjectPublisher, ID == UUID {
    var id: UUID { get }
    var kind: MediaFileOperationKind { get }
    /// e.g. "IMG_0123.mov vs tape7.mxf"
    var title: String { get }
    /// Live status line ("Reading both files byte-by-byte…").
    var subtitle: String { get }
    /// 0…1 overall progress; ignored while `isIndeterminate`.
    var fraction: Double { get }
    var isIndeterminate: Bool { get }
    var state: MediaFileOperationState { get }
    var startedAt: Date { get }
    /// When the job reached a terminal state (finished / failed /
    /// cancelled); nil while active. Conformers stamp it exactly once
    /// at the terminal transition. The window uses it to FREEZE the
    /// row clock (regression 2026-07-07: the clock kept ticking after
    /// completion, so a 5-minute job read "45 min" when glanced at 40
    /// minutes later). Deliberately a hard requirement with no default
    /// — the compiler forces every future verb to carry the stamp.
    var finishedAt: Date? { get }
    func cancel()
    /// The app is quitting. Most jobs simply cancel; a job with a saved
    /// plan (Delete Duplicates) SUSPENDS instead — leaves the plan
    /// resumable rather than filing it as abandoned (codex 1593 #5).
    /// Defaulted to `cancel()` below.
    func stopForQuit()
    /// True when the job is active but holds NO in-flight work and can be
    /// left exactly as it is by a quit — a Delete Duplicates run paused at
    /// a safe boundary with its plan on disk (Rick 2026-09-20 evening:
    /// "pausing … should allow quitting when paused, not requiring
    /// stop"). Such a job does not count as "running" for the quit
    /// dialog. Defaulted false below.
    var isQuiescentForQuit: Bool { get }

    // Optional pause capability — defaulted off below.
    var canPause: Bool { get }
    var isPaused: Bool { get }
    func pause()
    func resume()

    /// True when the job was REFUSED before doing any work (duplicate
    /// dispatch, safety gate). The terminal state is still `.failed` —
    /// the flag only changes the file-log OUTCOME wording from
    /// "<verb> FAILED:" to "<verb> refused:", so postmortem greps can
    /// tell "the operation broke" from "the guard said no". Defaulted
    /// false below; conformers with refusal paths set it.
    var wasRefused: Bool { get }

    /// True for jobs whose CANCELLED row should not linger in the list:
    /// the Center removes them the moment the terminal transition lands
    /// (still writing the one "<verb> cancelled:" OUTCOME line first, so
    /// the log trail survives). Rick 2026-08-20, Archive Helper
    /// lifecycle: a cancelled Helper session must disappear completely —
    /// its row is a workspace, not a record of work done. Defaulted
    /// false below; ordinary verbs keep their "Stopped" row.
    var vanishesWhenCancelled: Bool { get }
}

/// Pause is opt-in; jobs whose work is an ffmpeg child adopt it via
/// JobPauseCoordinator (GH #150). In-process loops (Vision extract) and
/// multi-source engines (compare) stay unpausable for now.
extension MediaFileOperationJob {
    var canPause: Bool { false }
    var isPaused: Bool { false }
    func pause() {}
    func resume() {}
    var wasRefused: Bool { false }
    var vanishesWhenCancelled: Bool { false }
    func stopForQuit() { cancel() }
    var isQuiescentForQuit: Bool { false }
}

/// Shared pause plumbing for ffmpeg-backed jobs (GH #150 — MFO Pause All).
///
/// Owns the ProcessControl handed to every ProcessRunner call the job makes
/// (SIGSTOP/SIGCONT on the live child, pause-between-phases remembered),
/// and keeps the job's current StallMonitor honest: a suspended child emits
/// no progress BY DESIGN, so the watchdog must be stopped on pause or it
/// would read the silence as the 14-hour-hang class and kill the job.
/// StallMonitor.start() resets its tick clock, so resume can't instant-fire.
@MainActor
final class JobPauseCoordinator {
    let control = ProcessControl()
    private(set) var isPaused = false
    private weak var monitor: StallMonitor?

    /// Adopt the current phase's watchdog (call right after monitor.start()).
    /// If the user paused between phases, the fresh monitor is stopped
    /// immediately — its child is born suspended via ProcessControl.attach.
    func register(_ monitor: StallMonitor) {
        self.monitor = monitor
        if isPaused { monitor.stop() }
    }

    /// Returns false when already paused (idempotent for the UI).
    @discardableResult
    func pause() -> Bool {
        guard !isPaused else { return false }
        isPaused = true
        control.suspend()
        monitor?.stop()
        return true
    }

    /// Returns false when not paused.
    @discardableResult
    func resume() -> Bool {
        guard isPaused else { return false }
        isPaused = false
        control.resume()
        monitor?.start()
        return true
    }
}

// MARK: - Per-volume gate policy (pure)

/// How many concurrent compare-style heavy reads a volume tolerates.
/// Mirrors the spirit of `ThumbnailPrecachePlanner.concurrencyBound`
/// (HDD=1, SSD/internal unrestricted), with unclassified volumes
/// treated as allowing 2.
enum MediaVolumeGatePolicy {

    /// Slot count for heavy sequential reads on one volume root.
    /// `nil` means unrestricted (no gate is created at all).
    static func compareSlots(mediaTech: VolumeMediaTech,
                             isInternalPath: Bool) -> Int? {
        if isInternalPath { return nil }
        switch mediaTech {
        case .ssd:
            return nil
        case .hdd:
            // One sequential reader at a time — two compares seeking
            // against the same spinning disk thrash it to a crawl.
            return 1
        case .network, .cloud:
            // Gentle on shared links: parallel multi-GB reads over SMB
            // compete with scans and Finder.
            return 2
        default:
            // unknown / RAID variants — unclassified allows 2.
            return 2
        }
    }

    /// "/Volumes/MyBook/sub/file.mov" → "/Volumes/MyBook";
    /// anything not under /Volumes (internal disk) → "/". Forwards to
    /// VideoScanCore's `previewVolumeRoot` — the preview sweep planner
    /// (Core) needs the same rule, so it lives there as the single source.
    static func volumeRoot(forPath path: String) -> String {
        previewVolumeRoot(forPath: path)
    }
}

// MARK: - Volume gate (shared by all job types)

/// One volume gate a job must hold while it reads. `root` is the
/// dedupe/sort key; `label` is the friendly volume name for the
/// "Waiting for…" subtitle. Built per-job by
/// `MediaFileOperationsCenter.gatePlan` — the shared `semaphore` per
/// volume root is what serializes HDD reads across jobs.
///
/// Phase 2: hoisted out of PairCompareJob (where phase 1 nested it) so
/// ExtractFramesJob and future verbs share the same type.
struct MediaVolumeGate {
    let root: String
    let label: String
    let semaphore: AsyncSemaphore
}

// MARK: - Gate-holder board (waiting-row honesty)

/// Who currently holds each volume-gate slot — so a queued job's row
/// can say WHAT it's waiting behind (2026-08-07: a compare waited ~3 h
/// for the LaCie with no clue a paused Verify Audio held the slot;
/// the mystery cost an afternoon). Best-effort UI truth, NOT
/// synchronization: multi-slot volumes overwrite last-writer, and the
/// semaphore stays the only authority on admission.
///
/// codex #292 round: ObservableObject (waiting rows must actually
/// re-render when the holder changes — gated jobs forward
/// `objectWillChange`), and entries are keyed by JOB ID so two jobs
/// with identical display names can't clear each other.
@MainActor
final class VolumeGateBoard: ObservableObject {

    static let shared = VolumeGateBoard()

    struct Holder: Equatable {
        let jobID: UUID
        let name: String
    }

    @Published private(set) var holders: [String: Holder] = [:]

    func claim(root: String, jobID: UUID, name: String) {
        holders[root] = Holder(jobID: jobID, name: name)
    }

    /// Clears only if THIS job still owns the entry — identity is the
    /// job id, never the display string (two "Verify IMG_0795.MOV"
    /// jobs are distinct).
    func clear(root: String, jobID: UUID) {
        if holders[root]?.jobID == jobID { holders[root] = nil }
    }

    /// The waiting-row sentence: names the current holder when known.
    static func describeWait(label: String, root: String) -> String {
        if let holder = shared.holders[root], !holder.name.isEmpty {
            return "Waiting for \(label) — in use by \(holder.name)…"
        }
        return "Waiting for \(label)…"
    }
}

// MARK: - Center (app-level registry)

/// Owns every new-style operation job, newest-first. Created once in
/// `VideoScanApp` and injected via `environmentObject` so the catalog
/// context menu, the operations window, and the quit guard all see the
/// same instance.
@MainActor
final class MediaFileOperationsCenter: ObservableObject {

    /// All jobs, newest-first. Finished jobs linger (capped, see
    /// `finishedCap`) so Rick can read verdicts later.
    @Published private(set) var jobs: [any MediaFileOperationJob] = []

    /// Keep at most this many non-active jobs around.
    static let finishedCap = 50

    /// Brings the window forward when a USER-started job registers
    /// (Rick 2026-09-21; MediaFileOperationsWindowForwarder.swift). `var`
    /// only so tests can swap in a forwarder with a fake presenter.
    var windowForwarder = MediaFileOperationsWindowForwarder.makeDefault()

    /// Maps a file path to the user's media-tech classification for its
    /// volume (from the scan targets). Wired up by VideoScanApp at
    /// launch; nil / no match ⇒ `.unknown` (gate allows 2).
    var mediaTechForPath: ((String) -> VolumeMediaTech)?

    /// One gate per volume root, shared by every job touching that
    /// volume — that sharing is what serializes HDD reads.
    private var volumeGates: [String: AsyncSemaphore] = [:]

    /// Re-publish each job's changes as our own so list-level UI
    /// (header counts) stays fresh. Keyed by job id for cleanup.
    private var jobForwarders: [UUID: AnyCancellable] = [:]

    // MARK: File-log summaries (START / OUTCOME)
    //
    // Every MFO job writes exactly ONE start line and ONE terminal line
    // to `appLog` (~/Library/Logs/VideoScan/videoscan.log) so failures
    // are greppable after the fact — motivating case 2026-07-17: a
    // Balance Audio ffmpeg failure (exit 183) lived only in the MFO
    // window and OSLog; videoscan.log went silent. The START lines are
    // written by the `start…` methods below (they know the per-verb
    // plan clause); the OUTCOME line is written HERE, at the Center's
    // single choke point, by watching each job's change publisher for
    // the terminal transition — no per-job copy-pasted call sites, and
    // derived-state jobs (compare/extract/ripFrames) are covered
    // without touching their internals.
    //
    // Memory: three collections keyed by job UUID, pruned when jobs
    // leave the list — bounded by `finishedCap` + active jobs (≈ 50–60
    // entries, bytes each). Worst case is trivially small.

    /// Unthrottled terminal-transition watchers (the 4 Hz forwarder
    /// above can't be reused — its throttling could sample state
    /// mid-transition, and OUTCOME logging must be exactly-once).
    private var terminalWatchers: [UUID: AnyCancellable] = [:]
    /// Jobs whose OUTCOME line has been written — the exactly-once guard.
    private var terminalLogged: Set<UUID> = []
    /// Coalesces the change-event flood (progress beats arrive 4–10 Hz
    /// per job) down to one pending state check at a time.
    private var terminalCheckScheduled: Set<UUID> = []

    /// Live jobs the quit guard must ask about. A job paused at a safe
    /// boundary with its plan saved (`isQuiescentForQuit`) is active for
    /// the window — its row shows "Paused at N of M" — but not a reason
    /// to warn on quit.
    var runningCount: Int {
        jobs.filter { $0.state.isActive && !$0.isQuiescentForQuit }.count
    }

    /// Every live job, quiescent ones included (the window header).
    var activeCount: Int {
        jobs.filter { $0.state.isActive }.count
    }

    // MARK: Verify Audio diagnosis cache (GH #135)
    //
    // Completed VerifyAudioJobs park their computed AudioVerifyDiagnosis
    // here, keyed by record id, so "Audio Info…" can present
    // it instantly — no re-probe, and NEVER a re-run of the levels pass
    // (the whole-track decode that motivated moving verify off the
    // sheet). Session-scoped, newest-wins per record.
    //
    // Memory: a diagnosis is a few small value structs (findings +
    // shape + optional per-channel levels) — well under 1 KB each.
    // FIFO-capped at 200 entries ⇒ worst case ~200 KB.

    private var verifyDiagnoses: [UUID: AudioVerifyDiagnosis] = [:]
    private var verifyDiagnosisOrder: [UUID] = []
    static let verifyDiagnosisCap = 200

    /// The START line's plan for a Verify Audio job. An Archive Angel
    /// check says so (QA 2026-09-25 MINOR-7: videoscan.log could not tell
    /// the app's own background check from Rick's until it ended).
    nonisolated static func verifyAudioStartPlan(autoRepair: Bool, angelCheck: Bool) -> String {
        if angelCheck { return "Archive Angel check (background) — diagnose the audio track" }
        return autoRepair ? "diagnose + repair if damaged" : "diagnose the audio track"
    }

    /// The Verify Audio job running for this record right now, if any —
    /// Archive Angel's Prepare waits for it instead of being refused as a
    /// duplicate (QA 2026-09-25 MAJOR-1). O(jobs).
    func activeVerifyAudioJob(forRecordID id: UUID) -> VerifyAudioJob? {
        for job in jobs where job.state.isActive {
            if let v = job as? VerifyAudioJob, v.record.id == id { return v }
        }
        return nil
    }

    /// The most recent completed diagnosis for a record this session,
    /// or nil (never verified this session / evicted by the cap).
    func verifyDiagnosis(forRecordID id: UUID) -> AudioVerifyDiagnosis? {
        verifyDiagnoses[id]
    }

    /// Store (newest-wins) with FIFO eviction at the cap. Internal so
    /// tests can seed the cache directly.
    func storeVerifyDiagnosis(_ diagnosis: AudioVerifyDiagnosis, forRecordID id: UUID) {
        if verifyDiagnoses[id] == nil {
            verifyDiagnosisOrder.append(id)
            if verifyDiagnosisOrder.count > Self.verifyDiagnosisCap {
                let evicted = verifyDiagnosisOrder.removeFirst()
                verifyDiagnoses[evicted] = nil
            }
        }
        verifyDiagnoses[id] = diagnosis
        objectWillChange.send()   // context menus key off cache presence
    }

    // MARK: List management

    /// Insert newest-first and start forwarding its change events.
    /// Internal (not private) so tests can drive the list directly.
    ///
    /// Forwarder is THROTTLED to 4 Hz (Rick 2026-06-15). Each running
    /// job publishes `fractionValue` etc. on every ffmpeg progress line
    /// (~4-10 Hz per job) plus on every Whisper/VLM log line, and the
    /// unthrottled forwarder re-broadcast all of it through this
    /// Center's `objectWillChange`. With 3-4 active jobs the Catalog
    /// (which observes the Center via `@EnvironmentObject fileOpsCenter`
    /// in CatalogHelpers.swift) was re-rendering 12-40× per second,
    /// starving NSTableView's main-thread mouse hit-testing and making
    /// row selection by mouse glitch during MFO load. Arrow-key
    /// navigation stayed smooth because it bypasses SwiftUI re-eval.
    /// 250 ms / 4 Hz is faster than the eye can resolve on a progress
    /// bar and is still snappy for state transitions. The MFO window's
    /// per-job rows subscribe to the job directly, so their progress
    /// bars stay smooth — they aren't affected by this throttle.
    /// False when the job was refused (remote viewer, Phase 1: every MFO
    /// kind — compare, extract, rip, reformat, verify, rebuild, balance,
    /// promote, relocate… — reads or writes the master's media and runs
    /// only there). Callers `guard add(job) else { return job }` so a
    /// refused job is never started.
    @discardableResult
    func add(_ job: any MediaFileOperationJob) -> Bool {
        if ViewerWriteGuard.refuse("MediaFileOperationsCenter.add(\(type(of: job)))") { return false }
        jobs.insert(job, at: 0)
        jobForwarders[job.id] = job.objectWillChange
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        terminalWatchers[job.id] = job.objectWillChange
            .sink { [weak self, weak job] _ in
                guard let self, let job else { return }
                self.scheduleTerminalCheck(job)
            }
        // A job can arrive already terminal (a refused/parked row) — it
        // will never publish another change, so check once right away.
        scheduleTerminalCheck(job)
        trimFinished()
        // Origin is user only inside a `startedByUser { }` scope.
        windowForwarder.jobStarted(id: job.id, title: job.title,
                                   origin: windowForwarder.currentOrigin)
        return true
    }

    /// Drop every non-active job (the "Clear Finished" button).
    func clearFinished() {
        let removed = jobs.filter { !$0.state.isActive }
        guard !removed.isEmpty else { return }
        jobs.removeAll { !$0.state.isActive }
        for job in removed { releaseLogBookkeeping(for: job) }
        fileOpsLog.info("cleared \(removed.count) finished operation(s)")
    }

    /// Remove specific jobs from the list regardless of state, releasing
    /// their subscriptions/bookkeeping (OUTCOME line written first if the
    /// job is terminal and unlogged). Used by the vanish-on-cancel path
    /// below (and, until S4 retired it, the Archive Helper's replace
    /// policy) — NOT a user-facing bulk verb.
    func removeJobs(withIDs ids: Set<UUID>) {
        let removed = jobs.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        jobs.removeAll { ids.contains($0.id) }
        for job in removed { releaseLogBookkeeping(for: job) }
    }

    /// Vanish-on-cancel (Rick 2026-08-20, Archive Helper lifecycle rule
    /// 2): a cancelled job that opts in via `vanishesWhenCancelled`
    /// leaves the list the moment its `.cancelled` state lands — no
    /// "Stopped" row to Clear later. Called from the deferred terminal
    /// check, AFTER the OUTCOME line is written. Idempotent.
    private func removeIfCancellationVanishes(_ job: any MediaFileOperationJob) {
        guard job.state == .cancelled, job.vanishesWhenCancelled else { return }
        guard jobs.contains(where: { $0.id == job.id }) else { return }
        fileOpsLog.info("removing cancelled \(job.kind.rawValue, privacy: .public) row (vanishes on cancel): \(job.title, privacy: .public)")
        removeJobs(withIDs: [job.id])
    }

    /// Ask every live job to stop. Used by the quit guard so ffmpeg
    /// children die before the process exits, and by the window
    /// header's "Cancel All" (Rick 2026-07-31).
    func cancelAll() {
        let active = jobs.filter { $0.state.isActive }
        guard !active.isEmpty else { return }
        fileOpsLog.info("cancelAll: stopping \(active.count) running operation(s)")
        for job in active { job.cancel() }
    }

    /// The quit guard's version of `cancelAll`: every live job gets
    /// `stopForQuit()` — a cancel for most, a suspension for jobs that
    /// keep a resumable plan (codex 1593 #5).
    func stopAllForQuit() {
        let active = jobs.filter { $0.state.isActive }
        guard !active.isEmpty else { return }
        fileOpsLog.info("stopAllForQuit: stopping \(active.count) running operation(s) for quit")
        for job in active { job.stopForQuit() }
    }

    /// Pause every live job that supports it (header "Pause All").
    /// Jobs without pause capability keep running — pause is opt-in.
    func pauseAll() {
        let targets = jobs.filter { $0.state.isActive && $0.canPause && !$0.isPaused }
        guard !targets.isEmpty else { return }
        fileOpsLog.info("pauseAll: pausing \(targets.count) operation(s)")
        for job in targets { job.pause() }
    }

    /// Resume every paused job (header "Resume All").
    func resumeAll() {
        let targets = jobs.filter { $0.state.isActive && $0.isPaused }
        guard !targets.isEmpty else { return }
        fileOpsLog.info("resumeAll: resuming \(targets.count) operation(s)")
        for job in targets { job.resume() }
    }

    /// True when at least one live job could be paused right now —
    /// drives the header's adaptive Pause All / Resume All button.
    var hasPausableRunning: Bool {
        jobs.contains { $0.state.isActive && $0.canPause && !$0.isPaused }
    }

    /// True when at least one live job is currently paused.
    var hasPausedJobs: Bool {
        jobs.contains { $0.state.isActive && $0.isPaused }
    }

    /// Enforce `finishedCap`: keep every active job, and the newest
    /// `finishedCap` non-active ones (list is newest-first, so a single
    /// forward pass keeps the right ones).
    private func trimFinished() {
        var finishedKept = 0
        var keep: [any MediaFileOperationJob] = []
        keep.reserveCapacity(jobs.count)
        for job in jobs {
            if job.state.isActive {
                keep.append(job)
            } else if finishedKept < Self.finishedCap {
                finishedKept += 1
                keep.append(job)
            } else {
                releaseLogBookkeeping(for: job)
            }
        }
        if keep.count != jobs.count { jobs = keep }
    }

    // MARK: File-log summary plumbing

    /// Drop a departing job's subscriptions and log bookkeeping — but
    /// first make sure its OUTCOME line was written (a job can be
    /// removed in the same main-actor turn as its terminal transition,
    /// before the scheduled async check ran).
    private func releaseLogBookkeeping(for job: any MediaFileOperationJob) {
        logTerminalIfNeeded(job)
        jobForwarders[job.id] = nil
        terminalWatchers[job.id] = nil
        // Prune the exactly-once marker ONLY when no deferred check is
        // still in flight — a pending check re-reading a pruned id
        // would double-write the OUTCOME line. (The unpruned entry in
        // that rare overlap is 16 bytes, reclaimed at app exit.)
        if !terminalCheckScheduled.contains(job.id) {
            terminalLogged.remove(job.id)
        }
    }

    /// Coalesced deferred state check. `objectWillChange` fires BEFORE
    /// the mutation lands (it's a *will*-change signal — ≈ observing a
    /// setter's entry, not its exit), so the read is hopped to the next
    /// main-actor turn, by which point the new state has settled.
    private func scheduleTerminalCheck(_ job: any MediaFileOperationJob) {
        let id = job.id
        guard !terminalLogged.contains(id),
              terminalCheckScheduled.insert(id).inserted else { return }
        Task { @MainActor [weak self, weak job] in
            guard let self else { return }
            self.terminalCheckScheduled.remove(id)
            guard let job else { return }
            self.logTerminalIfNeeded(job)
            self.removeIfCancellationVanishes(job)
        }
    }

    /// Write the one-and-only OUTCOME line if `job` has reached a
    /// terminal state. Safe to call repeatedly — `terminalLogged` makes
    /// it idempotent.
    private func logTerminalIfNeeded(_ job: any MediaFileOperationJob) {
        guard !job.state.isActive, !terminalLogged.contains(job.id) else { return }
        terminalLogged.insert(job.id)
        terminalWatchers[job.id] = nil
        // Delete Duplicates writes its own final line ("delete duplicates
        // done: <volume> — deleted N (X) · trashed …", 2026-09-22): one
        // line per run, not two.
        if (job as? DeleteDuplicatesJob)?.wroteOwnTerminalLine == true { return }
        if let line = Self.terminalSummaryLine(verb: job.kind.logVerb,
                                              title: job.title,
                                              state: job.state,
                                              wasRefused: job.wasRefused) {
            appLog.write(line)
        }
    }

    /// START line — "<verb>: <title> — <one-clause plan>". Pure; the
    /// `start…` methods below supply the per-verb plan clause.
    /// (`nonisolated` ≈ a free function that only happens to live in
    /// the class's namespace — no shared state, callable off-main.)
    nonisolated static func startSummaryLine(verb: String, title: String,
                                             plan: String) -> String {
        "\(verb): \(title) — \(plan)"
    }

    /// OUTCOME line for a terminal state; nil while the job is active.
    /// Pure and static so tests can pin the exact format per state.
    /// The failed/refused message is the SAME user-facing reason string
    /// the MFO window row shows — no separate wording to drift.
    nonisolated static func terminalSummaryLine(verb: String, title: String,
                                                state: MediaFileOperationState,
                                                wasRefused: Bool) -> String? {
        switch state {
        case .running, .cancelling:
            return nil
        case .finished(let summary):
            return "\(verb) done: \(title) — \(summary)"
        case .failed(let message):
            return wasRefused
                ? "\(verb) refused: \(title) — \(message)"
                : "\(verb) FAILED: \(title) — \(message)"
        case .cancelled:
            return "\(verb) cancelled: \(title)"
        }
    }

    /// Instance convenience for the `start…` methods.
    private func logStart(_ job: any MediaFileOperationJob, plan: String) {
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb,
                                           title: job.title, plan: plan))
    }

    // MARK: Starting operations

    /// Kick off a quick two-file check. The job owns its run Task; the
    /// caller just opens the operations window to watch it.
    @discardableResult
    func startCompare(recordA: VideoRecord, recordB: VideoRecord,
                      onFingerprintKept: (@MainActor () -> Void)? = nil) -> PairCompareJob {
        let gates = gatePlan(forPaths: [recordA.fullPath, recordB.fullPath])
        let job = PairCompareJob(recordA: recordA, recordB: recordB, gates: gates,
                                 onFingerprintKept: onFingerprintKept)
        guard add(job) else { return job }
        job.start()
        fileOpsLog.info("compare started: \(recordA.filename, privacy: .public) vs \(recordB.filename, privacy: .public) (gates: \(gates.count))")
        logStart(job, plan: "duplicate check")
        return job
    }

    // (startExtract / startRipAllFrames — the "Extract Facial Frames…" and
    // "Extract Frames…" jobs — retired 2026-10-07 with their menu items.
    // The .extract / .ripFrames kinds stay, like .trim, so the vocabulary
    // never loses a word an old log line used.)

    /// Kick off "Reformat and Analyze" on a single record — ffmpeg
    /// transcodes the source's legacy-codec stream into modern
    /// H.264/AAC mp4, auto-catalogs the output, and queues it for the
    /// in-app analyzer. Rick 2026-06-14: lets svq3/qdm2/cinepak/etc.
    /// files become analyzable.
    @discardableResult
    func startReformat(record: VideoRecord,
                       model: VideoScanModel,
                       orchestrator: CaptionOrchestrator?) -> ReformatJob {
        let job = ReformatJob(record: record, model: model, orchestrator: orchestrator)
        guard add(job) else { return job }
        job.start()
        fileOpsLog.info("reformat started: \(record.filename, privacy: .public) → \(job.outputURL.lastPathComponent, privacy: .public)")
        logStart(job, plan: "legacy codec → H.264/AAC \(job.outputURL.lastPathComponent)")
        return job
    }

    /// Kick off a Transcode on a single record. Two-preset faithful
    /// conversion — ProRes 422 HQ for FCP editing or HEVC 10-bit for
    /// long-term archive. Catalogs the new derivative as
    /// workspaceActive with `derivedFrom = record.id`, but does NOT
    /// auto-queue Analyze (the user transcoded for a specific
    /// workflow, not for analysis). Rick 2026-06-14 (Pass C).
    @discardableResult
    func startTranscode(record: VideoRecord,
                        preset: TranscodePreset,
                        outputURL: URL,
                        model: VideoScanModel,
                        replaceExisting: Bool = false) -> TranscodeJob {
        let job = TranscodeJob(
            record: record,
            preset: preset,
            outputURL: outputURL,
            model: model,
            replaceExisting: replaceExisting
        )
        guard add(job) else { return job }
        job.start()
        fileOpsLog.info("transcode started: \(record.filename, privacy: .public) preset=\(preset.rawValue, privacy: .public) → \(job.outputURL.lastPathComponent, privacy: .public)")
        logStart(job, plan: "\(preset.rawValue) → \(job.outputURL.lastPathComponent)")
        return job
    }

    /// Kick off "Clean Up Video" with a named recipe. The job renders in
    /// scratch (RAM disk when the estimate fits), atomically publishes
    /// `<stem>_cleaned.mov` beside the original (non-clobbering,
    /// re-uniquified at publish time), and catalogs the output with
    /// provenance (derivedFrom + recipe id/version). The original file is
    /// never modified. `plannedOutput` carries the destination the
    /// confirmation sheet displayed (m3); nil computes it fresh.
    /// Rick 2026-07-07.
    @discardableResult
    func startCleanup(record: VideoRecord,
                      recipe: CleanupRecipe,
                      model: VideoScanModel,
                      plannedOutput: URL? = nil) -> CleanupJob {
        let job = CleanupJob(record: record, recipe: recipe, model: model,
                             plannedOutput: plannedOutput)
        guard add(job) else { return job }
        job.start()
        fileOpsLog.info("cleanup started: \(record.filename, privacy: .public) recipe=\(recipe.id, privacy: .public) v\(recipe.version) → \(job.outputURL.lastPathComponent, privacy: .public)")
        logStart(job, plan: "\(recipe.displayName) → \(job.outputURL.lastPathComponent)")
        return job
    }

    /// Kick off "Trim Master…" on a single record — a stream-copy trim
    /// (never a re-encode) that publishes `<stem>_trimmed.<same ext>`
    /// beside the original and catalogs it with provenance. The original
    /// file and its catalog record are never modified beyond a journey
    /// note. `plannedOutput` carries the destination the trim sheet
    /// displayed; nil computes it fresh. `probedIntra` carries the
    /// sheet's packet-flag keyframe probe verdict (nil = probe not run /
    /// undecidable) so the job's summary wording and verification
    /// tolerance honor what the probe learned about the ACTUAL file,
    /// not just the codec name (QA MAJOR 1, 2026-07-17). Rick 2026-07-16.
    @discardableResult
    func startTrim(record: VideoRecord,
                   range: TrimRange,
                   model: VideoScanModel,
                   plannedOutput: URL? = nil,
                   probedIntra: Bool? = nil) -> TrimJob {
        let job = TrimJob(record: record, range: range, model: model,
                          plannedOutput: plannedOutput,
                          probedIntra: probedIntra)
        guard add(job) else { return job }
        // Same-record dedupe guard (QA MAJOR 2, 2026-07-17). The context
        // menu used to grey out "Trim Master…" while a trim ran (the menu
        // item was retired 2026-09-23), but the Center
        // is the last line of defense for every caller: two trims of one
        // record share the `.vs-partial` path, so the second job's
        // stale-partial cleanup would unlink the first job's in-flight
        // output. Refuse loudly — the parked row carries the reason.
        let duplicate = jobs.contains { other in
            guard other.id != job.id, other.state.isActive,
                  let t = other as? TrimJob else { return false }
            return t.record.id == record.id
        }
        if duplicate {
            fileOpsLog.warning("trim REFUSED (already running for this record): \(record.filename, privacy: .public)")
            // No START line for a refused job — nothing started; the
            // terminal watcher writes the one "trim refused:" line.
            job.refuseToStart(reason: "A trim of \(record.filename) is already running — wait for it to finish (or cancel it) before starting another. Nothing was started.")
            return job
        }
        job.start()
        fileOpsLog.info("trim started: \(record.filename, privacy: .public) [\(TrimTimecode.format(range.inSeconds), privacy: .public) → \(TrimTimecode.format(range.outSeconds), privacy: .public)] → \(job.outputURL.lastPathComponent, privacy: .public)")
        logStart(job, plan: "[\(TrimTimecode.format(range.inSeconds)) → \(TrimTimecode.format(range.outSeconds))] stream copy → \(job.outputURL.lastPathComponent)")
        return job
    }

    /// Kick off "Balance Audio" on a single record. The caller supplies
    /// an ALREADY-COMPUTED analysis — since the GH #137 consolidation
    /// the analyzer only ever runs inside a VerifyAudioJob, and the
    /// Verify results sheet's Balance offer forwards its diagnosis's
    /// analysis here (use the `fromDiagnosis` overload below). The job
    /// re-verifies the output after the fix. Returns nil — REFUSING the
    /// dispatch — when a balance job is already active for this same
    /// record (the MFO-layer duplicate guard: two concurrent jobs
    /// against one input would race on the same planned output name).
    /// GH #116.
    @discardableResult
    func startBalanceAudio(record: VideoRecord,
                           analysis: AudioBalanceAnalysis,
                           model: VideoScanModel,
                           plannedOutput: URL? = nil) -> BalanceAudioJob? {
        let duplicate = jobs.contains { job in
            guard job.state.isActive, let b = job as? BalanceAudioJob else { return false }
            return b.record.id == record.id
        }
        guard !duplicate else {
            fileOpsLog.notice("balanceAudio REFUSED duplicate dispatch: \(record.filename, privacy: .public) already has an active balance job")
            // No job row exists for this refusal (dispatch returned nil),
            // so the terminal watcher can't write it — log it here.
            appLog.write("balance audio refused: \(record.filename) — a balance job for this file is already running; nothing was started")
            return nil
        }
        let job = BalanceAudioJob(record: record, analysis: analysis,
                                  model: model, plannedOutput: plannedOutput)
        guard add(job) else { return job }
        job.start()
        fileOpsLog.info("balanceAudio started: \(record.filename, privacy: .public) class=\(analysis.classification.rawValue, privacy: .public) → \(job.outputURL.lastPathComponent, privacy: .public)")
        logStart(job, plan: "\(analysis.classification.rawValue) → \(job.outputURL.lastPathComponent)")
        return job
    }

    /// Balance Audio straight from a completed Verify diagnosis — the
    /// GH #137 consolidation entry point (the Verify results sheet's
    /// "Balance Audio" button). The diagnosis already CONTAINS the
    /// balance analysis, so this can never trigger a fresh decode;
    /// a diagnosis without one (reference movie, no-audio, undecodable
    /// track) returns nil and starts nothing — the sheet never shows
    /// the button in those cases, this guard is the model-layer twin.
    @discardableResult
    func startBalanceAudio(record: VideoRecord,
                           fromDiagnosis diagnosis: AudioVerifyDiagnosis,
                           model: VideoScanModel,
                           plannedOutput: URL? = nil) -> BalanceAudioJob? {
        guard let analysis = diagnosis.balanceAnalysis else {
            fileOpsLog.notice("balanceAudio dispatch skipped: \(record.filename, privacy: .public) — diagnosis carries no balance analysis")
            return nil
        }
        return startBalanceAudio(record: record, analysis: analysis,
                                 model: model, plannedOutput: plannedOutput)
    }

    /// Kick off "Rebuild Audio Track" — the Verify Audio repair
    /// (GH #128): video stream-copied, audio re-encoded to pcm_s16le in
    /// a .mov beside the original. The sheet already ran the diagnosis
    /// (verify-then-repair); `reason` is the diagnosed cause, carried
    /// into the derived record's File Journey stamp. Returns nil —
    /// REFUSING the dispatch — when a rebuild is already active for
    /// this same record (two jobs against one input would race on the
    /// same planned output name).
    @discardableResult
    func startRebuildAudio(record: VideoRecord,
                           reason: String,
                           shape: AudioVerifyShape,
                           model: VideoScanModel,
                           plannedOutput: URL? = nil) -> RebuildAudioJob? {
        let duplicate = jobs.contains { job in
            guard job.state.isActive, let r = job as? RebuildAudioJob else { return false }
            return r.record.id == record.id
        }
        guard !duplicate else {
            fileOpsLog.notice("rebuildAudio REFUSED duplicate dispatch: \(record.filename, privacy: .public) already has an active rebuild job")
            appLog.write("rebuild audio refused: \(record.filename) — a rebuild job for this file is already running; nothing was started")
            return nil
        }
        // Per-disk pacing (GH #132): the rebuild is a long sequential
        // read+write on the source's volume — it takes the same gates
        // compare/extract do, so a 25-job batch on one HDD renders one
        // at a time instead of thrashing the disk.
        let job = RebuildAudioJob(record: record, reason: reason,
                                  shape: shape, model: model,
                                  plannedOutput: plannedOutput,
                                  gates: gatePlan(forPaths: [record.fullPath]))
        guard add(job) else { return job }
        job.start()
        fileOpsLog.info("rebuildAudio started: \(record.filename, privacy: .public) (\(reason, privacy: .public)) → \(job.outputURL.lastPathComponent, privacy: .public)")
        logStart(job, plan: "\(reason) → \(job.outputURL.lastPathComponent)")
        return job
    }

    /// Kick off "Verify Audio" as an MFO job (GH #135 — the levels pass
    /// decodes the whole audio track, so it must never block the UI in
    /// a sheet). Persists the verdict on completion, parks the computed
    /// diagnosis in the cache for "Verification Results…", and — when
    /// `autoRepair` is set (the batch "Repair Damaged Audio" path) —
    /// chains straight into `startRebuildAudio` for an unsupported-codec
    /// finding (the Center's duplicate guard protects the chain).
    /// Returns nil — REFUSING the dispatch — when a verify job is
    /// already active for this same record.
    ///
    /// `diagnoseOverride` is a TEST SEAM only (the VerifyAudioProbe
    /// override convention) — every production call site passes nil.
    @discardableResult
    func startVerifyAudio(record: VideoRecord,
                          model: VideoScanModel,
                          autoRepair: Bool = false,
                          angelCheck: Bool = false,
                          diagnoseOverride: (@Sendable (String) async throws -> AudioVerifyDiagnosis)? = nil) -> VerifyAudioJob? {
        let duplicate = jobs.contains { job in
            guard job.state.isActive, let v = job as? VerifyAudioJob else { return false }
            return v.record.id == record.id
        }
        guard !duplicate else {
            fileOpsLog.notice("verifyAudio REFUSED duplicate dispatch: \(record.filename, privacy: .public) already has an active verify job")
            appLog.write("verify audio refused: \(record.filename) — a verify job for this file is already running; nothing was started")
            return nil
        }
        let job = VerifyAudioJob(record: record,
                                 model: model,
                                 autoRepair: autoRepair,
                                 gates: gatePlan(forPaths: [record.fullPath]),
                                 diagnoseOverride: diagnoseOverride)
        job.onDiagnosis = { [weak self, weak model] job, diagnosis in
            guard let self else { return }
            self.storeVerifyDiagnosis(diagnosis, forRecordID: job.record.id)
            guard job.autoRepair, let model else { return }
            // One repair verb per finding kind: the rebuild covers the
            // unsupported/undecodable-codec class only. Other findings
            // (reference movie, wrong-audio) have no automatic repair.
            if let finding = diagnosis.findings.first(where: {
                if case .unsupportedCodec = $0 { return true }
                return false
            }) {
                self.startRebuildAudio(record: job.record,
                                       reason: VerifyAudioRules.noteFragment(for: finding),
                                       shape: diagnosis.shape,
                                       model: model)
            }
        }
        guard add(job) else { return job }
        job.start()
        fileOpsLog.info("verifyAudio started: \(record.filename, privacy: .public) (autoRepair=\(autoRepair))")
        logStart(job, plan: Self.verifyAudioStartPlan(autoRepair: autoRepair, angelCheck: angelCheck))
        return job
    }

    /// Kick off "Verify Video" as an MFO job (Rick 2026-09-23) — built
    /// like `startVerifyAudio`: the full decode reads the whole file, so
    /// it runs here, gated per volume, never in a sheet. Persists the
    /// verdict on completion. Returns nil — REFUSING the dispatch — when a
    /// Verify Video job is already active for this same record.
    ///
    /// `diagnoseOverride` is a TEST SEAM only — production passes nil.
    @discardableResult
    func startVerifyVideo(record: VideoRecord,
                          model: VideoScanModel,
                          diagnoseOverride: (@Sendable (String) async throws -> VideoVerifyDiagnosis)? = nil) -> VerifyVideoJob? {
        let duplicate = jobs.contains { job in
            guard job.state.isActive, let v = job as? VerifyVideoJob else { return false }
            return v.record.id == record.id
        }
        guard !duplicate else {
            fileOpsLog.notice("verifyVideo REFUSED duplicate dispatch: \(record.filename, privacy: .public) already has an active verify video job")
            appLog.write("verify video refused: \(record.filename) — a verify video job for this file is already running; nothing was started")
            return nil
        }
        let job = VerifyVideoJob(record: record,
                                 model: model,
                                 gates: gatePlan(forPaths: [record.fullPath]),
                                 diagnoseOverride: diagnoseOverride)
        guard add(job) else { return job }
        job.start()
        fileOpsLog.info("verifyVideo started: \(record.filename, privacy: .public)")
        logStart(job, plan: "check the picture (header, timestamps, full decode)")
        return job
    }

    /// "Check Media…" (Rick 2026-10-07) — ONE job for the whole selection,
    /// gated per volume file by file. Records already inside an active
    /// Check Media job are left out (never checked twice at once); nil when
    /// nothing is left to start.
    ///
    /// `quickRunner` / `fullRunner` are TEST SEAMS only — production passes nil.
    @discardableResult
    func startCheckMedia(records: [VideoRecord],
                         tier: MediaReportCard.Tier,
                         model: VideoScanModel,
                         quickRunner: CheckMediaJob.QuickRunner? = nil,
                         fullRunner: CheckMediaJob.FullRunner? = nil) -> CheckMediaJob? {
        let busy = Set(jobs.compactMap { job -> [UUID]? in
            guard job.state.isActive, let c = job as? CheckMediaJob else { return nil }
            return c.records.map(\.id)
        }.joined())
        let fresh = records.filter { !busy.contains($0.id) }
        guard !fresh.isEmpty else {
            fileOpsLog.notice("checkMedia REFUSED duplicate dispatch: every selected file is already being checked")
            appLog.write("check media refused: the selected file(s) are already being checked; nothing was started")
            return nil
        }
        let job = CheckMediaJob(records: fresh, tier: tier, model: model, center: self,
                                gatesFor: { [weak self] in self?.gatePlan(forPaths: [$0]) ?? [] },
                                quickRunner: quickRunner, fullRunner: fullRunner)
        guard add(job) else { return job }
        job.start()
        fileOpsLog.info("checkMedia started: \(fresh.count) file(s), tier=\(tier.rawValue, privacy: .public)")
        logStart(job, plan: tier == .full
                 ? "full check (header, timing, frame windows, every frame decoded, sound levels)"
                 : "quick check (header, timing, frame windows)")
        return job
    }

    /// "Analyze This File" — runs VLM + Whisper on a single record
    /// through the orchestrator (uses fullPath as the prefix so only
    /// this one file enters the candidate set). Rick 2026-06-14:
    /// per-file analyze belongs in the Media File Operations window;
    /// volume-wide batches belong in the Analyze Dashboard.
    @discardableResult
    func startAnalyzeOne(record: VideoRecord,
                         model: VideoScanModel,
                         orchestrator: CaptionOrchestrator,
                         stages: Set<AnalyzeStage> = AnalyzeStage.all) -> AnalyzeJob {
        let job = AnalyzeJob(record: record, model: model,
                             orchestrator: orchestrator, stages: stages)
        guard add(job) else { return job }
        job.start()
        fileOpsLog.info("analyze started: \(record.filename, privacy: .public) stages=\(stages.map(\.rawValue).joined(separator: ","), privacy: .public)")
        logStart(job, plan: "stages \(stages.map(\.rawValue).sorted().joined(separator: "+"))")
        return job
    }

    /// Build the ordered list of volume gates a job must hold while it
    /// reads. Deduped per volume root; sorted by root so every job
    /// acquires in the same order (≈ the classic lock-ordering rule —
    /// no deadlocks). Volumes whose policy is unrestricted get no gate.
    /// Internal (was private) so verb extensions in sibling files
    /// (MediaFileOperations+Promote.swift) can build the same plan.
    func gatePlan(forPaths paths: [String]) -> [MediaVolumeGate] {
        var plan: [MediaVolumeGate] = []
        var seenRoots = Set<String>()
        for path in paths {
            let root = MediaVolumeGatePolicy.volumeRoot(forPath: path)
            guard seenRoots.insert(root).inserted else { continue }
            let isInternal = !path.hasPrefix("/Volumes/")
            let tech = mediaTechForPath?(path) ?? .unknown
            guard let slots = MediaVolumeGatePolicy.compareSlots(
                mediaTech: tech, isInternalPath: isInternal) else { continue }
            let gate: AsyncSemaphore
            if let existing = volumeGates[root] {
                gate = existing
            } else {
                gate = AsyncSemaphore(limit: slots)
                volumeGates[root] = gate
                fileOpsLog.info("volume gate created for \(root, privacy: .public): \(slots) slot(s) (\(tech.rawValue, privacy: .public))")
            }
            plan.append(MediaVolumeGate(
                root: root,
                label: VolumeReachability.displayLabel(forPath: path),
                semaphore: gate))
        }
        return plan.sorted { $0.root < $1.root }
    }
}
