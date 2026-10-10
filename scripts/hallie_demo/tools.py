#!/usr/bin/env python3
"""Read-only family-archive tools for the Hallie "take two" blind demo.

    python tools.py [--snapshots DIR] [--redact-media-text] <tool> [args]

Args are `key=value` words; a bare word (or several) fills the tool's main
argument (name / id / query). Every result is JSON on stdout with stable ids
for citation:

    gedcom:@I1@        a person in the family tree (GEDCOM)
    gedcom:@F1@        a family (couple + children) in the tree
    people:<uuid>      a People-tab profile
    family:<uuid>      a People-tab family group
    brain:<id>         a CyberBrain person or item (biography, note, event)
    catalog:<uuid>     a catalog record (one media file)
    q:<hash>           this query's own result (cite it for counts)

Tools: resolve_person, person_facts, relatives, relationship_between,
family_knowledge, search_media, catalog_stats. See README.md.

Nothing here writes anything. The snapshots are produced by snapshot.py.
"""
from __future__ import annotations

import collections
import hashlib
import json
import os
import re
import sys

DEFAULT_SNAPSHOTS = ("/private/tmp/claude-501/-Users-rickb-dev-VideoScan/"
                     "8562e4d1-ff42-4e46-b1b8-94e04b855380/scratchpad/hallie_demo/snapshots")
MAX_ITEMS = 25
MAX_CANDIDATES = 8
REDACTED = "[redacted: text derived from media]"


# ====================================================================== text

def norm(s: str | None) -> str:
    s = (s or "").lower().replace("’", "").replace("'", "")
    return " ".join(re.findall(r"[a-z0-9]+", s))


def toks(s: str | None) -> list[str]:
    return norm(s).split()


ABOUT_WORDS = ("about", "abt", "circa", "cir", "ca", "c", "est", "estimated", "environ", "um", "approx")
AFTER_WORDS = ("after", "aft")
BEFORE_WORDS = ("before", "bef")
RANGE_WORDS = ("between", "bet", "from", "or")


def date_range(date: str | None, fallback_year: int | None = None) -> dict:
    """A GEDCOM date as {qualifier, earliest, latest, text}.

    "after 1930 before 1950" is a RANGE, never the year 1930 (the demo
    printed "1877–1930" for a death the tree only bounds). qualifier is one
    of exact | about | after | before | between | unknown; earliest/latest
    are years or None for an open end. `text` is how to say it.
    """
    s = (date or "").lower()
    ys = [int(y) for y in re.findall(r"(?<!\d)(\d{3,4})(?!\d)", s)]
    if not ys and fallback_year:
        ys = [fallback_year]
    if not ys:
        return {"qualifier": "unknown", "earliest": None, "latest": None, "text": date or ""}
    words = set(re.findall(r"[a-z]+", s))
    has = lambda vocab: bool(words & set(vocab))  # noqa: E731
    if len(ys) >= 2 and (has(RANGE_WORDS) or (has(AFTER_WORDS) and has(BEFORE_WORDS)) or " to " in s):
        lo, hi = min(ys), max(ys)
        return {"qualifier": "between", "earliest": lo, "latest": hi, "text": f"between {lo} and {hi}"}
    y = ys[0]
    if has(AFTER_WORDS):
        return {"qualifier": "after", "earliest": y, "latest": None, "text": f"after {y}"}
    if has(BEFORE_WORDS):
        return {"qualifier": "before", "earliest": None, "latest": y, "text": f"before {y}"}
    if has(ABOUT_WORDS):
        return {"qualifier": "about", "earliest": y, "latest": y, "text": f"about {y}"}
    return {"qualifier": "exact", "earliest": y, "latest": y, "text": str(y)}


def event_view(ev: dict | None) -> dict | None:
    """A birth/death event with its qualifier carried through. `year` stays
    only when the tree gives one year (exact or about); bounded dates carry
    `range` [earliest, latest] instead, so nothing can flatten them."""
    if not ev:
        return None
    r = date_range(ev.get("date"), ev.get("year"))
    out = {k: v for k, v in ev.items() if k != "year"}
    out["qualifier"] = r["qualifier"]
    out["yearText"] = r["text"]
    if r["qualifier"] in ("exact", "about"):
        out["year"] = r["earliest"]
    elif r["qualifier"] != "unknown":
        out["range"] = [r["earliest"], r["latest"]]
    return out


def years(birth: dict | None, death: dict | None) -> str:
    b = date_range((birth or {}).get("date"), (birth or {}).get("year")) if birth else None
    d = date_range((death or {}).get("date"), (death or {}).get("year")) if death else None
    b = b if b and b["qualifier"] != "unknown" else None
    d = d if d and d["qualifier"] != "unknown" else None
    if b and d:
        if b["qualifier"] == "exact" and d["qualifier"] == "exact":
            return f"{b['text']}–{d['text']}"
        return f"b. {b['text']}; d. {d['text']}"
    if b:
        return f"b. {b['text']}"
    if d:
        return f"d. {d['text']}"
    return ""


def edit_distance(a: str, b: str, cap: int = 3) -> int:
    if abs(len(a) - len(b)) > cap:
        return cap + 1
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def snippet(text: str, term: str, width: int = 90) -> str | None:
    i = text.lower().find(term.lower())
    if i < 0:
        return None
    a, b = max(0, i - width), min(len(text), i + len(term) + width)
    return ("…" if a else "") + text[a:b].replace("\n", " ") + ("…" if b < len(text) else "")


# ====================================================================== data

class Data:
    """Snapshot + indexes. Loaded lazily per need (the tree is ~18 MB)."""

    def __init__(self, root: str, redact: bool = False):
        self.root = root
        self.redact = redact
        self._tree = self._people = self._brain = self._catalog = None

    def _load(self, name):
        with open(os.path.join(self.root, name), encoding="utf-8") as fh:
            return json.load(fh)

    # ---- tree
    @property
    def tree(self):
        if self._tree is None:
            self._tree = self._load("tree.json")
            self.P = self._tree["people"]
            self.F = self._tree["families"]
            self.owner = self._tree.get("owner")
            self.by_fsid = {p["fsid"]: pid for pid, p in self.P.items() if p.get("fsid")}
        return self._tree

    def tp(self, pid):
        self.tree
        return self.P.get(pid)

    def name(self, pid):
        p = self.tp(pid)
        return p["names"][0]["full"] if p and p["names"] else pid

    def parents(self, pid):
        out = []
        for f in self.tp(pid).get("famc", []):
            fam = self.F.get(f) or {}
            out += [x for x in (fam.get("husb"), fam.get("wife")) if x]
        return list(dict.fromkeys(out))

    def children(self, pid):
        out = []
        for f in self.tp(pid).get("fams", []):
            out += (self.F.get(f) or {}).get("children", [])
        return list(dict.fromkeys(out))

    def spouses(self, pid):
        out = []
        for f in self.tp(pid).get("fams", []):
            fam = self.F.get(f) or {}
            for x in (fam.get("husb"), fam.get("wife")):
                if x and x != pid:
                    out.append((x, f))
        return out

    def siblings(self, pid):
        out = []
        for f in self.tp(pid).get("famc", []):
            out += [c for c in (self.F.get(f) or {}).get("children", []) if c != pid]
        return list(dict.fromkeys(out))

    def brief(self, pid, **extra):
        p = self.tp(pid)
        d = {"id": f"gedcom:{pid}", "name": self.name(pid), "years": years(p.get("birth"), p.get("death")),
             "sex": p.get("sex")}
        dup = (p.get("identityDecision") or {}).get("duplicateOf")
        if dup:
            d["duplicateOf"] = f"FamilySearch {dup} (family identity decision: ignore this record)"
        d.update(extra)
        return d

    # ---- people / brain / catalog
    @property
    def people(self):
        if self._people is None:
            self._people = self._load("people.json")
            self.profiles = {p["uuid"]: p for p in self._people["profiles"]}
            self.groups = {g["uuid"]: g for g in self._people["families"]}
        return self._people

    @property
    def brain(self):
        if self._brain is None:
            self._brain = self._load("brain.json")
            self.bpeople = {p["id"]: p for p in self._brain["people"]}
            self.bitems = {i["id"]: i for i in self._brain["items"]}
            self.bsources = {s["id"]: s for s in self._brain["sources"]}
        return self._brain

    @property
    def catalog(self):
        if self._catalog is None:
            self._catalog = self._load("catalog.json")
        return self._catalog

    # ---- cross-links between the three people stores
    def links(self):
        if getattr(self, "_links", None) is not None:
            return self._links
        self.tree, self.people, self.brain
        prof_tree, brain_tree, brain_prof = {}, {}, {}
        for u, p in self.profiles.items():
            fsid = p.get("familySearchID")
            if fsid and fsid in self.by_fsid:
                prof_tree[u] = self.by_fsid[fsid]
            elif "tree root" in (p.get("treeIdentityAttestation") or "") and \
                    norm(p.get("name"))[:4] == norm(self.name(self.owner))[:4]:
                prof_tree[u] = self.owner
        full_index = collections.defaultdict(set)
        for pid, p in self.P.items():
            for n in p["names"]:
                full_index[norm(n["full"])].add(pid)
                full_index[norm(f'{n["given"]} {n["surname"]}')].add(pid)
        for bid, b in self.bpeople.items():
            g = (b.get("gedcomPersonID") or "")
            cand = None
            if g in self.P and set(toks(b["canonicalName"])) & set(toks(self.name(g)) + toks(" ".join(n["full"] for n in self.P[g]["names"]))):
                cand = g
            if not cand:
                for n in [b["canonicalName"]] + b.get("aliases", []):
                    hits = full_index.get(norm(n), set())
                    if len(hits) == 1:
                        cand = next(iter(hits))
                        break
            if cand:
                brain_tree[bid] = cand
            names = {norm(x) for x in [b["canonicalName"]] + b.get("aliases", [])}
            hits = [u for u, p in self.profiles.items() if names & self.profile_names(p)]
            if cand:
                hits += [u for u, t in prof_tree.items() if t == cand]
            hits = list(dict.fromkeys(hits))
            if len(hits) == 1:
                brain_prof[bid] = hits[0]
        self._links = {"prof_tree": prof_tree, "brain_tree": brain_tree, "brain_prof": brain_prof}
        return self._links

    def profile_names(self, p):
        names = {norm(p.get("name")), norm(f'{p.get("name")} {p.get("surname", "")}'),
                 norm(f'{p.get("name")} {p.get("middleName", "")} {p.get("surname", "")}')}
        if p.get("maidenName"):
            names.add(norm(f'{p.get("name")} {p["maidenName"]}'))
        names |= {norm(a) for a in p.get("aliases") or []}
        names.discard("")
        return names

    def same_as(self, eid):
        """All ids that denote the same person as `eid`."""
        L = self.links()
        kind, _, raw = eid.partition(":")
        tree = prof = None
        brains = []
        if kind == "gedcom":
            tree = raw
        elif kind == "people":
            prof = raw
            tree = L["prof_tree"].get(raw)
        elif kind == "brain":
            brains = [raw]
            tree = L["brain_tree"].get(raw)
            prof = L["brain_prof"].get(raw)
        if tree and not prof:
            prof = next((u for u, t in L["prof_tree"].items() if t == tree), None)
        if tree:
            brains += [b for b, t in L["brain_tree"].items() if t == tree]
        if prof:
            brains += [b for b, u in L["brain_prof"].items() if u == prof]
        ids = []
        if tree:
            ids.append(f"gedcom:{tree}")
        if prof:
            ids.append(f"people:{prof}")
        ids += [f"brain:{b}" for b in dict.fromkeys(brains)]
        return ids or [eid]


