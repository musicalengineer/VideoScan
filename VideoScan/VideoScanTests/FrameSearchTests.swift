// FrameSearchTests.swift — the Observations window's Frames mode
// (Observations/FrameSearch/; docs/design/file_dossier_view.md §II.7).
// Streamlined (Rick 11/06: an experiment), the dimensions that apply — the
// pure index logic (top-k, cache key, scope, the on-disk truth and
// isolation) is in Core's FrameIndexTests; here:
//   PARITY     the native MLX SigLIP 2 matches the reference implementation
//              (transformers' SiglipModel, fp32) on synthetic cards: the
//              same token ids, cosine ≥ 0.99 per vector. Needs the public
//              weights in ~/.cache/huggingface — SKIPPED (counted as such)
//              when they are absent.
//   SMOKE      three synthetic clips (ffmpeg lavfi: solid red, solid blue,
//              a white card with black text) through the job's one engine
//              (the captioner's frame door + SigLIP 2): "a red image" ranks
//              the red clip first. Skipped without weights or ffmpeg.
//   TRUTH      a store hit names the file and time of the index row whose
//              vector produced it; a content outside the scope is never shown.
//   ISOLATION  no index / an unreadable index → "Index not built" and no
//              hits, never a crash or stale rows.
//   JOB        the MFO job indexes the files with a picture, skips a drive
//              that is not connected (not a try), records an undecodable
//              file, and a second run resumes with nothing to do.
//   SENSOR     no `extension VideoScanModel`; nothing in FrameSearch/ writes
//              the catalog; the window still observes stores only.
// Synthetic pictures and names only.

import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Fixtures

private enum Cards {
    /// A solid sRGB card.
    static func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, size: Int = 224) -> CGImage {
        pixels(size: size) { _, _ in (r, g, b) }
    }

    /// The reference fixture's gradient: green = x, blue = y.
    static func gradient(size: Int = 224) -> CGImage {
        pixels(size: size) { x, y in (0, UInt8(x), UInt8(y)) }
    }

    static func pixels(size: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size { for x in 0..<size {
            let (r, g, b) = f(x, y)
            let i = (y * size + x) * 4
            bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b
        } }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}

private struct Reference: Decodable {
    struct Text: Decodable { let text: String; let ids: [Int]; let vector: [Float] }
    struct Card: Decodable { let card: String; let vector: [Float] }
    let model: String
    let texts: [Text]
    let images: [Card]

    static func load() throws -> Reference {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/siglip2_reference.json")
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }
}

private func cosine(_ a: [Float], _ b: [Float]) -> Float {
    let dot = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    let na = a.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot(), nb = b.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
    return dot / (na * nb)
}

/// Unit vectors along an axis, for a deterministic stub model.
private struct StubEmbedder: FrameEmbedding {
    let modelID = "test/stub-siglip"
    let dims = 8
    var imageVector: @Sendable (CGImage) -> [Float] = { image in
        var v = [Float](repeating: 0, count: 8)
        v[min(7, image.width % 8)] = 1   // the card's width picks the axis
        return v
    }
    func embed(images: [CGImage]) async throws -> [[Float]] { images.map(imageVector) }
    func embed(text: String) async throws -> [Float] {
        var v = [Float](repeating: 0, count: 8)
        v[min(7, Int(text.split(separator: " ").last.flatMap { Int($0) } ?? 0))] = 1   // "axis 3" → axis 3
        return v
    }
}

private enum Env {
    static let weights = SigLIPConfig.hubCacheSnapshot() != nil
    static let ffmpeg = FileManager.default.isExecutableFile(atPath: ToolLocator.ffmpegPath)

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("framesearch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func row(_ n: Int, path: String, stream: String = "Video+Audio", duration: Double = 10) -> CatalogRow.FrameIndexFile {
        CatalogRow.FrameIndexFile(digest: String(format: "%064x", n), fileID: String(format: "00000000-0000-0000-0000-%012X", n),
                                  filename: (path as NSString).lastPathComponent, path: path, removed: false, durationSeconds: duration, streamType: stream)
    }

    @MainActor
    static func loader(status: FrameIndexStatus, rows: [CatalogRow.FrameIndexFile], embedder: StubEmbedder = StubEmbedder()) -> FrameSearchLoader {
        FrameSearchLoader(modelID: embedder.modelID, loadIndex: { status }, files: { _ in rows },
                          embedText: { try await embedder.embed(text: $0) }, prewarm: {}, thumbnail: { _, _ in nil },
                          startIndex: { _, _ in nil }, reveal: { _ in true }, note: { _ in })
    }
}

