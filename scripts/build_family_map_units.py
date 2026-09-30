#!/usr/bin/env python3
"""Build the bundled Family Map units file (GH #227, stage 0).

Downloads, filters, simplifies and writes ONE GeoJSON FeatureCollection:

    VideoScan/VideoScan/Resources/FamilyMap/family-map-units.geojson
    VideoScan/VideoScan/Resources/FamilyMap/ATTRIBUTION.txt

Sources (cached under --cache, never committed):
  * Historic County Borders Project (Historic Counties Trust) — historic
    counties of England, Scotland, Wales and Northern Ireland, Definition A,
    WGS84 shapefile.  Free for all use; acknowledgement required (see
    ATTRIBUTION.txt).
  * Natural Earth (public domain) — 1:50m admin-1 for US states + DC and
    Canadian provinces/territories; 1:10m admin-1 for the counties of
    Ireland; 1:50m admin-0 map subunits for the country outlines.

Output contract (VideoScanCore MapUnits decodes exactly this):
  * FeatureCollection, WGS84, [lon, lat], Polygon or MultiPolygon, 6 dp.
  * properties: key, name, country (ENG SCT WLS NIR IRL USA CAN),
    kind (county state province country).
  * key = "<country lower>-<slug(name)>", or "<country lower>" for countries.
  * Features sorted by key; byte-stable across runs on the same downloads.

Dev-only: needs `pyshp` in the venv (pip install pyshp).  Douglas–Peucker,
ring handling and the dissolve are pure Python — no shapely, no GDAL.

Usage:
    venv/bin/python scripts/build_family_map_units.py [--cache DIR] [--out DIR]
    venv/bin/python scripts/build_family_map_units.py --report [--out DIR]
    venv/bin/python scripts/build_family_map_units.py --self-test
"""

from __future__ import annotations

import argparse
import collections
import io
import json
import math
import os
import pathlib
import sys
import tempfile
import unicodedata
import urllib.request
import zipfile

REPO = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_OUT = REPO / "VideoScan" / "VideoScan" / "Resources" / "FamilyMap"
DEFAULT_CACHE = pathlib.Path(tempfile.gettempdir()) / "videoscan-family-map-sources"
OUTPUT_NAME = "family-map-units.geojson"
ATTRIBUTION_NAME = "ATTRIBUTION.txt"

HCB_URL = "https://www.county-borders.co.uk/UKDefinitionA_WG84_Simplified.zip"
NE_BASE = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/"
NE_50M_ADMIN1 = "ne_50m_admin_1_states_provinces.geojson"
NE_10M_ADMIN1 = "ne_10m_admin_1_states_provinces.geojson"
NE_50M_SUBUNITS = "ne_50m_admin_0_map_subunits.geojson"

TOL_HISTORIC = 0.01   # degrees; Historic County Borders (1:5,000 source)
TOL_IRELAND = 0.005   # degrees; NE 1:10m Ireland — 0.01 lost Galway city centre
TOL_NE50 = 0.02       # degrees; Natural Earth 1:50m layers
DECIMALS = 6
MIN_RING_POINTS = 4   # closed ring: 3 distinct + closing point

COUNTRIES = ("ENG", "SCT", "WLS", "NIR", "IRL", "USA", "CAN")
KINDS = ("county", "state", "province", "country")

