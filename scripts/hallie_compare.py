#!/usr/bin/env python3
"""Run one Hallie corpus on several brains and put them side by side.

Rick, 2026-11-15: "we should have the ability for the hallie testbed to change
the engines/models so we can compare large corpi and see how it handles
questions ... maybe we should have a table showing pros and cons of things
like speed, natural language handling of complex questions, ability to search
catalog versus FT".

  scripts/hallie_compare.py run --brains qwen3.8:27b-mlx,llama3.3:70b \\
      [--corpus tests/hallie_strict_regressions.json] [--limit N] [--out-dir DIR]
  scripts/hallie_compare.py run --brains cloud:claude-sonnet-5-5 --allow-cloud
  scripts/hallie_compare.py table DIR

A brain is a local Ollama tag, or `cloud:<model>` for the Cloud brain on that
model. Each brain gets its own full replay through the real headless shell
(scripts/hallie_eval.py run), one after another, never two at once. A local
model is unloaded from Ollama after its run (--keep-loaded leaves it), so the
next brain does not share memory with it.

`table` reads the runs in DIR and writes two files there:
  table.md    one row per brain: answered clean, Family Tree / catalog /
              conversation questions clean, declines, how often the model (not
              the template) phrased the answer, failures, median and p90 time.
  answers.md  every question with each brain's own words under it — how
              natural an answer reads is judged by reading it; no column here
              measures that.

What the numbers are: hallie_eval.py's grading, the same rules as the nightly
replay. Advisory unless the corpus is the reviewed strict one.

Cloud brains: every question, and the family facts used to phrase its answer,
go to Anthropic, and each one is billed. `run` refuses a `cloud:` brain without
--allow-cloud. Nothing here reads or writes the app's brain settings.

Output holds family data: the default --out-dir is under .scratch/ (ignored by
git). Do not point it at a tracked folder.

Exit: 0 every brain's replay completed · 2 a replay was incomplete, a brain was
skipped, or usage · `table` exits 0 when it wrote the files.

Tests: tests/test_hallie_compare.py (no model, no network, no app binary).
"""

import argparse
import importlib.util
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
EVAL = REPO / "scripts/hallie_eval.py"
CLOUD_PREFIX = "cloud:"
DEFAULT_HOST = "http://127.0.0.1:11434"
DEFAULT_CORPUS = REPO / "tests/hallie_strict_regressions.json"

# Which side of the archive a question is about, by the route it should take
# (or took, when the corpus names none).
SIDES = {
    "graph": "tree", "record": "tree", "telling": "tree",
    "presence": "catalog", "temporal": "catalog", "aggregate": "catalog",
    "cross": "catalog", "event": "catalog", "followUp": "catalog",
    "smalltalk": "talk", "conversation": "talk", "help": "talk",
    "capability": "talk", "reset": "talk",
}
SIDE_TITLES = [("tree", "Family Tree"), ("catalog", "Catalog"), ("talk", "Conversation")]


def load_eval():
    spec = importlib.util.spec_from_file_location("hallie_eval", EVAL)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# ---------------------------------------------------------------- brains

def parse_brains(text):
    """'a, cloud:b' -> [{'label','kind','model'}], order kept, duplicates refused."""
    brains, seen = [], set()
    for raw in (text or "").split(","):
        name = raw.strip()
        if not name:
            continue
        if name.lower().startswith(CLOUD_PREFIX):
            model = name[len(CLOUD_PREFIX):].strip()
            if not model:
                raise ValueError("cloud: needs a model, e.g. cloud:claude-sonnet-5-5")
            brain = {"label": f"Cloud · {model}", "kind": "cloud", "model": model}
        else:
            brain = {"label": name, "kind": "local", "model": name}
        if brain["label"] in seen:
            raise ValueError(f"brain listed twice: {name}")
        seen.add(brain["label"])
        brains.append(brain)
    if not brains:
        raise ValueError("no brains named; pass --brains a,b,cloud:c")
    return brains


def slug(label):
    return re.sub(r"[^A-Za-z0-9._-]+", "-", label).strip("-") or "brain"


