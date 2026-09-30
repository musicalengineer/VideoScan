"""Offline adversarial regressions for the Family Map stage-0 builder.

Fixtures are synthetic lon/lat geometries plus sensors over the committed
asset; no downloads. The containment, area and crossing oracles below are
independent of the builder's helpers.
Run: venv/bin/python -m pytest -q tests/test_family_map_pipeline_regressions.py
"""

import copy
import importlib.util
import json
import pathlib

import pytest


ROOT = pathlib.Path(__file__).resolve().parents[1]


@pytest.fixture
def script():
    # Fresh module per test also isolates the longitude diagnostic counter.
    spec = importlib.util.spec_from_file_location(
        "family_map_pipeline_under_test", ROOT / "scripts/build_family_map_units.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def rectangle(x, y, width, height):
    return [(x, y), (x + width, y), (x + width, y + height),
            (x, y + height), (x, y)]


def in_ring(point, ring):
    x, y = point
    crossings = sum(
        1 for (ax, ay), (bx, by) in zip(ring, ring[1:])
        if (ay > y) != (by > y) and x < ax + (y - ay) * (bx - ax) / (by - ay)
    )
    return crossings % 2 == 1


def contains(polygons, point):
    return any(in_ring(point, rings[0]) and
               not any(in_ring(point, hole) for hole in rings[1:])
               for rings in polygons)


def area(ring):
    return abs(sum(ax * by - bx * ay for (ax, ay), (bx, by)
                   in zip(ring, ring[1:])) / 2)


def filled_area(polygons):
    return sum(area(rings[0]) - sum(area(hole) for hole in rings[1:])
               for rings in polygons)


def assert_simple_closed_rings(polygons):
    for rings in polygons:
        for ring in rings:
            assert ring[0] == ring[-1]
            assert len(ring) >= 4
            assert len(set(map(tuple, ring[:-1]))) == len(ring) - 1, (
                "nonclosing vertex repeated: self-touching ring", ring
            )
            assert area(ring) > 0


def test_simplification_keeps_surviving_hole_and_does_not_mutate_input(script):
    polygons = [[rectangle(0, 0, 4, 4), list(reversed(rectangle(1, 1, 1, 1)))]]
    original = copy.deepcopy(polygons)
    result = script.simplify_polygons(polygons, 0.01)
    assert polygons == original
    assert len(result) == 1 and len(result[0]) == 2
    assert contains(result, (0.5, 0.5))
    assert not contains(result, (1.5, 1.5))
    assert filled_area(result) == pytest.approx(15)
    assert_simple_closed_rings(result)


def test_simplification_fallback_keeps_original_hole(script):
    """Restoring an original shell must restore its original exclusions too.

    A small unit at the production historic-county tolerance collapses every
    simplified shell and enters fallback. A lake/enclave must not become land
    merely because the enclosing county required fallback.
    """
    polygons = [[rectangle(0, 0, 0.008, 0.008),
                 list(reversed(rectangle(0.002, 0.002, 0.002, 0.002)))]]
    result = script.simplify_polygons(polygons, script.TOL_HISTORIC)
    assert contains(result, (0.006, 0.006)), "whole county was lost"
    assert not contains(result, (0.003, 0.003)), "fallback filled the original hole"
    assert filled_area(result) == pytest.approx(0.000060)


def test_tiny_hole_can_be_dropped_without_losing_surviving_shell(script):
    # The ordinary simplification policy explicitly permits tiny rings to go.
    # This control distinguishes that policy from restoring only half of an
    # original polygon in the fallback regression above.
    polygons = [[rectangle(0, 0, 4, 4), list(reversed(rectangle(1, 1, 0.001, 0.001)))]]
    result = script.simplify_polygons(polygons, 0.01)
    assert len(result) == 1 and len(result[0]) == 1
    assert contains(result, (3, 3))


def test_fallback_keeps_every_unit_even_when_all_its_pieces_collapse(script):
    units = [
        ("county", "ENG", "Small One", [[rectangle(0, 0, 0.001, 0.001)]], 0.01),
        ("county", "ENG", "Small Two", [[rectangle(1, 1, 0.002, 0.002)],
                                           [rectangle(2, 2, 0.001, 0.001)]], 0.01),
    ]
    features, stats = script.build_features(units)
    assert [f["properties"]["key"] for f in features] == ["eng-small-one", "eng-small-two"]
    assert stats["ENG/county"]["features"] == 2
    for feature, probe in zip(features, [(0.0005, 0.0005), (1.001, 1.001)]):
        polygons = script.polygons_of(feature["geometry"])
        assert contains(polygons, probe), feature["properties"]["key"]
        assert_simple_closed_rings(polygons)


@pytest.mark.parametrize("reverse_inputs", [False, True])
def test_dissolve_adjacent_units_removes_seam_and_keeps_hole(script, reverse_inputs):
    left = [[rectangle(0, 0, 3, 3), list(reversed(rectangle(1, 1, 1, 1)))]]
    right = [[rectangle(3, 0, 1, 3)]]
    inputs = [right, left] if reverse_inputs else [left, right]
    original = copy.deepcopy(inputs)
    result, ok = script.dissolve(inputs)
    assert ok and len(result) == 1 and len(result[0]) == 2
    assert inputs == original
    assert filled_area(result) == pytest.approx(11)
    assert contains(result, (0.5, 0.5)) and contains(result, (3.5, 0.5))
    assert not contains(result, (1.5, 1.5))
    # A true dissolve removes the common edge, not just concatenates units.
    all_edges = [set((tuple(a), tuple(b))) for rings in result
                 for ring in rings for a, b in zip(ring, ring[1:])]
    assert {(3, 0), (3, 3)} not in all_edges
    assert_simple_closed_rings(result)


def test_dissolve_nested_island_stays_filled_inside_parent_hole(script):
    donut = [[rectangle(0, 0, 5, 5), list(reversed(rectangle(1, 1, 3, 3)))]]
    island = [[rectangle(2, 2, 1, 1)]]
    result, ok = script.dissolve([donut, island])
    assert ok and len(result) == 2
    assert filled_area(result) == pytest.approx(17)
    assert contains(result, (0.5, 0.5))
    assert not contains(result, (1.5, 1.5))
    assert contains(result, (2.5, 2.5))
    assert_simple_closed_rings(result)


@pytest.mark.parametrize("reverse_inputs", [False, True])
def test_dissolve_corner_touch_keeps_two_simple_shells(script, reverse_inputs):
    """A point contact cannot turn two islands into a figure-eight shell."""
    inputs = [[[rectangle(0, 0, 1, 1)]], [[rectangle(1, 1, 1, 1)]]]
    if reverse_inputs:
        inputs.reverse()
    result, _ = script.dissolve(inputs)
    # A safe concatenation fallback (ok=False) is equally acceptable here.
    assert_simple_closed_rings(result)
    assert len(result) == 2, "corner-touching units need separate polygon shells"
    assert filled_area(result) == pytest.approx(2)
    assert contains(result, (0.5, 0.5)) and contains(result, (1.5, 1.5))
    assert not contains(result, (0.5, 1.5)) and not contains(result, (1.5, 0.5))


def test_dissolve_unclosed_edges_reports_failure_and_retains_originals(script):
    inputs = [[[[(0, 0), (1, 0), (1, 1)]]], [[rectangle(3, 3, 1, 1)]]]
    original = copy.deepcopy(inputs)
    result, ok = script.dissolve(inputs)
    assert not ok, "unclosed edge chains must not be advertised as dissolved"
    assert result == [inputs[0][0], inputs[1][0]]
    assert inputs == original


def test_build_features_is_byte_stable_sorted_and_nonmutating(script):
    units = [
        ("state", "USA", "Zed", [[rectangle(-80, 40, 1, 1)]], 0.02),
        ("county", "ENG", "Alpha", [[rectangle(-2, 52, 1, 1)]], 0.01),
        ("province", "CAN", "Québec", [[rectangle(-70, 45, 1, 1)]], 0.02),
    ]
    original = copy.deepcopy(units)
    first = script.serialize(script.build_features(units)[0])
    second = script.serialize(script.build_features(units)[0])
    reordered = script.serialize(script.build_features(list(reversed(units)))[0])
    assert first == second == reordered
    assert units == original
    collection = json.loads(first)
    assert [f["properties"]["key"] for f in collection["features"]] == [
        "can-quebec", "eng-alpha", "usa-zed"
    ]
    assert first.endswith("\n")


def test_build_rejects_colliding_normalized_names(script):
    shape = [[rectangle(-70, 45, 1, 1)]]
    units = [("province", "CAN", name, shape, 0.02) for name in ("Québec", "Quebec")]
    with pytest.raises(ValueError, match="duplicate key can-quebec"):
        script.build_features(units)


def test_build_pipeline_is_offline_isolated_and_reproducible(script, monkeypatch, tmp_path):
    historical = [("county", "ENG", "Alpha", [[rectangle(-2, 52, 1, 1)]], 0.01)]
    north_america = [("state", "USA", "Beta", [[rectangle(-80, 40, 1, 1)]], 0.02)]
    ireland = [("county", "IRL", "Gamma", [[rectangle(-9, 53, 1, 1)]], 0.005)]
    countries = [("country", "ENG", "England", [[rectangle(-3, 51, 4, 4)]], 0.02)]

    def no_network(*args, **kwargs):
        raise AssertionError("synthetic build must not reach the network")

    monkeypatch.setattr(script.urllib.request, "urlopen", no_network)
    monkeypatch.setattr(script, "load_historic_counties", lambda cache: copy.deepcopy(historical))
    monkeypatch.setattr(script, "load_us_canada", lambda cache: copy.deepcopy(north_america))
    monkeypatch.setattr(script, "load_ireland", lambda cache: (copy.deepcopy(ireland), []))
    monkeypatch.setattr(script, "load_country_outlines", lambda cache: copy.deepcopy(countries))
    monkeypatch.setattr(script, "DEFAULT_CACHE", tmp_path / "poisoned-default-cache")
    monkeypatch.setattr(script, "DEFAULT_OUT", tmp_path / "poisoned-default-output")
    first, second = tmp_path / "one", tmp_path / "two"
    assert script.build(tmp_path / "cache-one", first) == 0
    # A previous build's process-global diagnostic must not affect the asset.
    script.NORMALISED_LONGITUDES[0] = 999999
    assert script.build(tmp_path / "cache-two", second) == 0
    for filename in (script.OUTPUT_NAME, script.ATTRIBUTION_NAME):
        assert (first / filename).read_bytes() == (second / filename).read_bytes()
    assert not script.DEFAULT_CACHE.exists() and not script.DEFAULT_OUT.exists()
    data = json.loads((first / script.OUTPUT_NAME).read_text())
    assert [f["properties"]["key"] for f in data["features"]] == [
        "eng", "eng-alpha", "irl-gamma", "usa-beta"
    ]


def proper_crossing(a, b, c, d):
    """Strict segment intersection: excludes contact and collinear edges."""
    def orientation(p, q, r):
        return (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0])

    return (orientation(a, b, c) * orientation(a, b, d) < 0 and
            orientation(c, d, a) * orientation(c, d, b) < 0)