# Historic County Borders shapefile has NAME but no nation column.  The 92
# historic counties (Historic Counties Standard) by nation; the build fails
# loudly if the shapefile's NAME set differs from this table.
HCB_NATION = {
    "ENG": [
        "Bedfordshire", "Berkshire", "Buckinghamshire", "Cambridgeshire", "Cheshire",
        "Cornwall", "Cumberland", "Derbyshire", "Devon", "Dorset", "Durham", "Essex",
        "Gloucestershire", "Hampshire", "Herefordshire", "Hertfordshire",
        "Huntingdonshire", "Kent", "Lancashire", "Leicestershire", "Lincolnshire",
        "Middlesex", "Norfolk", "Northamptonshire", "Northumberland",
        "Nottinghamshire", "Oxfordshire", "Rutland", "Shropshire", "Somerset",
        "Staffordshire", "Suffolk", "Surrey", "Sussex", "Warwickshire",
        "Westmorland", "Wiltshire", "Worcestershire", "Yorkshire",
    ],
    "SCT": [
        "Aberdeenshire", "Angus", "Argyllshire", "Ayrshire", "Banffshire",
        "Berwickshire", "Buteshire", "Caithness", "Clackmannanshire", "Cromartyshire",
        "Dumfriesshire", "Dunbartonshire", "East Lothian", "Fife", "Inverness-shire",
        "Kincardineshire", "Kinross-shire", "Kirkcudbrightshire", "Lanarkshire",
        "Midlothian", "Morayshire", "Nairnshire", "Orkney", "Peeblesshire",
        "Perthshire", "Renfrewshire", "Ross-shire", "Roxburghshire", "Selkirkshire",
        "Shetland", "Stirlingshire", "Sutherland", "West Lothian", "Wigtownshire",
    ],
    "WLS": [
        "Anglesey", "Brecknockshire", "Caernarfonshire", "Cardiganshire",
        "Carmarthenshire", "Denbighshire", "Flintshire", "Glamorgan",
        "Merionethshire", "Monmouthshire", "Montgomeryshire", "Pembrokeshire",
        "Radnorshire",
    ],
    "NIR": ["Antrim", "Armagh", "Down", "Fermanagh", "Londonderry", "Tyrone"],
}
HCB_NATION_BY_NAME = {name: nation for nation, names in HCB_NATION.items() for name in names}

# Natural Earth 1:10m splits Ireland into 34 administrative units; the family
# tree's strings use the 26 traditional counties.  Units are folded by
# name_en (city + county, North/South Tipperary) plus this table for Dublin.
IRELAND_FOLD = {
    "Dún Laoghaire–Rathdown": "Dublin",
    "Fingal": "Dublin",
    "South Dublin": "Dublin",
}
IRELAND_EXPECTED_COUNTIES = 26

US_CANADA_NAME_FIX = {"Québec": "Quebec"}

# NE admin-0 map subunits: the USA outline is three subunits.
SUBUNIT_COUNTRIES = {
    "ENG": ["ENG"], "SCT": ["SCT"], "WLS": ["WLS"], "NIR": ["NIR"],
    "IRL": ["IRL"], "CAN": ["CAN"], "USA": ["USB", "USK", "USH"],
}
SUBUNIT_NAMES = {
    "ENG": "England", "SCT": "Scotland", "WLS": "Wales", "NIR": "Northern Ireland",
    "IRL": "Ireland", "USA": "United States", "CAN": "Canada",
}

ATTRIBUTION_TEXT = """Family Map border data — sources and licences

This mapping made use of data provided by the Historic County Borders Project.
https://www.county-borders.co.uk

  Historic counties of England, Scotland, Wales and Northern Ireland:
  Historic County Borders Project (Historic Counties Trust), UK Definition A,
  WGS84, "Simplified" shapefile release, downloaded from
  {hcb_url}
  The data are provided free of charge for all personal, educational,
  non-commercial and commercial use; the Trust asks for the acknowledgement
  above.  Based on the Historic Counties Standard
  (https://historiccountiestrust.co.uk/Historic_Counties_Standard.pdf).

Made with Natural Earth. Free vector and raster map data @ naturalearthdata.com
(public domain).

  US states + District of Columbia, Canadian provinces and territories:
  {ne_base}{ne_50m_admin1}
  Counties of Ireland (folded to the 26 traditional counties):
  {ne_base}{ne_10m_admin1}
  Country outlines (England, Scotland, Wales, Northern Ireland, Ireland,
  United States, Canada):
  {ne_base}{ne_50m_subunits}

All layers were simplified (Douglas–Peucker, {tol_hist}° for the historic
counties, {tol_irl}° for Ireland, {tol_ne50}° for the Natural Earth 1:50m layers)
and rounded to {decimals} decimal places by scripts/build_family_map_units.py.
Borders are approximate and for family-history illustration only.
""".format(
    hcb_url=HCB_URL, ne_base=NE_BASE, ne_50m_admin1=NE_50M_ADMIN1,
    ne_10m_admin1=NE_10M_ADMIN1, ne_50m_subunits=NE_50M_SUBUNITS,
    tol_hist=TOL_HISTORIC, tol_irl=TOL_IRELAND, tol_ne50=TOL_NE50, decimals=DECIMALS,
)


