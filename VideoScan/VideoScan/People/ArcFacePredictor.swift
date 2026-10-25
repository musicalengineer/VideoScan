// ArcFacePredictor.swift
// EXPERIMENTAL concurrency control for ArcFace CoreML inference (P0-1).
//
// Background: every ArcFace prediction has historically run under a single
// process-wide lock (`arcfacePredictionLock`) against the caller's per-video
// MLModel. That serialization is what guards the reproduced MLE5
// `BindEmptyMemoryObjectToPort` crash (2026-05-12) — but it also caps ArcFace
// throughput at one prediction at a time, no matter how many videos scan in
// parallel.
//
// This type makes the concurrency a tunable. The DEFAULT (K <= 1) is unchanged:
// `borrow(fallback:)` returns the caller's per-video model and the global lock,
// so behavior is byte-for-byte the original serialized path. When K > 1 (opt-in
// via PersonFinderSettings.arcfaceInferenceConcurrency), it returns one of K
// distinct, individually-locked MLModel instances, allowing up to K predictions
// to run concurrently. Each slot's own lock guarantees a single instance is
// never touched by two threads at once — Apple's documented-safe condition for
// MLModel — so this fans out across instances rather than sharing one.
//
// Raising K re-enables the cross-instance concurrency that historically tripped
// MLE5, so it is OFF by default and backed by the P0-2 retry + ObjC-exception
// firewall in arcfaceEmbedding. Validate with scripts/run_arcface_super_stress.sh
// and run_arcface_parallel_repro.sh before raising K in production use.

import Foundation
import CoreML
import os

/// Swift 6: `Sendable` because the pool is the class's only mutable state and
/// the lock owns it (`OSAllocatedUnfairLock<Pool>`); `shared` is then a plain
/// `static let` the checker accepts.
final class ArcFacePredictor: Sendable {
    static let shared = ArcFacePredictor()
    private init() {}

    /// The K model instances and the round-robin cursor. `MLModel` has no
    /// Sendable conformance in this SDK, hence `uncheckedState`: a slot's
    /// model is only ever used under that slot's own lock (Apple's
    /// documented-safe condition for MLModel), and the array itself only
    /// under `pool`. Memory: K MLModel instances (~90 MB each for ArcFace),
    /// K ≤ processorCount, and 0 in the default serialized mode.
    private struct Pool {
        var slots: [(model: MLModel, lock: OSAllocatedUnfairLock<Void>)] = []
        var configuredK = 1
        var nextSlot = 0
    }
    private let pool = OSAllocatedUnfairLock(uncheckedState: Pool())

    /// Number of inference slots currently configured (1 == serialized).
    var concurrency: Int { pool.withLock { $0.configuredK } }

    /// Idempotent. Reshapes the shared pool to match `k`, clamped to
    /// [1, processorCount]. k <= 1 tears the pool down (serialized mode); k > 1
    /// builds K fresh model instances. Safe to call once per video — the fast
    /// path returns immediately when already configured for the requested K.
    func configure(concurrency k: Int) async {
        let want = max(1, min(k, ProcessInfo.processInfo.processorCount))

        let needsBuild: Bool = pool.withLock { p in
            let expectedSlots = want > 1 ? want : 0
            return !(want == p.configuredK && p.slots.count == expectedSlots)
        }
        guard needsBuild else { return }

        if want <= 1 {
            pool.withLock { p in p.slots = []; p.configuredK = 1; p.nextSlot = 0 }
            return
        }

        // Build K fresh instances up front (async via the loader), then install
        // under the lock. Two videos racing the first build may each construct a
        // set; the loser's set is simply discarded — wasteful once, never wrong.
        var built: [(model: MLModel, lock: OSAllocatedUnfairLock<Void>)] = []
        for _ in 0..<want {
            let (m, _) = await ArcFaceModelLoader.shared.getModel()
            if let m { built.append((model: m, lock: OSAllocatedUnfairLock())) }
        }
        guard built.count == want else { return }   // partial build → stay serialized
        let completedBuild = built

        // withLockUnchecked: the closure carries MLModel instances (not
        // Sendable in this SDK) into the lock; see `Pool`.
        pool.withLockUnchecked { p in
            p.slots = completedBuild
            p.configuredK = want
            p.nextSlot = 0
        }
    }

    /// Returns the (model, lock) for one prediction attempt. In serialized mode
    /// (empty pool) returns the caller's `fallback` model and the global lock —
    /// identical to the original behavior. In pooled mode, round-robins a slot;
    /// the slot's own lock still serializes any two callers that land on it, so
    /// a single instance is never used concurrently.
    func borrow(fallback: MLModel) -> (model: MLModel, lock: OSAllocatedUnfairLock<Void>) {
        // withLockUnchecked: returns an MLModel (not Sendable in this SDK).
        pool.withLockUnchecked { p in
            guard !p.slots.isEmpty else { return (model: fallback, lock: arcfacePredictionLock) }
            let s = p.slots[p.nextSlot % p.slots.count]
            p.nextSlot = (p.nextSlot &+ 1) % p.slots.count
            return s
        }
    }
}