# ====================================================================== result

def result(tool, args, items, *, truncated=False, extra=None, ids=None):
    qid = "q-" + hashlib.sha1(json.dumps([tool, args], sort_keys=True).encode()).hexdigest()[:8]
    out = {"ok": True, "tool": tool, "args": args, "queryID": f"q:{qid}"}
    if extra:
        out.update(extra)
    out["items"] = items
    out["truncated"] = truncated
    if ids is None:
        ids = []
        for it in items if isinstance(items, list) else [items]:
            if isinstance(it, dict) and isinstance(it.get("id"), str):
                ids.append(it["id"])
            if isinstance(it, dict):
                ids += [x for x in it.get("pathIDs", []) if isinstance(x, str)]
    out["ids"] = list(dict.fromkeys(ids + [f"q:{qid}"]))
    return out


def fail(tool, error, detail):
    return {"ok": False, "tool": tool, "error": error, "detail": detail}


# ====================================================================== kin words

KIN = {
    "father": ("parent", "M"), "dad": ("parent", "M"), "daddy": ("parent", "M"), "pop": ("parent", "M"),
    "pa": ("parent", "M"),
    "mother": ("parent", "F"), "mom": ("parent", "F"), "ma": ("parent", "F"), "mum": ("parent", "F"),
    "mommy": ("parent", "F"), "mama": ("parent", "F"),
    "parents": ("parent", None), "parent": ("parent", None),
    "grandmother": ("grandparent", "F"), "grandma": ("grandparent", "F"), "gramma": ("grandparent", "F"),
    "grammy": ("grandparent", "F"), "nana": ("grandparent", "F"), "nanna": ("grandparent", "F"),
    "nan": ("grandparent", "F"), "granny": ("grandparent", "F"), "memere": ("grandparent", "F"),
    "grandfather": ("grandparent", "M"), "grandpa": ("grandparent", "M"), "grampa": ("grandparent", "M"),
    "granddad": ("grandparent", "M"), "grandad": ("grandparent", "M"), "pepere": ("grandparent", "M"),
    "grandparents": ("grandparent", None),
    "wife": ("spouse", "F"), "husband": ("spouse", "M"), "spouse": ("spouse", None),
    "son": ("child", "M"), "sons": ("child", "M"), "daughter": ("child", "F"), "daughters": ("child", "F"),
    "kids": ("child", None), "children": ("child", None), "child": ("child", None),
    "brother": ("sibling", "M"), "brothers": ("sibling", "M"), "sister": ("sibling", "F"),
    "sisters": ("sibling", "F"), "siblings": ("sibling", None),
    "uncle": ("auntuncle", "M"), "aunt": ("auntuncle", "F"), "auntie": ("auntuncle", "F"),
    "grandson": ("grandchild", "M"), "granddaughter": ("grandchild", "F"), "grandkids": ("grandchild", None),
    "grandchildren": ("grandchild", None),
}
OWNER_WORDS = {"me", "i", "myself", "owner"}
MATERNAL = {"maternal", "mothers", "moms", "mas", "mother", "mom"}
PATERNAL = {"paternal", "fathers", "dads", "father", "dad"}
PROFILE_REL = {"parent": "child", "child": "parent", "sibling": "sibling", "spouse": "spouse",
               "grandparent": "grandchild", "grandchild": "grandparent"}


def profile_edges(D):
    """(a, rel, b) meaning: b is a's <rel>, from People-tab kinship rows."""
    D.people
    edges = set()
    for u, p in D.profiles.items():
        for k in p.get("kinships", []):
            r, to = k.get("relation"), k.get("to")
            if not to or r not in PROFILE_REL:
                continue
            # row on u says: u is <r> of `to`  ->  `to` is u's PROFILE_REL[r]
            edges.add((u, PROFILE_REL[r], to))
            edges.add((to, r, u))
    return edges


def tree_kin(D, pid, rel, sex, side, greats=0):
    """[(tree id, path note)] for owner-relative kin in the tree."""
    out = []
    if rel == "parent":
        out = [(x, "parent") for x in D.parents(pid)
               if not side or (D.tp(x) or {}).get("sex") == ("F" if side == "maternal" else "M")]
    elif rel in ("grandparent",):
        gen = 2 + greats
        frontier = [(pid, [])]
        for g in range(gen):
            nxt = []
            for x, path in frontier:
                for par in D.parents(x):
                    if g == 0 and side:
                        s = (D.tp(par) or {}).get("sex")
                        if (side == "maternal" and s != "F") or (side == "paternal" and s != "M"):
                            continue
                    nxt.append((par, path + [par]))
            frontier = nxt
        out = [(x, ("maternal " if side == "maternal" else "paternal " if side == "paternal" else "") +
                ("great-" * greats) + "grandparent via " + " → ".join(D.name(y) for y in path))
               for x, path in frontier]
    elif rel == "spouse":
        out = [(x, "spouse") for x, _ in D.spouses(pid)]
    elif rel == "child":
        out = [(x, "child") for x in D.children(pid)]
    elif rel == "sibling":
        out = [(x, "sibling") for x in D.siblings(pid)]
    elif rel == "grandchild":
        out = [(g, "grandchild") for c in D.children(pid) for g in D.children(c)]
    elif rel == "auntuncle":
        for par in D.parents(pid):
            s = (D.tp(par) or {}).get("sex")
            if side and ((side == "maternal" and s != "F") or (side == "paternal" and s != "M")):
                continue
            out += [(x, f"sibling of {D.name(par)}") for x in D.siblings(par)]
    if sex:
        out = [(x, n) for x, n in out if (D.tp(x) or {}).get("sex") == sex]
    return out


# ====================================================================== tools

