// ScanJobRow+Summary.swift
// The search-complete summary sentence(s) — collapsed and expanded variants,
// plus the plain-text mirror logged to OSLog — extracted verbatim from
// ScanJobRow's body in ScanJobRow.swift (refactor 2026-06-25). A cross-file
// `extension` can't see `private` members, so the ScanJobRow computed
// properties shared with this code (personName/volName/engineName/
// isVolumeOffline/isJobDone) were widened to internal in the main file.
// (Swift extension ≈ C++ partial class via free member functions: no new
// stored state allowed, methods share the same `self`; `private` here means
// file-private to THIS file.)

import SwiftUI

extension ScanJobRow {

    // MARK: - Search-complete summary sentence
    //
    // "Search Complete: Found Donna in 5 files on Volume-Name. (Searched
    // 24 total files. Elapsed time 0m 18s)"
    //
    // Or, when nothing matched:
    //
    // "Search Complete: Found no matches for Donna on Volume-Name. (Searched
    // 24 total files. Elapsed time 0m 18s)"
    //
    // Used in BOTH the collapsed row (chevron right) and the expanded row
    // (chevron down) when the job is genuinely .done. ScanJobStatus.isDone
    // also returns true for .cancelled, which is NOT what we want for this
    // sentence — `isJobDone` below is the precise gate.

    /// Plain-text version of the summary sentence — kept here so we log
    /// the same string to OSLog that the UI shows. The agent reading
    /// `log stream` sees what the user sees.
    private var summaryText: String {
        let hits = job.videosWithHits
        let total = job.videosTotal
        let elapsed = formatElapsed(job.elapsedSecs)
        let onVol = volName.isEmpty ? "" : " on \(volName)"
        let usingEngine = " using algorithm: \(engineName)"
        let stats = "(Searched \(total) total file\(total == 1 ? "" : "s"). Elapsed time \(elapsed))"
        let header = job.wasInterrupted ? "Search Interrupted" : "Search Complete"
        if hits > 0 {
            return "\(header): Found \(personName) in \(hits) file\(hits == 1 ? "" : "s")\(onVol)\(usingEngine). \(stats)"
        } else {
            return "\(header): Found no matches for \(personName)\(onVol)\(usingEngine). \(stats)"
        }
    }

    @ViewBuilder
    var summarySentence: some View {
        // job.results.count = number of unique videos that matched.
        // job.videosWithHits is a running counter that's noisier; the
        // results array is the authoritative "files containing the person."
        let hits = job.results.count
        let total = job.videosTotal
        let elapsed = formatElapsed(job.elapsedSecs)

        if job.wasInterrupted {
            Text("Search Interrupted:")
                .font(.title3.weight(.semibold))
                .foregroundColor(.yellow)
        } else {
            Text("Search Complete:")
                .font(.title3.weight(.semibold))
                .foregroundColor(.green)
        }

        if hits > 0 {
            Text("Found")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(personName)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Text("in")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("\(hits) file\(hits == 1 ? "" : "s")")
                .font(.title3.weight(.semibold))
                .foregroundColor(.green)
        } else {
            Text("Found no matches for")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(personName)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
        }

        if !volName.isEmpty {
            Text("on")
                .font(.title3)
                .foregroundStyle(.secondary)
            // Volume name italicizes + yellows when the drive isn't mounted.
            // Rick wanted "(offline)" tucked in parens so it's clearly state
            // info, not part of the volume's actual name.
            Text(volName)
                .font(isVolumeOffline ? .title3.weight(.medium).italic() : .title3.weight(.medium))
                .foregroundColor(isVolumeOffline ? .yellow : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if isVolumeOffline {
                Text("(offline)")
                    .font(.title3.italic())
                    .foregroundColor(.yellow)
            }
        }
        Text("using algorithm:")
            .font(.title3)
            .foregroundStyle(.secondary)
        Text(engineName)
            .font(.title3.weight(.medium))
            .foregroundColor(.accentColor)
            .lineLimit(1)
        Text(".")
            .font(.title3)
            .foregroundStyle(.secondary)

        Text("(Searched \(total) total file\(total == 1 ? "" : "s"). Elapsed time \(elapsed))")
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder
    var expandedSummarySentence: some View {
        let hits = job.results.count
        let total = job.videosTotal
        let elapsed = formatElapsed(job.elapsedSecs)

        if job.wasInterrupted {
            Text("Search Interrupted:")
                .font(.title2.weight(.semibold))
                .foregroundColor(.yellow)
        } else {
            Text("Search Complete:")
                .font(.title2.weight(.semibold))
                .foregroundColor(.green)
        }

        if hits > 0 {
            Text("Found")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(personName)
                .font(.title2.weight(.bold))
                .lineLimit(1)
            Text("in")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("\(hits) file\(hits == 1 ? "" : "s")")
                .font(.title2.weight(.semibold))
                .foregroundColor(.green)
        } else {
            Text("Found no matches for")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(personName)
                .font(.title2.weight(.bold))
                .lineLimit(1)
        }

        if !volName.isEmpty {
            Text("on")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(volName)
                .font(isVolumeOffline ? .title2.weight(.medium).italic() : .title2.weight(.medium))
                .foregroundColor(isVolumeOffline ? .yellow : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if isVolumeOffline {
                Text("(offline)")
                    .font(.title2.italic())
                    .foregroundColor(.yellow)
            }
        }
        Text("using algorithm:")
            .font(.title2)
            .foregroundStyle(.secondary)
        Text(engineName)
            .font(.title2.weight(.medium))
            .foregroundColor(.accentColor)
            .lineLimit(1)
        Text(".")
            .font(.title2)
            .foregroundStyle(.secondary)

        Text("(Searched \(total) total file\(total == 1 ? "" : "s"). Elapsed time \(elapsed))")
            .font(.body)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
