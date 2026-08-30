// MediaStreamResolverTests.swift
// Phase 1 remote use, slice 2 — media on the viewer (docs/remote_use_design.md §2).
//
// The resolver matrix: master role → local always; viewer → opted-in
// mounted volume with matching identity → local (re-rooted path); mounted
// but not opted in → stream; opted in but not mounted → stream; opted in,
// mounted, identity mismatch, master offline → honest masterOffline;
// master offline and nothing mounted → masterOffline. URL shapes carry
// the passphrase as a query item (AVPlayer sends no headers). The proxy
// handshake (206 / 202 + status poll / failures) and the ping probe run
// against a stub transport. No test writes anything except the one
// settings key in its own throwaway defaults suite.

import Testing
import Foundation
@testable import VideoScan
import VideoScanCore

private let config = MediaStreamResolver.Configuration(masterHostname: "RicksM4.local", port: 8765, passphrase: "porch pass")

private func viewerResolver(mapped: [String: String] = [:], reachable: Bool,
                            mounted: Set<String> = [], identityOK: Bool = true) -> MediaStreamResolver {
    MediaStreamResolver(role: .viewer(masterHostname: "RicksM4.local"),
                        configuration: config,
                        mappedVolumes: mapped,
                        masterReachable: reachable,
                        isMounted: { mounted.contains($0) },
                        volumeIdentityMatches: { _, _ in identityOK })
}

private let id: UUID = {
    guard let value = UUID(uuidString: "6F0E1E2C-2B0A-4C6B-9B0E-1A2B3C4D5E6F") else {
        preconditionFailure("invalid fixed media resolver UUID")
    }
    return value
}()
private let archivePath = "/Volumes/FamilyArchive/Breen_Family_Archive/1990s/1994/capecod.mxf"
private let mp4Path = "/Volumes/FamilyArchive/Breen_Family_Archive/2000s/2004/beach.mp4"

private func testURL(_ value: String) -> URL {
    guard let url = URL(string: value) else { preconditionFailure("invalid test URL: \(value)") }
    return url
}