def t_resolve_person(D, a):
    q = a.get("name") or ""
    t = toks(q)
    if t and t[0] == "my":
        t = t[1:]
    if t and t[-1] == "s" and len(t) > 1:
        t = t[:-1]
    qn = " ".join(t)
    if not qn:
        return fail("resolve_person", "badArgs", "name is required")
    D.tree, D.people, D.brain
    L = D.links()
    cands: dict[str, dict] = {}
    order = []

    def add(eid, kind, reason, rank):
        ids = D.same_as(eid)
        key = ids[0]
        c = cands.get(key)
        if c is None:
            c = {"id": key, "sameAs": ids[1:], "kinds": [], "reasons": [], "rank": rank}
            cands[key] = c
            order.append(key)
        if kind not in c["kinds"]:
            c["kinds"].append(kind)
        if reason not in c["reasons"]:
            c["reasons"].append(reason)
        c["rank"] = min(c["rank"], rank)

    notes = []
    owner = D.owner
    owner_prof = next((u for u, tr in L["prof_tree"].items() if tr == owner), None)

    # 1. owner words
    if qn in OWNER_WORDS:
        add(f"gedcom:{owner}", "owner", "the archive owner (pinned by FamilySearch id)", 0)

    # 2. kin words relative to the owner
    side = None
    rest = []
    greats = 0
    kin = None
    def near(w, vocab, d):
        if len(w) < 5 or w in vocab:
            return w
        hits = [v for v in vocab if len(v) >= 5 and edit_distance(w, v) <= d]
        return hits[0] if len(hits) == 1 else w
    t = [near(near(w, {"maternal", "paternal"}, 2), KIN, 1) for w in t]
    for w in t:
        if w in MATERNAL and kin is None and w not in KIN:
            side = "maternal"
        elif w in PATERNAL and kin is None and w not in KIN:
            side = "paternal"
        elif w in ("great", "greatgreat") and kin is None:
            greats += 2 if w == "greatgreat" else 1
        elif w in KIN and kin is None:
            kin = KIN[w]
        elif w in ("side", "the", "on", "of", "my"):
            continue
        else:
            rest.append(w)
    if kin is None and side and not rest:
        # "dad's side" / "mom's side": start at that parent
        kin = ("parent", "F" if side == "maternal" else "M")
        side = None
    if kin and owner:
        rel, sex = kin
        found = tree_kin(D, owner, rel, sex, side, greats if rel == "grandparent" else 0)
        for x, note in found:
            fam_names = set(toks(D.name(x)))
            for sp, _ in D.spouses(x):
                fam_names |= set(toks(D.name(sp)))
            for n in D.tp(x)["names"]:
                fam_names |= set(toks(n["full"]))
            if rest and not set(rest) <= fam_names:
                continue
            add(f"gedcom:{x}", "kinTerm", f"owner's {note} (family tree)", 1)
        if owner_prof and greats == 0 and rel in PROFILE_REL:
            for a_, r, b_ in profile_edges(D):
                if a_ == owner_prof and r == rel:
                    p = D.profiles[b_]
                    if sex and (p.get("sex") or "")[:1].upper() != sex:
                        continue
                    if rest and not set(rest) <= set(toks(" ".join(D.profile_names(p)) + " " + (p.get("surname") or ""))):
                        continue
                    add(f"people:{b_}", "kinTerm", f"owner's {rel} (People tab kinship row)", 1)
        notes.append(f"'{q}' read as a kin word relative to the owner ({D.name(owner)})")

    # 3. People tab names and aliases
    for u, p in D.profiles.items():
        names = D.profile_names(p)
        if qn in names:
            add(f"people:{u}", "profile", f"People tab name/alias match ({', '.join(p.get('aliases') or [])})", 2)
        elif len(t) == 1 and any(n.split()[0] == qn for n in names if n):
            add(f"people:{u}", "profile", "People tab first-name match", 3)

    # 4. CyberBrain names and aliases
    for bid, b in D.bpeople.items():
        names = [norm(x) for x in [b["canonicalName"]] + b.get("aliases", [])]
        if qn in names:
            add(f"brain:{bid}", "brain", "CyberBrain name/alias match", 2)
        elif len(t) == 1 and any(n.split() and n.split()[0] == qn for n in names):
            add(f"brain:{bid}", "brain", "CyberBrain first-name match", 3)

    # 5. family tree names
    suffixes = {"sr", "jr", "ii", "iii", "iv"}
    qcore = [w for w in t if w not in suffixes]
    qsuf = {w for w in t if w in suffixes}
    exact, given_hits = [], []
    for pid, p in D.P.items():
        for n in p["names"]:
            full, gs = norm(n["full"]), norm(f'{n["given"]} {n["surname"]}')
            gt = toks(n["given"])
            st = [w for w in toks(n["surname"]) if w not in suffixes]
            nsuf = {w for w in toks(n["surname"] + " " + n["suffix"]) if w in suffixes}
            two = (len(qcore) >= 2 and bool(gt) and gt[0] == qcore[0] and st[-1:] == qcore[-1:]
                   and qsuf <= nsuf)
            if qn in (full, gs) or two:
                exact.append(pid)
                break
            if len(t) == 1 and gt and gt[0] == qn:
                given_hits.append(pid)
                break
    exact = list(dict.fromkeys(exact))
    if not exact and len(t) >= 2 and not cands:
        # typo-tolerant last rung: same surname, first given name one edit away
        for pid, p in D.P.items():
            for n in p["names"]:
                gt, st = toks(n["given"]), toks(n["surname"])
                if gt and st and st[-1] == t[-1] and edit_distance(gt[0], t[0]) <= 1:
                    exact.append(pid)
                    break
        if exact:
            notes.append(f"no exact name match; {len(exact)} near spelling(s) of the first name with the same surname")
    for pid in exact[:MAX_CANDIDATES]:
        add(f"gedcom:{pid}", "tree", "family tree name match", 4)
    if len(exact) > MAX_CANDIDATES:
        notes.append(f"{len(exact)} family-tree people match the full name; showing {MAX_CANDIDATES}")
    if given_hits and not cands:
        notes.append(f"{len(given_hits)} family-tree people have the first name '{q}'; "
                     "too many to guess — add a surname, birth year or relationship")
        # nearest to the owner first: born closest to 1930-1990, then by year
        given_hits.sort(key=lambda x: -((D.tp(x).get("birth") or {}).get("year") or 0))
        for pid in given_hits[:3]:
            add(f"gedcom:{pid}", "treeFirstName", "family tree first-name match only", 6)

    # 6. names mentioned in told notes (not resolved people) — only when
    #    nothing above resolved; a capitalised whole word ("Ma" never hits "MA").
    if len(t) == 1 and not any(c["rank"] <= 4 for c in cands.values()):
        cap = q.strip()[:1].upper() + q.strip()[1:].lower()
        word = re.compile(r"\b" + re.escape(cap) + r"\b")
        mentions = []
        for u, p in D.profiles.items():
            for fld in ("notes", "identityNotes"):
                s = p.get(fld) or ""
                if word.search(s):
                    mentions.append({"id": f"people:{u}#{fld}", "about": f"people:{u}",
                                     "snippet": snippet(s, q.strip(), 120)})
        for iid, it in D.bitems.items():
            if word.search(it.get("text") or ""):
                mentions.append({"id": f"brain:{iid}", "about": ",".join(f"brain:{s}" for s in it.get("subjectPersonIDs") or []),
                                 "snippet": snippet(it["text"], q.strip(), 120)})
        if mentions:
            for m in mentions[:4]:
                c = {"id": m["id"], "kinds": ["mention"], "rank": 5,
                     "reasons": ["name appears inside a note; not a resolved person record"],
                     "snippet": m["snippet"], "noteAbout": m["about"]}
                cands[m["id"]] = c
                order.append(m["id"])

    # 7. people tags on catalog media
    tagged = collections.Counter()
    for r in D.catalog["records"]:
        names = {norm(x) for x in r.get("confirmedPeople", []) + r.get("detectedPeople", [])}
        if qn in names and qn not in {norm(x) for x in r.get("rejectedPeople", [])}:
            tagged["video" if "Video" in (r.get("streamType") or "") else "other"] += 1
    if tagged:
        notes.append(f"'{q}' is also a person tag on {tagged['video']} video record(s)"
                     + (f" and {tagged['other']} audio-only/other record(s)" if tagged["other"] else "")
                     + f" (copies not collapsed) — use search_media people={q} for distinct videos")

    # 8. surname
    sn = qn[:-1] if qn.endswith("s") and len(t) == 1 else qn
    sn = sn.replace(" family", "").replace("the ", "")
    scount = sum(1 for p in D.P.values() if p["names"] and norm(p["names"][0]["surname"]) in (qn, sn))
    if scount:
        notes.append(f"'{q}' is also a family-tree surname ({scount} people) — use catalog_stats surname=...")

    items = sorted(cands.values(), key=lambda c: (c["rank"], order.index(c["id"])))
    for c in items:
        c.pop("rank", None)
        c.update(describe(D, c["id"]))
    dups = [c for c in items if (c.get("identityDecision") or {}).get("duplicateOf")]
    for c in dups:
        notes.append(f"{c['id']} ({c['displayName']}) left out: the family's identity decision marks it a duplicate "
                     f"of FamilySearch {c['identityDecision']['duplicateOf']}")
    items = [c for c in items if c not in dups]
    trunc = len(items) > MAX_CANDIDATES
    items = items[:MAX_CANDIDATES]
    if not items:
        notes.append(f"no person found for '{q}'")
    ids = [i["id"] for i in items] + [x for i in items for x in i.get("sameAs", [])]
    return result("resolve_person", a, items, truncated=trunc, extra={"notes": notes}, ids=ids)


def describe(D, eid):
    kind, _, raw = eid.partition(":")
    if kind == "gedcom" and D.tp(raw):
        p = D.tp(raw)
        d = {"displayName": D.name(raw), "years": years(p.get("birth"), p.get("death")), "sex": p.get("sex")}
        if p.get("identityDecision"):
            d["identityDecision"] = p["identityDecision"]
        return d
    if kind == "people" and raw in D.profiles:
        p = D.profiles[raw]
        return {"displayName": " ".join(x for x in (p.get("name"), p.get("middleName"), p.get("surname"), p.get("suffix")) if x),
                "aliases": p.get("aliases", []), "born": p.get("birthDate"), "died": p.get("deathDate")}
    if kind == "brain" and raw in D.bpeople:
        b = D.bpeople[raw]
        return {"displayName": b["canonicalName"], "aliases": b.get("aliases", [])}
    return {}


