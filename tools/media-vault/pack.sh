#!/bin/bash
# media-vault pack — encrypt personal media into repo-safe AES-256 blobs.
#
# Design (Rick 2026-08-02/03): personal photos must never sit in git as
# plaintext — the repo goes PUBLIC with only ciphertext. Three photo
# sets are vaulted (each blob far under GitHub's 100 MB hard limit):
#   photos-Donna_<era>   each decade folder of the reference gallery
#   photos-fixture-set   the loose test-fixture photos (PersonFinder suite)
#   photos-app-collage   assets/app_photos (About-screen collage sources)
# Videos are deliberately NOT vaulted: every tracked video is synthetic;
# family video corpora (DonnaTestVideos etc.) are multi-GB and live in
# the normal 3-2-1 backups, never in git.
#
# Unlock is ONCE PER MACHINE (files persist gitignored in the working
# tree; git never removes them). CI never needs the vault — verified
# 2026-08-03: no workflow or TestDriver path reads these fixtures.
#
# Password: macOS Keychain item "videoscan-media-vault" (account
# "videoscan"). First run offers to store it. A fork carries only
# ciphertext — other developers bring their own media (see
# tests/fixtures/README.md).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
VAULT="$REPO/vault"
GALLERY="$REPO/tests/fixtures/photos/Donna"
FIXTURES="$REPO/tests/fixtures/photos"
APP_PHOTOS="$REPO/assets/app_photos"
KEYCHAIN_SERVICE="videoscan-media-vault"
KEYCHAIN_ACCOUNT="videoscan"

password() {
  if pw=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null); then
    printf '%s' "$pw"
    return
  fi
  printf 'Vault password (will be stored in your macOS Keychain): ' >&2
  read -rs pw; echo >&2
  printf 'Confirm: ' >&2
  read -rs pw2; echo >&2
  [ "$pw" = "$pw2" ] || { echo "passwords differ" >&2; exit 1; }
  [ -n "$pw" ] || { echo "empty password" >&2; exit 1; }
  security add-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w "$pw"
  printf '%s' "$pw"
}

encrypt() {  # encrypt <out.enc>  (tar stream on stdin)
  openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass "pass:$PW" -out "$1"
  echo "packed → vault/$(basename "$1") ($(du -h "$1" | cut -f1))"
}

mkdir -p "$VAULT"
PW="$(password)"
packed=0

# Donna reference gallery — one blob per decade folder.
if [ -d "$GALLERY" ]; then
  for dir in "$GALLERY"/*/; do
    set_name="$(basename "$dir")"
    tar -czf - -C "$GALLERY" "$set_name" | encrypt "$VAULT/photos-$set_name.tar.gz.enc"
    packed=$((packed + 1))
  done
fi

# Loose fixture photos (flat files only — Donna/ handled above).
flat=$(find "$FIXTURES" -maxdepth 1 -type f \
       \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.tif' -o -iname '*.tiff' \) \
       -exec basename {} \; | sort)
if [ -n "$flat" ]; then
  # shellcheck disable=SC2086
  (cd "$FIXTURES" && tar -czf - $flat) | encrypt "$VAULT/photos-fixture-set.tar.gz.enc"
  packed=$((packed + 1))
fi

# About-screen collage sources.
if [ -d "$APP_PHOTOS" ]; then
  tar -czf - -C "$(dirname "$APP_PHOTOS")" "$(basename "$APP_PHOTOS")" \
    | encrypt "$VAULT/photos-app-collage.tar.gz.enc"
  packed=$((packed + 1))
fi

echo "$packed set(s) packed. Verify with: tools/media-vault/unpack.sh --check"
echo "Next: git add vault/ — the .enc blobs are the ONLY media form that belongs in git."
