#!/bin/bash
# media-vault pack — encrypt personal media into repo-safe AES-256 blobs.
#
# Design (Rick 2026-08-02): personal photos must never sit in git as
# plaintext, but SHOULD travel with the repo so a fresh clone + password
# restores the reference galleries. Each decade folder becomes one
# vault/<set>.tar.gz.enc (AES-256-CBC, PBKDF2 200k iters) — per-folder
# so every blob stays far under GitHub's 100 MB hard limit. Videos are
# deliberately NOT vaulted (multi-GB — they ride the normal 3-2-1
# backups, not git).
#
# Password: macOS Keychain item "videoscan-media-vault" (account
# "videoscan"). First run offers to store it; later runs & unpack.sh
# read it silently. A fork of this repo carries only ciphertext.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
VAULT="$REPO/vault"
GALLERY="$REPO/tests/fixtures/photos/Donna"
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

[ -d "$GALLERY" ] || { echo "no gallery at $GALLERY — nothing to pack" >&2; exit 1; }
mkdir -p "$VAULT"
PW="$(password)"

packed=0
for dir in "$GALLERY"/*/; do
  set_name="$(basename "$dir")"
  out="$VAULT/photos-$set_name.tar.gz.enc"
  tar -czf - -C "$GALLERY" "$set_name" \
    | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass "pass:$PW" -out "$out"
  size=$(du -h "$out" | cut -f1)
  echo "packed $set_name → vault/$(basename "$out") ($size)"
  packed=$((packed + 1))
done

echo "$packed set(s) packed. Verify with: tools/media-vault/unpack.sh --check"
echo "Reminder: git add vault/ — the .enc blobs are the ONLY media form that belongs in git."
