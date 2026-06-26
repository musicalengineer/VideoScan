// MediaClassification+Presentation.swift
// SwiftUI display-only accessors for the media classification enums —
// the Color computed properties lifted OFF the pure-domain enums in
// Models/MediaClassification.swift (refactor 2026-06-26, model
// decomposition step 2). The domain enums stay Foundation-only so the
// Models/ group can later be lifted into a Swift package; these UI
// accessors live in the app-side ModelsUI/ group.

import SwiftUI

extension PairConfidence {
    var color: Color {
        switch self {
        case .high:   return Color.green.opacity(0.22)
        case .medium: return Color.orange.opacity(0.22)
        case .low:    return Color.clear
        }
    }

    var textColor: Color {
        switch self {
        case .high:   return .green
        case .medium: return .orange
        case .low:    return .secondary
        }
    }
}

extension DuplicateConfidence {
    var textColor: Color {
        switch self {
        case .high:   return .red
        case .medium: return .orange
        case .low:    return .yellow
        }
    }
}

extension DuplicateDisposition {
    var textColor: Color {
        switch self {
        case .none:      return .secondary
        case .keep:      return .green
        case .review:    return .orange
        case .extraCopy: return .red
        }
    }
}