# --------------------------------------------------------------------------
# Naming
# --------------------------------------------------------------------------

def slug(name: str) -> str:
    """lowercase ASCII, letters/digits only, words joined by '-', diacritics
    stripped.  'Inverness-shire' -> 'inverness-shire', 'Québec' -> 'quebec'."""
    words = []
    current = []
    for ch in unicodedata.normalize("NFKD", name).lower():
        if unicodedata.combining(ch):
            continue  # the accent stripped off 'é', 'ú' …
        if ch.isascii() and ch.isalnum():
            current.append(ch)
        elif current:
            words.append("".join(current))  # space, hyphen, en dash, apostrophe … all break words
            current = []
    if current:
        words.append("".join(current))
    return "-".join(words)


def unit_key(country: str, kind: str, name: str) -> str:
    if kind == "country":
        return country.lower()
    return f"{country.lower()}-{slug(name)}"


def strip_county_prefix(name: str) -> str:
    return name[len("County "):] if name.startswith("County ") else name


# --------------------------------------------------------------------------
# Geometry: Douglas–Peucker, rings, rounding
# --------------------------------------------------------------------------

def _point_segment_distance(p, a, b) -> float:
    ax, ay = a
    bx, by = b
    px, py = p
    dx, dy = bx - ax, by - ay
    if dx == 0.0 and dy == 0.0:
        return math.hypot(px - ax, py - ay)
    t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)
    t = max(0.0, min(1.0, t))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def douglas_peucker(points: list, tolerance: float) -> list:
    """Classic Ramer–Douglas–Peucker on an open polyline (iterative, so a
    40,000-point coastline does not hit the recursion limit).  Endpoints are
    always kept."""
    n = len(points)
    if n < 3:
        return list(points)
    keep = [False] * n
    keep[0] = keep[-1] = True
    stack = [(0, n - 1)]
    while stack:
        i, j = stack.pop()
        if j <= i + 1:
            continue
        a, b = points[i], points[j]
        best, best_k = -1.0, -1
        for k in range(i + 1, j):
            d = _point_segment_distance(points[k], a, b)
            if d > best:
                best, best_k = d, k
        if best > tolerance:
            keep[best_k] = True
            stack.append((i, best_k))
            stack.append((best_k, j))
    return [p for p, k in zip(points, keep) if k]


def _dedupe_consecutive(points: list) -> list:
    out = []
    for p in points:
        if not out or out[-1] != p:
            out.append(p)
    return out


def simplify_ring(ring: list, tolerance: float):
    """Simplify a closed ring.  Splits at the vertex farthest from the first
    vertex so DP has two proper polylines, then re-closes.  Returns None when
    fewer than MIN_RING_POINTS remain (a tiny islet)."""
    pts = _dedupe_consecutive([tuple(p) for p in ring])
    if len(pts) > 1 and pts[0] == pts[-1]:
        pts = pts[:-1]
    if len(pts) < 3:
        return None
    x0, y0 = pts[0]
    far = max(range(1, len(pts)), key=lambda i: (pts[i][0] - x0) ** 2 + (pts[i][1] - y0) ** 2)
    first = douglas_peucker(pts[: far + 1], tolerance)
    second = douglas_peucker(pts[far:] + [pts[0]], tolerance)
    out = _dedupe_consecutive(first[:-1] + second[:-1])
    if len(out) < 3:
        return None
    out.append(out[0])
    return out


def normalise_lon(lon: float) -> float:
    """Bring a longitude into [-180, 180] (Natural Earth's Aleutian pieces can
    carry lon > 180).  Pieces are never merged or clipped across the
    antimeridian; each MultiPolygon piece stays as the source drew it."""
    original = lon
    while lon > 180.0:
        lon -= 360.0
    while lon < -180.0:
        lon += 360.0
    if lon != original:
        NORMALISED_LONGITUDES[0] += 1
    return lon


NORMALISED_LONGITUDES = [0]


def round_ring(ring: list, decimals: int = DECIMALS):
    rounded = _dedupe_consecutive([(round(normalise_lon(x), decimals), round(y, decimals)) for x, y in ring])
    if rounded[0] != rounded[-1]:
        rounded.append(rounded[0])
    if len(rounded) < MIN_RING_POINTS:
        return None
    return rounded


