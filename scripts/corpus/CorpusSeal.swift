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
// filesystem only to resolve symlinks, to look for the marker files, and — for
// the external root — to read ~/corpus/external-volume.json and ask the kernel
// what is mounted at the adopted mount point and its volume UUID.
//
// The box (docs/guides/operations.md §1a), as checked here:
//   - (the GATE, decided before the config file is read at all) this Mac is
//     the M4 (its own name), and never the Ultra;
//   - the real home (the account database, not $HOME) holds corpus/THIS_IS_TEST_DATA.txt;
//   - ~/corpus/{state,work,media} ARE those folders: none of them is a symlink
//     or resolves anywhere but directly under the resolved corpus folder — so
//     a `work` that points into `media` (or anywhere else) is refused;
//   - the run's work folder is a folder INSIDE ~/corpus/work, never that folder itself;
//   - the config, the progress file, the catalog, the verbs lane's three
//     folders, $HOME and Application Support resolve inside ~/corpus/state or
//     inside the run's work folder — and NOTHING writable resolves inside
//     ~/corpus/media or ~/corpus/live;
//   - every file to run is under ~/corpus/media, or under the EXTERNAL root's
//     corpus/media while that root is proven (check, proof), or is a clone
//     inside the run's work folder (verbs);
//   - the external root (DECISIONS 2026-11-19; scripts/corpus_run.py
//     `Seal.external`, the same rules, pinned side by side by the tests): the
//     volume adopted once by `corpus_run.sh adopt-volume` (its mount point and
//     volume UUID in ~/corpus/external-volume.json, a plain file of the corpus).
//     Proven when that path is itself (no link), something is mounted exactly
//     there, it carries THIS_IS_TEST_DATA.txt and its volume UUID is the pinned
//     one; ABSENT when nothing is mounted there (its files are simply not given
//     to a driver); a volume there that fails a check is refused. Nothing
//     writable may resolve anywhere on the adopted mount, mounted or not;
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

/// The external root as the seal finds it (Python: `External` / `Seal.external`).
enum CorpusExternal: Equatable, Sendable {
    case none                                       // no volume adopted
    case absent(mount: String)                      // adopted; nothing is mounted at its mount point
    case proven(mount: String)                      // mounted there, marked, the adopted volume UUID
    case refused(String)                            // the refusal word

    /// The adopted mount point, mounted or not (what nothing may write into).
    var mount: String? {
        switch self {
        case .absent(let mount), .proven(let mount): return mount
        case .none, .refused: return nil
        }
    }

    var word: String {
        switch self {
        case .none: return "none"
        case .absent: return "absent"
        case .proven: return "ok"
        case .refused(let word): return word
        }
    }
}

enum CorpusSeal {
    static let allowedHosts: Set<String> = ["ricksm4"]
    static let volumePin = "external-volume.json"

    private struct VolumePin: Decodable {
        let mount: String
        // swiftlint:disable:next identifier_name
        let volume_uuid: String
    }

