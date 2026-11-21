// PeopleSeamScopeTests.swift
// Two People test seams are task-local since 2026-11-21 (they were
// process-global statics a test swapped and restored, which forced
// `.serialized` and still let a test of another suite see them):
//
//   PersonNameGuard.roster                 the gallery a name-keyed write is judged against
//   AdaFaceModelLoader.modelsDirOverride   where the AdaFace model is looked for
//
// Proven here: parallel tests with DIFFERENT bindings, and tests with none,
// never see each other's — through the real sinks (`PersonNameGuard.check`,
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

    /// 24 cases at once, ALL asking about the same short name. Case n binds
    /// a roster holding n % 3 people of that name; every fourth binds none
    /// and is judged by the gallery on disk, which has nobody of that name.
    /// The guard refuses exactly the cases whose own roster holds two.
    @Test("24 concurrent rosters for one shared name: each write is judged by its own roster", arguments: 0..<24)
    func rosterIsPerTaskTree(_ id: Int) async throws {
        try #require(TestEnvironment.isTestHost)
        let name = "SeamScopeNamesake"   // the SAME name in every case, on purpose
        let namesakes = id % 3
        let fixture = (0..<namesakes).map { _ in POIProfile(name: name, referencePath: "") }

        func refusals() async -> Int {
            var refused = 0
            for _ in 0..<20 {
                do { try PersonNameGuard.check(name, operation: "seam scope") } catch { refused += 1 }
                await Task.yield()   // let the other cases interleave
            }
            return refused
        }

        if id.isMultiple(of: 4) {
            #expect(PersonNameGuard.roster().allSatisfy { $0.name != name },
                    "an unbound case reads the gallery on disk, not another case's roster")
            #expect(await refusals() == 0, "an unbound case was refused on another case's roster")
        } else {
            let refused = await PersonNameGuard.$roster.withValue({ fixture }) {
                #expect(PersonNameGuard.roster().count == namesakes)
                return await refusals()
            }
            #expect(refused == (namesakes > 1 ? 20 : 0), "case \(id) bound \(namesakes) namesake(s) and was refused \(refused) of 20")
            #expect(PersonNameGuard.roster().allSatisfy { $0.name != name }, "the binding outlived its scope")
        }
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
}
