// VideoScanModel+ArchiveAngelSweep.swift
// Archive Angel phase 2 wiring: the model owns the evidence store and the
// background scoring sweep (`archiveAngelStore` / `archiveAngelSweep`,
// declared in VideoScanModel.swift beside the preview sweep); this file
// configures the sweep's closures, the launch trigger and the setting.

import Foundation

extension VideoScanModel {

    /// Called once at launch, right after configurePreviewSweep(). Loads
    /// the sidecar (off-main) so the catalog filter works immediately,
    /// then schedules the first scoring run. Test hosts never start a
    /// sweep: the setting is restored from the injected defaults and the
    /// launch trigger is skipped under a test bundle.
    func configureArchiveAngelSweep() {
        archiveAngelSweep.configure(ArchiveAngelSweep.Configuration(
            candidates: { [weak self] in self?.archiveAngelSweepCandidates() ?? [] },
            isExternallyBusy: { [weak self] in
                guard let self else { return true }
                if self.isScanning || self.isCombining { return true }
                return self.isMediaFileOperationBusyForAngel()
            },
            log: { [weak self] line in
                self?.log(line)
                appLog.write(line)
            }
        ), enabled: archiveAngelSweepSettings.enabled)

        guard !TestEnvironment.isTestHost else { return }
        Task { [weak self] in
            guard let self else { return }
            let loaded = await self.archiveAngelStore.load()
            // No sidecar, or one assessed under older rules: the grades
            // are needed now, not in 90 s — a pass is under 2 s.
            self.archiveAngelSweep.scheduleLaunchRun(delay: loaded ? nil : 15)
        }
    }

    /// Settings checkbox handler: persist + start/stop.
    func setArchiveAngelSweepEnabled(_ on: Bool) {
        archiveAngelSweepSettings.enabled = on
        archiveAngelSweepSettings.save(to: .standard)
        archiveAngelSweep.setEnabled(on)
        if on { archiveAngelSweep.rescoreNow() }
    }

    /// Scorer inputs for every active record. ONE keeper policy for the
    /// whole pass (it is the expensive part of the projection). Main actor,
    /// called by the sweep at plan time — never from a view body.
    func archiveAngelSweepCandidates() -> [ArchiveAngelCandidate] {
        let policy = duplicateKeeperPolicy()
        let active = pfActiveRecords(records)
        var out: [ArchiveAngelCandidate] = []
        out.reserveCapacity(active.count)
        for r in active {
            out.append(ArchiveAngelCandidate.project(r, model: self, policy: policy))
        }
        ArchiveAngelScorer.markDerivatives(&out)   // T10 H3: needs the whole set (one O(n) pass)
        return out
    }
}