    /// The adopted external volume, proven (see the header). Same order of questions as Python's
    /// `Seal.pin` + `Seal.external`.
    static func external(realHome: String) -> CorpusExternal {
        let corpus = realHome + "/corpus", pinPath = corpus + "/" + volumePin
        var info = stat()
        guard lstat(pinPath, &info) == 0 else { return .none }
        // One name only: a second name could be a run's progress file, appended to (Codex #331 F3).
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, resolved(pinPath) == resolved(corpus) + "/" + volumePin,
              let data = FileManager.default.contents(atPath: pinPath),
              let pin = try? JSONDecoder().decode(VolumePin.self, from: data),
              isPlainAbsolute(pin.mount), isVolumeUUID(pin.volume_uuid.uppercased()) else {
            return .refused("external_volume_pin_unreadable")
        }
        let mount = pin.mount
        guard lstat(mount, &info) == 0 else { return .absent(mount: mount) }
        guard resolved(mount) == mount else { return .refused("external_volume_through_a_link") }
        guard mountedOn(mount) == mount else { return .absent(mount: mount) }
        guard lstat(mount + "/THIS_IS_TEST_DATA.txt", &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            return .refused("external_volume_has_no_marker")
        }
        let uuid = (try? URL(fileURLWithPath: mount).resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        guard uuid?.uppercased() == pin.volume_uuid.uppercased() else { return .refused("external_volume_is_not_the_adopted_one") }
        let media = mount + "/corpus/media"
        if lstat(media, &info) == 0, resolved(media) != media { return .refused("external_volume_through_a_link") }
        return .proven(mount: mount)
    }

    /// May the file at `path` be opened NOW (Codex #331 F2: the volume is proven again before every
    /// engine, not once per run)? A file off the adopted volume: yes — `refusal` proved its place. On
    /// it: only while that volume is proven at this moment, and only under its corpus/media. When the
    /// volume (or its record) fails a check now, only ~/corpus/media and the run's clones may be opened.
    static func mayOpen(_ path: String, realHome: String) -> Bool {
        switch external(realHome: realHome) {
        case .none: return true
        case .absent(let mount): return !isUnder(path, mount)
        case .proven(let mount): return !isUnder(path, mount) || isUnder(path, mount + "/corpus/media")
        case .refused: return isUnder(path, realHome + "/corpus/media") || isUnder(path, realHome + "/corpus/work")
        }
    }

    /// A regular file with ONE name (not a link, not a folder, no second name a pristine file could share).
    static func isOneNameFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1
    }