// MARK: - Parity and smoke (real model)

@Suite("SigLIP 2 — native MLX parity and smoke", .serialized, .enabled(if: Env.weights, "SigLIP 2 weights are not in ~/.cache/huggingface"))
struct SigLIPEmbedderTests {

    @Test func tokensAndVectorsMatchTheReferenceImplementation() async throws {
        let ref = try Reference.load()
        let embedder = SigLIPEmbedder.shared
        #expect(ref.model == embedder.modelID)
        for t in ref.texts {
            let ids = try await embedder.tokenIDs(t.text)
            #expect(ids == t.ids, "Gemma tokenizer ids for \"\(t.text)\"")
            let v = try await embedder.embed(text: t.text)
            #expect(v.count == 768)
            let c = cosine(v, t.vector)
            #expect(c >= 0.99, "text \"\(t.text)\": cosine \(c) with the reference")
        }
        let cards = ["red": Cards.solid(255, 0, 0), "gradient_g_x_b_y": Cards.gradient()]
        for card in ref.images {
            let image = try #require(cards[card.card])
            let v = try #require(try await embedder.embed(images: [image]).first)
            let c = cosine(v, card.vector)
            #expect(c >= 0.99, "image \(card.card): cosine \(c) with the reference")
        }
    }

    @Test(.enabled(if: Env.ffmpeg, "ffmpeg is not installed"))
    func aRedImageRanksTheRedClipFirst() async throws {
        let dir = try Env.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clips: [(String, String)] = [("red.mp4", "color=c=red:s=320x240:d=2"),
                                         ("blue.mp4", "color=c=blue:s=320x240:d=2"),
                                         ("card.mp4", "color=c=white:s=320x240:d=2,drawtext=text='HELLO':fontsize=60:fontcolor=black:x=40:y=90")]
        var b = FrameIndexBuilder(model: SigLIPConfig.modelID, dims: SigLIPConfig.dims)
        var digests: [String: String] = [:]
        for (n, (name, source)) in clips.enumerated() {
            let path = dir.appendingPathComponent(name).path
            var made = await ProcessRunner.runProcess(executable: ToolLocator.ffmpegPath,
                                                      arguments: ["-v", "error", "-f", "lavfi", "-i", source, "-pix_fmt", "yuv420p", "-y", path], deadlineSeconds: 60)
            if made.exitCode != 0, source.contains("drawtext") {
                // An ffmpeg without libfreetype: a grey card stands in for the text card.
                made = await ProcessRunner.runProcess(executable: ToolLocator.ffmpegPath,
                                                      arguments: ["-v", "error", "-f", "lavfi", "-i", "color=c=gray:s=320x240:d=2", "-pix_fmt", "yuv420p", "-y", path],
                                                      deadlineSeconds: 60)
            }
            try #require(made.exitCode == 0, "ffmpeg made \(name): \(made.stderr)")
            let digest = String(format: "%064x", n + 1)
            digests[digest] = name
            let frames = try await FrameIndexEngine.frames(path: path, durationSeconds: 2, framesPerFile: 2,
                                                           extract: FrameIndexEngine.productionExtract, embedder: SigLIPEmbedder.shared)
            #expect(frames.count == 2)
            b.add(digest: digest, frames: frames)
        }
        let query = try await SigLIPEmbedder.shared.embed(text: "a red image")
        let hits = FrameSearch.topK(query: query, in: b.snapshot(), k: 6, perContent: 1)
        #expect(hits.map { digests[$0.entry.digest] ?? "?" }.first == "red.mp4", "ranking: \(hits.map { "\(digests[$0.entry.digest] ?? "?") \($0.score)" })")
        let blue = FrameSearch.topK(query: try await SigLIPEmbedder.shared.embed(text: "a blue image"), in: b.snapshot(), k: 1)
        #expect(blue.first.map { digests[$0.entry.digest] } == "blue.mp4")
    }
}

// MARK: - Store: truth and isolation (stub model)

@Suite("Frames mode — the store") @MainActor
struct FrameSearchStoreTests {

    /// Content n has one frame along axis n at n seconds.
    static func index(_ ns: [Int]) -> FrameIndex {
        var b = FrameIndexBuilder(model: "test/stub-siglip", dims: 8)
        for n in ns {
            var v = [Float](repeating: 0, count: 8); v[n] = 1
            b.add(digest: String(format: "%064x", n), frames: [(Double(n), v), (Double(n) + 0.5, v.map { $0 * 0.5 + 0.1 })])
        }
        return b.snapshot()
    }