def test_crossing_sensor_distinguishes_crossing_contact_and_collinearity():
    assert proper_crossing((0, 0), (2, 2), (0, 2), (2, 0))
    assert not proper_crossing((0, 0), (1, 1), (1, 1), (2, 0))
    assert not proper_crossing((0, 0), (2, 0), (1, 0), (3, 0))
    assert not proper_crossing((0, 0), (1, 0), (0, 1), (1, 1))


def test_bundled_rings_have_no_proper_edge_crossings(script):
    """Production sensor: simple shells/holes must survive simplification.

    Checks all committed rings, not only representative city points; bbox
    rejection keeps the independent quadratic scan bounded on this asset.
    """
    resource = ROOT / "VideoScan/VideoScan/Resources/FamilyMap/family-map-units.geojson"
    features = json.loads(resource.read_text())["features"]
    crossings = []
    for feature in features:
        key = feature["properties"]["key"]
        for pi, rings in enumerate(script.polygons_of(feature["geometry"])):
            for ri, ring in enumerate(rings):
                edges = list(zip(ring, ring[1:]))
                boxes = [(min(a[0], b[0]), min(a[1], b[1]),
                          max(a[0], b[0]), max(a[1], b[1])) for a, b in edges]
                for i, (a, b) in enumerate(edges):
                    for j in range(i + 2, len(edges)):
                        if i == 0 and j == len(edges) - 1:
                            continue  # first and last are adjacent too
                        x1, y1, x2, y2 = boxes[i]
                        u1, v1, u2, v2 = boxes[j]
                        if x2 < u1 or u2 < x1 or y2 < v1 or v2 < y1:
                            continue
                        c, d = edges[j]
                        if proper_crossing(a, b, c, d):
                            crossings.append((key, pi, ri, i, j))
    assert not crossings, f"{len(crossings)} proper edge crossings: {crossings}"


