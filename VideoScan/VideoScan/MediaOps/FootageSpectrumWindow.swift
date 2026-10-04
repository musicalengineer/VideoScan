// FootageSpectrumWindow.swift
// The Footage Spectrum window (trial, 2026-10-03): the helper's
// self-contained page in a WKWebView, under a small native toolbar —
// Show These in the Catalog · Reveal Page in Finder · Compare Again.
//
// No network: the page is one local file with its data and frames inline.
// The web view may load ONLY that run's folder (`loadFileURL(_:allowingRead
// AccessTo:)`), a content rule blocks every http(s)/ws(s) request, and the
// navigation delegate cancels any navigation that is not a file inside the
// run's folder (or the page's own about:/data: content).
//
// Opening never blocks: until the job has a page the window says
// "Preparing…" with the job's own status line; a failed or stopped job says
// so.
//
// (For Rick: `NSViewRepresentable` ≈ an adapter that hosts an AppKit NSView
// inside SwiftUI — `makeNSView` is the constructor, `updateNSView` runs on
// every state change; the `Coordinator` is the AppKit delegate object.)

import AppKit
import SwiftUI
import WebKit
import os

private let spectrumWindowLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "windows")

@MainActor
enum FootageSpectrumWindowOpener {
    static let sceneID = "footageSpectrum"
    static let windowTitle = "Footage Spectrum"

    /// The shared create → activate → find → clamp → raise funnel.
    static func open(using openWindow: OpenWindowAction, source: String) {
        DossierWindowOpener.open(sceneID: sceneID, windowTitle: windowTitle, using: openWindow, source: source)
    }
}

/// Pure navigation rule (table-tested): may the web view go to `url`?
enum FootageSpectrumNavigationPolicy {
    static func allows(_ url: URL?, runFolder: URL) -> Bool {
        guard let url else { return false }
        switch url.scheme?.lowercased() {
        case "about", "data", "blob":
            return true
        case "file":
            let folder = runFolder.standardizedFileURL.resolvingSymlinksInPath().path
            let target = url.standardizedFileURL.resolvingSymlinksInPath().path
            return target == folder || target.hasPrefix(folder + "/")
        default:
            return false
        }
    }

    /// WebKit content-blocker rules: block every network request.
    static let blockNetworkRules = """
    [{"trigger":{"url-filter":"^(https?|wss?|ftp)://"},"action":{"type":"block"}}]
    """
}

struct FootageSpectrumWindowView: View {
    @ObservedObject var viewer: FootageSpectrumViewer
    let model: VideoScanModel
    @Environment(\.mediaFileOperationsCenterReference) private var center
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let job = viewer.job {
                FootageSpectrumJobView(job: job, model: model, compareAgain: { compareAgain(job) })
            } else {
                placeholder("Nothing to show yet",
                            detail: "Select 2 to 8 videos in the Triage tab and choose Compare Footage…")
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    private func compareAgain(_ job: FootageSpectrumJob) {
        guard let center else { return }
        _ = model.startFootageSpectrum(ids: job.requestedIDs, title: job.requestTitle,
                                       preferredFirst: job.preferredFirst, center: center, source: "Compare Again")
    }
}

private struct FootageSpectrumJobView: View {
    @ObservedObject var job: FootageSpectrumJob
    let model: VideoScanModel
    let compareAgain: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .navigationTitle("\(FootageSpectrumWindowOpener.windowTitle) — \(job.title)")
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(job.title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Text(job.state.isActive ? job.subtitle : statusWords)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button {
                model.showFootageSpectrumInCatalog(job)
            } label: {
                Label("Show These in the Catalog", systemImage: "film.stack")
            }
            .help("Goes to the Catalog with just the compared videos listed")
            .accessibilityIdentifier("spectrum.showInCatalog")
            Button {
                if let page = job.pageURL { NSWorkspace.shared.activateFileViewerSelecting([page]) }
            } label: {
                Label("Reveal Page in Finder", systemImage: "folder")
            }
            .disabled(job.pageURL == nil)
            .help("The page is a single local file — it can be opened in any browser")
            .accessibilityIdentifier("spectrum.revealPage")
            Button {
                compareAgain()
            } label: {
                Label("Compare Again", systemImage: "arrow.clockwise")
            }
            .disabled(job.state.isActive)
            .help("Run the comparison again — videos already read come from the cache, so it is quick")
            .accessibilityIdentifier("spectrum.compareAgain")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var statusWords: String {
        switch job.state {
        case .finished(let summary): return summary
        case .failed(let message): return message
        case .cancelled: return "Stopped"
        case .running, .cancelling: return job.subtitle
        }
    }

    @ViewBuilder
    private var content: some View {
        if let page = job.pageURL {
            FootageSpectrumWebView(page: page, runFolder: page.deletingLastPathComponent())
        } else {
            switch job.state {
            case .running, .cancelling:
                VStack(spacing: 12) {
                    ProgressView(value: job.isIndeterminate ? nil : job.fraction)
                        .frame(width: 320)
                    Text("Preparing…").font(.system(size: 17, weight: .semibold))
                    Text(job.subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
                    Text("It runs in Media File Operations — you can close this window and open it again from there.")
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                placeholder("The comparison could not be made", detail: message)
            case .cancelled:
                placeholder("The comparison was stopped", detail: "Compare Again starts it over; videos already read are quick.")
            case .finished:
                placeholder("The page is missing", detail: "Compare Again makes it again.")
            }
        }
    }
}

private func placeholder(_ title: String, detail: String) -> some View {
    VStack(spacing: 8) {
        Text(title).font(.system(size: 17, weight: .semibold))
        Text(detail)
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 520)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

/// The page, in a web view that can read only its own run folder.
struct FootageSpectrumWebView: NSViewRepresentable {
    let page: URL
    let runFolder: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        context.coordinator.runFolder = runFolder
        let controller = config.userContentController
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "videoscan.spectrum.noNetwork",
            encodedContentRuleList: FootageSpectrumNavigationPolicy.blockNetworkRules) { list, error in
            if let list {
                controller.add(list)
            } else if let error {
                spectrumWindowLog.error("spectrum: network block rule did not compile — \(error.localizedDescription, privacy: .public); navigation policy still applies")
            }
        }
        load(web, coordinator: context.coordinator)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        guard context.coordinator.loadedPage != page else { return }
        context.coordinator.runFolder = runFolder
        load(web, coordinator: context.coordinator)
    }

    private func load(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.loadedPage = page
        web.loadFileURL(page, allowingReadAccessTo: runFolder)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var runFolder: URL?
        var loadedPage: URL?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let runFolder,
                  FootageSpectrumNavigationPolicy.allows(navigationAction.request.url, runFolder: runFolder) else {
                spectrumWindowLog.notice("spectrum: navigation cancelled (\(navigationAction.request.url?.scheme ?? "nil", privacy: .public))")
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
