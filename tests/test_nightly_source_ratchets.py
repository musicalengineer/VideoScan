#!/usr/bin/env python3
"""Unit tests for the two build-free nightly source ratchets.

  scripts/check_subprocess_injection.py
  scripts/check_volume_check_then_act.py
  scripts/ratchet_baseline.py  (grandfathering)

Fixture strategy, per the five-dimension checklist:

  Logic     — a clean file, then every violation shape, one per test.
  Isolation — the REAL, CORRECT patterns lifted verbatim from the codebase
              (PersonFinderCompilation's two concat writers, the promote
              engine's descriptor copy) are asserted SILENT. A checker that
              fires on correct code is worse than no checker, because it
              teaches everyone to skip the job.
  Sensor    — two tests scan the actual repository and assert that today's
              committed baselines still cover it. Those pin the real-world
              behaviour at production scale and will speak up if either
              checker starts flooding.
"""
from __future__ import annotations

import json
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = REPO_ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))

import check_subprocess_injection as inj  # noqa: E402
import check_volume_check_then_act as cta  # noqa: E402
import ratchet_baseline as rb  # noqa: E402
from swift_source_scan import (  # noqa: E402
    ROLE_PRODUCTION, ROLE_TEST, classify_source_role, split_functions,
    strip_comments,
)


def rules(findings):
    return sorted(f.rule for f in findings)


# ==========================================================================
# Subprocess injection — the "no command string exists" property
# ==========================================================================

CLEAN_PROCESS_RUNNER = """
import Foundation

enum CombineEngine {
    static func mux(video: String, audio: String, output: String) async -> Bool {
        // ffmpeg -i video.mxf -i audio.mxf -c copy -map 0:v -map 1:a out.mxf
        let result = await ProcessRunner.runProcess(
            executable: ToolLocator.ffmpegPath,
            arguments: [
                "-hide_banner", "-nostdin",
                "-i", video,
                "-i", audio,
                "-c", "copy",
                "-map", "0:v", "-map", "1:a",
                "-y", output
            ],
            deadlineSeconds: 600
        )
        return result.exitCode == 0
    }
}
"""


class TestNoShellCommandStrings(unittest.TestCase):
    def test_clean_process_runner_call_is_silent(self):
        self.assertEqual(inj.scan_text("Clean.swift", CLEAN_PROCESS_RUNNER), [])

    def test_semicolons_in_a_filename_are_not_a_finding(self):
        # The whole point of the argv array: this is just a weird filename.
        source = CLEAN_PROCESS_RUNNER.replace(
            'let result', 'let evil = "/Volumes/X/; rm -rf ~ .mov"\n        let result')
        self.assertEqual(inj.scan_text("Clean.swift", source), [])

    def test_bin_sh_dash_c_is_a_finding(self):
        source = """
        let result = await ProcessRunner.runProcess(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 30"])
        """
        found = inj.scan_text("Bad.swift", source)
        self.assertEqual(rules(found), ["shell-invocation"])

    def test_interpolated_command_string_is_flagged_separately(self):
        source = """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", "ffmpeg -i \\(inputPath) -c copy \\(outputPath)"]
        try proc.run()
        """
        found = inj.scan_text("Bad.swift", source)
        self.assertEqual(rules(found), ["shell-interpolated"])

    def test_env_shell_is_a_finding(self):
        source = """
        let result = await ProcessRunner.runProcess(
            executable: "/usr/bin/env",
            arguments: ["bash", "-c", "brew list"])
        """
        self.assertEqual(rules(inj.scan_text("Bad.swift", source)), ["shell-invocation"])

    def test_env_used_to_launch_a_real_tool_is_silent(self):
        # OllamaLocalServerBootstrap's actual shape: env + argv, no shell.
        source = """
        let result = await ProcessRunner.runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/env").path,
            arguments: ["ollama", "serve"])
        """
        self.assertEqual(inj.scan_text("Fine.swift", source), [])

    def test_new_shell_out_helper_is_a_finding(self):
        source = """
        func runShell(command: String) throws -> String {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            try proc.run()
            return ""
        }
        """
        found = inj.scan_text("Helper.swift", source)
        self.assertIn("shell-helper", rules(found))

    def test_helper_taking_an_arguments_array_is_silent(self):
        source = """
        func run(tool: String, arguments: [String]) throws -> String {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: tool)
            proc.arguments = arguments
            try proc.run()
            return ""
        }
        """
        self.assertEqual(inj.scan_text("Helper.swift", source), [])

    def test_libc_popen_and_launch_path(self):
        source = """
        let f = popen("ffprobe -show_streams", "r")
        proc.launchPath = "/usr/bin/ffmpeg"
        """
        self.assertEqual(rules(inj.scan_text("Old.swift", source)),
                         ["launch-path", "libc-shell"])

    def test_enum_case_named_system_is_not_libc(self):
        # CaptionRunner's chat roles: `.system("You are an image...")`
        source = 'let messages = [.system("You are an image understanding model.")]'
        self.assertEqual(inj.scan_text("CaptionRunner.swift", source), [])

    def test_a_comment_describing_the_rule_is_not_a_violation(self):
        source = """
        // Never do this: Process() with "/bin/sh" and ["-c", cmd].
        /* /bin/bash -c "\\(x)" would be an injection. */
        let x = 1
        """
        self.assertEqual(inj.scan_text("Docs.swift", source), [])

    def test_tests_are_out_of_scope_but_production_is_not(self):
        self.assertEqual(
            classify_source_role("VideoScan/VideoScanTests/ProcessControlTests.swift"),
            ROLE_TEST)
        self.assertEqual(
            classify_source_role("VideoScan/VideoScan/CombineEngine.swift"),
            ROLE_PRODUCTION)


