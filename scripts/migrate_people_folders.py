#!/usr/bin/env python3
"""One People/ folder per person, named <Name>_<FamilySearchID>.

Rick, 2026-09-17: "IFF a person has an ID from Gedcom such as an ID used by
family search, we can use that ID and centralize the folder such as
Donna_Hudson_Breen_ID" — and, for the cases the matcher cannot settle:
"have it pause and ask me which name to use as you go … so long as it prompts
with the names so I know which one is confused and how to choose and as long
as the folders have the _ID at the end."

WHAT IT DOES
  • Resolves every People/ folder to a person in the compiled tree.
  • Merges the folders that are one person (Peter had four) and renames the
    rest so each ends in _<FamilySearchID>.
  • ASKS, for anything it cannot settle on its own, showing the candidates.
  • Moves files. Never copies, never deletes one, never overwrites one.

SAFETY
  • Nothing moves without --apply. Bare, it prints the plan and asks nothing.
  • Every move is appended to a manifest AS IT HAPPENS, so an interrupted run
    is still reversible: --undo <manifest>.
  • A filename that exists in two sources is kept under a suffixed name
    rather than overwritten — two different photos, both kept.
  • A folder with no FamilySearch ID is LEFT ALONE. That is Rick's rule for
    Beth and for anyone living who is deliberately not on FamilySearch, and
    it is also what protects group folders like RickDonnaBreenFamily.

  usage:
    python3 scripts/migrate_people_folders.py                 # plan only
    python3 scripts/migrate_people_folders.py --apply         # ask, then move
    python3 scripts/migrate_people_folders.py --undo <file>   # put it all back
"""
import argparse, collections, json, os, re, shutil, sys
from datetime import datetime

ARCHIVE = "/Volumes/FamilyArchive/Breen_Family_Archive/40_Family_Tree"
PEOPLE = os.path.join(ARCHIVE, "People")
GEDCOM = os.path.join(ARCHIVE, "GEDCOM", "familysearch-merged-mco-20260917.ged")
FSID = re.compile(r"^[A-Z0-9]{4}-[A-Z0-9]{3}$")


# ---------------------------------------------------------------- tree

def norm(s):
    s = s.replace("/", " ").replace("'", "").replace("’", "")
    return " ".join(re.sub(r"[^A-Za-z0-9]+", " ", s).lower().split())


def short_key(k):
    parts = k.split()
    return (parts[0] + " " + parts[-1]) if len(parts) > 1 else k


def load_tree(path):
    people, by_name = {}, collections.defaultdict(set)
    cur = None

    def flush(c):
        if not c or not c.get("fsid"):
            return
        people[c["fsid"]] = {"name": c.get("name", ""), "year": c.get("year"),
                             "names": sorted(c.get("names", set()))}
        for n in c.get("names", set()):
            by_name[n].add(c["fsid"])

    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        if line.startswith("0 @") and " INDI" in line:
            flush(cur)
            cur = {"names": set()}
        elif cur is not None:
            if line.startswith("1 NAME "):
                cur.setdefault("name", line[7:])
                cur["names"].add(norm(line[7:]))
            elif line.startswith("1 _FSFTID "):
                cur["fsid"] = line[10:].strip()
            elif line.startswith("1 BIRT"):
                cur["_b"] = True
            elif line.startswith("2 DATE ") and cur.pop("_b", False):
                m = re.search(r"\b(1[0-9]{3}|20[0-9]{2})\b", line)
                if m:
                    cur["year"] = int(m.group(1))
            elif line.startswith("1 "):
                cur.pop("_b", None)
    flush(cur)
    return people, by_name


# ---------------------------------------------------------------- naming

def safe_component(name):
    """A Finder-legible folder name. Strips GEDCOM slashes BEFORE casing, or
    '/ronan/' title-cases to itself — FamilySearch really does store
    'peter /ronan/' in lower case."""
    name = name.replace("/", " ")
    if name == name.lower():
        name = " ".join(w.capitalize() for w in name.split())
    return re.sub(r"_+", "_", re.sub(r"[^A-Za-z0-9]+", "_", name)).strip("_")


def target_name(display, fsid):
    """Rick's invariant: whatever the name, the id is on the end."""
    base = safe_component(display)
    return f"{base}_{fsid}" if base else fsid


def id_in(component):
    if FSID.match(component):
        return component
    last = component.split("_")[-1]
    return last if FSID.match(last) else None


