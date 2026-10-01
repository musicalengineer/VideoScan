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
    Ireland and for Western Europe's second level (the 13 French régions,
    dissolved from the metropolitan départements; the 16 German Länder;
    the 12 Dutch and the 10 Belgian provinces + Brussels); 1:50m admin-0
    map subunits for the country outlines.

Output contract (VideoScanCore MapUnits decodes exactly this):
  * FeatureCollection, WGS84, [lon, lat], Polygon or MultiPolygon, 6 dp.
  * properties: key, name, country (ENG SCT WLS NIR IRL USA CAN, and the
    Western Europe stage FRA DEU NLD BEL LUX CHE AUT DNK NOR SWE ITA ESP
    PRT), kind (county state province region country).
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
import itertools
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
TOL_EUROPE = 0.02     # degrees; NE 1:10m Western Europe second level (≈ 2 km)
DECIMALS = 6
MIN_RING_POINTS = 4   # closed ring: 3 distinct + closing point

COUNTRIES = ("ENG", "SCT", "WLS", "NIR", "IRL", "USA", "CAN",
             "FRA", "DEU", "NLD", "BEL", "LUX", "CHE", "AUT", "DNK", "NOR", "SWE", "ITA", "ESP", "PRT")
KINDS = ("county", "state", "province", "region", "country")

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

# ---- Western Europe (GH #227, Rick 2026-09-30: "Countries + regions") -------
# NE 1:10m admin-1 draws France by its 101 départements, each carrying the
# CURRENT (2016) région in `region`.  The 96 metropolitan départements are
# dissolved into the 13 metropolitan régions; the five overseas départements
# are left out (they would put a pin in the Caribbean and the Indian Ocean —
# a birth there still resolves to France, shading the country outline).
# The old 22 régions (Rhône-Alpes, Poitou-Charentes, Basse-Normandie …) are
# NOT drawn: the resolver folds them into the 2016 région that contains them.
# Display names are the English ones a US family reads; the key is
# slug(display name), the one key rule.
FRANCE_REGION_NAMES = {
    "Auvergne-Rhône-Alpes": "Auvergne-Rhône-Alpes",
    "Bourgogne-Franche-Comté": "Bourgogne-Franche-Comté",
    "Bretagne": "Brittany",
    "Centre-Val de Loire": "Centre-Val de Loire",
    "Corse": "Corsica",
    "Grand Est": "Grand Est",
    "Hauts-de-France": "Hauts-de-France",
    "Île-de-France": "Île-de-France",
    "Normandie": "Normandy",
    "Nouvelle-Aquitaine": "Nouvelle-Aquitaine",
    "Occitanie": "Occitania",
    "Pays de la Loire": "Pays de la Loire",
    "Provence-Alpes-Côte-d'Azur": "Provence-Alpes-Côte d'Azur",
}
FRANCE_METROPOLITAN_TYPE = "Metropolitan department"
FRANCE_EXPECTED_DEPARTEMENTS = 96
# Germany, the Netherlands, Belgium: one NE unit per Land / province, keyed by
# ISO 3166-2 so a renamed NE `name_en` cannot silently re-key a unit.
GERMANY_STATES = {
    "DE-BW": "Baden-Württemberg", "DE-BY": "Bavaria", "DE-BE": "Berlin", "DE-BB": "Brandenburg",
    "DE-HB": "Bremen", "DE-HH": "Hamburg", "DE-HE": "Hesse", "DE-NI": "Lower Saxony",
    "DE-MV": "Mecklenburg-Vorpommern", "DE-NW": "North Rhine-Westphalia",
    "DE-RP": "Rhineland-Palatinate", "DE-SL": "Saarland", "DE-SN": "Saxony",
    "DE-ST": "Saxony-Anhalt", "DE-SH": "Schleswig-Holstein", "DE-TH": "Thuringia",
}
NETHERLANDS_PROVINCES = {
    "NL-DR": "Drenthe", "NL-FL": "Flevoland", "NL-FR": "Friesland", "NL-GE": "Gelderland",
    "NL-GR": "Groningen", "NL-LI": "Limburg", "NL-NB": "North Brabant", "NL-NH": "North Holland",
    "NL-OV": "Overijssel", "NL-UT": "Utrecht", "NL-ZE": "Zeeland", "NL-ZH": "South Holland",
}
BELGIUM_PROVINCES = {
    "BE-VAN": "Antwerp", "BE-VOV": "East Flanders", "BE-VWV": "West Flanders",
    "BE-VBR": "Flemish Brabant", "BE-VLI": "Limburg", "BE-WBR": "Walloon Brabant",
    "BE-WHT": "Hainaut", "BE-WLG": "Liège", "BE-WLX": "Luxembourg", "BE-WNA": "Namur",
    "BE-BRU": "Brussels",
}
# country code -> (NE iso_a2, kind, ISO 3166-2 -> display name)
EUROPE_ADMIN1 = {
    "DEU": ("DE", "state", GERMANY_STATES),
    "NLD": ("NL", "province", NETHERLANDS_PROVINCES),
    "BEL": ("BE", "province", BELGIUM_PROVINCES),
}

