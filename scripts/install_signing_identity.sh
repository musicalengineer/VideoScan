#!/bin/bash
# install_signing_identity.sh — put the "VideoScan Local" code-signing identity
# in this Mac's login keychain (Rick, 2026-10-28).
#
# Why: an ad-hoc signed app's identity is the hash of its binary, so every
# rebuild looked like a new app to macOS privacy (TCC) and Full Disk Access /
# removable-volume grants were asked for again ("Failed to match existing code
# requirement"). Signed with one certificate, the designated requirement is
# `identifier "Rick-Breen.VideoScan" and certificate root = H"4dedb56f…"`,
# which survives rebuilds: grant once per Mac.
#
# The certificate and key live in ~/.videoscan-signing (mode 700), never in
# git. Copy that folder from a Mac that has it (scp -rp), then run this from
# Terminal on the new Mac (it asks for the login password if the keychain is
# locked, e.g. over ssh: `ssh -t host ~/dev/VideoScan/scripts/install_signing_identity.sh`).
set -eu
DIR="$HOME/.videoscan-signing"
KC="$HOME/Library/Keychains/login.keychain-db"
if security find-identity -p codesigning "$KC" | grep -q '"VideoScan Local"'; then
    echo "VideoScan Local is already installed."
    exit 0
fi
[ -f "$DIR/VideoScanLocal.p12" ] && [ -f "$DIR/p12.pass" ] || {
    echo "missing $DIR/VideoScanLocal.p12 or p12.pass — copy ~/.videoscan-signing from another Mac first" >&2
    exit 1
}
security unlock-keychain "$KC"
security import "$DIR/VideoScanLocal.p12" -k "$KC" -P "$(cat "$DIR/p12.pass")" \
    -T /usr/bin/codesign -T /usr/bin/security
security find-identity -p codesigning "$KC" | grep '"VideoScan Local"'
echo "Installed. Grant Full Disk Access to VideoScan once more; it now survives rebuilds."