def ring_area(ring: list) -> float:
    """Signed shoelace area (positive = counter-clockwise in lon/lat)."""
    s = 0.0
    for (x1, y1), (x2, y2) in zip(ring, ring[1:]):
        s += x1 * y2 - x2 * y1
    return s / 2.0


def point_in_ring(p, ring: list) -> bool:
    x, y = p
    inside = False
    for (x1, y1), (x2, y2) in zip(ring, ring[1:]):
        if (y1 > y) != (y2 > y):
            xi = x1 + (y - y1) * (x2 - x1) / (y2 - y1)
            if x < xi:
                inside = not inside
    return inside


def polygons_of(geometry: dict) -> list:
    """GeoJSON geometry -> list of polygons, each a list of rings (outer first)."""
    if geometry["type"] == "Polygon":
        return [geometry["coordinates"]]
    if geometry["type"] == "MultiPolygon":
        return list(geometry["coordinates"])
    raise ValueError(f"unsupported geometry {geometry['type']}")


def simplify_polygons(polygons: list, tolerance: float) -> list:
    """Simplify every ring; drop rings below MIN_RING_POINTS; drop a polygon
    whose outer ring vanished; never drop the whole feature (falls back to the
    largest un-simplified outer ring so the unit still has a shape)."""
    out = []
    for rings in polygons:
        new_rings = []
        for i, ring in enumerate(rings):
            s = simplify_ring(ring, tolerance)
            if s is not None:
                s = round_ring(s)
            if s is None:
                if i == 0:
                    new_rings = None
                    break
                continue
            new_rings.append(s)
        if new_rings:
            out.append(new_rings)
    if not out:
        biggest = max(polygons, key=lambda rings: abs(ring_area(rings[0])))
        kept = round_ring([tuple(p) for p in biggest[0]])
        if kept is None:
            raise ValueError("feature collapsed entirely")
        out = [[kept]]
    return out


def vertex_count(polygons: list) -> int:
    return sum(len(ring) for rings in polygons for ring in rings)


def geometry_of(polygons: list) -> dict:
    coords = [[[list(p) for p in ring] for ring in rings] for rings in polygons]
    if len(coords) == 1:
        return {"type": "Polygon", "coordinates": coords[0]}
    return {"type": "MultiPolygon", "coordinates": coords}


# --------------------------------------------------------------------------
# Dissolve (merge adjacent units by cancelling shared directed edges)
# --------------------------------------------------------------------------

def dissolve(polygon_sets: list):
    """Merge several units' polygons into one.  Shared borders in
    topologically clean data appear as an edge in one unit and its reverse in
    the neighbour; removing both and re-chaining the rest gives the outline.
    Returns (polygons, ok).  ok=False (with the plain concatenation) when the
    edges do not chain into closed rings."""
    concatenated = [rings for polygons in polygon_sets for rings in polygons]
    if len(polygon_sets) < 2:
        return concatenated, True
    edges = collections.Counter()
    for rings in concatenated:
        for ring in rings:
            for a, b in zip(ring, ring[1:]):
                a, b = tuple(a), tuple(b)
                if a != b:
                    edges[(a, b)] += 1
    remaining = collections.Counter()
    for (a, b), n in edges.items():
        m = n - edges.get((b, a), 0)
        if m > 0:
            remaining[(a, b)] = m
    outgoing = collections.defaultdict(list)
    for (a, b), n in remaining.items():
        outgoing[a].extend([b] * n)
    rings = []
    while outgoing:
        start = min(outgoing)
        ring = [start]
        current = start
        while True:
            nexts = outgoing.get(current)
            if not nexts:
                return concatenated, False
            nxt = nexts.pop()
            if not nexts:
                del outgoing[current]
            ring.append(nxt)
            current = nxt
            if current == start:
                break
            if len(ring) > 10_000_000:
                return concatenated, False
        rings.append(ring)
    # Outer rings vs holes by containment (a hole sits inside exactly one outer).
    outers, holes = [], []
    for ring in rings:
        containers = [other for other in rings if other is not ring and point_in_ring(ring[0], other)]
        (holes if len(containers) % 2 == 1 else outers).append(ring)
    polygons = [[outer] for outer in outers]
    for hole in holes:
        owner = None
        for rings_ in polygons:
            if point_in_ring(hole[0], rings_[0]):
                if owner is None or abs(ring_area(rings_[0])) < abs(ring_area(owner[0])):
                    owner = rings_
        if owner is None:
            return concatenated, False
        owner.append(hole)
    return polygons, True