private func testDefaults(_ suite: String) -> UserDefaults {
    guard let defaults = UserDefaults(suiteName: suite) else {
        preconditionFailure("could not create test defaults suite: \(suite)")
    }
    return defaults
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

struct MediaStreamResolverMatrixTests {

    @Test func masterRoleIsAlwaysLocalAndIgnoresEverythingElse() {
        let resolver = MediaStreamResolver(role: .master, configuration: config,
                                           mappedVolumes: [:], masterReachable: false,
                                           isMounted: { _ in false })
        #expect(resolver.resolve(recordID: id, fullPath: archivePath, videoCodec: "dvvideo")
                == .local(URL(fileURLWithPath: archivePath)))
        #expect(resolver.resolve(recordID: id, fullPath: "/Users/rickb/Movies/x.mov", videoCodec: "prores")
                == .local(URL(fileURLWithPath: "/Users/rickb/Movies/x.mov")))
    }

    @Test func optedInMountedVolumeWithMatchingIdentityPlaysLocally() {
        let resolver = viewerResolver(mapped: ["FamilyArchive": "/Volumes/FamilyArchive"],
                                      reachable: true, mounted: ["/Volumes/FamilyArchive"])
        #expect(resolver.resolve(recordID: id, fullPath: archivePath, videoCodec: "dvvideo")
                == .local(URL(fileURLWithPath: archivePath)))
    }

    @Test func optedInVolumeMountedUnderAnotherNameIsReRooted() {
        let resolver = viewerResolver(mapped: ["FamilyArchive": "/Volumes/FamilyArchive-1"],
                                      reachable: true, mounted: ["/Volumes/FamilyArchive-1"])
        #expect(resolver.resolve(recordID: id, fullPath: archivePath, videoCodec: "dvvideo")
                == .local(URL(fileURLWithPath: "/Volumes/FamilyArchive-1/Breen_Family_Archive/1990s/1994/capecod.mxf")))
    }

    @Test func mountedButNotOptedInStreams() {
        let resolver = viewerResolver(mapped: [:], reachable: true, mounted: ["/Volumes/FamilyArchive"])
        guard case .stream(let url, let native) = resolver.resolve(recordID: id, fullPath: archivePath, videoCodec: "dvvideo") else {
            Issue.record("expected stream"); return
        }
        #expect(url.absoluteString == "http://ricksm4.local:8765/api/media/\(id.uuidString)?key=porch%20pass")
        #expect(native == false, "MXF needs the master's access copy")
    }

    @Test func optedInButNotMountedStreamsWhenMasterAnswers() {
        let resolver = viewerResolver(mapped: ["FamilyArchive": "/Volumes/FamilyArchive"], reachable: true, mounted: [])
        guard case .stream(_, let native) = resolver.resolve(recordID: id, fullPath: mp4Path, videoCodec: "h264") else {
            Issue.record("expected stream"); return
        }
        #expect(native == true, "MP4 plays as-is")
    }

    @Test func nativeDecisionFollowsTheBridgeRule() {
        #expect(MediaStreamResolver.isNativelyPlayable(fullPath: "/a/b.mp4", videoCodec: "h264"))
        #expect(MediaStreamResolver.isNativelyPlayable(fullPath: "/a/b.mov", videoCodec: "hevc"))
        #expect(!MediaStreamResolver.isNativelyPlayable(fullPath: "/a/b.mov", videoCodec: "prores"))
        #expect(!MediaStreamResolver.isNativelyPlayable(fullPath: "/a/b.mxf", videoCodec: "dvvideo"))
        #expect(MediaStreamResolver.isNativelyPlayable(fullPath: "/a/b.m4a", videoCodec: ""))
    }

    @Test func identityMismatchNeverPlaysTheWrongDiskAndFallsToStreamOrOffline() {
        let mapped = ["FamilyArchive": "/Volumes/FamilyArchive"]
        let online = viewerResolver(mapped: mapped, reachable: true, mounted: ["/Volumes/FamilyArchive"], identityOK: false)
        guard case .stream = online.resolve(recordID: id, fullPath: archivePath, videoCodec: "dvvideo") else {
            Issue.record("a look-alike volume must not be played; stream instead"); return
        }
        let offline = viewerResolver(mapped: mapped, reachable: false, mounted: ["/Volumes/FamilyArchive"], identityOK: false)
        #expect(offline.resolve(recordID: id, fullPath: archivePath, videoCodec: "dvvideo")
                == .masterOffline(masterDisplayName: "RicksM4"))
    }

    @Test func masterUnreachableAndNothingMountedIsAnHonestOfflineState() {
        let resolver = viewerResolver(mapped: ["FamilyArchive": "/Volumes/FamilyArchive"], reachable: false, mounted: [])
        #expect(resolver.resolve(recordID: id, fullPath: archivePath, videoCodec: "dvvideo")
                == .masterOffline(masterDisplayName: "RicksM4"))
        // Internal-disk master paths have no volume to mount; same answer.
        #expect(resolver.resolve(recordID: id, fullPath: "/Users/rickb/Movies/x.mov", videoCodec: "h264")
                == .masterOffline(masterDisplayName: "RicksM4"))
    }

    @Test func urlShapesAndHostNormalisation() {
        let resolver = viewerResolver(reachable: true)
        #expect(resolver.statusURL(recordID: id).absoluteString
                == "http://ricksm4.local:8765/api/media/\(id.uuidString)/status?key=porch%20pass")
        #expect(resolver.pingURL.absoluteString == "http://ricksm4.local:8765/api/ping")
        let bare = MediaStreamResolver.Configuration(masterHostname: "RicksM4", port: 9000, passphrase: "")
        #expect(bare.baseURL.absoluteString == "http://ricksm4.local:9000")
        let noKey = MediaStreamResolver(role: .viewer(masterHostname: "RicksM4"), configuration: bare, masterReachable: true)
        #expect(noKey.streamURL(recordID: id).query == nil, "no passphrase → no key item")
        #expect(MediaStreamResolver.volumeName(ofPath: archivePath) == "FamilyArchive")
        #expect(MediaStreamResolver.volumeName(ofPath: "/Users/rickb/x.mov") == nil)
        #expect(MediaStreamResolver.mappedPath("/Volumes/A/x/y.mov", volumeName: "A", mountPath: "/Volumes/A-1/") == "/Volumes/A-1/x/y.mov")
    }

    @Test func numericAddressesAndNumericBonjourLabelsKeepExactURLShapes() {
        let plain = MediaStreamResolver.Configuration(masterHostname: "2001:DB8::1", port: 8765, passphrase: "")
        let bracketed = MediaStreamResolver.Configuration(masterHostname: "[2001:db8::1]", port: 8765, passphrase: "")
        let scoped = MediaStreamResolver.Configuration(masterHostname: "FE80::A%Bridge0", port: 8765, passphrase: "")
        let ipv4 = MediaStreamResolver.Configuration(
            masterHostname: "192.168.1.10",
            port: 8765,
            passphrase: "porch pass"
        )
        let numericBonjour = MediaStreamResolver.Configuration(masterHostname: "123", port: 8765, passphrase: "")

        #expect(plain.hasValidEndpoint)
        #expect(plain.baseURL.absoluteString == "http://[2001:db8::1]:8765")
        #expect(bracketed.baseURL == plain.baseURL)
        #expect(scoped.baseURL.absoluteString == "http://[fe80::a%25Bridge0]:8765")
        #expect(ipv4.baseURL.absoluteString == "http://192.168.1.10:8765")
        #expect(numericBonjour.baseURL.absoluteString == "http://123.local:8765")

        let resolver = MediaStreamResolver(
            role: .viewer(masterHostname: "192.168.1.10"),
            configuration: ipv4,
            masterReachable: true
        )
        #expect(resolver.streamURL(recordID: id).absoluteString
                == "http://192.168.1.10:8765/api/media/\(id.uuidString)?key=porch%20pass")
    }

    @Test func malformedOrEmptyHostsFailClosedEvenWithStaleReachability() async {
        let poisonedHosts = [
            "", "   ", "http://router", "rick/path", "bad host", "[::1", "foo..bar",
            "999.168.1.10", "192.168.1.999",
        ]
        let requests = RequestCounter()
        let probe = MasterReachabilityProbe(transport: { _ in
            requests.increment()
            return (200, Data("{\"ok\":true}".utf8))
        })

        for hostname in poisonedHosts {
            let bad = MediaStreamResolver.Configuration(masterHostname: hostname, port: 8765, passphrase: "secret")
            #expect(!bad.hasValidEndpoint)
            #expect(bad.baseURL.isFileURL, "an invalid setting must not name any network host")

            let resolver = MediaStreamResolver(
                role: .viewer(masterHostname: hostname),
                configuration: bad,
                masterReachable: true
            )
            guard case .masterOffline = resolver.resolve(
                recordID: id,
                fullPath: archivePath,
                videoCodec: "dvvideo"
            ) else {
                Issue.record("invalid hostname must resolve offline: \(hostname)")
                continue
            }
            #expect(await probe.isReachable(bad) == false)
        }
        #expect(requests.value == 0, "invalid settings must fail before transport")
    }

    @Test func invalidPortsFailClosedBeforeTransport() async {
        let requests = RequestCounter()
        let probe = MasterReachabilityProbe(transport: { _ in
            requests.increment()
            return (200, Data("{\"ok\":true}".utf8))
        })

        for port in [0, 65536] {
            let bad = MediaStreamResolver.Configuration(
                masterHostname: "RicksM4",
                port: port,
                passphrase: "secret"
            )
            #expect(bad.endpointError == .invalidPort)
            #expect(bad.baseURL.isFileURL)

            let resolver = MediaStreamResolver(
                role: .viewer(masterHostname: "RicksM4"),
                configuration: bad,
                masterReachable: true
            )
            guard case .masterOffline = resolver.resolve(
                recordID: id,
                fullPath: archivePath,
                videoCodec: "dvvideo"
            ) else {
                Issue.record("invalid port must resolve offline: \(port)")
                continue
            }
            #expect(await probe.isReachable(bad) == false)
        }
        #expect(requests.value == 0, "invalid ports must fail before transport")
    }

    @Test func passphraseIsOneEncodedQueryValueNotURLSyntax() {
        let special = "porch pass&next=?/# ü"
        let configuration = MediaStreamResolver.Configuration(
            masterHostname: "RicksM4",
            port: 8765,
            passphrase: special
        )
        let resolver = MediaStreamResolver(
            role: .viewer(masterHostname: "RicksM4"),
            configuration: configuration,
            masterReachable: true
        )
        let stream = resolver.streamURL(recordID: id)
        let status = resolver.statusURL(recordID: id)

        #expect(URLComponents(url: stream, resolvingAgainstBaseURL: false)?.queryItems
                == [URLQueryItem(name: "key", value: special)])
        #expect(URLComponents(url: status, resolvingAgainstBaseURL: false)?.queryItems
                == [URLQueryItem(name: "key", value: special)])
        #expect(stream.host == "ricksm4.local")
        #expect(stream.path == "/api/media/\(id.uuidString)")
        #expect(status.path == "/api/media/\(id.uuidString)/status")
    }

    @Test func configurationReadsTheHallieWebKeysAndSanitisesThePort() {
        let suite = "MediaStreamResolverTests.\(UUID().uuidString)"
        let defaults = testDefaults(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("secret", forKey: HallieWebAccess.passphraseKey)
        defaults.set(70000, forKey: HallieWebAccess.portKey)
        let c = MediaStreamResolver.Configuration.fromDefaults(defaults, masterHostname: "RicksM4.local")
        #expect(c.passphrase == "secret")
        #expect(c.port == HallieWebAccess.defaultPort, "out-of-range port falls back")
    }

    /// Resolving reads settings and never writes: a poisoned suite stays
    /// byte-identical, and a throwaway App Support root stays empty.
    @Test func resolvingWritesNothing() throws {
        let suite = "MediaStreamResolverTests.nowrite.\(UUID().uuidString)"
        let defaults = testDefaults(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["FamilyArchive": "/Volumes/Nope"], forKey: ViewerMediaSettings.mountedVolumesKey)
        defaults.set("garbage", forKey: HallieWebAccess.portKey)
        let before = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("viewer.") || $0.key.hasPrefix("archivist.") }
        let settings = ViewerMediaSettings(defaults: defaults)
        let resolver = MediaStreamResolver(role: .viewer(masterHostname: "RicksM4.local"),
                                           configuration: .fromDefaults(defaults, masterHostname: "RicksM4.local"),
                                           mappedVolumes: settings.mappedVolumes,
                                           masterReachable: false,
                                           isMounted: { _ in false })
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("msr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for _ in 0..<50 {
            _ = resolver.resolve(recordID: UUID(), fullPath: archivePath, videoCodec: "dvvideo")
            _ = resolver.resolve(recordID: UUID(), fullPath: mp4Path, videoCodec: "h264")
        }
        let after = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("viewer.") || $0.key.hasPrefix("archivist.") }
        #expect(NSDictionary(dictionary: before) == NSDictionary(dictionary: after))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        // The one write there is: the settings toggle, into its own suite.
        settings.setOptedIn(true, volumeName: "X9")
        #expect(settings.mountPath(for: "X9") == "/Volumes/X9")
        settings.setOptedIn(false, volumeName: "X9")
        #expect(!settings.isOptedIn("X9"))
    }
}