def resolve_id(D, s):
    s = (s or "").strip()
    if ":" not in s:
        return None
    return s


def t_person_facts(D, a):
    eid = resolve_id(D, a.get("id"))
    if not eid:
        return fail("person_facts", "badArgs", "id=<gedcom:/people:/brain:/family: id from a tool result> is required")
    D.tree, D.people, D.brain
    ids = D.same_as(eid)
    out = {"id": ids[0], "sameAs": ids[1:]}
    tree = next((i.split(":", 1)[1] for i in ids if i.startswith("gedcom:")), None)
    prof = next((i.split(":", 1)[1] for i in ids if i.startswith("people:")), None)
    brains = [i.split(":", 1)[1] for i in ids if i.startswith("brain:")]
    if eid.startswith("family:"):
        g = D.groups.get(eid.split(":", 1)[1])
        if not g:
            return fail("person_facts", "unknownID", eid)
        return result("person_facts", a, {"id": eid, **g})
    if tree:
        p = D.tp(tree)
        if not p:
            return fail("person_facts", "unknownID", eid)
        out["tree"] = {
            "names": [n["full"] for n in p["names"]], "sex": p.get("sex"),
            "birth": event_view(p.get("birth")), "death": event_view(p.get("death")),
            "familySearchID": p.get("fsid"), "identityDecision": p.get("identityDecision"),
            "isOwner": tree == D.owner,
            "parents": [D.brief(x) for x in D.parents(tree)],
            "spouses": [D.brief(x, family=f"gedcom:{f}", marriage=(D.F[f].get("marriage") or None)) for x, f in D.spouses(tree)],
            "children": [D.brief(x) for x in D.children(tree)],
            "siblingCount": len(D.siblings(tree)),
        }
    if prof:
        p = D.profiles[prof]
        kin = []
        for a_, r, b_ in profile_edges(D):
            if a_ == prof:
                q = D.profiles.get(b_, {})
                kin.append({"relation": r, "id": f"people:{b_}", "name": q.get("name"), "aliases": q.get("aliases", [])})
        out["peopleTab"] = {k: v for k, v in p.items() if k not in ("kinships",)}
        out["peopleTab"]["id"] = f"people:{prof}"
        out["peopleTab"]["kinships"] = sorted(kin, key=lambda k: k["relation"])
    told_ids = []
    if brains:
        out["cyberBrain"] = []
        for b in brains:
            bp = D.bpeople.get(b)
            if not bp:
                continue
            items = [i for i in D.bitems.values() if b in (i.get("subjectPersonIDs") or [])]
            shown = [i for i in items if i.get("privacy") != "private"]
            told = [{"id": f"brain:{i['id']}", "kind": i.get("kind"), "text": short_text(i.get("text")),
                     "confidence": i.get("confidence"),
                     **({"service": i["service"]} if i.get("service") else {})}
                    for i in shown[:PERSON_FACTS_TOLD]]
            told_ids += [t["id"] for t in told]
            entry = {"id": f"brain:{b}", "canonicalName": bp["canonicalName"],
                     "aliases": bp.get("aliases"), "terminology": bp.get("terminology"),
                     "toldItems": told}
            if len(shown) > len(told):
                entry["moreItems"] = f"{len(shown) - len(told)} more; family_knowledge id=brain:{b}"
            if len(items) > len(shown):
                entry["privateItemsWithheld"] = len(items) - len(shown)
            out["cyberBrain"].append(entry)
    if len(out) == 2:
        return fail("person_facts", "unknownID", eid)
    flat = [out["id"]] + out["sameAs"]
    if "tree" in out:
        for k in ("parents", "spouses", "children"):
            flat += [x["id"] for x in out["tree"][k]]
    if "peopleTab" in out:
        for fld in ("notes", "identityNotes"):
            if out["peopleTab"].get(fld):
                flat.append(f"{out['peopleTab']['id']}#{fld}")
    flat += told_ids
    return result("person_facts", a, out, ids=flat)


PERSON_FACTS_TOLD = 8
TOLD_CHARS = 400


def short_text(s: str | None, limit: int = TOLD_CHARS) -> str:
    s = (s or "").strip()
    return s if len(s) <= limit else s[:limit].rsplit(" ", 1)[0] + "…"


REL_ALIASES = {"parents": "parent", "parent": "parent", "children": "child", "child": "child", "kids": "child",
               "siblings": "sibling", "sibling": "sibling", "spouses": "spouse", "spouse": "spouse",
               "grandparents": "grandparent", "grandparent": "grandparent",
               "greatgrandparents": "greatgrandparent", "great_grandparents": "greatgrandparent",
               "grandchildren": "grandchild", "grandchild": "grandchild", "all": "all"}


SIDED_RELATIONS = ("parent", "grandparent", "greatgrandparent", "auntuncle")


def t_relatives(D, a):
    eid = resolve_id(D, a.get("id"))
    rel = REL_ALIASES.get((a.get("relation") or "all").lower())
    side = (a.get("side") or "").lower() or None
    if not eid or not rel:
        return fail("relatives", "badArgs", "id=<id> relation=parents|siblings|spouses|children|grandparents|"
                                            "greatgrandparents|grandchildren|all [side=maternal|paternal]")
    D.tree, D.people
    ids = D.same_as(eid)
    tree = next((i.split(":", 1)[1] for i in ids if i.startswith("gedcom:")), None)
    prof = next((i.split(":", 1)[1] for i in ids if i.startswith("people:")), None)
    rels = ["parent", "sibling", "spouse", "child"] if rel == "all" else [rel]
    items = []
    for r in rels:
        if tree:
            if r == "greatgrandparent":
                found = tree_kin(D, tree, "grandparent", None, side, 1)
            else:
                found = tree_kin(D, tree, r, None, side if r in SIDED_RELATIONS else None)
            for x, note in found:
                items.append(D.brief(x, relation=r, source="family tree", path=note))
        if prof and r in PROFILE_REL:
            for a_, rr, b_ in profile_edges(D):
                if a_ == prof and rr == r:
                    q = D.profiles[b_]
                    sid = D.same_as(f"people:{b_}")
                    if any(i["id"] in sid for i in items):
                        continue
                    items.append({"id": f"people:{b_}", "sameAs": sid[1:], "name": describe(D, f"people:{b_}")["displayName"],
                                  "aliases": q.get("aliases"), "relation": r, "source": "People tab kinship row"})
    notes = []
    if side not in (None, "maternal", "paternal"):
        return fail("relatives", "badArgs", "side must be maternal or paternal")
    if side:
        notes.append(f"side={side} applied to parents/grandparents (through the {'mother' if side == 'maternal' else 'father'}); "
                     "siblings, spouses and children have no side")
        # People-tab kinship rows carry no side: keep only rows the tree did not already answer
        # for sided relations, and drop People-tab parents of the wrong sex.
        items = [i for i in items if not (i.get("source") == "People tab kinship row" and i["relation"] in SIDED_RELATIONS)]
    if not tree:
        notes.append("this person has no linked family-tree record; only People-tab kinship rows were used")
    if not items:
        notes.append("no such relatives recorded in the family tree or People-tab kinship rows; "
                     "told notes may still mention them (family_knowledge)")
    trunc = len(items) > MAX_ITEMS
    return result("relatives", a, items[:MAX_ITEMS], truncated=trunc,
                  extra={"subject": ids[0], "sameAs": ids[1:], "notes": notes})


def kin_name(up, down):
    def gp(n, base):
        if n == 1:
            return base
        if n == 2:
            return "grand" + base
        return ("great-" * (n - 2)) + "grand" + base
    if down == 0:
        return gp(up, "parent")
    if up == 0:
        return gp(down, "child")
    if up == 1 and down == 1:
        return "sibling"
    if down == 1:
        return "great-" * (up - 2) + "aunt/uncle" if up > 2 else "aunt/uncle"
    if up == 1:
        return "great-" * (down - 2) + "niece/nephew" if down > 2 else "niece/nephew"
    deg = min(up, down) - 1
    rem = abs(up - down)
    ords = {1: "1st", 2: "2nd", 3: "3rd"}
    s = f"{ords.get(deg, str(deg) + 'th')} cousin"
    if rem:
        s += f" {'once' if rem == 1 else 'twice' if rem == 2 else str(rem) + ' times'} removed"
    return s


def ancestors(D, pid, max_depth):
    seen = {pid: (0, None)}
    frontier = [pid]
    for d in range(1, max_depth + 1):
        nxt = []
        for x in frontier:
            for par in D.parents(x):
                if par not in seen:
                    seen[par] = (d, x)
                    nxt.append(par)
        frontier = nxt
    return seen


def chain(anc, top):
    path = [top]
    while anc[path[-1]][1] is not None:
        path.append(anc[path[-1]][1])
    return path  # top ... start


