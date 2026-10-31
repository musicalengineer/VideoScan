"""tools/video-llm-bench/bench.py — the review page (`watch`, `--keep-frames`).

No model, no media, no catalog: venv/bin/python3 -m pytest tests/test_video_llm_bench_review.py.
Rick 2026-10-31: "I wanna see it working in front of me, my dates, its dates" — one clip at a
time like the app's "Is Donna in this video?" sheet. Covers: frames kept under the run dir,
the page state as a pure function over the run records (truth, frames, rationale, cues,
error, tally), verdict recording (last wins, malformed skipped), the privacy guard (.scratch
only, loopback only), the server's routes (page, state, frames, traversal refused, verdict),
isolation against a corrupt clip file, and a scale check.
"""
from __future__ import annotations

import json
import threading
import time
import urllib.request
from pathlib import Path

import pytest

from test_video_llm_bench_a2 import FakeA2, bench, digest_for, entry, fake_ripper


def scratch_run(tmp_path: Path, entries, keep_frames=True, approach=None):
    out = tmp_path / ".scratch" / "bench" / "runs" / "review"
    out.mkdir(parents=True)
    (out / "run.json").write_text(json.dumps({"run_id": "r-review", "approach_id": "a2-py", "model_id": bench.A2_MODEL_ID}))
    bench.run_corpus_a1(entries, out, approach or FakeA2(), 6, {"run_id": "r-review"}, ripper=fake_ripper,
                        duration_of=lambda p, d: d, log=lambda s: None, ocr_sampler=bench.OCR_SAMPLER_STILLS,
                        keep_frames=keep_frames)
    return out


def manifest_for(entries):
    return {"clips": list(entries), "corpus_hash": "c" * 64, "seed": 1}


# ---------------------------------------------------------------------------
# --keep-frames
# ---------------------------------------------------------------------------
def test_keep_frames_leaves_the_frames_the_model_saw_under_the_run_dir(tmp_path):
    e = entry(digest_for(1))
    out = scratch_run(tmp_path, [e])
    frames = sorted((out / "frames" / e["digest"][:16]).glob("*.png"))
    assert len(frames) == 18, "3 windows × 6 frames stay on disk"
    assert frames[0].name == "w0_f000.png"
    header = bench.read_clip_records(bench.clip_file(out, e["digest"]))["header"]
    assert header["frames_dir"] == "frames/" + e["digest"][:16]
    # Without the flag nothing is left behind and the header does not claim frames.
    out2 = tmp_path / ".scratch" / "plain"
    out2.mkdir(parents=True)
    bench.run_corpus_a1([e], out2, FakeA2(), 6, {"run_id": "t"}, ripper=fake_ripper, duration_of=lambda p, d: d,
                        log=lambda s: None, ocr_sampler=bench.OCR_SAMPLER_STILLS)
    assert not (out2 / "frames").exists()
    assert "frames_dir" not in bench.read_clip_records(bench.clip_file(out2, e["digest"]))["header"]