// MARK: - Transport-level pieces

struct MediaStreamClientTests {
    private static func transport(_ script: @escaping @Sendable (URLRequest) -> (Int, String)) -> MediaHTTPTransport {
        { request in let (s, b) = script(request); return (s, Data(b.utf8)) }
    }

    @Test func nativeBytesAreReadyAtOnce() async {
        let client = MediaStreamClient(transport: Self.transport { _ in (206, "") }, sleep: { _ in })
        let r = await client.prepare(
            streamURL: testURL("http://m/api/media/x"),
            statusURL: testURL("http://m/api/media/x/status")
        )
        #expect(r == .ready)
    }

    @Test func proxyHandshakePollsStatusUntilReady() async {
        let counter = Counter()
        let client = MediaStreamClient(transport: Self.transport { request in
            if request.url?.path.hasSuffix("/status") == true {
                let n = counter.next()
                return n < 3 ? (200, "{\"state\":\"preparing\",\"seconds\":\(n * 2)}") : (200, "{\"state\":\"ready\",\"native\":false}")
            }
            return (202, "{\"state\":\"preparing\",\"seconds\":0}")
        }, sleep: { _ in }, pollInterval: .milliseconds(1), maximumPolls: 10)
        let seen = Counter()
        let r = await client.prepare(streamURL: testURL("http://m/api/media/x"),
                                     statusURL: testURL("http://m/api/media/x/status"),
                                     onProgress: { _ in _ = seen.next() })
        #expect(r == .ready)
        #expect(seen.value == 2, "two 'preparing' ticks were reported")
    }

