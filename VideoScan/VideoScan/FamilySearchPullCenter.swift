// FamilySearchPullCenter.swift
// App-wide owner of an in-flight "Get Family Tree" download.
//
// Why this exists (2026-08-25): the coordinator used to live in the Family
// Tree tab's `@State`. Closing the sheet nil'd it, which cancelled the
// file-watch Task — so a two-hour Terminal pull finished into a file nobody
// was watching. The center keeps the coordinator alive until the pull has
// settled (installed, or the user explicitly forgets it), and mirrors its
// phase into a small `Status` the tab bar and sidebar can render.
//
// The coordinator itself is unchanged and still fully injectable; the
// center is just the lifetime owner plus a status projection.

import Combine
import Foundation
import UserNotifications

// `@MainActor` ≈ "this must run on the UI thread". `ObservableObject` +
// `@Published` ≈ a subject whose setters notify SwiftUI observers.
@MainActor
final class FamilySearchPullCenter: ObservableObject {
    static let shared = FamilySearchPullCenter()

    /// What the rest of the app needs to know — deliberately coarser than
    /// the coordinator's `Phase` so views don't switch over URLs/summaries.
    enum Status: Equatable {
        case none
        case downloading(since: Date)
        case readyToInstall
        case failed
    }

    @Published private(set) var coordinator: FamilySearchPullCoordinator?
    @Published private(set) var status: Status = .none

    /// Builds a coordinator for a GEDCOM directory. Injected so tests can
    /// hand in silent launchers / fast poll intervals / temp directories.
    private let makeCoordinator: @MainActor (URL) -> FamilySearchPullCoordinator
    /// Delivers the completion notification (title, body). Injected so
    /// tests can capture it instead of touching UNUserNotificationCenter.
    private let notify: (String, String) -> Void
    // `AnyCancellable` ≈ an RAII subscription token: dropping it unsubscribes.
    private var phaseSubscription: AnyCancellable?

    init(
        makeCoordinator: @escaping @MainActor (URL) -> FamilySearchPullCoordinator = {
            FamilySearchPullCoordinator(gedcomDirectory: $0)
        },
        notify: @escaping (String, String) -> Void = FamilySearchPullCenter.postNotification
    ) {
        self.makeCoordinator = makeCoordinator
        self.notify = notify
    }

    // MARK: Lifetime

    /// The coordinator to show in the sheet. If a pull is in flight (or has
    /// finished and is waiting for the Install/Replace decision, or failed
    /// and hasn't been read yet) the SAME coordinator comes back so the
    /// sheet reopens onto it. Only a settled one (idle/installed) is
    /// replaced — and then against the directory the tab resolved *now*.
    @discardableResult
    func begin(gedcomDirectory: URL) -> FamilySearchPullCoordinator {
        if let existing = coordinator, !Self.isSettled(existing.phase) {
            return existing
        }
        let fresh = makeCoordinator(gedcomDirectory)
        adopt(fresh)
        return fresh
    }

    /// Sheet-dismiss path. Leaves an in-flight or decision-pending
    /// coordinator alone (that is the whole point); drops one that has
    /// nothing left to do.
    func dismissIfSettled() {
        guard let coordinator, Self.isSettled(coordinator.phase) else { return }
        clear()
    }

    /// "Forget this download": stop watching and drop the coordinator. The
    /// Terminal process is not ours to kill; it keeps running.
    func forget() {
        coordinator?.cancel()
        clear()
    }

    private static func isSettled(_ phase: FamilySearchPullCoordinator.Phase) -> Bool {
        switch phase {
        case .idle, .installed: return true
        case .waiting, .ready, .failed: return false
        }
    }

    private func adopt(_ coordinator: FamilySearchPullCoordinator) {
        self.coordinator = coordinator
        // `$phase` is the Combine publisher behind `@Published phase`. It
        // emits on willSet with the NEW value, so use the value passed in
        // rather than re-reading `coordinator.phase`.
        phaseSubscription = coordinator.$phase
            .sink { [weak self, weak coordinator] phase in
                guard let self, let coordinator else { return }
                self.mirror(phase, of: coordinator)
            }
    }

    private func clear() {
        phaseSubscription = nil
        coordinator = nil
        status = .none
    }

    // MARK: Status projection

    private func mirror(_ phase: FamilySearchPullCoordinator.Phase,
                        of coordinator: FamilySearchPullCoordinator) {
        let previous = status
        switch phase {
        case .idle, .installed:
            status = .none
        case .waiting:
            status = .downloading(since: coordinator.startedAt ?? Date())
        case .ready(_, let new, _, _):
            status = .readyToInstall
            if previous != .readyToInstall {
                notify(Self.notificationTitle,
                       Self.notificationBody(people: new.people, generations: new.generations))
            }
        case .failed:
            status = .failed
        }
    }

    // MARK: Notification

    /// Pure formatters, static so a test can pin the wording without
    /// UserNotifications in the loop (same shape as RelocateQueue's).
    nonisolated static let notificationTitle = "Family tree downloaded"

    nonisolated static func notificationBody(people: Int, generations: Int) -> String {
        "\(people) people, \(generations) generations — open the Family Tree tab to install."
    }

    /// Best-effort, mirrors VideoScanModel+RelocateQueue: check the existing
    /// authorization, never request it here, no sound (this may fire hours
    /// after the user walked away).
    nonisolated static func postNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = nil
            let request = UNNotificationRequest(
                identifier: "familysearch-pull.\(UUID().uuidString)",
                content: content,
                trigger: nil)
            center.add(request, withCompletionHandler: nil)
        }
    }
}