# NE admin-0 map subunits: the USA outline is three subunits.  The European
# outlines are the home territory only: metropolitan France + Corsica (no
# overseas départements), Norway without Svalbard / Jan Mayen, the European
# Netherlands without the Caribbean islands; Spain and Portugal keep their
# Atlantic islands (the camera frames the principal piece, the mainland).
SUBUNIT_COUNTRIES = {
    "ENG": ["ENG"], "SCT": ["SCT"], "WLS": ["WLS"], "NIR": ["NIR"],
    "IRL": ["IRL"], "CAN": ["CAN"], "USA": ["USB", "USK", "USH"],
    "FRA": ["FXX", "FXC"], "DEU": ["DEU"], "NLD": ["NLD"], "BEL": ["BFR", "BWR", "BCR"],
    "LUX": ["LUX"], "CHE": ["CHE"], "AUT": ["AUT"], "DNK": ["DNK", "DNB"], "NOR": ["NOR"],
    "SWE": ["SWE"], "ITA": ["ITX", "ITY", "ITD", "ITP"], "ESP": ["ESX", "ESI", "ESC"],
    "PRT": ["PRX", "PMD", "PAZ"],
}
SUBUNIT_NAMES = {
    "ENG": "England", "SCT": "Scotland", "WLS": "Wales", "NIR": "Northern Ireland",
    "IRL": "Ireland", "USA": "United States", "CAN": "Canada",
    "FRA": "France", "DEU": "Germany", "NLD": "Netherlands", "BEL": "Belgium",
    "LUX": "Luxembourg", "CHE": "Switzerland", "AUT": "Austria", "DNK": "Denmark",
    "NOR": "Norway", "SWE": "Sweden", "ITA": "Italy", "ESP": "Spain", "PRT": "Portugal",
}
# Outlines whose subunits share land borders (Belgium's three regions) are
# dissolved into one shape so the outline does not draw internal lines.  The
# others are separate islands / territories and are concatenated as before.
SUBUNIT_DISSOLVE = {"BEL"}

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
  Counties of Ireland (folded to the 26 traditional counties); the regions
  of France (the 13 metropolitan régions of 2016, dissolved from the
  départements), the German Länder, and the provinces of the Netherlands and
  Belgium (with Brussels):
  {ne_base}{ne_10m_admin1}
  Country outlines (England, Scotland, Wales, Northern Ireland, Ireland,
  United States, Canada; France, Germany, Netherlands, Belgium, Luxembourg,
  Switzerland, Austria, Denmark, Norway, Sweden, Italy, Spain, Portugal):
  {ne_base}{ne_50m_subunits}

