// HallieWebAccess.swift
// The on/off switch and the settings for Hallie on the home network. Owned
// by the app (started with the catalog model), persisted in the same
// `archivist.*` defaults the chat window uses.

import Combine
import Foundation
import SwiftUI

@MainActor
final class HallieWebAccess: ObservableObject {
    static let shared = HallieWebAccess()

    static let enabledKey = "archivist.webEnabled"
    static let portKey = "archivist.webPort"
    static let passphraseKey = "archivist.webPassphrase"
    static let defaultPort = 8765

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    private var server: HallieWebServer?
    private var bridge: HallieWebBridge?
    private weak var model: VideoScanModel?
    /// Archive Timeline items for the Browse tab, one compute per catalog version.
    private let timelineMemo = RenderMemo<RecordsVersion, [ArchiveTimelineItem]>()

    /// Attach the catalog once at launch; starts if enabled.
    func attach(model: VideoScanModel) {
        self.model = model
        apply()
    }

    /// Re-read the defaults and start/stop/restart accordingly.
    func apply(_ defaults: UserDefaults = .standard) {
        let enabled = defaults.bool(forKey: Self.enabledKey)
        let port = UInt16(clamping: defaults.object(forKey: Self.portKey) as? Int ?? Self.defaultPort)
        stop()
        guard enabled, let model else { return }
        // Access copies for tapes Safari can't decode (HallieWebProxy):
        // 720p H.264 by default, in Application Support unless Rick points
        // them elsewhere; the HDD one-reader rule comes from the catalog's
        // volume roles, same rule the file-operations gate uses.
        let proxyCache = HallieWebProxyCache(
            directory: HallieWebProxyPlan.directory(defaults),
            height: HallieWebProxyPlan.height(defaults))
        let posterCache = HallieWebPosterCache(
            directory: HallieWebProxyPlan.directory(defaults).appendingPathComponent("posters", isDirectory: true))
        let bridge = HallieWebBridge(
            records: { [weak model] in model?.records ?? [] },
            record: { [weak model] id in model?.record(forID: id) },
            configuration: {
                let d = UserDefaults.standard
                let archivist = d.string(forKey: HallieTurnExecutor.Speakers.archivistNameDefaultsKey)
                    ?? HallieTurnExecutor.Speakers.defaultArchivistName
                return .init(
                    passphrase: d.string(forKey: Self.passphraseKey) ?? "",
                    archivistName: archivist == "Name TBD" ? HallieTurnExecutor.Speakers.defaultArchivistName : archivist,
                    archivistPersonName: d.string(forKey: HallieTurnExecutor.Speakers.archivistPersonNameDefaultsKey),
                    hosts: OllamaEndpoints.resolved(from: d),
                    modelName: d.string(forKey: "archivist.ollamaModel") ?? "qwen3.6:35b-a3b-nvfp4",
                    composeWithModel: HallieCompositionSettings.isEnabled(d))
            },
            proxy: proxyCache,
            isSpinningDisk: { [weak model] path in
                guard let model else { return false }
                return model.scanTargets
                    .filter { !$0.searchPath.isEmpty && path.hasPrefix($0.searchPath) }
                    .max(by: { $0.searchPath.count < $1.searchPath.count })?
                    .mediaTech == .hdd
            },
            timeline: { [weak model, timelineMemo] in
                guard let model else { return [] }
                // Same projection the Archive tab uses, memoized per catalog
                // version so a Browse request is O(1) after the first.
                let key = RecordsVersion(count: model.records.count,
                                         revision: model.volumeAggregatesRevision)
                return timelineMemo.value(for: key) {
                    let snapshot = ArchiveCategorySnapshot.compute(
                        active: pfActiveRecords(model.records),
                        allRecords: model.records, model: model, volumeSearchPaths: [])
                    return snapshot.archived.map { ArchiveView.timelineItem(for: $0, model: model) }
                }
            },
            posters: posterCache)
        let server = HallieWebServer { request, peer in
            await bridge.handle(request, peer: peer)
        }

        do {
            try server.start(port: port)
            self.server = server
            self.bridge = bridge
            isRunning = true
            lastError = nil
            appLog.write("Hallie web: listening on port \(server.port) (\(Self.url(port: Int(server.port))))")
        } catch {
            isRunning = false
            lastError = error.localizedDescription
            appLog.write("Hallie web: could not listen on \(port) — \(error.localizedDescription)")
        }
    }

    func stop() {
        server?.stop()
        server = nil
        bridge = nil
        if isRunning { appLog.write("Hallie web: stopped") }
        isRunning = false
    }

    /// "http://ricksm4.local:8765" — what the family types once, then adds
    /// to the home screen.
    static func url(port: Int) -> String {
        var host = ProcessInfo.processInfo.hostName
        if !host.hasSuffix(".local") {
            host = host.replacingOccurrences(of: ".", with: "-") + ".local"
        }
        return "http://\(host.lowercased()):\(port)"
    }
}
