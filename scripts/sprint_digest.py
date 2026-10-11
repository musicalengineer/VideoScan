#!/usr/bin/env python3
"""Morning digest lines for the weekly sprint (Rick 2026-10-11).

Prints the open "Week of …" milestone's progress (done / total, days left,
what's still open) and the top 3 open `bug` issues. Read-only; quiet and
exit 0 on any failure, so the digest never breaks on a network hiccup.
"""
import datetime
import json
import subprocess
import sys

REPO = "musicalengineer/VideoScan"


def gh(*args):
    r = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=20)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip())
    return json.loads(r.stdout)


def sprint_lines():
    milestones = gh("api", f"repos/{REPO}/milestones?state=open&per_page=50")
    weeks = [m for m in milestones if m["title"].startswith("Week of")]
    if not weeks:
        return ["Sprint: no open \"Week of …\" milestone — draft next week's picks."]
    m = min(weeks, key=lambda w: w.get("due_on") or "9999")
    done, still = m["closed_issues"], m["open_issues"]
    total = done + still
    left = ""
    if m.get("due_on"):
        due = datetime.datetime.fromisoformat(m["due_on"].replace("Z", "+00:00")).date()
        days = (due - datetime.date.today()).days
        left = f" · {days} day(s) left" if days >= 0 else f" · {-days} day(s) OVERDUE — time for the review"
    lines = [f"Sprint \"{m['title']}\": {done} of {total} done{left}"]
    issues = gh("issue", "list", "-R", REPO, "--milestone", m["title"], "--state", "open",
                "--json", "number,title", "--limit", "20")
    lines += [f"   • #{i['number']} {i['title'][:80]}" for i in issues]
    return lines


def bug_lines():
    bugs = gh("issue", "list", "-R", REPO, "--label", "bug", "--state", "open",
              "--json", "number,title,updatedAt", "--limit", "100")
    if not bugs:
        return ["Top bugs: none open."]
    bugs.sort(key=lambda b: b["updatedAt"], reverse=True)
    return ["Top bugs (most recently active):"] + [f"   • #{b['number']} {b['title'][:80]}" for b in bugs[:3]]


def main():
    try:
        out = sprint_lines() + bug_lines()
    except Exception as exc:  # network, auth, schema: never break the digest
        out = [f"(sprint digest unavailable: {exc})"[:200]]
    print("\n── Sprint ──")
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
