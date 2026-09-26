// NotificationObserverBag.swift
// Owns block-based NotificationCenter registrations and removes every one
// of them when the bag is released.
//
// WHY THIS EXISTS (fix/ci-red-5, CI run 36223041786). NotificationCenter
// RETAINS a block observer — `addObserver(forName:object:queue:using:)` —
// until someone calls `removeObserver(token)`. Only the old selector-based
// observers auto-unregister when their target dies. VideoScanModel
// registered 8 block observers per instance and never removed any, so each
// model ever created (716 construction sites in the unit tests) left 8
// closures behind for the life of the process. `[weak self]` kept the
// dead model from being called, but the closure still RAN: the
// reachability observer spawned a `Task { @MainActor … }` per delivery
// whether or not `self` was still alive. A 100k-record test produced ~99k
// reachability posts; each fanned out to every dead model's observer, and
// the CI host reached a 42.98 GB footprint on a 7 GB VM before macOS
// suspended it (XCTest spindump in the run's result bundle).
//
// C++ analogy: an RAII guard — like a vector of unique_ptrs whose deleter
// is `center.removeObserver(token)`. The owner holds the bag as a `let`,
// so the owner's destruction destroys the bag, and the bag's deinit
// unregisters everything. No owner code has to remember to call anything.
//
// Thread safety: `NotificationCenter.removeObserver` is thread-safe, and
// the owner's deinit may run on any thread (a @MainActor class's deinit is
// nonisolated), so the token list is guarded by a plain lock and the bag
// is `@unchecked Sendable`.

import Foundation

final class NotificationObserverBag: @unchecked Sendable {

    private struct Registration {
        let center: NotificationCenter
        let token: any NSObjectProtocol
    }

    private let lock = NSLock()
    private var registrations: [Registration] = []

    init() {}

    /// Keep `token` (the value `center.addObserver(forName:…)` returned)
    /// and remove it from `center` when this bag is released. Pass the
    /// SAME center the token came from: NSWorkspace notifications live on
    /// `NSWorkspace.shared.notificationCenter`, not `.default`.
    func add(_ token: any NSObjectProtocol, to center: NotificationCenter) {
        lock.lock()
        registrations.append(Registration(center: center, token: token))
        lock.unlock()
    }

    /// How many registrations the bag currently owns (tests / sensors).
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return registrations.count
    }

    /// Unregister everything now. Idempotent; the bag stays usable.
    func removeAll() {
        lock.lock()
        let owned = registrations
        registrations.removeAll()
        lock.unlock()
        // Outside the lock: removeObserver takes NotificationCenter's own
        // lock, and a lock is never held across a call into another
        // subsystem's locking.
        for registration in owned {
            registration.center.removeObserver(registration.token)
        }
    }

    deinit {
        removeAll()
    }
}
