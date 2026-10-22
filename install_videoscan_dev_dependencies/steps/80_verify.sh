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
# Exit 0 AND "N tests collected" both required ("no tests collected" exits 5).
# No bytecode or cache writes, so --check leaves the checkout untouched.
if [[ -x "$REPO_ROOT/venv/bin/python" ]]; then
    # From the checkout: some tests import `scripts.…` relative to it.
    collected=$(cd "$REPO_ROOT" && PYTHONDONTWRITEBYTECODE=1 venv/bin/python -m pytest -q --collect-only \
        -p no:cacheprovider tests 2>&1)
    pytest_rc=$?
    collected=$(tail -1 <<< "$collected")
    if [[ "$pytest_rc" == "0" && "$collected" =~ [1-9][0-9]*\ tests?\ collected ]]; then
        ok "pytest collects: $collected"
    else
        failed "pytest collection" "exit $pytest_rc: ${collected:-no output}; run: venv/bin/python -m pytest -q --collect-only tests"
    fi
fi

LOG_DIR="$HOME/Library/Logs/VideoScan"
if [[ -d "$LOG_DIR" ]]; then
    ok "log folder ~/Library/Logs/VideoScan"
elif checking; then
    failed "log folder" "~/Library/Logs/VideoScan missing; run without --check to create it"
elif mkdir -p "$LOG_DIR"; then
    installed "log folder ~/Library/Logs/VideoScan"
else
    failed "log folder" "could not create ~/Library/Logs/VideoScan"
fi

note "Build and run is yours: open VideoScan/VideoScan.xcodeproj, scheme VideoScan, Debug, ⌘R."
note "Command-line equivalent: xcodebuild -project VideoScan/VideoScan.xcodeproj -scheme VideoScan -configuration Debug build"
