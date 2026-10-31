#!/usr/bin/env python3
"""tools/household-roster/roster.py — approach A7 feasibility: people as a constraint solver.

No model, no pixels.  For a file's date the family tree says who was alive, their ages and
sex, who lived in the house, and who was probably holding the camera.  This tool measures
whether that roster ALONE narrows a (sex, age band) perception to one person, using what
the catalog already holds as truth: Rick-confirmed People tags on files whose date is
Rick-confirmed (`user_dates`) or a camera-native `embedded_created_at`.

Inputs are read-only: a sqlite `.backup` copy of the catalog opened `mode=ro`, a GEDCOM
file, the People-tab profiles (`POI/*/profile.json`) and `cyberbrain.json`.  Everything
per-file or per-name stays in the scratch JSON; `summarize` writes roles and counts only
and refuses to write if a name, digest or path would leak (privacy, CLAUDE.md rule 13).

Memory: the whole household is ~20 members; the catalog read is one pass over the
confirmed `people_tags` rows (hundreds) plus their `files` rows — worst case O(tagged
files) dicts, far under 10 MB even at 100k tags.

Usage:
  venv/bin/python3 tools/household-roster/roster.py measure --catalog C --gedcom G \\
      --poi DIR --cyberbrain CB --out .scratch/roster/results.json
  venv/bin/python3 tools/household-roster/roster.py summarize --results .scratch/roster/results.json \\
      --md docs/reviews/household_roster_feasibility.md
"""
from __future__ import annotations

import argparse
import collections
import dataclasses
import datetime as dt
import glob
import json
import os
import re
import sqlite3
import sys
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

# ---------------------------------------------------------------------------------------------
# Rules (written down once; the markdown quotes them)
# ---------------------------------------------------------------------------------------------

BANDS: Tuple[Tuple[int, Optional[int], str], ...] = (
    (0, 2, "0–2"), (3, 5, "3–5"), (6, 12, "6–12"), (13, 19, "13–19"), (20, 29, "20–29"),
    (30, 39, "30–39"), (40, 49, "40–49"), (50, 64, "50–64"), (65, None, "65+"),
)
ADULT_AGE = 18            # camera-operator candidates are adults
CHILD_LEAVES_HOME_AT = 18  # a child is "in the household" while younger than this
WIDEN_YEARS = 5

# Same rule as tools/video-llm-bench/bench.py: a camera writes these natively, so
# `format:creation_time` is the footage date; ProRes/FFV1/DNxHD stamps are transfers.
CAMERA_NATIVE_CODECS = {"hevc", "h264", "mjpeg", "dvvideo", "DV 25", "mpeg4", "svq3", "h263"}

APPLE_EPOCH = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)   # NSDate reference date

RULES_TEXT = [
    "Roster = owner, spouse, the owner's children (birth order), the owner's parents and the "
    "spouse's parents; the extended roster adds the owner's siblings. A member is on the roster "
    "at a date if born on or before it; `alive` is false after the death date (alive on the day).",
    "Age = whole years at the date (the birthday counts on the day; a 29 Feb birthday counts on "
    "1 Mar in non-leap years). A year-only date is read as 1 July, a year-month date as the 15th.",
    "Band = one of " + ", ".join(b[2] for b in BANDS) + ". Candidates for (sex, band) = alive roster "
    "members of that sex whose age falls in the band; widened = age within the band ±{} years.".format(
        WIDEN_YEARS),
    "Household at a date: before the owner turns {a}, the owner's childhood home (owner, owner's "
    "parents, owner's siblings under {a}); afterwards the owner's own home (owner; the spouse from "
    "the marriage date, else from the eldest child's birth; children under {a}).".format(a=CHILD_LEAVES_HOME_AT),
    "Camera-operator prior = alive household adults (age ≥ {}) NOT tagged in the file, ranked: owner, "
    "spouse, then the rest oldest first. It is an ordering to propose, not a probability.".format(ADULT_AGE),
    "Truth set = files with at least one owner-confirmed People tag and a date from `user_dates` "
    "(the owner) or, failing that, `files.embedded_created_at` on a camera-native codec. Machine "
    "(detected/suspected) tags are not truth and are only counted.",
    "A tag resolves to a member when it equals (case-insensitive) one profile's name, alias or "
    "People-folder name, or a tree-only member's given name; a tag that matches two members is "
    "ambiguous and excluded; a tag that matches a non-roster profile is off-roster.",
]


# ---------------------------------------------------------------------------------------------
# Dates
# ---------------------------------------------------------------------------------------------

@dataclasses.dataclass(frozen=True)
class PartialDate:
    year: int
    month: Optional[int] = None
    day: Optional[int] = None

    def as_date(self) -> dt.date:
        """The representative calendar day: year-only → 1 July, year-month → the 15th."""
        if self.month is None:
            return dt.date(self.year, 7, 1)
        if self.day is None:
            return dt.date(self.year, self.month, 15)
        return dt.date(self.year, self.month, self.day)

    @property
    def precision(self) -> str:
        return "year" if self.month is None else ("month" if self.day is None else "day")


