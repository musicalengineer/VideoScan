"""Family Map units file (GH #227 stage 0) — contract tests.

No network: reads the committed GeoJSON under VideoScan/VideoScan/Resources/
FamilyMap and imports the build script only for its pure helpers
(Douglas–Peucker, slug, point-in-ring).  Run with the repo venv:

    venv/bin/python -m pytest -q tests/test_family_map_units.py
"""

import importlib.util
import json
import pathlib
import sys

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "VideoScan" / "VideoScan" / "Resources" / "FamilyMap"
GEOJSON = RESOURCES / "family-map-units.geojson"
ATTRIBUTION = RESOURCES / "ATTRIBUTION.txt"
SCRIPT = ROOT / "scripts" / "build_family_map_units.py"

MAX_BYTES = 1_500_000
COUNTRIES = {"ENG", "SCT", "WLS", "NIR", "IRL", "USA", "CAN"}
KINDS = {"county", "state", "province", "country"}
# Sane per-country longitude/latitude windows (lon_min, lon_max, lat_min, lat_max).
# The USA outline's far-Aleutian pieces sit east of the antimeridian
# (lon 165..180 in the source) and are kept as separate pieces, so the USA
# window is the union of two lon ranges.
BBOX = {
    "USA": (-180.0, -50.0, 15.0, 75.0),
    "CAN": (-145.0, -50.0, 40.0, 84.0),
    "ENG": (-11.0, 2.0, 49.0, 61.0),
    "SCT": (-11.0, 2.0, 49.0, 61.0),
    "WLS": (-11.0, 2.0, 49.0, 61.0),
    "NIR": (-11.0, 2.0, 49.0, 61.0),
    "IRL": (-11.0, 2.0, 49.0, 61.0),
}

# Design doc §1 spellings (synthetic list, no personal data).  Each must slug
# to a key in the file.  Where the source spells a county differently the
# exception is written down here so the test documents it instead of
# silently passing; if the source ever changes, this fails.
SYNTHETIC_COUNTIES = {
    "ENG": [
        "Yorkshire", "Suffolk", "Kent", "Essex", "Cheshire", "Lancashire", "Norfolk",
        "Devon", "Somerset", "Shropshire", "Gloucestershire", "Lincolnshire",
        "Northamptonshire", "Buckinghamshire", "Staffordshire", "Wiltshire",
        "Cornwall", "Warwickshire", "Hertfordshire", "Oxfordshire", "Sussex",
        "Dorset", "Derbyshire", "Berkshire", "Leicestershire", "Northumberland",
        "Hampshire", "Middlesex", "Herefordshire", "Bedfordshire",
        "Nottinghamshire", "Surrey", "Cambridgeshire", "Worcestershire", "Durham",
        "Cumberland", "Westmorland", "Huntingdonshire", "Rutland",
    ],
    "SCT": [
        "Aberdeenshire", "Perthshire", "Midlothian", "Fife", "Lanarkshire",
        "Ayrshire", "Stirlingshire", "Roxburghshire", "Dumfriesshire",
        "East Lothian", "Berwickshire", "Renfrewshire", "Kincardineshire", "Argyll",
        "Angus", "Inverness-shire",
    ],
    "WLS": [
        "Monmouthshire", "Glamorgan", "Denbighshire", "Montgomeryshire",
        "Carmarthenshire", "Caernarfonshire", "Pembrokeshire", "Merionethshire",
        "Breconshire", "Flintshire", "Cardiganshire", "Radnorshire", "Anglesey",
    ],
    "USA": [
        "Massachusetts", "Rhode Island", "Connecticut", "Virginia", "South Carolina",
        "Maine", "New York", "New Hampshire", "Vermont", "Pennsylvania",
        "North Carolina", "New Jersey", "Maryland", "Kentucky", "Ohio",
    ],
    "CAN": ["Quebec", "Nova Scotia", "New Brunswick", "Ontario"],
}
# Design-doc spelling -> the Historic County Borders Project's NAME.  These are
# the only synthetic spellings that do not slug straight to a key; the Core
# resolver's alias table must carry them.
SOURCE_SPELLING = {
    ("SCT", "Argyll"): "Argyllshire",
    ("WLS", "Breconshire"): "Brecknockshire",
}