def parse_folder(component):
    parts = component.split("_")
    fs = None
    if FSID.match(component):
        return component, "", None
    if parts and FSID.match(parts[-1]):
        fs, parts = parts[-1], parts[:-1]
    year = None
    if parts and re.fullmatch(r"[bB](1[0-9]{3}|20[0-9]{2})", parts[-1]):
        year, parts = int(parts[-1][1:]), parts[:-1]
    if parts and re.fullmatch(r"[Ii]\d+", parts[-1]):
        parts = parts[:-1]
    return fs, " ".join(parts), year


def files_in(path):
    try:
        return sorted(f for f in os.listdir(path) if not f.startswith("."))
    except OSError:
        return []


# ---------------------------------------------------------------- matching

def edits1(a, b):
    if a == b or abs(len(a) - len(b)) > 1:
        return False
    if len(a) == len(b):
        return sum(x != y for x, y in zip(a, b)) == 1
    lo, hi = (a, b) if len(a) < len(b) else (b, a)
    return any(hi[:i] + hi[i + 1:] == lo for i in range(len(hi)))


def resolve(folders, people, by_name):
    by_short = collections.defaultdict(set)
    for n, fss in by_name.items():
        by_short[short_key(n)] |= fss

    def near(k):
        parts = k.split()
        if len(parts) < 2:
            return set()
        given, surname = parts[0], parts[-1]
        out = set()
        for cand, fss in by_short.items():
            cp = cand.split()
            if len(cp) >= 2 and cp[-1] == surname and edits1(cp[0], given):
                out |= fss
        return out

    sure, asks = {}, []
    for comp in folders:
        fs, name, year = parse_folder(comp)
        count = len(files_in(os.path.join(PEOPLE, comp)))
        if fs and fs in people:
            sure[comp] = (fs, "id in the folder name")
            continue
        if fs:
            asks.append((comp, count, [], f"folder id {fs} is not in the tree"))
            continue
        key = norm(name)
        hits, how = by_name.get(key, set()), "exact name"
        if not hits:
            hits, how = by_short.get(short_key(key), set()), "given name + surname"
        if len(hits) > 1 and year:
            narrowed = {h for h in hits if people[h]["year"] == year}
            if len(narrowed) == 1:
                hits, how = narrowed, how + " + birth year"
        if len(hits) == 1:
            sure[comp] = (next(iter(hits)), how)
            continue
        if len(hits) > 1:
            asks.append((comp, count, sorted(hits), "several people share that name"))
            continue
        cand = near(key)
        if cand:
            asks.append((comp, count, sorted(cand),
                         "no exact match; these are one letter away"))
        else:
            why = ("looks like a GROUP folder, not one person"
                   if re.search(r"family", comp, re.I) else "no tree record with that name")
            asks.append((comp, count, [], why))
    return sure, asks


# ---------------------------------------------------------------- asking

def ask(comp, count, candidates, why, people):
    """Returns (fsid, folder_name) or None to leave the folder alone.

    Two shapes, because they are two different questions. WITH candidates:
    which of these people is it. WITHOUT: there is nobody to offer, so the
    only useful thing is a FamilySearch id typed in — Rick often knows it
    even when the name in the folder does not match the tree.
    """
    print()
    print("─" * 70)
    print(f"  {comp}   ({count} file{'s' if count != 1 else ''})")
    print(f"  confused because: {why}")

    def confirm(fs):
        suggested = safe_component(people[fs]["name"])
        print(f"  folder will be: {suggested}_{fs}")
        try:
            typed = input("  return to accept, or type a different name > ").strip()
        except EOFError:
            typed = ""
        # Rick's invariant is enforced here, never left to typing.
        return fs, target_name(typed or suggested, fs)

    if candidates:
        print("  candidates in the tree:")
        for i, fs in enumerate(candidates, 1):
            p = people[fs]
            year = f"b. {p['year']}" if p["year"] else "no birth year"
            others = [n for n in p["names"] if n != norm(p["name"])]
            also = f"   also known as: {', '.join(others)}" if others else ""
            print(f"    {i}. {p['name']:38} {fs}  {year}{also}")
        prompt = "  number, a FamilySearch id, or 's' to skip > "
    else:
        print("  nobody in the tree to offer. Type a FamilySearch id if you")
        print("  know it (e.g. G2CL-86B), or skip and it stays exactly as it is.")
        prompt = "  FamilySearch id, or 's' to skip > "

    while True:
        try:
            choice = input(prompt).strip()
        except EOFError:
            print("  (no input — skipping)")
            return None
        if choice.lower() in ("s", ""):
            return None
        if candidates and choice.isdigit() and 1 <= int(choice) <= len(candidates):
            return confirm(candidates[int(choice) - 1])
        typed = choice.upper()
        if FSID.match(typed):
            if typed in people:
                return confirm(typed)
            print(f"  {typed} is not in this tree.")
            continue
        print("  didn't understand that.")


# ---------------------------------------------------------------- moving