    @Test func aHitNamesTheFileAndTimeOfTheRowThatProducedItAndStaysInScope() async {
        let rows = [Env.row(2, path: "/V/a/two.mov"), Env.row(3, path: "/V/a/three.mov")]   // content 5 is indexed but out of scope
        let store = FrameSearchStore(scope: .folder("/V/a"), loader: Env.loader(status: .ready(Self.index([2, 3, 5])), rows: rows))
        await store.loadIndex()
        #expect(store.indexState == .ready(frames: 6, contents: 3))
        await store.search("axis 3")
        let top = store.hits.first
        #expect(top != nil)
        #expect(top?.digest == String(format: "%064x", 3) && top?.seconds == 3 && top?.filename == "three.mov" && top?.path == "/V/a/three.mov")
        #expect((top?.score ?? 0) > 0.999)
        #expect(top?.sourceWords == "SigLIP 2 (test/stub-siglip), similarity 1.00")
        #expect(store.hits.allSatisfy { $0.digest != String(format: "%064x", 5) }, "content 5 is outside the scope")
        await store.search("axis 5")
        #expect(store.hits.allSatisfy { $0.digest != String(format: "%064x", 5) })
        #expect(store.hits.count <= FrameSearchStore.perContent * rows.count)
        #expect(store.timing?.contains("frames in scope") == true)
    }

    @Test func noIndexOrAnUnreadableOneIsIndexNotBuiltAndNoHits() async {
        for status in [FrameIndexStatus.notBuilt, .unreadable("the matrix is 6 bytes; 3 frames × 8 need 48")] {
            let store = FrameSearchStore(scope: .everything, loader: Env.loader(status: status, rows: [Env.row(1, path: "/V/x.mov")]))
            await store.loadIndex()
            guard case .notBuilt(let words) = store.indexState else { Issue.record("\(status) must read as not built"); continue }
            #expect(words.hasPrefix("Index not built"))
            if case .unreadable = status { #expect(words.contains("6 bytes"), "the reason is shown") }
            await store.search("axis 1")
            #expect(store.hits.isEmpty && store.failure == nil, "no stale or partial hits")
        }
    }
}

// MARK: - The job (stub decode, stub model)

@Suite("Frames mode — Index Frames job") @MainActor
struct FrameIndexJobTests {

    @Test func indexesPicturesSkipsOfflineRecordsUndecodableAndResumes() async throws {
        let root = try Env.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = [Env.row(1, path: "/V/ok.mov"), Env.row(2, path: "/V/song.wav", stream: "Audio only"),
                    Env.row(3, path: "/Offline/tape.dv"), Env.row(4, path: "/V/broken.mov"), Env.row(5, path: "/V/ok2.mov", duration: 3)]
        func job() -> FrameIndexJob {
            let j = FrameIndexJob(scope: .everything, loadFiles: { _ in rows }, embedder: StubEmbedder())
            j.root = root
            j.framesPerFile = 3
            j.volumeOnline = { !$0.hasPrefix("/Offline") }
            j.fileExists = { _ in true }
            j.note = { _ in }
            j.extract = { path, times in
                times.map { ($0, path.contains("broken") ? nil : Cards.solid(9, 9, 9, size: 16 + Int($0.rounded()) % 8)) }
            }
            return j
        }
        let first = job()
        first.start()
        await first.task?.value
        guard case .finished(let summary) = first.state else { Issue.record("job did not finish: \(first.state)"); return }
        #expect(first.indexed == 2 && first.unreadable == 1 && first.offline == 1, "\(summary)")
        let index = try #require(FrameIndexStore.load(root: root, model: "test/stub-siglip").index)
        #expect(index.indexedDigests == [String(format: "%064x", 1), String(format: "%064x", 5)])
        #expect(index.count == 6, "3 frames per file")
        #expect(index.failures[String(format: "%064x", 4)]?.contains("no frame") == true)
        #expect(index.entries.filter { $0.digest == String(format: "%064x", 1) }.map(\.seconds) == FrameIndexEngine.timestamps(durationSeconds: 10, framesPerFile: 3).map { FrameIndexEntry(digest: "", seconds: $0).seconds },
                "the rows carry the times the engine decoded")

        let second = job()
        second.start()
        await second.task?.value
        #expect(second.planned == 1, "only the offline file is left (the undecodable one is recorded, not retried)")
        #expect(second.indexed == 0 && second.offline == 1)
    }
}

