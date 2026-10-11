import SwiftUI

// MARK: - Diagnostic banners, drawn (Rick 2026-10-10)
//
//   DiagnosticBannerView  the full banner: a filled severity badge with the
//                         symbol, the bold headline, the next step, and
//                         the one action button (Repair…).
//   DiagnosticChip        the compact form for a collapsed MFO row
//                         ("2 of 5 have no sound"), same colours.
//   MediaRepairLauncher   how a button deep in a view tree opens the
//                         Repair sheet: an environment value the window
//                         that can present the sheet injects
//                         (≈ a C++ callback handed down through a context
//                         object, instead of threaded through every ctor).
//
// Legibility rule (light AND dark mode): text is never drawn in yellow. The
// colour lives in the badge fill (symbol drawn black on yellow), the tinted
// background and the border; headline and next step use `.primary`.
// Content, not navigation: plain fills, no Liquid Glass.

extension DiagnosticSeverity {

    /// The badge fill / border colour: system yellow, red, blue.
    var tint: Color {
        switch self {
        case .warning: return .yellow
        case .error: return .red
        case .info: return .blue
        }
    }

    /// The symbol's colour on the badge: black on yellow, white otherwise.
    var symbolColor: Color {
        self == .warning ? .black : .white
    }

    var accessibilityWord: String {
        switch self {
        case .warning: return "Warning"
        case .error: return "Problem"
        case .info: return "Note"
        }
    }
}

struct DiagnosticBannerView: View {
    let banner: DiagnosticBanner
    /// nil = draw no button (e.g. a surface that can't open Repair).
    var onAction: (@MainActor (DiagnosticAction) -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            DiagnosticBadge(severity: banner.severity, symbol: banner.symbol, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.headline)
                    .font(.body.weight(.bold))
                    .foregroundStyle(.primary)
                Text(banner.nextStep)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if let action = banner.action, let onAction {
                Button(action.title) { onAction(action) }
                    .controlSize(.regular)
                    .help("Opens Repair with this diagnosis filled in. Nothing runs until you press Repair Now there; your original is never changed.")
                    .accessibilityIdentifier("diagnostic.\(banner.id).repair")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(banner.severity.tint.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(banner.severity.tint, lineWidth: 1.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(banner.severity.accessibilityWord): \(banner.headline). \(banner.nextStep)")
        .accessibilityIdentifier("diagnostic.\(banner.id)")
    }
}

/// The filled square with the symbol — the part the eye finds first.
struct DiagnosticBadge: View {
    let severity: DiagnosticSeverity
    let symbol: String
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(severity.symbolColor)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.22).fill(severity.tint))
            .accessibilityHidden(true)
    }
}

/// "2 of 5 have no sound" on a collapsed MFO row.
struct DiagnosticChip: View {
    let severity: DiagnosticSeverity
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            DiagnosticBadge(severity: severity, symbol: symbol, size: 16)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.leading, 3)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(severity.tint.opacity(0.22)))
        .overlay(Capsule().stroke(severity.tint, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("diagnostic.chip")
    }
}

// MARK: - Opening Repair from anywhere

/// Opens the Repair sheet for a prefill. Injected by a window that can
/// present it (MediaRepairLaunchHost); nil elsewhere, and then banners
/// draw no button rather than a button that does nothing.
struct MediaRepairLauncher {
    let open: @MainActor (MediaRepairPrefill) -> Void

    @MainActor func callAsFunction(_ prefill: MediaRepairPrefill) { open(prefill) }

    /// The banner's action handler, ready to hand to DiagnosticBannerView.
    var onAction: @MainActor (DiagnosticAction) -> Void {
        { [open] action in
            switch action {
            case .repair(let prefill): open(prefill)
            }
        }
    }
}

private struct MediaRepairLauncherKey: EnvironmentKey {
    static let defaultValue: MediaRepairLauncher? = nil
}

extension EnvironmentValues {
    var mediaRepairLauncher: MediaRepairLauncher? {
        get { self[MediaRepairLauncherKey.self] }
        set { self[MediaRepairLauncherKey.self] = newValue }
    }
}

/// Lets a window that isn't the catalog (Media File Operations) open the
/// Repair sheet — and, from it, Verify… — on itself: the same sheets, the
/// same `.sheet(item:)` shape. The record is resolved by id at the click
/// (a rescan may have replaced the object since the job ran).
struct MediaRepairLaunchHost: ViewModifier {
    @EnvironmentObject private var model: VideoScanModel
    @EnvironmentObject private var center: MediaFileOperationsCenter
    @State private var repairRequest: MediaRepairSheetRequest?
    @State private var checkMediaRequest: CheckMediaRequest?

    func body(content: Content) -> some View {
        content
            .environment(\.mediaRepairLauncher, MediaRepairLauncher { prefill in open(prefill) })
            .sheet(item: $repairRequest) { MediaRepairSheet(request: $0) }
            .sheet(item: $checkMediaRequest) { CheckMediaSheet(request: $0) }
    }

    private func open(_ prefill: MediaRepairPrefill) {
        guard let rec = model.record(forID: prefill.recordID) else {
            model.log("Repair: that file is no longer in the catalog — it may have been removed or replaced by a re-scan.")
            return
        }
        repairRequest = MediaRepairSheetRequest(
            record: rec,
            audioDiagnosis: center.verifyDiagnosis(forRecordID: rec.id),
            onVerify: { checkMediaRequest = CheckMediaRequest(records: [rec]) },
            soundSource: prefill.soundSource)
    }
}
