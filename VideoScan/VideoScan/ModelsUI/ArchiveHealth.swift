// ArchiveHealth.swift
// The traffic-light archive-health summary type — moved verbatim out of
// Models/ArchiveModels.swift (refactor 2026-06-26, model decomposition
// step 2). ArchiveHealth is a wholly-UI value (never persisted; exists
// only to drive a badge), so it lives in the app-side ModelsUI/ group
// and keeps its SwiftUI dependency, leaving the domain file
// Foundation-only.

import SwiftUI

// MARK: - Archive Health (traffic-light summary)

enum ArchiveHealth {
    case safe            // green: reviewed, has A/V, backed up
    case inProgress      // yellow: partially classified or archived
    case needsAttention  // red: unreviewed, no backups
    case notApplicable   // junk — no badge

    var icon: String {
        switch self {
        case .safe:           return "checkmark.shield.fill"
        case .inProgress:     return "clock.badge.checkmark"
        case .needsAttention: return "exclamationmark.shield.fill"
        case .notApplicable:  return ""
        }
    }

    var color: Color {
        switch self {
        case .safe:           return .green
        case .inProgress:     return .yellow
        case .needsAttention: return .red
        case .notApplicable:  return .clear
        }
    }

    var label: String {
        switch self {
        case .safe:           return "Safe"
        case .inProgress:     return "In Progress"
        case .needsAttention: return "Needs Attention"
        case .notApplicable:  return ""
        }
    }

    var detail: String {
        switch self {
        case .safe:           return "Reviewed, has audio/video, backed up"
        case .inProgress:     return "Partially reviewed or archived"
        case .needsAttention: return "Not yet reviewed or backed up"
        case .notApplicable:  return ""
        }
    }
}
