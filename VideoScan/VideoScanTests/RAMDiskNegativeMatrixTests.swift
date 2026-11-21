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
        let mock = b.mock().on("hdiutil", containing: ["attach"], .hang())
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
                #expect(await disk.mount(sizeMB: b.sizeMB) == false, "garbage accepted as a device: \(output.debugDescription)")
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
        #expect(RAMDisk.OwnedDevice(attachOutput: "/dev/disk4          \t         \n")?.node == "/dev/disk4")
        #expect(RAMDisk.OwnedDevice(attachOutput: "/dev/disk27\n")?.node == "/dev/disk27")
        #expect(RAMDisk.OwnedDevice(attachOutput: "/dev/disk1")?.node == "/dev/disk1")
        for bad in Self.garbage + ["/dev/disk04", "/dev/disk1234567", "/dev/disk4s", "/dev/disk-4", "/dev/disk4\u{0}"] {
            #expect(RAMDisk.OwnedDevice(attachOutput: bad) == nil, "\(bad.debugDescription)")
        }
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
            .on("diskutil", .hang())
            .on("hdiutil", containing: ["detach"], .output())
        let disk = RAMDisk(timeouts: Self.fast)
        let sink = b.log
        let size = b.sizeMB
        // Bounded wait: before the deadline existed this mount never
        // returned, so the test must not simply await it.
        let mounting = Task { await withAppLog(sink) { await mock.scoped { await disk.mount(sizeMB: size) } } }
        let finished = await Self.finishes(mounting, within: .seconds(15))
        #expect(finished == false, "mount is still waiting on a hung diskutil (or reported success)")
        mounting.cancel()
        _ = await mounting.value
        #expect(Self.lines(mock) == [Self.line("hdiutil", b.attach), Self.line("diskutil", b.erase), Self.line("hdiutil", b.detach)])
        #expect(b.log.contains("diskutil eraseVolume on \(b.node) failed (timed out"), "\(b.log.lines)")
    }

    /// The task's value if it ends within `limit`, else nil (still running).
    static func finishes(_ task: Task<Bool, Never>, within limit: Duration) async -> Bool? {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(for: limit); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    @Test("the caller is cancelled while eraseVolume runs: the attached device is STILL detached (no leaked RAM device)")
    func cancelledMidFormat() async {
        let b = Bench()
        let mock = b.mock()
            .on("hdiutil", containing: ["attach"], b.attachOutput)
            .on("diskutil", .hang())
            .on("hdiutil", containing: ["detach"], .output())
        let disk = RAMDisk(timeouts: Self.fast)
        let size = b.sizeMB
        let mounting = Task { await mock.scoped { await disk.mount(sizeMB: size) } }
        for _ in 0..<400 where mock.calls(to: "diskutil").isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        mounting.cancel()
        #expect(await mounting.value == false)
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
            : how == "hang" ? .hang() : .launchFailure
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
            : how == "hang" ? .hang() : .launchFailure
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
