// FamilyMapUnits.swift (VideoScanCore/FamilyMap)
// The bundled border file, decoded, and "which unit is this click in?"
// (GH #227 design §4). Foundation only — MKGeoJSONDecoder lives in MapKit,
// which stays out of Core so this is testable without a display and so
// the MapKit link hazard (52abfaaa) stays confined to the app.
//
// THE FILE. A GeoJSON FeatureCollection, WGS84, positions [lon, lat];
// geometry Polygon or MultiPolygon (outer ring first, holes after);
// properties `key`, `name`, `country` ∈ {ENG,SCT,WLS,NIR,IRL,USA,CAN},
// `kind` ∈ {county,state,province,country}. The decoder REFUSES a
// malformed key (wrong country prefix, not slug-shaped, a country unit
// whose key is not the bare country) — that is the join with the
// resolver, and a drift there would otherwise show as a silently empty
// county. A key that is well-formed but is not `unitKey(country, name)`
// is RECORDED in `keyNameMismatches`, not refused: the bundled file names
// usa-district-of-columbia "Washington" on purpose (the name is display,
// the key is the join), and a sensor test pins that list.
//
// POINT IN POLYGON. Bounding-box prefilter per unit and per polygon PIECE
// (Alaska's union box spans the globe; its pieces do not), then ONE pass
// over each candidate ring that does both jobs: even-odd ray casting
// (count the edges a horizontal ray from the point crosses; odd = inside)
// and an on-the-edge test. Even-odd makes holes fall out for free. A
// point ON a boundary is inside: a click on a county line still answers,
// and the tie between the two neighbours is broken deterministically —
// the unit with the SMALLER bounding box wins, so an enclave beats its
// enclosure (Cromartyshire's fragments inside Ross-shire), and equal
// areas fall back to the key.
//
// NEAREST. Natural Earth 1:50m coastlines are coarse — Halifax's
// waterfront falls outside Nova Scotia. `unit(nearest:withinDegrees:)` is
// the fallback when `unit(containing:)` is nil: the closest boundary
// EDGE (a superset of the nearest vertex, and what a click on a long
// simplified coast segment needs) among the pieces whose box, widened by
// the tolerance, holds the point. Degrees, not metres — at 0.15° the
// cos(latitude) distortion cannot change which coast is nearest.
//
// COST. Each ring carries a latitude-band edge index (built at decode),
// so a click visits ~8 edges per band instead of every edge, and the
// bbox prefilter is a raw scan of four flat columns. 1,000 clicks over
// 200 units × 300 vertices in a few ms even at -Onone; measured in
// FamilyMapUnitsTests, and the index is pinned against the plain scan.
//
// MEMORY. A 1.5 MB file is ~60k positions → ~1 MB of Coordinate storage
// plus ~0.3 MB of band indexes, resident; JSONSerialization needs ~10×
// the file transiently while decoding and frees it. No cache, nothing
// grows after init.
//
// (C++ readers: `struct` here is a value type with copy-on-write arrays;
// `throws` + `DecodeError` is the checked-exception idiom — the caller
// must `try`; `withUnsafeBufferPointer` hands the loop a raw T* + count.)

import Foundation

public struct FamilyMapUnits: Sendable {

    public struct Polygon: Sendable, Equatable {
        public let outer: [FamilyMap.Coordinate]
        public let holes: [[FamilyMap.Coordinate]]
        public let bbox: FamilyMap.BoundingBox
        /// Latitude-band edge indexes, outer ring first then the holes —
        /// built once here so a click touches ~n/bands edges, not n.
        let ringIndexes: [RingIndex]

        public init(outer: [FamilyMap.Coordinate], holes: [[FamilyMap.Coordinate]] = []) {
            self.outer = outer
            self.holes = holes
            self.bbox = FamilyMap.BoundingBox(around: outer)
                ?? FamilyMap.BoundingBox(minLatitude: 0, maxLatitude: 0, minLongitude: 0, maxLongitude: 0)
            self.ringIndexes = [RingIndex(ring: outer)] + holes.map { RingIndex(ring: $0) }
        }

        public static func == (a: Polygon, b: Polygon) -> Bool { a.outer == b.outer && a.holes == b.holes }
    }