# ==========================================================================
# ffmpeg concat demuxer escaping
# ==========================================================================

# Verbatim from VideoScan/VideoScan/PersonFinderCompilation.swift (~line 417).
REAL_CONCAT_WRITER_A = """
    let listContent = entries.map { e -> String in
        let escaped = e.clipPath.replacingOccurrences(of: "'", with: "'\\\\''")
        return "file '\\(escaped)'"
    }.joined(separator: "\\n")
"""

# Verbatim from the same file (~line 524).
REAL_CONCAT_WRITER_B = """
    let listContent = normalizedPaths
        .map { "file '\\($0.replacingOccurrences(of: "'", with: "'\\\\''"))'" }
        .joined(separator: "\\n")
"""

# Verbatim from swift_cli/PersonFinder.swift:881 — the unescaped one.
REAL_CONCAT_WRITER_UNESCAPED = """
    let listContent = entries.map { "file '\\($0.clipPath)'" }.joined(separator: "\\n")
"""

# Verbatim shape from ArchivistQueryAST+TranslatorDecoding.swift:164 — prose,
# not a concat list. Must never fire.
PROSE_MENTIONING_A_FILE = """
    var note = "rewrote \\(shape) naming file '\\(file)' to record{file}"
"""


class TestConcatEscaping(unittest.TestCase):
    def test_real_writer_a_is_silent(self):
        self.assertEqual(
            inj.scan_text("PersonFinderCompilation.swift", REAL_CONCAT_WRITER_A), [])

    def test_real_writer_b_is_silent(self):
        self.assertEqual(
            inj.scan_text("PersonFinderCompilation.swift", REAL_CONCAT_WRITER_B), [])

    def test_removing_the_escaping_from_writer_a_fires(self):
        """Regression sensor: this is the exact edit the rule exists to catch."""
        broken = REAL_CONCAT_WRITER_A.replace(
            'let escaped = e.clipPath.replacingOccurrences(of: "\'", with: "\'\\\\\'\'")',
            "let escaped = e.clipPath")
        found = inj.scan_text("PersonFinderCompilation.swift", broken)
        self.assertEqual(rules(found), ["concat-unescaped"])

    def test_removing_the_escaping_from_writer_b_fires(self):
        broken = REAL_CONCAT_WRITER_B.replace(
            '$0.replacingOccurrences(of: "\'", with: "\'\\\\\'\'")', "$0")
        found = inj.scan_text("PersonFinderCompilation.swift", broken)
        self.assertEqual(rules(found), ["concat-unescaped"])

    def test_swift_cli_unescaped_writer_fires(self):
        found = inj.scan_text("swift_cli/PersonFinder.swift",
                              REAL_CONCAT_WRITER_UNESCAPED)
        self.assertEqual(rules(found), ["concat-unescaped"])
        self.assertIn("apostrophe", found[0].message)

    def test_prose_mentioning_a_quoted_filename_is_silent(self):
        self.assertEqual(
            inj.scan_text("ArchivistQueryAST+TranslatorDecoding.swift",
                          PROSE_MENTIONING_A_FILE), [])

    def test_fully_literal_concat_line_is_silent(self):
        source = """let listContent = "file '/tmp/fixture.mov'" """
        self.assertEqual(inj.scan_text("Fixture.swift", source), [])

    def test_escaping_bound_several_lines_earlier_is_accepted(self):
        source = """
        func writeList(paths: [String]) -> String {
            var out: [String] = []
            for p in paths {
                let safe = p.replacingOccurrences(of: "'", with: "'\\\\''")
                let comment = "entry"
                _ = comment
                out.append("file '\\(safe)'")
            }
            return out.joined(separator: "\\n")
        }
        """
        self.assertEqual(inj.scan_text("Writer.swift", source), [])


