// AvidIDBackfill.swift
// "Fill In Avid IDs…" — the catalog's side (A/V pair-matcher fix, Rick
// 2026-10-22). Every live MXF row was scanned before the Avid identity was
// captured (all 3,699 had an empty UMID; the clip name was never read), and
// a rescan does not re-read an unchanged file, so the pair rule
// (AvidPairEvidence) had nothing to go on. This fills the three fields:
//
//   • `plan` — every live `.mxf` row whose UMID or clip name is still
//     empty, in path order (a resumed run reads disks in the same order).
//     ONE pass over the records, O(records); never in a view.
//   • `probe` — ONE tag-only ffprobe (`-show_entries format_tags`, no
//     stream analysis) plus a read of the first 256 KB for the render
//     marker. READ-ONLY: media is never written.
//   • `apply` — compare-and-set on the record the plan named (same id,
//     path and size); fills only EMPTY fields, never clears one, and only
//     ever turns the render flag on.
//   • `releaseStoredPairs` — with the IDs known, the stored pairs they
//     prove wrong are released (CorrelationScorer.releaseInvalidPairs —
//     catalog only), each one logged.
//
// A namespace that takes the model, not an `extension VideoScanModel` (the
// model is being split into stores — GH #337, VideoScanModelSplitGuardTests).
// (For Rick: an `enum` with no cases ≈ a C++ namespace of free functions.)

import Foundation
import VideoScanCore
import os

private let avidIDLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "avidIDs")

/// One MXF row the backfill will read — plain values captured on the main
/// actor, safe to hand to the off-main ffprobe.
struct AvidIDBackfillItem: Equatable, Sendable, Identifiable {
    let id: UUID
    let path: String
    let filename: String
    let sizeBytes: Int64
}

/// What one file yielded.
struct AvidIDProbe: Equatable, Sendable {
    var umid = ""
    var name = ""
    var isRender = false
    var hasAnyID: Bool { !umid.isEmpty || !name.isEmpty }
}

/// What a compare-and-set write did.
enum AvidIDWrite: Equatable, Sendable {
    /// Written; `changed` = at least one field gained a value.
    case written(changed: Bool)
    /// The record moved, changed size, left the catalog, or the catalog is
    /// read-only — nothing written.
    case recordChanged
}

enum AvidIDBackfill {

    /// May the backfill read this record? A live MXF row with a path whose
    /// UMID or clip name is still empty.
    static func needsAvidIDs(_ rec: VideoRecord) -> Bool {
        guard rec.purgedAt == nil, !rec.isSetAside, !rec.isSuperseded, !rec.fullPath.isEmpty,
              (rec.filename as NSString).pathExtension.lowercased() == "mxf" else { return false }
        return rec.materialPackageUMID.isEmpty || rec.materialPackageName.isEmpty
    }

    /// Pure over its inputs (the tests drive it with 100k synthetic rows).
    static func plan(records: [VideoRecord]) -> [AvidIDBackfillItem] {
        records.lazy.filter(needsAvidIDs)
            .map { AvidIDBackfillItem(id: $0.id, path: $0.fullPath, filename: $0.filename, sizeBytes: $0.sizeBytes) }
            .sorted { $0.path < $1.path }
    }

    /// ffprobe's format tags (+ the header) → the three fields. Pure; the
    /// tests feed it injected tags.
    static func avidIDs(formatTags tags: [String: String], header: Data?) -> AvidIDProbe {
        let name = tags["material_package_name"] ?? ""
        return AvidIDProbe(umid: tags["material_package_umid"] ?? "", name: name,
                           isRender: AvidRenderSignal.isRender(name: name, header: header))
    }

    /// One tag-only ffprobe + the header read. nil when neither could read
    /// the file. Read-only; safe from any executor.
    static func probe(path: String) async -> AvidIDProbe? {
        let args = ["-v", "error", "-print_format", "json", "-show_entries", "format_tags", path]
        let result = await ProcessRunner.runCapturingStderr(executable: ToolLocator.ffprobePath,
                                                            arguments: args, deadlineSeconds: 60)
        let tags = result.stdout.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(FFProbeOutput.self, from: $0) }?.format?.tags
        let header = AvidRenderSignal.readHeader(path: path)
        guard tags != nil || header != nil else { return nil }
        return avidIDs(formatTags: tags ?? [:], header: header)
    }

    /// The backfill's write: compare-and-set on the planned record. Fills
    /// only empty fields; the render flag only ever turns on.
    @MainActor
    static func apply(_ probe: AvidIDProbe, to item: AvidIDBackfillItem, in model: VideoScanModel) -> AvidIDWrite {
        guard !model.isReadOnly, let rec = model.record(forID: item.id), rec.fullPath == item.path,
              rec.sizeBytes == item.sizeBytes, rec.purgedAt == nil else { return .recordChanged }
        return .written(changed: fill(probe, into: rec))
    }

    /// The field fill itself (pure on the record). True when a field gained
    /// a value.
    static func fill(_ probe: AvidIDProbe, into rec: VideoRecord) -> Bool {
        var changed = false
        if rec.materialPackageUMID.isEmpty, !probe.umid.isEmpty { rec.materialPackageUMID = probe.umid; changed = true }
        if rec.materialPackageName.isEmpty, !probe.name.isEmpty { rec.materialPackageName = probe.name; changed = true }
        if !rec.isAvidRender, probe.isRender { rec.isAvidRender = true; changed = true }
        return changed
    }

    /// With the IDs known: release the stored pairs they prove wrong,
    /// through the one door (AvidPairRelease: safety copy, then the
    /// journal, then the release — a failed copy holds). Catalog only — no
    /// media file is touched; the caller saves.
    @MainActor
    static func releaseStoredPairs(in model: VideoScanModel, safetyCopy: () -> String?,
                                   journal: URL = AvidPairRelease.defaultJournalURL) -> AvidPairRelease.Outcome {
        AvidPairRelease.release(in: model, context: "after Fill In Avid IDs", safetyCopy: safetyCopy,
                                journal: journal, sink: { note($0, model: model) })
    }

    /// Console + catalog.log (`log`), videoscan.log and the unified log —
    /// the backfill's one sink for START / progress / OUTCOME lines.
    @MainActor
    static func note(_ line: String, model: VideoScanModel) {
        model.log(line)
        appLog.write("[avid-ids] " + line)
        avidIDLog.notice("\(line, privacy: .public)")
    }
}