    /// Which edges of a ring can touch a given latitude: the ring's
    /// latitude span cut into equal bands, each listing (CSR) the edges
    /// whose span overlaps it. An edge that crosses latitude y is in y's
    /// band, so even-odd parity over the band alone is exact. About
    /// 1.3 × n Int32 per ring (edges that straddle a band line are listed
    /// twice) — ~300 KB for the bundled file.
    struct RingIndex: Sendable {
        let minLatitude: Double
        let maxLatitude: Double
        let bands: Int
        let starts: [Int32]
        let edges: [Int32]

        init(ring: [FamilyMap.Coordinate]) {
            let n = ring.count
            var lo = Double.infinity, hi = -Double.infinity
            for p in ring {
                if p.latitude < lo { lo = p.latitude }
                if p.latitude > hi { hi = p.latitude }
            }
            if n == 0 { lo = 0; hi = 0 }
            minLatitude = lo
            maxLatitude = hi
            // Eight edges per band on average; one band for a tiny ring or
            // a degenerate (flat) one.
            let bandCount = (hi > lo && n >= 16) ? min(64, n / 8) : 1
            bands = bandCount
            let scale = hi > lo ? Double(bandCount) / (hi - lo) : 0
            func band(_ latitude: Double) -> Int {
                let b = Int((latitude - lo) * scale)
                return b < 0 ? 0 : (b >= bandCount ? bandCount - 1 : b)
            }
            // Edge e runs from ring[e - 1] (ring[n - 1] for e = 0) to ring[e].
            var counts = [Int32](repeating: 0, count: bandCount + 1)
            var spans: [(Int, Int)] = []
            spans.reserveCapacity(n)
            var j = n - 1
            for i in 0..<n {
                let a = ring[j].latitude, b = ring[i].latitude
                // Widened by the boundary tolerance so an on-the-line point
                // at a band edge still meets its edge.
                let first = band((a < b ? a : b) - 1e-9), last = band((a < b ? b : a) + 1e-9)
                spans.append((first, last))
                for k in first...last { counts[k + 1] += 1 }
                j = i
            }
            for k in 0..<bandCount { counts[k + 1] += counts[k] }
            var fill = counts
            var list = [Int32](repeating: 0, count: Int(counts[bandCount]))
            for (e, span) in spans.enumerated() {
                for k in span.0...span.1 {
                    list[Int(fill[k])] = Int32(e)
                    fill[k] += 1
                }
            }
            starts = counts
            edges = list
        }

        /// The band a latitude falls in, or nil when the ring cannot reach it.
        @inline(__always) func band(for latitude: Double, tolerance: Double) -> Int? {
            guard latitude >= minLatitude - tolerance, latitude <= maxLatitude + tolerance else { return nil }
            guard maxLatitude > minLatitude else { return 0 }
            let b = Int((latitude - minLatitude) * Double(bands) / (maxLatitude - minLatitude))
            return b < 0 ? 0 : (b >= bands ? bands - 1 : b)
        }
    }

    public struct Unit: Sendable, Equatable, Identifiable {
        public let key: String
        public let name: String
        public let country: FamilyMap.Country
        public let kind: FamilyMap.UnitKind
        public let polygons: [Polygon]
        /// The union of every piece — the containment prefilter.
        public let bbox: FamilyMap.BoundingBox
        /// Where the camera should look: the union of the pieces, EXCEPT
        /// that pieces east of +150° are ignored when the unit also has
        /// pieces in the western hemisphere. Alaska's Aleutian tail sits
        /// at 172…180° as separate pieces; a camera box that included it
        /// would span the whole Pacific.
        public let cameraBox: FamilyMap.BoundingBox
        public var id: String { key }

        public init(key: String, name: String, country: FamilyMap.Country, kind: FamilyMap.UnitKind, polygons: [Polygon]) {
            self.key = key
            self.name = name
            self.country = country
            self.kind = kind
            self.polygons = polygons
            let empty = FamilyMap.BoundingBox(minLatitude: 0, maxLatitude: 0, minLongitude: 0, maxLongitude: 0)
            var box = polygons.first?.bbox ?? empty
            for p in polygons.dropFirst() { box = box.union(p.bbox) }
            self.bbox = box
            let hasWestern = polygons.contains { $0.bbox.maxLongitude < 0 }
            let forCamera = hasWestern ? polygons.filter { $0.bbox.minLongitude <= 150 } : polygons
            var camera = forCamera.first?.bbox ?? box
            for p in forCamera.dropFirst() { camera = camera.union(p.bbox) }
            self.cameraBox = camera
        }

