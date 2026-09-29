import Foundation

/// #567: the guards of one turn (front door, pre-translation, general
/// verdict, context capture) each asked for People and CyberBrain, so a
/// first question naming someone read both from disk twice or more. The
/// graph already has a per-process cache; these two are read once per
/// turn instead — fresh on the next turn, so a People-tab edit between
/// questions is seen — and any write Hallie makes during the turn drops
/// the memo, so she never answers from a read older than her own write.
extension HallieAppTurnCoordinator.Dependencies {
    func readingIdentitySourcesOncePerTurn() -> Self {
        let profiles = TurnMemo(loadProfiles)
        let cyberBrain = TurnMemo(loadCyberBrain)
        let forget: @Sendable () -> Void = {
            profiles.forget()
            cyberBrain.forget()
        }
        let recordTestimony = self.recordTestimony
        let recordPhotoCaption = self.recordPhotoCaption
        let recordPronunciation = self.recordPronunciation
        var turn = self
        turn.loadProfiles = { profiles.value() }
        turn.loadCyberBrain = { cyberBrain.value() }
        turn.recordTestimony = { defer { forget() }; try recordTestimony($0) }
        turn.recordPhotoCaption = { defer { forget() }; try recordPhotoCaption($0) }
        turn.recordPronunciation = { defer { forget() }; try recordPronunciation($0) }
        return turn
    }
}

/// A load run at most once until `forget()`; nil is remembered too
/// ("no CyberBrain" is an answer, not a reason to look again). The load
/// runs under the lock, so concurrent guards wait for the one read rather
/// than starting their own.
final class TurnMemo<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let load: @Sendable () -> Value
    private var stored: Value?
    private var loaded = false

    init(_ load: @escaping @Sendable () -> Value) { self.load = load }

    func value() -> Value {
        lock.withLock {
            if loaded, let stored { return stored }
            let fresh = load()
            stored = fresh
            loaded = true
            return fresh
        }
    }

    func forget() {
        lock.withLock {
            stored = nil
            loaded = false
        }
    }
}
