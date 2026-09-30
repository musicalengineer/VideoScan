"""Regression tests for stage-0 repair's refusal to ship crossed boundaries."""

import importlib.util
import json
import pathlib

import pytest


@pytest.fixture
def script():
    root = pathlib.Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location(
        "family_map_write_gate", root / "scripts/build_family_map_units.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def crossed_feature():
    return {
        "type": "Feature",
        "properties": {"key": "eng-x", "name": "X", "country": "ENG", "kind": "county"},
        "geometry": {"type": "Polygon", "coordinates": [
            [[0, 0], [1, 1], [0, 1], [1, 0], [0, 0]],
        ]},
    }


def test_an_unrepairable_source_ring_cannot_overwrite_existing_assets(script, monkeypatch, tmp_path):
    feature = crossed_feature()
    unit = ("county", "ENG", "X", [feature["geometry"]["coordinates"]], 0)

    def no_network(*args, **kwargs):
        raise AssertionError("the refusal test must stay offline")

    monkeypatch.setattr(script.urllib.request, "urlopen", no_network)
    monkeypatch.setattr(script, "load_historic_counties", lambda cache: [unit])
    monkeypatch.setattr(script, "load_us_canada", lambda cache: [])
    monkeypatch.setattr(script, "load_ireland", lambda cache: ([], []))
    monkeypatch.setattr(script, "load_country_outlines", lambda cache: [])
    output = tmp_path / "existing"
    output.mkdir()
    old_geometry = b"previous verified geometry\n"
    old_attribution = b"previous attribution\n"
    (output / script.OUTPUT_NAME).write_bytes(old_geometry)
    (output / script.ATTRIBUTION_NAME).write_bytes(old_attribution)

    assert script.build(tmp_path / "cache", output) != 0
    assert (output / script.OUTPUT_NAME).read_bytes() == old_geometry
    assert (output / script.ATTRIBUTION_NAME).read_bytes() == old_attribution


def test_report_is_nonzero_for_crossings_and_zero_for_a_simple_ring(script, tmp_path):
    feature = crossed_feature()
    path = tmp_path / script.OUTPUT_NAME
    path.write_text(json.dumps({"type": "FeatureCollection", "features": [feature]}))
    assert script.report(tmp_path) != 0

    feature["geometry"]["coordinates"] = [[[0, 0], [1, 0], [1, 1], [0, 1], [0, 0]]]
    path.write_text(json.dumps({"type": "FeatureCollection", "features": [feature]}))
    assert script.report(tmp_path) == 0