# ---------------------------------------------------------------------------
# The page state
# ---------------------------------------------------------------------------
def test_review_state_shows_truth_frames_rationale_cues_and_error(tmp_path):
    e = entry(digest_for(2))                       # truth year 1991; FakeA2 answers 1991–1995 with a cue at 131 s
    out = scratch_run(tmp_path, [e])
    state = bench.review_state(out, manifest_for([e]))
    assert state["run_id"] == "r-review" and state["approach_id"] == "a2-py"
    assert len(state["clips"]) == 1
    c = state["clips"][0]
    assert c["name"] == Path(e["path"]).name and "/" not in c["name"], "the file NAME only, never its path"
    assert c["confirmed_year"] == 1991 and c["machine_range"] == [1991, 1995] and c["machine_midpoint"] == 1993
    assert c["error_years"] == 2.0 and c["inside"] is True and c["done"] is True and c["verdict"] is None
    assert len(c["windows"]) == 3
    w = c["windows"][0]
    assert [f["src"] for f in w["frames"]][:2] == ["frames/{}/w0_f000.png".format(e["digest"][:16]),
                                                   "frames/{}/w0_f001.png".format(e["digest"][:16])]
    era = next(a for a in w["answers"] if a["family"] == "era")
    assert era["valid"] and era["year_range"] == [1991, 1995] and era["rationale"].startswith("4:3")
    assert era["cues"][0]["text"] == "tracking lines" and era["cues"][0]["at_s"] == 131.0
    assert era["cues"][0]["frame"] == min(range(6), key=lambda i: abs(w["frames"][i]["at_s"] - 131.0))
    room = next(a for a in w["answers"] if a["family"] == "roomFeatures")
    assert room["valid"] and room["setting"] == "indoor" and "brick fireplace" in room["features"]
    t = state["tally"]
    assert t == {"clips_seen": 1, "clips_done": 1, "with_truth": 1, "within_5": 1, "within_10": 1, "inside_range": 1,
                 "mean_error_years": 2.0, "verdicts": {"model": 0, "mine": 0, "unsure": 0}}


def test_review_state_lists_clips_in_manifest_order_as_they_appear_and_skips_missing_or_corrupt(tmp_path):
    e1, e2, e3 = entry(digest_for(3)), entry(digest_for(4)), entry(digest_for(5))
    out = scratch_run(tmp_path, [e2])                                     # only e2 has run
    (out / "clips" / (e3["digest"] + ".jsonl")).write_text("not json\n{\"record_type\": \"result\"}\n")   # corrupt, no header
    state = bench.review_state(out, manifest_for([e1, e2, e3]))
    assert [c["digest"] for c in state["clips"]] == [e2["digest"]]
    assert state["tally"]["clips_seen"] == 1


def test_an_ocr_only_clip_has_no_era_but_shows_the_dates_it_read(tmp_path):
    e = entry(digest_for(6), corpus="ocr", stratum="ocr/dvvideo")
    out = scratch_run(tmp_path, [e])
    c = bench.review_state(out, manifest_for([e]))["clips"][0]
    assert c["machine_range"] is None and c["error_years"] is None and c["confirmed_date"] == "1991-06-21"
    assert c["ocr_dates"] == ["1991-06-21"] and c["windows"] == []


# ---------------------------------------------------------------------------
# Verdicts
# ---------------------------------------------------------------------------
def test_verdicts_last_wins_malformed_skipped_and_show_in_the_state(tmp_path):
    e = entry(digest_for(7))
    out = scratch_run(tmp_path, [e])
    rec = bench.write_verdict(out, e["digest"], "mine", {"confirmed_year": 1991, "machine_range": [1991, 1995], "run_id": "r"})
    assert rec["verdict"] == "mine" and rec["confirmed_year"] == 1991 and "at" in rec
    bench.write_verdict(out, e["digest"], "model")
    with (out / bench.VERDICTS_FILE).open("a") as f:
        f.write("garbage\n" + json.dumps({"digest": e["digest"], "verdict": "maybe"}) + "\n")
    assert bench.read_verdicts(out)[e["digest"]]["verdict"] == "model", "the last VALID line wins"
    assert bench.review_state(out, manifest_for([e]))["clips"][0]["verdict"] == "model"
    assert bench.review_state(out, manifest_for([e]))["tally"]["verdicts"] == {"model": 1, "mine": 0, "unsure": 0}
    with pytest.raises(ValueError):
        bench.write_verdict(out, e["digest"], "maybe")
    with pytest.raises(ValueError):
        bench.write_verdict(out, "../etc", "model")


