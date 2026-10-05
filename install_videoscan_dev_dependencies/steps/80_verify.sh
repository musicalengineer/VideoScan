# Step: verify — prove the pieces work together, without building the app.
# Fast (< 1 minute). Run alone any time: ./install.sh --only verify

section "Verify"

# ffprobe can read a real file, through the same lookup order the app uses.
ffprobe_bin=""
for candidate in /opt/homebrew/bin/ffprobe /usr/local/bin/ffprobe; do
    [[ -x "$candidate" ]] && { ffprobe_bin="$candidate"; break; }
done
fixture=$(ls "$REPO_ROOT"/tests/fixtures/videos/* 2>/dev/null | head -1)
if [[ -z "$ffprobe_bin" ]]; then
    failed "ffprobe" "not found where FFmpegLocator looks (/opt/homebrew/bin, /usr/local/bin)"
elif [[ -n "$fixture" ]] && "$ffprobe_bin" -v error -show_entries format=duration -of csv=p=0 "$fixture" >/dev/null 2>&1; then
    ok "ffprobe reads $(basename "$fixture")"
elif [[ -z "$fixture" ]]; then
    ok "ffprobe present ($ffprobe_bin; no fixture video to probe)"
else
    failed "ffprobe" "could not read $fixture"
fi

# The Xcode project opens and lists its schemes.
if xcodebuild -list -project "$REPO_ROOT/VideoScan/VideoScan.xcodeproj" 2>/dev/null | grep -q "VideoScan"; then
    ok "Xcode project lists the VideoScan scheme"
else
    failed "Xcode project" "xcodebuild -list failed"
fi

# VideoScanCore is a plain SwiftPM package; describing it proves the toolchain.
if swift package --package-path "$REPO_ROOT/VideoScan/VideoScanCore" describe >/dev/null 2>&1; then
    ok "VideoScanCore package (swift package describe)"
else
    failed "VideoScanCore" "swift package --package-path VideoScan/VideoScanCore describe failed"
fi

# The Python side: collect (not run) the pytest suite, which imports every
# test module and so catches a missing package in seconds.
if [[ -x "$REPO_ROOT/venv/bin/python" ]]; then
    collected=$("$REPO_ROOT/venv/bin/python" -m pytest -q --collect-only "$REPO_ROOT/tests" 2>/dev/null | tail -1)
    if [[ "$collected" == *"error"* || -z "$collected" ]]; then
        failed "pytest collection" "${collected:-no output}; run: venv/bin/python -m pytest -q --collect-only tests"
    else
        ok "pytest collects: $collected"
    fi
fi

mkdir -p "$HOME/Library/Logs/VideoScan" 2>/dev/null && ok "log folder ~/Library/Logs/VideoScan"

note "Build and run is yours: open VideoScan/VideoScan.xcodeproj, scheme VideoScan, Debug, ⌘R."
note "Command-line equivalent: xcodebuild -project VideoScan/VideoScan.xcodeproj -scheme VideoScan -configuration Debug build"