def blood(D, a, b, max_depth):
    A, B = ancestors(D, a, max_depth), ancestors(D, b, max_depth)
    common = [(A[x][0] + B[x][0], A[x][0], B[x][0], x) for x in set(A) & set(B)]
    if not common:
        return None
    common.sort()
    best = common[0]
    tied = [c[3] for c in common if c[1] == best[1] and c[2] == best[2]]
    up, down, top = best[1], best[2], best[3]
    path = list(reversed(chain(A, top))) + chain(B, top)[1:]
    return {"up": up, "down": down, "commonAncestors": tied, "path": path}


def t_relationship_between(D, a):
    ai, bi = resolve_id(D, a.get("a")), resolve_id(D, a.get("b"))
    if not ai or not bi:
        return fail("relationship_between", "badArgs", "a=<id> b=<id>")
    D.tree, D.people
    max_depth = min(int(a.get("max_generations", 16)), 25)

    def tree_of(i):
        return next((x.split(":", 1)[1] for x in D.same_as(i) if x.startswith("gedcom:")), None)

    def prof_of(i):
        return next((x.split(":", 1)[1] for x in D.same_as(i) if x.startswith("people:")), None)

    ta, tb = tree_of(ai), tree_of(bi)
    if ta and tb:
        if ta == tb:
            return result("relationship_between", a, {"relation": "same person", "pathIDs": [f"gedcom:{ta}"]})
        if tb in [x for x, _ in D.spouses(ta)]:
            return result("relationship_between", a, {"relation": "spouse", "pathIDs": [f"gedcom:{ta}", f"gedcom:{tb}"],
                                                      "statement": f"{D.name(tb)} is {D.name(ta)}'s spouse"})
        # kin_name(up, down) names b relative to a: up = a's generations to the common ancestor.
        r = blood(D, ta, tb, max_depth)
        by_blood = None
        if r:
            name = kin_name(r["up"], r["down"])
            by_blood = {"relation": name, "statement": f"{D.name(tb)} is {D.name(ta)}'s {name} (by blood)",
                        "generationsUpFromA": r["up"], "generationsDownToB": r["down"],
                        "commonAncestors": [D.brief(x) for x in r["commonAncestors"][:4]],
                        "pathIDs": [f"gedcom:{x}" for x in r["path"]],
                        "pathNames": [D.name(x) for x in r["path"]]}
        # one marriage hop (in-law); a close in-law tie outranks a distant blood one
        inlaw = None
        for sp, _ in D.spouses(tb):
            r2 = blood(D, ta, sp, max_depth)
            if r2 and (inlaw is None or r2["up"] + r2["down"] < inlaw[0]):
                name = kin_name(r2["up"], r2["down"])
                inlaw = (r2["up"] + r2["down"], {
                    "relation": f"spouse of {name}",
                    "statement": f"{D.name(tb)} is the spouse of {D.name(ta)}'s {name} ({D.name(sp)})",
                    "pathIDs": [f"gedcom:{x}" for x in r2["path"]] + [f"gedcom:{tb}"]})
        for sp, _ in D.spouses(ta):
            r2 = blood(D, sp, tb, max_depth)
            if r2 and (inlaw is None or r2["up"] + r2["down"] < inlaw[0]):
                name = kin_name(r2["up"], r2["down"])
                inlaw = (r2["up"] + r2["down"], {
                    "relation": f"spouse's {name}",
                    "statement": f"{D.name(tb)} is {D.name(ta)}'s spouse's ({D.name(sp)}) {name}",
                    "pathIDs": [f"gedcom:{ta}"] + [f"gedcom:{x}" for x in r2["path"]]})
        if inlaw and (by_blood is None or inlaw[0] <= 3 < by_blood["generationsUpFromA"] + by_blood["generationsDownToB"]):
            item = inlaw[1]
            if by_blood:
                item["alsoByBlood"] = by_blood
            return result("relationship_between", a, item,
                          ids=item["pathIDs"] + (by_blood["pathIDs"] if by_blood else []))
        if by_blood:
            if inlaw:
                by_blood["alsoByMarriage"] = inlaw[1]
            return result("relationship_between", a, by_blood,
                          ids=by_blood["pathIDs"] + [c["id"] for c in by_blood["commonAncestors"]])
    pa, pb = prof_of(ai), prof_of(bi)
    if pa and pb:
        for x, r, y in profile_edges(D):
            if x == pa and y == pb:
                return result("relationship_between", a, {"relation": r, "source": "People tab kinship row",
                                                          "statement": f"People tab: {D.profiles[pb]['name']} is {D.profiles[pa]['name']}'s {r}",
                                                          "pathIDs": [f"people:{pa}", f"people:{pb}"]})
    return fail("relationship_between", "noPathWithinLimit",
                f"no blood or one-marriage path within {max_depth} generations in the family tree, and no direct "
                "People-tab kinship row" + ("" if ta and tb else " (one or both people have no family-tree record)"))


def t_family_knowledge(D, a):
    D.people, D.brain
    query = a.get("query") or ""
    eid = resolve_id(D, a.get("id"))
    limit = min(int(a.get("limit", 12)), MAX_ITEMS)
    terms = [w for w in toks(query) if w not in {"the", "a", "an", "of", "and", "about", "in", "on"}]
    subjects_b, subject_p = set(), None
    if eid:
        for i in D.same_as(eid):
            k, _, raw = i.partition(":")
            if k == "brain":
                subjects_b.add(raw)
            elif k == "people":
                subject_p = raw
    rows = []
    for iid, it in D.bitems.items():
        if eid and not (subjects_b & set(it.get("subjectPersonIDs") or [])):
            continue
        rows.append({"id": f"brain:{iid}", "kind": it.get("kind"), "text": it.get("text") or "",
                     "confidence": it.get("confidence"), "privacy": it.get("privacy"),
                     "about": [f"brain:{s}" for s in it.get("subjectPersonIDs") or []],
                     "sources": [(D.bsources.get(s) or {}).get("title", s) for s in it.get("sourceIDs") or []],
                     **({"service": it["service"]} if it.get("service") else {})})
    for u, p in D.profiles.items():
        if eid and u != subject_p:
            continue
        for fld in ("notes", "identityNotes"):
            if p.get(fld):
                rows.append({"id": f"people:{u}#{fld}", "kind": "peopleTabNote" if fld == "notes" else "peopleTabIdentityNote",
                             "text": p[fld], "about": [f"people:{u}"], "sources": ["People tab (written by Rick)"]})
    if terms:
        scored = []
        for r in rows:
            tt = set(toks(r["text"]))
            hits = sum(1 for w in terms if w in tt or (w.endswith("s") and w[:-1] in tt))
            if hits:
                scored.append((-hits, r))
        scored.sort(key=lambda x: x[0])
        rows = [r for _, r in scored]
    trunc = len(rows) > limit
    return result("family_knowledge", a, rows[:limit], truncated=trunc, extra={"matchCount": len(rows)})


# ---------------------------------------------------------------- media

def person_name_set(D, ref):
    """Name strings a catalog person tag may use for this person."""
    ref = ref.strip()
    D.people, D.brain
    if ":" not in ref:
        # a plain name: widen to one People-tab profile's spellings when exactly one profile owns it
        owners = [u for u, p in D.profiles.items() if norm(ref) in D.profile_names(p)]
        if len(owners) != 1:
            return {norm(ref)}
        ref = f"people:{owners[0]}"
    names = set()
    for i in D.same_as(ref):
        k, _, raw = i.partition(":")
        if k == "people" and raw in D.profiles:
            p = D.profiles[raw]
            names |= {norm(p.get("name"))} | {norm(x) for x in p.get("aliases") or []}
        elif k == "gedcom" and D.tp(raw):
            n = D.tp(raw)["names"][0]
            names.add(norm(n["full"]))
            names.add(norm(f'{n["given"]} {n["surname"]}'))
        elif k == "brain" and raw in D.bpeople:
            names |= {norm(x) for x in D.bpeople[raw].get("aliases", [])}
        elif k == "family" and raw in D.groups:
            names.add(norm(D.groups[raw]["name"]))
    names.discard("")
    return names


PEOPLE_BASIS = {
    "confirmed": (("confirmedPeople", "confirmed"),),
    "detected": (("confirmedPeople", "confirmed"), ("detectedPeople", "detected")),
    "any": (("confirmedPeople", "confirmed"), ("detectedPeople", "detected"), ("suspectedPeople", "suspected")),
}


def record_people(r, basis="detected"):
    rej = {norm(x) for x in r.get("rejectedPeople", [])}
    out = {}
    for fld, label in PEOPLE_BASIS[basis]:
        for x in r.get(fld, []):
            n = norm(x)
            if n not in rej and n not in out:
                out[n] = (x, label)
    return out


TEXT_FIELDS = ("filename", "path", "notes", "place", "transcript", "captions")


def text_fields(r, fields=TEXT_FIELDS):
    if "filename" in fields:
        yield "filename", r.get("filename") or ""
    if "path" in fields:
        yield "path", r.get("path") or ""
    if "notes" in fields:
        yield "userNotes", r.get("userNotes") or ""
    if "place" in fields:
        yield "place", r.get("userPlace") or ""
    if "transcript" in fields:
        yield "transcript", r.get("transcriptSnippet") or ""
    if "captions" in fields:
        for c in r.get("captions", []):
            yield f"caption@{c['t']}s", c["text"]


