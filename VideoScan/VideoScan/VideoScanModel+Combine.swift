import Foundation

extension VideoScanModel {

    // MARK: - Combine

    /// All correlated pairs (video record is always first in tuple)
    var correlatedPairs: [(video: VideoRecord, audio: VideoRecord)] {
        var seen = Set<UUID>()
        var pairs: [(VideoRecord, VideoRecord)] = []
        for rec in records {
            guard let partner = rec.pairedWith, !seen.contains(rec.id) else { continue }
            seen.insert(rec.id)
            seen.insert(partner.id)
            let v = rec.streamType == .videoOnly ? rec : partner
            let a = rec.streamType == .audioOnly ? rec : partner
            pairs.append((v, a))
        }
        return pairs
    }

    func combineSelectedPairs(_ pairs: [(video: VideoRecord, audio: VideoRecord)], outputFolder: URL, technique: CombineJobStatus.CombineTechnique = .streamCopy, maxConcurrency: Int? = nil) {
        guard !pairs.isEmpty else {
            log("No pairs selected to combine.")
            return
        }
        combineAllPairsInternal(pairs: pairs, outputFolder: outputFolder, technique: technique, maxConcurrency: maxConcurrency)
    }

    func combineAllPairs(outputFolder: URL, maxConcurrency: Int? = nil) {
        let pairs = correlatedPairs
        guard !pairs.isEmpty else {
            log("No correlated pairs to combine.")
            return
        }
        combineAllPairsInternal(pairs: pairs, outputFolder: outputFolder, maxConcurrency: maxConcurrency)
    }

    // MARK: - Combine helpers

    /// Mount the RAM disk for combine temp buffering. Returns the base URL to
    /// use (RAM disk if mounted, otherwise the system temp dir) and a flag.
    func mountCombineRAMDisk() async -> (tempBase: URL, hasRAMDisk: Bool) {
        let combineDiskMB = perfSettings.ramDiskGB * 1024
        let hasRAMDisk = await ramDisk.mount(sizeMB: combineDiskMB)
        let ramMountPoint = await ramDisk.mountPoint
        if hasRAMDisk, let mp = ramMountPoint {
            log("  RAM disk mounted at \(mp) (\(perfSettings.ramDiskGB) GB)")
            return (URL(fileURLWithPath: mp), true)
        }
        return (FileManager.default.temporaryDirectory, false)
    }

    /// Buffer a single network-side file to the combine temp dir.
    /// Returns the local URL to pass to ffmpeg.
    func bufferCombineSource(
        kind: String,
        from remotePath: String,
        to destination: URL,
        hasRAMDisk: Bool
    ) async throws -> URL {
        await MainActor.run {
            self.log("    Buffering \(kind) to \(hasRAMDisk ? "RAM disk" : "temp")...")
        }
        try await CombineVerifier.bufferedCopy(from: URL(fileURLWithPath: remotePath), to: destination)
        return destination
    }