def test_bundled_holes_have_excluded_interior_witnesses(script):
    resource = ROOT / "VideoScan/VideoScan/Resources/FamilyMap/family-map-units.geojson"
    features = json.loads(resource.read_text())["features"]
    count = 0
    for feature in features:
        polygons = script.polygons_of(feature["geometry"])
        for rings in polygons:
            for hole in rings[1:]:
                # Scan a horizontal line inside the hole and choose midpoints
                # between paired boundary intersections. This works for
                # concave holes without assuming their centroid is interior.
                low, high = min(p[1] for p in hole), max(p[1] for p in hole)
                witness = None
                for fraction in (0.5, 0.25, 0.75, 0.125, 0.875):
                    y = low + (high - low) * fraction
                    xs = sorted(ax + (y - ay) * (bx - ax) / (by - ay)
                                for (ax, ay), (bx, by) in zip(hole, hole[1:])
                                if (ay > y) != (by > y))
                    for left, right in zip(xs[::2], xs[1::2]):
                        point = ((left + right) / 2, y)
                        if in_ring(point, hole) and in_ring(point, rings[0]):
                            # A separate island inside a hole legitimately
                            # fills that point; seek a witness off such islands.
                            if not any(in_ring(point, other[0]) for other in polygons
                                       if other is not rings):
                                witness = point
                                break
                    if witness is not None:
                        break
                assert witness is not None, (feature["properties"]["key"], "hole has no interior witness")
                assert not contains(polygons, witness), (feature["properties"]["key"], witness)
                count += 1
    assert count > 0, "the production hole sensor silently lost all its fixtures"
