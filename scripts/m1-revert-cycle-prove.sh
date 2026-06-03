#!/bin/bash
# Red→green→red→green cycle for SessionRestorePauseStateTests.
# Done at the unit-test level since XCUITest is blocked on TCC.
#
# Cycle:
#  green-1: branch HEAD as-is — fix in place. Tests should PASS.
#  red-1:   revert two key lines to pre-fix shape. Tests should FAIL.
#  green-2: restore fix. Tests should PASS again.
#
# Output: human-readable per-cycle pass/fail summary.

set -uo pipefail

LOG=/tmp/m1-revert-cycle.log
exec > >(tee "$LOG") 2>&1

cd /Users/rickb/dev/VideoScan
TARGET=VideoScan/VideoScan/PersonFinderModel+JobLifecycle.swift
SAVED=/tmp/PersonFinderModel-JobLifecycle.swift.green

cleanup() {
    # Always restore the file on exit. Belt-and-suspenders.
    if [ -f "$SAVED" ]; then
        cp "$SAVED" "$TARGET"
        echo "cleanup: restored $TARGET"
    fi
}
trap cleanup EXIT

cp "$TARGET" "$SAVED"
echo "Saved pristine HEAD copy of $TARGET → $SAVED"

run_tests() {
    local label=$1
    echo ""
    echo "============================================"
    echo "  $label"
    echo "============================================"

    DERIVED=$HOME/Library/Developer/Xcode/DerivedData/m1-cycle-dd
    xcodebuild test \
        -project VideoScan/VideoScan.xcodeproj \
        -scheme VideoScan \
        -configuration Debug \
        -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED" \
        -only-testing:VideoScanTests/SessionRestorePauseStateTests \
        CODE_SIGN_IDENTITY=- \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_ENTITLEMENTS= \
        2>&1 | grep -E "Test Suite|Test Case|passed|failed|✘|✔|error:|FAIL" | tail -40
    return ${PIPESTATUS[0]}
}

# --- green-1: HEAD as-is ---
run_tests "green-1: fix in place (HEAD as-is)"
G1_RC=$?
echo "green-1 rc=$G1_RC"

# --- red-1: revert the two fix lines ---
echo ""
echo "Editing $TARGET — reverting to pre-fix shape..."
python3 <<'PYEOF'
import re
path = "VideoScan/VideoScan/PersonFinderModel+JobLifecycle.swift"
with open(path) as f:
    src = f.read()

# Revert 1: makeJob — strip the if descriptor.statusRaw == "paused" branch,
# leave only job.status = .done; job.progress = 1.0
old_make = '''        if descriptor.statusRaw == "paused" {
            job.status = .paused
            let total = max(descriptor.videosTotal, 1)
            job.progress = Double(descriptor.videosScanned) / Double(total)
        } else {
            job.status = .done
            job.progress = 1.0
        }'''
new_make = '''        job.status = .done
        job.progress = 1.0'''
assert old_make in src, "make-job block not found"
src = src.replace(old_make, new_make)

# Revert 2: resumeJob — drop `job.status = .idle` before startJob() so the
# isActive guard bails. The exact line we want gone:
old_resume = '''            job.wasRestoredFromDisk = false
            job.status = .idle'''
new_resume = '''            job.wasRestoredFromDisk = false'''
assert old_resume in src, "resume-job block not found"
src = src.replace(old_resume, new_resume)

with open(path, "w") as f:
    f.write(src)
print("Reverted fix lines.")
PYEOF

run_tests "red-1: fix reverted (pre-fix shape)"
R1_RC=$?
echo "red-1 rc=$R1_RC"

# --- green-2: restore ---
cp "$SAVED" "$TARGET"
run_tests "green-2: fix restored (HEAD as-is again)"
G2_RC=$?
echo "green-2 rc=$G2_RC"

echo ""
echo "============================================"
echo "  Cycle summary"
echo "============================================"
echo "green-1 (fix in place):  rc=$G1_RC (0 = PASS)"
echo "red-1   (fix reverted):  rc=$R1_RC (NON-ZERO = expected FAIL)"
echo "green-2 (fix restored):  rc=$G2_RC (0 = PASS)"
echo ""
if [ "$G1_RC" -eq 0 ] && [ "$R1_RC" -ne 0 ] && [ "$G2_RC" -eq 0 ]; then
    echo "✔ RED→GREEN→RED→GREEN cycle PASSED — test catches the bug shape."
    exit 0
else
    echo "✘ Cycle outcome unexpected. See $LOG."
    exit 1
fi