MONTHS = {m: i + 1 for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"])}


def parse_gedcom_date(text: str) -> Optional[PartialDate]:
    """GEDCOM-ish date → PartialDate.  Accepts '4 Mar 1959', 'june 1928', 'jan 16 1933',
    '1933', 'ABT 1930', 'BEF 1 JAN 1900'; qualifiers are dropped (the day is a guess anyway).
    A range ('BET 1930 AND 1935') takes its first date. Unparseable → None."""
    if not text:
        return None
    tokens = re.findall(r"[A-Za-z]+|\d+", text.lower())
    tokens = [t for t in tokens if t not in {"abt", "about", "bef", "aft", "est", "cal", "c", "circa",
                                              "bet", "from", "to", "int"}]
    if "and" in tokens:
        tokens = tokens[:tokens.index("and")]
    year = month = day = None
    for tok in tokens:
        if tok.isdigit():
            n = int(tok)
            if n > 31 or len(tok) >= 3:
                year = n if year is None else year
            elif day is None:
                day = n
        elif tok[:3] in MONTHS and month is None:
            month = MONTHS[tok[:3]]
    if year is None:
        return None
    if month is None:
        day = None
    if day is not None:
        try:
            dt.date(year, month, day)  # type: ignore[arg-type]
        except ValueError:
            day = None
    return PartialDate(year, month, day)


def parse_user_date(value: str) -> Optional[PartialDate]:
    """`user_dates.value` is YYYY, YYYY-MM or YYYY-MM-DD (schema GLOB)."""
    if not value:
        return None
    parts = value.split("-")
    try:
        nums = [int(p) for p in parts]
    except ValueError:
        return None
    return PartialDate(*nums[:3]) if 1 <= len(nums) <= 3 else None


def apple_reference_to_date(seconds: float) -> dt.date:
    """People-tab dates are seconds since 2001-01-01 UTC (Swift `Date` encoded by JSONEncoder)."""
    return (APPLE_EPOCH + dt.timedelta(seconds=seconds)).date()


def age_years(birth: dt.date, at: dt.date) -> int:
    """Whole years; the birthday counts on the day.  29 Feb in a non-leap year counts on 1 Mar
    (because (2, 28) < (2, 29) the birthday has not happened on 28 Feb)."""
    return at.year - birth.year - ((at.month, at.day) < (birth.month, birth.day))


def band_of(age: int) -> str:
    for lo, hi, label in BANDS:
        if age >= lo and (hi is None or age <= hi):
            return label
    raise ValueError("negative age {}".format(age))


def band_bounds(label: str) -> Tuple[int, Optional[int]]:
    for lo, hi, name in BANDS:
        if name == label:
            return lo, hi
    raise KeyError(label)


def decade_label(year: int) -> str:
    return "{}s".format(year - year % 10)


# ---------------------------------------------------------------------------------------------
# Household model
# ---------------------------------------------------------------------------------------------

@dataclasses.dataclass(frozen=True)
class Member:
    role: str                      # "owner", "spouse", "child 2", "owner's mother", …
    sex: Optional[str]             # "M" / "F" / None
    birth: Optional[PartialDate]
    death: Optional[PartialDate]
    keys: Tuple[str, ...] = ()     # lower-cased tag-match keys (names) — never leave scratch
    hair: Optional[str] = None
    group: str = "core"            # "core" (the brief's roster) or "sibling" (extended)


@dataclasses.dataclass(frozen=True)
class Household:
    members: Tuple[Member, ...]
    marriage: Optional[PartialDate] = None   # owner's marriage; None → eldest child's birth

    def member(self, role: str) -> Optional[Member]:
        return next((m for m in self.members if m.role == role), None)

    def restricted(self, groups: Iterable[str]) -> "Household":
        keep = set(groups)
        return Household(tuple(m for m in self.members if m.group in keep), self.marriage)


@dataclasses.dataclass(frozen=True)
class Person:
    role: str
    sex: Optional[str]
    age_years: int
    alive: bool
    in_household: bool


def _home_start(h: Household) -> Optional[dt.date]:
    """The spouse joins the owner's home at the marriage, else at the eldest child's birth."""
    if h.marriage is not None:
        return h.marriage.as_date()
    births = [m.birth.as_date() for m in h.members if m.role.startswith("child ") and m.birth]
    return min(births) if births else None


def _in_household(h: Household, m: Member, at: dt.date) -> bool:
    owner = h.member("owner")
    if owner is None or owner.birth is None or m.birth is None:
        return False
    owner_age = age_years(owner.birth.as_date(), at)
    age = age_years(m.birth.as_date(), at)
    if owner_age < CHILD_LEAVES_HOME_AT:      # the owner's childhood home
        if m.role in ("owner", "owner's father", "owner's mother"):
            return True
        return m.role.startswith("owner's sibling") and age < CHILD_LEAVES_HOME_AT
    if m.role == "owner":
        return True
    if m.role == "spouse":
        start = _home_start(h)
        return start is not None and at >= start
    if m.role.startswith("child "):
        return age < CHILD_LEAVES_HOME_AT
    return False


def roster(h: Household, at: dt.date) -> List[Person]:
    """Members born on or before `at` (unknown birth → absent: the roster cannot place them)."""
    out: List[Person] = []
    for m in h.members:
        if m.birth is None or m.birth.as_date() > at:
            continue
        alive = m.death is None or at <= m.death.as_date()
        out.append(Person(m.role, m.sex, age_years(m.birth.as_date(), at), alive,
                          alive and _in_household(h, m, at)))
    return out


def _band_match(age: int, band: str, widen: int) -> bool:
    lo, hi = band_bounds(band)
    return age >= lo - widen and (hi is None or age <= hi + widen)


def candidates(h: Household, at: dt.date, sex: Optional[str], band: str, widen: int = 0) -> List[Person]:
    """Alive roster members of `sex` whose age at `at` is in `band` (± `widen` years)."""
    return [p for p in roster(h, at)
            if p.alive and (sex is None or p.sex == sex) and _band_match(p.age_years, band, widen)]


def camera_operator_prior(h: Household, at: dt.date, tagged_roles: Iterable[str]) -> List[Tuple[str, str]]:
    """Ranked (role, reason): alive household adults absent from the tags.  Owner, spouse, then
    oldest first.  Everyone tagged → []."""
    tagged = set(tagged_roles)
    pool = [p for p in roster(h, at) if p.in_household and p.age_years >= ADULT_AGE and p.role not in tagged]

    def rank(p: Person) -> Tuple[int, int]:
        first = {"owner": 0, "spouse": 1}.get(p.role, 2)
        return first, -p.age_years

    return [(p.role, "household adult, {} at the date, not in frame".format(band_of(p.age_years)))
            for p in sorted(pool, key=rank)]


# ---------------------------------------------------------------------------------------------
# Loading the tree (GEDCOM + People tab + CyberBrain)
# ---------------------------------------------------------------------------------------------

@dataclasses.dataclass
class Indi:
    xref: str
    given: str = ""
    sex: Optional[str] = None
    birth: Optional[PartialDate] = None
    death: Optional[PartialDate] = None
    famc: List[str] = dataclasses.field(default_factory=list)
    fams: List[str] = dataclasses.field(default_factory=list)


@dataclasses.dataclass
class Fam:
    xref: str
    husb: Optional[str] = None
    wife: Optional[str] = None
    chil: List[str] = dataclasses.field(default_factory=list)
    marr: Optional[PartialDate] = None


LINE = re.compile(r"^\s*(\d+)\s+(?:(@[^@]+@)\s+)?(\S+)(?:\s(.*))?$")


def parse_gedcom(text: str) -> Tuple[Dict[str, Indi], Dict[str, Fam]]:
    """Tiny GEDCOM reader: INDI (NAME given part, SEX, BIRT/DEAT DATE, FAMC, FAMS) and FAM
    (HUSB, WIFE, CHIL, MARR DATE).  Only the first DATE directly under BIRT/DEAT/MARR counts."""
    indis: Dict[str, Indi] = {}
    fams: Dict[str, Fam] = {}
    rec: Any = None
    event: Optional[str] = None
    for raw in text.splitlines():
        m = LINE.match(raw.lstrip("﻿"))
        if not m:
            continue
        level, xref, tag, value = int(m.group(1)), m.group(2), m.group(3), (m.group(4) or "").strip()
        if level == 0:
            event = None
            rec = Indi(xref) if tag == "INDI" and xref else (Fam(xref) if tag == "FAM" and xref else None)
            if isinstance(rec, Indi):
                indis[rec.xref] = rec
            elif isinstance(rec, Fam):
                fams[rec.xref] = rec
            continue
        if rec is None:
            continue
        if level == 1:
            event = tag if tag in ("BIRT", "DEAT", "MARR") else None
            if isinstance(rec, Indi):
                if tag == "NAME" and not rec.given:
                    rec.given = value.split("/")[0].strip()
                elif tag == "SEX":
                    rec.sex = value[:1].upper() or None
                elif tag == "FAMC":
                    rec.famc.append(value)
                elif tag == "FAMS":
                    rec.fams.append(value)
            else:
                if tag == "HUSB":
                    rec.husb = value
                elif tag == "WIFE":
                    rec.wife = value
                elif tag == "CHIL":
                    rec.chil.append(value)
        elif level == 2 and tag == "DATE" and event:
            parsed = parse_gedcom_date(value)
            if isinstance(rec, Indi) and event == "BIRT" and rec.birth is None:
                rec.birth = parsed
            elif isinstance(rec, Indi) and event == "DEAT" and rec.death is None:
                rec.death = parsed
            elif isinstance(rec, Fam) and event == "MARR" and rec.marr is None:
                rec.marr = parsed
            event = None   # first DATE only
    return indis, fams


def load_profiles(poi_dir: str) -> List[Dict[str, Any]]:
    out = []
    for path in sorted(glob.glob(os.path.join(poi_dir, "*", "profile.json"))):
        with open(path, encoding="utf-8") as f:
            out.append(json.load(f))
    return out


def owner_xref_from_cyberbrain(cb: Dict[str, Any]) -> Optional[str]:
    """The archive's first person: the CyberBrain person named by most first-person sources."""
    counts = collections.Counter(s.get("attribution") for s in cb.get("sources", [])
                                 if s.get("type") == "firstPerson" and s.get("attribution"))
    for name, _ in counts.most_common():
        for p in cb.get("people", []):
            if p.get("canonicalName") == name and p.get("gedcomPersonID"):
                return p["gedcomPersonID"]
    return None


def _profile_keys(p: Dict[str, Any]) -> Tuple[str, ...]:
    keys = [p.get("name"), p.get("legacyFolderName")] + list(p.get("aliases") or [])
    return tuple(sorted({k.strip().lower() for k in keys if isinstance(k, str) and k.strip()}))


def _profile_sex(p: Dict[str, Any]) -> Optional[str]:
    s = (p.get("sex") or "").lower()
    return "M" if s == "male" else ("F" if s == "female" else None)


def _profile_date(p: Dict[str, Any], key: str) -> Optional[PartialDate]:
    v = p.get(key)
    if not isinstance(v, (int, float)):
        return None
    d = apple_reference_to_date(v)
    return PartialDate(d.year, d.month, d.day)


def _kin(profile: Dict[str, Any], relation: str) -> List[str]:
    return [k["relativeTo"]["profile"]["id"] for k in profile.get("kinships") or []
            if k.get("relation") == relation and "profile" in (k.get("relativeTo") or {})]


@dataclasses.dataclass
class LoadReport:
    gedcom_people: int = 0
    profiles: int = 0
    missing_birth: List[str] = dataclasses.field(default_factory=list)   # roles
    missing_sex: List[str] = dataclasses.field(default_factory=list)
    date_disagreements: List[str] = dataclasses.field(default_factory=list)   # roles where tree ≠ People tab
    tree_children_listed: int = 0
    off_roster_keys: Tuple[str, ...] = ()


def _same_day(a: Optional[PartialDate], b: Optional[PartialDate]) -> bool:
    return a is not None and b is not None and a.precision == b.precision == "day" and a == b


def build_household(indis: Dict[str, Indi], fams: Dict[str, Fam], profiles: Sequence[Dict[str, Any]],
                    owner_xref: str) -> Tuple[Household, LoadReport]:
    """Owner from the tree; the People-tab profile is linked to a tree person by (sex, exact birth
    day) — evidence, not a name match.  Roles come from the People-tab kinships (the tree holds
    no living children), the spouse's parents from the tree.  Tree dates win; People-tab dates
    fill gaps; disagreements are reported."""
    rep = LoadReport(gedcom_people=len(indis), profiles=len(profiles))
    by_id = {p["uuid"]: p for p in profiles if p.get("uuid")}

    def profile_for(indi: Optional[Indi]) -> Optional[Dict[str, Any]]:
        if indi is None:
            return None
        for p in profiles:
            if _profile_sex(p) == indi.sex and _same_day(_profile_date(p, "birthdate"), indi.birth):
                return p
        return None

    def indi_for(profile: Dict[str, Any]) -> Optional[Indi]:
        b = _profile_date(profile, "birthdate")
        for i in indis.values():
            if i.sex == _profile_sex(profile) and _same_day(i.birth, b):
                return i
        return None

    members: List[Member] = []
    used_profiles: set = set()

    def add(role: str, group: str, indi: Optional[Indi], profile: Optional[Dict[str, Any]]) -> None:
        tree_birth = indi.birth if indi else None
        prof_birth = _profile_date(profile, "birthdate") if profile else None
        tree_death = indi.death if indi else None
        prof_death = _profile_date(profile, "deathdate") if profile else None
        if tree_birth and prof_birth and tree_birth.as_date() != prof_birth.as_date():
            rep.date_disagreements.append(role + " birth")
        if tree_death and prof_death and tree_death.as_date() != prof_death.as_date():
            rep.date_disagreements.append(role + " death")
        sex = (indi.sex if indi and indi.sex else None) or (_profile_sex(profile) if profile else None)
        keys = set(_profile_keys(profile)) if profile else set()
        if indi and indi.given and not profile:
            keys.update(k.lower() for k in indi.given.split())
        birth = tree_birth or prof_birth
        if birth is None:
            rep.missing_birth.append(role)
        if sex is None:
            rep.missing_sex.append(role)
        if profile:
            used_profiles.add(profile.get("uuid"))
        members.append(Member(role, sex, birth, tree_death or prof_death, tuple(sorted(keys)),
                              (profile or {}).get("hairColor"), group))

    owner = indis.get(owner_xref)
    if owner is None:
        raise ValueError("owner not in the tree")
    owner_p = profile_for(owner)
    add("owner", "core", owner, owner_p)

    # spouse: the tree FAMS partner, else the People-tab spouse kinship (either direction)
    marriage = None
    spouse: Optional[Indi] = None
    for fx in owner.fams:
        fam = fams.get(fx)
        if fam:
            other = fam.wife if fam.husb == owner_xref else fam.husb
            if other in indis:
                spouse, marriage = indis[other], fam.marr
                rep.tree_children_listed += len(fam.chil)
                break
    spouse_p = profile_for(spouse)
    if spouse_p is None and owner_p is not None:
        ids = _kin(owner_p, "spouse") + [p["uuid"] for p in profiles if owner_p.get("uuid") in _kin(p, "spouse")]
        spouse_p = by_id.get(ids[0]) if ids else None
        spouse = spouse or (indi_for(spouse_p) if spouse_p else None)
    if spouse or spouse_p:
        add("spouse", "core", spouse, spouse_p)

    # children: People-tab "owner is parent of X" (or spouse is), birth order
    child_ids: List[str] = []
    for src in (owner_p, spouse_p):
        if src:
            child_ids += [i for i in _kin(src, "parent") if i not in child_ids]
    children = [by_id[i] for i in child_ids if i in by_id]
    children.sort(key=lambda p: (p.get("birthdate") is None, p.get("birthdate") or 0))
    for n, c in enumerate(children, 1):
        add("child {}".format(n), "core", indi_for(c), c)

    # parents: owner's from the tree FAMC (+ People "owner is child of"), spouse's from the tree
    def parents(person: Optional[Indi], person_p: Optional[Dict[str, Any]], label: str) -> None:
        father = mother = None
        if person:
            for fx in person.famc:
                fam = fams.get(fx)
                if fam:
                    father = indis.get(fam.husb) if fam.husb else None
                    mother = indis.get(fam.wife) if fam.wife else None
                    break
        prof_parents = [by_id[i] for i in (_kin(person_p, "child") if person_p else []) if i in by_id]
        for indi, sex, role in ((father, "M", label + " father"), (mother, "F", label + " mother")):
            prof = profile_for(indi) if indi else None
            if prof is None:
                prof = next((p for p in prof_parents if _profile_sex(p) == sex), None)
            if indi or prof:
                add(role, "core", indi, prof)

    parents(owner, owner_p, "owner's")
    parents(spouse, spouse_p, "spouse's")

    # owner's siblings (extended roster): People-tab "sibling" kinships, birth order
    sib_ids = _kin(owner_p, "sibling") if owner_p else []
    sibs = sorted((by_id[i] for i in sib_ids if i in by_id),
                  key=lambda p: (p.get("birthdate") is None, p.get("birthdate") or 0))
    for n, s in enumerate(sibs, 1):
        add("owner's sibling {}".format(n), "sibling", indi_for(s), s)

    rep.off_roster_keys = tuple(sorted({k for p in profiles if p.get("uuid") not in used_profiles
                                        for k in _profile_keys(p)}))
    return Household(tuple(members), marriage), rep


# ---------------------------------------------------------------------------------------------
# Truth set (catalog copy, read-only)
# ---------------------------------------------------------------------------------------------

@dataclasses.dataclass
class TruthFile:
    digest: str
    date: PartialDate
    source: str                 # "user_dates" | "camera"
    tags: List[str]             # confirmed People tag names (scratch only)


def open_ro(path: str) -> sqlite3.Connection:
    return sqlite3.connect("file:{}?mode=ro".format(path), uri=True)


def load_truth(conn: sqlite3.Connection) -> Tuple[List[TruthFile], Dict[str, Any]]:
    """Every digest with ≥1 confirmed People tag and a trusted date (Rick's first)."""
    tags: Dict[str, List[str]] = collections.defaultdict(list)
    for digest, name in conn.execute(
            "SELECT digest, name FROM people_tags WHERE kind = 'confirmed' ORDER BY digest, name"):
        tags[digest].append(name.strip())
    user = {d: v for d, v in conn.execute("SELECT digest, value FROM user_dates WHERE value IS NOT NULL")}
    camera: Dict[str, int] = {}
    for digest, codec, stamp in conn.execute(
            "SELECT content_digest, video_codec, embedded_created_at FROM files "
            "WHERE embedded_created_at IS NOT NULL ORDER BY content_digest, embedded_created_at"):
        if codec in CAMERA_NATIVE_CODECS and digest not in camera:
            camera[digest] = stamp
    machine = conn.execute("SELECT count(DISTINCT digest) FROM people_tags "
                           "WHERE kind IN ('detected','suspected')").fetchone()[0]
    out: List[TruthFile] = []
    report: Dict[str, Any] = {"tagged_files": len(tags), "user_dates_with_value": len(user),
                              "machine_tagged_files": machine, "camera_vs_rick": {"agree": 0, "disagree": 0}}
    for digest in sorted(tags):
        u = parse_user_date(user.get(digest, ""))
        if digest in camera and u is not None:
            year = dt.datetime.fromtimestamp(camera[digest], dt.timezone.utc).year
            report["camera_vs_rick"]["agree" if year == u.year else "disagree"] += 1
        if u is not None:
            out.append(TruthFile(digest, u, "user_dates", tags[digest]))
        elif digest in camera:
            d = dt.datetime.fromtimestamp(camera[digest], dt.timezone.utc).date()
            out.append(TruthFile(digest, PartialDate(d.year, d.month, d.day), "camera", tags[digest]))
    report["tagged_without_trusted_date"] = len(tags) - len(out)
    report["user_dated_without_tags"] = len([d for d in user if d not in tags])
    return out, report


# ---------------------------------------------------------------------------------------------
# Measurement
# ---------------------------------------------------------------------------------------------

def resolve_tag(h: Household, name: str, off_roster_keys: Iterable[str]) -> Tuple[str, Optional[Member]]:
    key = name.strip().lower()
    hits = [m for m in h.members if key in m.keys]
    if len(hits) == 1:
        return "resolved", hits[0]
    if len(hits) > 1:
        return "ambiguous_name", None
    return ("off_roster" if key in set(off_roster_keys) else "unresolved"), None


def _size_bucket(n: int) -> str:
    return "0" if n == 0 else ("1" if n == 1 else ("2" if n == 2 else "3+"))


def _roster_key(role: str) -> str:
    return role


def measure(h: Household, truth: Sequence[TruthFile], off_roster_keys: Sequence[str]) -> Dict[str, Any]:
    """Per tagged person: the candidate set for their true (sex, band), exact and ±WIDEN.
    Returns aggregates (roles + counts) and `detail` (per file — scratch only)."""
    agg: Dict[str, Any] = {
        "files": len(truth), "files_by_source": collections.Counter(t.source for t in truth),
        "tag_outcomes": collections.Counter(), "sizes": collections.Counter(),
        "sizes_widened": collections.Counter(), "by_decade": {}, "ambiguous": collections.Counter(),
        "ambiguous_widened": collections.Counter(), "hair_breaks": {"ties": 0, "broken": 0, "unknown": 0},
        "camera_top": collections.Counter(), "camera_empty": 0, "files_with_resolved": 0,
        "by_source_sizes": {"user_dates": collections.Counter(), "camera": collections.Counter()},
    }
    detail = []
    for t in truth:
        at = t.date.as_date()
        dec = decade_label(t.date.year)
        d = agg["by_decade"].setdefault(dec, {"tags": 0, "unambiguous": 0, "unambiguous_widened": 0, "files": 0})
        d["files"] += 1
        roles = []
        rec = {"digest": t.digest, "date": t.date.as_date().isoformat(), "source": t.source, "tags": []}
        for name in t.tags:
            outcome, m = resolve_tag(h, name, off_roster_keys)
            if m is not None and (m.birth is None or m.sex is None):
                outcome = "member_missing_facts"
            elif m is not None and m.birth.as_date() > at:
                outcome = "tagged_before_birth"
            elif m is not None and m.death is not None and at > m.death.as_date():
                outcome = "tagged_after_death"
            agg["tag_outcomes"][outcome] += 1
            rec["tags"].append({"name": name, "outcome": outcome, "role": m.role if m else None})
            if outcome != "resolved" or m is None:
                continue
            roles.append(m.role)
            age = age_years(m.birth.as_date(), at)   # type: ignore[union-attr]
            band = band_of(age)
            exact = candidates(h, at, m.sex, band)
            wide = candidates(h, at, m.sex, band, WIDEN_YEARS)
            agg["sizes"][_size_bucket(len(exact))] += 1
            agg["sizes_widened"][_size_bucket(len(wide))] += 1
            agg["by_source_sizes"][t.source][_size_bucket(len(exact))] += 1
            d["tags"] += 1
            d["unambiguous"] += len(exact) == 1
            d["unambiguous_widened"] += len(wide) == 1
            sex_word = {"M": "male", "F": "female"}.get(m.sex or "", "?")
            if len(exact) > 1:
                key = "{} | {} {} | {}".format(" + ".join(sorted(p.role for p in exact)), sex_word, band, dec)
                agg["ambiguous"][key] += 1
                hairs = [h.member(p.role).hair for p in exact]   # type: ignore[union-attr]
                if any(x is None for x in hairs):
                    agg["hair_breaks"]["unknown"] += 1
                else:
                    agg["hair_breaks"]["ties"] += 1
                    mine = m.hair
                    agg["hair_breaks"]["broken"] += sum(1 for x in hairs if x == mine) == 1
            if len(wide) > 1:
                key = "{} | {} {}±{} | {}".format(" + ".join(sorted(p.role for p in wide)), sex_word, band,
                                                  WIDEN_YEARS, dec)
                agg["ambiguous_widened"][key] += 1
            rec["tags"][-1].update(band=band, candidates=[p.role for p in exact],
                                   candidates_widened=[p.role for p in wide])
        if roles:
            agg["files_with_resolved"] += 1
            prior = camera_operator_prior(h, at, roles)
            rec["camera_prior"] = [r for r, _ in prior]
            if prior:
                agg["camera_top"][prior[0][0]] += 1
            else:
                agg["camera_empty"] += 1
        detail.append(rec)
    return {"aggregate": _plain(agg), "detail": detail}


def year_sweep(h: Household, first: int, last: int) -> Dict[str, Any]:
    """Structural answer independent of the tiny truth set: every alive roster member on 1 July
    of every year, how big is the (sex, band) candidate set?"""
    sizes = collections.Counter()
    sizes_w = collections.Counter()
    by_dec: Dict[str, collections.Counter] = {}
    hard = collections.Counter()
    for year in range(first, last + 1):
        at = dt.date(year, 7, 1)
        for p in roster(h, at):
            if not p.alive or p.sex is None:
                continue
            band = band_of(p.age_years)
            n = len(candidates(h, at, p.sex, band))
            nw = len(candidates(h, at, p.sex, band, WIDEN_YEARS))
            sizes[_size_bucket(n)] += 1
            sizes_w[_size_bucket(nw)] += 1
            by_dec.setdefault(decade_label(year), collections.Counter())["1" if n == 1 else "many"] += 1
            if n > 1:
                roles = " + ".join(sorted(q.role for q in candidates(h, at, p.sex, band)))
                hard["{} | {}".format(roles, {"M": "male", "F": "female"}[p.sex])] += 1
    return _plain({"first": first, "last": last, "sizes": sizes, "sizes_widened": sizes_w,
                   "by_decade": by_dec, "hard": hard})


def _plain(x: Any) -> Any:
    if isinstance(x, collections.Counter):
        return dict(sorted(x.items()))
    if isinstance(x, dict):
        return {k: _plain(v) for k, v in x.items()}
    if isinstance(x, list):
        return [_plain(v) for v in x]
    return x


# ---------------------------------------------------------------------------------------------
# Markdown (aggregate only)
# ---------------------------------------------------------------------------------------------

def _pct(n: int, d: int) -> str:
    return "—" if d == 0 else "{:.0f}%".format(100.0 * n / d)


def _sizes_row(label: str, sizes: Dict[str, int]) -> str:
    total = sum(sizes.values())
    return "| {} | {} | {} | {} | {} | {} |".format(label, total, sizes.get("1", 0), sizes.get("2", 0),
                                                     sizes.get("3+", 0), _pct(sizes.get("1", 0), total))


def render_markdown(results: Dict[str, Any]) -> str:
    L: List[str] = []
    load = results["load"]
    truth = results["truth_report"]
    L += ["# Household Roster (A7) — feasibility, no model",
          "",
          "Generated by `tools/household-roster/roster.py` from a read-only `.backup` copy of the catalog, "
          "the GEDCOM tree and the People-tab profiles. Roles and counts only — no names, dates, paths "
          "or digests. Per-file detail stays in `.scratch/roster/`.",
          "",
          "## Rules", ""]
    L += ["{}. {}".format(i, r) for i, r in enumerate(RULES_TEXT, 1)]
    L += ["", "## Inputs", "",
          "| | count |", "|---|---|",
          "| roster members (core / extended) | {} / {} |".format(load["core_members"], load["all_members"]),
          "| files with an owner-confirmed People tag | {} |".format(truth["tagged_files"]),
          "| … of which with a trusted date (truth set) | {} (owner-dated {}, camera-dated {}) |".format(
              results["core"]["aggregate"]["files"], results["core"]["aggregate"]["files_by_source"].get("user_dates", 0),
              results["core"]["aggregate"]["files_by_source"].get("camera", 0)),
          "| files with an owner-confirmed date but no confirmed tag | {} |".format(truth["user_dated_without_tags"]),
          "| tagged files with no trusted date (excluded) | {} |".format(truth["tagged_without_trusted_date"]),
          "| files with machine-only (detected/suspected) tags — not truth | {} |".format(truth["machine_tagged_files"]),
          "| camera stamp vs the owner's year, where both exist (agree / disagree) | {} / {} |".format(
              truth["camera_vs_rick"]["agree"], truth["camera_vs_rick"]["disagree"]),
          ""]
    for variant, title in (("core", "Core roster (owner, spouse, children, both sets of parents)"),
                           ("extended", "Extended roster (core + owner's siblings)")):
        a = results[variant]["aggregate"]
        L += ["## Truth set — {}".format(title), "",
              "Tag outcomes: " + ", ".join("{} {}".format(k.replace("_", " "), v)
                                           for k, v in sorted(a["tag_outcomes"].items())) + ".", "",
              "| candidate-set size | tags | 1 | 2 | 3+ | unambiguous |", "|---|---|---|---|---|---|",
              _sizes_row("exact band", a["sizes"]), _sizes_row("band ±{} y".format(WIDEN_YEARS), a["sizes_widened"]),
              _sizes_row("… owner-dated files only", a["by_source_sizes"]["user_dates"]),
              _sizes_row("… camera-dated files only", a["by_source_sizes"]["camera"]), "",
              "| decade | files | resolved tags | unambiguous | unambiguous ±{} y |".format(WIDEN_YEARS),
              "|---|---|---|---|---|"]
        for dec, d in sorted(a["by_decade"].items()):
            L.append("| {} | {} | {} | {} | {} |".format(dec, d["files"], d["tags"],
                                                        _pct(d["unambiguous"], d["tags"]),
                                                        _pct(d["unambiguous_widened"], d["tags"])))
        L += ["", "Ambiguous (exact band) by candidate roles · sex band · decade:", ""]
        L += ["- {} — {} tag(s)".format(k, v) for k, v in sorted(a["ambiguous"].items())] or ["- none"]
        L += ["", "Ambiguous with the band widened ±{} y:".format(WIDEN_YEARS), ""]
        L += ["- {} — {} tag(s)".format(k, v) for k, v in sorted(a["ambiguous_widened"].items())] or ["- none"]
        hb = a["hair_breaks"]
        L += ["", "Hair colour (People-tab) among the exact-band ties: {} tie(s) checkable, {} broken by hair alone, "
              "{} with a member's hair unknown.".format(hb["ties"], hb["broken"], hb["unknown"]), "",
              "Camera-operator prior over {} file(s) with a resolved tag: top-ranked ".format(a["files_with_resolved"])
              + (", ".join("{} {}".format(k, v) for k, v in sorted(a["camera_top"].items())) or "none")
              + "; empty (every household adult in frame, or none adult) {}. Owner named first in {}.".format(
                  a["camera_empty"], _pct(a["camera_top"].get("owner", 0), a["files_with_resolved"])), ""]
    for key, label in (("sweep_core", "core"), ("sweep", "extended")):
        if key in results:
            L += _sweep_section(results[key], label)
    L += _missing_and_verdict(results, load)
    return "\n".join(L)


def _sweep_section(s: Dict[str, Any], label: str) -> List[str]:
    L: List[str] = []
    L += ["## Structural sweep ({} roster) — every alive member, 1 July of every year {}–{}".format(
          label, s["first"], s["last"]), "",
          "Independent of which files happen to be tagged: if a model reported this person's true sex "
          "and band, how many roster members would match?", "",
          "| | person-years | 1 | 2 | 3+ | unambiguous |", "|---|---|---|---|---|---|",
          _sizes_row("exact band", s["sizes"]), _sizes_row("band ±{} y".format(WIDEN_YEARS), s["sizes_widened"]), "",
          "| decade | person-years | unambiguous |", "|---|---|---|"]
    for dec, c in sorted(s["by_decade"].items()):
        tot = c.get("1", 0) + c.get("many", 0)
        L.append("| {} | {} | {} |".format(dec, tot, _pct(c.get("1", 0), tot)))
    L += ["", "Hard cases (person-years in a tie, all bands and decades), by roles · sex:", ""]
    L += ["- {} — {}".format(k, v) for k, v in sorted(s["hard"].items())] or ["- none"]
    L.append("")
    return L


def _missing_and_verdict(results: Dict[str, Any], load: Dict[str, Any]) -> List[str]:
    L: List[str] = []
    L += ["## Missing from the data", "",
          "- Roster members with no birth date: {} ({}).".format(len(load["missing_birth"]),
                                                                ", ".join(load["missing_birth"]) or "none"),
          "- Roster members with no sex: {}.".format(len(load["missing_sex"])),
          "- Tree vs People-tab date disagreements: {} ({}).".format(len(load["date_disagreements"]),
                                                                    ", ".join(load["date_disagreements"]) or "none"),
          "- Children listed under the owner's marriage in the GEDCOM: {} (living people are not in the "
          "exported tree; children come from People-tab kinships).".format(load["tree_children_listed"]),
          "- Owner's siblings on the People tab: {}.".format(load["siblings"]), ""]
    L += ["## Verdict", ""] + ["- " + v for v in results.get("verdict", [])] + [""]
    return L


def privacy_violations(text: str, forbidden: Iterable[str]) -> List[str]:
    """Any forbidden token (names, digests) present as a whole word, or anything path-like."""
    bad = []
    low = text.lower()
    for tok in forbidden:
        t = tok.strip().lower()
        if len(t) >= 3 and re.search(r"(?<![a-z0-9]){}(?![a-z0-9])".format(re.escape(t)), low):
            bad.append(tok)
    if re.search(r"/(Users|Volumes)/", text):
        bad.append("<path>")
    if re.search(r"\b[0-9a-f]{40,64}\b", text):
        bad.append("<digest>")
    return bad


# ---------------------------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------------------------

def run_measure(catalog: str, gedcom: str, poi: str, cyberbrain: str, owner_xref: Optional[str]) -> Dict[str, Any]:
    with open(gedcom, encoding="utf-8-sig", errors="replace") as f:
        indis, fams = parse_gedcom(f.read())
    profiles = load_profiles(poi)
    with open(cyberbrain, encoding="utf-8") as f:
        cb = json.load(f)
    owner = owner_xref or owner_xref_from_cyberbrain(cb)
    if not owner:
        raise SystemExit("no owner: pass --owner-xref")
    household, rep = build_household(indis, fams, profiles, owner)
    conn = open_ro(catalog)
    try:
        truth, truth_rep = load_truth(conn)
    finally:
        conn.close()
    core = household.restricted(["core"])
    off = list(rep.off_roster_keys)
    # the core roster must not resolve sibling tags, but they are not "unknown" either
    sib_keys = [k for m in household.members if m.group == "sibling" for k in m.keys]
    results = {
        "load": {"core_members": len(core.members), "all_members": len(household.members),
                 "missing_birth": rep.missing_birth, "missing_sex": rep.missing_sex,
                 "date_disagreements": rep.date_disagreements, "tree_children_listed": rep.tree_children_listed,
                 "siblings": sum(m.group == "sibling" for m in household.members)},
        "truth_report": truth_rep,
        "core": measure(core, truth, off + sib_keys),
        "extended": measure(household, truth, off),
        "sweep": year_sweep(household, 1955, dt.date.today().year),
        "sweep_core": year_sweep(core, 1955, dt.date.today().year),
        "forbidden": sorted({k for m in household.members for k in m.keys} | set(off)
                            | {t for tf in truth for t in tf.tags} | {tf.digest for tf in truth}),
    }
    return results


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("measure")
    m.add_argument("--catalog", required=True)
    m.add_argument("--gedcom", required=True)
    m.add_argument("--poi", required=True)
    m.add_argument("--cyberbrain", required=True)
    m.add_argument("--owner-xref")
    m.add_argument("--out", required=True)
    s = sub.add_parser("summarize")
    s.add_argument("--results", required=True)
    s.add_argument("--md", required=True)
    s.add_argument("--verdict", action="append", default=[], help="one verdict line (repeatable)")
    args = ap.parse_args(argv)
    if args.cmd == "measure":
        results = run_measure(args.catalog, args.gedcom, args.poi, args.cyberbrain, args.owner_xref)
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(results, f, indent=1, sort_keys=True, default=str)
        a = results["extended"]["aggregate"]
        print("truth files {} · resolved tags {} · unambiguous {}".format(
            a["files"], sum(a["sizes"].values()), a["sizes"].get("1", 0)))
        return 0
    with open(args.results, encoding="utf-8") as f:
        results = json.load(f)
    results["verdict"] = args.verdict or results.get("verdict", [])
    text = render_markdown(results)
    bad = privacy_violations(text, results.get("forbidden", []))
    if bad:
        print("refusing to write: {} forbidden token(s) in the markdown".format(len(bad)), file=sys.stderr)
        return 2
    with open(args.md, "w", encoding="utf-8") as f:
        f.write(text)
    print("wrote {} ({} lines)".format(args.md, text.count("\n") + 1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