All layers were simplified (Douglas–Peucker, {tol_hist}° for the historic
counties, {tol_irl}° for Ireland, {tol_eu}° for the Western Europe regions,
{tol_ne50}° for the Natural Earth 1:50m layers) and rounded to {decimals} decimal
places by scripts/build_family_map_units.py.
Borders are approximate and for family-history illustration only.
""".format(
    hcb_url=HCB_URL, ne_base=NE_BASE, ne_50m_admin1=NE_50M_ADMIN1,
    ne_10m_admin1=NE_10M_ADMIN1, ne_50m_subunits=NE_50M_SUBUNITS,
    tol_hist=TOL_HISTORIC, tol_irl=TOL_IRELAND, tol_eu=TOL_EUROPE, tol_ne50=TOL_NE50,
    decimals=DECIMALS,
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


def douglas_peucker_indices(points: list, tolerance: float) -> list:
    """Indices kept by classic Ramer–Douglas–Peucker on an open polyline
    (iterative, so a 40,000-point coastline does not hit the recursion
    limit).  Endpoints are always kept."""
    n = len(points)
    if n < 3:
        return list(range(n))
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
    return [i for i in range(n) if keep[i]]


def douglas_peucker(points: list, tolerance: float) -> list:
    return [points[i] for i in douglas_peucker_indices(points, tolerance)]


def _dedupe_consecutive(points: list) -> list:
    out = []
    for p in points:
        if not out or out[-1] != p:
            out.append(p)
    return out


def _ring_points(ring: list) -> list:
    """A ring as an OPEN list of distinct consecutive tuples (closing point
    removed) — the index space every ring helper below works in."""
    pts = _dedupe_consecutive([tuple(p) for p in ring])
    if len(pts) > 1 and pts[0] == pts[-1]:
        pts = pts[:-1]
    return pts


def _simplify_ring_indices(pts: list, tolerance: float) -> list:
    """Indices into pts (an open ring, len >= 3) kept by Douglas–Peucker.
    Splits at the vertex farthest from the first vertex so DP has two proper
    polylines.  Always contains 0 and the split vertex, strictly increasing."""
    x0, y0 = pts[0]
    far = max(range(1, len(pts)), key=lambda i: (pts[i][0] - x0) ** 2 + (pts[i][1] - y0) ** 2)
    first = douglas_peucker_indices(pts[: far + 1], tolerance)
    second = douglas_peucker_indices(pts[far:] + [pts[0]], tolerance)
    return first[:-1] + [far + k for k in second[:-1]]


def simplify_ring(ring: list, tolerance: float):
    """Simplify a closed ring and re-close it.  Returns None when fewer than
    MIN_RING_POINTS remain (a tiny islet).  Plain DP — see
    simplify_ring_simple for the self-crossing repair the build uses."""
    pts = _ring_points(ring)
    if len(pts) < 3:
        return None
    out = _dedupe_consecutive([pts[k] for k in _simplify_ring_indices(pts, tolerance)])
    if len(out) < 3:
        return None
    out.append(out[0])
    return out


def _wrap_lon(lon: float) -> float:
    while lon > 180.0:
        lon -= 360.0
    while lon < -180.0:
        lon += 360.0
    return lon


def normalise_lon(lon: float) -> float:
    """Bring a longitude into [-180, 180] (Natural Earth's Aleutian pieces can
    carry lon > 180).  Pieces are never merged or clipped across the
    antimeridian; each MultiPolygon piece stays as the source drew it."""
    wrapped = _wrap_lon(lon)
    if wrapped != lon:
        NORMALISED_LONGITUDES[0] += 1
    return wrapped


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


# --------------------------------------------------------------------------
# Ring validity: no proper crossing between non-adjacent edges
# --------------------------------------------------------------------------

def _orientation(p, q, r) -> float:
    return (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0])


def segments_cross(a, b, c, d) -> bool:
    """Strict crossing of segments ab and cd: the interiors meet at one point.
    Touching at an endpoint and collinear overlap both return False."""
    return (_orientation(a, b, c) * _orientation(a, b, d) < 0 and
            _orientation(c, d, a) * _orientation(c, d, b) < 0)


def ring_crossings(ring: list, limit: int = 0) -> list:
    """Proper crossings between non-adjacent edges of a closed ring, as sorted
    (i, j) edge-index pairs (edge i = ring[i] -> ring[i+1]).  Sweep along x
    with bbox rejection, so an 11,000-vertex coastline costs well under a
    second.  limit > 0 stops after that many hits (validity probe)."""
    edges = list(zip(ring, ring[1:]))
    n = len(edges)
    if n < 4:
        return []
    boxes = [(min(ax, bx), min(ay, by), max(ax, bx), max(ay, by)) for (ax, ay), (bx, by) in edges]
    order = sorted(range(n), key=lambda i: boxes[i][0])
    active = []
    found = []
    for i in order:
        x_lo, y_lo, x_hi, y_hi = boxes[i]
        active = [j for j in active if boxes[j][2] >= x_lo]
        a, b = edges[i]
        for j in active:
            gap = abs(i - j)
            if gap == 1 or gap == n - 1:
                continue  # adjacent edges share a vertex; first and last too
            _, v_lo, _, v_hi = boxes[j]
            if v_hi < y_lo or y_hi < v_lo:
                continue
            c, d = edges[j]
            if segments_cross(a, b, c, d):
                found.append((min(i, j), max(i, j)))
                if limit and len(found) >= limit:
                    return found
        active.append(i)
    found.sort()
    return found


def find_crossings(features: list) -> list:
    """(key, polygon index, ring index, edge i, edge j) for every proper
    self-crossing in a feature list.  Empty = every ring is simple."""
    found = []
    for feature in features:
        key = feature["properties"]["key"]
        for pi, rings in enumerate(polygons_of(feature["geometry"])):
            for ri, ring in enumerate(rings):
                for i, j in ring_crossings([tuple(p) for p in ring]):
                    found.append((key, pi, ri, i, j))
    return found


# Per-build histogram: integer key n = rings that needed n local refinement
# passes to come out simple; "vertices" = original vertices re-inserted by
# those passes; "original" = rings that fell back to their source vertices.
# Diagnostic only; never affects the output bytes.
RING_REPAIRS = collections.Counter()


def _rounded_ring(pts: list, kept: list):
    """Closed 6-dp ring over the kept indices, plus the index into pts of each
    distinct rounded vertex (so edge e of the ring runs between original
    vertices origin[e] and origin[e + 1]).  (None, None) when fewer than 3
    distinct vertices survive rounding."""
    verts, origin = [], []
    for k in kept:
        x, y = pts[k]
        p = (round(_wrap_lon(x), DECIMALS), round(y, DECIMALS))
        if verts and verts[-1] == p:
            continue
        verts.append(p)
        origin.append(k)
    if len(verts) > 1 and verts[0] == verts[-1]:
        verts.pop()
        origin.pop()
    if len(verts) < 3:
        return None, None
    return verts + [verts[0]], origin


def _farthest_between(pts: list, a: int, b: int, exclude: set):
    """Index of the original vertex strictly between a and b (cyclically) that
    lies farthest from chord a-b — one Douglas–Peucker step on that chord.
    None when the chord already is an original edge."""
    n = len(pts)
    candidates = range(a + 1, b) if a < b else itertools.chain(range(a + 1, n), range(0, b))
    best, best_k = -1.0, None
    for k in candidates:
        if k in exclude:
            continue
        d = _point_segment_distance(pts[k], pts[a], pts[b])
        if d > best:
            best, best_k = d, k
    return best_k


def simplify_ring_simple(ring: list, tolerance: float):
    """Douglas–Peucker + 6-dp rounding, refusing a self-crossing result.

    DP keeps each vertex by its distance from the current chord and never
    looks at the rest of the ring, so a simplified edge can be pulled straight
    across another part of the same ring (a fjord mouth closing over a spur —
    46 such edge pairs in the first committed build).  Repair is LOCAL: for
    each crossing edge pair, re-insert the original vertex farthest from each
    offending chord (one more DP step on just those chords), re-check, repeat.
    Vertices only ever grow, so this terminates; at worst the ring returns to
    its source vertices, and if even those cross, the ORIGINAL ring (rounded)
    is kept for this ring only and the final build gate names it.  Whole-ring
    re-simplification at a smaller tolerance was tried first and doubled the
    asset (769 KB -> 1.49 MB); local repair costs a few dozen vertices.
    Returns None when the ring is an islet below MIN_RING_POINTS at the
    requested tolerance (unchanged policy)."""
    pts = _ring_points(ring)
    if len(pts) < 3:
        return None
    kept = set(_simplify_ring_indices(pts, tolerance))
    initial = len(kept)
    passes = 0
    while True:
        verts, origin = _rounded_ring(pts, sorted(kept))
        if verts is None:
            return None  # only reachable on the first pass: an islet
        crossings = ring_crossings(verts)
        if not crossings:
            NORMALISED_LONGITUDES[0] += sum(1 for k in origin if _wrap_lon(pts[k][0]) != pts[k][0])
            if passes:
                RING_REPAIRS[passes] += 1
                RING_REPAIRS["vertices"] += len(kept) - initial
            return verts
        grew = False
        m = len(origin)
        for i, j in crossings:
            for e in (i, j):
                k = _farthest_between(pts, origin[e], origin[(e + 1) % m], kept)
                if k is not None:
                    kept.add(k)
                    grew = True
        if not grew:
            break
        passes += 1
    RING_REPAIRS["original"] += 1
    return round_ring([tuple(p) for p in ring])


def simplify_polygons(polygons: list, tolerance: float) -> list:
    """Simplify every ring; drop rings below MIN_RING_POINTS; drop a polygon
    whose outer ring vanished; never drop the whole feature (falls back to the
    largest un-simplified polygon — its outer ring AND its holes — so the unit
    still has a shape and a lake does not become land)."""
    out = []
    for rings in polygons:
        new_rings = []
        for i, ring in enumerate(rings):
            s = simplify_ring_simple(ring, tolerance)
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
        restored = []
        for i, ring in enumerate(biggest):
            kept = round_ring([tuple(p) for p in ring])
            if kept is None:
                if i == 0:
                    raise ValueError("feature collapsed entirely")
                continue  # a hole below MIN_RING_POINTS may go, as in the main path
            restored.append(kept)
        out = [restored]
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

def _turn(prev, at, nxt) -> float:
    """Signed turn angle in (-pi, pi] going prev -> at -> nxt; positive = left
    (counter-clockwise), 0 = straight on, ±pi = back the way we came."""
    dx1, dy1 = at[0] - prev[0], at[1] - prev[1]
    dx2, dy2 = nxt[0] - at[0], nxt[1] - at[1]
    return math.atan2(dx1 * dy2 - dy1 * dx2, dx1 * dx2 + dy1 * dy2)


def _ring_witness(ring: list) -> tuple:
    """A point for containment tests that is on this ring but not on a ring
    that merely touches it at a vertex: the midpoint of its first edge."""
    (x1, y1), (x2, y2) = ring[0], ring[1]
    return ((x1 + x2) / 2.0, (y1 + y2) / 2.0)


def dissolve(polygon_sets: list):
    """Merge several units' polygons into one.  Shared borders in
    topologically clean data appear as an edge in one unit and its reverse in
    the neighbour; removing both and re-chaining the rest gives the outline.
    Returns (polygons, ok).  ok=False (with the plain concatenation) when the
    edges do not chain into closed rings.

    Chaining rule at a vertex with several outgoing edges (two shells that
    touch at exactly one point, or a unit that pinches against itself): take
    the edge that turns most sharply toward the FILL side of the input rings.
    With consistently oriented input every other ring's edge lies in this
    ring's exterior wedge, so the ring's own continuation always wins — a
    touch-at-a-point is not a shared border, and the two shells stay
    separate simple rings instead of becoming one figure-eight.  The choice
    depends only on geometry, never on input order.  (The sources are all
    clockwise; the fill side is read from the input, not assumed.)"""
    concatenated = [rings for polygons in polygon_sets for rings in polygons]
    if len(polygon_sets) < 2:
        return concatenated, True
    fill_left = sum(ring_area(rings[0]) for rings in concatenated) > 0  # CCW shells = fill on the left
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
    for (a, b), n in sorted(remaining.items()):
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
            if len(nexts) == 1 or len(ring) == 1:
                choice = 0  # the only way on, or no incoming direction yet (sorted -> deterministic)
            else:
                prev = ring[-2]
                turns = [_turn(prev, current, nxt) for nxt in nexts]
                best = max(turns) if fill_left else min(turns)
                choice = turns.index(best)
            nxt = nexts.pop(choice)
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
        witness = _ring_witness(ring)
        containers = [other for other in rings if other is not ring and point_in_ring(witness, other)]
        (holes if len(containers) % 2 == 1 else outers).append(ring)
    polygons = [[outer] for outer in outers]
    for hole in holes:
        owner = None
        witness = _ring_witness(hole)
        for rings_ in polygons:
            if point_in_ring(witness, rings_[0]):
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


def load_europe(cache: pathlib.Path) -> tuple:
    """Western Europe's second level from NE 1:10m admin-1 (the same file as
    Ireland): France by the 13 metropolitan régions (départements dissolved
    by their `region`), Germany by Land, the Netherlands and Belgium by
    province.  Fails loudly when a table above and the source disagree."""
    path = download(NE_BASE + NE_10M_ADMIN1, cache / NE_10M_ADMIN1)
    data = json.loads(path.read_text(encoding="utf-8"))
    france = collections.OrderedDict()
    departements = 0
    by_iso = {}
    for feature in data["features"]:
        p = feature["properties"]
        iso = p.get("iso_a2")
        if iso == "FR":
            if p.get("type_en") != FRANCE_METROPOLITAN_TYPE:
                continue  # overseas département: the country outline covers it
            region = p.get("region")
            if region not in FRANCE_REGION_NAMES:
                raise ValueError(f"French département {p.get('name')!r} has an unknown région {region!r}")
            france.setdefault(region, []).append(polygons_of(feature["geometry"]))
            departements += 1
        elif iso in ("DE", "NL", "BE"):
            by_iso[(p.get("iso_3166_2") or "").strip()] = feature
    if departements != FRANCE_EXPECTED_DEPARTEMENTS or set(france) != set(FRANCE_REGION_NAMES):
        raise ValueError(f"expected {FRANCE_EXPECTED_DEPARTEMENTS} metropolitan départements in "
                         f"{len(FRANCE_REGION_NAMES)} régions, got {departements} in {sorted(france)}")
    units, notes = [], []
    for region in sorted(france):
        polygons, ok = dissolve(france[region])
        notes.append(f"  France: {FRANCE_REGION_NAMES[region]} = {len(france[region])} départements "
                     f"{'dissolved' if ok else 'CONCATENATED (dissolve failed)'} -> {len(polygons)} polygon(s)")
        units.append(("region", "FRA", FRANCE_REGION_NAMES[region], polygons, TOL_EUROPE))
    for country, (iso_a2, kind, table) in EUROPE_ADMIN1.items():
        missing = [code for code in table if code not in by_iso]
        if missing:
            raise ValueError(f"{country}: NE admin-1 has no unit for {missing}")
        for code, name in table.items():
            units.append((kind, country, name, polygons_of(by_iso[code]["geometry"]), TOL_EUROPE))
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
        pieces = []
        for code in codes:
            if code not in by_code:
                raise ValueError(f"map subunit {code} not found for {country}")
            pieces.append(polygons_of(by_code[code]["geometry"]))
        if country in SUBUNIT_DISSOLVE:
            polygons, ok = dissolve(pieces)
            if not ok:
                print(f"  note: {country} outline subunits CONCATENATED (dissolve failed)")
        else:
            polygons = [rings for piece in pieces for rings in piece]
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
    RING_REPAIRS.clear()
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
    europe, europe_notes = load_europe(cache)
    units += europe
    notes += europe_notes
    units += load_country_outlines(cache)
    features, stats = build_features(units)
    for feature in features:
        for rings in polygons_of(feature["geometry"]):
            for ring in rings:
                for lon, lat in ring:
                    if not (-180.0 <= lon <= 180.0 and -90.0 <= lat <= 90.0):
                        raise ValueError(f"{feature['properties']['key']}: coordinate out of range ({lon}, {lat})")
    crossings = find_crossings(features)
    if crossings:
        print(f"\nREFUSING to write {OUTPUT_NAME}: {len(crossings)} self-crossing edge pair(s) remain after repair:")
        for key, pi, ri, i, j in crossings:
            print(f"  {key} polygon {pi} ring {ri} edges {i}/{j}")
        return 1
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
    passes = sorted(k for k in RING_REPAIRS if isinstance(k, int))
    repaired = sum(RING_REPAIRS[k] for k in passes)
    total_rings = sum(len(rings) for f in features for rings in polygons_of(f["geometry"]))
    notes.append(f"  self-crossing rings repaired locally: {repaired} of {total_rings} output rings, "
                 f"{RING_REPAIRS['vertices']} original vertices re-inserted; all output rings validated simple")
    for n in passes:
        notes.append(f"    needed {n} refinement pass(es): {RING_REPAIRS[n]} ring(s)")
    notes.append(f"    fell back to the original ring: {RING_REPAIRS['original']}")
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
    crossings = find_crossings(features)
    print(f"\nself-crossing edge pairs (non-adjacent edges of one ring): {len(crossings)}")
    for key, pi, ri, i, j in crossings:
        print(f"  {key} polygon {pi} ring {ri} edges {i}/{j}")
    print("\nkeys:")
    for f in features:
        print(f"  {f['properties']['key']}")
    return 1 if crossings else 0


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
    # Western Europe: accents fold, apostrophes break words.
    assert unit_key("FRA", "region", "Provence-Alpes-Côte d'Azur") == "fra-provence-alpes-cote-d-azur"
    assert unit_key("FRA", "region", "Île-de-France") == "fra-ile-de-france"
    assert unit_key("DEU", "state", "Baden-Württemberg") == "deu-baden-wurttemberg"
    assert unit_key("BEL", "province", "Liège") == "bel-liege"
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
