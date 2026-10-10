"""Tests for scripts/hallie_demo/tools.py over a tiny synthetic snapshot.

No real family data: the snapshot is written into pytest's tmp_path.
Run:  venv/bin/python -m pytest tests/test_hallie_demo_tools.py -q
"""
import importlib.util
import json
from pathlib import Path

import pytest

TOOLS = Path(__file__).resolve().parent.parent / "scripts/hallie_demo/tools.py"
spec = importlib.util.spec_from_file_location("hallie_demo_tools", TOOLS)
tools = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tools)


def person(pid, full, given, surname, sex, by=None, famc=(), fams=(), fsid=None, more_names=()):
    names = [{"full": full, "given": given, "surname": surname, "suffix": ""}]
    names += [{"full": n, "given": n.split()[0], "surname": n.split()[-1], "suffix": ""} for n in more_names]
    return {"id": pid, "names": names, "sex": sex, "birth": {"year": by, "date": str(by)} if by else {},
            "death": {}, "famc": list(famc), "fams": list(fams), "fsid": fsid}


@pytest.fixture()
def snap(tmp_path):
    P = {
        "@I1@": person("@I1@", "Owen Test", "Owen", "Test", "M", 1960, famc=["@F1@"], fsid="OWNR-001"),
        "@I2@": person("@I2@", "Frank Test", "Frank", "Test", "M", 1930, famc=["@F2@"], fams=["@F1@"]),
        "@I3@": person("@I3@", "Mabel Hudson", "Mabel", "Hudson", "F", 1932, famc=["@F3@"], fams=["@F1@"],
                       fsid="MABL-001"),
        "@I4@": person("@I4@", "Gladys Lamb", "Gladys", "Lamb", "F", 1905, fams=["@F2@"]),
        "@I5@": person("@I5@", "George Test", "George", "Test", "M", 1900, fams=["@F2@"]),
        "@I6@": person("@I6@", "Ivy Hudson", "Ivy", "Hudson", "F", 1907, fams=["@F3@"]),
        "@I7@": person("@I7@", "Ivy Hudson", "Ivy", "Hudson", "F", 1908, fams=["@F3@"], fsid="DUPE-001"),
        "@I8@": person("@I8@", "Carl Hudson", "Carl", "Hudson", "M", 1903, fams=["@F3@"]),
        "@I9@": person("@I9@", "Ann Smith", "Ann", "Smith", "F", 1700, more_names=["Ann Hudson"]),
    }
    P["@I7@"]["identityDecision"] = {"duplicateOf": "REAL-001", "verified": False}
    F = {
        "@F1@": {"id": "@F1@", "husb": "@I2@", "wife": "@I3@", "children": ["@I1@"], "marriage": {}},
        "@F2@": {"id": "@F2@", "husb": "@I5@", "wife": "@I4@", "children": ["@I2@"], "marriage": {}},
        "@F3@": {"id": "@F3@", "husb": "@I8@", "wife": "@I6@", "children": ["@I3@"], "marriage": {}},
    }
    # @I7@ claims the same parent family (the "other Mary" shape)
    F["@F3@"]["children"].append("@I7@")
    P["@I7@"]["fams"] = []
    P["@I7@"]["famc"] = []
    P["@I3@"]["famc"] = ["@F3@"]
    F["@F4@"] = {"id": "@F4@", "husb": None, "wife": "@I7@", "children": [], "marriage": {}}
    # make @I7@ a second "grandmother": a second parent family for @I3@
    P["@I3@"]["famc"].append("@F4@")
    F["@F4@"]["children"].append("@I3@")
    P["@I7@"]["fams"] = ["@F4@"]
    tree = {"owner": "@I1@", "people": P, "families": F, "roots": ["@I1@"]}
    people = {"profiles": [
        {"uuid": "U-MABEL", "name": "Mabel", "surname": "Test", "maidenName": "Hudson", "aliases": ["Ma"],
         "sex": "female", "familySearchID": "MABL-001", "kinships": [], "notes": "Mabel is Owen's mother."},
        {"uuid": "U-OWEN", "name": "Owen", "surname": "Test", "aliases": ["O"], "sex": "male",
         "treeIdentityAttestation": "derived: tree root",
         "kinships": [{"relation": "child", "to": "U-MABEL"}], "notes": "Owner. Sister Bonnie lives nearby."},
    ], "families": [{"uuid": "FAM-1", "name": "Hudson Family", "featuredVideos": []}]}
    brain = {"people": [], "items": [], "sources": []}
    recs = [
        {"id": "R1", "filename": "Thanksgiving-1984.mov", "path": "/v/Thanksgiving-1984.mov", "year": 1984,
         "durationSeconds": 3600, "streamType": "Video+Audio", "contentHash": "h1",
         "confirmedPeople": ["Hudson Family"], "detectedPeople": ["Mabel"]},
        {"id": "R2", "filename": "Thanksgiving-1984 copy.mov", "path": "/w/Thanksgiving-1984 copy.mov", "year": 1984,
         "durationSeconds": 3600, "streamType": "Video+Audio", "contentHash": "h1",
         "confirmedPeople": ["Hudson Family"]},
        {"id": "R3", "filename": "Beach-1990.mov", "path": "/v/Beach-1990.mov", "year": 1990,
         "durationSeconds": 600, "streamType": "Video+Audio", "contentHash": "h3",
         "confirmedPeople": ["Ma"], "tags": ["Gold"]},
        {"id": "R4", "filename": "Rejected.mov", "path": "/v/Rejected.mov", "year": 1991, "durationSeconds": 60,
         "streamType": "Video+Audio", "contentHash": "h4", "detectedPeople": ["Hudson Family"],
         "rejectedPeople": ["Hudson Family"]},
    ]
    catalog = {"meta": {}, "records": recs}
    for name, obj in (("tree.json", tree), ("people.json", people), ("brain.json", brain), ("catalog.json", catalog)):
        (tmp_path / name).write_text(json.dumps(obj))
    return str(tmp_path)


