// BackgroundProtocolVersion.swift — VideoScanCore/Background
//
// The wire contract between VideoScan.app and "VideoScan Background" (the
// launchd agent inside the app bundle; docs/design/background_service_2026_10_30.md
// §3.3). Everything in Background/ is Foundation-only: the helper, the app and
// the tests all link it, and nothing here may import AppKit, CoreGraphics,
// SwiftUI or GRDB (BackgroundServiceSensorTests pins that).
//
// C++ reading: `BackgroundServiceXPC` is the IDL — an abstract interface the
// NSXPC runtime proxies across processes. Arguments are plain `Data` blobs
// produced by `BackgroundPayloadCodec`, so the interface never changes shape
// when a payload grows a field; only `schema` moves.

import Foundation

/// The payload schema the two sides must agree on. Bump it when a payload
/// changes incompatibly; `BackgroundPayloadCodec` refuses a mismatch in words.
public enum BackgroundProtocolVersion {
    public static let current = 1
}

/// A refusal in words — the catalog's convention (never a bare error code).
public struct Refusal: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    public let words: String
    public init(_ words: String) { self.words = words }
    public var description: String { words }
}

/// Names shared by both processes: the helper's bundle id and its Mach
/// service are the app's bundle id with `.Background` appended, so the one
/// place that knows the app's id (the app target's PRODUCT_BUNDLE_IDENTIFIER)
/// decides both.
public enum BackgroundServiceNames {
    public static let suffix = ".Background"

    /// "Rick-Breen.VideoScan" → "Rick-Breen.VideoScan.Background".
    public static func helperBundleIdentifier(appBundleIdentifier: String) -> String {
        appBundleIdentifier + suffix
    }

    /// The Mach service launchd registers for the agent — the same string
    /// as the helper's bundle id and the plist's Label.
    public static func machServiceName(appBundleIdentifier: String) -> String {
        helperBundleIdentifier(appBundleIdentifier: appBundleIdentifier)
    }

    /// The launchd plist inside `Contents/Library/LaunchAgents/`.
    public static func launchdPlistName(appBundleIdentifier: String) -> String {
        helperBundleIdentifier(appBundleIdentifier: appBundleIdentifier) + ".plist"
    }

    /// "Rick-Breen.VideoScan.Background" → "Rick-Breen.VideoScan" (the helper
    /// working out which app it belongs to). nil when the suffix is absent.
    public static func appBundleIdentifier(helperBundleIdentifier: String) -> String? {
        guard helperBundleIdentifier.hasSuffix(suffix) else { return nil }
        return String(helperBundleIdentifier.dropLast(suffix.count))
    }
}

/// The one XPC interface (design §3.3). Every `Data` is a
/// `BackgroundPayloadCodec` envelope; every reply that can refuse carries a
/// `Refusal` in words rather than failing the call.
///
/// `@objc` because NSXPC proxies Objective-C selectors; the Swift types stay
/// on either side of the wire.
@objc public protocol BackgroundServiceXPC {
    /// → `ServiceStatus`.
    func status(reply: @escaping @Sendable (Data) -> Void)
    /// `JobRequest` → `EnqueueReply` (a `JobID` or a `Refusal`).
    func enqueue(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    /// `JobID` → did the job exist and take the verb.
    func pause(_ id: Data, reply: @escaping @Sendable (Bool) -> Void)
    func resume(_ id: Data, reply: @escaping @Sendable (Bool) -> Void)
    func stop(_ id: Data, reply: @escaping @Sendable (Bool) -> Void)
    /// The app hands the service an endpoint it can push `JobProgressSnapshot`
    /// envelopes to (at most 4/s). Step 0 accepts and remembers it; the MFO
    /// row that draws it is Rick's UI step.
    func subscribe(progress endpoint: NSXPCListenerEndpoint)
}

/// The callback side of `subscribe(progress:)`: the app exports this on the
/// endpoint it hands over, the service calls it.
@objc public protocol BackgroundProgressXPC {
    /// A `JobProgressSnapshot` envelope.
    func progress(_ snapshot: Data)
}