        /// Boundary-inclusive containment across every piece.
        public func contains(_ p: FamilyMap.Coordinate) -> Bool {
            guard bbox.contains(p) else { return false }
            for polygon in polygons where polygon.bbox.contains(p) {
                if FamilyMapUnits.contains(p, polygon: polygon) { return true }
            }
            return false
        }

        /// The distance in degrees from `p` to the nearest boundary edge of
        /// any piece whose box, widened by `tolerance`, holds `p`; nil when
        /// no piece is that close.
        func boundaryDistance(to p: FamilyMap.Coordinate, within tolerance: Double) -> Double? {
            var best = Double.infinity
            for polygon in polygons {
                let b = polygon.bbox
                guard p.latitude >= b.minLatitude - tolerance, p.latitude <= b.maxLatitude + tolerance,
                      p.longitude >= b.minLongitude - tolerance, p.longitude <= b.maxLongitude + tolerance else { continue }
                best = min(best, FamilyMapUnits.edgeDistanceSquared(p, ring: polygon.outer))
                for hole in polygon.holes { best = min(best, FamilyMapUnits.edgeDistanceSquared(p, ring: hole)) }
            }
            let d = best.squareRoot()
            return d <= tolerance ? d : nil
        }
    }

    public enum DecodeError: Error, Equatable, CustomStringConvertible {
        case notAFeatureCollection
        case missingProperty(feature: Int, name: String)
        case unknownCountry(feature: Int, value: String)
        case unknownKind(feature: Int, value: String)
        case badGeometry(feature: Int, reason: String)
        case malformedKey(feature: Int, key: String, reason: String)
        case duplicateKey(String)

        public var description: String {
            switch self {
            case .notAFeatureCollection: return "not a GeoJSON FeatureCollection"
            case .missingProperty(let f, let name): return "feature \(f): missing property '\(name)'"
            case .unknownCountry(let f, let v): return "feature \(f): unknown country '\(v)'"
            case .unknownKind(let f, let v): return "feature \(f): unknown kind '\(v)'"
            case .badGeometry(let f, let why): return "feature \(f): bad geometry — \(why)"
            case .malformedKey(let f, let key, let why): return "feature \(f): key '\(key)' — \(why)"
            case .duplicateKey(let key): return "duplicate unit key '\(key)'"
            }
        }
    }

    /// Every unit, sorted by key.
    public let units: [Unit]
    /// Keys whose key is not `FamilyMapKey.unitKey(country, name)` — the
    /// file's deliberate display names (usa-district-of-columbia is named
    /// "Washington"). A sensor pins this list against the bundled file.
    public let keyNameMismatches: [String]
    private let indexByKey: [String: Int]
    /// The units' boxes as four flat columns for the prefilter — a raw
    /// scan of 4 × units doubles, no struct copy per test.
    private let boxMinLat: [Double], boxMaxLat: [Double], boxMinLon: [Double], boxMaxLon: [Double]

    public init(units: [Unit], keyNameMismatches: [String] = []) {
        let sorted = units.sorted { $0.key < $1.key }
        self.units = sorted
        self.keyNameMismatches = keyNameMismatches
        var index: [String: Int] = [:]
        index.reserveCapacity(sorted.count)
        for (i, u) in sorted.enumerated() { index[u.key] = i }
        self.indexByKey = index
        self.boxMinLat = sorted.map(\.bbox.minLatitude)
        self.boxMaxLat = sorted.map(\.bbox.maxLatitude)
        self.boxMinLon = sorted.map(\.bbox.minLongitude)
        self.boxMaxLon = sorted.map(\.bbox.maxLongitude)
    }

    public var count: Int { units.count }

    public func unit(forKey key: String) -> Unit? {
        indexByKey[key].map { units[$0] }
    }

    // MARK: - Decoding