def installed_tags(host, timeout=10):
    """The tags this Ollama lists, or None when it does not answer."""
    try:
        with urllib.request.urlopen(host.rstrip("/") + "/api/tags", timeout=timeout) as reply:
            data = json.loads(reply.read().decode("utf-8"))
    except (OSError, ValueError, urllib.error.URLError):
        return None
    return [m.get("name", "") for m in data.get("models", [])]


def unload(host, model, timeout=30):
    """Ask Ollama to drop the model (keep_alive 0) so the next brain does not
    share memory with it. Best effort: True when the server took the request."""
    body = json.dumps({"model": model, "keep_alive": 0}).encode("utf-8")
    request = urllib.request.Request(host.rstrip("/") + "/api/generate", data=body,
                                     headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout):
            return True
    except (OSError, urllib.error.URLError):
        return False


def eval_command(brain, args, out):
    cmd = [sys.executable, str(EVAL), "run", "--corpus", str(args.corpus), "--out", str(out),
           "--timeout", str(args.timeout)]
    if brain["kind"] == "cloud":
        cmd += ["--cloud-model", brain["model"]]
    else:
        cmd += ["--model", brain["model"]]
        if args.host:
            cmd += ["--host", args.host]
    for flag, value in (("--limit", args.limit), ("--bin", args.bin), ("--gedcom", args.gedcom)):
        if value:
            cmd += [flag, str(value)]
    return cmd


def announce(line):
    """Flushed, so START/OUTCOME stay in order with the replay's own output."""
    print(line, flush=True)


def run(args, *, tags=installed_tags, call=subprocess.run, say=announce, release=unload):
    brains = parse_brains(args.brains)
    cloud = [b["label"] for b in brains if b["kind"] == "cloud"]
    if cloud and not args.allow_cloud:
        say("refused: " + ", ".join(cloud) + " — a cloud brain sends every question and the "
            "family facts behind its answer to Anthropic, and each one is billed. "
            "Pass --allow-cloud to run it.")
        return 2
    out_dir = Path(args.out_dir or REPO / ".scratch/hallie-compare" / time.strftime("%Y%m%d_%H%M%S"))
    out_dir.mkdir(parents=True, exist_ok=True)
    host = args.host or DEFAULT_HOST
    local_tags = tags(host) if any(b["kind"] == "local" for b in brains) else []
    status = 0
    for brain in brains:
        out = out_dir / f"{slug(brain['label'])}.jsonl"
        note = out_dir / f"{slug(brain['label'])}.brain.json"
        record = dict(brain, run=out.name)
        if brain["kind"] == "local" and (local_tags is None or brain["model"] not in local_tags):
            record["skipped"] = (f"{host} did not answer" if local_tags is None
                                 else f"{host} does not have this model")
            say(f"SKIPPED {brain['label']}: {record['skipped']}")
            note.write_text(json.dumps(record) + "\n", encoding="utf-8")
            status = 2
            continue
        say(f"START {brain['label']} → {out}")
        t0 = time.time()
        code = call(eval_command(brain, args, out), cwd=str(REPO)).returncode
        record["exit"] = code
        record["seconds"] = round(time.time() - t0)
        note.write_text(json.dumps(record) + "\n", encoding="utf-8")
        say(f"OUTCOME {brain['label']} {'complete' if code == 0 else f'INCOMPLETE (exit {code})'} "
            f"in {record['seconds']} s")
        if code != 0:
            status = 2
        if brain["kind"] == "local" and not args.keep_loaded:
            release(host, brain["model"])
    table(argparse.Namespace(dir=str(out_dir)), say=say)
    return status


# ---------------------------------------------------------------- table

def side_of(record):
    expected = record.get("expectedRoutes") or []
    for route in list(expected) + [record.get("route")]:
        if route in SIDES:
            return SIDES[route]
    return None


def read_run(path):
    with open(path, encoding="utf-8") as f:
        lines = [json.loads(line) for line in f if line.strip()]
    if not lines or "meta" not in lines[0]:
        raise ValueError(f"{path} is not a hallie_eval run (no meta line)")
    return lines[0]["meta"], lines[1:]