# ==========================================================================
# Check-then-act on removable volumes
# ==========================================================================

# The correct pattern, modelled on PromoteToArchiveJob / ArchivePromoteEngine:
# open once, write/hash/fsync through that same descriptor into `.partial`,
# rename into place, fsync the parent directory.
PROMOTE_DESCRIPTOR_COPY = """
    private func copyVerified(from source: String, to dest: String) throws {
        let partial = dest + ".partial"
        let fd = open(partial, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw Failure.cannotOpen(partial) }
        defer { close(fd) }
        var digest = SHA256()
        while let chunk = try reader.next() {
            try writeAll(fd, chunk)
            digest.update(data: chunk)
        }
        guard barriers.fullFsync(fd) == 0 else { throw Failure.durabilityBarrierFailed(dest) }
        guard renameatx_np(dirfd, partialName, dirfd, finalName, 0) == 0 else {
            throw Failure.renameFailed(dest)
        }
        guard barriers.fsync(dirfd) == 0 else { throw Failure.durabilityBarrierFailed(dest) }
        try manifest.write(toFile: dest + ".manifest", atomically: true, encoding: .utf8)
    }
"""

BARE_CHECK_THEN_WRITE = """
    func stash(_ data: Data, onto volumeRoot: String) throws {
        let destPath = (volumeRoot as NSString).appendingPathComponent("sidecar.json")
        let fm = FileManager.default
        guard fm.fileExists(atPath: destPath) == false else { return }
        try data.write(to: URL(fileURLWithPath: destPath))
    }
"""

# The real VolumeCompare.fastCopy shape (~line 313): an existing file at the
# destination is counted as a finished copy, then copyItem writes to the same
# final name with no `.partial` in sight.
REAL_FAST_COPY = """
    private nonisolated func fastCopy(files: [VideoRecordSnapshot], sourcePath: String, rescueDir: String) async {
        let fm = FileManager.default
        for rec in files {
            let srcFile = rec.fullPath
            let relative = Self.relativePath(srcFile, under: sourcePath, fallback: rec.filename)
            let destFile = (rescueDir as NSString).appendingPathComponent(relative)
            if fm.fileExists(atPath: destFile) {
                continue
            }
            do {
                try fm.copyItem(atPath: srcFile, toPath: destFile)
            } catch {
                continue
            }
        }
    }
"""