    /// Copy network-backed inputs to `tempBase` and return the local paths to use.
    /// Creates (and marks for cleanup) a dedicated temp dir only when needed.
    func stageCombineInputs(
        videoPath: String,
        videoFilename: String,
        audioPath: String,
        audioFilename: String,
        tempBase: URL,
        hasRAMDisk: Bool
    ) async throws -> (video: URL, audio: URL, tempDir: URL?) {
        let videoIsNetwork = CombineVerifier.isNetworkPath(videoPath)
        let audioIsNetwork = CombineVerifier.isNetworkPath(audioPath)
        guard videoIsNetwork || audioIsNetwork else {
            return (URL(fileURLWithPath: videoPath), URL(fileURLWithPath: audioPath), nil)
        }
        let tempDir = tempBase.appendingPathComponent("VS_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        var localVideo = URL(fileURLWithPath: videoPath)
        var localAudio = URL(fileURLWithPath: audioPath)
        if videoIsNetwork {
            localVideo = try await bufferCombineSource(
                kind: "video", from: videoPath,
                to: tempDir.appendingPathComponent(videoFilename),
                hasRAMDisk: hasRAMDisk
            )
        }
        if audioIsNetwork {
            localAudio = try await bufferCombineSource(
                kind: "audio", from: audioPath,
                to: tempDir.appendingPathComponent(audioFilename),
                hasRAMDisk: hasRAMDisk
            )
        }
        return (localVideo, localAudio, tempDir)
    }

    /// Process one video/audio pair end-to-end: skip-if-exists, pause-gate,
    /// stage inputs, mux, clean up. Returns true on success.
    func processCombinePair(
        video: VideoRecord,
        audio: VideoRecord,
        outputFolder: URL,
        tempBase: URL,
        hasRAMDisk: Bool,
        jobIndex: Int
    ) async -> Bool {
        if Task.isCancelled { return false }
        await combinePauseGate.waitIfPaused()
        await waitForJobPause(jobIndex)
        if Task.isCancelled { return false }

        let videoPath = video.fullPath
        let audioPath = audio.fullPath
        let videoFilename = video.filename
        let audioFilename = audio.filename
        let baseName = URL(fileURLWithPath: videoPath).deletingPathExtension().lastPathComponent
        let outName = "\(baseName)_combined.mov"
        let outURL = outputFolder.appendingPathComponent(outName)

        // Skip offline files (VolumeReachability avoids blocking on network timeouts)
        if !VolumeReachability.isReachable(path: videoPath) || !VolumeReachability.isReachable(path: audioPath) {
            await MainActor.run {
                self.dashboard.combineCompleted += 1
                self.dashboard.combineFailed += 1
                self.updateJobPhase(jobIndex, .failed)
                self.log("  [\(self.dashboard.combineCompleted)/\(self.dashboard.combineTotal)] \(outName) — media offline, skipping")
            }
            return false
        }

        // Skip if already completed (resume after pause)
        let fm = FileManager.default
        if fm.fileExists(atPath: outURL.path) {
            await MainActor.run {
                self.dashboard.combineCompleted += 1
                self.dashboard.combineSkipped += 1
                self.updateJobPhase(jobIndex, .skipped)
                self.log("  [\(self.dashboard.combineCompleted)/\(self.dashboard.combineTotal)] \(outName) — already exists, skipping")
            }
            return true
        }

        let technique = await resolveCombineTechnique(video: video, audio: audio, jobIndex: jobIndex)

        await MainActor.run {
            self.dashboard.combineCurrentFile = outName
            self.updateJobPhase(jobIndex, .buffering)
            self.log("  [\(self.dashboard.combineCompleted + 1)/\(self.dashboard.combineTotal)] \(outName) (\(technique.rawValue))")
            self.log("    Video: \(videoPath)")
            self.log("    Audio: \(audioPath)")
        }

        let staged: (video: URL, audio: URL, tempDir: URL?)
        do {
            staged = try await stageCombineInputs(
                videoPath: videoPath, videoFilename: videoFilename,
                audioPath: audioPath, audioFilename: audioFilename,
                tempBase: tempBase, hasRAMDisk: hasRAMDisk
            )
        } catch {
            await MainActor.run {
                self.log("    ERROR buffering: \(error.localizedDescription)")
                self.dashboard.combineCompleted += 1
                self.dashboard.combineFailed += 1
                self.updateJobPhase(jobIndex, .failed)
            }
            return false
        }

        return await runMuxAndVerify(
            staged: staged, outURL: outURL, outName: outName,
            technique: technique, video: video, audio: audio, jobIndex: jobIndex
        )
    }

    private func runMuxAndVerify(
        staged: (video: URL, audio: URL, tempDir: URL?),
        outURL: URL, outName: String,
        technique: CombineJobStatus.CombineTechnique,
        video: VideoRecord, audio: VideoRecord,
        jobIndex: Int
    ) async -> Bool {
        await MainActor.run { self.updateJobPhase(jobIndex, .muxing) }

        let duration = await MainActor.run {
            guard jobIndex < self.dashboard.combineJobs.count else { return 0.0 }
            return self.dashboard.combineJobs[jobIndex].totalDurationSeconds
        }

        let logFn: @Sendable (String) -> Void = { [weak self] msg in
            DispatchQueue.main.async { self?.log(msg) }
        }
        let jobIdx = jobIndex
        let progressFn: @Sendable (Double) -> Void = { [weak self] frac in
            DispatchQueue.main.async {
                guard let self, jobIdx < self.dashboard.combineJobs.count else { return }
                self.dashboard.combineJobs[jobIdx].progressFraction = frac
            }
        }

        let result = await CombineEngine.runFFMpeg(
            videoPath: staged.video.path,
            audioPath: staged.audio.path,
            outputPath: outURL.path,
            technique: technique,
            durationSeconds: duration,
            onProgress: progressFn,
            log: logFn
        )

        if let tempDir = staged.tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        if !result.success {
            try? FileManager.default.removeItem(at: outURL)
            log("ffmpeg exit code \(result.exitCode)")
            await MainActor.run {
                self.dashboard.combineCompleted += 1
                self.dashboard.combineFailed += 1
                self.updateJobPhase(jobIndex, .failed)
                self.log("    ✗ FAILED: \(outName)")
            }
            return false
        }

        await MainActor.run {
            self.updateJobPhase(jobIndex, .verifying)
            self.log("    Verifying output…")
        }
        let verified = await CombineVerifier.verifyCombineOutput(
            url: outURL, expectedDuration: duration,
            ffprobePath: ffprobePath, ffmpegPath: CombineEngine.ffmpegPath
        )
        if !verified.ok {
            try? FileManager.default.removeItem(at: outURL)
            await MainActor.run {
                self.dashboard.combineCompleted += 1
                self.dashboard.combineFailed += 1
                self.updateJobPhase(jobIndex, .failed)
                self.log("    ✗ VERIFY FAILED: \(outName) — \(verified.reason)")
            }
            return false
        }

        let combinedRecord = await buildCombinedRecord(
            outputURL: outURL, video: video, audio: audio, summary: verified.summary
        )
        await MainActor.run {
            self.dashboard.combineCompleted += 1
            self.dashboard.combineSucceeded += 1
            self.updateJobPhase(jobIndex, .done)
            if jobIndex < self.dashboard.combineJobs.count {
                self.dashboard.combineJobs[jobIndex].progressFraction = 1.0
                if let warning = verified.warning {
                    self.dashboard.combineJobs[jobIndex].warningMessage = warning
                    self.log("    ⚠ \(warning)")
                }
            }
            self.log("    ✓ Verified: \(outURL.path) (\(verified.summary))")
            if let rec = combinedRecord {
                self.records.append(rec)
                self.log("    → Added to catalog for Archive")
            }
        }
        return true
    }

    @MainActor
    func updateJobPhase(_ index: Int, _ phase: CombineJobStatus.CombinePhase) {
        guard index < dashboard.combineJobs.count else { return }
        if phase == .buffering || phase == .muxing {
            dashboard.combineJobs[index].startTime = dashboard.combineJobs[index].startTime ?? Date()
        }
        if phase == .done || phase == .failed || phase == .skipped {
            dashboard.combineJobs[index].endTime = Date()
        }
        dashboard.combineJobs[index].phase = phase
    }

    private func resolveCombineTechnique(video: VideoRecord, audio: VideoRecord, jobIndex: Int) async -> CombineJobStatus.CombineTechnique {
        var technique = await MainActor.run {
            guard jobIndex < self.dashboard.combineJobs.count else { return CombineJobStatus.CombineTechnique.streamCopy }
            return self.dashboard.combineJobs[jobIndex].technique
        }

        if technique == .streamCopy {
            let check = CombineEngine.checkStreamCopyCompatibility(
                videoCodec: video.videoCodec.isEmpty ? nil : video.videoCodec,
                audioCodec: audio.audioCodec.isEmpty ? nil : audio.audioCodec
            )
            if !check.streamCopySafe {
                technique = .reencodeProRes
                await MainActor.run {
                    if jobIndex < self.dashboard.combineJobs.count {
                        self.dashboard.combineJobs[jobIndex].technique = technique
                        self.dashboard.combineJobs[jobIndex].warningMessage = check.warning
                    }
                    self.log("    ⚠ \(check.warning ?? "Codec incompatible") — auto-switching to ProRes re-encode")
                }
            }
        }
        return technique
    }

    @MainActor
    func toggleJobPause(_ index: Int) {
        guard index < dashboard.combineJobs.count else { return }
        dashboard.combineJobs[index].isPaused.toggle()
    }

    /// Build a catalog record for a successfully combined output file.
    /// Inherits the star rating from the source pair and links back via combinedFromPairID.
    nonisolated func buildCombinedRecord(
        outputURL: URL, video: VideoRecord, audio: VideoRecord, summary: String
    ) async -> VideoRecord? {
        let (probe, _) = await CombineVerifier.runFFProbe(url: outputURL, ffprobePath: ffprobePath)
        guard let probe else { return nil }
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: outputURL.path)

        let rec = VideoRecord()
        rec.filename = outputURL.lastPathComponent
        rec.ext = outputURL.pathExtension.lowercased()
        rec.fullPath = outputURL.path
        rec.directory = outputURL.deletingLastPathComponent().path
        rec.container = probe.format?.format_name ?? "mov"
        rec.streamTypeRaw = StreamType.videoAndAudio.rawValue

        let bytes = (attrs?[.size] as? Int64) ?? Int64(probe.format?.size ?? "0") ?? 0
        rec.sizeBytes = bytes
        rec.size = Formatting.humanSize(bytes)

        let dur = Double(probe.format?.duration ?? "0") ?? 0
        rec.durationSeconds = dur
        rec.duration = Formatting.duration(dur)

        let streams = probe.streams ?? []
        if let vs = streams.first(where: { $0.codec_type == "video" }) {
            rec.videoCodec = vs.codec_name ?? ""
            if let w = vs.width, let h = vs.height { rec.resolution = "\(w)x\(h)" } else { rec.resolution = "" }
            rec.frameRate = vs.r_frame_rate ?? ""
            rec.videoBitrate = vs.bit_rate ?? ""
            rec.colorSpace = vs.color_space ?? ""
            rec.bitDepth = vs.bits_per_raw_sample ?? ""
            rec.scanType = vs.field_order ?? ""
        }
        if let as_ = streams.first(where: { $0.codec_type == "audio" }) {
            rec.audioCodec = as_.codec_name ?? ""
            rec.audioChannels = as_.channels.map(String.init) ?? ""
            rec.audioSampleRate = as_.sample_rate ?? ""
        }

        rec.totalBitrate = probe.format?.bit_rate ?? ""
        rec.isPlayable = "Yes"
        rec.notes = "Combined: \(summary)"

        let dateFmt = ISO8601DateFormatter()
        dateFmt.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        if let created = attrs?[.creationDate] as? Date {
            rec.dateCreatedRaw = created
            rec.dateCreated = dateFmt.string(from: created)
        }
        if let modified = attrs?[.modificationDate] as? Date {
            rec.dateModifiedRaw = modified
            rec.dateModified = dateFmt.string(from: modified)
        }

        rec.mediaDisposition = .unreviewed
        rec.archiveStage = .none
        rec.starRating = max(video.starRating, audio.starRating)
        rec.combinedFromPairID = video.pairGroupID

        return rec
    }