def call(snap, *argv):
    return tools.run(["--snapshots", snap, *argv])


def ids(res):
    return [i["id"] for i in res["items"]]


def test_kin_word_nana_returns_both_grandmothers_never_a_name_count(snap):
    r = call(snap, "resolve_person", "nana")
    assert r["ok"]
    assert set(ids(r)) == {"gedcom:@I4@", "gedcom:@I6@"}  # the duplicate @I7@ is left out
    assert any("duplicate" in n for n in r["notes"])
    assert all("kinTerm" in i["kinds"] for i in r["items"])


def test_kin_word_side_and_typo(snap):
    r = call(snap, "resolve_person", "my materanl grandmother")
    assert ids(r) == ["gedcom:@I6@"]
    r = call(snap, "resolve_person", "dad's side")
    assert ids(r) == ["gedcom:@I2@"]


def test_ma_resolves_to_mother_and_merges_the_profile(snap):
    r = call(snap, "resolve_person", "Ma")
    assert ids(r) == ["gedcom:@I3@"]
    first = r["items"][0]
    assert first["sameAs"] == ["people:U-MABEL"]
    assert {"kinTerm", "profile"} <= set(first["kinds"])


def test_unknown_name_is_none_or_a_labelled_mention(snap):
    r = call(snap, "resolve_person", "Bonnie")
    assert all(i["kinds"] == ["mention"] for i in r["items"])
    r = call(snap, "resolve_person", "Zebulon")
    assert r["items"] == []


def test_surname_count_primary_and_alternate(snap):
    r = call(snap, "catalog_stats", "surname=Hudson")
    assert r["count"] == 4                      # Mabel, Ivy, Ivy(dup), Carl
    assert r["countIncludingAlternateNames"] == 5  # + Ann Smith a.k.a. Ann Hudson
    assert len(r["items"]) == 4 and not r["truncated"]


def test_search_media_by_people_tag_collapses_identical_copies(snap):
    r = call(snap, "search_media", "tags=Hudson", "Family")   # unquoted multi-word value
    assert r["args"]["tags"] == "Hudson Family"
    assert r["matchCount"] == 1 and r["recordCount"] == 2
    item = r["items"][0]
    assert item["copies"] == 2
    assert item["evidence"][0]["kind"].startswith("personTag")
    # R4 carries the tag only as a rejected detection: never returned
    assert all(i["id"] != "catalog:R4" for i in r["items"])


def test_search_media_by_alias_widens_to_profile(snap):
    r = call(snap, "search_media", "people=Mabel")
    assert {i["id"] for i in r["items"]} == {"catalog:R1", "catalog:R3"}  # detected "Mabel" + confirmed "Ma"


def test_catalog_stats_hours_and_copies(snap):
    r = call(snap, "catalog_stats", "text=thanksgiving", "in=filename,path,notes")
    t = r["totals"]
    assert (t["distinctContent"], t["records"], t["extraCopies"]) == (1, 2, 1)
    assert t["distinctHours"] == 1.0 and t["allCopiesHours"] == 2.0


def test_results_carry_query_ids_and_caps(snap):
    r = call(snap, "search_media", "years=1900-2000")
    assert r["queryID"].startswith("q:q-") and r["queryID"] in r["ids"]
    assert len(r["items"]) <= tools.MAX_ITEMS


def test_relationship_between_blood_and_in_law(snap):
    r = call(snap, "relationship_between", "a=gedcom:@I1@", "b=gedcom:@I4@")
    assert r["items"]["relation"] == "grandparent"
    assert r["items"]["pathIDs"] == ["gedcom:@I1@", "gedcom:@I2@", "gedcom:@I4@"]
    r = call(snap, "relationship_between", "a=gedcom:@I5@", "b=gedcom:@I3@")
    assert r["items"]["relation"] == "spouse of child"


def test_bad_args_fail_closed(snap):
    assert call(snap, "search_media")["ok"] is False
    assert call(snap, "nope")["error"] == "unknownTool"