class TestVolumeCheckThenAct(unittest.TestCase):
    def test_promote_descriptor_copy_is_silent(self):
        self.assertEqual(cta.scan_text("ArchivePromoteEngine.swift",
                                       PROMOTE_DESCRIPTOR_COPY), [])

    def test_bare_check_then_write_on_a_volume_path_fires(self):
        found = cta.scan_text("Stash.swift", BARE_CHECK_THEN_WRITE)
        self.assertEqual(rules(found), ["volume-check-then-act"])
        self.assertIn("PromoteToArchiveJob", found[0].message)
        self.assertIn("removable volume can disappear", found[0].message)

    def test_real_fast_copy_shape_fires(self):
        """Sensor for the live finding: a rescue copy that treats any file at
        the destination name as a completed copy."""
        found = cta.scan_text("VolumeCompare.swift", REAL_FAST_COPY)
        self.assertEqual(rules(found), ["volume-check-then-act"])

    def test_literal_volumes_path_counts_as_evidence(self):
        source = """
        func cacheDelta(_ text: String) throws {
            let dir = "/Volumes/CrucialX9/dossier-deltas"
            let target = (dir as NSString).appendingPathComponent("delta.json")
            if FileManager.default.fileExists(atPath: target) { return }
            try text.write(toFile: target, atomically: true, encoding: .utf8)
        }
        """
        self.assertEqual(rules(cta.scan_text("X.swift", source)),
                         ["volume-check-then-act"])

    def test_app_support_path_is_not_a_volume(self):
        """Narrowness check: the common, harmless shape must stay silent."""
        source = """
        func saveSettings(_ text: String) throws {
            let target = appSupportDir.appendingPathComponent("settings.json").path
            if FileManager.default.fileExists(atPath: target) { return }
            try text.write(toFile: target, atomically: true, encoding: .utf8)
        }
        """
        self.assertEqual(cta.scan_text("Settings.swift", source), [])

    def test_check_and_write_in_different_functions_is_silent(self):
        source = """
        func probe(_ volumePath: String) -> Bool {
            return FileManager.default.fileExists(atPath: volumePath)
        }

        func store(_ data: Data, at volumePath: String) throws {
            try data.write(to: URL(fileURLWithPath: volumePath))
        }
        """
        self.assertEqual(cta.scan_text("Split.swift", source), [])

    def test_write_before_the_check_is_silent(self):
        source = """
        func store(_ data: Data, at volumePath: String) throws {
            try data.write(to: URL(fileURLWithPath: volumePath))
            if FileManager.default.fileExists(atPath: volumePath) {
                log("stored")
            }
        }
        """
        self.assertEqual(cta.scan_text("Order.swift", source), [])

    def test_exists_then_remove_is_silent(self):
        """`if exists { try? remove }` is everywhere and is the benign
        direction of the race — deleting something already gone is fine."""
        source = """
        func clear(_ volumePath: String) {
            let fm = FileManager.default
            if fm.fileExists(atPath: volumePath) { try? fm.removeItem(atPath: volumePath) }
        }
        """
        self.assertEqual(cta.scan_text("Clear.swift", source), [])

    def test_attributes_check_also_counts(self):
        source = """
        func refresh(_ mountPointPath: String, data: Data) throws {
            let attrs = try? FileManager.default.attributesOfItem(atPath: mountPointPath)
            _ = attrs
            try data.write(to: URL(fileURLWithPath: mountPointPath))
        }
        """
        self.assertEqual(rules(cta.scan_text("Refresh.swift", source)),
                         ["volume-check-then-act"])

    def test_provenance_walks_back_to_a_catalogued_media_path(self):
        """`newPath <- dir <- oldPath <- record.fullPath` still counts."""
        source = """
        func renameRecord(_ record: VideoRecord, to newFilename: String) throws {
            let oldPath = record.fullPath
            let dir = (oldPath as NSString).deletingLastPathComponent
            let newPath = (dir as NSString).appendingPathComponent(newFilename)
            let fm = FileManager.default
            guard !fm.fileExists(atPath: newPath) else { throw RenameError.exists }
            try fm.moveItem(atPath: oldPath, toPath: newPath)
        }
        """
        self.assertEqual(rules(cta.scan_text("Rename.swift", source)),
                         ["volume-check-then-act"])


# ==========================================================================
# Grandfathered baseline behaviour (shared by both checkers)
# ==========================================================================

