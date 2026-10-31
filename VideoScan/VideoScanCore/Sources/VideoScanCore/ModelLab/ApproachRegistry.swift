// ApproachRegistry.swift (VideoScanCore/ModelLab)
// ONE SENTENCE: the pure description of an Approach (one model + one host +
// one prompt family + one output contract), the registry that knows every
// (id, revision) once, and the payload gate that is CLAUDE.md rule 13
// carried by code (docs/design/video_llm_lab_2026_10_30.md §3.3, §7).
//
// For Rick (C++): `ApproachRegistry` is a factory keyed by (id, revision) —
// a `std::map<std::pair<Id,int>, Descriptor>` whose `insert` throws on a
// duplicate key instead of overwriting. `PayloadClass` is a bit-set
// (`enum class : unsigned` with operator|). `PayloadGate.check` is a free
// function with no state: the job calls it before any transport, and the
// sensor proves a fake transport is never touched.
//
// MEMORY: a handful of descriptors (tens of bytes each); a registry never
// grows beyond the approaches compiled into the build.

import Foundation

// MARK: - Identity

/// "model/promptFamily/sampler", e.g. "qwen3-vl-32b-4bit/era-v1/window-60s".
/// Three non-empty segments without whitespace; anything else is not an id.
public struct ApproachID: Hashable, Sendable, Codable, CustomStringConvertible, Comparable {
    public let model: String
    public let promptFamily: String
    public let sampler: String

