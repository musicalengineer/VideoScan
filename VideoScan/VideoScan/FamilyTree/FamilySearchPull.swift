// FamilySearchPull.swift
// "Get Family Tree" — build a getmyancestors command, hand it to Terminal for
// the user to run, and install the GEDCOM it produces.
//
// WHY A TERMINAL HAND-OFF INSTEAD OF RUNNING IT OURSELVES (Rick 2026-08-25):
//
//   getmyancestors authenticates by POSTing the user's FamilySearch username
//   and password straight at ident.familysearch.org's login form — it does
//   NOT use the sanctioned OAuth browser flow. docs/familysearch_api_notes.md
//   rules that VideoScan must "never collect or proxy the user's FamilySearch
//   password". Terminal is therefore the seam: the tool prompts for the
//   password itself (getpass, on its own tty) and VideoScan never sees,
//   stores, forwards, or logs it.
//
//   Two further consequences of the same seam, both deliberate:
//     - the tool runs as a separate process, so its GPL license does not
//       reach VideoScan's own sources (same relationship we have to ffmpeg);
//     - the tool rides a third-party app key, so when that key is revoked
//       the failure lands in a Terminal window the user is already looking
//       at, not inside VideoScan.
//
// This file is pure value logic (no SwiftUI, no I/O beyond writing the
// script). FamilySearchPullCoordinator owns the lifecycle.

import Foundation

// MARK: - Request

/// Everything the user picks in the sheet. Deliberately has no password
/// field, and never will — see the file header.
struct FamilySearchPullRequest: Equatable {
    /// FamilySearch account name (normally an email address).
    var username: String
    /// Generations of ancestors. getmyancestors climbs ONE generation at a
    /// time (`for i in range(args.ascend): tree.add_parents(...)`), fetching
    /// each person's parents individually — so there is no API ceiling here;
    /// FamilySearch's 8-generation limit belongs to its bulk `ancestry`
    /// resource, which the tool does not use. 40 is a PRODUCT safety cap
    /// (docs/vs_app_gets_gedcom_data_using_own_script.md), not an API fact:
    /// it stops an accidental unbounded run; a sparse tree ends on its own
    /// long before. `-a 1` = the start person plus ONE parent step, hence
    /// the UI label "Ancestor steps".
    var ascend: Int = 8
    /// Generations of descendants. The `descendancy` resource accepts 1...4;
    /// 0 means "don't ask for any".
    var descend: Int = 0
    /// Optional FamilySearch person ID to start from ("LF7T-Y4C"). Empty
    /// means "start from the signed-in user", which is the tool's default.
    var startPersonID: String = ""
    /// `-m`: spouses and couple facts. On by default — a tree without
    /// marriages is not much of a tree.
    var includeMarriage: Bool = true
    /// `--rate-limit`: max requests/second. FamilySearch throttles per user
    /// and publishes no fixed budget, so we default well under the tool's
    /// own default rather than inviting a 429.
    var rateLimit: Int = 2
    /// `--concurrency`: worker threads. The tool defaults to 10; we default
    /// to 4 for the same reason.
    var concurrency: Int = 4
    /// Where the .ged should land. Staging, not the archive — the archive
    /// copy is made by `install()` only after the file parses.
    var outputURL: URL

    static let ascendRange = 1...40
    /// Convenient depths offered as one-tap presets.
    static let ascendPresets = [8, 12, 20, 40]
    static let descendRange = 0...4
    static let rateLimitRange = 1...10
    static let concurrencyRange = 1...10
}

// MARK: - Errors

enum FamilySearchPullError: LocalizedError, Equatable {
    case toolNotFound
    case emptyUsername
    case unsafeUsername
    case invalidPersonID(String)
    case outputNotGedcom(URL)
    case outputDirectoryMissing(URL)
    case scriptWriteFailed(String)
    case downloadedFileUnreadable(URL)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound:
            return "getmyancestors was not found. Install it with: python3 -m venv ~/dev/VideoScan/venv-genealogy && ~/dev/VideoScan/venv-genealogy/bin/pip install getmyancestors"
        case .emptyUsername:
            return "Enter your FamilySearch username (usually the email address you sign in with)."
        case .unsafeUsername:
            return "That username contains characters that cannot be passed safely to a shell. Check for stray spaces or line breaks."
        case .invalidPersonID(let value):
            return "“\(value)” is not a FamilySearch person ID. They look like LF7T-Y4C — four characters, a dash, then three."
        case .outputNotGedcom(let url):
            return "The output file must end in .ged (got “\(url.lastPathComponent)”)."
        case .outputDirectoryMissing(let url):
            return "The folder \(url.path) does not exist."
        case .scriptWriteFailed(let reason):
            return "Could not prepare the Terminal command: \(reason)"
        case .downloadedFileUnreadable(let url):
            return "\(url.lastPathComponent) could not be read as a non-empty GEDCOM file. The download may have been interrupted — check the Terminal window, then try again."
        case .installFailed(let reason):
            return "Could not install the family tree: \(reason)"
        }
    }
}

