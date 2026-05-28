import Foundation

// MARK: - Avid Bin Scanning
//
// Discover .avb files on every scan target, parse them with AvbParser,
// and cross-reference the parsed clip metadata against the existing MXF
// records. Lives in its own file because (a) it operates on a different
// slice of the catalog than the main scan path (Avid bins, not media
// essence) and (b) the Combine/Correlate pipeline can also invoke
// crossReferenceAvidBins after running its own correlation pass.

extension VideoScanModel {

    /// Scan all scan target paths for .avb files and parse them.
    func scanAvidBins() {
        let paths = scanTargets.map { $0.searchPath }.filter { !$0.isEmpty }
        guard !paths.isEmpty else {
            log("No scan targets configured — add a volume first.")
            return
        }

        log("━━ Scanning for Avid bin files (.avb) ━━")
        avidBinResults = []

        Task {
            var allResults: [AvbBinResult] = []
            for path in paths {
                await MainActor.run {
                    log("  Searching \(path) for .avb files…")
                }
                let results = await Task.detached(priority: .userInitiated) {
                    AvbParser.scanDirectory(path)
                }.value
                allResults.append(contentsOf: results)
            }

            await MainActor.run {
                self.avidBinResults = allResults
                let totalClips = allResults.reduce(0) { $0 + $1.clips.count }
                let totalBins = allResults.count
                let errorCount = allResults.reduce(0) { $0 + $1.errors.count }

                log("  Found \(totalBins) .avb files containing \(totalClips) clips")
                if errorCount > 0 {
                    log("  ⚠ \(errorCount) parse errors — some bins may use newer format features")
                }

                for result in allResults {
                    if !result.errors.isEmpty {
                        log("  \(result.binName).avb: \(result.errors.joined(separator: ", "))")
                    }
                    for clip in result.clips where clip.mobType == "MasterMob" {
                        let trackDesc = clip.tracks.map { t in
                            let kind = t.mediaKind == "picture" ? "V" : (t.mediaKind == "sound" ? "A" : String(t.mediaKind.prefix(2)).uppercased())
                            return "\(kind)\(t.index)"
                        }.joined(separator: ", ")
                        let tapeStr = clip.tapeName.isEmpty ? "" : " tape:\(clip.tapeName)"
                        let pathStr = clip.mediaPath.isEmpty ? "" : " \(clip.mediaPath)"
                        log("    \(clip.clipName)  [\(trackDesc)]\(tapeStr)\(pathStr)")
                    }
                }

                // Auto cross-reference with existing records
                crossReferenceAvidBins()
            }
        }
    }

    /// Cross-reference parsed Avid bin clips with scanned MXF records.
    /// Matching is done by filename stem and media path patterns since
    /// MXF UMID extraction via ffprobe requires specific format flags.
    func crossReferenceAvidBins() {
        guard !avidBinResults.isEmpty, !records.isEmpty else { return }

        // Build lookup tables from Avid clips
        // Key: lowercased filename stem from mediaPath → clip
        var clipsByMediaFilename: [String: AvbClip] = [:]
        // Key: material UUID → clip
        var clipsByMaterialUUID: [String: AvbClip] = [:]

        for result in avidBinResults {
            for clip in result.clips {
                // Index by media path filename
                if !clip.mediaPath.isEmpty {
                    let mediaFilename = URL(fileURLWithPath: clip.mediaPath).lastPathComponent.lowercased()
                    clipsByMediaFilename[mediaFilename] = clip
                }
                if !clip.mediaPathPosix.isEmpty {
                    let mediaFilename = URL(fileURLWithPath: clip.mediaPathPosix).lastPathComponent.lowercased()
                    clipsByMediaFilename[mediaFilename] = clip
                }
                // Index by material UUID
                if !clip.materialUUID.isEmpty {
                    clipsByMaterialUUID[clip.materialUUID.lowercased()] = clip
                }
            }
        }

        var matchCount = 0
        for record in records {
            // Try matching by filename (most reliable for MXF files)
            let recFilename = record.filename.lowercased()
            if let clip = clipsByMediaFilename[recFilename] {
                applyAvidMetadata(clip: clip, to: record)
                matchCount += 1
                continue
            }

            // Try matching by partial path — the MXF filename might be under
            // Avid MediaFiles/MXF/n/ and the media path in the bin points there
            for (mediaFilename, clip) in clipsByMediaFilename {
                if recFilename == mediaFilename ||
                   record.fullPath.lowercased().hasSuffix(mediaFilename) {
                    applyAvidMetadata(clip: clip, to: record)
                    matchCount += 1
                    break
                }
            }
        }

        if matchCount > 0 {
            log("━━ Cross-referenced \(matchCount) media files with Avid bin metadata ━━")
        } else {
            log("  No matches found between Avid bins and scanned media (bins may reference different volumes)")
        }
    }

    fileprivate func applyAvidMetadata(clip: AvbClip, to record: VideoRecord) {
        record.avidClipName = clip.clipName
        record.avidMobID = clip.mobID
        record.avidMaterialUUID = clip.materialUUID
        record.avidBinFile = clip.binFileName
        record.avidMobType = clip.mobType
        record.avidMediaPath = clip.mediaPath.isEmpty ? clip.mediaPathPosix : clip.mediaPath
        record.avidTapeName = clip.tapeName
        record.avidEditRate = clip.editRate

        let trackDesc = clip.tracks.map { t in
            let kind = t.mediaKind == "picture" ? "V" : (t.mediaKind == "sound" ? "A" : t.mediaKind.prefix(2).uppercased())
            return "\(kind)\(t.index)"
        }.joined(separator: ", ")
        record.avidTracks = trackDesc

        // Fill in tape name if record doesn't already have one
        if record.tapeName.isEmpty && !clip.tapeName.isEmpty {
            record.tapeName = clip.tapeName
        }
    }
}
