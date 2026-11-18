// CorpusSeal.swift — the in-app seal of the real-data corpus harness, as one pure function.
//
// NOT part of the Xcode project (see CorpusDriverSupport.swift for how these
// files reach a build). This file imports Foundation ONLY, so the seal can be
// compiled by itself and its REFUSALS pinned by behaviour, not by reading the
// source: tests/test_corpus_run.py builds it with `swiftc` beside a small
// main and feeds it hostnames, homes and folders — symlinks included.
//
// `CorpusSeal.refusal` answers: may THIS process, on THIS Mac, with THIS
// config, touch anything? nil = yes; otherwise the refusal word. It reads the
// filesystem only to resolve symlinks and to look for the marker file.
//
// The box (docs/guides/operations.md §1a), as checked here:
//   - this Mac is the M4 (its own name), and never the Ultra;
//   - the real home (the account database, not $HOME) holds corpus/THIS_IS_TEST_DATA.txt;
//   - ~/corpus/{state,work,media} ARE those folders: none of them is a symlink
//     or resolves anywhere but directly under the resolved corpus folder — so
//     a `work` that points into `media` (or anywhere else) is refused;
//   - the run's work folder is a folder INSIDE ~/corpus/work, never that folder itself;
//   - the config, the progress file, the catalog, the verbs lane's three
//     folders, $HOME and Application Support resolve inside ~/corpus/state or
//     inside the run's work folder — and NOTHING writable resolves inside
//     ~/corpus/media or ~/corpus/live;
//   - every file to run is under ~/corpus/media (check, proof) or is a clone
//     inside the run's work folder (verbs);
//   - this is a test host.
// (For Rick: a caseless `enum` with static functions ≈ a C++ namespace of free functions.)

import Foundation

struct CorpusConfig: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let sha: String
        let path: String
        /// The verbs lane: what is done to this file, and its extra byte-identical clones.
        let role: String?
        let copies: [String]?
    }
    let lane: String
    let corpusRoot: String
    let stateRoot: String
    let catalog: String
    let mediaRoot: String
    let work: String
    let progress: String
    let deadlineSeconds: Double
    let pending: [Item]
    /// The verbs lane only, each under `work`: the clones, the scratch archive root, scratch space.
    let volRoot: String?
    let archiveRoot: String?
    let scratch: String?
}

/// Everything the seal decides from. The driver fills it from the process; the tests fill it by hand.
struct CorpusSealInput {
    var hostname: String
    var realHome: String
    var configPath: String
    var lane: String
    var config: CorpusConfig?
    var homeDirectory: String
    var applicationSupport: String
    var isTestHost: Bool
}

enum CorpusSeal {
    static let allowedHosts: Set<String> = ["ricksm4"]
    /// The refusals decided before the run's progress file is known to be inside ~/corpus/work:
    /// for these nothing is written anywhere.
    static let beforeTheProgressFileIsProven: Set<String> = [
        "not_the_m4", "no_test_data_marker", "a_corpus_folder_is_an_alias", "config_outside_the_corpus", "work_outside_the_corpus",
    ]

    /// The path with every symlink followed (realpath(3)). A path that does not exist yet is
    /// resolved through its deepest existing folder, the rest appended as written; a path that
    /// runs through a DANGLING symlink has no answer and is contained by nothing.
    static func resolved(_ path: String) -> String {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var tail: [String] = []
        var info = stat()
        while lstat(url.path, &info) != 0, url.path != "/" {
            tail.insert(url.pathComponents.last ?? "", at: 0)
            url.deleteLastPathComponent()
        }
        guard let real = realpath(url.path, nil) else { return "/unresolvable/" + UUID().uuidString }
        defer { free(real) }
        return tail.reduce(String(cString: real)) { ($0 as NSString).appendingPathComponent($1) }
    }

    /// True containment: equal to the root, or below it, after both are resolved.
    static func isUnder(_ path: String, _ root: String) -> Bool {
        let p = resolved(path), r = resolved(root)
        return p == r || p.hasPrefix(r + "/")
    }

    static func shortHost(_ name: String) -> String {
        (name.split(separator: ".").first.map(String.init) ?? "").lowercased()
    }

    /// nil when the seal holds; otherwise the refusal word (never a path).
    static func refusal(_ input: CorpusSealInput) -> String? {
        guard allowedHosts.contains(shortHost(input.hostname)) else { return "not_the_m4" }
        let corpus = input.realHome + "/corpus"
        let state = corpus + "/state", work = corpus + "/work", media = corpus + "/media", live = corpus + "/live"
        guard FileManager.default.fileExists(atPath: corpus + "/THIS_IS_TEST_DATA.txt") else { return "no_test_data_marker" }
        // The three folders are themselves: an alias (work -> media, state -> anywhere) is refused.
        let corpusReal = resolved(corpus)
        for (folder, name) in [(state, "state"), (work, "work"), (media, "media")] where resolved(folder) != corpusReal + "/" + name {
            return "a_corpus_folder_is_an_alias"
        }
        guard isUnder(input.configPath, work), let config = input.config else { return "config_outside_the_corpus" }
        guard isUnder(config.progress, work), isUnder(config.work, work), resolved(config.work) != resolved(work) else {
            return "work_outside_the_corpus"
        }
        guard config.lane == input.lane else { return "config_is_for_another_lane" }
        // `inRun`: inside THIS run's work folder.
        func inRun(_ path: String) -> Bool { isUnder(path, config.work) && resolved(path) != resolved(work) }
        func pristine(_ path: String) -> Bool { isUnder(path, media) || isUnder(path, live) }
        guard resolved(config.corpusRoot) == corpusReal, isUnder(config.stateRoot, state),
              isUnder(config.catalog, state) || inRun(config.catalog), resolved(config.mediaRoot) == resolved(media) else {
            return "state_root_outside_the_corpus"
        }
        guard input.isTestHost else { return "not_a_test_host" }
        guard isUnder(input.homeDirectory, state) || inRun(input.homeDirectory),
              isUnder(input.applicationSupport, state) || inRun(input.applicationSupport) else { return "home_not_sealed" }
        guard config.pending.allSatisfy({ isUnder($0.path, media) || inRun($0.path) }),
              config.pending.allSatisfy({ ($0.copies ?? []).allSatisfy(inRun) }) else { return "a_file_is_outside_the_corpus" }
        let verbsFolders = [config.volRoot, config.archiveRoot, config.scratch].compactMap { $0 }
        guard verbsFolders.allSatisfy(inRun) else { return "a_verbs_folder_is_outside_the_run" }
        // Nothing this process may write resolves into the pristine copies or the read-only mount.
        let writable = [config.work, config.progress, input.homeDirectory, input.applicationSupport, config.stateRoot] + verbsFolders
            + (inRun(config.catalog) ? [config.catalog] : [])
        guard !writable.contains(where: pristine) else { return "a_writable_path_is_inside_the_pristine_corpus" }
        return nil
    }
}