    public init(geoJSON data: Data) throws {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let top = root as? [String: Any], top["type"] as? String == "FeatureCollection",
              let features = top["features"] as? [Any] else {
            throw DecodeError.notAFeatureCollection
        }
        var units: [Unit] = []
        units.reserveCapacity(features.count)
        var seen = Set<String>()
        var mismatches: [String] = []
        for (i, any) in features.enumerated() {
            guard let feature = any as? [String: Any] else { throw DecodeError.badGeometry(feature: i, reason: "feature is not an object") }
            let properties = feature["properties"] as? [String: Any] ?? [:]
            func property(_ name: String) throws -> String {
                guard let v = properties[name] as? String, !v.isEmpty else { throw DecodeError.missingProperty(feature: i, name: name) }
                return v
            }
            let key = try property("key")
            let name = try property("name")
            let countryText = try property("country")
            let kindText = try property("kind")
            guard let country = FamilyMap.Country(rawValue: countryText) else { throw DecodeError.unknownCountry(feature: i, value: countryText) }
            guard let kind = FamilyMap.UnitKind(rawValue: kindText) else { throw DecodeError.unknownKind(feature: i, value: kindText) }
            if kind == .country {
                guard key == country.key else {
                    throw DecodeError.malformedKey(feature: i, key: key, reason: "a country unit's key must be '\(country.key)'")
                }
            } else {
                guard key.hasPrefix(country.key + "-"), key.count > country.key.count + 1 else {
                    throw DecodeError.malformedKey(feature: i, key: key, reason: "must start with '\(country.key)-'")
                }
                guard key == FamilyMapKey.slug(key) else {
                    throw DecodeError.malformedKey(feature: i, key: key, reason: "not slug-shaped (FamilyMapKey rule)")
                }
                if key != FamilyMapKey.unitKey(country: country, name: name) { mismatches.append(key) }
            }
            guard seen.insert(key).inserted else { throw DecodeError.duplicateKey(key) }
            let polygons = try Self.polygons(feature: i, geometry: feature["geometry"])
            units.append(Unit(key: key, name: name, country: country, kind: kind, polygons: polygons))
        }
        self.init(units: units, keyNameMismatches: mismatches.sorted())
    }

    static func polygons(feature i: Int, geometry: Any?) throws -> [Polygon] {
        guard let geometry = geometry as? [String: Any], let type = geometry["type"] as? String else {
            throw DecodeError.badGeometry(feature: i, reason: "no geometry")
        }
        switch type {
        case "Polygon":
            guard let rings = geometry["coordinates"] as? [Any] else { throw DecodeError.badGeometry(feature: i, reason: "Polygon without coordinates") }
            return [try polygon(feature: i, rings: rings)]
        case "MultiPolygon":
            guard let polys = geometry["coordinates"] as? [Any] else { throw DecodeError.badGeometry(feature: i, reason: "MultiPolygon without coordinates") }
            guard !polys.isEmpty else { throw DecodeError.badGeometry(feature: i, reason: "empty MultiPolygon") }
            return try polys.map { any -> Polygon in
                guard let rings = any as? [Any] else { throw DecodeError.badGeometry(feature: i, reason: "polygon is not an array of rings") }
                return try polygon(feature: i, rings: rings)
            }
        default:
            throw DecodeError.badGeometry(feature: i, reason: "geometry type \(type)")
        }
    }

    static func polygon(feature i: Int, rings: [Any]) throws -> Polygon {
        guard !rings.isEmpty else { throw DecodeError.badGeometry(feature: i, reason: "polygon with no rings") }
        let decoded = try rings.map { try ring(feature: i, positions: $0) }
        return Polygon(outer: decoded[0], holes: Array(decoded.dropFirst()))
    }

    static func ring(feature i: Int, positions: Any) throws -> [FamilyMap.Coordinate] {
        guard let positions = positions as? [Any] else { throw DecodeError.badGeometry(feature: i, reason: "ring is not an array") }
        var ring: [FamilyMap.Coordinate] = []
        ring.reserveCapacity(positions.count)
        for any in positions {
            // [lon, lat] — a third element (elevation) is ignored.
            guard let pair = any as? [Any], pair.count >= 2,
                  let lon = (pair[0] as? NSNumber)?.doubleValue, let lat = (pair[1] as? NSNumber)?.doubleValue else {
                throw DecodeError.badGeometry(feature: i, reason: "position is not [lon, lat]")
            }
            guard lat >= -90, lat <= 90, lon >= -180, lon <= 180 else {
                throw DecodeError.badGeometry(feature: i, reason: "position out of range (\(lon), \(lat)) — [lon, lat] order?")
            }
            ring.append(FamilyMap.Coordinate(latitude: lat, longitude: lon))
        }
        guard ring.count >= 3 else { throw DecodeError.badGeometry(feature: i, reason: "ring with fewer than 3 positions") }
        return ring
    }