class TestBaselineRatchet(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = str(Path(self.tmp.name) / "baseline.json")

    def tearDown(self):
        self.tmp.cleanup()

    def _findings(self, n=1, path="A.swift", sig="sig"):
        return [rb.Finding(rule="r", path=path, line=10 + i, signature=sig,
                           message="m") for i in range(n)]

    def test_recorded_hits_report_as_pre_existing(self):
        found = self._findings(2)
        rb.write_baseline(self.path, found)
        new, old = rb.partition(found, rb.load_baseline(self.path))
        self.assertEqual(len(new), 0)
        self.assertEqual(len(old), 2)

    def test_a_new_violation_fails(self):
        rb.write_baseline(self.path, self._findings(1))
        new, old = rb.partition(self._findings(1) + self._findings(1, path="B.swift"),
                                rb.load_baseline(self.path))
        self.assertEqual([f.path for f in new], ["B.swift"])
        self.assertEqual([f.path for f in old], ["A.swift"])

    def test_a_baseline_entry_that_grew_fails(self):
        """Two copies of the same bad pattern in one file, one grandfathered."""
        rb.write_baseline(self.path, self._findings(1))
        new, old = rb.partition(self._findings(2), rb.load_baseline(self.path))
        self.assertEqual(len(new), 1)
        self.assertEqual(len(old), 1)

    def test_line_drift_does_not_resurrect_a_finding(self):
        """Inserting 200 lines above the offending code must not read as new."""
        rb.write_baseline(self.path, self._findings(1))
        drifted = [rb.Finding(rule="r", path="A.swift", line=210,
                              signature="sig", message="m")]
        new, old = rb.partition(drifted, rb.load_baseline(self.path))
        self.assertEqual(len(new), 0)
        self.assertEqual(len(old), 1)

    def test_editing_the_offending_line_does_read_as_new(self):
        rb.write_baseline(self.path, self._findings(1))
        edited = [rb.Finding(rule="r", path="A.swift", line=10,
                             signature="different code", message="m")]
        new, _ = rb.partition(edited, rb.load_baseline(self.path))
        self.assertEqual(len(new), 1)

    def test_fixed_entries_are_reported_for_shrinking(self):
        rb.write_baseline(self.path, self._findings(1))
        self.assertEqual(len(rb.fixed_keys([], rb.load_baseline(self.path))), 1)

    def test_signature_ignores_reflowing(self):
        self.assertEqual(rb.normalise_signature("a   b\n  c"),
                         rb.normalise_signature("a b c"))


# ==========================================================================
# Comment / function splitting helpers
# ==========================================================================

class TestSwiftSourceScan(unittest.TestCase):
    def test_strip_comments_preserves_line_count(self):
        source = 'let a = 1\n// note\n/* two\n   lines */\nlet b = "/* not a comment */"\n'
        stripped = strip_comments(source)
        self.assertEqual(source.count("\n"), stripped.count("\n"))
        self.assertIn("/* not a comment */", stripped)
        self.assertNotIn("note", stripped)

    def test_split_functions_finds_bodies(self):
        source = """
        func alpha() {
            let x = 1
            if x > 0 { print(x) }
        }

        func beta(a: Int,
                  b: Int) -> Int {
            return a + b
        }
        """
        names = [r.name for r in split_functions(strip_comments(source))]
        self.assertEqual(names, ["alpha", "beta"])


# ==========================================================================
# Live sensors against the real tree
# ==========================================================================

class TestAgainstRealRepository(unittest.TestCase):
    """These scan the actual ~725 production Swift files. They are the honest
    test: a checker that behaves on fixtures but floods on the real codebase
    is not shippable."""

    def test_injection_ratchet_is_green_against_its_committed_baseline(self):
        findings = inj.scan_tree(str(REPO_ROOT))
        baseline = rb.load_baseline(
            str(REPO_ROOT / "ci" / "baselines" / "subprocess_injection.json"))
        new, _ = rb.partition(findings, baseline)
        self.assertEqual(
            [f"{f.path}:{f.line} {f.rule}" for f in new], [],
            "New subprocess-injection findings on main. Either fix them or, if "
            "deliberate, regenerate with --update-baseline and say why.")

    def test_check_then_act_ratchet_is_green_against_its_committed_baseline(self):
        findings = cta.scan_tree(str(REPO_ROOT))
        baseline = rb.load_baseline(
            str(REPO_ROOT / "ci" / "baselines" / "volume_check_then_act.json"))
        new, _ = rb.partition(findings, baseline)
        self.assertEqual([f"{f.path}:{f.line}" for f in new], [])

    def test_neither_checker_floods(self):
        """Narrowness sensor. If a future edit to the rules makes either
        checker chatty, this fails long before it lands in Rick's morning
        summary as 300 unread findings."""
        total = len(inj.scan_tree(str(REPO_ROOT))) + len(cta.scan_tree(str(REPO_ROOT)))
        self.assertLess(total, 25, "Ratchets became chatty — retune, don't re-baseline.")

    def test_scan_of_the_whole_tree_is_fast_enough_for_a_ci_step(self):
        started = time.monotonic()
        inj.scan_tree(str(REPO_ROOT))
        cta.scan_tree(str(REPO_ROOT))
        elapsed = time.monotonic() - started
        self.assertLess(elapsed, 60.0, f"Tree scan took {elapsed:.1f}s")

    def test_committed_baselines_are_well_formed(self):
        for name in ("subprocess_injection.json", "volume_check_then_act.json"):
            with open(REPO_ROOT / "ci" / "baselines" / name, encoding="utf-8") as handle:
                payload = json.load(handle)
            self.assertIn("entries", payload)
            self.assertEqual(payload["entry_count"], len(payload["entries"]))


if __name__ == "__main__":
    unittest.main()
