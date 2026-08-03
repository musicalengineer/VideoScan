#!/bin/bash
# media-vault unpack — restore personal media from the encrypted vault.
#
# Fresh-clone flow: clone repo → run this once → enter the vault
# password (offered into Keychain) → tests/fixtures/photos/Donna/ is
# rebuilt exactly. --check verifies every blob decrypts + lists
# contents WITHOUT writing any files (cheap integrity audit).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
VAULT="$REPO/vault"
GALLERY="$REPO/tests/fixtures/photos/Donna"
KEYCHAIN_SERVICE="videoscan-media-vault"
KEYCHAIN_ACCOUNT="videoscan"
CHECK_ONLY=${1:-}

password() {
  if pw=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null); then
    printf '%s' "$pw"
    return
  fi
  printf 'Vault password: ' >&2
  read -rs pw; echo >&2
  [ -n "$pw" ] || { echo "empty password" >&2; exit 1; }
  security add-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w "$pw" 2>/dev/null || true
  printf '%s' "$pw"
}

blobs=("$VAULT"/photos-*.tar.gz.enc)
[ -e "${blobs[0]}" ] || { echo "no vault blobs under $VAULT" >&2; exit 1; }
PW="$(password)"

for blob in "${blobs[@]}"; do
  name="$(basename "$blob")"
  # Destination by set name (mirror of pack.sh's three sets).
  case "$name" in
    photos-app-collage.*)  dest="$REPO/assets" ;;
    photos-fixture-set.*)  dest="$REPO/tests/fixtures/photos" ;;
    *)                     dest="$GALLERY" ;;
  esac
  if [ "$CHECK_ONLY" = "--check" ]; then
    count=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass "pass:$PW" -in "$blob" \
      | tar -tzf - | grep -cv '/$') || { echo "FAILED to decrypt $name (wrong password or corrupt blob)" >&2; exit 1; }
    echo "OK $name — $count file(s) → $dest"
  else
    mkdir -p "$dest"
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass "pass:$PW" -in "$blob" \
      | tar -xzf - -C "$dest" \
      || { echo "FAILED to decrypt $name (wrong password or corrupt blob)" >&2; exit 1; }
    echo "restored $name → $dest/"
  fi
done
[ "$CHECK_ONLY" = "--check" ] || echo "Gallery restored. (It stays gitignored — plaintext never enters git.)"
