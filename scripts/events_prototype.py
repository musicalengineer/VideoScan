#!/usr/bin/env python3
"""Events prototype v0 (Rick 2026-10-12): which recordings belong to the same family memory?

Read-only. Uses evidence the catalog already holds — Dossier scene captions,
Whisper transcripts, dates and folder names — to propose event *categories*
per clip and group clips into candidate event *instances*. Copies collapse by
full SHA-256 (Fill In Full Hashes, 10/11), so three copies of one tape are one
witness, not three.

Output is a LOCAL HTML page (thumbnails from the app's preview cache, file://)
for Rick to mark ✓/✗ per clip. It never leaves the machine: family pixels and
speech stay local (Hallie cloud ruling, 10/10). Do not publish it.

    python3 scripts/events_prototype.py            # writes + opens the page
    python3 scripts/events_prototype.py --no-open
    python3 scripts/events_prototype.py --no-open --stats-json out.json

--stats-json writes COUNTS ONLY (no names, paths, captions or speech) for the
metrics page via tools/publish_metrics.py: active records, how many carry
captions / transcripts, clips with evidence, candidate and strong events,
events per category, and Rick's ✓/✗ marks (from the newest
~/Downloads/events-v0-marks*.json, else nulls) overall and per category.
"""
from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

APP_SUPPORT = Path.home() / "Library" / "Application Support" / "VideoScan"
CATALOG = APP_SUPPORT / "catalog.json"
PREVIEWS = APP_SUPPORT / "preview-cache"
OUT_DIR = APP_SUPPORT / "events-prototype"
DOWNLOADS = Path.home() / "Downloads"          # where the page's "Export marks" lands
MARKS_GLOB = "events-v0-marks*.json"

# category -> (what's SEEN in scene captions, what's SAID in the transcript)
CATEGORIES: dict[str, tuple[str, str]] = {
    "Birthday": (r"birthday|cake with (lit )?candles|blowing out (the )?candles|candles on (a|the) cake",
                 r"happy birthday|birthday"),
    "Christmas": (r"christmas|santa|wrapped (gifts|presents)|ornaments?\b",
                  r"merry christmas|christmas|santa"),
    "Thanksgiving": (r"thanksgiving|roast(ed)? turkey|turkey dinner",
                     r"thanksgiving|happy thanksgiving"),
    "Easter": (r"easter|egg hunt", r"easter|egg hunt"),
    "Halloween": (r"halloween|costumes?\b.*(trick|treat)|jack-o|pumpkins?", r"halloween|trick or treat"),
    "Wedding": (r"wedding|bride|groom", r"wedding|bride|groom"),
    "Beach / vacation": (r"\bbeach\b|seashore|ocean waves", r"vacation|the beach"),
    "Music / performance": (r"playing (the |a )?(guitar|piano|keyboard|drums|violin)|on stage|concert|recital",
                            r"recital|concert"),
    "Graduation": (r"graduation|cap and gown|diploma", r"graduation|graduate"),
}
COMPILED = {k: (re.compile(a, re.I), re.compile(b, re.I)) for k, (a, b) in CATEGORIES.items()}
PATH_YEAR = re.compile(r"(?<!\d)(19[5-9]\d|20[0-2]\d)(?!\d)")
GROUP_WINDOW = timedelta(days=4)


def load_records() -> list[dict]:
    with CATALOG.open() as f:
        d = json.load(f)
    recs = d["records"] if isinstance(d, dict) else d
    return [r for r in recs if not r.get("purgedAt") and not r.get("removal")]


def content_key(r: dict) -> str:
    cf = r.get("contentFixity")
    if isinstance(cf, dict):
        for k in ("sha256", "digest"):
            if cf.get(k):
                return cf[k]
    return "id:" + str(r.get("id"))


def parse_date(v) -> datetime | None:
    if not v:
        return None
    if isinstance(v, (int, float)):  # Swift reference date (2001-01-01) seconds
        return datetime(2001, 1, 1) + timedelta(seconds=v)
    s = str(v)
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%d", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            return datetime.strptime(s[:len(datetime.now().strftime(fmt))] if "%f" not in fmt else s, fmt).replace(tzinfo=None)
        except ValueError:
            continue
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})", s)
    return datetime(int(m[1]), int(m[2]), int(m[3])) if m else None


def best_date(r: dict) -> tuple[datetime | None, str]:
    """Most trustworthy date first; the source travels with it (show the WHY)."""
    for field, label in (("userDate", "you"), ("inferredRecordDate", "inferred"),
                         ("embeddedCreationDate", "camera")):
        dt = parse_date(r.get(field))
        if dt and 1940 < dt.year <= datetime.now().year:
            return dt, label
    m = PATH_YEAR.search(r.get("fullPath", ""))
    if m:
        return datetime(int(m[1]), 7, 1), "folder name (year only)"
    return None, "no date"


