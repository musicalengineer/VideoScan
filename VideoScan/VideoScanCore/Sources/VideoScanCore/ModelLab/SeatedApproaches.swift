// SeatedApproaches.swift (VideoScanCore/ModelLab)
// ONE SENTENCE: the approaches that have earned a seat (a Judge verdict in
// docs/reviews/video_llm_benchmarks.md and a DECISIONS line), as the pure
// descriptors the jobs and the payload gate read.
//
// `eraA2` — DECISIONS 2026-10-31 "Background service step 1 is the 8B
// era/OCR job": Qwen3-VL-8B-Instruct 4-bit through bench.py's A2 paths
// (era windows 3 × N = 8, ≤ 60 s, the r3 contract; A0's `date` prompt on 5
// stills), hosted by the Python worker on THIS Mac, pixels only. The id and
// revision here are what the job EXPECTS; every `by` it writes comes from
// the worker's own load reply (PythonClipWorker.LoadInfo).
//
// Memory: one descriptor (tens of bytes).

import Foundation

public enum SeatedApproach {
    public static let eraA2ID = ApproachID(model: "qwen3-vl-8b-4bit", promptFamily: "era-v1", sampler: "window-60s")!

    public static let eraA2 = ApproachDescriptor(
        id: eraA2ID, revision: 3,
        host: .pythonWorker(venv: "venv-mlx", script: "tools/video-llm-bench/bench.py"),
        accepts: [.pixels], emits: [.era, .ocrDate],
        resources: ResourceProfile(peakRAMGB: 8, needsResidentModel: true, expectedSecondsPerWindowUltra: 2.3,
                                   weightsLocation: "mlx-community/Qwen3-VL-8B-Instruct-4bit"),
        promptHash: "bench.py A1_ERA_PROMPT r3 + PROMPTS[date] (hashes in the worker's load reply)")
}
