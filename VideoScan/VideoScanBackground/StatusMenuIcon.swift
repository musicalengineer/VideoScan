// StatusMenuIcon.swift — VideoScan Background
//
// The menu bar glyph, drawn in code as a TEMPLATE image (Apple HIG: menu bar
// extras are monochrome; macOS tints them for light, dark and the accent).
// The app icon reduced to its two shapes: the film frame with its sprocket
// holes, and the magnifier over its lower-right corner. The lens is knocked
// out of the frame so the two read apart at 16 pt.
//
//   idle    — outline lens
//   working — solid lens (a job is running)
//   paused  — pause bars in the lens
//
// (For Rick: NSBezierPath is Cocoa's 2-D path, like a Skia/Cairo path; a
// "template" image is an alpha mask the menu bar colours itself.)

import AppKit
import VideoScanCore

enum StatusMenuIcon {
    static let size = NSSize(width: 20, height: 18)

    static func image(_ state: BackgroundMenuPresentation.Icon) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            draw(state)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "VideoScan Background"
        return image
    }

    static func draw(_ state: BackgroundMenuPresentation.Icon) {
        NSColor.black.setStroke()
        NSColor.black.setFill()

        // Film frame: a portrait frame, sprocket holes along its top and bottom.
        let frame = NSRect(x: 1.5, y: 2.5, width: 11, height: 13)
        let film = NSBezierPath(roundedRect: frame, xRadius: 2.2, yRadius: 2.2)
        film.lineWidth = 1.4
        film.stroke()
        for i in 0..<3 {
            let x = frame.minX + 2.2 + CGFloat(i) * 2.6
            NSBezierPath(rect: NSRect(x: x, y: frame.maxY - 2.6, width: 1.3, height: 1.2)).fill()
            NSBezierPath(rect: NSRect(x: x, y: frame.minY + 1.4, width: 1.3, height: 1.2)).fill()
        }

        // Magnifier over the lower-right corner; knock the frame out under it.
        let centre = NSPoint(x: 13.2, y: 7.4)
        let r: CGFloat = 4.3
        let lens = NSRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r)
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: lens.insetBy(dx: -1.4, dy: -1.4)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        let ring = NSBezierPath(ovalIn: lens)
        ring.lineWidth = 1.5
        ring.stroke()

        let handle = NSBezierPath()
        let a = CGFloat.pi / 4
        handle.move(to: NSPoint(x: centre.x + r * cos(-a), y: centre.y + r * sin(-a)))
        handle.line(to: NSPoint(x: 19.0, y: 1.4))
        handle.lineWidth = 2.2
        handle.lineCapStyle = .round
        handle.stroke()

        switch state {
        case .idle:
            break
        case .working:
            NSBezierPath(ovalIn: lens.insetBy(dx: 1.7, dy: 1.7)).fill()
        case .paused:
            let h: CGFloat = 3.6, w: CGFloat = 1.2, gap: CGFloat = 1.1
            NSBezierPath(rect: NSRect(x: centre.x - gap / 2 - w, y: centre.y - h / 2, width: w, height: h)).fill()
            NSBezierPath(rect: NSRect(x: centre.x + gap / 2, y: centre.y - h / 2, width: w, height: h)).fill()
        }
    }
}