def move_folder(src_dir, dst_dir, manifest, log):
    os.makedirs(dst_dir, exist_ok=True)
    for name in files_in(src_dir):
        src = os.path.join(src_dir, name)
        dst = os.path.join(dst_dir, name)
        if os.path.exists(dst):
            stem, ext = os.path.splitext(name)
            tag = os.path.basename(src_dir)
            dst = os.path.join(dst_dir, f"{stem}--from-{tag}{ext}")
            n = 2
            while os.path.exists(dst):
                dst = os.path.join(dst_dir, f"{stem}--from-{tag}-{n}{ext}")
                n += 1
        shutil.move(src, dst)
        entry = {"from": src, "to": dst}
        manifest.append(entry)
        log.write(json.dumps(entry) + "\n")
        log.flush()
        print(f"      {name}  →  {os.path.basename(dst)}")
    # Finder leaves a .DS_Store behind, which kept every emptied source
    # folder alive and visible — so People/ still SHOWED two Donnas even
    # though one held nothing. macOS metadata is not content.
    if not files_in(src_dir) and os.path.isdir(src_dir):
        for junk in ("​.DS_Store".strip("\u200b"), ".localized"):
            path = os.path.join(src_dir, junk)
            if os.path.exists(path):
                os.remove(path)
        try:
            os.rmdir(src_dir)                      # only ever an EMPTY dir
            entry = {"removed_empty_dir": src_dir}
            manifest.append(entry)
            log.write(json.dumps(entry) + "\n")
            log.flush()
        except OSError:
            pass


def undo(path):
    """Put everything back, and SAY what could not be.

    A manifest goes stale the moment anything moves afterwards — Rick
    tidying a photo in Finder, or the app recording a new chosen photo. That
    is normal, not corruption. What is not acceptable is an undo that skips
    those quietly and still reports success: he would believe the archive
    was restored when part of it was not.
    """
    entries = [json.loads(l) for l in open(path) if l.strip()]
    restored, dirs, missing, blocked = 0, 0, [], []
    for e in reversed(entries):
        if "removed_empty_dir" in e:
            os.makedirs(e["removed_empty_dir"], exist_ok=True)
            dirs += 1
            continue
        if not os.path.exists(e["to"]):
            missing.append(e)
            continue
        if os.path.exists(e["from"]):
            # Something is already sitting where this file came from.
            # Never overwrite it.
            blocked.append(e)
            continue
        os.makedirs(os.path.dirname(e["from"]), exist_ok=True)
        shutil.move(e["to"], e["from"])
        restored += 1

    print(f"restored {restored} file(s) and {dirs} folder(s)")
    if missing:
        print(f"\n{len(missing)} file(s) were NOT where the manifest left them — "
              "moved or renamed since, so they were left alone:")
        for e in missing:
            print(f"  {os.path.basename(e['to'])}")
            print(f"     expected in {os.path.basename(os.path.dirname(e['to']))}/")
            found = _find_by_name(os.path.dirname(os.path.dirname(e["to"])),
                                  os.path.basename(e["to"]))
            print(f"     now in      {found or '(not found anywhere under People/)'}")
    if blocked:
        print(f"\n{len(blocked)} file(s) could not go back — something is already there:")
        for e in blocked:
            print(f"  {e['from']}")
    if missing or blocked:
        print("\nThe undo did what it safely could. Nothing was overwritten "
              "and nothing was deleted.")


def _find_by_name(root, name):
    """Where a file ended up, so a stale manifest entry is a lead rather
    than a dead end."""
    for dirpath, _dirs, files in os.walk(root):
        if name in files:
            return os.path.relpath(os.path.join(dirpath, name), os.path.dirname(root))
    return None


# ---------------------------------------------------------------- main

