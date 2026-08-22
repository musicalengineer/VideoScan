#!/usr/bin/env bash
# Build and install Hallie's optional Kokoro/MLX neural speech helper.
# Models and build products remain outside the repository.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER_SOURCE="$REPO_ROOT/tools/hallie-kokoro"
KOKORO_APP_REPOSITORY="https://github.com/mlalma/KokoroTestApp.git"
KOKORO_APP_REVISION="9dcd3b06468a3c1ecee6d09a33ca687c8e708566"
MODEL_SHA256="4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8"
VOICES_SHA256="56dbfa2f2970af2e395397020393d368c5f441d09b3de4e9b77f6222e790f10f"
INSTALL_PARENT="$HOME/Library/Application Support/VideoScan"
INSTALL_DIRECTORY="$INSTALL_PARENT/HallieKokoro"
WORK_DIRECTORY="$(mktemp -d "${TMPDIR%/}/VideoScan-Hallie-Kokoro.XXXXXX")"

cleanup() {
    if [[ -n "${STAGING_DIRECTORY:-}" && -d "$STAGING_DIRECTORY" ]]; then
        rm -rf "$STAGING_DIRECTORY"
    fi
    rm -rf "$WORK_DIRECTORY"
}
trap cleanup EXIT

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "ERROR: Hallie's MLX voice helper requires an Apple Silicon Mac." >&2
    exit 1
fi

for command in git git-lfs swift xcode-select; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "ERROR: required command is missing: $command" >&2
        exit 1
    fi
done
xcode-select -p >/dev/null

echo "Building the pinned Hallie Kokoro helper..."
cp -R "$HELPER_SOURCE" "$WORK_DIRECTORY/helper"
(
    cd "$WORK_DIRECTORY/helper"
    swift package --disable-sandbox resolve

    # KokoroSwift 1.0.10 and MisakiSwift 1.0.5 publish dynamic libraries.
    # Linking both into one helper then duplicates MLX Objective-C classes at
    # runtime. Build these two pinned products statically until upstream fixes it.
    for manifest in \
        .build/checkouts/kokoro-ios/Package.swift \
        .build/checkouts/MisakiSwift/Package.swift; do
        chmod u+w "$manifest"
        if ! grep -q 'type: \.dynamic' "$manifest"; then
            echo "ERROR: upstream package layout changed: $manifest" >&2
            exit 1
        fi
        sed -i '' '/type: \.dynamic,/d' "$manifest"
    done
    swift build --disable-sandbox -c release
)

echo "Fetching the pinned Kokoro model and voice embeddings..."
git clone --no-checkout "$KOKORO_APP_REPOSITORY" "$WORK_DIRECTORY/KokoroTestApp"
(
    cd "$WORK_DIRECTORY/KokoroTestApp"
    git lfs install --local
    git checkout "$KOKORO_APP_REVISION"
    git lfs pull
)

# SwiftPM command-line builds do not emit MLX's precompiled Metal library.
# Build the pinned example app solely to generate that resource with Xcode.
echo "Building the pinned MLX Metal library..."
xcodebuild \
    -project "$WORK_DIRECTORY/KokoroTestApp/KokoroTestApp.xcodeproj" \
    -scheme KokoroTestApp \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath "$WORK_DIRECTORY/KokoroTestApp-derived" \
    -onlyUsePackageVersionsFromResolvedFile \
    CODE_SIGNING_ALLOWED=NO \
    build >/dev/null

MODEL_FILE="$WORK_DIRECTORY/KokoroTestApp/Resources/kokoro-v1_0.safetensors"
VOICES_FILE="$WORK_DIRECTORY/KokoroTestApp/Resources/voices.npz"
echo "$MODEL_SHA256  $MODEL_FILE" | shasum -a 256 -c -
echo "$VOICES_SHA256  $VOICES_FILE" | shasum -a 256 -c -

BUILD_DIRECTORY="$(cd "$WORK_DIRECTORY/helper" && swift build --disable-sandbox -c release --show-bin-path)"
METAL_LIBRARY="$WORK_DIRECTORY/KokoroTestApp-derived/Build/Products/Release/"
METAL_LIBRARY+="KokoroTestApp.app/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
mkdir -p "$INSTALL_PARENT"
STAGING_DIRECTORY="$(mktemp -d "$INSTALL_PARENT/.HallieKokoro-install.XXXXXX")"
cp "$BUILD_DIRECTORY/kokoro-tts" "$STAGING_DIRECTORY/kokoro-tts"
cp "$METAL_LIBRARY" "$STAGING_DIRECTORY/mlx.metallib"
cp -R "$BUILD_DIRECTORY/KokoroSwift_KokoroSwift.bundle" "$STAGING_DIRECTORY/"
cp -R "$BUILD_DIRECTORY/MisakiSwift_MisakiSwift.bundle" "$STAGING_DIRECTORY/"
cp -R "$BUILD_DIRECTORY/ZIPFoundation_ZIPFoundation.bundle" "$STAGING_DIRECTORY/"
cp "$MODEL_FILE" "$STAGING_DIRECTORY/kokoro-v1_0.safetensors"
cp "$VOICES_FILE" "$STAGING_DIRECTORY/voices.npz"
chmod +x "$STAGING_DIRECTORY/kokoro-tts"

SMOKE_DIRECTORY="$WORK_DIRECTORY/smoke"
"$STAGING_DIRECTORY/kokoro-tts" \
    --model "$STAGING_DIRECTORY/kokoro-v1_0.safetensors" \
    --voices "$STAGING_DIRECTORY/voices.npz" \
    --output "$SMOKE_DIRECTORY" \
    --voice af_heart \
    --speed 0.92 \
    --text "Hello. Hallie's local neural voice is ready."
test -s "$SMOKE_DIRECTORY/hallie-af_heart.wav"

if [[ -d "$INSTALL_DIRECTORY" ]]; then
    BACKUP_DIRECTORY="$INSTALL_DIRECTORY.previous.$(date +%Y%m%d-%H%M%S)"
    mv "$INSTALL_DIRECTORY" "$BACKUP_DIRECTORY"
    echo "Previous installation preserved at: $BACKUP_DIRECTORY"
fi
mv "$STAGING_DIRECTORY" "$INSTALL_DIRECTORY"

echo "Hallie's neural voices are installed at: $INSTALL_DIRECTORY"
echo "Restart VideoScan, then choose Heart, Bella, Sarah, or Emma in Hallie's voice settings."