// MARK: - Tool discovery

/// Finds the `getmyancestors` executable. Only explicit, known locations are
/// consulted — VideoScan never searches `$PATH`, so a shadowing binary
/// somewhere on the user's path can't be launched on their behalf.
struct FamilySearchToolLocator {
    /// Searched in order. The dedicated venv first: keeping the tool out of
    /// the project venv means a broken genealogy dependency can never take
    /// VideoScan's own Python scripts down with it.
    static let defaultCandidatePaths: [String] = [
        "~/dev/VideoScan/venv-genealogy/bin/getmyancestors",
        "~/dev/VideoScan/venv/bin/getmyancestors",
        "/opt/homebrew/bin/getmyancestors",
        "/usr/local/bin/getmyancestors",
    ]

    var fileManager: FileManager = .default
    /// Overrides the search when the user has pointed us at a copy by hand.
    /// Consulted first; the candidate list is still searched if it is absent
    /// or unusable.
    var overridePath: String? = nil
    /// The well-known install locations searched after `overridePath`.
    /// Injectable so tests can confine the search to a sandbox instead of
    /// falling through to whatever is really installed on this machine.
    var candidatePaths: [String] = FamilySearchToolLocator.defaultCandidatePaths

    func locate() -> URL? {
        let paths = (overridePath.map { [$0] } ?? []) + candidatePaths
        for path in paths {
            let expanded = (path as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  fileManager.isExecutableFile(atPath: expanded)
            else { continue }
            return URL(fileURLWithPath: expanded)
        }
        return nil
    }
}

// MARK: - Command

/// A validated command line. Constructing one is the only way to get
/// arguments, so the forbidden-flag rules below cannot be bypassed by a
/// caller assembling its own array.
struct FamilySearchPullCommand: Equatable {
    /// Flags that would defeat the whole point of the Terminal hand-off.
    /// `-p`/`--password` puts the password in shell history and in `ps`;
    /// `--save-settings` with `--show-password` writes it to disk in
    /// plaintext next to the export. None of these are ever emitted, and
    /// FamilySearchPullTests pins that.
    static let forbiddenArguments: Set<String> = [
        "-p", "--password", "--save-settings", "--show-password",
    ]

    let toolURL: URL
    let request: FamilySearchPullRequest
    let arguments: [String]

    init(toolURL: URL, request: FamilySearchPullRequest) throws {
        let username = request.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { throw FamilySearchPullError.emptyUsername }
        guard Self.isSafeShellValue(username) else {
            throw FamilySearchPullError.unsafeUsername
        }
        guard request.outputURL.pathExtension.lowercased() == "ged" else {
            throw FamilySearchPullError.outputNotGedcom(request.outputURL)
        }

        var arguments = ["-u", username]

        let personID = request.startPersonID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !personID.isEmpty {
            let normalized = personID.uppercased()
            guard Self.isPersonID(normalized) else {
                throw FamilySearchPullError.invalidPersonID(personID)
            }
            arguments += ["-i", normalized]
        }

        // Clamp rather than reject: the sheet's steppers already constrain
        // these, and a programmatic caller asking for 20 generations should
        // get the 8 the API allows, not a crash.
        arguments += ["-a", String(request.ascend.clamped(to: FamilySearchPullRequest.ascendRange))]
        let descend = request.descend.clamped(to: FamilySearchPullRequest.descendRange)
        if descend > 0 {
            arguments += ["-d", String(descend)]
        }
        if request.includeMarriage {
            arguments.append("-m")
        }
        arguments += ["-v"]
        arguments += ["--rate-limit", String(request.rateLimit.clamped(to: FamilySearchPullRequest.rateLimitRange))]
        arguments += ["--concurrency", String(request.concurrency.clamped(to: FamilySearchPullRequest.concurrencyRange))]
        arguments += ["-o", request.outputURL.path]

        // Belt and braces: if a future edit ever introduces one of these,
        // fail loudly here rather than leaking a password.
        let offenders = arguments.filter { Self.forbiddenArguments.contains($0) }
        guard offenders.isEmpty else {
            throw FamilySearchPullError.scriptWriteFailed(
                "refusing to emit \(offenders.joined(separator: ", "))")
        }

        self.toolURL = toolURL
        self.request = request
        self.arguments = arguments
    }

