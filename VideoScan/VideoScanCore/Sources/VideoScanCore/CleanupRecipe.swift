// CleanupRecipe.swift
// The "Clean Up Video" recipe model — VideoScanCore (domain layer).
//
// A recipe is a named, versioned, ORDERED list of cleanup steps. V1 ships
// one built-in recipe ("VHS Quick Clean") defined as a code constant, but
// the model is fully Codable because future recipes will ship as JSON
// files (and may be authored outside the app). The Codable round-trip is
// therefore load-bearing, not decorative — CleanupTests pins it.
//
// Deliberately hooks, not a framework (Rick 2026-07-07): a step is just a
// kind + a flat string parameter bag + an enabled flag. Engines interpret
// the parameters; the model doesn't know what "hqdn3d" means. New step
// kinds (vidstab passes, CoreML frame models, tools not yet invented) are
// added to `CleanupStepKind` as they arrive.

import Foundation

// MARK: - Step kind

/// What a single cleanup step does, engine-agnostically. The raw string is
/// the JSON wire value — never rename a case's rawValue once shipped.
///
/// (Swift's String-raw-value enum ≈ a C++ enum class with to_string/
/// from_string built in; Codable uses the raw value automatically.)
public enum CleanupStepKind: String, Codable, Sendable, CaseIterable {
    /// Remove interlacing comb artifacts (bwdif in the v1 ffmpeg engine).
    /// Auto-skips when the source is already progressive.
    case deinterlace
    /// Mask VHS head-switching noise: crop N lines off the bottom edge and
    /// pad back to the original dimensions with black (SAR/DAR unchanged).
    case cropBottomNoise
    /// Light spatio-temporal denoise (hqdn3d in the v1 engine).
    case denoise
    /// Conservative levels/color touch-up. Deliberately subtle.
    case colorTouchUp
}

// MARK: - Step

/// One ordered entry in a recipe. `parameters` is a flat string→string bag
/// so recipes serialize to plain JSON and engines own the interpretation.
/// `familyLabel` is the plain-language line the confirmation sheet shows
/// ("Fix comb lines from old tapes") — friendly family language is a UI
/// requirement, so it travels WITH the recipe rather than being hardcoded
/// in a view.
public struct CleanupStep: Codable, Sendable, Equatable, Identifiable {
    public var kind: CleanupStepKind
    public var parameters: [String: String]
    public var enabled: Bool
    public var familyLabel: String

    /// One step per kind within a recipe (v1 invariant), so the kind is a
    /// stable identity for SwiftUI ForEach.
    public var id: String { kind.rawValue }

    public init(kind: CleanupStepKind,
                parameters: [String: String] = [:],
                enabled: Bool = true,
                familyLabel: String) {
        self.kind = kind
        self.parameters = parameters
        self.enabled = enabled
        self.familyLabel = familyLabel
    }
}

// MARK: - Recipe

/// A named, versioned cleanup recipe. `id` + `version` are the provenance
/// stamp written onto cleaned catalog records — bump `version` whenever a
/// recipe's steps/parameters change so old outputs remain attributable to
/// the exact recipe that produced them.
public struct CleanupRecipe: Codable, Sendable, Equatable, Identifiable {
    /// Stable machine id, e.g. "vhs-quick-clean". Never reuse across
    /// different recipes.
    public var id: String
    /// Bumped on any change to steps/parameters.
    public var version: Int
    /// Menu title, e.g. "VHS Quick Clean".
    public var displayName: String
    /// One-paragraph friendly description for the confirmation sheet.
    public var familyDescription: String
    /// Ordered steps — execution order is array order.
    public var steps: [CleanupStep]

    public init(id: String,
                version: Int,
                displayName: String,
                familyDescription: String,
                steps: [CleanupStep]) {
        self.id = id
        self.version = version
        self.displayName = displayName
        self.familyDescription = familyDescription
        self.steps = steps
    }
}

// MARK: - Registry

/// Built-in recipes. V1 defines them as code constants; the JSON pathway
/// (decode a bundled/user-provided .json into `CleanupRecipe`) is already
/// exercised by the Codable round-trip tests so shipping file-based
/// recipes later is a loader, not a model change.
public enum CleanupRecipeRegistry {

    /// "VHS Quick Clean" — the v1 low-hanging-fruit recipe: single-pass
    /// ffmpeg filtergraph (deinterlace → bottom-edge mask → light denoise
    /// → subtle color touch-up), audio stream-copied, ProRes LT output.
    public static let vhsQuickClean = CleanupRecipe(
        id: "vhs-quick-clean",
        version: 1,
        displayName: "VHS Quick Clean",
        familyDescription: "A gentle, all-in-one cleanup for videos captured from VHS and other old tapes. It smooths out the most common tape problems without changing the character of the footage — and it never touches your original file.",
        steps: [
            CleanupStep(
                kind: .deinterlace,
                parameters: ["mode": "send_field", "parity": "auto"],
                familyLabel: "Fix comb lines from old tapes"
            ),
            CleanupStep(
                kind: .cropBottomNoise,
                parameters: ["lines": "8"],
                familyLabel: "Trim video noise at the bottom edge"
            ),
            CleanupStep(
                kind: .denoise,
                // Gentle hqdn3d — half of ffmpeg's default strength
                // (default is 4:3:6:4.5). When in doubt, weaker.
                parameters: ["hqdn3d": "2:1.5:3:2.25"],
                familyLabel: "Reduce speckle and grain"
            ),
            CleanupStep(
                kind: .colorTouchUp,
                // Barely-there eq: +2% contrast, +5% saturation. No
                // brightness/gamma shift — old tapes vary too much to
                // guess a global level safely.
                parameters: ["eq": "contrast=1.02:saturation=1.05"],
                familyLabel: "Gently touch up color and brightness"
            )
        ]
    )

    /// Every recipe the "Clean Up Video" submenu offers, in menu order.
    public static let builtIn: [CleanupRecipe] = [vhsQuickClean]

    /// Lookup by stable id (provenance display, future JSON loading).
    public static func recipe(id: String) -> CleanupRecipe? {
        builtIn.first { $0.id == id }
    }
}
