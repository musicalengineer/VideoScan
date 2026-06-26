// DestinationPolicy.swift
// The archival-destination suitability enum — moved verbatim out of
// Models/VolumeStatusEnums.swift (refactor 2026-06-26, model
// decomposition step 2). DestinationPolicy is a wholly-UI value (never
// persisted; computed on demand to drive badges/labels), so it lives in
// the app-side ModelsUI/ group and keeps its SwiftUI dependency, leaving
// the domain file Foundation-only. The CatalogScanTarget.destinationPolicy
// computed property that produces it also lives in ModelsUI/.

import SwiftUI

// MARK: - Destination Policy (computed)

/// How appropriate a volume is as a *destination* for archived media.
/// Pure function of role + trust + mediaTech + age + reachability.
enum DestinationPolicy: String {
    case preferred
    case acceptable
    case discouraged
    case forbidden

    var label: String {
        switch self {
        case .preferred:   return "Preferred"
        case .acceptable:  return "Acceptable"
        case .discouraged: return "Discouraged"
        case .forbidden:   return "Forbidden"
        }
    }

    var color: Color {
        switch self {
        case .preferred:   return .green
        case .acceptable:  return .yellow
        case .discouraged: return .orange
        case .forbidden:   return .red
        }
    }

    var icon: String {
        switch self {
        case .preferred:   return "checkmark.seal.fill"
        case .acceptable:  return "checkmark.circle"
        case .discouraged: return "exclamationmark.triangle.fill"
        case .forbidden:   return "xmark.octagon.fill"
        }
    }
}
