// VolumesWindow+Editor.swift
// The right-hand detail editor for a single volume — extracted verbatim
// from VolumesWindow.swift (refactor 2026-06-25): the VolumeEditor view
// (header, relocated banner, workflow / hardware / notes sections, the
// Detect Hardware probe, and the purchase-year / capacity commit helpers).
// VolumeEditor is a standalone SwiftUI view with no dependency on
// VolumesWindow's `self`, so it moves as a whole type rather than into an
// extension. It lost its `private` because VolumesWindow's body (still in
// the main file) instantiates it across the file boundary — Swift `private`
// is file-scoped. Its own helpers stay `private` because they are only
// referenced within THIS file.
// (Swift file split ≈ C++ splitting a translation unit: `private` here
// means file-private to THIS .swift file.)

import SwiftUI

// MARK: - Editor

struct VolumeEditor: View {
    @EnvironmentObject var model: VideoScanModel
    @ObservedObject var target: CatalogScanTarget

    @State private var purchaseYearText: String = ""
    @State private var capacityTBText: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                // 2026-05-31: "Relocated to" indicator. Sits between the
                // Volume ID header and the Workflow picker so users see
                // at a glance that the catalog for this drive now lives
                // somewhere else. Shows nothing when no records have
                // moved off this volume.
                if let summary = relocatedSummary {
                    relocatedBanner(summary)
                }
                Divider()
                workflowSection
                Divider()
                hardwareSection
                Divider()
                notesSection
                Spacer(minLength: 8)
            }
            .padding(20)
        }
        .onAppear { syncTextFields() }
        .onChange(of: target.id) { syncTextFields() }
    }

    /// Compute the relocated-to summary for the current target. Reads
    /// `model.records` so the banner updates live when a Relocate job
    /// finishes and the @Published records array changes. Returns nil
    /// when no records originated on this volume OR all of them are still
    /// resident here.
    private var relocatedSummary: VideoScanModel.RelocatedDestinationSummary? {
        let leaf: String = {
            if let last = target.searchPath.split(separator: "/").last {
                return String(last)
            }
            return target.searchPath
        }()
        return VideoScanModel.relocatedDestinationSummary(
            sourceVolumeRootPath: target.searchPath,
            sourceVolumeName: leaf,
            allRecords: model.records
        )
    }

    /// Blue-tinted banner. SF Symbol arrow + headline + monospaced
    /// destination path + count subtitle. Path is `textSelection(.enabled)`
    /// so the user can copy it.
    @ViewBuilder
    private func relocatedBanner(_ s: VideoScanModel.RelocatedDestinationSummary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(.blue)
            VStack(alignment: .leading, spacing: 3) {
                Text("Migrated to:")
                    .font(.callout.weight(.semibold))
                    .foregroundColor(.blue)
                Text(s.dominantDestinationPath)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(relocatedSubtitle(s))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 4)
        }
        .padding(10)
        .background(Color.blue.opacity(0.10))
        .cornerRadius(6)
        .accessibilityIdentifier("volumeEditor.relocatedBanner")
    }

    /// "<moved> of <total> records moved" + optional
    /// "(... and N more on other volumes)".
    private func relocatedSubtitle(_ s: VideoScanModel.RelocatedDestinationSummary) -> String {
        let recordWord = s.movedRecordCount == 1 ? "record" : "records"
        var base: String
        if s.movedRecordCount == s.totalOriginRecords {
            base = "All \(s.movedRecordCount) \(recordWord) moved."
        } else {
            base = "\(s.movedRecordCount) of \(s.totalOriginRecords) \(recordWord) moved."
        }
        if s.hasOtherDestinations {
            let volWord = s.otherDestinationVolumeCount == 1 ? "volume" : "volumes"
            base += " (… and \(s.otherDestinationVolumeCount) more on other \(volWord).)"
        }
        return base
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: target.role.icon)
                    .font(.system(size: 32))
                    .foregroundColor(target.role.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(VolumeReachability.displayLabel(forPath: target.searchPath))
                        .font(.title.bold())
                    Text(target.searchPath)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                // §1B: retired drives don't show a destination-policy
                // badge — they're not viable destinations. The retired
                // banner below tells the whole story.
                if !target.isRetired {
                    PolicyBadge(policy: target.destinationPolicy)
                        .scaleEffect(1.15)
                }
            }
            // §1B: retired status replaces the online/offline line. A
            // retired drive being offline is the expected steady state,
            // so the "Offline" badge would be noise; instead we show
            // when + why it was retired.
            if target.isRetired {
                retiredStatusLine
            } else {
                HStack(spacing: 6) {
                    Image(systemName: target.isReachable ? "checkmark.circle.fill" : "wifi.slash")
                        .foregroundColor(target.isReachable ? .green : .orange)
                    Text(target.isReachable ? "Online" : "Offline")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    /// Retired drives get a brown archive banner with the date stamp +
    /// reason. The Reinstate affordance lives in the sidebar context
    /// menu, not here — clicking through to the editor is read-only for
    /// retired volumes (matches the "fully reversible, just not via
    /// every surface" UX).
    @ViewBuilder
    private var retiredStatusLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "archivebox.fill")
                .foregroundColor(.brown)
            VStack(alignment: .leading, spacing: 2) {
                Text("Retired" + (target.retiredAt.map { " on \(Self.shortDateStamp($0))" } ?? ""))
                    .font(.callout.bold())
                    .foregroundColor(.brown)
                if let reason = target.retiredReason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let w = target.retiredWitnesses, !w.isEmpty {
                    Text("\(w.count) witness path(s) recorded.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color.brown.opacity(0.08))
        .cornerRadius(6)
        .accessibilityIdentifier("volumeEditor.retiredBanner")
    }

    static func shortDateStamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: d)
    }

    private var workflowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Workflow").font(.title3.bold())
            HStack(alignment: .top, spacing: 24) {
                pickerColumn(title: "Role") {
                    // Display-only roles: the Master Archive (Archive is set
                    // by Initialize, never picked) and the boot volume
                    // (System is auto-assigned). Everything else gets the
                    // user-selectable list — never `allCases`.
                    if model.isMasterArchive(target) || target.isBootVolumeRoot {
                        HStack(spacing: 6) {
                            Image(systemName: target.role.icon)
                                .foregroundColor(target.role.color)
                            Text(target.role.rawValue)
                            Text(model.isMasterArchive(target)
                                 ? "(set by Initialize)"
                                 : "(boot volume)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: 220, alignment: .leading)
                        .accessibilityIdentifier("volumeEditor.roleDisplayOnly")
                    } else {
                        Picker("", selection: Binding(
                            get: { target.role },
                            set: { model.setRole($0, for: target) }
                        )) {
                            ForEach(VolumeRole.pickerChoices(including: target.role), id: \.self) { r in
                                Label(r.rawValue, systemImage: r.icon).tag(r)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                    }
                    if target.isRetired {
                        Text("Retired — retirement is a badge on any role, not a role itself.")
                            .font(.caption)
                            .foregroundColor(.brown)
                    }
                }
                pickerColumn(title: "Reliability") {
                    Picker("", selection: Binding(
                        get: { target.trust },
                        set: { model.setTrust($0, for: target) }
                    )) {
                        ForEach(VolumeTrust.allCases, id: \.self) { t in
                            Label(t.rawValue, systemImage: t.icon).tag(t)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                Spacer()
            }
        }
    }

    private var hardwareSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Hardware").font(.title3.bold())
                Spacer()
                Button {
                    detectHardware()
                } label: {
                    Label("Detect Hardware", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
                .disabled(!target.isReachable)
                .help(target.isReachable
                      ? "Auto-fill filesystem and capacity from the mounted volume"
                      : "Volume offline — connect it to detect hardware")
            }
            HStack(alignment: .top, spacing: 24) {
                pickerColumn(title: "Media") {
                    Picker("", selection: Binding(
                        get: { target.mediaTech },
                        set: { model.setMediaTech($0, for: target) }
                    )) {
                        ForEach(VolumeMediaTech.allCases, id: \.self) { m in
                            Label(m.rawValue, systemImage: m.icon).tag(m)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }
                pickerColumn(title: "Filesystem") {
                    TextField("APFS, exFAT, …", text: Binding(
                        get: { target.filesystem },
                        set: { model.setFilesystem($0, for: target) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                }
                Spacer()
            }
            HStack(alignment: .top, spacing: 24) {
                pickerColumn(title: "Purchased (year)") {
                    TextField("YYYY", text: $purchaseYearText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onChange(of: purchaseYearText) { _, _ in commitPurchaseYear() }
                        .onSubmit { commitPurchaseYear() }
                }
                pickerColumn(title: "Capacity (TB)") {
                    TextField("0.0", text: $capacityTBText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onChange(of: capacityTBText) { _, _ in commitCapacity() }
                        .onSubmit { commitCapacity() }
                }
                Spacer()
            }
            // Drive Health card — sits at the bottom of Hardware so
            // the SMART-driven recommendation is right next to the
            // manual Reliability/purchase-year fields it informs.
            // Retired/offline drives skip the card entirely; the rest
            // get an async probe.
            if !target.isRetired {
                DriveHealthCard(target: target)
                    .padding(.top, 4)
            }
        }
    }

    /// Pull filesystem name and total capacity from the live mount via
    /// URLResourceValues. Media tech and purchase year stay user-driven —
    /// macOS doesn't expose "is this RAID-0?" or purchase date.
    private func detectHardware() {
        let url = URL(fileURLWithPath: target.searchPath)
        let keys: Set<URLResourceKey> = [
            .volumeLocalizedFormatDescriptionKey,
            .volumeTotalCapacityKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return }

        if let fs = values.volumeLocalizedFormatDescription, !fs.isEmpty {
            model.setFilesystem(fs, for: target)
        }
        if let bytes = values.volumeTotalCapacity, bytes > 0 {
            let tb = Double(bytes) / 1_000_000_000_000.0
            model.setCapacityTB(tb, for: target)
            capacityTBText = String(format: "%.2f", tb)
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes").font(.title3.bold())
            TextEditor(text: Binding(
                get: { target.notes },
                set: { model.setNotes($0, for: target) }
            ))
            .font(.system(size: 14))
            .frame(minHeight: 100, maxHeight: 220)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
        }
    }

    // MARK: Helpers

    private func pickerColumn<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout)
                .foregroundColor(.secondary)
            content()
        }
    }

    private func syncTextFields() {
        purchaseYearText = target.purchaseYear.map(String.init) ?? ""
        capacityTBText = target.capacityTB.map { String(format: "%.2f", $0) } ?? ""
    }

    private func commitPurchaseYear() {
        let trimmed = purchaseYearText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            model.setPurchaseYear(nil, for: target)
        } else if let y = Int(trimmed), (1990...2100).contains(y) {
            model.setPurchaseYear(y, for: target)
        }
        // else: partial / invalid input — don't reset; let user keep typing.
        // syncTextFields() will restore saved value on next re-open if needed.
    }

    private func commitCapacity() {
        let trimmed = capacityTBText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            model.setCapacityTB(nil, for: target)
        } else if let v = Double(trimmed), v > 0 {
            model.setCapacityTB(v, for: target)
        }
        // else: partial / invalid input — don't reset; let user keep typing.
    }
}