def evidence(r: dict) -> dict[str, list[str]]:
    """category -> short evidence lines ('seen @ 1:35 …', 'said …')."""
    out: dict[str, list[str]] = defaultdict(list)
    caps = r.get("sceneCaptions") or []
    tx = r.get("audioTranscript") or ""
    for cat, (seen, said) in COMPILED.items():
        for c in caps:
            t = c.get("text", "")
            m = seen.search(t)
            if m:
                ts = int(c.get("timestamp") or 0)
                out[cat].append(f"seen @ {ts // 60}:{ts % 60:02d} — …{snippet(t, m)}…")
                break
        m = said.search(tx)
        if m:
            out[cat].append(f"said — “…{snippet(tx, m)}…”")
        if not out[cat] and seen.search(r.get("fullPath", "")):
            out[cat].append("folder/file name")
    return {k: v for k, v in out.items() if v}


def snippet(text: str, m: re.Match, pad: int = 60) -> str:
    a, b = max(0, m.start() - pad), min(len(text), m.end() + pad)
    return text[a:b].replace("\n", " ").strip()


def preview_path(path: str) -> str | None:
    try:
        st = os.stat(path)
    except OSError:
        return None
    key = hashlib.sha256(f"{path}|{int(st.st_mtime)}|{st.st_size}".encode()).hexdigest()
    for tier in ("best", "fast"):
        p = PREVIEWS / f"{key}-{tier}.jpg"
        if p.exists():
            return p.as_uri()
    return None


def collapse_copies(recs: list[dict]) -> list[dict]:
    """One representative per full hash: the copy on disk now, else the first."""
    by: dict[str, list[dict]] = defaultdict(list)
    for r in recs:
        by[content_key(r)].append(r)
    reps = []
    for group in by.values():
        rep = next((r for r in group if os.path.exists(r.get("fullPath", ""))), group[0])
        rep = dict(rep)
        rep["_copies"] = len(group)
        reps.append(rep)
    return reps


def group_events(clips: list[dict]) -> list[dict]:
    """Instances: same category AND (same folder, or dated within GROUP_WINDOW)."""
    events: list[dict] = []
    by_cat: dict[str, list[dict]] = defaultdict(list)
    for c in clips:
        for cat in c["_cats"]:
            by_cat[cat].append(c)
    for cat, items in by_cat.items():
        items.sort(key=lambda c: (c["_date"] or datetime.max, c["fullPath"]))
        open_groups: list[dict] = []
        for c in items:
            folder = os.path.dirname(c["fullPath"])
            home = None
            for g in open_groups:
                if folder in g["folders"]:
                    home = g
                    break
                if c["_date"] and g["end"] and c["_date"] - g["end"] <= GROUP_WINDOW and c["_dsrc"] != "folder name (year only)":
                    home = g
                    break
            if home is None:
                home = {"category": cat, "clips": [], "folders": set(), "start": c["_date"], "end": c["_date"]}
                open_groups.append(home)
            home["clips"].append(c)
            home["folders"].add(folder)
            if c["_date"]:
                home["start"] = min(filter(None, [home["start"], c["_date"]]))
                home["end"] = max(filter(None, [home["end"], c["_date"]]))
        events.extend(open_groups)
    for e in events:
        both = sum(1 for c in e["clips"] if any(l.startswith("seen") for l in c["_ev"][e["category"]])
                   and any(l.startswith("said") for l in c["_ev"][e["category"]]))
        e["strength"] = "strong" if (both or len(e["clips"]) >= 3) else "weak"
    events.sort(key=lambda e: (e["start"] or datetime.max, e["category"]))
    return events


def fmt_range(e: dict) -> str:
    if not e["start"]:
        return "date unknown"
    a, b = e["start"], e["end"]
    srcs = {c["_dsrc"] for c in e["clips"] if c["_date"]}
    if srcs == {"folder name (year only)"}:
        return f"{a.year} (from folder name)"
    return a.strftime("%b %-d, %Y") if a.date() == b.date() else f"{a:%b %-d, %Y} – {b:%b %-d, %Y}"