# --------------------------------------------------------------------------
# Sources
# --------------------------------------------------------------------------

def download(url: str, dest: pathlib.Path) -> pathlib.Path:
    if dest.exists() and dest.stat().st_size > 0:
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    print(f"downloading {url}")
    with urllib.request.urlopen(url, timeout=120) as response, open(dest, "wb") as fh:
        while True:
            chunk = response.read(1 << 20)
            if not chunk:
                break
            fh.write(chunk)
    return dest


def load_historic_counties(cache: pathlib.Path) -> list:
    import shapefile  # pyshp (dev-only dependency)
    path = download(HCB_URL, cache / pathlib.Path(HCB_URL).name)
    archive = zipfile.ZipFile(path)
    stems = sorted({n[:-4] for n in archive.namelist() if n.lower().endswith(".shp")})
    if len(stems) != 1:
        raise ValueError(f"expected one shapefile in {path.name}, found {stems}")
    stem = stems[0]
    reader = shapefile.Reader(
        shp=io.BytesIO(archive.read(stem + ".shp")),
        dbf=io.BytesIO(archive.read(stem + ".dbf")),
        shx=io.BytesIO(archive.read(stem + ".shx")),
    )
    units = []
    names = set()
    for record, shape in zip(reader.iterRecords(), reader.iterShapes()):
        name = record["NAME"].strip()
        names.add(name)
        nation = HCB_NATION_BY_NAME.get(name)
        if nation is None:
            raise ValueError(f"historic county not in HCB_NATION table: {name!r}")
        geometry = shape.__geo_interface__  # organises rings into (Multi)Polygon
        units.append(("county", nation, name, polygons_of(geometry), TOL_HISTORIC))
    missing = set(HCB_NATION_BY_NAME) - names
    if missing:
        raise ValueError(f"historic counties missing from shapefile: {sorted(missing)}")
    return units


def load_us_canada(cache: pathlib.Path) -> list:
    path = download(NE_BASE + NE_50M_ADMIN1, cache / NE_50M_ADMIN1)
    data = json.loads(path.read_text(encoding="utf-8"))
    units = []
    for feature in data["features"]:
        p = feature["properties"]
        iso = p.get("iso_a2")
        if iso == "US" and p.get("adm0_a3") == "USA":
            country, kind = "USA", "state"
        elif iso == "CA" and p.get("adm0_a3") == "CAN":
            country, kind = "CAN", "province"
        else:
            continue
        # NE's name_en for the District of Columbia is "Washington" (collides
        # with the state), so use `name` and fix the one accented province.
        name = US_CANADA_NAME_FIX.get(p["name"], p["name"])
        units.append((kind, country, name, polygons_of(feature["geometry"]), TOL_NE50))
    us = sum(1 for u in units if u[1] == "USA")
    ca = sum(1 for u in units if u[1] == "CAN")
    if us != 51 or ca != 13:
        raise ValueError(f"expected 51 US + 13 CA admin-1 units, got {us} + {ca}")
    return units


def load_ireland(cache: pathlib.Path) -> tuple:
    path = download(NE_BASE + NE_10M_ADMIN1, cache / NE_10M_ADMIN1)
    data = json.loads(path.read_text(encoding="utf-8"))
    grouped = collections.OrderedDict()
    for feature in data["features"]:
        p = feature["properties"]
        if p.get("iso_a2") != "IE":
            continue
        name = p.get("name_en") or p["name"]
        name = IRELAND_FOLD.get(name, strip_county_prefix(name))
        grouped.setdefault(name, []).append(polygons_of(feature["geometry"]))
    if len(grouped) != IRELAND_EXPECTED_COUNTIES:
        raise ValueError(f"expected {IRELAND_EXPECTED_COUNTIES} Irish counties after folding, got {len(grouped)}: {sorted(grouped)}")
    units, notes = [], []
    for name in sorted(grouped):
        polygons, ok = dissolve(grouped[name])
        if len(grouped[name]) > 1:
            notes.append(f"  Ireland: {name} = {len(grouped[name])} NE units {'dissolved' if ok else 'CONCATENATED (dissolve failed)'} -> {len(polygons)} polygon(s)")
        units.append(("county", "IRL", name, polygons, TOL_IRELAND))
    return units, notes