// MARK: - Sensor

@Suite("Frames mode — sensors")
struct FrameSearchSensorTests {

    private let files = ["SigLIPEmbedder.swift", "FrameIndexJob.swift", "FrameSearchStore.swift", "FrameSearchView.swift"]

    @Test func noModelExtensionAndNothingWritesTheCatalog() throws {
        for file in files {
            let src = try SourceTree.appCode(named: file)
            #expect(!src.contains("extension VideoScanModel"), "rule 12: \(file)")
            for forbidden in ["repository.write", "commit(as", "writeBlocking", "INSERT", "UPDATE ", "saveCatalog", ".records"] {
                #expect(!src.contains(forbidden), "\(file): `\(forbidden)` — the frame index never writes the catalog or walks records")
            }
        }
        let view = try SourceTree.appCode(named: "FrameSearchView.swift")
        #expect(!view.contains("@EnvironmentObject") && !view.contains("model.") && !view.contains(".yellow"))
        #expect(try SourceTree.appCode(named: "FrameSearchStore.swift").contains("repository.read {"), "the catalog through the read door only")
    }
}

// MARK: - Mockup (rendered from the real view, synthetic cards)

@Suite("Frames mode — the view renders (mockup)") @MainActor
struct FrameSearchMockupTests {

    @Test func framesDark() async throws {
        // Twelve synthetic "frames": colour cards with a word drawn on them (no family pixels).
        let words = ["cake", "candles", "beach", "snow", "dog", "tree", "boat", "table", "presents", "baby", "lake", "party"]
        var b = FrameIndexBuilder(model: SigLIPConfig.modelID, dims: 8)
        var thumbs: [String: CGImage] = [:]
        var rows: [CatalogRow.FrameIndexFile] = []
        for (i, word) in words.enumerated() {
            var v = [Float](repeating: 0.05, count: 8); v[0] = 1 - Float(i) * 0.06
            let digest = String(format: "%064x", i + 1)
            b.add(digest: digest, frames: [(Double(30 + i * 17), v)])
            rows.append(Env.row(i + 1, path: "/Volumes/Synthetic/Tape_\(String(format: "%02d", i + 1))_\(word).mov"))
            thumbs[FrameIndex.cacheKey(model: SigLIPConfig.modelID, digest: digest, seconds: Double(30 + i * 17))] = Self.card(word, hue: Double(i) / 12)
        }
        let index = b.snapshot()
        let fixedRows = rows
        let loader = FrameSearchLoader(modelID: SigLIPConfig.modelID, loadIndex: { .ready(index) }, files: { _ in fixedRows },
                                       embedText: { _ in [1, 0, 0, 0, 0, 0, 0, 0] }, prewarm: {}, thumbnail: { _, _ in nil },
                                       startIndex: { _, _ in nil }, reveal: { _ in true }, note: { _ in })
        let store = FrameSearchStore(scope: .everything, loader: loader)
        await store.loadIndex()
        await store.search("a birthday cake with candles")
        #expect(store.hits.count == 12)
        let view = VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Observations").font(.title2.weight(.semibold))
                Text("· everything in the catalog").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text("Words | **Frames**").font(.callout)
            }
            Text("🔍  a birthday cake with candles").padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08)).cornerRadius(7)
            FrameSearchView(frames: store, dossiers: nil, mockupThumbnails: thumbs)
            Text("MOCKUP — rendered from the real view with synthetic cards and names").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 980, alignment: .top)
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark).background(Color(white: 0.12)))
        renderer.scale = 2
        var rendered: CGImage?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { rendered = renderer.cgImage }
        let image = try #require(rendered)
        #expect(image.width == 1960 && image.height > 600)
        let dir = ProcessInfo.processInfo.environment["VIDEOSCAN_MOCKUP_DIR"]
            ?? (try? JSONSerialization.jsonObject(with: Data(contentsOf: FrameIndexStore.productionRoot.appendingPathComponent("realrun.json"))) as? [String: Any])?["queriesOut"] as? String
        if let dir, !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("MOCKUP-observations-frames-dark.png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
        }
    }

    static func card(_ word: String, hue: Double) -> CGImage {
        let w = 320, h = 180
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let c = NSColor(hue: hue, saturation: 0.45, brightness: 0.7, alpha: 1)
        ctx.setFillColor(c.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (word as NSString).draw(at: NSPoint(x: 24, y: 70), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 40), .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }
}