def term_variants(term):
    t = term.lower()
    v = {t}
    if len(t) > 3 and t.endswith("s"):
        v.add(t[:-1])
    return v


def parse_years(s):
    if not s:
        return None
    m = re.match(r"^\s*(\d{4})s?\s*(?:[-–]\s*(\d{4}))?\s*$", s)
    if not m:
        raise ValueError(f"years must be YYYY or YYYY-YYYY or 1980s, got {s!r}")
    lo = int(m.group(1))
    if s.strip().endswith("s") and not m.group(2):
        return lo, lo + 9
    return lo, int(m.group(2) or m.group(1))


KINDS = {
    "video": "video files (stream type Video+Audio or Video only); audio-only and unreadable files NOT counted",
    "audio": "audio-only files",
    "any": "every catalog record of any stream type, audio-only files included",
}
MENTION_ITEMS = 10
TEXT_ONLY_ITEMS = 5
MENTION_NOTE = ("NOT counted in matchCount: nobody tagged this person on these files; the name occurs in "
                "machine-made transcript or caption text. A spoken mention is not proof the person appears.")


def kind_of(a):
    """The stream kind a media count covers. Default video: an audio-only
    file is never a "video" unless the asker says so (demo review gap 1)."""
    k = (a.get("kind") or "video").strip().lower()
    if k not in KINDS:
        raise ValueError("kind must be video|audio|any")
    return k


def kind_ok(r, kind):
    st = r.get("streamType") or ""
    if kind == "video":
        return "Video" in st
    if kind == "audio":
        return st == "Audio only"
    return True


def truthy(v, default):
    if v is None or v == "":
        return default
    if isinstance(v, bool):
        return v
    return str(v).strip().lower() not in ("0", "false", "no", "off")


def mention_terms(names):
    """Name strings worth looking for in speech: no kin words, no 1–2 letter aliases."""
    return {n for n in names if len(n) >= 3 and n not in KIN and n not in OWNER_WORDS}


def find_mention(r, terms, redact):
    for fld, s in text_fields(r, ("transcript", "captions")):
        ns = norm(s)
        for t in sorted(terms, key=len, reverse=True):
            if re.search(r"\b" + re.escape(t) + r"\b", ns):
                sn = snippet(s, t.split()[-1]) or snippet(s, t.split()[0]) or s[:180]
                return {"kind": f"spokenMention:{fld}", "term": t,
                        "snippet": REDACTED if redact else sn}
    return None


def filter_media(D, a, redact, *, skip_tags=False, mentions=False):
    """(matches, undatedExcluded, mentionMatches). A mention match is a record
    where at least one asked-for person is not tagged but named in a
    transcript/caption; it is kept apart and never counted as a match."""
    people = [p for p in re.split(r"[,;]", a.get("people") or "") if p.strip()]
    tags = [t for t in re.split(r"[,;]", a.get("tags") or "") if t.strip()]
    if skip_tags:
        people, tags = [], []
    text = a.get("text") or ""
    terms = [w for w in re.findall(r'"[^"]+"|\S+', text)]
    terms = [w.strip('"') for w in terms if w.strip('"')]
    place = (a.get("place") or "").strip()
    yr = parse_years(a.get("years"))
    kind = kind_of(a)
    basis = (a.get("people_basis") or "detected").lower()
    if basis not in PEOPLE_BASIS:
        raise ValueError("people_basis must be confirmed|detected|any")
    fields = tuple(f.strip() for f in (a.get("in") or ",".join(TEXT_FIELDS)).split(",") if f.strip())
    bad = [f for f in fields if f not in TEXT_FIELDS]
    if bad:
        raise ValueError(f"in= takes {','.join(TEXT_FIELDS)}; got {bad}")
    pnames = [(p, names, mention_terms(names)) for p in people for names in [person_name_set(D, p)]]
    matches, mention_matches, undated_excluded = [], [], 0
    for r in D.catalog["records"]:
        if not kind_ok(r, kind):
            continue
        ev = []
        rp = record_people(r, basis)
        ok, mentioned = True, False
        for ref, names, mterms in pnames:
            hit = next(((n, rp[n]) for n in names if n in rp), None)
            if hit:
                ev.append({"kind": f"personTag:{hit[1][1]}", "term": hit[1][0], "for": ref})
                continue
            m = find_mention(r, mterms, redact) if mentions and mterms else None
            if m:
                ev.append({**m, "for": ref})
                mentioned = True
                continue
            ok = False
            break
        if not ok:
            continue
        for tg in tags:
            tn = norm(tg)
            if tn in {norm(x) for x in r.get("tags", [])}:
                ev.append({"kind": "tag", "term": tg})
            elif tn in rp:
                ev.append({"kind": f"personTag:{rp[tn][1]}", "term": rp[tn][0]})
            else:
                ok = False
                break
        if not ok:
            continue
        for term in terms:
            found = None
            for fld, s in text_fields(r, fields):
                for v in term_variants(term):
                    if re.search(r"(?<![a-z])" + re.escape(v), s.lower()):
                        sn = snippet(s, v)
                        if redact and (fld == "transcript" or fld.startswith("caption")):
                            sn = REDACTED
                        found = {"kind": fld, "term": term, "snippet": sn}
                        break
                if found:
                    break
            if not found:
                ok = False
                break
            ev.append(found)
        if not ok:
            continue
        if place:
            s = " ".join([r.get("userPlace") or "", r.get("path") or "", r.get("userNotes") or ""])
            if place.lower() not in s.lower():
                continue
            ev.append({"kind": "place", "term": place})
        if yr:
            y = r.get("year")
            if y is None:
                if not mentioned:
                    undated_excluded += 1
                continue
            if not (yr[0] <= y <= yr[1]):
                continue
            ev.append({"kind": "year", "term": f"{y} ({r.get('yearSource')})"})
        (mention_matches if mentioned else matches).append((r, ev))
    return matches, undated_excluded, mention_matches


def group_copies(matches):
    groups = collections.OrderedDict()
    for r, ev in matches:
        key = r.get("contentHash") or r["id"]
        groups.setdefault(key, []).append((r, ev))
    out = []
    for key, rows in groups.items():
        rows.sort(key=lambda x: (x[0].get("archiveStage") != "Master", x[0].get("lifecycleStage") != "Archived",
                                 not x[0].get("confirmedPeople")))
        out.append(rows)
    return out


def media_item(r, ev, copies, redact):
    it = {"id": f"catalog:{r['id']}", "filename": r.get("filename"), "path": r.get("path"),
          "volume": r.get("volume"), "year": r.get("year"), "yearSource": r.get("yearSource"),
          "durationSeconds": round(r.get("durationSeconds") or 0, 1), "streamType": r.get("streamType"),
          "stage": r.get("lifecycleStage"),
          "people": {k: r[k] for k in ("confirmedPeople", "detectedPeople", "suspectedPeople") if r.get(k)},
          "tags": r.get("tags") or None, "userPlace": r.get("userPlace"), "userNotes": r.get("userNotes"),
          "evidence": ev}
    if len(copies) > 1:
        it["copies"] = len(copies)
        it["copyIDs"] = [f"catalog:{c['id']}" for c in copies[1:6]]
    return {k: v for k, v in it.items() if v not in (None, [], {})}


def kind_exclusions(D, a, redact, kept_ids):
    """Stream types of records that match everything EXCEPT the kind filter —
    so a count can say what it left out ("+12 audio-only files not counted")."""
    if kind_of(a) == "any":
        return {}
    other, _, _ = filter_media(D, {**a, "kind": "any"}, redact)
    return dict(collections.Counter(r.get("streamType") or "unknown" for r, _ in other if r["id"] not in kept_ids))


def text_without_tag(D, a, redact, kept_ids):
    """Records matching the other filters but not the tag/person filter. A
    filename like 'AtHudsons-Thanksgiving-1984.mov' carries no tag; AND-ing a
    tag with the text used to hide it (demo review gap 4)."""
    if not ((a.get("tags") or a.get("people")) and (a.get("text") or a.get("years") or a.get("place"))):
        return None
    loose, _, _ = filter_media(D, a, redact, skip_tags=True)
    extra = [(r, ev) for r, ev in loose if r["id"] not in kept_ids]
    if not extra:
        return None
    words = [w for w in toks((a.get("tags") or "") + " " + (a.get("people") or ""))
             if w not in {"family", "the", "and"} and len(w) >= 3]
    words = [w[:-1] if w.endswith("s") and len(w) > 4 else w for w in words]
    groups = group_copies(extra)

    def has_words(r):
        s = " ".join([r.get("filename") or "", r.get("path") or "", r.get("userNotes") or "",
                      r.get("userPlace") or ""]).lower()
        return bool(words) and all(w in s for w in words)

    groups.sort(key=lambda g: (not has_words(g[0][0]), g[0][0].get("year") or 9999))
    items = []
    for g in groups[:TEXT_ONLY_ITEMS]:
        it = media_item(g[0][0], g[0][1], [r for r, _ in g], redact)
        it["tagWordsInFilenameOrPath"] = has_words(g[0][0])
        items.append(it)
    return {"count": len(groups), "withTagWordsInFilenameOrPath": sum(1 for g in groups if has_words(g[0][0])),
            "items": items,
            "note": "these match the other filters but carry no such tag/person tag; check filenames and paths "
                    "(tagWordsInFilenameOrPath) before ruling them out. Not counted in matchCount."}