# (lat, lon) -> expected key, or None for open sea.
PROBES = [
    ("York", 53.9600, -1.0873, "eng-yorkshire"),
    ("Boston MA", 42.3601, -71.0589, "usa-massachusetts"),
    ("Edinburgh", 55.9533, -3.1883, "sct-midlothian"),
    ("Cardiff", 51.4816, -3.1791, "wls-glamorgan"),
    ("London", 51.5072, -0.1276, "eng-middlesex"),
    ("Glasgow", 55.8642, -4.2518, "sct-lanarkshire"),
    ("Galway city", 53.2707, -9.0568, "irl-galway"),
    ("North Sea", 55.0, 2.0, None),
    # Halifax waterfront (44.6488, -63.5752) is NOT inside Natural Earth's
    # 1:50m Nova Scotia polygon even before simplification (the harbour
    # peninsula is below 1:50m resolution) — see the dedicated test below.
    ("Halifax NS airport, 10 km inland", 44.8808, -63.5086, "can-nova-scotia"),
]
HALIFAX_WATERFRONT = (44.6488, -63.5752)


def _load_script():
    spec = importlib.util.spec_from_file_location("build_family_map_units", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def script():
    return _load_script()


@pytest.fixture(scope="module")
def collection():
    return json.loads(GEOJSON.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def features(collection):
    return collection["features"]


@pytest.fixture(scope="module")
def by_key(features):
    return {f["properties"]["key"]: f for f in features}


def _polygons(geometry):
    if geometry["type"] == "Polygon":
        return [geometry["coordinates"]]
    assert geometry["type"] == "MultiPolygon", geometry["type"]
    return geometry["coordinates"]


def _point_in_ring(lon, lat, ring):
    """Ray-cast point-in-polygon, pure Python (independent of the script)."""
    inside = False
    for (x1, y1), (x2, y2) in zip(ring, ring[1:]):
        if (y1 > lat) != (y2 > lat):
            xi = x1 + (lat - y1) * (x2 - x1) / (y2 - y1)
            if lon < xi:
                inside = not inside
    return inside


def _unit_contains(feature, lon, lat):
    for rings in _polygons(feature["geometry"]):
        if _point_in_ring(lon, lat, rings[0]) and not any(_point_in_ring(lon, lat, hole) for hole in rings[1:]):
            return True
    return False


# --------------------------------------------------------------------------
# File shape
# --------------------------------------------------------------------------

def test_files_exist_and_size_ceiling():
    assert GEOJSON.is_file()
    assert ATTRIBUTION.is_file()
    assert GEOJSON.stat().st_size <= MAX_BYTES, f"{GEOJSON.stat().st_size:,} bytes > {MAX_BYTES:,}"


def test_attribution_carries_required_acknowledgement():
    text = ATTRIBUTION.read_text(encoding="utf-8")
    assert "This mapping made use of data provided by the Historic County Borders Project." in text
    assert "county-borders.co.uk" in text
    assert "Natural Earth" in text


def test_valid_geojson_feature_collection(collection, features):
    assert collection["type"] == "FeatureCollection"
    assert len(features) > 100
    for f in features:
        assert f["type"] == "Feature"
        assert f["geometry"]["type"] in ("Polygon", "MultiPolygon"), f["properties"]
        for rings in _polygons(f["geometry"]):
            assert len(rings) >= 1
            for ring in rings:
                assert len(ring) >= 4, f["properties"]["key"]
                assert ring[0] == ring[-1], f"{f['properties']['key']}: ring not closed"
                for point in ring:
                    assert len(point) == 2


def test_properties_in_allowed_sets(features):
    for f in features:
        p = f["properties"]
        assert set(p) == {"key", "name", "country", "kind"}, p
        assert isinstance(p["key"], str) and p["key"]
        assert isinstance(p["name"], str) and p["name"]
        assert p["country"] in COUNTRIES, p
        assert p["kind"] in KINDS, p


def test_keys_unique_sorted_and_follow_the_rule(features, script):
    keys = [f["properties"]["key"] for f in features]
    assert len(keys) == len(set(keys)), "duplicate keys"
    assert keys == sorted(keys), "features not sorted by key"
    for f in features:
        p = f["properties"]
        assert p["key"] == script.unit_key(p["country"], p["kind"], p["name"]), p


def test_every_country_has_exactly_one_outline(features):
    outlines = [f["properties"]["country"] for f in features if f["properties"]["kind"] == "country"]
    assert sorted(outlines) == sorted(COUNTRIES)
    for f in features:
        p = f["properties"]
        if p["kind"] == "country":
            assert p["key"] == p["country"].lower()


def test_kind_matches_country(features):
    expected = {"ENG": "county", "SCT": "county", "WLS": "county", "NIR": "county",
                "IRL": "county", "USA": "state", "CAN": "province"}
    for f in features:
        p = f["properties"]
        if p["kind"] != "country":
            assert p["kind"] == expected[p["country"]], p


def test_layer_counts(features):
    counts = {}
    for f in features:
        p = f["properties"]
        counts[(p["country"], p["kind"])] = counts.get((p["country"], p["kind"]), 0) + 1
    assert counts[("ENG", "county")] == 39
    assert counts[("SCT", "county")] == 34
    assert counts[("WLS", "county")] == 13
    assert counts[("NIR", "county")] == 6
    assert counts[("IRL", "county")] == 26
    assert counts[("USA", "state")] == 51   # 50 states + District of Columbia
    assert counts[("CAN", "province")] == 13  # 10 provinces + 3 territories


# --------------------------------------------------------------------------
# Coordinates
# --------------------------------------------------------------------------

def test_coordinates_in_range_six_decimals_and_sane_bbox(features):
    for f in features:
        p = f["properties"]
        lon_min, lon_max, lat_min, lat_max = BBOX[p["country"]]
        for rings in _polygons(f["geometry"]):
            for ring in rings:
                for lon, lat in ring:
                    assert -180.0 <= lon <= 180.0 and -90.0 <= lat <= 90.0, (p["key"], lon, lat)
                    lon_ok = lon_min <= lon <= lon_max or (p["country"] == "USA" and 165.0 <= lon <= 180.0)
                    assert lon_ok and lat_min <= lat <= lat_max, (p["key"], lon, lat)
                    assert round(lon, 6) == lon and round(lat, 6) == lat, (p["key"], lon, lat)


@pytest.mark.parametrize("key", ["usa-alaska", "usa"])
def test_pieces_never_straddle_the_antimeridian(by_key, key):
    """Each MultiPolygon piece stays on one side of ±180 (never merged or
    clipped across it); Core handles the split per piece.  The `usa` outline
    has far-Aleutian pieces with lon > 0; `usa-alaska` (NE 50m admin-1) has
    none in the current source."""
    for rings in _polygons(by_key[key]["geometry"]):
        lons = [lon for ring in rings for lon, _ in ring]
        assert max(lons) - min(lons) < 180.0, key


def test_usa_outline_has_far_aleutian_pieces_east_of_antimeridian(by_key):
    pieces = _polygons(by_key["usa"]["geometry"])
    east = [rings for rings in pieces if min(lon for ring in rings for lon, _ in ring) > 0]
    assert east, "expected far-Aleutian pieces with lon > 0 in the USA outline"
    for rings in east:
        assert all(165.0 <= lon <= 180.0 for ring in rings for lon, _ in ring)


# --------------------------------------------------------------------------
# Coverage of the design-doc spellings
# --------------------------------------------------------------------------

def test_synthetic_county_spellings_resolve_to_keys(by_key, script):
    missing = []
    for country, names in SYNTHETIC_COUNTIES.items():
        for name in names:
            source_name = SOURCE_SPELLING.get((country, name), name)
            key = f"{country.lower()}-{script.slug(source_name)}"
            if key not in by_key:
                missing.append((country, name, key))
    assert not missing, f"design-doc spellings with no unit in the file: {missing}"


def test_documented_source_spellings_are_still_the_source_spellings(by_key, script):
    """The exceptions table must stay honest: the plain spelling must NOT be a
    key (else the exception is stale) and the source spelling must be."""
    for (country, name), source_name in SOURCE_SPELLING.items():
        plain = f"{country.lower()}-{script.slug(name)}"
        source = f"{country.lower()}-{script.slug(source_name)}"
        assert plain not in by_key, f"{plain} now exists; drop the SOURCE_SPELLING entry"
        assert source in by_key, source


def test_single_unit_counties_are_not_split(by_key):
    """Yorkshire and Sussex are single historic units in the source; the
    resolver can map ridings / East-West Sussex straight to them."""
    assert "eng-yorkshire" in by_key and "eng-north-yorkshire" not in by_key
    assert "eng-sussex" in by_key and "eng-east-sussex" not in by_key
    assert "eng-middlesex" in by_key and "eng-london" not in by_key


def test_ireland_names_have_no_county_prefix(features):
    for f in features:
        p = f["properties"]
        if p["country"] == "IRL" and p["kind"] == "county":
            assert not p["name"].startswith("County "), p


# --------------------------------------------------------------------------
# Geometry probes against the actual bundled shapes
# --------------------------------------------------------------------------

@pytest.mark.parametrize("label,lat,lon,expected", PROBES, ids=[p[0] for p in PROBES])
def test_probe_point_lands_in_expected_unit(by_key, label, lat, lon, expected):
    hits = sorted(
        key for key, f in by_key.items()
        if f["properties"]["kind"] != "country" and _unit_contains(f, lon, lat)
    )
    if expected is None:
        assert hits == [], f"{label} should be at sea, hit {hits}"
    else:
        assert hits == [expected], f"{label}: expected [{expected}], got {hits}"


def test_halifax_waterfront_is_a_known_source_gap(by_key):
    """Sensor for a documented limitation: NE 1:50m omits the Halifax harbour
    peninsula, so the waterfront point hits no province.  If a future source
    fixes this, this test fails and the probe above can move back downtown."""
    lat, lon = HALIFAX_WATERFRONT
    hits = [key for key, f in by_key.items() if f["properties"]["kind"] != "country" and _unit_contains(f, lon, lat)]
    assert hits == [], f"Halifax waterfront now resolves to {hits}; update PROBES"


def test_probe_points_land_in_their_country_outline(by_key):
    for label, lat, lon, expected in PROBES:
        if expected is None:
            continue
        country = expected.split("-")[0]
        assert _unit_contains(by_key[country], lon, lat), f"{label} not inside {country} outline"


# --------------------------------------------------------------------------
# Script self-test (pure helpers, no network)
# --------------------------------------------------------------------------

def test_douglas_peucker_reference_polyline(script):
    points = [(0.0, 0.0), (1.0, 0.1), (2.0, -0.1), (3.0, 5.0), (4.0, 6.0), (5.0, 7.0),
              (6.0, 8.1), (7.0, 9.0), (8.0, 9.0), (9.0, 9.0)]
    assert script.douglas_peucker(points, 1.0) == [(0.0, 0.0), (2.0, -0.1), (3.0, 5.0), (7.0, 9.0), (9.0, 9.0)]
    # Endpoints always survive; a huge tolerance leaves only them.
    assert script.douglas_peucker(points, 100.0) == [points[0], points[-1]]
    assert script.douglas_peucker(points[:2], 1.0) == points[:2]
    # Tolerance 0 drops only exactly collinear points ((4,6),(5,7) sit on (3,5)->(7,9)).
    assert (6.0, 8.1) in script.douglas_peucker(points, 0.0)


def test_simplify_ring_keeps_closure_and_drops_islets(script):
    square = [(0, 0), (0.001, 0.5), (0, 1), (1, 1), (1, 0), (0, 0)]
    assert script.simplify_ring(square, 0.01) == [(0, 0), (0, 1), (1, 1), (1, 0), (0, 0)]
    islet = [(0, 0), (0.001, 0.001), (0.002, 0), (0, 0)]
    assert script.simplify_ring(islet, 0.01) is None


def test_slug_rules(script):
    assert script.slug("Inverness-shire") == "inverness-shire"
    assert script.slug("Québec") == "quebec"
    assert script.slug("New  York") == "new-york"
    assert script.slug("Dún Laoghaire–Rathdown") == "dun-laoghaire-rathdown"
    assert script.unit_key("ENG", "country", "England") == "eng"
    assert script.unit_key("IRL", "county", script.strip_county_prefix("County Cork")) == "irl-cork"


def test_script_self_test_passes(script):
    assert script.self_test() == 0