def load_country_outlines(cache: pathlib.Path) -> list:
    path = download(NE_BASE + NE_50M_SUBUNITS, cache / NE_50M_SUBUNITS)
    data = json.loads(path.read_text(encoding="utf-8"))
    by_code = {}
    for feature in data["features"]:
        code = feature["properties"].get("SU_A3") or feature["properties"].get("su_a3")
        if code:
            by_code[code] = feature
    units = []
    for country, codes in SUBUNIT_COUNTRIES.items():
        polygons = []
        for code in codes:
            if code not in by_code:
                raise ValueError(f"map subunit {code} not found for {country}")
            polygons.extend(polygons_of(by_code[code]["geometry"]))
        units.append(("country", country, SUBUNIT_NAMES[country], polygons, TOL_NE50))
    return units


# --------------------------------------------------------------------------
# Build / report
# --------------------------------------------------------------------------

def build_features(units: list) -> tuple:
    """units: (kind, country, name, polygons, tolerance) -> (features, stats)."""
    features = []
    stats = collections.OrderedDict()
    seen = {}
    for kind, country, name, polygons, tolerance in units:
        key = unit_key(country, kind, name)
        if key in seen:
            raise ValueError(f"duplicate key {key}: {seen[key]!r} and {name!r}")
        seen[key] = name
        before = vertex_count(polygons)
        simplified = simplify_polygons(polygons, tolerance)
        after = vertex_count(simplified)
        layer = f"{country}/{kind}"
        s = stats.setdefault(layer, {"features": 0, "before": 0, "after": 0})
        s["features"] += 1
        s["before"] += before
        s["after"] += after
        features.append({
            "type": "Feature",
            "properties": {"key": key, "name": name, "country": country, "kind": kind},
            "geometry": geometry_of(simplified),
        })
    features.sort(key=lambda f: f["properties"]["key"])
    return features, stats


def serialize(features: list) -> str:
    collection = {"type": "FeatureCollection", "features": features}
    return json.dumps(collection, separators=(",", ":"), sort_keys=True, ensure_ascii=True) + "\n"


def build(cache: pathlib.Path, out_dir: pathlib.Path) -> int:
    cache.mkdir(parents=True, exist_ok=True)
    print(f"cache: {cache}")
    units = []
    units += load_historic_counties(cache)
    units += load_us_canada(cache)
    ireland, notes = load_ireland(cache)
    units += ireland
    units += load_country_outlines(cache)
    features, stats = build_features(units)
    for feature in features:
        for rings in polygons_of(feature["geometry"]):
            for ring in rings:
                for lon, lat in ring:
                    if not (-180.0 <= lon <= 180.0 and -90.0 <= lat <= 90.0):
                        raise ValueError(f"{feature['properties']['key']}: coordinate out of range ({lon}, {lat})")
    text = serialize(features)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / OUTPUT_NAME).write_text(text, encoding="utf-8")
    (out_dir / ATTRIBUTION_NAME).write_text(ATTRIBUTION_TEXT, encoding="utf-8")
    print(f"\nwrote {out_dir / OUTPUT_NAME} ({len(text.encode('utf-8')):,} bytes)")
    print(f"wrote {out_dir / ATTRIBUTION_NAME}")
    print("\nper-layer vertices (before -> after simplification):")
    total_before = total_after = 0
    for layer, s in stats.items():
        print(f"  {layer:14s} {s['features']:4d} features  {s['before']:9,d} -> {s['after']:7,d}")
        total_before += s["before"]
        total_after += s["after"]
    print(f"  {'total':14s} {len(features):4d} features  {total_before:9,d} -> {total_after:7,d}")
    notes.append(f"  antimeridian: {NORMALISED_LONGITUDES[0]} longitude(s) outside [-180, 180] normalised by ±360 (pieces never merged or clipped)")
    print("\nnotes:")
    print("\n".join(notes))
    return 0