    func waitForJobPause(_ index: Int) async {
        while await MainActor.run(body: {
            index < dashboard.combineJobs.count && dashboard.combineJobs[index].isPaused
        }) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
        }
    }

    /// Emit the Combine Complete banner and clear the combine UI state.
    /// Only marks isCombining = false when all jobs (including appended ones) are done.
    @MainActor
    func logCombineSummary() {
        let allDone = dashboard.combineCompleted >= dashboard.combineTotal
        guard allDone else { return }
        self.log("""

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          Combine Complete
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          Succeeded: \(dashboard.combineSucceeded)
          Skipped:   \(dashboard.combineSkipped)
          Failed:    \(dashboard.combineFailed)
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        """)
        isCombining = false
        dashboard.combineCurrentFile = ""
    }

    func combineAllPairsInternal(pairs: [(video: VideoRecord, audio: VideoRecord)], outputFolder: URL, technique: CombineJobStatus.CombineTechnique = .streamCopy, maxConcurrency: Int? = nil) {
        let appending = isCombining

        let filteredPairs: [(video: VideoRecord, audio: VideoRecord)]
        if appending {
            let activeOutputs = Set(dashboard.combineJobs
                .filter { $0.phase != .done && $0.phase != .failed && $0.phase != .skipped }
                .map { $0.outputFilename })
            filteredPairs = pairs.filter { pair in
                let baseName = URL(fileURLWithPath: pair.video.fullPath).deletingPathExtension().lastPathComponent
                let outName = "\(baseName)_combined.mov"
                if activeOutputs.contains(outName) {
                    log("  ⚠ \(outName) already in progress, skipping")
                    return false
                }
                return true
            }
            guard !filteredPairs.isEmpty else {
                log("All selected pairs are already in progress.")
                return
            }
        } else {
            filteredPairs = pairs
        }

        let jobOffset = dashboard.combineJobs.count

        if appending {
            dashboard.combineTotal += filteredPairs.count
        } else {
            isCombining = true
            dashboard.resetForCombine(total: filteredPairs.count)
        }

        let fm = FileManager.default
        for (i, pair) in filteredPairs.enumerated() {
            let baseName = URL(fileURLWithPath: pair.video.fullPath).deletingPathExtension().lastPathComponent
            let outName = "\(baseName)_combined.mov"
            dashboard.combineJobs.append(CombineJobStatus(
                pairIndex: jobOffset + i,
                videoFilename: pair.video.filename,
                audioFilename: pair.audio.filename,
                outputFilename: outName,
                outputPath: outputFolder.appendingPathComponent(outName).path,
                videoSizeBytes: pair.video.sizeBytes,
                audioSizeBytes: pair.audio.sizeBytes,
                totalDurationSeconds: max(pair.video.durationSeconds, pair.audio.durationSeconds),
                videoOnline: VolumeReachability.isReachable(path: pair.video.fullPath),
                audioOnline: VolumeReachability.isReachable(path: pair.audio.fullPath),
                technique: technique
            ))
        }

        log("""

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          \(appending ? "Adding" : "Combining") \(filteredPairs.count) pair\(filteredPairs.count == 1 ? "" : "s") → \(outputFolder.path)
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        """)

        let newTask = Task {
            let (tempBase, hasRAMDisk) = await mountCombineRAMDisk()
            let semaphore = AsyncSemaphore(limit: maxConcurrency ?? self.perfSettings.combineConcurrency)

            await withTaskGroup(of: Bool.self) { group in
                for (i, (video, audio)) in filteredPairs.enumerated() {
                    if Task.isCancelled { break }
                    let jobIndex = jobOffset + i
                    group.addTask { [self] in
                        await semaphore.withPermit {
                            await self.processCombinePair(
                                video: video, audio: audio,
                                outputFolder: outputFolder,
                                tempBase: tempBase, hasRAMDisk: hasRAMDisk,
                                jobIndex: jobIndex
                            )
                        }
                    }
                }

                for await _ in group {
                    // Succeeded/failed/skipped counters are updated inside processCombinePair
                }

                await self.ramDisk.unmount()
                await self.logCombineSummary()
            }
        }

        if !appending {
            combineTask = newTask
        }
    }

    func pauseCombine() {
        isCombinePaused = true
        Task { await combinePauseGate.pause() }
        log("--- Combine paused ---")
    }

    func resumeCombine() {
        isCombinePaused = false
        Task { await combinePauseGate.resume() }
        log("--- Combine resumed ---")
    }

    func stopCombine() {
        combineTask?.cancel()
        combineTask = nil
        Task {
            await combinePauseGate.resume()  // release any waiters before cancel
            await ramDisk.unmount()
        }
        log("--- Combine stopped by user ---")
        isCombining = false
        isCombinePaused = false
        dashboard.combineCurrentFile = ""
    }
}