    // MARK: - Lookup

    /// The unit under a point, or nil in the sea. Ties (a point on a
    /// shared border, or inside an enclave) go to the smaller bounding
    /// box, then the smaller key. O(units) bbox tests + ray casts over the
    /// few candidates.
    public func unit(containing p: FamilyMap.Coordinate) -> Unit? {
        // Raw pointers, latitude columns first: at -Onone a buffer
        // subscript is a bounds-checked call, and most units fail on
        // latitude after two loads.
        let candidates = boxMinLat.withUnsafeBufferPointer { minLat in
            boxMaxLat.withUnsafeBufferPointer { maxLat in
                boxMinLon.withUnsafeBufferPointer { minLon in
                    boxMaxLon.withUnsafeBufferPointer { maxLon -> [Int] in
                        var out: [Int] = []
                        guard let a = minLat.baseAddress, let b = maxLat.baseAddress,
                              let c = minLon.baseAddress, let d = maxLon.baseAddress else { return out }
                        let y = p.latitude, x = p.longitude
                        let n = minLat.count
                        var i = 0
                        while i < n {
                            if y >= a[i], y <= b[i], x >= c[i], x <= d[i] { out.append(i) }
                            i += 1
                        }
                        return out
                    }
                }
            }
        }
        var best: Int?
        for i in candidates where units[i].contains(p) {
            guard let current = best else { best = i; continue }
            let a = units[i].bbox.area, b = units[current].bbox.area
            if a < b || (a == b && units[i].key < units[current].key) { best = i }
        }
        return best.map { units[$0] }
    }

    /// The unit whose boundary is nearest a point that is in no unit — a
    /// click on a coarse coastline. Only for `unit(containing:) == nil`.
    /// Nil beyond `withinDegrees` (0.15° ≈ 10–17 km). Ties go to the key.
    public func unit(nearest p: FamilyMap.Coordinate, withinDegrees tolerance: Double = 0.15) -> Unit? {
        var best: (index: Int, distance: Double)?
        for i in units.indices {
            guard let d = units[i].boundaryDistance(to: p, within: tolerance) else { continue }
            if let current = best, !(d < current.distance || (d == current.distance && units[i].key < units[current.index].key)) { continue }
            best = (i, d)
        }
        return best.map { units[$0.index] }
    }

    /// The camera box around every listed unit that exists. Nil when none
    /// of the keys is a unit.
    public func coverage(for keys: some Sequence<String>) -> FamilyMap.BoundingBox? {
        var box: FamilyMap.BoundingBox?
        for key in keys {
            guard let u = unit(forKey: key) else { continue }
            box = box.map { $0.union(u.cameraBox) } ?? u.cameraBox
        }
        return box
    }

    // MARK: - Geometry

    public enum RingRelation: Sendable, Equatable { case inside, boundary, outside }

    /// Boundary-inclusive: inside the outer ring and outside every hole,
    /// or on any ring. Uses the polygon's band indexes.
    public static func contains(_ p: FamilyMap.Coordinate, polygon: Polygon) -> Bool {
        switch relation(p, ring: polygon.outer, index: polygon.ringIndexes[0]) {
        case .outside: return false
        case .boundary: return true
        case .inside: break
        }
        for (h, hole) in polygon.holes.enumerated() {
            switch relation(p, ring: hole, index: polygon.ringIndexes[h + 1]) {
            case .boundary: return true
            case .inside: return false
            case .outside: continue
            }
        }
        return true
    }