def t_search_media(D, a, redact):
    if not any(a.get(k) for k in ("people", "tags", "text", "place", "years")):
        return fail("search_media", "badArgs", "give at least one of people= tags= text= place= years=")
    try:
        kind = kind_of(a)
        want_mentions = truthy(a.get("include_mentions"), True) and bool(a.get("people"))
        matches, undated, mentions = filter_media(D, a, redact, mentions=want_mentions)
    except ValueError as e:
        return fail("search_media", "badArgs", str(e))
    groups = group_copies(matches)
    groups.sort(key=lambda g: (g[0][0].get("year") or 9999, g[0][0].get("filename") or ""))
    limit = min(int(a.get("limit", MAX_ITEMS)), MAX_ITEMS)
    items = [media_item(g[0][0], g[0][1], [r for r, _ in g], redact) for g in groups[:limit]]
    kept = {r["id"] for r, _ in matches}
    extra = {"matchCount": len(groups), "recordCount": len(matches), "kindCounted": kind,
             "countBasis": f"matchCount = distinct {KINDS[kind]} (identical copies collapsed); "
                           "recordCount counts every catalog record incl. copies"}
    if undated:
        extra["undatedExcluded"] = undated
    excl = kind_exclusions(D, a, redact, kept)
    if excl:
        extra["notCountedByKind"] = excl
    if mentions:
        mg = group_copies(mentions)
        mg.sort(key=lambda g: (g[0][0].get("year") or 9999, g[0][0].get("filename") or ""))
        extra["mentionCount"] = len(mg)
        extra["mentions"] = [media_item(g[0][0], g[0][1], [r for r, _ in g], redact) for g in mg[:MENTION_ITEMS]]
        extra["mentionNote"] = MENTION_NOTE
    tw = text_without_tag(D, a, redact, kept)
    if tw:
        extra["textMatchesWithoutTag"] = tw
    ids = [i["id"] for i in items] + [x for i in items for x in i.get("copyIDs", [])]
    ids += [i["id"] for i in extra.get("mentions", [])]
    ids += [i["id"] for i in (tw or {}).get("items", [])]
    return result("search_media", a, items, truncated=len(groups) > limit, extra=extra, ids=ids)


def tree_scope(D, a):
    """(pool {pid: generations}, description); pool None = whole tree.

    born_in= with no scope defaults to the owner's and spouse's ancestors:
    "who in the family was born in Ireland" means the family, not 39k
    medieval records (demo review gap 5). scope=all asks for the whole tree."""
    scope = (a.get("scope") or "").strip()
    if not scope and a.get("born_in") and not a.get("surname"):
        scope = "family"
    gens = min(int(a.get("generations") or (12 if scope == "family" else 6)), 25)
    if not scope or scope == "all":
        return None, "the whole family tree"
    if scope == "family":
        roots = ([D.owner] + [x for x, _ in D.spouses(D.owner)]) if D.owner else []
        pool = {}
        for root in roots:
            for k, v in ancestors(D, root, gens).items():
                if k not in roots and (k not in pool or v[0] < pool[k]):
                    pool[k] = v[0]
        names = " and ".join(D.name(r) for r in roots)
        return pool, f"the ancestors of {names} (up to {gens} generations)"
    m = re.match(r"^(ancestors|descendants):(.+)$", scope)
    if not m:
        raise ValueError("scope=family | all | ancestors:<id> | descendants:<id>")
    tid = next((x.split(":", 1)[1] for x in D.same_as(m.group(2)) if x.startswith("gedcom:")), None)
    if not tid:
        raise ValueError(f"{m.group(2)} has no family-tree record")
    if m.group(1) == "ancestors":
        return ({k: v[0] for k, v in ancestors(D, tid, gens).items() if k != tid},
                f"the ancestors of {D.name(tid)} (up to {gens} generations)")
    pool, frontier = {}, [tid]
    for d in range(1, gens + 1):
        nxt = []
        for x in frontier:
            for c in D.children(x):
                if c not in pool:
                    pool[c] = d
                    nxt.append(c)
        frontier = nxt
    return pool, f"the descendants of {D.name(tid)} (up to {gens} generations)"


def tree_stats(D, a):
    D.tree
    sn = norm(a.get("surname")) if a.get("surname") else None
    born_in = (a.get("born_in") or "").lower() or None
    try:
        pool, scope_text = tree_scope(D, a)
    except ValueError as e:
        return fail("catalog_stats", "badArgs", str(e))
    primary, anyname, rows = 0, 0, []
    for pid, p in D.P.items():
        if pool is not None and pid not in pool:
            continue
        if sn:
            sns = [norm(n["surname"]) for n in p["names"]]
            if not sns or sn not in sns:
                continue
            anyname += 1
            if sns[0] != sn:
                continue
        if born_in and born_in not in ((p.get("birth") or {}).get("place") or "").lower():
            continue
        primary += 1
        rows.append(pid)

    def birth_year(x):
        return (D.tp(x).get("birth") or {}).get("year")

    if pool is not None:
        rows.sort(key=lambda x: (pool[x], birth_year(x) or 9999))   # closest generations first
    else:
        rows.sort(key=lambda x: birth_year(x) or 9999)
    by = [y for y in (birth_year(x) for x in rows) if y]
    items = [D.brief(x, birthPlace=(D.tp(x).get("birth") or {}).get("place"),
                     **({"generationsFromScope": pool[x]} if pool else {})) for x in rows[:MAX_ITEMS]]
    extra = {"count": primary, "countBasis": "people whose PRIMARY name matches"
             + (" the surname" if sn else "") + (" and whose birth place contains the text" if born_in else "")
             + f", within {scope_text}", "scope": scope_text}
    if pool is not None and a.get("born_in") and not a.get("scope"):
        extra["scopeNote"] = "born_in defaults to the family's own ancestors; pass scope=all for the whole tree"
    if sn:
        extra["countIncludingAlternateNames"] = anyname
    if by:
        extra["birthYearSpan"] = [min(by), max(by)]
    extra["familyTreeSize"] = len(D.P)
    if len(rows) > MAX_ITEMS:
        sur = collections.Counter(((D.tp(x)["names"] or [{}])[0].get("surname") or "?") for x in rows)
        extra["truncationSummary"] = {
            "shown": MAX_ITEMS, "of": len(rows),
            "order": "closest generations first" if pool is not None else "earliest birth first",
            "bySurname": dict(sur.most_common(12)),
            "byCentury": dict(sorted(collections.Counter(f"{y // 100 * 100}s" for y in by).items())),
            "hint": "narrow with surname=, scope= or generations= rather than guessing about the rest"}
    return result("catalog_stats", a, items, truncated=len(rows) > MAX_ITEMS, extra=extra)


def t_catalog_stats(D, a, redact):
    # ---- family-tree counts
    if a.get("surname") or a.get("born_in") or a.get("scope"):
        return tree_stats(D, a)

    # ---- catalog counts (kind defaults to video)
    try:
        kind = kind_of(a)
        matches, undated, _ = filter_media(D, a, redact)
    except ValueError as e:
        return fail("catalog_stats", "badArgs", str(e))
    groups = group_copies(matches)

    def summarize(gs):
        uniq_secs = sum((g[0][0].get("durationSeconds") or 0) for g in gs)
        all_secs = sum((r.get("durationSeconds") or 0) for g in gs for r, _ in g)
        nrec = sum(len(g) for g in gs)
        return {"distinctContent": len(gs), "records": nrec, "extraCopies": nrec - len(gs),
                "distinctHours": round(uniq_secs / 3600, 2), "allCopiesHours": round(all_secs / 3600, 2)}

    group_by = (a.get("group_by") or "").lower()
    kept = {r["id"] for r, _ in matches}
    extra = {"totals": summarize(groups), "kindCounted": kind,
             "countBasis": f"counted: {KINDS[kind]}. distinct = identical copies (same content hash) collapsed; "
                           "extraCopies = records beyond the first copy",
             "byStreamType": dict(collections.Counter(r.get("streamType") for r, _ in matches))}
    if undated:
        extra["undatedExcluded"] = undated
    excl = kind_exclusions(D, a, redact, kept)
    if excl:
        extra["notCountedByKind"] = excl
    if not any(a.get(k) for k in ("people", "tags", "text", "place", "years")):
        cnt = collections.Counter
        extra["catalogWideByStreamType"] = dict(cnt(r.get("streamType") for r in D.catalog["records"]))
        extra["byStage"] = dict(cnt(r.get("lifecycleStage") for r, _ in matches))
        extra["undatedRecords"] = sum(1 for r, _ in matches if not r.get("year"))
    items = []
    if group_by:
        keyf = {
            "decade": lambda r: f"{r['year'] // 10 * 10}s" if r.get("year") else "undated",
            "year": lambda r: str(r["year"]) if r.get("year") else "undated",
            "volume": lambda r: r.get("volume") or "unknown",
            "stream": lambda r: r.get("streamType") or "unknown",
            "person": None,
        }.get(group_by, "bad")
        if keyf == "bad":
            return fail("catalog_stats", "badArgs", "group_by=decade|year|volume|stream|person")
        buckets = collections.defaultdict(list)
        for g in groups:
            r = g[0][0]
            if group_by == "person":
                for n, (orig, _) in record_people(r).items():
                    buckets[orig].append(g)
            else:
                buckets[keyf(r)].append(g)
        items = [{"group": k, **summarize(v)} for k, v in buckets.items()]
        items.sort(key=lambda x: (-x["distinctHours"], x["group"]))
    return result("catalog_stats", a, items[:MAX_ITEMS], truncated=len(items) > MAX_ITEMS, extra=extra)