    /// The command exactly as it will run, shell-quoted. Shown in the sheet
    /// and echoed in the Terminal window so the user can read it before
    /// committing — that verification step is the feature, not decoration.
    var displayLine: String {
        ([toolURL.path] + arguments).map(Self.quoted).joined(separator: " ")
    }

    // MARK: Validation helpers

    /// POSIX single-quoting: everything inside is literal, and an embedded
    /// quote is closed, escaped, and reopened. Bare words that are already
    /// safe are left alone so the previewed line stays readable.
    static func quoted(_ value: String) -> String {
        let safe = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./@=+:,")
        if !value.isEmpty, value.unicodeScalars.allSatisfy(safe.contains) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Rejects control characters and newlines outright. Anything else is
    /// made safe by quoting, but a newline in a username is always a
    /// mistake or an injection attempt.
    static func isSafeShellValue(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }

    /// FamilySearch person IDs are four characters, a dash, then three,
    /// from an uppercase alphanumeric alphabet (e.g. LF7T-Y4C).
    static func isPersonID(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 3 else {
            return false
        }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return parts.allSatisfy { part in
            part.unicodeScalars.allSatisfy(allowed.contains)
        }
    }
}

// MARK: - Script

/// Writes the `.command` file Terminal will open.
///
/// A `.command` file rather than AppleScript on purpose: `open`ing a file
/// needs no Automation entitlement, so the user never sees a TCC prompt
/// asking VideoScan for permission to control Terminal.
struct FamilySearchPullScript {
    let command: FamilySearchPullCommand
    let scriptURL: URL

    /// Note the deliberate pause. The user asked to see the command and
    /// approve it before anything runs (Rick 2026-08-25: "we see it we
    /// verify it we type in the pw").
    var contents: String {
        let line = command.displayLine
        return """
        #!/bin/zsh
        # Written by VideoScan — Get Family Tree.
        # Safe to delete; VideoScan rewrites it each time you use the sheet.
        #
        # VideoScan does not know your FamilySearch password and never will.
        # getmyancestors prompts for it below, on this terminal.

        set -u

        printf '\\n'
        printf '  VideoScan — Get Family Tree\\n'
        printf '  ===========================\\n\\n'
        printf '  About to run:\\n\\n'
        printf '    %s\\n\\n' \(FamilySearchPullCommand.quoted(line))
        printf '  getmyancestors will ask for your FamilySearch password.\\n'
        printf '  Type it here — it is never sent to VideoScan, never stored,\\n'
        printf '  and never written to this file or your shell history.\\n\\n'
        printf '  Press Return to run, or Control-C to cancel: '
        read -r confirm
        printf '\\n'

        \(line)
        # NOT `status` — that name is read-only in zsh and the assignment
        # aborts the script before the tool ever runs.
        exit_status=$?

        printf '\\n'
        if [ $exit_status -eq 0 ]; then
          printf '  Done. Switch back to VideoScan to install the tree.\\n'
        else
          printf '  getmyancestors exited with status %s.\\n' "$exit_status"
          printf '  Nothing was installed. The output above says why.\\n'
        fi
        printf '  You can close this window.\\n\\n'
        """
    }

    /// Writes the script and marks it executable. Overwrites any previous
    /// one: there is exactly one pending pull at a time.
    @discardableResult
    func write(fileManager: FileManager = .default) throws -> URL {
        let directory = scriptURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        } catch {
            throw FamilySearchPullError.scriptWriteFailed(error.localizedDescription)
        }
        return scriptURL
    }
}

// MARK: - Small helpers

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
