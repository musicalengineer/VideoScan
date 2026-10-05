# Step: helpers — app-side helpers that live outside the repo.
#
#   HallieKokoro   Hallie's neural voice (~/Library/Application Support/VideoScan/HallieKokoro).
#                  Built by the existing scripts/install_hallie_kokoro.sh.
#   drivetemps     the drive-temperature menubar app (~/bin/drivetemps).
#   vs-drive-temps the root-owned helper it calls through sudo — Rick's step.
#   promiseutil    Promise's own RAID tool — a vendor download, Rick's step.

section "App helpers"

KOKORO_DIR="$HOME/Library/Application Support/VideoScan/HallieKokoro"
if [[ -x "$KOKORO_DIR/kokoro-tts" && -f "$KOKORO_DIR/worker-protocol-v1" ]]; then
    ok "Hallie Kokoro voice ($KOKORO_DIR)"
elif checking; then
    failed "Hallie Kokoro voice" "missing; run without --check (or: scripts/install_hallie_kokoro.sh)"
elif ! command -v git-lfs >/dev/null 2>&1; then
    failed "Hallie Kokoro voice" "git-lfs missing (Brewfile installs it)"
else
    # Builds a pinned Swift helper, fetches the SHA-checked model, smoke-tests it.
    note "building Hallie's Kokoro voice (several minutes)…"
    if bash "$REPO_ROOT/scripts/install_hallie_kokoro.sh" >/tmp/videoscan-install-kokoro.log 2>&1; then
        installed "Hallie Kokoro voice"
    else
        failed "Hallie Kokoro voice" "see /tmp/videoscan-install-kokoro.log"
    fi
fi

if [[ -x "$HOME/bin/drivetemps" ]]; then
    ok "drivetemps menubar app (~/bin/drivetemps)"
elif checking; then
    manual "drivetemps menubar app" "optional; run without --check to build it"
else
    mkdir -p "$HOME/bin"
    if swiftc -O "$REPO_ROOT/scripts/DriveTempsMenuBar.swift" -o "$HOME/bin/drivetemps" >/dev/null 2>&1; then
        installed "drivetemps menubar app (~/bin/drivetemps)"
    else
        failed "drivetemps" "run: swiftc -O scripts/DriveTempsMenuBar.swift -o ~/bin/drivetemps"
    fi
fi

# Root-owned + a sudoers rule: never done by a script on Rick's behalf.
# DriveTempsMenuBar looks in /usr/local/sbin then /usr/local/bin.
helper_ok=0
for helper in /usr/local/sbin/vs-drive-temps /usr/local/bin/vs-drive-temps; do
    if [[ -x "$helper" && "$(stat -f %Su "$helper")" == "root" ]]; then
        ok "vs-drive-temps helper ($helper, root-owned)"
        helper_ok=1
        break
    fi
done
if [[ "$helper_ok" == "0" ]]; then
    manual "vs-drive-temps helper" "sudo install -o root -g wheel -m 755 scripts/vs-drive-temps /usr/local/sbin/vs-drive-temps; then sudo visudo -f /etc/sudoers.d/vs-drive-temps and add: $USER ALL=(root) NOPASSWD: /usr/local/sbin/vs-drive-temps"
fi

if [[ -x /usr/local/bin/promiseutil ]]; then
    ok "promiseutil (Promise RAID CLI)"
else
    manual "promiseutil" "only if a Promise Pegasus is attached: install Promise Utility from promise.com"
fi
