// FamilyTreeMapView.swift
// The Family Map (GH #227 stage 2; Rick 2026-09-29 approved MapKit:
// "professional, impress Donna and other family"). A real map — coastlines,
// towns, pan and zoom — with the historic counties of England, Scotland and
// Wales, the counties of Ireland, the US states and the Canadian provinces
// drawn over it and SHADED by how many of the walked ancestors were born
// there. Click a region and the side panel names them.
//
// WHAT YOU SEE. Every bundled unit has a thin outline, so the counties read
// as a map even before the tiles arrive (or with no network at all — the
// polygons are ours, a missing tile only greys the background). A unit
// with births is filled in its dominant line's colour (Rick's blue, Donna's
// rose, violet for both — the fan's `TreeWalkPalette`), darker the more
// people, on a log ramp so a county with 30 births still shows next to one
// with 600. The twelve busiest units carry a name-and-count label. The
// camera opens on the box around every shaded unit; "Fit" brings it back.
//
// THE SIDE PANEL. With a region selected: its count line, the line chips,
// the top surnames and the people nearest generation first — each with
// what was recorded ("recorded as Massachusetts Bay Colony", the approved
// colonial tooltip) or, when the tree was blank and the family's notes
// placed them, "from the family's notes: Cork, Ireland". With NOTHING
// selected: the totals, the busiest regions, and "Not on the map" — the
// people the map could not place, nearest generation first, split
// honestly into "no recorded place" and "recorded but off the map"
// (Berlin, Germany). A country outline's count line says "county
// unresolved", never "not recorded": "Lothian, Scotland" WAS recorded.
//
// COST (no O(people) work in any view body): the counts, shades, labels,
// camera box and the unplaced list are computed off-main by
// `FamilyMapModel` and published together; this body reads dictionaries by
// key and lists that are already capped. The MKPolygons for the bundled
// units are built once per process (`FamilyMapShapes`, ~1 MB for ~60k
// vertices) and reused by every walk. A click is a few point-in-polygon
// lookups over ≤ 189 bounding boxes.
//
// LINKING. `Map` lives in the `_MapKit_SwiftUI` overlay; on macOS 27 an
// `import AVKit` alone did not link AVKit itself and `VideoPlayer` aborted
// at first use (52abfaaa). MapKit.framework is linked in the project AND
// `mapKitLinkAnchor()` names a real MapKit class here; `MapKitLinkSensorTests`
// pins the link. Measured 2026-09-29: because this file also uses MKPolygon
// and MKCoordinateRegion (real MapKit symbols, not overlay ones), the
// autolinker already pulls MapKit in even without the project entry — the
// explicit link is belt-and-braces for the day those uses are refactored away.
//
// (For Rick: `MapReader` ≈ a wrapper that hands you a proxy with a
// screen-point → lat/lon conversion; `@MapContentBuilder` closures are the
// DSL the Map draws from, like a ViewBuilder for map layers.)

import MapKit
import SwiftUI
import VideoScanCore

/// A real function returning a real MapKit class, called from the view
/// body, so the linker cannot drop MapKit.framework (see 52abfaaa: a bare
/// `let _ = X.self` in a body is discarded).
func mapKitLinkAnchor() -> AnyClass { MKMapView.self }

// MARK: - The unit polygons, once per process

/// The bundled units as MKPolygons (outer ring + holes as interior
/// polygons). Built once per distinct unit set — the bundled file in the
/// app, synthetic sets in tests — and kept for the process: an MKPolygon is
/// immutable, and rebuilding ~60k vertices per walk would be waste.
@MainActor
enum FamilyMapShapes {
    struct Piece: Identifiable {
        /// "eng-yorkshire#0" — one per polygon piece of a unit.
        let id: String
        let key: String
        let polygon: MKPolygon
    }

    private static var cache: [String: [Piece]] = [:]

    /// A cheap identity for a unit set: the bundled file always yields the
    /// same string; two different synthetic sets in one test process almost
    /// never collide (count, first and last key, total vertices).
    static func fingerprint(_ units: FamilyMapUnits) -> String {
        let vertices = units.units.reduce(0) { n, u in n + u.polygons.reduce(0) { $0 + $1.outer.count } }
        return "\(units.count)/\(units.units.first?.key ?? "")/\(units.units.last?.key ?? "")/\(vertices)"
    }

    static func pieces(for units: FamilyMapUnits) -> [Piece] {
        let id = fingerprint(units)
        if let cached = cache[id] { return cached }
        var out: [Piece] = []
        for unit in units.units {
            for (i, polygon) in unit.polygons.enumerated() {
                let holes = polygon.holes.map { ring -> MKPolygon in
                    let c = ring.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    return MKPolygon(coordinates: c, count: c.count)
                }
                let outer = polygon.outer.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                let shape = MKPolygon(coordinates: outer, count: outer.count, interiorPolygons: holes.isEmpty ? nil : holes)
                out.append(Piece(id: "\(unit.key)#\(i)", key: unit.key, polygon: shape))
            }
        }
        cache[id] = out
        return out
    }
}

// MARK: - The view