    /// Where the file system that holds `path` is mounted (statfs(2) f_mntonname), or nil.
    static func mountedOn(_ path: String) -> String? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        return withUnsafeBytes(of: &fs.f_mntonname) { raw in
            raw.bindMemory(to: CChar.self).baseAddress.map { String(cString: $0) }
        }
    }

    /// Absolute, not "/", and every component a plain name (no "", ".", ".."): Python's normpath(p) == p.
    static func isPlainAbsolute(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return path.hasPrefix("/") && parts.count > 1 && parts.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func isVolumeUUID(_ text: String) -> Bool {
        let hex = Set("0123456789ABCDEF")
        let groups = text.split(separator: "-", omittingEmptySubsequences: false)
        return groups.map(\.count) == [8, 4, 4, 4, 12] && groups.allSatisfy { $0.allSatisfy(hex.contains) }
    }

    /// The path with every symlink followed (realpath(3)). A path that does not exist yet is
    /// resolved through its deepest existing folder, the rest appended as written; a path that
    /// runs through a DANGLING symlink has no answer and is contained by nothing. Neither is a
    /// path with a `..` in it: Foundation would cancel `link/..` as text BEFORE following the
    /// link, so the path checked would not be the path opened (Codex #313 F1). The harness
    /// never writes one.
    static func resolved(_ path: String) -> String {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return "/unresolvable/" + UUID().uuidString }
        var url = URL(fileURLWithPath: path)
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

    /// THE GATE: what is decided before the config file is even read — this Mac, the marker, the
    /// corpus folders being themselves, and the config file being a file inside ~/corpus/work.
    /// nil = the config may be read (Codex #313 F6: nothing is opened on the wrong Mac).
    static func gate(hostname: String, realHome: String, configPath: String) -> String? {
        guard allowedHosts.contains(shortHost(hostname)) else { return "not_the_m4" }
        let corpus = realHome + "/corpus"
        let state = corpus + "/state", work = corpus + "/work", media = corpus + "/media"
        guard FileManager.default.fileExists(atPath: corpus + "/THIS_IS_TEST_DATA.txt") else { return "no_test_data_marker" }
        // The three folders are themselves: an alias (work -> media, state -> anywhere) is refused.
        let corpusReal = resolved(corpus)
        for (folder, name) in [(state, "state"), (work, "work"), (media, "media")] where resolved(folder) != corpusReal + "/" + name {
            return "a_corpus_folder_is_an_alias"
        }
        guard isUnder(configPath, work), resolved(configPath) != resolved(work) else { return "config_outside_the_corpus" }
        return nil
    }

    /// The gate, then — only if it holds — the config, read through `read` (the driver passes
    /// FileManager's; the tests count the calls).
    static func loadConfig(hostname: String, realHome: String, configPath: String,
                           read: (String) -> Data?) -> (config: CorpusConfig?, refusal: String?) {
        if let word = gate(hostname: hostname, realHome: realHome, configPath: configPath) { return (nil, word) }
        guard let config = read(configPath).flatMap({ try? JSONDecoder().decode(CorpusConfig.self, from: $0) }) else {
            return (nil, "config_outside_the_corpus")
        }
        return (config, nil)
    }

    /// True when the run's progress file is proven to be a file inside THIS run's work folder,
    /// itself a folder inside ~/corpus/work, and not inside the pristine corpus: the only case
    /// in which a refusal may be written to it (Codex #313 F7).
    static func progressIsProven(_ config: CorpusConfig, realHome: String) -> Bool {
        let corpus = realHome + "/corpus", work = corpus + "/work"
        return isUnder(config.work, work) && resolved(config.work) != resolved(work)
            && isUnder(config.progress, config.work) && resolved(config.progress) != resolved(config.work)
            && !isUnder(config.progress, corpus + "/media") && !isUnder(config.progress, corpus + "/live")
            && isOneNameFile(config.progress)
    }

    /// nil when the seal holds; otherwise the refusal word (never a path).
    static func refusal(_ input: CorpusSealInput) -> String? {
        if let word = gate(hostname: input.hostname, realHome: input.realHome, configPath: input.configPath) { return word }
        let corpus = input.realHome + "/corpus"
        let state = corpus + "/state", work = corpus + "/work", media = corpus + "/media", live = corpus + "/live"
        let corpusReal = resolved(corpus)
        guard let config = input.config else { return "config_outside_the_corpus" }
        // The progress file is THIS run's: inside the run's work folder, not merely somewhere in ~/corpus/work.
        guard isUnder(config.work, work), resolved(config.work) != resolved(work),
              isUnder(config.progress, config.work), resolved(config.progress) != resolved(config.work) else {
            return "work_outside_the_corpus"
        }
        guard isOneNameFile(config.progress) else { return "progress_is_not_a_plain_file" }
        guard config.lane == input.lane else { return "config_is_for_another_lane" }
        // `inRun`: inside THIS run's work folder.
        func inRun(_ path: String) -> Bool { isUnder(path, config.work) && resolved(path) != resolved(work) }
        let external = external(realHome: input.realHome)
        if case .refused(let word) = external { return word }
        // The adopted volume, whole, mounted or not, is as pristine as ~/corpus/media.
        func pristine(_ path: String) -> Bool {
            isUnder(path, media) || isUnder(path, live) || (external.mount.map { isUnder(path, $0) } ?? false)
        }
        func onExternal(_ path: String) -> Bool {
            if case .proven(let mount) = external { return isUnder(path, mount + "/corpus/media") }
            return false
        }
        guard resolved(config.corpusRoot) == corpusReal, isUnder(config.stateRoot, state),
              isUnder(config.catalog, state) || inRun(config.catalog), resolved(config.mediaRoot) == resolved(media) else {
            return "state_root_outside_the_corpus"
        }
        guard input.isTestHost else { return "not_a_test_host" }
        guard isUnder(input.homeDirectory, state) || inRun(input.homeDirectory),
              isUnder(input.applicationSupport, state) || inRun(input.applicationSupport) else { return "home_not_sealed" }
        guard config.pending.allSatisfy({ isUnder($0.path, media) || onExternal($0.path) || inRun($0.path) }),
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
