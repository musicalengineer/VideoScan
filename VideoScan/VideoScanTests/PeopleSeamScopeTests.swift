// PeopleSeamScopeTests.swift
// Two People test seams are task-local since 2026-11-21 (they were
// process-global statics a test swapped and restored, which forced
// `.serialized` and still let a test of another suite see them):
//
//   PersonNameGuard.roster                 the gallery a name-keyed write is judged against
//   AdaFaceModelLoader.modelsDirOverride   where the AdaFace model is looked for
//
// Proven here: sibling tasks holding DIFFERENT bindings (and none) at the
// same moment — a counted rendezvous (SeamRendezvousSupport), not a hope —
// each see only their own, through the real sinks (`PersonNameGuard.check`,
// the shared `AdaFaceModelLoader`). The source half (no app source binds
// either; the globals are gone) is in GlobalTestHookRetiredSensorTests.
//
// (C++: `@TaskLocal` is a thread_local that follows the coroutine and its
// children; `$name.withValue(x) { … }` is the RAII scope that installs it.)

import Foundation
import Testing
@testable import VideoScan

@Suite("People seams — a binding belongs to its own task tree")
struct PeopleSeamScopeTests {

    // MARK: PersonNameGuard.roster

    /// 24 sibling tasks, ALL asking about the same short name. Task n binds
    /// a roster holding n % 3 people of that name; every fourth binds none
    /// and is judged by the gallery on disk, which has nobody of that name.
    /// Each makes its binding and WAITS until all 24 hold theirs
    /// (SeamRendezvous — the overlap is constructed and counted); only then
    /// does each ask. The guard refuses exactly the tasks whose own roster
    /// holds two.
    @Test("24 rosters for one shared name held at once: each write is judged by its own roster",
          .timeLimit(.minutes(1)))
    func rosterIsPerTaskTree() async throws {
        try #require(TestEnvironment.isTestHost)
        let parties = 24
        let gate = SeamRendezvous(parties: parties)
        let name = "SeamScopeNamesake"   // the SAME name in every task, on purpose
        func namesakes(_ id: Int) -> Int? { id.isMultiple(of: 4) ? nil : id % 3 }   // nil: binds nothing

        /// (id, people of that name visible at the rendezvous, refusals of 20)
        let seen = await withTaskGroup(of: (Int, Int, Int).self, returning: [(Int, Int, Int)].self) { group in
            for id in 0..<parties {
                group.addTask {
                    func party() async -> (Int, Int, Int) {
                        await gate.arrive()                       // … until all 24 are here
                        let visible = PersonNameGuard.roster().filter { $0.name == name }.count
                        var refused = 0
                        for _ in 0..<20 {
                            do { try PersonNameGuard.check(name, operation: "seam scope") } catch { refused += 1 }
                        }
                        await gate.leave()
                        return (id, visible, refused)
                    }
                    guard let count = namesakes(id) else { return await party() }
                    let fixture = (0..<count).map { _ in POIProfile(name: name, referencePath: "") }
                    return await PersonNameGuard.$roster.withValue({ fixture }) { await party() }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(await gate.peakHeld == parties, "the bindings did not overlap — the test proved nothing")
        #expect(seen.count == parties)
        for (id, visible, refused) in seen {
            let own = namesakes(id) ?? 0   // unbound: the gallery on disk has nobody of that name
            #expect(visible == own, "task \(id) read another task's roster while all were held (\(visible) namesakes, own \(own))")
            #expect(refused == (own > 1 ? 20 : 0), "task \(id) with \(own) namesake(s) was refused \(refused) of 20")
        }
        #expect(PersonNameGuard.roster().allSatisfy { $0.name != name }, "a binding outlived its scope")
    }

    /// A child task is judged by its parent's roster; a detached task, which
    /// inherits nothing, by the gallery on disk.
    @Test func rosterReachesChildTasksOnly() async throws {
        try #require(TestEnvironment.isTestHost)
        let name = "SeamScopeChild-\(UUID().uuidString.prefix(6))"
        let two = [POIProfile(name: name, referencePath: ""), POIProfile(name: name, referencePath: "")]
        await PersonNameGuard.$roster.withValue({ two }) {
            let child = Task { PersonNameGuard.isShared(name, among: PersonNameGuard.roster()) }
            #expect(await child.value, "a child task inherits the roster")
            let detached = Task.detached { PersonNameGuard.isShared(name, among: PersonNameGuard.roster()) }
            #expect(await detached.value == false, "a detached task reads the gallery on disk")
        }
    }

    // MARK: AdaFaceModelLoader.modelsDirOverride

    private static func modelsDir(_ label: String, withCorruptModel: Bool) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_seam_adaface_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if withCorruptModel {
            // An empty folder named like a compiled model: present, unloadable.
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(AdaFaceModelLoader.modelBaseName + ".mlmodelc", isDirectory: true),
                withIntermediateDirectories: true)
        }
        return dir
    }

    /// 16 sibling tasks through the ONE shared loader. Even ones bind an
    /// empty models dir, odd ones a dir holding an unloadable model. Each
    /// makes its binding and WAITS until all 16 hold theirs (SeamRendezvous);
    /// only then does each ask. Every task is answered about its own
    /// directory, by name — never a sibling's, never the real
    /// ~/dev/VideoScan/models.
    @Test("16 models dirs held at once through the shared loader: each task is answered about its own directory",
          .timeLimit(.minutes(1)))
    func modelsDirIsPerTaskTree() async throws {
        let parties = 16
        let gate = SeamRendezvous(parties: parties)
        let dirs = try (0..<parties).map { try Self.modelsDir("\($0)", withCorruptModel: !$0.isMultiple(of: 2)) }
        defer { dirs.forEach { try? FileManager.default.removeItem(at: $0) } }
        struct Seen: Sendable {
            let id: Int
            let dirAtRendezvous: String
            let assetsPresent: Bool
            let loadedAModel: Bool
            let messages: [String]
        }

        let seen = await withTaskGroup(of: Seen.self, returning: [Seen].self) { group in
            for id in 0..<parties {
                let dir = dirs[id].path
                group.addTask {
                    await AdaFaceModelLoader.$modelsDirOverride.withValue(dir) {
                        await gate.arrive()                       // … until all 16 are here
                        let visible = AdaFaceModelLoader.modelsDir
                        let present = AdaFaceModelLoader.modelAssetsPresent()
                        var loaded = false
                        var messages: [String] = []
                        for _ in 0..<3 {
                            // Only the message leaves the actor (an MLModel is not Sendable).
                            let (model, error) = await AdaFaceModelLoader.shared.getModel()
                            if model != nil { loaded = true }
                            messages.append(error ?? "")
                        }
                        await gate.leave()
                        return Seen(id: id, dirAtRendezvous: visible, assetsPresent: present,
                                    loadedAModel: loaded, messages: messages)
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(await gate.peakHeld == parties, "the bindings did not overlap — the test proved nothing")
        #expect(seen.count == parties)
        for s in seen {
            let corrupt = !s.id.isMultiple(of: 2), dir = dirs[s.id].path
            #expect(s.dirAtRendezvous == dir, "task \(s.id) read another task's models dir while all were held")
            #expect(s.assetsPresent == corrupt)
            #expect(!s.loadedAModel, "task \(s.id) was handed a model — a URL cached for another directory?")
            for message in s.messages {
                #expect(message.contains(dir), "task \(s.id) was answered about another directory: \(message)")
                #expect(message.contains(corrupt ? "found but failed to load" : "AdaFace model not found"), "\(message)")
            }
        }
        #expect(AdaFaceModelLoader.modelsDirOverride == nil, "a binding outlived its scope")
    }

    /// Unbound, the directory is what production reads: the environment
    /// variable if the process has one, else the checkout's models folder.
    @Test func unboundTheModelsDirIsProductions() {
        let env = ProcessInfo.processInfo.environment["VIDEOSCAN_MODELS_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        #expect(AdaFaceModelLoader.modelsDirOverride == nil)
        #expect(AdaFaceModelLoader.modelsDir == env ?? NSHomeDirectory() + "/dev/VideoScan/models")
        // An empty binding is not a directory: it falls through, as it did.
        AdaFaceModelLoader.$modelsDirOverride.withValue("") {
            #expect(AdaFaceModelLoader.modelsDir == env ?? NSHomeDirectory() + "/dev/VideoScan/models")
        }
    }
}