struct FamilyTreeMapView: View {
    @ObservedObject var model: FamilyMapModel
    /// The Highlight checks drive the map's filter; the panel offers Clear.
    @ObservedObject var highlighter: TreeWalkHighlighter
    let onBack: () -> Void

    /// A camera region in plain degrees — MapKit-free so a test can pin it
    /// without importing MapKit (which would load the framework from the
    /// test bundle and blind the link sensor).
    struct CameraRegion: Equatable {
        let centerLatitude: Double
        let centerLongitude: Double
        let latitudeDelta: Double
        let longitudeDelta: Double
    }

    /// The box around the shaded units, padded so the outermost county
    /// does not touch the edge, never tighter than 0.6° (one county alone
    /// still shows its neighbours) and never wider than the world.
    static func cameraRegion(for box: FamilyMap.BoundingBox, padding: Double = 1.25) -> CameraRegion {
        let latSpan = min(170, max(0.6, (box.maxLatitude - box.minLatitude) * padding))
        let lonSpan = min(340, max(0.6, (box.maxLongitude - box.minLongitude) * padding))
        return CameraRegion(centerLatitude: box.center.latitude, centerLongitude: box.center.longitude,
                            latitudeDelta: latSpan, longitudeDelta: lonSpan)
    }

    @State private var position: MapCameraPosition = .automatic
    @State private var fitted = false

