// ProvenanceMenu.swift — the Catalog row menu's Provenance submenu
// (policy docs/guides/provenance_roles.md §In the app):
//   Provenance ▸ Find ▸ Master (sound)            (FindMasterMenuItem — reads only)
//   Provenance ▸ Set Role ▸ Master · Camera Original · … · Unknown
// A View, not a model extension (rule 12). Its body runs when the menu
// opens, on the clicked rows only: O(selection) digest lookups, O(1) store
// reads — never O(records). The click writes through ProvenanceRoleStore
// .set, the one engine (rule 4); this file holds no SQL and no commit.
//
// Checkmark: the current role of the selection's contents — for several,
// only when they all share it. A selection with a file lacking a full
// SHA-256, or a session that may not write (viewer, read-only, a job's
// hold), gets the Set Role submenu disabled with the reason as its tooltip.
// Master asks once, with the "source not in the catalog" checkbox.
//
// (For Rick: `Toggle` inside a `Menu` is how SwiftUI spells a checkmarked
// NSMenuItem; `Binding(get:set:)` ≈ a property with a getter/setter pair.)

import AppKit
import SwiftUI
import VideoScanCore

struct ProvenanceMenu: View {
    /// NOT observed (a catalog change must not re-render a menu): read once
    /// when the menu is built.
    let model: VideoScanModel
    let recordIDs: Set<UUID>

    var body: some View {
        Menu(ProvenanceRoleWords.menuTitle) {
            Menu(ProvenanceRoleWords.findTitle) {
                FindMasterMenuItem(model: model, recordIDs: recordIDs)
            }
            SetRoleMenu(store: model.provenanceRoles,
                        targets: ProvenanceRoleTargets(records: recordIDs.compactMap { model.record(forID: $0) }))
        }
    }
}

struct SetRoleMenu: View {
    let store: ProvenanceRoleStore
    let targets: ProvenanceRoleTargets

    /// Why Set Role is unavailable for this selection now; nil = available.
    static func refusal(targets: ProvenanceRoleTargets, writeRefusal: String?) -> String? {
        if let why = targets.refusal { return why }
        if targets.digests.isEmpty { return ProvenanceRoleWords.noDigestHelp }
        return writeRefusal.map { "No role can be set now: \($0)." }
    }

    var body: some View {
        let refusal = Self.refusal(targets: targets, writeRefusal: store.writeRefusal)
        let current = store.commonRole(of: targets.digests)
        Menu(ProvenanceRoleWords.setRoleTitle) {
            ForEach(ProvenanceRole.allCases, id: \.self) { role in
                Toggle(role.title, isOn: Binding(get: { current == role }, set: { _ in choose(role) }))
            }
        }
        .disabled(refusal != nil)
        .help(refusal ?? ProvenanceRoleWords.setRoleHelp)
    }

    private func choose(_ role: ProvenanceRole) {
        var sourceMissing = false
        if role == .master {
            guard let answer = ProvenanceRoleDialogs.confirmMaster(contents: targets.digests.count) else { return }
            sourceMissing = answer.sourceMissing
        }
        if case .refused(let words) = store.set(role, digests: targets.digests, sourceMissing: sourceMissing, files: targets.total) {
            ProvenanceRoleDialogs.refused(words)
        }
    }
}

/// The two small native dialogs Set Role may show.
@MainActor
enum ProvenanceRoleDialogs {

    struct MasterAnswer { let sourceMissing: Bool }

    /// nil = cancelled.
    static func confirmMaster(contents: Int) -> MasterAnswer? {
        let alert = NSAlert()
        alert.messageText = ProvenanceRoleWords.masterQuestion(contents: contents)
        alert.informativeText = ProvenanceRoleWords.masterExplanation
        let checkbox = NSButton(checkboxWithTitle: ProvenanceRoleWords.sourceMissingCheckbox, target: nil, action: nil)
        checkbox.state = .off
        alert.accessoryView = checkbox
        alert.addButton(withTitle: ProvenanceRoleWords.masterConfirmButton)
        alert.addButton(withTitle: ProvenanceRoleWords.cancelButton)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return MasterAnswer(sourceMissing: checkbox.state == .on)
    }

    static func refused(_ words: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = ProvenanceRoleWords.refusedTitle
        alert.informativeText = words.prefix(1).uppercased() + words.dropFirst() + "."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