def measure(records, grade_record, latency_summary):
    """The numbers for one brain's records. Pure."""
    row = {"turns": len(records), "clean": 0, "declined": 0, "failed": 0,
           "composable": 0, "by_model": 0, "sides": {}, "flags": {}, "defect_ids": []}
    for r in records:
        flags = grade_record(r)
        defects = [f for f in flags if not f.startswith("~")]
        for f in defects:
            row["flags"][f] = row["flags"].get(f, 0) + 1
        clean = not defects
        row["clean"] += clean
        if not clean:
            row["defect_ids"].append(r.get("id"))
        side = side_of(r)
        if side:
            s = row["sides"].setdefault(side, {"n": 0, "clean": 0})
            s["n"] += 1
            s["clean"] += clean
        if r.get("outcome") == "declined":
            row["declined"] += 1
        # No route at all = the turn never got as far as an answer (the brain
        # call failed, timed out or was refused).
        if not r.get("route"):
            row["failed"] += 1
        if r.get("composedBy") in ("model", "template"):
            row["composable"] += 1
            row["by_model"] += r["composedBy"] == "model"
    row["latency"] = latency_summary(records)
    return row


def collect(directory, hallie_eval):
    """[(brain record, meta or None, measured row or None)] in run order."""
    directory = Path(directory)
    notes = sorted(directory.glob("*.brain.json"), key=lambda p: p.stat().st_mtime)
    brains = [json.loads(p.read_text(encoding="utf-8")) for p in notes]
    known = {b["run"] for b in brains}
    # A run dropped in by hand (hallie_eval.py run --out DIR/x.jsonl) counts too.
    for path in sorted(directory.glob("*.jsonl")):
        if path.name not in known and not path.name.endswith(".graded.jsonl"):
            brains.append({"label": path.stem, "run": path.name})
    rows = []
    for brain in brains:
        path = directory / brain["run"]
        if brain.get("skipped") or not path.exists():
            rows.append((brain, None, None))
            continue
        meta, records = read_run(path)
        rows.append((brain, meta, dict(
            measure(records, hallie_eval.grade_record, hallie_eval.latency_summary),
            records=records)))
    return rows


def pct(part, whole):
    return "—" if not whole else f"{part} of {whole} ({100 * part / whole:.0f}%)"


def seconds(ms):
    return "—" if ms is None else f"{ms / 1000:.1f} s"


def render_table(rows):
    head = ["Brain", "Asked", "Clean", "Family Tree", "Catalog", "Conversation",
            "Declined", "Phrased by the model", "No answer", "Median", "p90", "Most common defects"]
    lines = ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    for brain, meta, row in rows:
        if row is None:
            why = brain.get("skipped", "no run file")
            lines.append(f"| {brain['label']} | not run: {why} |" + " — |" * (len(head) - 2))
            continue
        asked = meta.get("questions") or row["turns"]
        cells = [brain["label"],
                 str(asked) + ("" if row["turns"] == asked else f" ({row['turns']} answered — INCOMPLETE)"),
                 pct(row["clean"], row["turns"])]
        for key, _ in SIDE_TITLES:
            s = row["sides"].get(key, {"n": 0, "clean": 0})
            cells.append(pct(s["clean"], s["n"]))
        top = sorted(row["flags"].items(), key=lambda kv: (-kv[1], kv[0]))[:3]
        cells += [pct(row["declined"], row["turns"]),
                  pct(row["by_model"], row["composable"]),
                  str(row["failed"]),
                  seconds(row["latency"]["median_ms"]),
                  seconds(row["latency"]["p90_ms"]),
                  ", ".join(f"{name} ×{n}" for name, n in top) or "none"]
        lines.append("| " + " | ".join(cells) + " |")
    return "\n".join(lines)


NOTES = """
How to read it
- **Clean** = no grading defect (scripts/hallie_eval.py; the nightly replay's rules). On any corpus but the reviewed strict one this is advisory: a signal, not proof of a right answer.
- **Family Tree / Catalog / Conversation** = the same count, split by the side of the archive the question is about (the route the corpus expects, else the route taken).
- **Phrased by the model** = of the answers that could be phrased, how many the brain worded itself; the rest fell back to the fixed template (verifier rejected the wording, or the brain ran out of time). A proxy for natural speech, not a measure of it — read answers.md.
- **No answer** = turns with no route: the brain call failed, timed out or was refused.
- **Median / p90** = time from question to answer, per question. A local brain's first question may include loading the model.
- Runs on different machines, builds or corpora are not comparable; the provenance lines below say what each row ran on.
"""