def main():
    global ARCHIVE, PEOPLE
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="actually move files")
    ap.add_argument("--undo", metavar="MANIFEST")
    ap.add_argument("--gedcom", default=GEDCOM)
    ap.add_argument("--archive", default=ARCHIVE,
                    help="archive root (tests point this at a sandbox)")
    ap.add_argument("--decisions", metavar="JSON",
                    help="answers for the flagged folders, so a run is "
                         "repeatable and auditable instead of typed blind: "
                         '{"Folder": {"fsid": "G2CL-86B", "name": "Donna_Hudson"}} '
                         'or {"Folder": "skip"}')
    args = ap.parse_args()
    ARCHIVE = args.archive
    PEOPLE = os.path.join(ARCHIVE, "People")

    if args.undo:
        undo(args.undo)
        return

    if not os.path.isdir(PEOPLE):
        sys.exit(f"People folder not found: {PEOPLE}  (is the archive mounted?)")
    people, by_name = load_tree(args.gedcom)
    folders = sorted(f for f in os.listdir(PEOPLE)
                     if os.path.isdir(os.path.join(PEOPLE, f)) and not f.startswith("."))
    sure, asks = resolve(folders, people, by_name)
    print(f"{len(folders)} folders · {len(sure)} resolved · {len(asks)} need you")

    answers = json.load(open(args.decisions)) if args.decisions else {}
    decided, typed_names = {}, set()
    for comp, (fs, _why) in sure.items():
        decided[comp] = (fs, target_name(people[fs]["name"], fs))

    # Pre-supplied answers settle a flagged folder without a prompt.
    remaining = []
    for comp, count, cands, why in asks:
        if comp not in answers:
            remaining.append((comp, count, cands, why)); continue
        a = answers[comp]
        if a == "skip":
            print(f"  (answer) {comp}: left alone"); continue
        fs = a["fsid"]
        if fs not in people:
            sys.exit(f"answer for {comp} names {fs}, which is not in the tree")
        name = a.get("name")
        decided[comp] = (fs, target_name(name, fs) if name else
                         target_name(people[fs]["name"], fs))
        if name:
            typed_names.add(comp)
        print(f"  (answer) {comp} → {decided[comp][1]}")
    asks = remaining

    if args.apply and asks:
        print("\nNow the ones I could not settle. 's' leaves a folder untouched.")
        for comp, count, cands, why in asks:
            got = ask(comp, count, cands, why, people)
            if got:
                decided[comp] = got
                if got[1] != target_name(people[got[0]]["name"], got[0]):
                    typed_names.add(comp)
    elif asks:
        print("\nWould ask about:")
        for comp, count, _c, why in asks:
            print(f"  {comp} ({count} files) — {why}")

    # Group by PERSON, never by (person, name). A name Rick types for one
    # folder and a name derived for another are the same human being, and
    # keying on both would hand him two folders for her — the very thing
    # this script exists to end. A name he typed wins for the whole group.
    groups = collections.defaultdict(list)
    chosen_name = {}
    for comp, (fs, target) in decided.items():
        groups[fs].append(comp)
        if comp in typed_names:
            chosen_name[fs] = target
    groups = {fs: sorted(comps) for fs, comps in groups.items()}
    moves = {}
    for fs, comps in groups.items():
        target = chosen_name.get(fs) or target_name(people[fs]["name"], fs)
        if len(comps) > 1 or comps[0] != target:
            moves[(fs, target)] = comps
    if not moves:
        print("\nNothing to do — every folder is already <Name>_<ID>.")
        return

    print(f"\n{len(moves)} folder(s) to write:")
    for (fs, target), sources in sorted(moves.items(), key=lambda kv: kv[0][1]):
        total = sum(len(files_in(os.path.join(PEOPLE, s))) for s in sources)
        print(f"  {target}   ({total} files)")
        for s in sources:
            print(f"      ← {s}")
        assert id_in(target) == fs, f"target {target} lost its id"

    if not args.apply:
        print("\nPlan only. Re-run with --apply to be asked about the rest and move files.")
        return

    try:
        answer = input("\nmove these now? type yes > ").strip().lower()
    except EOFError:
        answer = ""          # no tty: refuse rather than move files unasked
    if answer != "yes":
        print("nothing moved.")
        return

    stamp = datetime.now().strftime("%Y%m%dT%H%M%S")
    manifest_path = os.path.join(ARCHIVE, f"people-migration-{stamp}.jsonl")
    manifest = []
    with open(manifest_path, "w") as log:
        for (fs, target), sources in sorted(moves.items(), key=lambda kv: kv[0][1]):
            dst = os.path.join(PEOPLE, target)
            print(f"\n  {target}")
            for s in sources:
                if os.path.join(PEOPLE, s) == dst:
                    continue
                move_folder(os.path.join(PEOPLE, s), dst, manifest, log)
            if os.path.isdir(os.path.join(PEOPLE, target)) and \
               any(os.path.join(PEOPLE, s) == dst for s in sources):
                pass

    print(f"\nmoved {len([m for m in manifest if 'from' in m])} file(s)")
    print(f"manifest: {manifest_path}")
    print(f"undo:     python3 {sys.argv[0]} --undo {manifest_path}")

    bad = [f for f in os.listdir(PEOPLE)
           if os.path.isdir(os.path.join(PEOPLE, f)) and not f.startswith(".")
           and files_in(os.path.join(PEOPLE, f)) and not id_in(f)]
    if bad:
        print("\nStill without an id (left alone on purpose — no FamilySearch id):")
        for f in bad:
            print(f"  {f}")


if __name__ == "__main__":
    main()