# ---------------------------------------------------------------------------
# Privacy guard
# ---------------------------------------------------------------------------
def test_the_run_dir_must_be_under_scratch_and_the_server_stays_on_loopback(tmp_path):
    with pytest.raises(SystemExit):
        bench.assert_scratch_path(tmp_path / "runs" / "x")
    assert bench.assert_scratch_path(tmp_path / ".scratch" / "x") == (tmp_path / ".scratch" / "x").resolve()
    e = entry(digest_for(8))
    out = scratch_run(tmp_path, [e])
    with pytest.raises(SystemExit):
        bench.make_review_server(tmp_path / "elsewhere", manifest_for([e]), port=0)
    with pytest.raises(SystemExit):
        bench.make_review_server(out, manifest_for([e]), host="0.0.0.0", port=0)


# ---------------------------------------------------------------------------
# The server
# ---------------------------------------------------------------------------
@pytest.fixture
def served(tmp_path):
    e = entry(digest_for(9))
    out = scratch_run(tmp_path, [e])
    server = bench.make_review_server(out, manifest_for([e]), port=0)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = "http://127.0.0.1:{}".format(server.server_address[1])
    try:
        yield base, out, e
    finally:
        server.shutdown()
        server.server_close()


def get(url):
    with urllib.request.urlopen(url, timeout=5) as r:
        return r.status, r.headers.get("Content-Type", ""), r.read()


def test_server_serves_page_state_frames_and_refuses_traversal(served):
    base, out, e = served
    status, ctype, body = get(base + "/")
    assert status == 200 and ctype.startswith("text/html")
    page = body.decode()
    assert "Era review" in page and "Model is right" in page and "My date is right" in page and "Unsure" in page
    assert "/Users/" not in page and "/Volumes/" not in page
    status, ctype, body = get(base + "/state.json")
    assert status == 200 and ctype.startswith("application/json")
    state = json.loads(body)
    assert state["clips"][0]["digest"] == e["digest"]
    src = state["clips"][0]["windows"][0]["frames"][0]["src"]
    status, ctype, body = get(base + "/" + src)
    assert status == 200 and ctype == "image/png" and body.startswith(b"\x89PNG")
    for bad in ("/frames/../run.json", "/frames/../../run.json", "/run.json", "/frames/{}/w0_f000.txt".format(e["digest"][:16])):
        with pytest.raises(urllib.error.HTTPError) as err:
            get(base + bad)
        assert err.value.code == 404, bad


def test_server_records_a_verdict_and_refuses_a_bad_one(served):
    base, out, e = served
    req = urllib.request.Request(base + "/verdict", data=json.dumps({"digest": e["digest"], "verdict": "mine"}).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=5) as r:
        rec = json.loads(r.read())
    assert rec["verdict"] == "mine" and rec["confirmed_year"] == 1991 and rec["machine_range"] == [1991, 1995]
    assert rec["run_id"] == "r-review"
    assert bench.read_verdicts(out)[e["digest"]]["verdict"] == "mine"
    assert json.loads(get(base + "/state.json")[2])["clips"][0]["verdict"] == "mine"
    for payload in ({"digest": e["digest"], "verdict": "maybe"}, {"digest": "f" * 64, "verdict": "model"}, {}):
        req = urllib.request.Request(base + "/verdict", data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json"}, method="POST")
        with pytest.raises(urllib.error.HTTPError) as err:
            urllib.request.urlopen(req, timeout=5)
        assert err.value.code == 400


# ---------------------------------------------------------------------------
# Scale
# ---------------------------------------------------------------------------
def test_review_state_over_two_thousand_clips_is_quick(tmp_path):
    entries = [entry(digest_for(1000 + i)) for i in range(2000)]
    out = scratch_run(tmp_path, entries, keep_frames=False)
    started = time.perf_counter()
    state = bench.review_state(out, manifest_for(entries))
    elapsed = time.perf_counter() - started
    assert state["tally"]["clips_done"] == 2000
    assert elapsed < 20, "2,000 clips in {:.1f} s — the page polls this every 2 s".format(elapsed)
