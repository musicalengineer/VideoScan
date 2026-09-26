// NotificationObserverBagTests.swift
// Logic + model-level tests for NotificationObserverBag (fix/ci-red-5,
// CI run 36223041786): block observers must die with their owner.
//
// Each test uses its OWN NotificationCenter instance (never .default) for
// the logic cases, so no parallel test can deliver into — or be delivered
// from — these observers (isolation dimension).

import Foundation
import Testing
@testable import VideoScan

@Suite("NotificationObserverBag — observers die with their owner")
struct NotificationObserverBagTests {

    final class Hits: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private static let ping = Notification.Name("NotificationObserverBagTests.ping")

    /// Registers `count` synchronous (queue: nil) observers into a new bag.
    private func makeBag(on center: NotificationCenter, count: Int, hits: Hits) -> NotificationObserverBag {
        let bag = NotificationObserverBag()
        for _ in 0..<count {
            let token = center.addObserver(forName: Self.ping, object: nil, queue: nil) { _ in hits.bump() }
            bag.add(token, to: center)
        }
        return bag
    }

    @Test func releasingTheBagUnregistersEveryObserver() {
        let center = NotificationCenter()
        let hits = Hits()
        var bag: NotificationObserverBag? = makeBag(on: center, count: 3, hits: hits)
        #expect(bag?.count == 3)

        center.post(name: Self.ping, object: nil)
        #expect(hits.value == 3, "while the bag lives, every observer is delivered to")

        bag = nil                                   // the owner goes away
        center.post(name: Self.ping, object: nil)
        center.post(name: Self.ping, object: nil)
        #expect(hits.value == 3, "after the bag is released NO observer may run — got \(hits.value - 3) stray deliveries")
    }

    @Test func removeAllIsIdempotentAndTheBagStaysUsable() {
        let center = NotificationCenter()
        let hits = Hits()
        let bag = makeBag(on: center, count: 2, hits: hits)
        bag.removeAll()
        bag.removeAll()
        #expect(bag.isEmpty)
        center.post(name: Self.ping, object: nil)
        #expect(hits.value == 0)

        let token = center.addObserver(forName: Self.ping, object: nil, queue: nil) { _ in hits.bump() }
        bag.add(token, to: center)
        center.post(name: Self.ping, object: nil)
        #expect(hits.value == 1, "a bag emptied by removeAll must accept and deliver new registrations")
    }

    @Test func tokensAreRemovedFromTheCenterTheyCameFrom() {
        // NSWorkspace notifications live on NSWorkspace's own center; a
        // token removed from the wrong center stays registered. Two centers,
        // one bag: releasing it must silence both.
        let a = NotificationCenter(), b = NotificationCenter()
        let hits = Hits()
        var bag: NotificationObserverBag? = NotificationObserverBag()
        bag?.add(a.addObserver(forName: Self.ping, object: nil, queue: nil) { _ in hits.bump() }, to: a)
        bag?.add(b.addObserver(forName: Self.ping, object: nil, queue: nil) { _ in hits.bump() }, to: b)
        bag = nil
        a.post(name: Self.ping, object: nil)
        b.post(name: Self.ping, object: nil)
        #expect(hits.value == 0)
    }

    /// Model level: a VideoScanModel owns all 8 of its registrations in the
    /// bag, and the bag — hence every registration — goes away with the
    /// model. Before the fix the 8 tokens were never removed, so every model
    /// a test run built kept reacting to notifications forever.
    @Test(.timeLimit(.minutes(1))) @MainActor
    func aReleasedVideoScanModelTakesItsEightObserversWithIt() async throws {
        weak var weakModel: VideoScanModel?
        weak var weakBag: NotificationObserverBag?
        do {
            let model = VideoScanModel()
            weakModel = model
            weakBag = model.notificationObservers
            #expect(model.notificationObservers.count == 8,
                    "VideoScanModel registers 8 block observers (2 lifecycle, 3 volume, 3 archive snapshot); the bag owns \(model.notificationObservers.count)")
        }
        // init() starts background work that may hold the model briefly;
        // give it bounded time to finish, then require the release.
        let deadline = ContinuousClock.now + .seconds(20)
        while weakBag != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(weakModel == nil, "the model was never released — something still retains it, so its observers would live on")
        #expect(weakBag == nil, "the observer bag outlived its model — its registrations were not removed")
    }
}