def render(events: list[dict], stats: dict) -> str:
    esc = html.escape
    cards = []
    for i, e in enumerate(events):
        clips = []
        for c in e["clips"][:24]:
            thumb = c["_thumb"]
            img = f'<img src="{thumb}" loading="lazy">' if thumb else '<div class="noimg">no preview</div>'
            ev = "".join(f"<li>{esc(l)}</li>" for l in c["_ev"][e["category"]][:3])
            cid = esc(f'{e["category"]}|{content_key(c)}')
            copies = f' · {c["_copies"]} copies' if c["_copies"] > 1 else ""
            clips.append(f"""
<div class="clip" data-id="{cid}">
  <a href="{Path(c['fullPath']).as_uri()}">{img}</a>
  <div class="meta"><b>{esc(c.get('filename', ''))}</b><br>
    <span class="dim">{esc(c['_dsrc'])}{copies} · {esc(c.get('duration') or '')}</span>
    <ul>{ev}</ul>
    <div class="vote"><button data-v="yes">✓ right</button><button data-v="no">✗ wrong</button></div>
  </div>
</div>""")
        more = f'<p class="dim">… and {len(e["clips"]) - 24} more</p>' if len(e["clips"]) > 24 else ""
        folders = "<br>".join(esc(f) for f in sorted(e["folders"])[:3])
        cards.append(f"""
<section class="event {e['strength']}" data-cat="{esc(e['category'])}">
  <h2>{esc(e['category'])} · {esc(fmt_range(e))} <span class="dim">· {len(e['clips'])} clip(s) · {e['strength']}</span></h2>
  <p class="dim small">{folders}</p>
  <div class="clips">{''.join(clips)}</div>{more}
</section>""")
    chips = "".join(f'<button class="chip" data-cat="{esc(k)}">{esc(k)} ({v})</button>'
                    for k, v in sorted(stats["by_cat"].items(), key=lambda kv: -kv[1]))
    return f"""<!doctype html><html><head><meta charset="utf-8">
<title>Events prototype</title>
<style>
:root {{ --bg:#fbfaf7; --fg:#222; --dim:#777; --card:#fff; --line:#e4e0d8; --yes:#2e7d32; --no:#c62828; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#1b1a18; --fg:#eee; --dim:#999; --card:#252421; --line:#3a3833; }} }}
body {{ background:var(--bg); color:var(--fg); font:14px -apple-system, system-ui, sans-serif; margin:0 auto; max-width:1200px; padding:16px; }}
h1 {{ font-size:22px; margin:0 0 4px; }} h2 {{ font-size:17px; margin:0 0 4px; }}
.dim {{ color:var(--dim); }} .small {{ font-size:12px; }}
.event {{ background:var(--card); border:1px solid var(--line); border-radius:10px; padding:12px; margin:12px 0; }}
.event.weak {{ opacity:.85; }}
.clips {{ display:grid; grid-template-columns:repeat(auto-fill,minmax(260px,1fr)); gap:10px; }}
.clip {{ border:1px solid var(--line); border-radius:8px; overflow:hidden; }}
.clip img, .noimg {{ width:100%; aspect-ratio:16/9; object-fit:cover; display:block; background:#0002; }}
.noimg {{ display:flex; align-items:center; justify-content:center; color:var(--dim); }}
.meta {{ padding:6px 8px; }} .meta ul {{ margin:4px 0; padding-left:16px; font-size:12px; }}
.vote button {{ margin-right:6px; border:1px solid var(--line); background:transparent; color:var(--fg); border-radius:6px; padding:2px 8px; cursor:pointer; }}
.clip.yes {{ outline:3px solid var(--yes); }} .clip.no {{ outline:3px solid var(--no); opacity:.6; }}
.bar {{ position:sticky; top:0; background:var(--bg); padding:8px 0; border-bottom:1px solid var(--line); z-index:2; }}
.chip {{ border:1px solid var(--line); background:var(--card); color:var(--fg); border-radius:14px; padding:3px 10px; margin:2px; cursor:pointer; }}
.chip.on {{ background:var(--fg); color:var(--bg); }}
</style></head><body>
<h1>Events prototype v0 <span class="dim small">· local only · read-only · {esc(stats['when'])}</span></h1>
<p class="dim">{stats['clips']} unique clips with event evidence (copies collapsed by full SHA-256) → {len(events)} candidate events
 ({stats['strong']} strong). Evidence = Dossier scene captions (seen) + Whisper transcripts (said) + dates + folder names.
 Mark clips ✓/✗; your marks stay in this browser — “Export marks” saves them for scoring.</p>
<div class="bar"><button class="chip on" data-cat="">All</button>{chips}
 <label class="small"><input type="checkbox" id="strong"> strong only</label>
 <button class="chip" id="export">Export marks</button> <span id="tally" class="dim small"></span></div>
{''.join(cards)}
<script>
const KEY = 'events-v0-marks';
let marks = {{}}; try {{ marks = JSON.parse(localStorage.getItem(KEY) || '{{}}'); }} catch (e) {{}}
function paint() {{
  document.querySelectorAll('.clip').forEach(c => {{ c.classList.remove('yes','no'); const m = marks[c.dataset.id]; if (m) c.classList.add(m); }});
  const v = Object.values(marks); document.getElementById('tally').textContent = v.length ? `${{v.filter(x=>x==='yes').length}} ✓ · ${{v.filter(x=>x==='no').length}} ✗` : '';
}}
document.addEventListener('click', ev => {{
  const b = ev.target.closest('.vote button'); if (!b) return;
  const id = b.closest('.clip').dataset.id; marks[id] = marks[id] === b.dataset.v ? undefined : b.dataset.v;
  if (!marks[id]) delete marks[id]; try {{ localStorage.setItem(KEY, JSON.stringify(marks)); }} catch (e) {{}} paint();
}});
let cat = '', strongOnly = false;
function filter() {{ document.querySelectorAll('.event').forEach(e => {{
  e.style.display = ((!cat || e.dataset.cat === cat) && (!strongOnly || e.classList.contains('strong'))) ? '' : 'none'; }}); }}
document.querySelectorAll('.bar .chip[data-cat]').forEach(b => b.onclick = () => {{
  cat = b.dataset.cat; document.querySelectorAll('.bar .chip[data-cat]').forEach(x => x.classList.toggle('on', x === b)); filter(); }});
document.getElementById('strong').onchange = e => {{ strongOnly = e.target.checked; filter(); }};
document.getElementById('export').onclick = () => {{
  const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([JSON.stringify(marks, null, 1)], {{type:'application/json'}}));
  a.download = 'events-v0-marks.json'; a.click(); }};
paint();
</script></body></html>"""


