#!/usr/bin/env python3
"""gh_runner_release.py — which GitHub Actions runner build to install, from a release record.

scripts/install_gh_runner.sh ships this file to the host beside itself and feeds it the
JSON of https://api.github.com/repos/actions/runner/releases/<latest|tags/vX.Y.Z>. It prints
ONE line — "<version> <download url> <sha256 or ->" — for the asset of the wanted platform
(osx-arm64 for every Mac in the fleet). The checksum comes from the release notes, where
GitHub publishes it twice: a marker `<!-- BEGIN SHA osx-arm64 -->hex<!-- END SHA osx-arm64 -->`
the `echo "hex  actions-runner-osx-arm64-X.tar.gz" | shasum -a 256 -c` line, and the SHA-256
Checksums list ("actions-runner-osx-arm64-X.tar.gz hex"). Any of them is taken; with none the third word is "-" and the installer refuses to install an unverified
download unless told the digest by hand (--sha256).

    python3 gh_runner_release.py <release.json|-> [platform]      # default platform osx-arm64

Exit 0 with the line; 1 with the reason on stderr (no such asset, not a release record).
Tests: tests/test_install_gh_runner.py. No apostrophes in this file: the installer ships it to
the host inside a quoted heredoc.
"""
from __future__ import annotations

import json
import re
import sys


def resolve(release: dict, platform: str = "osx-arm64") -> tuple[str, str, str]:
    """(version, url, sha256 or "-") for the platform asset of a GitHub release record."""
    if not isinstance(release, dict):
        raise ValueError("not a release record")
    tag = str(release.get("tag_name") or "")
    version = tag[1:] if tag.startswith("v") else tag
    if not re.fullmatch(r"[0-9]+(\.[0-9]+){1,2}", version):
        raise ValueError("release has no version tag (got %r)" % tag)
    wanted = "actions-runner-%s-%s.tar.gz" % (platform, version)
    url = ""
    for asset in release.get("assets") or []:
        if isinstance(asset, dict) and asset.get("name") == wanted:
            url = str(asset.get("browser_download_url") or "")
            break
    if not url:
        raise ValueError("release %s has no asset %s" % (tag, wanted))
    body = str(release.get("body") or "")
    sha = "-"
    marker = re.search(r"<!--\s*BEGIN SHA %s\s*-->\s*([0-9a-fA-F]{64})\s*<!--\s*END SHA %s\s*-->"
                       % (re.escape(platform), re.escape(platform)), body)
    if marker:
        sha = marker.group(1).lower()
    else:
        # The shasum line ("hex  file") or the checksum list ("file hex"), whichever is there.
        line = (re.search(r"([0-9a-fA-F]{64})\s+%s" % re.escape(wanted), body)
                or re.search(r"%s\s+([0-9a-fA-F]{64})" % re.escape(wanted), body))
        if line:
            sha = line.group(1).lower()
    return version, url, sha


def main(argv: list[str]) -> int:
    if len(argv) < 2 or len(argv) > 3:
        print("usage: gh_runner_release.py <release.json|-> [platform]", file=sys.stderr)
        return 2
    platform = argv[2] if len(argv) == 3 else "osx-arm64"
    try:
        raw = sys.stdin.read() if argv[1] == "-" else open(argv[1], encoding="utf-8").read()
        version, url, sha = resolve(json.loads(raw), platform)
    except (OSError, ValueError) as e:
        print("gh_runner_release: %s" % e, file=sys.stderr)
        return 1
    print(version, url, sha)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
