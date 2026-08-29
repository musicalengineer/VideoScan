// MediaStreamResolver.swift
// Where a catalog record's bytes come from on a remote viewer (Phase 1,
// docs/remote_use_design.md §2). Catalog paths are master-local
// (`/Volumes/FamilyArchive/…`); the porch Mac has none of those drives.
//
// Resolution order, per record:
//   1. The record's volume is opted in for SMB mapping (Storage tab, per
//      volume), is mounted here under the mapped name, and — when the
//      catalog knows the volume's identity — carries the same volume UUID:
//      play the LOCAL file (full quality, scrubbing). Opt-in is explicit
//      intent, so it beats streaming when both are possible.
//   2. The master answers `/api/ping`: stream from the master's Hallie web
//      server — the same `/api/media/<id>` endpoint the iPad page uses,
//      with HTTP Range support and the on-demand 720p access copy for
//      tapes AVPlayer can't decode (HallieWebProxy). AVPlayer and VLC both
//      take an http URL.
//   3. Otherwise `masterOffline` — an honest state the UI shows as such,
//      never a spinner or a fake "file not found".
//
// On the master every record resolves to its local file, byte-for-byte
// what `MediaOpener` did before this file existed.
//
// Nothing here writes: no cache, no settings save (the toggle in the
// Storage tab writes the one defaults key through `ViewerMediaSettings`).
// The reachability probe and the HTTP transport are injected so the
// matrix is unit-tested without a socket.

import Foundation
import Combine

/// The per-volume SMB opt-in, persisted in the viewer's own defaults.
/// Key: `viewer.smbMountedVolumes` → `[volumeName: mountPath]`. The mount
/// path defaults to `/Volumes/<name>`; Rick can point a volume at
/// `/Volumes/FamilyArchive-1` when macOS renamed the mount.
struct ViewerMediaSettings {
    static let mountedVolumesKey = "viewer.smbMountedVolumes"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// volumeName → mount path for every opted-in volume.
    var mappedVolumes: [String: String] {
        (defaults.dictionary(forKey: Self.mountedVolumesKey) as? [String: String]) ?? [:]
    }

    func mountPath(for volumeName: String) -> String? { mappedVolumes[volumeName] }

    func isOptedIn(_ volumeName: String) -> Bool { mappedVolumes[volumeName] != nil }

    /// The one write in this file — the Storage tab toggle. Harmless on a
    /// viewer: it is the viewer's OWN preference, never synced data.
    func setOptedIn(_ optedIn: Bool, volumeName: String, mountPath: String? = nil) {
        var map = mappedVolumes
        if optedIn {
            map[volumeName] = mountPath ?? "/Volumes/\(volumeName)"
        } else {
            map[volumeName] = nil
        }
        defaults.set(map, forKey: Self.mountedVolumesKey)
    }
}

/// One record's playback source.
enum MediaPlaybackSource: Equatable, Sendable {
    /// A file on this Mac (the master's own disk, or an opted-in SMB mount).
    case local(URL)
    /// The master's web endpoint. `native` = AVPlayer can play the bytes
    /// as-is; false = the master must prepare an access copy first
    /// (`MediaStreamClient.prepare`).
    case stream(URL, native: Bool)
    /// Not mounted here and the master is not answering.
    case masterOffline(masterDisplayName: String)

    var isLocal: Bool { if case .local = self { return true }; return false }
}

/// Pure resolver. Build one per decision from the current snapshot of the
/// world (role, settings, reachability) and ask it about records.
struct MediaStreamResolver: Sendable {
    struct Configuration: Equatable, Sendable {
        let masterHostname: String
        let port: Int
        let passphrase: String

        /// The master's web server settings live in the SAME defaults keys
        /// the Hallie settings sheet edits (`archivist.webPort` /
        /// `archivist.webPassphrase`), so the viewer's sheet is where the
        /// passphrase is typed — one field, one meaning, both machines.
        static func fromDefaults(_ defaults: UserDefaults = .standard, masterHostname: String) -> Configuration {
            let port = defaults.object(forKey: HallieWebAccess.portKey) as? Int ?? HallieWebAccess.defaultPort
            return Configuration(masterHostname: masterHostname,
                                 port: (1...65535).contains(port) ? port : HallieWebAccess.defaultPort,
                                 passphrase: defaults.string(forKey: HallieWebAccess.passphraseKey) ?? "")
        }

        /// `http://ricksm4.local:8765`
        var baseURL: URL {
            var host = masterHostname.lowercased()
            if !host.hasSuffix(".local") { host += ".local" }
            return URL(string: "http://\(host):\(port)")!
        }
    }

    let role: RemoteViewerRole
    let configuration: Configuration
    /// volumeName → mount path (opted-in volumes only).
    let mappedVolumes: [String: String]
    /// Is the master's web server answering right now? A snapshot taken by
    /// `MasterReachabilityProbe`; the resolver never blocks on the network.
    let masterReachable: Bool
    /// Injected filesystem facts so the matrix is testable.
    let isMounted: @Sendable (_ mountPath: String) -> Bool
    /// Does the mounted volume carry the identity the catalog recorded for
    /// this volume name? `true` when the catalog recorded none.
    let volumeIdentityMatches: @Sendable (_ volumeName: String, _ mountPath: String) -> Bool

