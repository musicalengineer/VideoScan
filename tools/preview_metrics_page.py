#!/usr/bin/env python3
"""Preview docs/index.html locally with TODAY's tree measured, before anything is published.

The page normally reads the public `metrics` branch. This builds a throw-away
folder with the page, the branch's metrics files (from the local
origin/metrics ref: no fetch, no push), a fresh complexity row for the working
tree (with the per-module `modules` field), and the per-module history
(scripts/complexity_backfill.py --modules --no-publish), then serves it.

    venv/bin/python3 tools/preview_metrics_page.py            # build + serve on :8777
    venv/bin/python3 tools/preview_metrics_page.py --no-serve --out /tmp/x
    then open http://localhost:8777/index.html?local          (?local = never read GitHub)

Needs lizard (the repo venv has it). About 40 s of CPU, mostly the 60-day
module backfill; --skip-backfill keeps only the published modules.jsonl.
Nothing in the repo is written.
"""
from __future__ import annotations

import argparse
import functools
import http.server
import io
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default="", help="folder to build into (default: a new temp folder)")
    ap.add_argument("--ref", default="origin/metrics", help="where the published metrics files come from")
    ap.add_argument("--port", type=int, default=8777)
    ap.add_argument("--skip-backfill", action="store_true")
    ap.add_argument("--no-serve", action="store_true")
    a = ap.parse_args()

    out = Path(a.out).expanduser() if a.out else Path(tempfile.mkdtemp(prefix="vs-metrics-preview-"))
    out.mkdir(parents=True, exist_ok=True)
    blob = subprocess.run(["git", "-C", str(REPO), "archive", "--format=tar", a.ref, "metrics"],
                          capture_output=True, check=True).stdout
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:") as tar:
        for m in tar.getmembers():
            if m.isfile():
                (out / Path(m.name).name).write_bytes(tar.extractfile(m).read())
    shutil.copy(REPO / "docs" / "index.html", out / "index.html")

    row = out / "complexity-row.json"
    subprocess.run([sys.executable, str(REPO / "scripts" / "complexity_metrics.py"), "--root", str(REPO),
                    "--row-out", str(row)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with open(out / "complexity.jsonl", "a", encoding="utf-8") as handle:
        handle.write(row.read_text())
    if not a.skip_backfill:
        subprocess.run([sys.executable, str(REPO / "scripts" / "complexity_backfill.py"), "--modules", "--no-publish",
                        "--repo", str(REPO), "--modules-out", str(out / "modules.jsonl")], check=True)
    url = f"http://localhost:{a.port}/index.html?local"
    print(f"Preview folder: {out}\nOpen: {url}")
    if a.no_serve:
        return 0
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(out))
    with http.server.ThreadingHTTPServer(("127.0.0.1", a.port), handler) as httpd:
        print("Serving; Ctrl-C to stop.")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
