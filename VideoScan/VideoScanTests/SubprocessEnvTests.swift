import Foundation
import Testing
@testable import VideoScan

// MARK: - SubprocessEnv tests
//
// Pins the ordering contract of `augmentedPathWithHomebrew(inheriting:)`,
// the shared helper that any Process()-launching site uses to make sure
// Homebrew-installed tools (ffmpeg, ffprobe, etc.) are reachable
// regardless of how the parent app was launched.
//
// White-box test moved out of AudioTranscriberTests in
// fix/identify-family-path when the helper itself moved to a shared
// file. IdentifyFamilyModel now uses the same helper for its
// cluster_faces.py subprocess; the helper's behavior is covered here
// rather than at each call site.

@Suite("SubprocessEnv — augmentedPathWithHomebrew ordering contract")
struct SubprocessEnvTests {

    /// `/opt/homebrew/bin` (and the Intel `/usr/local/bin` fallback)
    /// must come ahead of whatever the parent process inherited. Several
    /// of our subprocesses shell out to `ffmpeg` internally; without
    /// this prefix the child Python fails with `[Errno 2] No such file
    /// or directory: 'ffmpeg'` whenever the app is launched from Xcode
    /// or Finder. If we ever regress the ordering, ffmpeg lookup might
    /// pick up a stale build from a non-Homebrew location.
    @Test("Subprocess PATH puts /opt/homebrew/bin first")
    func subprocessEnvironmentIncludesHomebrewPaths() {
        // Case 1: typical inherited PATH from a Finder/Xcode launch
        // (no Homebrew prefix present).
        let inherited = "/usr/bin:/bin:/usr/sbin:/sbin"
        let augmented = augmentedPathWithHomebrew(inheriting: inherited)
        let parts = augmented.split(separator: ":").map(String.init)
        #expect(parts.first == "/opt/homebrew/bin",
                "Apple Silicon Homebrew prefix must come first; got: \(augmented)")
        #expect(parts.dropFirst().first == "/usr/local/bin",
                "Intel Homebrew fallback must be second; got: \(augmented)")
        #expect(augmented.contains("/usr/bin"),
                "Inherited PATH entries must be preserved: \(augmented)")
        // Ordering: Homebrew entries must precede the inherited /usr/bin.
        let homebrewIdx = parts.firstIndex(of: "/opt/homebrew/bin")
        let usrBinIdx = parts.firstIndex(of: "/usr/bin")
        if let h = homebrewIdx, let u = usrBinIdx {
            #expect(h < u, "Homebrew must precede /usr/bin in PATH")
        } else {
            Issue.record("Missing expected entry — homebrew=\(String(describing: homebrewIdx)) usr/bin=\(String(describing: usrBinIdx))")
        }

        // Case 2: nil inherited PATH (process launched with no PATH env
        // at all — pathological but possible). We must still emit a
        // usable PATH with no trailing colon.
        let fromNil = augmentedPathWithHomebrew(inheriting: nil)
        #expect(fromNil.hasPrefix("/opt/homebrew/bin:/usr/local/bin:"),
                "nil inherited PATH should fall back to POSIX defaults; got: \(fromNil)")
        #expect(!fromNil.hasSuffix(":"),
                "Augmented PATH must not have a trailing colon (implicit cwd): \(fromNil)")

        // Case 3: empty-string inherited PATH — same fallback as nil.
        let fromEmpty = augmentedPathWithHomebrew(inheriting: "")
        #expect(fromEmpty.hasPrefix("/opt/homebrew/bin:/usr/local/bin:"),
                "Empty inherited PATH should also fall back; got: \(fromEmpty)")
        #expect(!fromEmpty.hasSuffix(":"))
    }
}
