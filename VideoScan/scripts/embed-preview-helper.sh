#!/bin/sh
# embed-preview-helper.sh — Stage 3 of the preview-sweep helper.
#
# Invoked as a Run Script build phase of the VideoScan app target. It:
#   1. builds the `videoscan-preview-sweep` SwiftPM executable (from the
#      VideoScanCore package — no external deps, builds offline) for the
#      current $CONFIGURATION and $ARCHS,
#   2. copies the binary into the app bundle at Contents/Helpers/, and
#   3. code-signs the nested binary with the app's identity BEFORE Xcode
#      seals the outer bundle signature.
#
# Placed as the LAST build phase of the app target so the helper is in place
# and signed before Xcode's automatic final app-signing (which then seals
# Contents/Helpers/ into the bundle's CodeResources). If it ran after the
# seal, the app signature would be invalid ("code object is not signed at
# all" at launch).
#
# The whole point of Stage 3: a clean checkout + Xcode build "just works" —
# the helper ships inside VideoScan.app with zero manual `swift build`.

set -eu

HELPER_NAME="videoscan-preview-sweep"
PKG_PATH="${SRCROOT}/VideoScanCore"

# Map the Xcode configuration to a SwiftPM build config.
case "${CONFIGURATION}" in
  Debug|debug) SWIFT_CONFIG="debug" ;;
  *)           SWIFT_CONFIG="release" ;;
esac

# Match SwiftPM architectures to the app build. $ARCHS is space-separated:
# "arm64" for a normal Apple-Silicon build, "arm64 x86_64" for universal.
ARCH_FLAGS=""
for a in ${ARCHS}; do
  ARCH_FLAGS="${ARCH_FLAGS} --arch ${a}"
done

# Isolated SPM scratch dir under the target's derived-files dir so this build
# never fights Xcode's own build graph or the app's package resolution.
SCRATCH="${DERIVED_FILE_DIR}/preview-helper-spm"
mkdir -p "${SCRATCH}"

echo "note: building ${HELPER_NAME} (config=${SWIFT_CONFIG}, archs=${ARCHS})"
# shellcheck disable=SC2086
swift build \
  -c "${SWIFT_CONFIG}" \
  --product "${HELPER_NAME}" \
  --package-path "${PKG_PATH}" \
  --scratch-path "${SCRATCH}" \
  ${ARCH_FLAGS}

# Ask SwiftPM for the exact bin dir (handles universal / arch-triple subdirs).
# shellcheck disable=SC2086
BIN_DIR="$(swift build -c "${SWIFT_CONFIG}" \
  --package-path "${PKG_PATH}" \
  --scratch-path "${SCRATCH}" \
  ${ARCH_FLAGS} \
  --show-bin-path)"
SRC_BIN="${BIN_DIR}/${HELPER_NAME}"

if [ ! -x "${SRC_BIN}" ]; then
  echo "error: built helper not found or not executable at ${SRC_BIN}" >&2
  exit 1
fi

# Destination inside the app bundle being assembled.
DEST_DIR="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
DEST_BIN="${DEST_DIR}/${HELPER_NAME}"
mkdir -p "${DEST_DIR}"
cp -f "${SRC_BIN}" "${DEST_BIN}"
chmod +x "${DEST_BIN}"

# Code-sign the nested binary with the app's identity. EXPANDED_CODE_SIGN_IDENTITY
# is set by Xcode from the target's signing settings; fall back to "-" (ad-hoc /
# "Sign to Run Locally") when empty so a bare dev machine works AND a future
# Developer ID flows through unchanged. Never hardcode a team/identity.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"

# Mirror the app's hardened-runtime setting. It's OFF today (dev / ad-hoc), so
# no --options is added; when a Developer-ID + notarized build turns it ON,
# the nested binary is signed with the runtime option to match.
CS_OPTS=""
if [ "${ENABLE_HARDENED_RUNTIME:-NO}" = "YES" ]; then
  CS_OPTS="--options runtime"
fi

echo "note: codesigning ${HELPER_NAME} with identity '${IDENTITY}'"
# shellcheck disable=SC2086
codesign --force --sign "${IDENTITY}" ${CS_OPTS} "${DEST_BIN}"

echo "note: embedded ${HELPER_NAME} at ${DEST_BIN}"
