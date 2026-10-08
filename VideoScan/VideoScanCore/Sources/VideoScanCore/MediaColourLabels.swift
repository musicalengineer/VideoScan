// MediaColourLabels.swift (VideoScanCore)
// A picture stream's colour labels, as ffprobe names them (Check Media's
// full tier compares them with what the decoded picture really holds).
// "" = not labelled: ffprobe's "unknown" / "unspecified" / "reserved" all
// read as "". A plain value type (≈ a C++ struct of four strings).

import Foundation

public struct MediaColourLabels: Sendable, Equatable {
    /// "tv" (limited range, 16–235 at 8 bits) or "pc" (full, 0–255).
    public var range: String = ""
    /// The YUV matrix: "bt709", "smpte170m", "bt470bg", "bt2020nc", …
    public var matrix: String = ""
    public var transfer: String = ""
    public var primaries: String = ""

    public init() {}

    public init(range: String?, matrix: String?, transfer: String?, primaries: String?) {
        self.range = Self.labelled(range)
        self.matrix = Self.labelled(matrix)
        self.transfer = Self.labelled(transfer)
        self.primaries = Self.labelled(primaries)
    }

    private static func labelled(_ s: String?) -> String {
        guard let s, !["unknown", "unspecified", "reserved"].contains(s) else { return "" }
        return s
    }

    public var isLabelled: Bool { !(range + matrix + transfer + primaries).isEmpty }
}
