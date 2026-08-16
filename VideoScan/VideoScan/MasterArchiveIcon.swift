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

    /// Apply the badge to the designated volume/folder and the archive root.
    /// Returns the paths that took the icon; logs and skips anything that
    /// refuses (network volumes, read-only media, permissions).
    @discardableResult
    static func apply(volumeOrFolderPath: String, archiveRootPath: String) -> [String] {
        let img = image()
        var done: [String] = []
        for path in [volumeOrFolderPath, archiveRootPath] where FileManager.default.fileExists(atPath: path) {
            if NSWorkspace.shared.setIcon(img, forFile: path, options: []) {
                done.append(path)
            }
        }
        return done
    }

    /// Remove the badge (v1 clear). Best-effort.
    static func remove(volumeOrFolderPath: String, archiveRootPath: String) {
        for path in [volumeOrFolderPath, archiveRootPath] where FileManager.default.fileExists(atPath: path) {
            _ = NSWorkspace.shared.setIcon(nil, forFile: path, options: [])
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