def bbox_of(polygons: list) -> tuple:
    lons = [x for rings in polygons for ring in rings for x, _ in ring]
    lats = [y for rings in polygons for ring in rings for _, y in ring]
    return (min(lons), min(lats), max(lons), max(lats))


def report(out_dir: pathlib.Path) -> int:
    path = out_dir / OUTPUT_NAME
    data = json.loads(path.read_text(encoding="utf-8"))
    features = data["features"]
    counts = collections.Counter((f["properties"]["country"], f["properties"]["kind"]) for f in features)
    print(f"{path}: {path.stat().st_size:,} bytes, {len(features)} features")
    print("\nfeatures per country/kind:")
    for (country, kind), n in sorted(counts.items()):
        print(f"  {country} {kind:9s} {n:4d}")
    sizes = [(vertex_count(polygons_of(f["geometry"])), f["properties"]["key"]) for f in features]
    lo, hi = min(sizes), max(sizes)
    print(f"\nvertices per feature: min {lo[0]} ({lo[1]}), max {hi[0]} ({hi[1]}), total {sum(v for v, _ in sizes):,}")
    by_key = {f["properties"]["key"]: f for f in features}
    if len(by_key) != len(features):
        raise ValueError("duplicate keys in output")
    print("\nantimeridian (pieces are kept per side, never merged or clipped across ±180):")
    for key in ("usa-alaska", "usa"):
        feature = by_key.get(key)
        if not feature:
            continue
        pieces = polygons_of(feature["geometry"])
        west = [rings for rings in pieces if bbox_of([rings])[0] < 0]
        east = [rings for rings in pieces if bbox_of([rings])[0] >= 0]
        straddling = sum(1 for rings in pieces if bbox_of([rings])[2] - bbox_of([rings])[0] >= 180.0)
        print(f"  {key}: {len(pieces)} pieces, bbox (lon_min, lat_min, lon_max, lat_max) = {bbox_of(pieces)}")
        print(f"    west of the antimeridian (lon < 0): {len(west)} pieces, bbox {bbox_of(west) if west else None}")
        print(f"    east of it (lon > 0, the far Aleutians): {len(east)} pieces, bbox {bbox_of(east) if east else None}")
        print(f"    pieces straddling ±180: {straddling}")
    london_like = [k for k in by_key if "london" in k or "middlesex" in k]
    print(f"\nLondon / Middlesex keys present: {london_like}")
    print("\nkeys:")
    for f in features:
        print(f"  {f['properties']['key']}")
    return 0


def self_test() -> int:
    """Douglas–Peucker on the classic reference polyline (Rosetta Code)."""
    points = [(0.0, 0.0), (1.0, 0.1), (2.0, -0.1), (3.0, 5.0), (4.0, 6.0), (5.0, 7.0),
              (6.0, 8.1), (7.0, 9.0), (8.0, 9.0), (9.0, 9.0)]
    expected = [(0.0, 0.0), (2.0, -0.1), (3.0, 5.0), (7.0, 9.0), (9.0, 9.0)]
    got = douglas_peucker(points, 1.0)
    if got != expected:
        print(f"self-test FAILED: {got} != {expected}")
        return 1
    square = [(0, 0), (0.001, 0.5), (0, 1), (1, 1), (1, 0), (0, 0)]
    ring = simplify_ring(square, 0.01)
    if ring != [(0, 0), (0, 1), (1, 1), (1, 0), (0, 0)]:
        print(f"self-test FAILED (ring): {ring}")
        return 1
    assert slug("Inverness-shire") == "inverness-shire"
    assert slug("Québec") == "quebec"
    assert slug("County Cork") == "county-cork"
    assert unit_key("ENG", "country", "England") == "eng"
    print("self-test OK")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cache", type=pathlib.Path, default=DEFAULT_CACHE, help="download cache dir (never committed)")
    parser.add_argument("--out", type=pathlib.Path, default=DEFAULT_OUT, help="output folder")
    parser.add_argument("--report", action="store_true", help="describe the built file and exit")
    parser.add_argument("--self-test", action="store_true", help="run the Douglas–Peucker self-test and exit")
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    if args.report:
        return report(args.out)
    return build(args.cache, args.out)


if __name__ == "__main__":
    sys.exit(main())