TOOLS = {
    "resolve_person": ("name", lambda D, a, r: t_resolve_person(D, a)),
    "person_facts": ("id", lambda D, a, r: t_person_facts(D, a)),
    "relatives": ("id", lambda D, a, r: t_relatives(D, a)),
    "relationship_between": (None, lambda D, a, r: t_relationship_between(D, a)),
    "family_knowledge": ("query", lambda D, a, r: t_family_knowledge(D, a)),
    "search_media": ("text", t_search_media),
    "catalog_stats": (None, t_catalog_stats),
}

# One declaration of every tool's arguments. The E1 harness generates its
# JSON Schemas from this (scripts/hallie_e1/schemas.py); the CLI above still
# takes the same names as key=value words. Every value may be given as a
# string; integers and booleans are also accepted.
_ID = "an id copied from a tool result (gedcom:@I12@, people:<uuid>, brain:<id>, family:<uuid>)"
_MEDIA_FILTERS = {
    "people": {"type": "string", "description": "person names or ids; comma = AND. Matches person TAGS; "
               "untagged spoken mentions come back separately under `mentions`."},
    "tags": {"type": "string", "description": "curated tags or person/family tags; comma = AND (e.g. 'Smith Family')"},
    "text": {"type": "string", "description": "words that must ALL appear (in=fields); quote a phrase"},
    "in": {"type": "string", "description": "comma list of fields for text: filename,path,notes,place,transcript,captions (default all)"},
    "place": {"type": "string", "description": "place text"},
    "years": {"type": "string", "description": "1984 | 1980s | 1980-1989"},
    "kind": {"type": "string", "enum": ["video", "audio", "any"],
             "description": "default video: audio-only files are NOT videos and are not counted unless asked"},
    "people_basis": {"type": "string", "enum": ["confirmed", "detected", "any"],
                     "description": "which person tags count (default detected = confirmed + face-detected)"},
}
TOOL_SPECS = {
    "resolve_person": {
        "description": "Find who a name, nickname or kin word means. Kin words (dad, Ma, nana, maternal grandmother, "
                       "my sister) are relative to the archive owner. Returns candidates with kinds (owner, kinTerm, "
                       "profile, brain, tree, treeFirstName, mention) and reasons; several candidates = ambiguous, ask "
                       "which one. `mention` is a name inside a note, not a person record. Notes say when the word "
                       "is also a media tag or a surname.",
        "args": {"name": {"type": "string", "description": "the name or kin phrase exactly as the asker wrote it"}},
        "required": ["name"]},
    "person_facts": {
        "description": "Everything recorded about one person: family-tree record (names, birth/death with qualifier "
                       "and range, parents, spouses + marriage, children), People-tab profile (aliases, dates, "
                       "notes, kinship rows) and the told CyberBrain items with their text.",
        "args": {"id": {"type": "string", "description": _ID}},
        "required": ["id"]},
    "relatives": {
        "description": "Relatives of one person from the family tree and People-tab kinship rows, each with path "
                       "and source. side= limits parents/grandparents/aunts-uncles to one side.",
        "args": {"id": {"type": "string", "description": _ID},
                 "relation": {"type": "string", "enum": ["parents", "siblings", "spouses", "children", "grandparents",
                                                         "greatgrandparents", "grandchildren", "all"]},
                 "side": {"type": "string", "enum": ["maternal", "paternal"]}},
        "required": ["id", "relation"]},
    "relationship_between": {
        "description": "How person b is related to person a (blood, or one marriage hop), with common ancestors "
                       "and path ids; noPathWithinLimit when none.",
        "args": {"a": {"type": "string", "description": _ID}, "b": {"type": "string", "description": _ID},
                 "max_generations": {"type": "integer", "description": "default 16, at most 25"}},
        "required": ["a", "b"]},
    "family_knowledge": {
        "description": "Told text: CyberBrain items (biography, notes, events) and People-tab notes, with "
                       "confidence and source. Filter by person id and/or words.",
        "args": {"id": {"type": "string", "description": _ID},
                 "query": {"type": "string", "description": "words to look for"},
                 "limit": {"type": "integer", "description": "default 12, at most 25"}},
        "required": []},
    "search_media": {
        "description": "Find catalog media files. matchCount = distinct content (identical copies collapsed); "
                       "every result says what it counted (kindCounted, countBasis, notCountedByKind). Untagged "
                       "transcript mentions of a person come back separately as `mentions`; files that match the "
                       "text but not a tag come back as `textMatchesWithoutTag`.",
        "args": {**_MEDIA_FILTERS,
                 "include_mentions": {"type": "boolean", "description": "default true: also list spoken/caption mentions of people= (labelled, not counted)"},
                 "limit": {"type": "integer", "description": "default and max 25"}},
        "required": []},
    "catalog_stats": {
        "description": "Counts. Catalog mode (default kind=video): totals {distinctContent, records, extraCopies, "
                       "distinctHours, allCopiesHours}, byStreamType, notCountedByKind, optional group_by rows. "
                       "Family-tree mode (surname= / born_in= / scope=): count by primary name, "
                       "countIncludingAlternateNames, birthYearSpan; born_in defaults to the owner's and spouse's "
                       "ancestors (scope=all for the whole tree).",
        "args": {**_MEDIA_FILTERS,
                 "group_by": {"type": "string", "enum": ["decade", "year", "volume", "stream", "person"]},
                 "surname": {"type": "string"}, "born_in": {"type": "string", "description": "birth-place text"},
                 "scope": {"type": "string", "description": "family | all | ancestors:<id> | descendants:<id>"},
                 "generations": {"type": "integer", "description": "scope depth (default 12 for family, 6 otherwise)"}},
        "required": []},
}
assert set(TOOL_SPECS) == set(TOOLS)


def call_tool(D, name, args):
    """Run one tool by name over a loaded Data. Never raises: an unknown tool
    or a bad argument comes back as ok:false so the caller can hand it to the
    model as an error result."""
    if name not in TOOLS:
        return fail(name, "unknownTool", f"tools: {', '.join(TOOLS)}")
    spec = TOOL_SPECS[name]
    if not isinstance(args, dict):
        return fail(name, "badArgs", "arguments must be an object")
    unknown = [k for k in args if k not in spec["args"]]
    if unknown:
        return fail(name, "badArgs", f"unknown argument(s) {unknown}; takes {sorted(spec['args'])}")
    clean = {}
    for k, v in args.items():
        if v is None:
            continue
        clean[k] = v if isinstance(v, bool) else str(v)
    missing = [k for k in spec["required"] if not clean.get(k)]
    if missing:
        return fail(name, "badArgs", f"missing {missing}")
    try:
        return TOOLS[name][1](D, clean, D.redact)
    except FileNotFoundError as e:
        return fail(name, "noSnapshot", str(e))
    except (ValueError, KeyError, TypeError) as e:
        return fail(name, "badArgs", f"{type(e).__name__}: {e}")


def run(argv, snapshots=None, redact=False):
    snap = snapshots or DEFAULT_SNAPSHOTS
    args = list(argv)
    while args and args[0].startswith("--"):
        flag = args.pop(0)
        if flag == "--snapshots":
            snap = args.pop(0)
        elif flag == "--redact-media-text":
            redact = True
        else:
            return fail("cli", "badArgs", f"unknown flag {flag}")
    if not args or args[0] not in TOOLS:
        return fail("cli", "unknownTool", f"tools: {', '.join(TOOLS)}")
    tool = args.pop(0)
    main_key, fn = TOOLS[tool]
    kv, bare, last = {}, [], None
    for w in args:
        if re.match(r"^[a-z_]+=", w):
            k, v = w.split("=", 1)
            kv[k] = v
            last = k
        elif last:  # an unquoted multi-word value: tags=Hudson Family
            kv[last] += " " + w
        else:
            bare.append(w)
    if bare and main_key and main_key not in kv:
        kv[main_key] = " ".join(bare)
    D = Data(snap, redact)
    try:
        return fn(D, kv, redact)
    except FileNotFoundError as e:
        return fail(tool, "noSnapshot", f"{e}; run snapshot.py first")


def main():
    out = run(sys.argv[1:])
    json.dump(out, sys.stdout, ensure_ascii=False, indent=1)
    print()
    return 0 if out.get("ok") else 2


if __name__ == "__main__":
    sys.exit(main())