    init(role: RemoteViewerRole,
         configuration: Configuration,
         mappedVolumes: [String: String] = [:],
         masterReachable: Bool,
         isMounted: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
         volumeIdentityMatches: @escaping @Sendable (String, String) -> Bool = { _, _ in true }) {
        self.role = role
        self.configuration = configuration
        self.mappedVolumes = mappedVolumes
        self.masterReachable = masterReachable
        self.isMounted = isMounted
        self.volumeIdentityMatches = volumeIdentityMatches
    }

    /// `/Volumes/FamilyArchive/a/b.mov` → ("FamilyArchive", "a/b.mov");
    /// a path not under /Volumes has no volume (the master's internal disk).
    static func volumeName(ofPath path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        return String(parts[1])
    }

    /// The master path re-rooted at the viewer's mount point.
    static func mappedPath(_ path: String, volumeName: String, mountPath: String) -> String {
        let prefix = "/Volumes/\(volumeName)"
        guard path.hasPrefix(prefix) else { return path }
        let rest = String(path.dropFirst(prefix.count))
        let mount = mountPath.hasSuffix("/") ? String(mountPath.dropLast()) : mountPath
        return mount + rest
    }

    /// `http://ricksm4.local:8765/api/media/<uuid>?key=…` — the bridge
    /// accepts the passphrase as a query item because AVPlayer sends no
    /// custom headers.
    func streamURL(recordID: UUID) -> URL {
        var components = URLComponents(url: configuration.baseURL.appendingPathComponent("api/media/\(recordID.uuidString)"),
                                       resolvingAgainstBaseURL: false)!
        if !configuration.passphrase.isEmpty {
            components.queryItems = [URLQueryItem(name: "key", value: configuration.passphrase)]
        }
        return components.url!
    }

    /// `…/api/media/<uuid>/status?key=…`
    func statusURL(recordID: UUID) -> URL {
        var components = URLComponents(url: configuration.baseURL.appendingPathComponent("api/media/\(recordID.uuidString)/status"),
                                       resolvingAgainstBaseURL: false)!
        if !configuration.passphrase.isEmpty {
            components.queryItems = [URLQueryItem(name: "key", value: configuration.passphrase)]
        }
        return components.url!
    }

    /// `…/api/ping` — no passphrase needed.
    var pingURL: URL { configuration.baseURL.appendingPathComponent("api/ping") }

    /// The bridge's own rule for "AVPlayer plays these bytes as-is"; a
    /// viewer holds the same record, so it can predict the handshake and
    /// skip the status poll for MP4/M4V/audio.
    static func isNativelyPlayable(fullPath: String, videoCodec: String) -> Bool {
        let ext = (fullPath as NSString).pathExtension.lowercased()
        if HallieWebBridge.browserPlayableExtensions.contains(ext) { return true }
        return ext == "mov" && HallieWebBridge.nativeMovCodecs.contains(videoCodec.lowercased())
    }

    func resolve(recordID: UUID, fullPath: String, videoCodec: String) -> MediaPlaybackSource {
        if case .master = role {
            return .local(URL(fileURLWithPath: fullPath))
        }
        // 1. Opted-in SMB mount with the same identity.
        if let volume = Self.volumeName(ofPath: fullPath),
           let mount = mappedVolumes[volume],
           isMounted(mount),
           volumeIdentityMatches(volume, mount) {
            return .local(URL(fileURLWithPath: Self.mappedPath(fullPath, volumeName: volume, mountPath: mount)))
        }
        // 2. Stream from the master.
        if masterReachable {
            return .stream(streamURL(recordID: recordID),
                           native: Self.isNativelyPlayable(fullPath: fullPath, videoCodec: videoCodec))
        }
        // 3. Honest offline state.
        return .masterOffline(masterDisplayName: ViewerModeCenter.shortName(configuration.masterHostname))
    }

    func resolve(_ record: VideoRecord) -> MediaPlaybackSource {
        resolve(recordID: record.id, fullPath: record.fullPath, videoCodec: record.videoCodec)
    }
}

// MARK: - Transport seam

/// One HTTP exchange: status code + body. Production = URLSession.
typealias MediaHTTPTransport = @Sendable (URLRequest) async throws -> (status: Int, body: Data)

enum MediaHTTP {
    /// Ephemeral session, short timeouts: a probe must fail fast so the
    /// chat never hangs on an unplugged master.
    static let urlSession: MediaHTTPTransport = { request in
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 8
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// Is the master's web server answering? `GET /api/ping` → 200 with
/// `{"ok":true}`. False on any error or timeout.
struct MasterReachabilityProbe: Sendable {
    let transport: MediaHTTPTransport

    init(transport: @escaping MediaHTTPTransport = MediaHTTP.urlSession) { self.transport = transport }

    func isReachable(_ configuration: MediaStreamResolver.Configuration) async -> Bool {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("api/ping"))
        request.timeoutInterval = 4
        guard let (status, body) = try? await transport(request), status == 200 else { return false }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return (object["ok"] as? Bool) == true
    }
}

/// The proxy handshake the iPad page performs: ask for the first byte; a
/// 200/206 means the bytes are ready, a 202 means the master is encoding
/// an access copy — then poll `/status` until it is ready or fails.
struct MediaStreamClient: Sendable {
    enum PrepareResult: Equatable, Sendable {
        case ready
        case failed(reason: String)
        case timedOut
    }

