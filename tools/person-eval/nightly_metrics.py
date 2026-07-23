#!/usr/bin/env python3
"""Produce privacy-safe nightly person-recognition metric fields.

The public metric distinguishes benchmark readiness from measured recognition
quality.  An unconfigured benchmark is intentionally readiness 0, while its
quality score remains null: "not measured" is not the same as 0% accurate.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import pathlib
import re
import signal
import subprocess
import sys
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_CYCLE_METRICS = ROOT / "docs" / "poi-cycles" / "metrics.jsonl"


def score_band(value: float | int | None) -> str:
    """Return Rick's dashboard band, clamping hostile/out-of-range input."""
    try:
        score = float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return "red"
    if score != score:  # NaN
        return "red"
    score = max(0.0, min(100.0, score))
    if score < 25:
        return "red"
    if score < 50:
        return "yellow"
    if score < 80:
        return "orange"
    return "green"


def _base(status: str, reason: str, readiness: int) -> dict[str, Any]:
    return {
        "person_eval_status": status,
        "person_eval_reason": reason,
        "person_eval_readiness_pct": readiness,
        "person_eval_readiness_band": score_band(readiness),
        "person_eval_publish_eligible": False,
        "person_eval_quality_score": None,
        "person_eval_quality_band": None,
        "person_eval_identity_precision": None,
        "person_eval_identity_recall": None,
        "person_eval_face_recall": None,
        "person_eval_segment_precision": None,
        "person_eval_segment_recall": None,
        "person_eval_false_positives": None,
        "person_eval_false_negatives": None,
        "person_eval_case_count": 0,
        "person_eval_engine": None,
        "person_eval_dataset_version": None,
        "person_eval_elapsed_s": None,
        "person_eval_peak_rss_mb": None,
        "person_eval_generated_at": None,
    }


def metrics_for(
    manifest: dict[str, Any] | None,
    report: dict[str, Any] | None = None,
    run_error: str | None = None,
    allow_quality: bool = False,
) -> dict[str, Any]:
    if manifest is None:
        return _base("not-configured", "quality-holdout-not-configured", 0)

    publication = manifest.get("publication", {})
    intends_quality = (
        publication.get("tier") == "quality"
        and publication.get("holdout") is True
        and bool(publication.get("datasetVersion"))
    )
    if run_error:
        readiness = 75 if intends_quality else 25
        return _base("run-failed", run_error, readiness)
    if report is None:
        return _base("configured", "quality-manifest-awaiting-live-run", 25)

    report_eligible = report.get("publishEligible") is True
    eligible = report_eligible and allow_quality
    readiness = 100 if eligible else (75 if intends_quality else 50)
    if eligible:
        status, reason = "measured", ""
    elif report_eligible:
        status, reason = "quality-awaiting-approval", "quality-publication-provenance-gate-closed"
    else:
        status, reason = "development-only", "quality-report-ineligible"
    row = _base(status, reason, readiness)
    row.update({
        "person_eval_publish_eligible": eligible,
        "person_eval_case_count": int(report.get("caseCount") or 0),
        "person_eval_engine": _safe_engine(report.get("engine")),
        "person_eval_dataset_version": _safe_dataset_version(report.get("datasetVersion")),
        "person_eval_elapsed_s": report.get("performance", {}).get("elapsedSeconds"),
        "person_eval_peak_rss_mb": report.get("performance", {}).get("peakRSSMB"),
        "person_eval_generated_at": report.get("generatedAt"),
    })
    if not eligible:
        return row

    identity = report.get("identityPresence", {})
    face = report.get("facePresence", {})
    segment = report.get("segment", {})
    score = report.get("score")
    row.update({
        "person_eval_quality_score": score,
        "person_eval_quality_band": score_band(score),
        "person_eval_identity_precision": identity.get("precision"),
        "person_eval_identity_recall": identity.get("recall"),
        "person_eval_face_recall": face.get("recall"),
        "person_eval_segment_precision": segment.get("precision"),
        "person_eval_segment_recall": segment.get("recall"),
        "person_eval_false_positives": identity.get("fp"),
        "person_eval_false_negatives": identity.get("fn"),
    })
    return row