    /// nil unless every segment is non-empty with no '/' and no whitespace.
    public init?(model: String, promptFamily: String, sampler: String) {
        guard Self.isSegment(model), Self.isSegment(promptFamily), Self.isSegment(sampler) else { return nil }
        self.model = model
        self.promptFamily = promptFamily
        self.sampler = sampler
    }

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let id = ApproachID(model: parts[0], promptFamily: parts[1], sampler: parts[2]) else { return nil }
        self = id
    }

    public var rawValue: String { "\(model)/\(promptFamily)/\(sampler)" }
    public var description: String { rawValue }

    public static func < (lhs: ApproachID, rhs: ApproachID) -> Bool { lhs.rawValue < rhs.rawValue }

    private static func isSegment(_ s: String) -> Bool {
        !s.isEmpty && !s.contains("/") && s.unicodeScalars.allSatisfy { !CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = ApproachID(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an approach id: \(raw)"))
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Host, payload, field families, resources

/// Where the model runs. `isLocal` is the rule-13 question: may family
/// pixels or audio be sent here? `.mlxSwift` is in-process and
/// `.pythonWorker` a child process on this machine; `.ollama` carries only
/// `LocalHost` values (validated at construction — loopback, `.local`,
/// private-range literals), so an empty list is the only non-local ollama
/// and it is refused everywhere; `.remoteTextOnly` is the registry slot for
/// a cloud model that may ever see DERIVED TEXT only, and ships disabled.
public enum ApproachHost: Hashable, Sendable {
    case mlxSwift
    case pythonWorker(venv: String, script: String)
    case ollama(hosts: [LocalHost])
    case remoteTextOnly

    public var isLocal: Bool {
        switch self {
        case .mlxSwift, .pythonWorker: return true
        case .ollama(let hosts): return !hosts.isEmpty
        case .remoteTextOnly: return false
        }
    }

    /// Stable words for the run record and the START line.
    public var label: String {
        switch self {
        case .mlxSwift: return "mlxSwift"
        case .pythonWorker(let venv, let script): return "pythonWorker(\(venv), \(script))"
        case .ollama(let hosts): return "ollama(\(hosts.map(\.rawValue).joined(separator: ",")))"
        case .remoteTextOnly: return "remoteTextOnly"
        }
    }
}

/// What may be sent to a model. A bit-set: `[.pixels, .derivedText]`.
public struct PayloadClass: OptionSet, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Frames of family footage.
    public static let pixels = PayloadClass(rawValue: 1 << 0)
    /// Family voices.
    public static let audio = PayloadClass(rawValue: 1 << 1)
    /// Captions, transcripts, OCR strings — text ABOUT family, already derived.
    public static let derivedText = PayloadClass(rawValue: 1 << 2)

    /// The classes rule 13 keeps on the machine.
    public static let familyMedia: PayloadClass = [.pixels, .audio]

    public var description: String {
        var words: [String] = []
        if contains(.pixels) { words.append("pixels") }
        if contains(.audio) { words.append("audio") }
        if contains(.derivedText) { words.append("derivedText") }
        return words.isEmpty ? "none" : words.joined(separator: "+")
    }
}

/// What an approach emits: one output contract per family (§3.3).
public enum FieldFamily: String, Sendable, Codable, CaseIterable, Hashable, Comparable {
    case era, scene, ocrDate, ocrText, occasionKind, roomFeatures, carrierClues, spokenNamePresence
    public static func < (lhs: FieldFamily, rhs: FieldFamily) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What the approach needs to run; the job refuses a host that cannot hold it.
public struct ResourceProfile: Hashable, Sendable {
    public let peakRAMGB: Double
    /// One resident model at a time (CaptionRunner.swift enforces it).
    public let needsResidentModel: Bool
    public let expectedSecondsPerWindowUltra: Double?
    public let expectedSecondsPerWindowM4: Double?
    /// Where the weights live (a Hugging Face repo id or an Ollama tag).
    /// Informational: the caller checks presence and tells `preflight`.
    public let weightsLocation: String?

    public init(peakRAMGB: Double, needsResidentModel: Bool = true,
                expectedSecondsPerWindowUltra: Double? = nil, expectedSecondsPerWindowM4: Double? = nil,
                weightsLocation: String? = nil) {
        self.peakRAMGB = peakRAMGB
        self.needsResidentModel = needsResidentModel
        self.expectedSecondsPerWindowUltra = expectedSecondsPerWindowUltra
        self.expectedSecondsPerWindowM4 = expectedSecondsPerWindowM4
        self.weightsLocation = weightsLocation
    }
}

/// The pure description of an approach. The runnable half (`run(_:…)`) is
/// the app's; Core holds what the registry, the gate, the run record and
/// the assertion mapping need.
public struct ApproachDescriptor: Hashable, Sendable {
    public let id: ApproachID
    /// Bumped on any prompt or parameter change; counted from 1.
    public let revision: Int
    public let host: ApproachHost
    public let accepts: PayloadClass
    public let emits: Set<FieldFamily>
    public let resources: ResourceProfile
    /// Hash of the exact prompt text, "sha256:<hex>"; goes into every run record.
    public let promptHash: String
    /// A disabled approach may be registered (so its id is known and
    /// refused by name) but never started.
    public let enabled: Bool

    public init(id: ApproachID, revision: Int, host: ApproachHost, accepts: PayloadClass, emits: Set<FieldFamily>,
                resources: ResourceProfile, promptHash: String, enabled: Bool = true) {
        self.id = id
        self.revision = revision
        self.host = host
        self.accepts = accepts
        self.emits = emits
        self.resources = resources
        self.promptHash = promptHash
        self.enabled = enabled
    }

    /// "machine:<id>@r<revision>" — the `by` of every assertion this approach makes.
    public var signer: String { "machine:\(id.rawValue)@r\(revision)" }
}

// MARK: - Registry

public enum ApproachRegistryError: Error, Equatable, Sendable, CustomStringConvertible {
    case duplicate(id: ApproachID, revision: Int)
    case revisionNotPositive(id: ApproachID, revision: Int)
    /// An `.ollama` host list that is empty (so not local): never registered
    /// (rule 13). `.remoteTextOnly` is still registrable — it is the slot.
    case hostNotLocal(id: ApproachID, host: String)

    public var description: String {
        switch self {
        case .hostNotLocal(let id, let host):
            return "approach \(id) names host \(host), which is not on this machine or the local network; not registered (CLAUDE.md rule 13)"
        case .duplicate(let id, let revision):
            return "approach \(id)@r\(revision) is already registered; bump the revision for a changed prompt or parameter"
        case .revisionNotPositive(let id, let revision):
            return "approach \(id) revision \(revision) is not allowed; revisions count from 1"
        }
    }
}

/// Every approach this build knows, once per (id, revision).
public struct ApproachRegistry: Sendable {
    private struct Key: Hashable { let id: ApproachID; let revision: Int }
    private var descriptors: [Key: ApproachDescriptor] = [:]

    public init() {}

    public mutating func register(_ descriptor: ApproachDescriptor) throws(ApproachRegistryError) {
        guard descriptor.revision >= 1 else {
            throw .revisionNotPositive(id: descriptor.id, revision: descriptor.revision)
        }
        if case .ollama(let hosts) = descriptor.host, hosts.isEmpty {
            throw .hostNotLocal(id: descriptor.id, host: descriptor.host.label)
        }
        let key = Key(id: descriptor.id, revision: descriptor.revision)
        guard descriptors[key] == nil else { throw .duplicate(id: descriptor.id, revision: descriptor.revision) }
        descriptors[key] = descriptor
    }

    public func descriptor(_ id: ApproachID, revision: Int) -> ApproachDescriptor? {
        descriptors[Key(id: id, revision: revision)]
    }

    /// The highest revision registered for `id`.
    public func latest(_ id: ApproachID) -> ApproachDescriptor? {
        descriptors.values.filter { $0.id == id }.max { $0.revision < $1.revision }
    }

    /// Sorted by id, then revision — stable for a START line or a table.
    public var all: [ApproachDescriptor] {
        descriptors.values.sorted { ($0.id, $0.revision) < ($1.id, $1.revision) }
    }

    public var count: Int { descriptors.count }
}

// MARK: - Payload gate (rule 13 in code)

public enum PayloadRefused: Error, Equatable, Sendable, CustomStringConvertible {
    /// Family pixels or audio were about to go to a host that is not local.
    case hostNotLocal(approach: ApproachID, host: String, refused: PayloadClass)
    /// A class the approach did not declare in `accepts`.
    case notAccepted(approach: ApproachID, refused: PayloadClass)

    public var description: String {
        switch self {
        case .hostNotLocal(let approach, let host, let refused):
            return "refused: \(approach) on host \(host) may not be sent \(refused) — family pixels and audio never leave the machine (CLAUDE.md rule 13). Nothing was sent."
        case .notAccepted(let approach, let refused):
            return "refused: \(approach) does not accept \(refused). Nothing was sent."
        }
    }
}

/// The one check every runner makes BEFORE a byte reaches a transport.
/// Pure, so the sensor is a function call: a `.remoteTextOnly` approach
/// handed `.pixels` throws here, and a fake transport counts zero.
public enum PayloadGate {
    public static func check(_ descriptor: ApproachDescriptor, payload: PayloadClass) throws(PayloadRefused) {
        let media = payload.intersection(.familyMedia)
        // Spelled per case (not `isLocal`) so the architecture sensor can read
        // every non-local host name on the refusal path; a test pins that
        // this switch and `isLocal` agree for every case.
        switch descriptor.host {
        case .mlxSwift, .pythonWorker:
            break                                    // this machine
        case .ollama(let hosts) where !hosts.isEmpty:
            break                                    // every LocalHost was validated at construction
        case .ollama, .remoteTextOnly:
            if !media.isEmpty {
                throw .hostNotLocal(approach: descriptor.id, host: descriptor.host.label, refused: media)
            }
        }
        let unaccepted = payload.subtracting(descriptor.accepts)
        if !unaccepted.isEmpty {
            throw .notAccepted(approach: descriptor.id, refused: unaccepted)
        }
    }
}
