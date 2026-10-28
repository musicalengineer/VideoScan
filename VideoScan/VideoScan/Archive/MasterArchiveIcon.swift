//
//  MasterArchiveIcon.swift
//  VideoScan
//
//  Finder-visible marker for the Master Archive (Rick 2026-08-16: "can we
//  make a special icon when we designate a volume as an archive volume so
//  it shows up as such in Finder?"). Sets a custom icon on the volume /
//  chosen folder AND on the Breen_Family_Archive folder via
//  NSWorkspace.setIcon (Finder writes .VolumeIcon.icns / the folder icon
//  resource and flips the custom-icon bit). Best-effort by design: a
//  failure here never fails Initialize — the archive is the tree and the
//  manifest, the icon is a courtesy.
//

import AppKit

// @MainActor: it draws with lockFocus and reads NSApp, both main-thread
// AppKit; its only callers (VideoScanModel+MasterArchive) already run there.
@MainActor
enum MasterArchiveIcon {

    /// The badge image: the app icon with an archive-box badge in the
    /// lower-right — recognisably "VideoScan's archive" at Finder sizes.
    /// Swap this for a hand-drawn .icns later; callers only see an NSImage.
    static func image() -> NSImage {
        let size = NSSize(width: 512, height: 512)
        let base = NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage(size: size)
        let out = NSImage(size: size)
        out.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size),
                  from: .zero, operation: .sourceOver, fraction: 1.0)
        // Badge plate + symbol.
        let plate = NSRect(x: 292, y: 20, width: 200, height: 200)
        let path = NSBezierPath(roundedRect: plate, xRadius: 44, yRadius: 44)
        NSColor(calibratedRed: 0.93, green: 0.72, blue: 0.20, alpha: 1.0).setFill()   // archival amber
        path.fill()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        path.lineWidth = 6
        path.stroke()
        if let symbol = NSImage(systemSymbolName: "archivebox.fill", accessibilityDescription: "Archive")?
            .withSymbolConfiguration(.init(pointSize: 128, weight: .bold)) {
            let tinted = symbol.tinted(with: .white)
            let sz = NSSize(width: 140, height: 140)
            tinted.draw(in: NSRect(x: plate.midX - sz.width / 2, y: plate.midY - sz.height / 2,
                                   width: sz.width, height: sz.height),
                        from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        out.unlockFocus()
        return out
    }

    /// Apply the badge to the archive ROOT FOLDER only (Breen_Family_Archive).
    /// Rick 2026-08-16: the volume may carry other, unrelated folders, so
    /// the volume icon stays stock — the badge marks exactly what the app
    /// manages. Returns the paths that took the icon; skips anything that
    /// refuses (network volumes, read-only media, permissions).
    @discardableResult
    static func apply(volumeOrFolderPath: String, archiveRootPath: String) -> [String] {
        _ = volumeOrFolderPath   // deliberately not badged
        // Cosmetic only. Skipped under a sanitizer test run (2026-10-05): the
        // Thread Sanitizer runtime segfaulted freeing IconServices' icon data
        // here (VideoScan-2026-10-05-050113.ips), killing the test host.
        // Ordinary tests and the app still set it.
        if ProcessInfo.processInfo.environment["VIDEOSCAN_SANITIZER"] != nil { return [] }
        guard mayTouch(archiveRootPath) else { return [] }
        guard FileManager.default.fileExists(atPath: archiveRootPath) else { return [] }
        return NSWorkspace.shared.setIcon(image(), forFile: archiveRootPath, options: []) ? [archiveRootPath] : []
    }

    /// Remove the badge (v1 clear). Best-effort. Also clears a volume-level
    /// icon left by the short-lived build that badged both.
    static func remove(volumeOrFolderPath: String, archiveRootPath: String) {
        for path in [archiveRootPath, volumeOrFolderPath] where mayTouch(path) && FileManager.default.fileExists(atPath: path) {
            _ = NSWorkspace.shared.setIcon(nil, forFile: path, options: [])
        }
    }

    // MARK: Test-host isolation (2026-10-28)
    //
    // A unit test that hard-coded "/Volumes/FamilyArchive" reached the REAL
    // Master Archive on the M5 Ultra (the Pegasus is attached there; on the
    // M4 the path did not exist, so it was a silent no-op for weeks). In a
    // test host the icon is only ever set or cleared inside the temp folder;
    // anything else is refused before NSWorkspace runs, and recorded so a
    // test can fail on it. Outside a test host nothing changes.

    /// Paths a test host asked to badge or un-badge outside the temp folder.
    private(set) static var testHostRefusals: [String] = []

    private static func mayTouch(_ path: String) -> Bool {
        guard TestEnvironment.isTestHost else { return true }
        if isInsideTemporaryDirectory(path, temporaryDirectory: FileManager.default.temporaryDirectory) { return true }
        testHostRefusals.append(path)
        NSLog("TEST-ISOLATION: MasterArchiveIcon refused %@ — a test host may only badge paths inside the temp folder", path)
        return false
    }

    /// Pure: is `path` the temp folder or below it, after resolving symlinks
    /// and `..` on both sides (/var → /private/var)? A sibling that merely
    /// shares the prefix ("/private/var/folders/xxTX") is not inside.
    nonisolated static func isInsideTemporaryDirectory(_ path: String, temporaryDirectory: URL) -> Bool {
        guard let root = canonicalPath(temporaryDirectory.path), let candidate = canonicalPath(path) else { return false }
        let base = root.hasSuffix("/") ? root : root + "/"
        return candidate == root || candidate.hasPrefix(base)
    }

    /// realpath(3) of the nearest existing ancestor, plus the components
    /// below it that do not exist yet. Not resolvingSymlinksInPath: that
    /// strips "/private" only from paths that exist, so an existing temp
    /// root and a not-yet-created file under it came out in different forms.
    /// Any `..` is refused outright (codex #162 P1): collapsing it on paper
    /// before resolving a symlink lets `<temp>/link/../x` name a file the
    /// filesystem finds outside temp. nil (refuse) if nothing resolves.
    nonisolated private static func canonicalPath(_ path: String) -> String? {
        guard !path.isEmpty, !path.split(separator: "/").contains("..") else { return nil }
        var head = URL(fileURLWithPath: path).path
        var tail: [String] = []
        while true {
            if let real = realpath(head, nil) {
                defer { free(real) }
                let resolved = String(cString: real)
                return tail.isEmpty ? resolved : (resolved as NSString).appendingPathComponent(tail.reversed().joined(separator: "/"))
            }
            guard head != "/", !head.isEmpty else { return nil }
            tail.append((head as NSString).lastPathComponent)
            head = (head as NSString).deletingLastPathComponent
        }
    }
}

private extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: size)
        draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        rect.fill(using: .sourceAtop)
        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}