    var body: some View {
        let _ = mapKitLinkAnchor()
        HStack(alignment: .top, spacing: 16) {
            map
                .frame(minWidth: TreeWalkAnimationView.minimumFan, maxWidth: .infinity,
                       minHeight: TreeWalkAnimationView.minimumFan, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            sidePanel
                .frame(width: TreeWalkAnimationView.sidePanelWidth, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear { fitIfPossible(force: false) }
        .onChange(of: model.computed.cameraBox) { _, _ in fitIfPossible(force: false) }
    }

    // MARK: The map

    private var map: some View {
        let pieces = FamilyMapShapes.pieces(for: model.units)
        let shades = model.computed.shades
        let selected = model.selectedKey
        return MapReader { proxy in
            Map(position: $position, interactionModes: .all) {
                ForEach(pieces) { piece in
                    let shade = shades[piece.key]
                    let isSelected = piece.key == selected
                    MapPolygon(piece.polygon)
                        .foregroundStyle(shade.map { TreeWalkPalette.color($0.line).opacity($0.opacity) } ?? Color.clear)
                        .stroke(isSelected ? Color.white : Color.white.opacity(0.55), lineWidth: isSelected ? 2.5 : 0.7)
                }
                ForEach(model.computed.labels) { label in
                    Annotation(label.name, coordinate: CLLocationCoordinate2D(latitude: label.latitude, longitude: label.longitude),
                               anchor: .center) {
                        Text("\(label.name) · \(label.count.formatted())")
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.regularMaterial, in: Capsule())
                            .allowsHitTesting(false)
                    }
                    .annotationTitles(.hidden)   // the capsule carries the name; no second label
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .onTapGesture { point in
                guard let c = proxy.convert(point, from: .local) else { return }
                model.select(coordinate: FamilyMap.Coordinate(latitude: c.latitude, longitude: c.longitude))
            }
        }
    }

    private func fitIfPossible(force: Bool) {
        guard force || !fitted, let box = model.computed.cameraBox else { return }
        fitted = true
        withAnimation(.easeInOut(duration: 0.6)) { position = .region(Self.mkRegion(Self.cameraRegion(for: box))) }
    }

    private func look(at unit: FamilyMapUnits.Unit) {
        withAnimation(.easeInOut(duration: 0.6)) { position = .region(Self.mkRegion(Self.cameraRegion(for: unit.cameraBox, padding: 2.2))) }
    }

    private static func mkRegion(_ r: CameraRegion) -> MKCoordinateRegion {
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: r.centerLatitude, longitude: r.centerLongitude),
                           span: MKCoordinateSpan(latitudeDelta: r.latitudeDelta, longitudeDelta: r.longitudeDelta))
    }

    // MARK: The side panel

    private var sidePanel: some View {
        let c = model.computed
        return VStack(alignment: .leading, spacing: 8) {
            Text("Where they were born").font(.headline)
            Text(FamilyMapModel.totalsLine(c.totals))
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            if !model.selection.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text("Counting only the people checked in Highlight.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Button("Clear") { highlighter.clear() }.controlSize(.small)
                }
            }
            if let problem = model.problem {
                Text(problem).font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            legend
            HStack {
                Button("Fit") { fitIfPossible(force: true) }
                Button("Back to the fan") { onBack() }
            }
            .controlSize(.small)
            Divider()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    if let unit = model.selectedUnit, let count = model.selectedCount {
                        selectedUnit(unit, count)
                    } else {
                        busiest(c.labels)
                        notOnTheMap(c)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.07)))
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach([TreeWalk.Line.first, .second, .both], id: \.self) { line in
                HStack(spacing: 4) {
                    Circle().fill(TreeWalkPalette.color(line)).frame(width: 8, height: 8)
                    Text(TreeWalkPalette.lineName(line, names: model.displayNames)).font(.system(size: 10.5))
                }
            }
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private func busiest(_ labels: [FamilyMapModel.Label]) -> some View {
        Text(labels.isEmpty ? "No one on the fan has a recorded birthplace the map knows."
                            : "Click a shaded region, or one of the busiest:")
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        ForEach(labels) { label in
            Button {
                model.select(unitKey: label.key)
                if let unit = model.units.unit(forKey: label.key) { look(at: unit) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let shade = model.computed.shades[label.key] {
                        Circle().fill(TreeWalkPalette.color(shade.line)).frame(width: 8, height: 8)
                    }
                    Text(label.name).font(.system(size: 12))
                    Spacer(minLength: 6)
                    Text(label.count.formatted()).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// "Not on the map": the people the map could not place, nearest
    /// generation first, with what WAS recorded. Nothing when everyone is
    /// placed. The list is already capped by the model (`unplacedLimit`);
    /// the totals give the rest.
    @ViewBuilder private func notOnTheMap(_ c: FamilyMapModel.Computed) -> some View {
        if c.totals.unresolved > 0 {
            Divider().padding(.vertical, 4)
            Text("Not on the map").font(.system(size: 12, weight: .semibold))
            Text(FamilyMapModel.notOnTheMapLine(c.totals))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(c.unplaced.enumerated()), id: \.offset) { _, m in
                memberRow(m, note: FamilyMapModel.placeNote(recordedPlace: m.recordedPlace, fromFamilyNotes: false)
                             ?? "no recorded place")
            }
            let rest = c.totals.unresolved - c.unplaced.count
            if rest > 0 {
                Text("and \(rest.formatted()) more, further back")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func selectedUnit(_ unit: FamilyMapUnits.Unit, _ count: FamilyMapTally.UnitCount) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(unit.name).font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 6)
            Button("All regions") { model.select(unitKey: nil) }.controlSize(.mini)
        }
        Text(Self.countLine(unit: unit, count: count.people))
            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        // Line chips — the fan's colours, the fan's names.
        HStack(spacing: 6) {
            ForEach(TreeWalk.Line.allCases, id: \.self) { line in
                if let n = count.byLine[line], n > 0 {
                    Text("\(TreeWalkPalette.lineName(line, names: model.displayNames)) \(n.formatted())")
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(TreeWalkPalette.color(line).opacity(0.22)))
                }
            }
        }
        if !count.topSurnames.isEmpty {
            Text(count.distinctSurnames > count.topSurnames.count
                 ? "Top surnames (of \(count.distinctSurnames.formatted()))" : "Surnames")
                .font(.system(size: 12, weight: .semibold)).padding(.top, 4)
            ForEach(Array(count.topSurnames.enumerated()), id: \.offset) { _, s in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(s.surname).font(.system(size: 12))
                    Spacer(minLength: 6)
                    Text(s.count.formatted()).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        if !count.members.isEmpty {
            Divider().padding(.vertical, 4)
            Text(count.people > count.members.count
                 ? "The nearest \(count.members.count) of \(count.people.formatted())" : "Who they are")
                .font(.system(size: 12, weight: .semibold))
            ForEach(Array(count.members.enumerated()), id: \.offset) { _, m in
                memberRow(m, note: FamilyMapModel.placeNote(recordedPlace: m.recordedPlace,
                                                            fromFamilyNotes: model.isPlacedFromFamilyNotes(m.id)))
            }
        }
    }

    /// One person: line dot, name, birth year, generation, and under it the
    /// recorded place ("recorded as Massachusetts Bay Colony" / "from the
    /// family's notes: Cork, Ireland" / "no recorded place"). The same text
    /// is the row's tooltip, for a long place that wraps.
    @ViewBuilder private func memberRow(_ m: FamilyMapTally.Member, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(TreeWalkPalette.color(m.line)).frame(width: 6, height: 6)
                Text(m.name.isEmpty ? m.id : m.name).font(.system(size: 12))
                Spacer(minLength: 6)
                Text(m.birthYear.map { "b. \($0)" } ?? "").font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(m.generation.map { "gen \($0)" } ?? "").font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let note {
                Text(note).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.leading, 12)
            }
        }
        .help(note ?? "")
    }

    /// "42 people born in Yorkshire, England" — or, for a country outline,
    /// the honest "county unresolved": the place WAS recorded ("Lothian,
    /// Scotland", "New England"), the map just cannot pin one county /
    /// state to it, so the outline is never read as the whole country's
    /// total (people with a county shade the county only). The member rows
    /// say what was recorded.
    static func countLine(unit: FamilyMapUnits.Unit, count: Int) -> String {
        let people = "\(count.formatted()) \(count == 1 ? "person" : "people")"
        if unit.kind == .country {
            let finer: String
            switch unit.country.unitKind {
            case .state: finer = "state"
            case .province: finer = "province"
            default: finer = "county"
            }
            return "\(people) born in \(unit.name), \(finer) unresolved"
        }
        return "\(people) born in \(unit.name), \(unit.country.label)"
    }
}