def _safe_engine(value: Any) -> str | None:
    known = {"vision": "Vision", "arcface": "ArcFace", "dlib": "dlib", "hybrid": "Hybrid"}
    return known.get(str(value or "").lower())


def _safe_dataset_version(value: Any) -> str | None:
    text = str(value or "")
    return text if re.fullmatch(r"[A-Za-z0-9._-]{1,64}", text) else None


def _load_json(path: pathlib.Path) -> dict[str, Any]:
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError("JSON root must be an object")
    return value


def cycle_metrics_for(path: pathlib.Path) -> dict[str, Any]:
    """Validate the canonical cycle stream and expose only honest daily state."""
    empty = {
        "poi_cycle_count": 0,
        "poi_cycle_latest_label": None,
        "poi_cycle_latest_evidence_tier": None,
        "poi_cycle_latest_verdict": None,
        "poi_cycle_production_label": None,
        "poi_cycle_production_commit": None,
        "poi_cycle_production_balanced_accuracy": None,
        "poi_cycle_production_precision": None,
        "poi_cycle_production_recall": None,
        "poi_cycle_production_f1": None,
    }
    if not path.exists():
        return {"poi_cycle_stream_status": "missing", **empty}
    try:
        module_path = ROOT / "scripts" / "publish_poi_cycle_metrics.py"
        spec = importlib.util.spec_from_file_location("poi_cycle_metrics_validator", module_path)
        if spec is None or spec.loader is None:
            raise ImportError("cycle metrics validator unavailable")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        rows = module.load_and_validate(path)
        return module.nightly_summary(rows)
    except (OSError, ValueError, ImportError, json.JSONDecodeError):
        return {"poi_cycle_stream_status": "invalid", **empty}


def collect(
    manifest_path: pathlib.Path,
    app_path: pathlib.Path | None,
    report_path: pathlib.Path,
    timeout_seconds: float,
    allow_quality: bool = False,
) -> dict[str, Any]:
    if not manifest_path.exists():
        return metrics_for(None)
    try:
        manifest = _load_json(manifest_path)
    except (OSError, ValueError, json.JSONDecodeError):
        return metrics_for({}, run_error="quality-manifest-invalid")
    if app_path is None:
        return metrics_for(manifest)
    if not app_path.exists():
        return metrics_for(manifest, run_error="evaluation-app-not-built")

    report_path.parent.mkdir(parents=True, exist_ok=True)
    markdown_path = report_path.with_suffix(".md")
    evaluator = pathlib.Path(__file__).with_name("person_eval.py")
    try:
        process = subprocess.Popen(
            [sys.executable, str(evaluator), str(manifest_path),
             "--app", str(app_path), "--json", str(report_path),
             "--markdown", str(markdown_path)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            start_new_session=True,
        )
        process.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        # The evaluator owns a VideoScan child. Kill the entire process group
        # so a timed-out nightly cannot leave scanners chewing through media.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
        return metrics_for(manifest, run_error="evaluation-timeout")
    if process.returncode != 0:
        return metrics_for(manifest, run_error=f"evaluation-exit-{process.returncode}")
    try:
        report = _load_json(report_path)
    except (OSError, ValueError, json.JSONDecodeError):
        return metrics_for(manifest, run_error="evaluation-report-invalid")
    return metrics_for(manifest, report, allow_quality=allow_quality)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=pathlib.Path, required=True)
    parser.add_argument("--app", type=pathlib.Path)
    parser.add_argument("--report", type=pathlib.Path, required=True)
    parser.add_argument("--timeout-seconds", type=float, default=1_200)
    parser.add_argument("--allow-quality", action="store_true",
                        help="publish eligible quality fields after provenance review")
    parser.add_argument("--cycle-metrics", type=pathlib.Path,
                        default=DEFAULT_CYCLE_METRICS)
    args = parser.parse_args(argv)
    row = collect(args.manifest.expanduser().resolve(),
                  args.app.expanduser().resolve() if args.app else None,
                  args.report.expanduser().resolve(), args.timeout_seconds,
                  allow_quality=args.allow_quality)
    row.update(cycle_metrics_for(args.cycle_metrics.expanduser().resolve()))
    print(json.dumps(row, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
