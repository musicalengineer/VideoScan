// RAMDiskNegativeMatrixTests.swift — the negative matrix for the RAM scratch
// disk (Shared/RAMDisk.swift), whose commands are DESTRUCTIVE by nature:
//   hdiutil attach -nomount ram://N · diskutil eraseVolume APFS VideoScan_Temp <dev>
//   · hdiutil detach <dev> -force · (sweep) hdiutil detach <mount> -force
// Until 2026-11-21 these were four hand-rolled Process() sites no test could
// reach. They now go through ProcessRunner, so a ScriptedExecutor answers
// them: no real hdiutil or diskutil ever runs here.
//
// THE INVARIANT (rule 2, the safety-critical checklist's "refuse before
// mutating"): RAMDisk never erases or detaches a device it did not just
// create. `eraseVolume` and a device `detach` are only ever given the node
// its OWN attach printed, and only when that output is exactly one
// /dev/diskN. Every row asserts the exact commands issued — a destructive
// command naming anything else is a failure.
//
// Rows: the command lines (positive control) · attach fails / cannot start /
// hangs · attach prints garbage (11 shapes) · eraseVolume fails / cannot
// start / hangs · the caller is cancelled mid-format · the cleanup detach
// fails · unmount's detach fails · refcount · the quit sweep: which names
// it detaches, a failing / hanging / unlaunchable hdiutil.
// One row stays RED under `withKnownIssue` for Rick (the sweep trusts a
// volume NAMED VideoScan_Temp to be a RAM disk).
//
// BELT AND BRACES. Should the seam ever fail and a command reach the real
// tools, nothing here can hurt: every attach names a unique 10-digit
// `ram://` size the mock CLAIMS (the real executor refuses a claimed
// command), every device node is a /dev/disk9NNNNN that does not exist, and
// the sweep reads a scratch directory, never /Volumes.
//
// Parallel by design: each test binds its own mock and log sink.

import Foundation
import Testing
@testable import VideoScan
@_spi(Testing) import VideoScanCore

@Suite("RAM disk — negative matrix through a scripted hdiutil/diskutil", .timeLimit(.minutes(1)))
struct RAMDiskNegativeMatrixTests {

    /// One test's fake world: a size no other test uses (its `ram://` token
    /// is the mock's claim) and a device node that cannot exist.
    struct Bench {
        let sizeMB = 500_000 + Int.random(in: 0..<400_000)
        let node = "/dev/disk9\(Int.random(in: 10_000..<100_000))"
        let log = InMemoryLogSink()
        var ramURL: String { "ram://\(sizeMB * 2048)" }
        var attach: [String] { ["attach", "-nomount", ramURL] }
        var erase: [String] { ["eraseVolume", "APFS", "VideoScan_Temp", node] }
        var detach: [String] { ["detach", node, "-force"] }

        /// A strict mock: a command no rule names is a failure.
        func mock(claiming extra: [String] = []) -> ScriptedExecutor {
            ScriptedExecutor(claiming: [ramURL] + extra)
        }
        /// What hdiutil really prints: the node, padded, newline-terminated.
        var attachOutput: ScriptedExecutor.Behaviour { .output(stdout: "\(node)          \t         \n") }
    }

    /// A hung tool. FINITE on purpose (Codex r1, 2026-11-21): if nothing
    /// stops it — the very regression these rows exist to catch — the child
    /// ends by itself after 20 s instead of living on as a day-long
    /// `/bin/sleep` orphan (the first red run of this suite left two).
    static let hang = ScriptedExecutor.Behaviour.hang(maxSeconds: 20)

    /// A result another task will deliver, read with a bound.
    /// (C++: a mutex-guarded std::optional — a future you can poll.)
    final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool?
        func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
        var current: Bool? { lock.lock(); defer { lock.unlock() }; return value }

