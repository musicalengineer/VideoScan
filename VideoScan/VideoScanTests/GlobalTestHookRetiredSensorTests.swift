// GlobalTestHookRetiredSensorTests.swift
// Source sensor for the seam survey's "pattern F" (2026-11-20): a
// process-global mutable test hook —
//
//     nonisolated(unsafe) static var hook: (…)?     // production
//     Type.hook = { … }; defer { Type.hook = nil }  // a test
//
// One global means every suite that sets it must be `.serialized`, and even
// then a test of ANOTHER suite running beside it sees the hook. Each hook
// in the table below became a `@TaskLocal` (pattern A) on 2026-11-21. This
// sensor holds three lines per hook:
//
//   1. the declaration is a `@TaskLocal`, and the global spelling is gone;
//   2. no test source assigns it (`Type.hook = …` no longer compiles, but a
//      rename back would — this names the reason);
//   3. no APP source binds it: `$hook.withValue` appears only in tests, so
//      production can never run with a test's fault or probe installed.
//
// (C++: `@TaskLocal` is a thread_local that follows the coroutine and its
// children; `$hook.withValue(x) { … }` is the only way to install one, an
// RAII scope. There is no setter to forget to undo.)
//
// Adding a hook: one row. The behaviour half — parallel tests with
// different bindings never see each other's — lives beside each owner
// (ArchiveAngelSeamScopeTests, PeopleSeamScopeTests).

import Foundation
import Testing

@Suite("Process-global test hooks are retired — task-local, bound by tests only")
struct GlobalTestHookRetiredSensorTests {

    struct Hook: Sendable, CustomTestStringConvertible {
        /// The app source file that declares it.
        let file: String
        /// The task-local's name (what `$name.withValue` binds).
        let name: String
        /// How tests assigned the old global ("Type.name").
        let oldSpelling: String
        var testDescription: String { oldSpelling }
    }

    static let hooks: [Hook] = [
        Hook(file: "ArchiveAngel/Prepare/ArchiveAngelPlan.swift", name: "injectedFailure",
             oldSpelling: "ArchiveAngelPlanWriter.injectedFailure"),
    ]

    /// Every test source: (file name, text).
    private static let testSources: [(name: String, text: String)] = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [(String, String)] = []
        for case let url as URL in walk where url.pathExtension == "swift" {
            if let text = try? String(contentsOf: url, encoding: .utf8) { out.append((url.lastPathComponent, text)) }
        }
        return out
    }()

    @Test("the declaration is a @TaskLocal; the global spelling is gone", arguments: hooks)
    func declaredTaskLocal(_ hook: Hook) throws {
        let code = try SourceTree.appCode(named: hook.file)
        #expect(code.contains("@TaskLocal static var \(hook.name)"), "\(hook.file) no longer declares the task-local")
        let name = NSRegularExpression.escapedPattern(for: hook.name)
        let global = try NSRegularExpression(pattern: #"(?m)^(?!.*@TaskLocal).*\bstatic\s+var\s+"# + name + #"\b"#)
        #expect(global.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) == nil,
                "\(hook.file) declares \(hook.name) as a plain static again — a process-global hook")
        let oldName = hook.oldSpelling.split(separator: ".").last.map(String.init) ?? hook.name
        if oldName != hook.name {
            for source in SourceTree.appSources {
                let text = try String(contentsOf: source.url, encoding: .utf8)
                guard text.contains(oldName) else { continue }
                #expect(!SourceTree.scan(text).code.contains(oldName), "\(source.relative) still names \(oldName)")
            }
        }
    }

    @Test("no test source assigns the old global", arguments: hooks)
    func noTestAssignsTheGlobal(_ hook: Hook) throws {
        #expect(Self.testSources.count > 1_000, "the walk read \(Self.testSources.count) test sources — not the tree")
        let assign = try NSRegularExpression(
            pattern: NSRegularExpression.escapedPattern(for: hook.oldSpelling) + #"\s*=[^=]"#)
        for source in Self.testSources where source.text.contains(hook.oldSpelling) {
            #expect(assign.firstMatch(in: source.text, range: NSRange(source.text.startIndex..., in: source.text)) == nil,
                    "\(source.name) assigns \(hook.oldSpelling) — bind the task-local for the test's own task tree instead")
        }
    }

    @Test("no app source binds it — only a test can", arguments: hooks)
    func noAppSourceBinds(_ hook: Hook) throws {
        #expect(SourceTree.appSources.count > 500, "the walk read \(SourceTree.appSources.count) app sources — not the tree")
        let binder = "$" + hook.name
        for source in SourceTree.appSources {
            let text = try String(contentsOf: source.url, encoding: .utf8)
            guard text.contains(binder) else { continue }
            // Code only: a doc comment may show a test how to bind. A file
            // the stripper cannot read is judged on its whole text (fails
            // closed: a mention anywhere counts).
            let scanned = SourceTree.scan(text)
            let judged = scanned.unsupported.isEmpty ? scanned.code : text
            #expect(!judged.contains(binder), "\(source.relative) binds \(binder) — a test seam bound by production")
        }
        // The positive control: the tests DO bind it, so the spelling this
        // looks for is the real one.
        #expect(Self.testSources.contains { $0.name != "GlobalTestHookRetiredSensorTests.swift" && $0.text.contains(binder + ".withValue") },
                "no test binds \(binder) — the sensor is looking for the wrong spelling, or the seam is unused")
    }

    /// The plan writer's fault crosses the job's three DETACHED saves by
    /// capture-and-pass (a detached task inherits no task-locals): each
    /// reads the task-local on the tree and hands the value in. A site that
    /// passed nil, or read the task-local inside the detached block, would
    /// silently stop injecting there.
    @Test func theAngelJobHandsTheFaultToEveryDetachedSave() throws {
        let code = try SourceTree.appCode(named: "ArchiveAngel/Prepare/ArchiveAngelJob.swift")
        func count(_ needle: String) -> Int { code.components(separatedBy: needle).count - 1 }
        #expect(count("Self.savePlanOffMain(") == 4, "the job's save sites changed — re-read this sensor")
        #expect(count("let fault = ArchiveAngelPlanWriter.injectedFailure") == 3, "one capture per detached save")
        #expect(count("generation: generation, injecting: fault) } catch") == 3, "each detached save is handed its captured fault")
        #expect(count("injecting: ArchiveAngelPlanWriter.injectedFailure)") == 1, "the loop save reads it on the tree")
        #expect(count("injecting: nil") == 0)
        #expect(count("TaskTreeScope.detached") == 3, "a new detached block: does it save the plan?")
    }
}