    let transport: MediaHTTPTransport
    /// Injected so a test never sleeps.
    let sleep: @Sendable (Duration) async -> Void
    let pollInterval: Duration
    /// A long tape can take minutes to encode; bound the wait anyway.
    let maximumPolls: Int

    init(transport: @escaping MediaHTTPTransport = MediaHTTP.urlSession,
         sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
         pollInterval: Duration = .seconds(2),
         maximumPolls: Int = 300) {
        self.transport = transport
        self.sleep = sleep
        self.pollInterval = pollInterval
        self.maximumPolls = maximumPolls
    }

    /// `onProgress` is called with the master's "preparing… Ns" while an
    /// access copy is being made, so the chat can say so.
    func prepare(streamURL: URL, statusURL: URL,
                 onProgress: @Sendable (Int) -> Void = { _ in }) async -> PrepareResult {
        var probe = URLRequest(url: streamURL)
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let (status, body) = try? await transport(probe) else {
            return .failed(reason: "the master did not answer")
        }
        switch status {
        case 200, 206: return .ready
        case 202: break
        case 401: return .failed(reason: "passphrase refused — check Hallie's web passphrase in settings")
        case 404: return .failed(reason: "that file isn't reachable on the master right now")
        case 415: return .failed(reason: String(data: body, encoding: .utf8) ?? "plays on the master only")
        default: return .failed(reason: "HTTP \(status)")
        }
        for _ in 0..<maximumPolls {
            if Task.isCancelled { return .timedOut }
            await sleep(pollInterval)
            guard let (pollStatus, pollBody) = try? await transport(URLRequest(url: statusURL)),
                  pollStatus == 200,
                  let object = try? JSONSerialization.jsonObject(with: pollBody) as? [String: Any],
                  let state = object["state"] as? String else { continue }
            switch state {
            case "ready": return .ready
            case "failed", "unavailable":
                return .failed(reason: (object["reason"] as? String) ?? "the master couldn't prepare it")
            default:
                onProgress(object["seconds"] as? Int ?? 0)
            }
        }
        return .timedOut
    }
}

// MARK: - Live status for the viewer chip

/// "media: streaming" / "media: master offline" — the master's last known
/// reachability, refreshed by the chip on a timer and by every playback
/// attempt. Main-actor because SwiftUI observes it.
@MainActor
final class ViewerMediaStatus: ObservableObject {
    static let shared = ViewerMediaStatus()

    @Published private(set) var masterReachable: Bool?
    @Published private(set) var lastChecked: Date?

    func record(reachable: Bool) {
        masterReachable = reachable
        lastChecked = Date()
    }

    /// The chip's media word.
    var label: String {
        switch masterReachable {
        case nil: return "checking…"
        case true?: return "streaming"
        case false?: return "master offline"
        }
    }

    /// Probe now and remember. One call per playback attempt / chip tick;
    /// cheap (one small GET, 4 s cap).
    func refresh(configuration: MediaStreamResolver.Configuration,
                 probe: MasterReachabilityProbe = MasterReachabilityProbe()) async -> Bool {
        let reachable = await probe.isReachable(configuration)
        record(reachable: reachable)
        return reachable
    }
}

// MARK: - Production assembly

extension MediaStreamResolver {
    /// The resolver for THIS process right now: role from the center,
    /// settings from defaults, reachability from the shared status. On the
    /// master the configuration is unused (every record is local).
    @MainActor
    static func current(defaults: UserDefaults = .standard,
                        designation: MasterArchiveDesignation? = nil) -> MediaStreamResolver {
        let role = ViewerModeCenter.shared.currentRole
        let masterHostname: String
        if case .viewer(let host) = role { masterHostname = host } else { masterHostname = defaultMasterHostname }
        let configuration = Configuration.fromDefaults(defaults, masterHostname: masterHostname)
        let settings = ViewerMediaSettings(defaults: defaults)
        // Identity: when the catalog's Master Archive designation recorded
        // a volume UUID for this volume name, the mount must carry it.
        let designatedName = designation.flatMap { Self.volumeName(ofPath: $0.rootPath) }
        let designatedUUID = designation?.volumeUUID
        return MediaStreamResolver(
            role: role,
            configuration: configuration,
            mappedVolumes: settings.mappedVolumes,
            masterReachable: ViewerMediaStatus.shared.masterReachable ?? false,
            volumeIdentityMatches: { volumeName, mountPath in
                guard volumeName == designatedName, let designatedUUID else { return true }
                return MasterArchiveDesignation.volumeUUID(forPath: mountPath) == designatedUUID
            })
    }
}