def load_marks(downloads: Path | None = None) -> dict[str, str] | None:
    """Rick's marks from the newest Downloads/events-v0-marks*.json
    ("Category|contenthash" -> "yes" / "no"), or None when there is none."""
    folder = downloads if downloads is not None else DOWNLOADS
    try:
        files = sorted(folder.glob(MARKS_GLOB), key=lambda p: p.stat().st_mtime)
        if not files:
            return None
        data = json.loads(files[-1].read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    return {k: v for k, v in data.items() if isinstance(k, str) and v in ("yes", "no")}


def compute_stats(records: list[dict], clips: list[dict], events: list[dict],
                  marks: dict[str, str] | None, now: datetime | None = None) -> dict:
    """The --stats-json object: counts only. Category names are the CATEGORIES
    constants (a mark whose category is not one of them is ignored); no name,
    path, caption or transcript text is ever carried."""
    when = now or datetime.now(timezone.utc)
    by_category = {cat: 0 for cat in CATEGORIES}
    for e in events:
        by_category[e["category"]] += 1
    stats: dict = {
        "ts": when.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "active_records": len(records),
        "with_captions": sum(1 for r in records if r.get("sceneCaptions")),
        "with_transcripts": sum(1 for r in records if str(r.get("audioTranscript") or "").strip()),
        "clips_with_evidence": len(clips),
        "candidate_events": len(events),
        "strong_events": sum(1 for e in events if e["strength"] == "strong"),
        "by_category": by_category,
        "marks_yes": None, "marks_no": None, "precision_by_category": None,
    }
    if marks is not None:
        per_cat = {cat: {"yes": 0, "no": 0} for cat in CATEGORIES}
        for key, verdict in marks.items():
            cat = key.split("|", 1)[0]
            if cat in per_cat:
                per_cat[cat][verdict] += 1
        stats["marks_yes"] = sum(c["yes"] for c in per_cat.values())
        stats["marks_no"] = sum(c["no"] for c in per_cat.values())
        stats["precision_by_category"] = per_cat
    return stats


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--no-open", action="store_true")
    ap.add_argument("--stats-json", metavar="PATH",
                    help="also write counts only (no names, paths or text) to PATH for the metrics page")
    args = ap.parse_args(argv)
    records = load_records()
    clips = []
    for r in collapse_copies(records):
        ev = evidence(r)
        if not ev:
            continue
        r["_ev"], r["_cats"] = ev, list(ev)
        r["_date"], r["_dsrc"] = best_date(r)
        r["_thumb"] = preview_path(r["fullPath"])
        clips.append(r)
    events = group_events(clips)
    by_cat: dict[str, int] = defaultdict(int)
    for e in events:
        by_cat[e["category"]] += 1
    stats = {"clips": len(clips), "strong": sum(e["strength"] == "strong" for e in events),
             "by_cat": by_cat, "when": datetime.now().strftime("%b %-d %H:%M")}
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out = OUT_DIR / "index.html"
    out.write_text(render(events, stats), encoding="utf-8")
    thumbs = sum(1 for c in clips if c["_thumb"])
    print(f"{len(clips)} clips → {len(events)} candidate events ({stats['strong']} strong); "
          f"{thumbs} with a preview frame")
    for k, v in sorted(by_cat.items(), key=lambda kv: -kv[1]):
        print(f"   {k:22} {v} event(s)")
    print(out)
    if args.stats_json:
        stats = compute_stats(records, clips, events, load_marks())
        Path(args.stats_json).write_text(json.dumps(stats, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    if not args.no_open:
        subprocess.run(["open", str(out)], check=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