    /// Even-odd ray casting (the classic PNPOLY form — a ray from `p`
    /// toward +longitude; each edge that straddles p's latitude and lies
    /// to the right flips the parity) with the on-the-edge test folded
    /// into the same pass, over EVERY edge. The ring may be open or
    /// closed. `tolerance` is degrees (1e-9 ≈ 0.1 mm). The indexed form
    /// below is what containment uses; this one is the reference.
    public static func relation(_ p: FamilyMap.Coordinate, ring: [FamilyMap.Coordinate], tolerance: Double = 1e-9) -> RingRelation {
        ring.withUnsafeBufferPointer { buf -> RingRelation in
            let n = buf.count
            guard n >= 3 else { return .outside }
            var inside = false
            var j = n - 1
            for i in 0..<n {
                if edgeTest(p, a: buf[j], b: buf[i], tolerance: tolerance, inside: &inside) { return .boundary }
                j = i
            }
            return inside ? .inside : .outside
        }
    }

    /// The same answer as `relation(_:ring:)`, visiting only the edges in
    /// the point's latitude band.
    static func relation(_ p: FamilyMap.Coordinate, ring: [FamilyMap.Coordinate], index: RingIndex,
                         tolerance: Double = 1e-9) -> RingRelation {
        let n = ring.count
        guard n >= 3, let band = index.band(for: p.latitude, tolerance: tolerance) else { return .outside }
        return ring.withUnsafeBufferPointer { buf -> RingRelation in
            index.edges.withUnsafeBufferPointer { edges -> RingRelation in
                var inside = false
                let lo = Int(index.starts[band]), hi = Int(index.starts[band + 1])
                var k = lo
                while k < hi {
                    let e = Int(edges[k])
                    let j = e == 0 ? n - 1 : e - 1
                    if edgeTest(p, a: buf[j], b: buf[e], tolerance: tolerance, inside: &inside) { return .boundary }
                    k += 1
                }
                return inside ? .inside : .outside
            }
        }
    }

    /// One edge a→b: flips `inside` when the ray from `p` crosses it;
    /// returns true when `p` lies on it (within `tolerance`). Explicit
    /// comparisons rather than min()/max()/abs(): in a Debug build those
    /// are unspecialised generic calls.
    @inline(__always)
    static func edgeTest(_ p: FamilyMap.Coordinate, a: FamilyMap.Coordinate, b: FamilyMap.Coordinate,
                         tolerance: Double, inside: inout Bool) -> Bool {
        let x = p.longitude, y = p.latitude
        let ax = a.longitude, ay = a.latitude, bx = b.longitude, by = b.latitude
        let loY = ay < by ? ay : by, hiY = ay < by ? by : ay
        if y >= loY - tolerance, y <= hiY + tolerance {
            let loX = ax < bx ? ax : bx, hiX = ax < bx ? bx : ax
            if x >= loX - tolerance, x <= hiX + tolerance {
                let dx = bx - ax, dy = by - ay
                let length2 = dx * dx + dy * dy
                if length2 == 0 {
                    let ex = x - ax, ey = y - ay
                    if ex * ex + ey * ey <= tolerance * tolerance { return true }
                } else {
                    // Perpendicular distance via the cross product, squared.
                    let cross = dx * (y - ay) - dy * (x - ax)
                    if cross * cross <= tolerance * tolerance * length2 { return true }
                }
            }
        }
        if (by > y) != (ay > y) {
            let crossing = (ax - bx) * (y - by) / (ay - by) + bx
            if x < crossing { inside.toggle() }
        }
        return false
    }

    /// Squared distance from `p` to the nearest edge of the ring.
    static func edgeDistanceSquared(_ p: FamilyMap.Coordinate, ring: [FamilyMap.Coordinate]) -> Double {
        ring.withUnsafeBufferPointer { buf -> Double in
            let n = buf.count
            guard n >= 2 else { return .infinity }
            var best = Double.infinity
            var j = n - 1
            let x = p.longitude, y = p.latitude
            for i in 0..<n {
                let ax = buf[j].longitude, ay = buf[j].latitude
                let bx = buf[i].longitude, by = buf[i].latitude
                j = i
                let dx = bx - ax, dy = by - ay
                let length2 = dx * dx + dy * dy
                // The projection of p onto the edge, clamped to its ends.
                var t = length2 == 0 ? 0 : ((x - ax) * dx + (y - ay) * dy) / length2
                if t < 0 { t = 0 } else if t > 1 { t = 1 }
                let ex = ax + t * dx - x, ey = ay + t * dy - y
                let d2 = ex * ex + ey * ey
                if d2 < best { best = d2 }
            }
            return best
        }
    }
}
