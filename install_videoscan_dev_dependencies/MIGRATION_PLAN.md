# Migration plan: M4 Max Mac Studio → M5 Ultra Mac Studio

Written 2026-10-05. Goal: the Ultra becomes Rick's primary VideoScan machine with
nothing lost, the M4 kept untouched as a fallback until the Ultra has run green
for a week, and the whole thing reproducible from the scripts in this folder
rather than from memory.

## Decisions for Rick (before the Ultra arrives)

1. **Hostname.** Recommend **`RicksUltra`**. Don't use anything containing
   `M5`: `scripts/install_nightly.sh` matches `*M5*` and would give the Ultra
   the M5 laptop's 03:15 failover slot.
2. **Roles that move to the Ultra.** Recommend all of them: primary dev,
   2 AM nightly + weekly sanitizers + adversarial review, catalog sync
   master, Ollama host for Hallie. The M4 then becomes the failover nightly
   host (or retires, your call).
3. **Clean install, not Migration Assistant.** Recommended. A clean install
   proves these scripts, and it leaves behind the M4's accumulated drift: the
   main venv is a 3.12/3.14 hybrid, there are retired LaunchAgents, and the
   Brewfile no longer matches what's installed. Migration Assistant is fine for
   your non-dev life (Mail, Photos, music apps), which you said you'll handle.
   If you use it for those, skip its "Other files and folders" for
   `~/dev` and `~/Library/Application Support/VideoScan`: `migrate_data.sh`
   copies those consistently.

## Phase 0 — now, before it arrives

- [ ] Merge `feat/dev-env-installer` (this folder, revised Brewfile, requirements).
- [ ] **Dress rehearsal on the M1:** make a temporary macOS user, clone, run
      `install.sh`, fix whatever breaks, delete the user. That's the only real
      fresh-machine test; the M4 run only proves "already installed" is detected.
- [ ] Save the custom Ollama model `qwen-videoscan:64k` (engineering room) into
      the repo: on the M5, `ollama show --modelfile qwen-videoscan:64k`
      → `tools/engineering-room/Modelfile`.
- [ ] Hostname changes in code (separate small branch). These hard-code the
      current fleet and need the new name:
      - `Catalog/CatalogSync.swift:88`: default master `RicksM4.local`
      - `Hallie/LLM/OllamaEndpoints.swift:43`: default Ollama hosts
      - `People/DossierDashboardView+FleetStats.swift:24-26`: worker hosts
      - `scripts/install_nightly.sh`: slot table
      - `scripts/nightly_hallie_replay.sh:30`, `tools/engineering-room/src/qwen-client.mjs:166`
- [ ] Free space on the M4 is 88 GB, below the 150 GB the installer recommends.
      It doesn't block anything; it just limits rehearsals there.

## Phase 1 — day one, Rick (about an hour, mostly waiting)

- [ ] macOS setup; update to the current macOS 27.x; set the hostname
      (System Settings ▸ General ▸ Sharing ▸ Local hostname).
- [ ] Turn on Remote Login (Sharing) so the fleet can reach it.
- [ ] Xcode 27 from the App Store → open once → accept the license.
- [ ] Homebrew (installer asks for your password), then add
      `eval "$(/opt/homebrew/bin/brew shellenv)"` to `~/.zprofile`.
- [ ] git identity, `gh auth login`, Claude Code + `claude` sign-in, `codex login`.
- [ ] `ssh-copy-id RicksM4.local` (and the laptops).

## Phase 2 — day one, scripts (about 1–2 hours unattended)

```bash
git clone https://github.com/musicalengineer/VideoScan.git ~/dev/VideoScan
~/dev/VideoScan/install_videoscan_dev_dependencies/install.sh --copy-from RicksM4.local --with-models
```

Slowest parts: dlib compiling (5–10 min), torch download, the Kokoro voice build,
and the 18 GB Ollama pull. To save the pull, `migrate_data.sh --with-ollama`
copies the M4's 56 GB of Ollama models instead; over the 1 Gb/s LAN that's
about 8 minutes vs. however fast your internet is.

## Phase 3 — the data (the irreversible-feeling part, done safely)

1. Quit VideoScan on **both** Macs (the script refuses otherwise).
2. Dry run, read the totals: `migrate_data.sh --from RicksM4.local`
   (~6.3 GB App Support + ~1.4 GB of git-ignored photos/models/fixtures).
3. Copy: `migrate_data.sh --from RicksM4.local --go`.
   Pull only: the M4 is never written, nothing on the Ultra is deleted, and
   any file it replaces is kept as `*.pre-migrate-<stamp>`.
4. Don't run VideoScan on the M4 again until Phase 6 is decided. Two Macs
   editing two copies of the catalog is the one real way to lose work here.

## Phase 4 — hardware and permissions (Rick)

- [ ] Move the drives using the wiring slide ("Mac Studio wiring — Sept 2026"
      in Drive) as the map: Pegasus TB5 #1, CalDigit TB5 #2, SanDisk TB5 #3,
      Babyface TB5 #4, UPS + Acasis on the rear USB-A ports.
- [ ] UPS shutdown settings again: `pmset -g everything` on the M4 shows
      10 min / 39% / 10 min remaining; auto-restart off.
- [ ] Promise Utility, the `vs-drive-temps` helper + sudoers rule (the installer
      prints the exact commands).
- [ ] Privacy & Security ▸ Full Disk Access (and Removable Volumes) for
      VideoScan (after the first build), Xcode, Terminal.

## Phase 5 — verify

- [ ] `install.sh --check` → 0 failed.
- [ ] You: Debug build and run. Spot-check: catalog file count matches the
      M4's; the People tab shows everyone; Hallie speaks in the Kokoro voice;
      the Archive tab sees FamilyArchive; Family Tree ▸ FamilySearch pull opens.
- [ ] One overnight Release gauntlet on the Ultra (`scripts/run_gauntlet.sh`)
      compared against the M4 baseline: same counts, no new failures.

## Phase 6 — cut-over (after a week green)

- [ ] On the Ultra: `install.sh --with-schedules` once `install_nightly.sh`
      knows `RicksUltra`; then `scripts/install_sanitizer_weekly.sh` and
      `scripts/adversarial/install.sh`.
- [ ] On the M4: remove or re-slot its agents so nothing runs twice
      (`launchctl bootout gui/$(id -u)/com.videoscan.<label>` per agent).
- [ ] In the app: catalog sync master and Ollama hosts → `RicksUltra.local`.
- [ ] Update the machine policy (M4 midnight–10 am window, RAM budget of
      ≤ 2 concurrent test runs) for the Ultra's cores and memory.

## Rollback

Until Phase 6, the M4 is unchanged: same drives (once moved back), same catalog,
same agents. If the Ultra misbehaves, plug the drives back into the M4 and carry
on. Anything written on the Ultra in the meantime can be copied back with the same
script, run in the other direction (`--from RicksUltra.local` on the M4).
