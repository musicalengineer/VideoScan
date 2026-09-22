// ArchiveAngel.swift
// The Archive Angel's ONE front door (docs/archive_angel_consolidation_plan.md,
// "Target architecture"). The rest of the app talks to `model.archiveAngel`;
// everything else under ArchiveAngel/ is the module's inside.
//
// S1 (this commit): a thin FORWARDING façade over the four stored Angel
// properties the model still owns — no behaviour moves yet. S2 turns it into
// the owner (evidence store, sweep, attention memory, settings, batches) and
// composes it from seams (ArchiveAngel/Seams/).
//
// (For Rick: think of this as the module's public header. The app includes
// only this; ArchiveAngelBoundarySensorTests fails the build's test run if
// app code outside ArchiveAngel/ reaches past it.)

import Combine
import Foundation

@MainActor
final class ArchiveAngel: ObservableObject {

    /// What the catalog shows for a record (grade, score, why-lines, floor).
    typealias Evidence = ArchiveAngelEvidenceRecord
    /// The catalog row's "Promote me" / "Worth a look" chip.
    typealias Badge = ArchiveAngelCatalogBadge

    /// S1 only: the model still owns the stored pieces. `unowned` ≈ a C++
    /// raw back-pointer to the owner — the model holds this façade, so the
    /// façade never outlives it (S2 removes the back-pointer).
    private unowned let model: VideoScanModel

    init(model: VideoScanModel) {
        self.model = model
    }

    // MARK: Recommend (O(1) reads — safe in a row or an inspector)

    var store: ArchiveAngelEvidenceStore { model.archiveAngelStore }
    var sweep: ArchiveAngelSweep { model.archiveAngelSweep }
    var attention: ArchiveAngelAttentionStore { model.archiveAngelAttention }

    /// Grade A + B ids — the catalog's "Archive candidates" filter set.
    var candidateIDs: Set<UUID> { store.candidateIDs }

    func evidence(for id: UUID) -> Evidence? { store.record(for: id) }

    func badge(for id: UUID) -> Badge? { ArchiveAngelCatalogBadge.make(for: store.record(for: id)) }
}