        /// The value once it is delivered, or nil if `limit` passes first.
        /// Polls — it never awaits the producing task, so a producer that
        /// hangs for ever cannot hold the test (awaiting an unstructured
        /// task's value inside a task group could: cancelAll does not end
        /// that wait, and leaving the group waits for it).
        func wait(_ limit: Duration) async -> Bool? {
            let deadline = ContinuousClock.now + limit
            while current == nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            return current
        }
    }

    static let fast = RAMDisk.Timeouts(attachSeconds: 0.4, eraseSeconds: 0.4, detachSeconds: 0.4, killGraceSeconds: 0.5)

    /// "tool arg arg …" per call, for exact-sequence assertions.
    static func lines(_ mock: ScriptedExecutor) -> [String] {
        mock.calls.map { ([$0.tool] + $0.arguments).joined(separator: " ") }
    }

    static func line(_ tool: String, _ arguments: [String]) -> String {
        ([tool] + arguments).joined(separator: " ")
    }

    // MARK: - The command lines

    @Test("COMMAND: mount issues exactly attach then eraseVolume on the node attach printed; unmount detaches that node")
    func theCommandLines() async {
        let b = Bench()
        let mock = b.mock()
            .on("hdiutil", containing: ["attach"], b.attachOutput)
            .on("diskutil", .output(stdout: "Finished erase on disk\n"))
            .on("hdiutil", containing: ["detach"], .output())
        let disk = RAMDisk()
        await mock.scoped {
            #expect(await disk.mount(sizeMB: b.sizeMB))
            #expect(await disk.mountPoint == "/Volumes/VideoScan_Temp")
            #expect(await disk.currentRefCount == 1)
            await disk.unmount()
            #expect(await disk.mountPoint == nil)
        }
        #expect(mock.calls.count == 3)
        guard mock.calls.count == 3 else { return }
        #expect(mock.calls[0].executable == "/usr/bin/hdiutil" && mock.calls[0].arguments == b.attach)
        #expect(mock.calls[1].executable == "/usr/sbin/diskutil" && mock.calls[1].arguments == b.erase)
        #expect(mock.calls[2].executable == "/usr/bin/hdiutil" && mock.calls[2].arguments == b.detach)
        #expect(mock.calls.allSatisfy { $0.environment == nil }, "the app's own environment, as before")
    }

    @Test("COMMAND: two users share one disk — one attach, and only the last unmount detaches")
    func refCount() async {
        let b = Bench()
        let mock = b.mock()
            .on("hdiutil", containing: ["attach"], b.attachOutput)
            .on("diskutil", .output())
            .on("hdiutil", containing: ["detach"], .output())
        let disk = RAMDisk()
        await mock.scoped {
            #expect(await disk.mount(sizeMB: b.sizeMB))
            #expect(await disk.mount(sizeMB: b.sizeMB))
            #expect(await disk.currentRefCount == 2)
            await disk.unmount()
            #expect(mock.calls(to: "hdiutil", containing: ["detach"]).isEmpty, "the other user still has it")
            await disk.unmount()
        }
        #expect(Self.lines(mock) == [Self.line("hdiutil", b.attach), Self.line("diskutil", b.erase), Self.line("hdiutil", b.detach)])
    }

    @Test("an unmount with nothing mounted issues no command at all")
    func unmountWithoutMount() async {
        let mock = ScriptedExecutor()
        await mock.scoped { await RAMDisk().unmount() }
        #expect(mock.calls.isEmpty)
    }

    // MARK: - attach fails

    @Test("attach exits nonzero: no RAM disk, and nothing is erased or detached")
    func attachFails() async {
        let b = Bench()
        let mock = b.mock().on("hdiutil", containing: ["attach"],
                               .output(stdout: "\(b.node)\n", stderr: "hdiutil: attach failed - no mountable file systems\n", exit: 1))
        let disk = RAMDisk()
        await withAppLog(b.log) {
            await mock.scoped {
                #expect(await disk.mount(sizeMB: b.sizeMB) == false)
                #expect(await disk.mountPoint == nil)
                await disk.unmount()
            }
        }
        #expect(Self.lines(mock) == [Self.line("hdiutil", b.attach)],
                "a node printed by a FAILED attach is not ours to erase or detach")
        #expect(b.log.contains("hdiutil attach failed (exit 1: hdiutil: attach failed - no mountable file systems)"), "\(b.log.lines)")
    }

    @Test("attach cannot be started: no RAM disk, nothing else is run")
    func attachCannotStart() async {
        let b = Bench()
        let mock = b.mock().on("hdiutil", .launchFailure)
        let disk = RAMDisk()
        await withAppLog(b.log) {
            await mock.scoped { #expect(await disk.mount(sizeMB: b.sizeMB) == false) }
        }
        #expect(Self.lines(mock) == [Self.line("hdiutil", b.attach)])
        #expect(b.log.contains("hdiutil attach failed (could not start:"), "\(b.log.lines)")
    }

    @Test("attach hangs: stopped at its deadline, no RAM disk, nothing erased or detached")
    func attachHangs() async {
        let b = Bench()
        let mock = b.mock().on("hdiutil", containing: ["attach"], Self.hang)
        let disk = RAMDisk(timeouts: Self.fast)
        let started = ContinuousClock.now
        await withAppLog(b.log) {
            await mock.scoped { #expect(await disk.mount(sizeMB: b.sizeMB) == false) }
        }
        #expect(ContinuousClock.now - started < .seconds(20))
        #expect(Self.lines(mock) == [Self.line("hdiutil", b.attach)])
        #expect(b.log.contains("hdiutil attach failed (timed out"), "\(b.log.lines)")
    }

    // MARK: - attach prints something that is not its own device node

    /// `diskutil eraseVolume` takes a mount point or a volume NAME as its
    /// device argument, so anything but one whole-disk node is refused.
    static let garbage: [String] = [
        "",
        "   \n",
        "/Volumes/NoSuchVolume-RAMDiskMatrix",          // a mount point: diskutil would erase that volume
        "NoSuchVolume RAMDiskMatrix HD",                 // a volume name: likewise
        "/dev/disk912345s1",                             // a slice of some disk
        "/dev/disk912345\n/dev/disk912346",              // two nodes: which one is ours?
        "disk912345",                                    // no /dev/
        "/dev/rdisk912345",                              // the raw node
        "hdiutil: attach: /dev/disk912345 is busy",      // a node inside an error sentence
        "/dev/disk 912345",
        "/dev/disk0",                                    // the internal boot disk
        "/dev/disk912345 /Volumes/NoSuchVolume-RAMDiskMatrix",
        "/dev/disk９",                                    // a full-width digit
        // Codex r1 P1: a valid-looking node, padding up to the 4096-byte
        // collection cap, then a SECOND node the runner's cap drops — the
        // collected prefix alone would read as one clean device.
        "/dev/disk912345" + String(repeating: " ", count: 4096 - "/dev/disk912345".utf8.count) + "\n/dev/disk912346\n",
        // …and the boundary: output that exactly fills the cap is not known to be whole.
        "/dev/disk912345" + String(repeating: " ", count: 4096 - "/dev/disk912345".utf8.count),
        "/dev/disk912345" + String(repeating: "\n", count: 8000),
        // Codex r2 P1: a UTF-8 BOM first. The runner collects 4096 RAW bytes;
        // decoding strips the 3-byte BOM, so a count taken AFTER decoding
        // reads 4093 — "under the cap" — and the second node is gone.
        "\u{FEFF}/dev/disk912345" + String(repeating: " ", count: 4096 - 3 - "/dev/disk912345".utf8.count) + "\n/dev/disk912346\n",
        "\u{FEFF}/dev/disk912345\n",                    // a BOM alone: not hdiutil's bytes
        "/dev/disk912345\u{0}\n",                       // a NUL after the node
        "/dev/disk912345\n\u{0}",
        "/dev/disk٩١٢٣٤٥\n",                            // Arabic-Indic digits
        "/dev/disk91234５\n",                            // one full-width digit among ASCII ones
        "/dev/disk912345\u{00A0}\n",                    // a no-break space is not hdiutil's padding
        "/dev/disk912345" + String(repeating: " ", count: 400) + "\n",   // far longer than hdiutil's ~53-byte line
        " /dev/disk912345\n",                           // leading space: not hdiutil's shape
    ]

    @Test("attach exits 0 but prints garbage: REFUSED before any erase — no diskutil, no detach",
          arguments: garbage)
    func attachPrintsGarbage(_ output: String) async {
        let b = Bench()
        let mock = b.mock(claiming: ["NoSuchVolume-RAMDiskMatrix", "NoSuchVolume RAMDiskMatrix HD"])
            .on("hdiutil", containing: ["attach"], .garbage(stdout: output))
            .on("diskutil", .output())                       // answered, so the hole shows as a CALL, not as an unmatched command
            .on("hdiutil", containing: ["detach"], .output())
        let disk = RAMDisk()
        await withAppLog(b.log) {
            await mock.scoped {
                #expect(await disk.mount(sizeMB: b.sizeMB) == false, "garbage accepted as a device: \(output.prefix(60).debugDescription)… (\(output.utf8.count) bytes)")
                #expect(await disk.mountPoint == nil)
                await disk.unmount()
            }
        }
        #expect(mock.calls(to: "diskutil").isEmpty,
                "eraseVolume was run on \(mock.calls(to: "diskutil").map(\.commandLine)) — a device RAMDisk did not create")
        #expect(mock.calls(to: "hdiutil", containing: ["detach"]).isEmpty,
                "detach -force was run on something RAMDisk did not create: \(Self.lines(mock))")
        #expect(b.log.contains("REFUSED"), "\(b.log.lines)")
        #expect(b.log.contains("nothing erased, nothing detached"), "\(b.log.lines)")
    }

    @Test("the device node parser accepts exactly hdiutil's own shape")
    func ownedDeviceParser() {
        func parse(_ text: String) -> String? { RAMDisk.OwnedDevice(rawAttachOutput: Data(text.utf8))?.node }
        #expect(parse("/dev/disk4          \t                              \t\n") == "/dev/disk4")     // hdiutil's own 53-byte line
        #expect(parse("/dev/disk27\n") == "/dev/disk27")
        #expect(parse("/dev/disk1") == "/dev/disk1")
        #expect(parse("/dev/disk123456\r\n") == "/dev/disk123456")
        for bad in Self.garbage + ["/dev/disk04", "/dev/disk1234567", "/dev/disk4s", "/dev/disk-4", "/dev/disk4\u{0}", "/dev/disk4\u{B}"] {
            #expect(parse(bad) == nil, "\(bad.prefix(60).debugDescription)… (\(bad.utf8.count) bytes)")
        }
        // The bound: exactly at it is whole; one byte over is not.
        let max = RAMDisk.maxAttachOutputBytes
        #expect(max == 256)
        let node = "/dev/disk7"
        #expect(parse(node + String(repeating: " ", count: max - node.utf8.count)) == node)
        #expect(parse(node + String(repeating: " ", count: max + 1 - node.utf8.count)) == nil)
        // Raw bytes that are not UTF-8 at all.
        #expect(RAMDisk.OwnedDevice(rawAttachOutput: Data([0xFF, 0xFE] + Array("/dev/disk7\n".utf8))) == nil)
        #expect(RAMDisk.OwnedDevice(rawAttachOutput: Data(Array("/dev/disk7".utf8) + [0x80, 0x0A])) == nil)

        // The collector keeps one byte past the bound and counts everything,
        // however the pipe chunks it — over-long output is never a prefix.
        let raw = RAMDisk.RawOutput(limit: max)
        raw.append(Data("/dev/disk7".utf8))
        for _ in 0..<50 { raw.append(Data(repeating: 0x20, count: 100)) }
        raw.append(Data("\n/dev/disk8\n".utf8))
        #expect(raw.data.count == max + 1 && raw.byteCount == 10 + 5000 + 12)
        #expect(RAMDisk.OwnedDevice(rawAttachOutput: raw.data) == nil)
    }

    // MARK: - eraseVolume fails

    @Test("eraseVolume exits nonzero: the device THIS call attached is detached, once, and nothing else")
    func eraseFails() async {
        let b = Bench()
        let mock = b.mock()
            .on("hdiutil", containing: ["attach"], b.attachOutput)
            .on("diskutil", .output(stderr: "Error: -69877: Couldn't open device\n", exit: 1))
            .on("hdiutil", containing: ["detach"], .output())
        let disk = RAMDisk()
        await withAppLog(b.log) {
            await mock.scoped {
                #expect(await disk.mount(sizeMB: b.sizeMB) == false)
                #expect(await disk.mountPoint == nil)
                await disk.unmount()                          // nothing is mounted: no second detach
            }
        }
        #expect(Self.lines(mock) == [Self.line("hdiutil", b.attach), Self.line("diskutil", b.erase), Self.line("hdiutil", b.detach)])
        #expect(b.log.contains("diskutil eraseVolume on \(b.node) failed (exit 1: Error: -69877: Couldn't open device)"), "\(b.log.lines)")
    }

    @Test("eraseVolume cannot be started: the attached device is detached, once")
    func eraseCannotStart() async {
        let b = Bench()
        let mock = b.mock()
            .on("hdiutil", containing: ["attach"], b.attachOutput)
            .on("diskutil", .launchFailure)
            .on("hdiutil", containing: ["detach"], .output())
        let disk = RAMDisk()
        await mock.scoped { #expect(await disk.mount(sizeMB: b.sizeMB) == false) }
        #expect(Self.lines(mock) == [Self.line("hdiutil", b.attach), Self.line("diskutil", b.erase), Self.line("hdiutil", b.detach)])
    }

    @Test("eraseVolume hangs: stopped at its deadline (it had none), then the attached device is detached — mount does not hang")
    func eraseHangs() async {
        let b = Bench()
        let mock = b.mock()
            .on("hdiutil", containing: ["attach"], b.attachOutput)
            .on("diskutil", Self.hang)
            .on("hdiutil", containing: ["detach"], .output())
        let disk = RAMDisk(timeouts: Self.fast)
        let sink = b.log
        let size = b.sizeMB
        // Bounded wait: before the deadline existed this mount never
        // returned, so the test must not await it — it polls an Outcome.
        let outcome = Outcome()
        let mounting = Task { outcome.set(await withAppLog(sink) { await mock.scoped { await disk.mount(sizeMB: size) } }) }
        let finished = await outcome.wait(.seconds(8))
        mounting.cancel()
        #expect(finished == false, finished == nil ? "mount is still waiting on a hung diskutil after 8 s"
                                                    : "mount reported SUCCESS over a diskutil that never finished")
        guard finished != nil else { return }      // nothing more to assert; the hung child ends itself (Self.hang)
        #expect(Self.lines(mock) == [Self.line("hdiutil", b.attach), Self.line("diskutil", b.erase), Self.line("hdiutil", b.detach)])
        #expect(b.log.contains("diskutil eraseVolume on \(b.node) failed (timed out"), "\(b.log.lines)")
    }

    @Test("the caller is cancelled while eraseVolume runs: the attached device is STILL detached (no leaked RAM device)")
    func cancelledMidFormat() async {
        let b = Bench()
        let mock = b.mock()
            .on("hdiutil", containing: ["attach"], b.attachOutput)
            .on("diskutil", Self.hang)
            .on("hdiutil", containing: ["detach"], .output())
        let disk = RAMDisk(timeouts: Self.fast)
        let size = b.sizeMB
        let outcome = Outcome()
        let mounting = Task { outcome.set(await mock.scoped { await disk.mount(sizeMB: size) }) }
        for _ in 0..<400 where mock.calls(to: "diskutil").isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        mounting.cancel()
        let finished = await outcome.wait(.seconds(8))      // never an unbounded await of the task
        #expect(finished == false, "\(finished.map { "mount returned \($0)" } ?? "mount had not returned 8 s after the cancel")")
        #expect(Self.lines(mock) == [Self.line("hdiutil", b.attach), Self.line("diskutil", b.erase), Self.line("hdiutil", b.detach)],
                "a cancelled caller must not skip the detach of the device it attached")
    }

    // MARK: - detach fails

    @Test("eraseVolume fails AND the cleanup detach fails: said in words; no other device is touched, no retry storm")
    func eraseFailsThenDetachFails() async {
        let b = Bench()
        let mock = b.mock()
            .on("hdiutil", containing: ["attach"], b.attachOutput)
            .on("diskutil", .output(exit: 1))
            .on("hdiutil", containing: ["detach"], .output(stderr: "hdiutil: couldn't unmount \"disk9\" - Resource busy\n", exit: 16))
        let disk = RAMDisk()
        await withAppLog(b.log) {
            await mock.scoped { #expect(await disk.mount(sizeMB: b.sizeMB) == false) }
        }
        #expect(Self.lines(mock) == [Self.line("hdiutil", b.attach), Self.line("diskutil", b.erase), Self.line("hdiutil", b.detach)])
        #expect(b.log.contains("hdiutil detach of \(b.node) FAILED (exit 16: hdiutil: couldn't unmount \"disk9\" - Resource busy) — the RAM device is still attached"),
                "\(b.log.lines)")
    }

    @Test("unmount's detach fails (exit, hang, cannot start): one detach of its own node, and the failure is logged — never silent",
          arguments: ["exit", "hang", "launch"])
    func unmountDetachFails(_ how: String) async {
        let b = Bench()
        let failing: ScriptedExecutor.Behaviour = how == "exit" ? .output(stderr: "Resource busy\n", exit: 16)
            : how == "hang" ? Self.hang : .launchFailure
        let mock = b.mock()
            .on("hdiutil", containing: ["attach"], b.attachOutput)
            .on("diskutil", .output())
            .on("hdiutil", containing: ["detach"], failing)
        let disk = RAMDisk(timeouts: Self.fast)
        await withAppLog(b.log) {
            await mock.scoped {
                #expect(await disk.mount(sizeMB: b.sizeMB))
                await disk.unmount()
                #expect(await disk.mountPoint == nil)
                await disk.unmount()                          // already released: no second detach
            }
        }
        #expect(Self.lines(mock) == [Self.line("hdiutil", b.attach), Self.line("diskutil", b.erase), Self.line("hdiutil", b.detach)])
        #expect(b.log.contains("hdiutil detach of \(b.node) FAILED ("), "\(b.log.lines)")
        #expect(b.log.contains("still attached"), "\(b.log.lines)")
    }

    // MARK: - The launch/quit sweep

    struct SweepBench {
        let volumes: URL
        let log = InMemoryLogSink()

        init(_ names: [String]) throws {
            volumes = FileManager.default.temporaryDirectory
                .appendingPathComponent("ramdisk-sweep-\(UUID().uuidString)", isDirectory: true)
            for name in names {
                try FileManager.default.createDirectory(at: volumes.appendingPathComponent(name, isDirectory: true),
                                                        withIntermediateDirectories: true)
            }
        }
        func path(_ name: String) -> String { "\(volumes.path)/\(name)" }
        func cleanup() { try? FileManager.default.removeItem(at: volumes) }
    }

    @Test("SWEEP: detaches exactly this app's RAM-disk names — never a volume that merely starts with VideoScan_Temp")
    func sweepDetachesOnlyOwnNames() async throws {
        let s = try SweepBench(["VideoScan_Temp", "VideoScan_Temp 1", "VideoScan_Temp 12",
                                "VideoScan_Temp_Archive", "VideoScan_Temporary", "VideoScan_Temp 1 copy",
                                "VideoScan_Temp ", "VideoScan_Temp x", "VideoScan_Temp2", "Media", "Family Archive"])
        defer { s.cleanup() }
        let mock = ScriptedExecutor(claiming: [s.volumes.path]).on("hdiutil", containing: ["detach"], .output())
        var detached: [String] = []
        await withAppLog(s.log) {
            await mock.scoped { detached = RAMDisk.cleanupStaleMounts(volumesDir: s.volumes.path) }
        }
        let own = [s.path("VideoScan_Temp"), s.path("VideoScan_Temp 1"), s.path("VideoScan_Temp 12")]
        #expect(mock.calls.map(\.executable) == Array(repeating: "/usr/bin/hdiutil", count: mock.calls.count))
        #expect(mock.calls.map(\.arguments) == own.map { ["detach", $0, "-force"] },
                "force-detached something that is not this app's RAM disk: \(Self.lines(mock))")
        #expect(detached == own)
        for spared in ["VideoScan_Temp_Archive", "VideoScan_Temporary", "VideoScan_Temp 1 copy", "VideoScan_Temp x", "VideoScan_Temp2"] {
            #expect(s.log.contains("LEFT ALONE \(s.path(spared))"), "\(spared): \(s.log.lines)")
        }
    }

    @Test("SWEEP: the name rule")
    func ownMountNames() {
        for own in ["VideoScan_Temp", "VideoScan_Temp 1", "VideoScan_Temp 2", "VideoScan_Temp 37", "VideoScan_Temp 999"] {
            #expect(RAMDisk.isOwnMountName(own), "\(own)")
        }
        for other in ["VideoScan_Temp_Archive", "VideoScan_Temporary", "VideoScan_Temp 1 copy", "VideoScan_Temp ", "VideoScan_Temp  1",
                      "VideoScan_Temp x", "VideoScan_Temp2", "VideoScan_Temp 1000", "VideoScan_Temp -1", "videoscan_temp", "", "Media"] {
            #expect(!RAMDisk.isOwnMountName(other), "\(other)")
        }
    }

    @Test("SWEEP: nothing to detach issues no command; an unreadable /Volumes issues none either")
    func sweepWithNothing() async throws {
        let s = try SweepBench(["Media", "Family Archive"])
        defer { s.cleanup() }
        let mock = ScriptedExecutor(claiming: [s.volumes.path])
        await mock.scoped {
            #expect(RAMDisk.cleanupStaleMounts(volumesDir: s.volumes.path).isEmpty)
            #expect(RAMDisk.cleanupStaleMounts(volumesDir: s.path("no-such-directory")).isEmpty)
        }
        #expect(mock.calls.isEmpty)
    }

    @Test("SWEEP: a detach that fails, hangs or cannot start is not reported detached, is logged, and the sweep still ends",
          arguments: ["exit", "hang", "launch"])
    func sweepDetachFails(_ how: String) async throws {
        let s = try SweepBench(["VideoScan_Temp", "VideoScan_Temp 1"])
        defer { s.cleanup() }
        let failing: ScriptedExecutor.Behaviour = how == "exit" ? .output(stderr: "Resource busy\n", exit: 16)
            : how == "hang" ? Self.hang : .launchFailure
        // The first mount misbehaves; the second detaches cleanly.
        let mock = ScriptedExecutor(claiming: [s.volumes.path])
            .on("hdiutil", where: { $0 == ["detach", s.path("VideoScan_Temp"), "-force"] }, failing)
            .on("hdiutil", containing: ["detach"], .output())
        var detached: [String] = []
        let started = ContinuousClock.now
        await withAppLog(s.log) {
            await mock.scoped { detached = RAMDisk.cleanupStaleMounts(volumesDir: s.volumes.path, timeouts: Self.fast) }
        }
        #expect(ContinuousClock.now - started < .seconds(20), "a wedged hdiutil must not hold the quit")
        #expect(detached == [s.path("VideoScan_Temp 1")], "a failed detach was reported as detached")
        #expect(mock.calls.count == 2)
        let expected = how == "exit" ? "hdiutil exited 16 for \(s.path("VideoScan_Temp"))"
            : how == "hang" ? "hdiutil timed out, exit" : "could not launch hdiutil for \(s.path("VideoScan_Temp"))"
        #expect(s.log.contains(expected), "\(s.log.lines)")
        #expect(s.log.contains("ram disk sweep: done — detached 1"))
    }

    @Test("PARKED (P2): the sweep trusts the NAME — a real volume named exactly VideoScan_Temp would be force-detached")
    func sweepTrustsTheName() async throws {
        let s = try SweepBench(["VideoScan_Temp"])
        defer { s.cleanup() }
        // What a fix would ask first: is this mount a ram:// disk image?
        // Here hdiutil says there are no attached images at all.
        let noImages = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>images</key><array/></dict></plist>\n"
        let mock = ScriptedExecutor(claiming: [s.volumes.path])
            .on("hdiutil", containing: ["info"], .output(stdout: noImages))
            .on("hdiutil", containing: ["detach"], .output())
        await mock.scoped { _ = RAMDisk.cleanupStaleMounts(volumesDir: s.volumes.path) }
        // Severity P2 (no data is deleted; a force-detach of a user's volume
        // mid-write can lose that write). Reserved name: the scan-target
        // screen already hides VideoScan_Temp*. Proposed fix: before the
        // detach, `hdiutil info -plist` and require an image whose
        // image-path starts with ram:// to own the mount point; refuse when
        // it cannot be shown. Needs the real plist shape captured from a
        // live RAM disk on macOS 27 (not done here: it means attaching one
        // on Rick's machine).
        withKnownIssue("P2: cleanupStaleMounts detaches by name alone, without proving the mount is a ram:// image") {
            #expect(mock.calls(to: "hdiutil", containing: ["detach"]).isEmpty,
                    "a mount named VideoScan_Temp that is not a RAM disk was force-detached")
        }
    }
}
