// ArchiveAngelSettings.swift
// Every Archive Angel preference in ONE place, under the SAME UserDefaults
// keys it always had — a renamed key would silently reset Rick's choice
// (pinned by ArchiveAngelVocabularyTests / ArchiveAngelSettingsTests).
//
//   archiveAngel.sweepEnabled  Assess Continuously    (default ON; missing
//                              key → ON, only an explicit false turns it off)
//   archiveAngel.count         the start sheet's 10/25/35/50   (default 25)
//   archiveAngel.makeLossless  the FFV1 checkbox, also used by the catalog's
//                              "Prepare with Archive Angel"      (default off)
//   archiveAngel.checksEnabled Check Sound in the Background (Angel Checks,
//                              docs/archive_angel_wise_design.md §4; default
//                              ON; missing key → ON)
//   archiveAngel.footageAutoEnabled  Keep footage groups current (§5;
//                              default ON; missing key → ON)
//
// Before S2 the first lived in ArchiveAngelSweepSettings, the other two were
// @AppStorage literals in the start sheet, and the catalog read the third
// with a raw UserDefaults call. The façade owns the reads and writes now.

import Foundation

struct ArchiveAngelSettings: Equatable {
    static let sweepEnabledKey = "archiveAngel.sweepEnabled"
    static let batchCountKey = "archiveAngel.count"
    static let makeLosslessKey = "archiveAngel.makeLossless"
    static let checksEnabledKey = "archiveAngel.checksEnabled"
    static let footageAutoEnabledKey = "archiveAngel.footageAutoEnabled"
    /// When "Keep footage groups current" last STARTED a run (QA 2026-09-25
    /// MAJOR-4: a run that changes no answer leaves every record's
    /// `scannedAt` where it was, so the records cannot say "current").
    static let footageLastAutoRunAtKey = "archiveAngel.footageLastAutoRunAt"

    static let defaultBatchCount = 25

    var sweepEnabled: Bool = true
    var batchCount: Int = ArchiveAngelSettings.defaultBatchCount
    var makeLossless: Bool = false
    var checksEnabled: Bool = true
    var footageAutoEnabled: Bool = true

    /// Missing keys → the defaults above; a value of the wrong type → the
    /// default too (the @AppStorage behaviour the sheet had).
    static func restored(from defaults: UserDefaults) -> ArchiveAngelSettings {
        var s = ArchiveAngelSettings()
        if let stored = defaults.object(forKey: sweepEnabledKey) as? Bool { s.sweepEnabled = stored }
        if let stored = defaults.object(forKey: batchCountKey) as? Int { s.batchCount = stored }
        if let stored = defaults.object(forKey: makeLosslessKey) as? Bool { s.makeLossless = stored }
        if let stored = defaults.object(forKey: checksEnabledKey) as? Bool { s.checksEnabled = stored }
        if let stored = defaults.object(forKey: footageAutoEnabledKey) as? Bool { s.footageAutoEnabled = stored }
        return s
    }

    /// Each key is written only by its own setter (the start sheet, the
    /// catalog and the ⋯ menu change one at a time; writing all three
    /// would record defaults Rick never chose).
    static func saveSweepEnabled(_ on: Bool, to defaults: UserDefaults) { defaults.set(on, forKey: sweepEnabledKey) }
    static func saveBatchCount(_ n: Int, to defaults: UserDefaults) { defaults.set(n, forKey: batchCountKey) }
    static func saveMakeLossless(_ on: Bool, to defaults: UserDefaults) { defaults.set(on, forKey: makeLosslessKey) }
    static func saveChecksEnabled(_ on: Bool, to defaults: UserDefaults) { defaults.set(on, forKey: checksEnabledKey) }
    static func saveFootageAutoEnabled(_ on: Bool, to defaults: UserDefaults) { defaults.set(on, forKey: footageAutoEnabledKey) }
    /// The footage stamp is read and written only where it is safe: never
    /// in a test host still pointed at `.standard` (the app's own domain —
    /// Rick's real preferences). There it is nil / not written; the façade
    /// keeps it in memory instead.
    static func footageLastAutoRunAt(in defaults: UserDefaults, isTestHost: Bool) -> Date? {
        guard persistsFootageStamp(defaults, isTestHost: isTestHost) else { return nil }
        return defaults.object(forKey: footageLastAutoRunAtKey) as? Date
    }
    static func saveFootageLastAutoRunAt(_ at: Date, to defaults: UserDefaults, isTestHost: Bool) {
        guard persistsFootageStamp(defaults, isTestHost: isTestHost) else { return }
        defaults.set(at, forKey: footageLastAutoRunAtKey)
    }
    static func persistsFootageStamp(_ defaults: UserDefaults, isTestHost: Bool) -> Bool {
        !(isTestHost && defaults === UserDefaults.standard)
    }
}
