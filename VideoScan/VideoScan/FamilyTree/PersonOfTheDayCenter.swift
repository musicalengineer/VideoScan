// PersonOfTheDayCenter.swift
// The app side of PERSON OF THE DAY (Rick 2026-10-01). The choice itself is
// Core's (`PersonOfTheDay` + `PersonOfTheDayService`, pure and tested);
// this object gathers the tree's facts off the main actor, asks the
// service, and publishes the pick for the Family Tree tab's card.
//
// WHEN: the card asks (`refresh`) whenever one of its inputs changes — the
// installed tree, the walk's decorations, the family's notes, or the day.
// A burst of changes after launch (tree → notes → decorations, a few
// seconds apart) is DEBOUNCED into one computation (`debounce`, 3 s), so
// the day's pick is made with the line / relation / notes facts in hand
// rather than from the bare tree. Once made, the pick is recorded and is
// stable for the rest of the day (Core's history), whatever reloads later.
//
// STORE: App Support/VideoScan/family-tree/person-of-the-day.json
// (PersonOfTheDayFileStore). In the TEST HOST an in-memory store, so a
// synthetic tree never rotates Rick's real history (the settings-pollution
// class) — tests inject their own service anyway.
//
// FOR HALLIE (later; another agent owns Hallie): `PersonOfTheDayCenter
// .shared.pick` is today's person, `opener` the sentence. Hallie should
// read these rather than pick again; the service is deterministic, so a
// second pick over the same inputs would agree anyway.
//
// LOGGING: one line to videoscan.log per new pick — the person's GEDCOM id
// and the reason, never a name (the pick may be a living inner-circle
// person on their birthday).
//
// (For Rick: `@MainActor final class … ObservableObject` ≈ a UI-thread
// object whose `@Published` members notify views; the work runs in a
// `Task.detached` ≈ std::async on a worker. The `generation` counter is
// the usual "ignore a stale reply" sequence number.)

import Combine
import Foundation
import VideoScanCore

@MainActor
final class PersonOfTheDayCenter: ObservableObject {

    static let shared = PersonOfTheDayCenter()

    @Published private(set) var pick: PersonOfTheDay.Pick?
    /// The inputs key of the last computation (tests read it).
    private(set) var computedKey: String?

    /// Injected by tests; production: the App Support file store.
    var service: PersonOfTheDayService
    /// Quiet time after the last input change. Tests shorten it.
    var debounce: Duration = .seconds(3)
    /// Where the portrait hints come from (nil in the test host).
    var assetConfiguration: () -> FamilyAssetConfiguration? = {
        TestEnvironment.isTestHost ? nil : FamilyAssetConfigurationCenter.shared.snapshot()
    }

    private var task: Task<Void, Never>?
    private var pendingKey: String?
    private var generation = 0

    init(service: PersonOfTheDayService? = nil) {
        if let service {
            self.service = service
        } else if TestEnvironment.isTestHost {
            self.service = PersonOfTheDayService(store: PersonOfTheDayMemoryStore())
        } else if let url = PersonOfTheDayFileStore.defaultURL() {
            self.service = PersonOfTheDayService(store: PersonOfTheDayFileStore(url: url))
        } else {
            self.service = PersonOfTheDayService(store: PersonOfTheDayMemoryStore())
        }
    }

    /// Hallie's opener for today ("Today's person is …"), or nil.
    var opener: String? { pick.map(PersonOfTheDay.opener(for:)) }

    /// The inputs that decide the pick, as one string — cheap (no
    /// O(people) work): graph identity, decorations key, notes present,
    /// today's date.
    static func inputsKey(graph: GedcomFamilyGraph?, decorationsKey: String?, hasNotes: Bool, day: String) -> String {
        guard let graph else { return "none|\(day)" }
        return [FamilyTreeWalkCenter.identity(of: graph), decorationsKey ?? "-", hasNotes ? "notes" : "-", day]
            .joined(separator: "|")
    }

    /// Ask for today's pick over these inputs. A repeat of the inputs
    /// already computed (or pending) is a no-op.
    func refresh(graph: GedcomFamilyGraph?, decorations: TreeWalkStored?, knowledge: FamilyTreeNotesResolver?,
                 displayNames: [String], ownerFamilySearchID: String?) {
        let day = service.today.key
        let key = Self.inputsKey(graph: graph, decorationsKey: decorations?.sourceKey,
                                 hasNotes: knowledge != nil, day: day)
        guard key != computedKey, key != pendingKey else { return }
        task?.cancel()
        pendingKey = key
        guard let graph else {
            task = nil
            pendingKey = nil
            computedKey = key
            pick = nil
            return
        }
        generation &+= 1
        let mine = generation
        let debounce = debounce
        let service = service
        let configuration = assetConfiguration()
        let starts = decorations?.starts.map(\.id)
            ?? FamilyTreeWalkCenter.defaultStarts(in: graph, ownerFamilySearchID: ownerFamilySearchID)
        let people = decorations?.people ?? [:]
        task = Task { [weak self] in
            do { try await Task.sleep(for: debounce) } catch { return }   // superseded
            let chosen = await Task.detached(priority: .utility) { () -> PersonOfTheDay.Pick? in
                let hints = configuration?.makeStore().portraitHints() ?? .none
                let context = FamilyTreeFeatureContext(graph: graph, decorations: people, displayNames: displayNames,
                                                       knowledge: knowledge, hints: hints, starts: starts,
                                                       now: service.now())
                let today = service.today
                let result = service.todaysPick(from: context.candidates()) { c in
                    context.life(id: c.id, quick: PersonOfTheDay.lifeFromDates(c, today: today))
                }
                if !result.saved { appLog.write("Person of the Day: today's pick could not be saved (rotation memory only)") }
                return result.pick
            }.value
            guard let self, !Task.isCancelled, self.generation == mine else { return }
            self.pendingKey = nil
            self.computedKey = key
            if chosen != self.pick {
                self.pick = chosen
                appLog.write(chosen.map { "Person of the Day: \($0.personID) — \(Self.logReason($0.reason))" }
                             ?? "Person of the Day: nobody to feature in this tree")
            }
        }
    }

    /// Await the computation in flight (tests).
    func waitForPick() async { await task?.value }

    nonisolated static func logReason(_ r: PersonOfTheDay.Reason) -> String {
        switch r {
        case .bornOnThisDay(let n): return "born on this day (\(n) years)"
        case .diedOnThisDay(let n): return "died on this day (\(n) years)"
        case .marriedOnThisDay(let n): return "married on this day (\(n) years)"
        case .birthday: return "birthday"
        case .portraitAndStory: return "portrait and notes"
        case .portrait: return "portrait"
        case .story: return "notes"
        case .rotation: return "rotation"
        }
    }
}
