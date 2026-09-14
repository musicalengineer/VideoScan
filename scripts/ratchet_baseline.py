#!/usr/bin/env python3
"""Grandfathered-baseline plumbing shared by the nightly source ratchets.

The philosophy is a lint ratchet, not a refactor mandate: today's hits are
recorded once, reported forever as *pre-existing*, and the build only goes red
on a NEW violation or on a baseline entry whose hit count GREW.

Baseline keys deliberately exclude line numbers. A key is

    rule_id | repo-relative path | signature

where `signature` is a normalised fragment of the offending code. Inserting
twenty lines at the top of a file must not resurrect every finding in it as
"new"; editing the offending line itself should.

Value stored per key is the hit count, so a second copy of an existing bad
pattern in the same file is caught even though the key already exists.
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, asdict
from typing import Dict, Iterable, List, Tuple

BASELINE_DIR = os.path.join("ci", "baselines")


@dataclass(frozen=True)
class Finding:
    rule: str
    path: str
    line: int
    signature: str
    message: str
    severity: str = "warning"   # "warning" | "error"

    @property
    def key(self) -> str:
        return f"{self.rule}|{self.path}|{self.signature}"

    def as_dict(self) -> dict:
        return asdict(self)


_WS = re.compile(r"\s+")


def normalise_signature(code: str, max_len: int = 160) -> str:
    """Collapse whitespace and trim so a reflow doesn't read as a new finding."""
    return _WS.sub(" ", code).strip()[:max_len]


def load_baseline(path: str) -> Dict[str, int]:
    if not os.path.exists(path):
        return {}
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    return {str(k): int(v) for k, v in data.get("entries", {}).items()}


def write_baseline(path: str, findings: Iterable[Finding], note: str = "") -> Dict[str, int]:
    entries: Dict[str, int] = {}
    for finding in findings:
        entries[finding.key] = entries.get(finding.key, 0) + 1
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    payload = {
        "note": note or (
            "Grandfathered baseline. Regenerate deliberately with --update-baseline "
            "and explain the delta in the commit message."
        ),
        "entry_count": len(entries),
        "hit_count": sum(entries.values()),
        "entries": dict(sorted(entries.items())),
    }
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=False)
        handle.write("\n")
    return entries


def partition(findings: List[Finding],
              baseline: Dict[str, int]) -> Tuple[List[Finding], List[Finding]]:
    """Split findings into (new_or_grown, pre_existing).

    A key present in the baseline contributes `baseline[key]` grandfathered
    hits; anything beyond that count is new.
    """
    remaining = dict(baseline)
    new: List[Finding] = []
    old: List[Finding] = []
    for finding in findings:
        allowance = remaining.get(finding.key, 0)
        if allowance > 0:
            remaining[finding.key] = allowance - 1
            old.append(finding)
        else:
            new.append(finding)
    return new, old


def fixed_keys(findings: List[Finding], baseline: Dict[str, int]) -> List[str]:
    """Baseline keys nobody hit any more — candidates for baseline shrinkage."""
    seen = {f.key for f in findings}
    return sorted(k for k in baseline if k not in seen)


def markdown_report(title: str,
                    new: List[Finding],
                    old: List[Finding],
                    fixed: List[str],
                    rule_docs: Dict[str, str],
                    detail_limit: int = 50) -> str:
    """Render the GITHUB_STEP_SUMMARY block, matching the workflow's idiom:
    a count table first, then collapsed <details> for the listings."""
    lines: List[str] = [f"## {title}", ""]
    by_rule: Dict[str, List[Finding]] = {}
    for finding in new + old:
        by_rule.setdefault(finding.rule, []).append(finding)

    lines.append("| Rule | New | Pre-existing (grandfathered) |")
    lines.append("|---|---:|---:|")
    for rule in sorted(by_rule):
        n_new = sum(1 for f in new if f.rule == rule)
        n_old = sum(1 for f in old if f.rule == rule)
        lines.append(f"| `{rule}` | {n_new} | {n_old} |")
    lines.append(f"| **Total** | **{len(new)}** | **{len(old)}** |")
    lines.append("")

    if not new:
        lines.append("✅ **No new violations.**")
    else:
        lines.append(f"❌ **{len(new)} NEW violation(s).** These fail the job.")
    lines.append("")

    if new:
        lines.append(f"<details open><summary>New violations ({len(new)})</summary>")
        lines.append("")
        lines.append("```")
        for finding in new[:detail_limit]:
            lines.append(f"{finding.path}:{finding.line}: {finding.rule}: {finding.message}")
        if len(new) > detail_limit:
            lines.append(f"... ({len(new) - detail_limit} more — see artifact)")
        lines.append("```")
        lines.append("")
        shown = {f.rule for f in new}
        for rule in sorted(shown):
            if rule in rule_docs:
                lines.append(f"**`{rule}`** — {rule_docs[rule]}")
                lines.append("")
        lines.append("</details>")
        lines.append("")

    if old:
        lines.append(f"<details><summary>Pre-existing, grandfathered ({len(old)})</summary>")
        lines.append("")
        lines.append("```")
        for finding in old[:detail_limit]:
            lines.append(f"{finding.path}:{finding.line}: {finding.rule}: {finding.message}")
        if len(old) > detail_limit:
            lines.append(f"... ({len(old) - detail_limit} more — see artifact)")
        lines.append("```")
        lines.append("")
        lines.append("</details>")
        lines.append("")

    if fixed:
        lines.append(
            f"🎉 {len(fixed)} baseline entr{'y' if len(fixed) == 1 else 'ies'} no longer hit — "
            "rerun with `--update-baseline` to lock the improvement in."
        )
        lines.append("")

    return "\n".join(lines)


def emit(summary_markdown: str, json_path: str, findings_new: List[Finding],
         findings_old: List[Finding]) -> None:
    """Write the step summary (if running under Actions) and the artifact JSON."""
    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        with open(step_summary, "a", encoding="utf-8") as handle:
            handle.write(summary_markdown)
            handle.write("\n")
    print(summary_markdown)
    if json_path:
        os.makedirs(os.path.dirname(json_path) or ".", exist_ok=True)
        with open(json_path, "w", encoding="utf-8") as handle:
            json.dump(
                {
                    "new": [f.as_dict() for f in findings_new],
                    "pre_existing": [f.as_dict() for f in findings_old],
                    "new_count": len(findings_new),
                    "pre_existing_count": len(findings_old),
                },
                handle,
                indent=2,
            )
            handle.write("\n")


def set_output(name: str, value) -> None:
    """`echo "k=v" >> $GITHUB_OUTPUT`, the workflow's existing idiom."""
    target = os.environ.get("GITHUB_OUTPUT")
    if not target:
        return
    with open(target, "a", encoding="utf-8") as handle:
        handle.write(f"{name}={value}\n")