    @Test func failuresAreNamedNotSwallowed() async {
        let statusURL = testURL("http://m/api/media/x/status")
        let failed = MediaStreamClient(transport: Self.transport { request in
            request.url?.path.hasSuffix("/status") == true
                ? (200, "{\"state\":\"failed\",\"reason\":\"ffmpeg exit 1\"}")
                : (202, "{}")
        }, sleep: { _ in }, pollInterval: .milliseconds(1))
        #expect(await failed.prepare(streamURL: testURL("http://m/api/media/x"), statusURL: statusURL)
                == .failed(reason: "ffmpeg exit 1"))

        let refused = MediaStreamClient(transport: Self.transport { _ in (401, "passphrase") }, sleep: { _ in })
        guard case .failed(let why) = await refused.prepare(streamURL: testURL("http://m/x"), statusURL: statusURL) else {
            Issue.record("expected failure"); return
        }
        #expect(why.contains("passphrase"))

        let macOnly = MediaStreamClient(transport: Self.transport { _ in (415, "this one plays on the Mac only") }, sleep: { _ in })
        #expect(await macOnly.prepare(streamURL: testURL("http://m/x"), statusURL: statusURL)
                == .failed(reason: "this one plays on the Mac only"))

        let dead = MediaStreamClient(transport: { _ in throw URLError(.cannotConnectToHost) }, sleep: { _ in })
        #expect(await dead.prepare(streamURL: testURL("http://m/x"), statusURL: statusURL)
                == .failed(reason: "the master did not answer"))

        let stuck = MediaStreamClient(transport: Self.transport { _ in (202, "{\"state\":\"preparing\"}") },
                                      sleep: { _ in }, pollInterval: .milliseconds(1), maximumPolls: 3)
        #expect(await stuck.prepare(streamURL: testURL("http://m/x"), statusURL: statusURL) == .timedOut)
    }

    @Test func pingProbeIsHonest() async {
        let ok = MasterReachabilityProbe(transport: Self.transport { _ in (200, "{\"ok\":true,\"name\":\"Hallie\"}") })
        #expect(await ok.isReachable(config) == true)
        let wrongPage = MasterReachabilityProbe(transport: Self.transport { _ in (200, "<html>router</html>") })
        #expect(await wrongPage.isReachable(config) == false)
        let down = MasterReachabilityProbe(transport: { _ in throw URLError(.timedOut) })
        #expect(await down.isReachable(config) == false)
    }

    @Test @MainActor func statusLabelsFollowTheProbe() async {
        let status = ViewerMediaStatus()
        #expect(status.label == "checking…")
        _ = await status.refresh(configuration: config, probe: MasterReachabilityProbe(transport: Self.transport { _ in (200, "{\"ok\":true}") }))
        #expect(status.label == "streaming")
        _ = await status.refresh(configuration: config, probe: MasterReachabilityProbe(transport: { _ in throw URLError(.timedOut) }))
        #expect(status.label == "master offline")
        #expect(status.lastChecked != nil)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int { lock.withLock { n += 1; return n } }
        var value: Int { lock.withLock { n } }
    }
}