def render_provenance(rows):
    lines = []
    for brain, meta, row in rows:
        if row is None:
            continue
        lines.append(f"- {brain['label']}: git {meta.get('git', '?')}, binary built "
                     f"{meta.get('binary_built', '?')}, corpus {str(meta.get('corpusSHA256') or '?')[:12]}, "
                     f"run {meta.get('when', '?')}, {meta.get('elapsed_s', '?')} s in all")
    return "\n".join(lines)


def render_answers(rows, limit=400):
    """Every question, each brain's words under it; defects marked."""
    ran = [(brain, row) for brain, _, row in rows if row is not None]
    order, by_brain = [], {}
    for brain, row in ran:
        answers = {}
        for r in row["records"]:
            answers[r.get("id")] = r
            if r.get("id") not in order:
                order.append(r.get("id"))
        by_brain[brain["label"]] = (answers, set(row["defect_ids"]))
    out = ["# Hallie brains, answer by answer", "",
           "Family data. Keep this file out of git and out of anything shared.", ""]
    for qid in order:
        question = next((a[qid].get("question") for a, _ in by_brain.values() if qid in a), "")
        out.append(f"## {qid} — {question}")
        for label, (answers, defects) in by_brain.items():
            r = answers.get(qid)
            if r is None:
                out.append(f"- **{label}** — no answer recorded")
                continue
            text = " ".join((r.get("answer") or "").split())
            if len(text) > limit:
                text = text[:limit] + " …"
            mark = "DEFECT" if qid in defects else "clean"
            took = seconds(r.get("latencyMs"))
            out.append(f"- **{label}** ({mark}, {r.get('route') or 'no route'}, "
                       f"{r.get('composedBy') or 'not phrased'}, {took}): {text}")
        out.append("")
    return "\n".join(out)


def table(args, *, say=announce):
    hallie_eval = load_eval()
    directory = Path(args.dir)
    rows = collect(directory, hallie_eval)
    if not rows:
        say(f"no runs in {directory}")
        return 2
    text = render_table(rows)
    (directory / "table.md").write_text(
        "# Hallie brains compared\n\n" + text + "\n" + NOTES + "\nProvenance\n"
        + render_provenance(rows) + "\n", encoding="utf-8")
    (directory / "answers.md").write_text(render_answers(rows) + "\n", encoding="utf-8")
    say(text)
    say(f"\ntable → {directory / 'table.md'}\nanswers → {directory / 'answers.md'}")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    pr = sub.add_parser("run", help="replay the corpus on each brain, then write the table")
    pr.add_argument("--brains", required=True,
                    help="comma-separated: local Ollama tags and/or cloud:<model>")
    pr.add_argument("--corpus", default=str(DEFAULT_CORPUS))
    pr.add_argument("--limit", type=int, help="only the first N questions")
    pr.add_argument("--out-dir", help="default: .scratch/hallie-compare/<stamp>")
    pr.add_argument("--host", help=f"the local brains' Ollama (default {DEFAULT_HOST})")
    pr.add_argument("--bin", help="pin this VideoScan binary (default: newest built)")
    pr.add_argument("--gedcom")
    pr.add_argument("--timeout", type=int, default=5400, help="seconds per brain")
    pr.add_argument("--keep-loaded", action="store_true",
                    help="do not ask Ollama to unload each local model after its run")
    pr.add_argument("--allow-cloud", action="store_true",
                    help="permit cloud: brains (questions and answer facts go to Anthropic; billed)")
    pr.set_defaults(func=run)
    pt = sub.add_parser("table", help="rebuild table.md and answers.md from the runs in DIR")
    pt.add_argument("dir")
    pt.set_defaults(func=table)
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except ValueError as error:
        print(f"hallie_compare: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
