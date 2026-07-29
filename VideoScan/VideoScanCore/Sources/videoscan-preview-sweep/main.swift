// videoscan-preview-sweep — out-of-process preview prewarmer (Stage 1)
//
// A standalone CLI the user launches by hand to warm the SAME on-disk
// preview cache the app reads (filmstrips + best stills), driving the SAME
// PreviewSweepEngine out-of-process. Stage 2 will wrap this executable in
// SMAppService — this task ships only the hand-launched tool.
//
// This file is deliberately THIN: all testable logic (arg parsing, the
// single-instance lock, catalog freshness, the engine wiring) lives in
// VideoScanCore so VideoScanCoreTests can exercise it without spawning a
// process. main.swift just parses argv, takes the single-instance lock, and
// runs.

import Foundation
import VideoScanCore

func writeStderr(_ s: String) {
    FileHandle.standardError.write(Data(s.utf8))
}

let args = Array(CommandLine.arguments.dropFirst())
let defaultCatalog = PreviewSweepCLIOptions.defaultCatalogURL()

switch PreviewSweepCLIOptions.parse(args, defaultCatalog: defaultCatalog) {
case .failure(let error):
    switch error {
    case .helpRequested:
        print(PreviewSweepCLIOptions.usage)
        exit(0)
    case .unknownFlag(let flag):
        writeStderr("error: unknown flag \(flag)\n\n")
        writeStderr(PreviewSweepCLIOptions.usage + "\n")
        exit(2)
    case .missingValue(let flag):
        writeStderr("error: \(flag) requires a value\n\n")
        writeStderr(PreviewSweepCLIOptions.usage + "\n")
        exit(2)
    case .badNumber(let flag, let value):
        writeStderr("error: \(flag) got a bad number '\(value)'\n\n")
        writeStderr(PreviewSweepCLIOptions.usage + "\n")
        exit(2)
    }

case .success(let options):
    // Single-instance lock: two helpers must never both run (they'd race the
    // same cache dir). The OS releases the advisory lock automatically if
    // this process dies, so a crash can't strand it.
    guard let instanceLock = SingleInstanceLock.acquire(at: SingleInstanceLock.defaultURL()) else {
        writeStderr("preview sweep helper: another instance is already running — exiting\n")
        exit(3)
    }
    defer { instanceLock.release() }

    let renderer = FFmpegPreviewRenderer()
    // ffmpeg preflight: a bare machine can't rip anything. Warn but still
    // run in --dry-run (planning needs no ffmpeg); refuse a real run.
    if !FFmpegLocator.ffmpegIsAvailable() && !options.dryRun {
        writeStderr("preview sweep helper: no executable ffmpeg found (looked in "
                    + FFmpegLocator.ffmpegCandidates.joined(separator: ", ")
                    + "; set VS_FFMPEG_PATH to override). Install with: brew install ffmpeg\n")
        exit(4)
    }

    let runner = PreviewSweepCLIRunner(
        options: options,
        cacheRootURL: options.cacheDirOverride ?? PreviewDiskCache.productionRootURL,
        renderer: renderer)
    await runner.run()
}
