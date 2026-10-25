// Swift6IsolationStage567Tests.swift
// Pins for the Swift 6 stage 5–7 isolation fixes in People/, FamilyTree/
// and Hallie/ (2026-10-25). The compiler's data-race proof is the red
// (87 warnings in those modules); these tests pin that the refactors which
// moved shared state behind a lock or into a parameter kept behaviour
// byte-for-byte. Dimensions: logic (parity with the serial builders and
// with the old captured-var shapes), scale (a 3 MiB ranged stream = three
// 1 MiB steps; 2,500-record snapshot capture across 40 batch yields),
// isolation (temp files only; an ephemeral loopback port; nothing of the
// catalog is read), sensor (the web server answers a request that arrives
// in two TCP segments — the shape the lock-owned buffer exists for).

import Foundation
import Network
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Swift 6 stage 5–7 isolation pins")
struct Swift6IsolationStage567Tests {

    // MARK: HallieWebServer — the request buffer is lock-owned; the stream offset is a parameter

    /// A request split across two TCP writes must be reassembled. Before
    /// 2026-10-25 the bytes lived in a captured `var` shared by the
    /// @Sendable receive completions; now an `OSAllocatedUnfairLock<Data>`
    /// owns them. Same observable contract: one request, one response.
    @MainActor
    @Test func aRequestArrivingInTwoSegmentsIsReassembled() async throws {
        let server = HallieWebServer { request, _ in
            guard request.path == "/api/echo" else { return .text(404, "no") }
            return .json(["body": String(decoding: request.body, as: UTF8.self), "ok": true])
        }
        try server.start(port: 0)
        defer { server.stop() }
        let head = "POST /api/echo HTTP/1.1\r\nHost: test\r\nContent-Length: 5\r\n\r\n"
        let reply = try await Self.rawExchange(
            port: server.port,
            segments: [Data(head.utf8), Data("hello".utf8)],
            gap: .milliseconds(80))
        let text = String(decoding: reply, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"), "got: \(text.prefix(80))")
        #expect(text.hasSuffix("\r\n\r\n{\"body\":\"hello\",\"ok\":true}"), "got: \(text.suffix(80))")
    }

    /// 3 MiB file, a 2.5 MiB range from offset 256 KiB: three 1 MiB steps,
    /// each carrying its offset as a parameter (the old shared `var offset`
    /// is gone). The bytes are position-dependent, so a step served twice,
    /// skipped or out of order changes the payload.
    @MainActor
    @Test func aRangedStreamWalksEveryChunkInOrder() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stage567-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("media.bin")
        let total = 3 << 20
        var bytes = Data(count: total)
        bytes.withUnsafeMutableBytes { raw in
            for i in 0..<raw.count { raw[i] = UInt8(truncatingIfNeeded: i &* 31 &+ (i >> 8)) }
        }
        try bytes.write(to: file)
        let start = Int64(256 << 10)
        let end = start + Int64(5 << 19)   // 2.5 MiB
        let server = HallieWebServer { _, _ in
            HallieHTTPResponse(status: 206, reason: "Partial Content",
                               headers: [("Content-Type", "application/octet-stream")],
                               body: .file(file, range: start..<end, totalLength: Int64(total)))
        }
        try server.start(port: 0)
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/media")!
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 206)
        #expect(data.count == Int(end - start))
        #expect(data == bytes[Int(start)..<Int(end)])
    }

    /// Writes `segments` with `gap` between them, then reads until the
    /// server closes the connection (it always does: `Connection: close`).
    private static func rawExchange(port: UInt16, segments: [Data], gap: Duration) async throws -> Data {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: DispatchQueue(label: "stage567.raw-client"))
        defer { connection.cancel() }
        for (i, segment) in segments.enumerated() {
            if i > 0 { try await Task.sleep(for: gap) }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                connection.send(content: segment, completion: .contentProcessed { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                })
            }
        }
        var received = Data()
        while true {
            let step: (data: Data?, complete: Bool)
            do {
                step = try await withCheckedThrowingContinuation { cont in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                        if let error { cont.resume(throwing: error) } else { cont.resume(returning: (data, isComplete)) }
                    }
                }
            } catch {
                // The server's close can surface as an error after the last
                // bytes; a non-empty reply is the result, an empty one is not.
                if received.isEmpty { throw error }
                break
            }
            if let data = step.data { received.append(data) }
            if step.complete || step.data == nil { break }
        }
        return received
    }

    // MARK: Hallie record snapshots — built in the caller's isolation

    /// `capture` and the `init(record:)`s lost their `@MainActor`: a
    /// `VideoRecord` is not Sendable, so only its owner can call them, and
    /// the read happens inline there. Same records → the same snapshots in
    /// record order, whether the owner is the main actor or a detached
    /// task; the batch yield still walks every record (2,500 / 64 = 40
    /// yields).
    @Test func snapshotCaptureIsOrderPreservingFromAnyIsolation() async {
        let n = 2_500
        let onMain = await Self.captureOnMain(n)
        let detached = await Task.detached { () -> ([ArchivistPresenceRecordSnapshot], [ArchivistAggregateRecordSnapshot]) in
            let records = Self.records(n)
            let presence = await ArchivistPresenceRecordSnapshot.capture(records, batchSize: 64)
            let aggregate = await ArchivistAggregateRecordSnapshot.capture(records, batchSize: 64)
            return (presence, aggregate)
        }.value
        // Each isolation built its own records (fresh UUIDs), so compare the
        // captured facts, not the ids.
        let paths = (0..<n).map { "/v/clip-\($0).mp4" }
        #expect(onMain.0.count == n)
        #expect(onMain.1.count == n)
        #expect(onMain.0.map(\.fullPath) == paths)
        #expect(onMain.1.map(\.fullPath) == paths)
        #expect(detached.0.map(\.fullPath) == paths)
        #expect(detached.1.map(\.fullPath) == paths)
        #expect(onMain.0.map(\.filename) == detached.0.map(\.filename))
        #expect(onMain.1.map(\.filename) == detached.1.map(\.filename))
    }

    @MainActor
    private static func captureOnMain(_ n: Int) async -> ([ArchivistPresenceRecordSnapshot], [ArchivistAggregateRecordSnapshot]) {
        let records = records(n)
        return (await ArchivistPresenceRecordSnapshot.capture(records, batchSize: 64),
                await ArchivistAggregateRecordSnapshot.capture(records, batchSize: 64))
    }

    /// Built inside the caller's isolation on purpose: a VideoRecord never
    /// crosses a boundary in this test (that is the contract under test).
    private static func records(_ n: Int) -> [VideoRecord] {
        (0..<n).map { i in
            let r = VideoRecord()
            r.fullPath = "/v/clip-\(i).mp4"
            r.directory = "/v"
            r.filename = "clip-\(i).mp4"
            return r
        }
    }

    // MARK: FamilyTreeLaunchBundle.build — lock-owned partial result

    /// The four parallel jobs now move their results into one lock-owned
    /// struct instead of six `withUnsafeMutablePointer` slots; every part
    /// must still equal its serial builder.
    @Test func bundlePartsEqualTheirSerialBuilders() {
        let graph = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 2_000))
        let speakers = HallieTurnExecutor.Speakers(ownerName: "Rick Breen", archivistName: "Hallie",
                                                   archivistPersonName: nil, ownerFamilySearchID: nil)
        let settings = FamilyTreeLaunchBundle.Settings(speakers: speakers, ownerFamilySearchID: nil)
        let bundle = FamilyTreeLaunchBundle.build(graph: graph, settings: settings)
        #expect(bundle.rows == FamilyTreeLiveModel.sidebarRows(of: graph))
        #expect(bundle.identity == FamilyAssetIdentityDirectory(graph: graph, speakers: speakers))
        #expect(bundle.search == FamilyTreeNameSearch(graph: graph))
        let anchors = FamilyTreeLiveModel.anchors(in: graph, ownerFamilySearchID: nil)
        #expect(!anchors.isEmpty)
        #expect(bundle.anchors == anchors)
        #expect(bundle.anchorsCaption == FamilyTreeLiveModel.staleOwnerPinCaption(in: graph, ownerFamilySearchID: nil))
        #expect(Set(bundle.anchorIndexes.keys) == Set(anchors.map(\.id)))
        for anchor in anchors {
            #expect(bundle.anchorIndexes[anchor.id]?.depths
                    == GedcomFamilyGraph.AncestorIndex(graph: graph, descendantID: anchor.id).depths)
        }
    }
}
