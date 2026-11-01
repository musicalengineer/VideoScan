<!-- moved from Claude memory (reference_storage_layout_2026_08_13) on 2026-10-23; operational reference, rewrite in place -->

Merged from: reference_pegasus32_r4_dext_approval.md (2026-10-05)

Storage layout decided 2026-08-13 when the Promise Pegasus32 R4 came online (see [[reference_pegasus32_r4_dext_approval]] for the DEXT gotcha that made it invisible at first).

**Pegasus RAID format — DONE 2026-08-13.** Factory config kept: RAID5, 4×4TB = 12.0 TB usable, `/dev/disk4`. Single APFS container `disk6` (physical store `disk4s2`), two volumes sharing all space, no quotas — reserves only:

| Volume | Disk | Reserve | Finder shows |
|---|---|---|---|
| `FamilyArchive` | disk6s1 | 6 TB | 8.2 TiB avail |
| `Projects` | disk6s2 | 3 TB | 5.5 TiB avail |

Created with `diskutil apfs addVolume disk6 APFS <name> -reserve 6t|3t`. The two "available" figures sum to more than the disk holds because the ~3 TB of unreserved slack is visible to both and counted twice — first-come-first-served. `diskutil apfs list` reporting "9.0 TB (75.0% used)" on an empty array is the reserves being accounted, NOT data.

`Projects` is deliberately vague-purpose (photos, FCP projects, astrophotos) — Rick's plan for running short is "add another faster RAID in a year or two," not repartitioning.

Rejected: 8+4 reserves (sums to 12.0 TB > the 11.99 TB actually available — second addVolume fails, and zero slack defeats the point) and true GPT partitions (rigid, two containers, destructive to resize).

**GOTCHA: `-reserve`/`-quota` are creation-time only.** This macOS has no `diskutil apfs resizeVolume` and no `setQuota` verb. Changing a reserve later requires `deleteVolume` + `addVolume`, destroying that volume's data. The 6/3 split is a one-shot decision until the next erase. This is also why `eraseDisk` can't be used — it creates its volume with no reserve.

**Desk Thunderbolt topology (M4 Mac Studio).** TB0 → Pegasus RAID (40 Gb/s, dedicated, nothing daisy-chained). TB1 → CalDigit TS5 Plus (80 Gb/s, dual-controller — genuinely solid, 3 free downstream ports). TB2 → BenQ display (DP alt-mode, correctly shows as "no device" in the TB tree). TB3 → reserved for the new SanDisk 4TB SSD, its own bus, no contention with archive I/O.

**Device speed reality check.** The LaCie d2 Professional is a **single 7200 rpm HDD and a USB-C product by design** — not Thunderbolt, and it never was (the d2 Thunderbolt 3 was a separate SKU). `diskutil` reports `Protocol: USB`. Measured 207 MB/s sustained sequential read via `dd`; BlackMagic showed ~250 MB/s (outer-track flattery). That is platter speed, NOT a cable or port problem — no USB negotiation except USB 2.0 could produce 207, and that would be ~40 MB/s. Don't chase cables on this drive.

The Crucial X9/X10 scratch drives are likewise **USB 3.2 (~1 GB/s), not Thunderbolt**. Do not plan on daisy-chaining them off the Pegasus: its second port is TB3, and TB3 daisy-chain ports on storage enclosures generally don't carry USB data (only TB4 hubs are required to). Put USB drives on the CalDigit or the 16-port Acasis hub.

**Migration is source-limited.** Copying off the LaCie runs at ~207 MB/s regardless of how fast the Pegasus writes (~1 GB/s observed). LaCieWorkspace 3.2 TB ≈ 4.3 h; MediaExpansion 1.3 TB ≈ 1.75 h; worse with many small files. Clean before copying — see [[project_volume_roles_rick_2026_07_23]] for volume roles (LaCie = MASTER, currently a single non-redundant disk, which is the reason to migrate now).

## Power situation — DONE 2026-08-15: CyberPower UPS live; Pegasus RAID, LaCie, and Mac Studio all on it (Rick confirmed 8/15). History below.

**The UPS is a CyberPower `CP1500PFCRM2U`** — 1500VA / 1000W, 2U rack-mount, **pure sine wave** output with active PFC compatibility. Rick took delivery and was registering it on 2026-08-15. Sine wave matters here: Macs and the Pegasus use active-PFC supplies that can drop out or buzz on the stepped-approximation waveform cheaper UPSes emit during a transfer. Full gear entry in [[user_hardware_fleet]].

**Root cause of the 8/13 LaCie failure was an old Belkin power strip, NOT the drive, its wall wart, or the dock's USB controller.** Moving the LaCie to a newer Furman strip brought it straight up. The Belkin's **top connectors are the bad ones**; the side connectors are visibly more robust and are what everything else is running on.

Deliberate decision 8/13: **do not rejigger power yet.** The failure mode is spin-up surge, not steady-state — everything currently powered has been stable for hours, so a shutdown to move cords would force a cold start (max surge) on the suspect strip. Leaving it running is the lower-risk path. Do the rework as a planned maintenance window when the CyberPower arrives: move Pegasus first (RAID5 + power loss = write-hole / multi-hour degraded rebuild), then LaCie, then cold-start deliberately and verify each device returns.

LaCie now runs off the Mac Studio's rear USB-A port on a short cable, via the Mac's own `AppleEmbeddedUSBXHCIASMedia3142` controller — stable there. Note this **disproves the earlier ASMedia-controller theory** (the dock's `AppleASMediaUSBXHCI` was innocent; ASMedia silicon is fine, power was the whole story).

## LaCie PSU incident 2026-08-13 evening — RESOLVED (power strip), READ FIRST

The LaCie d2 Professional (MASTER volume, 3.2 TiB `LaCieWorkspace` + 1.3 TiB `MediaExpansion`) **went dead the evening of 8/13**. Sequence: intermittent dropouts all evening → LED off entirely → on a substitute power supply it spins/vibrates/warms but shows **no LED and never enumerates on USB**. Rick pulled power and set it in front of a fan to cool.

Diagnosis: **failing/inadequate power supply**, not the drive. A 3.5" spin-up surge is ~2 A on 12 V; a cheap wart sags below regulation exactly then, so the bridge board never initializes. Symptom fits perfectly. Replacement must match voltage exactly, amperage equal-or-higher, correct polarity and barrel size — read the spec off the d2's rear panel.

This likely supersedes the earlier ASMedia-controller theory. The dropouts were first blamed on the CalDigit TS5 Plus putting the LaCie on `AppleASMediaUSBXHCI` (Hub B) while the Crucials sat on Apple's `AppleT8132USBXHCI` (Hub A) and stayed stable — plausible, but "worked flawlessly a month, then degraded, then died" fits a dying PSU better. Keep both hypotheses live.

**Data is intact and was verified AFTER the disconnects**: SMART `Verified`, `diskutil verifyVolume` clean, 3.2 TiB readable. Risk is that tier-1 family media has one copy on hardware with a bad supply.

Fallback if the enclosure stays dead: it's an ordinary 3.5" SATA drive — a USB3 SATA dock bypasses both wart and bridge. Caveat: confirm this unit doesn't tie encryption to the bridge chip first.

**RESOLVED same night.** Root cause was the old Belkin power strip (top connectors bad); LaCie came straight up on the Furman strip, rear Studio USB-A port, short cable. Verified clean, SMART `Verified`.

**Curated media secured 8/13 (~21:00):** `Movies` + `Pictures` + `ancestry` = **101 files, 88,029,292,131 bytes** copied LaCie → `SanDiskWorkspace` (206.9 MB/s, platter-limited) → `Projects/_staging_from_LaCie` (850.7 MB/s). Counts and byte totals verified identical across all three. Deliberately staged in **`Projects`, not `FamilyArchive`** — Rick's call, so the clean archive stays uncommitted until curation. `FamilyArchive` is still empty by design.

**KEY SIZE FINDING — the irreplaceable material is only 2.5% of the volume.** LaCieWorkspace breakdown: `CheesegraterArchive` 2.3 T (72%), `from_mybook` 356 G, `from-Mini2TB` 271 G, `from-Seagate` 132 G, `Movies` 78 G, `Old PT sessions` 40 G, `from-Maxtor750` 26 G, `ImmichBenchmark` 24 G, `Pictures` 4.2 G, `Downloads` 185 M, `ancestry` 72 K. So "migrate the LaCie" is really a triage problem over `CheesegraterArchive` + the `from-*` set, not a data-rescue problem.

**Agreed division of labor:** script (`rsync`) moves bytes — resumable, verifiable, proven at scale; VideoScan app decides *which* bytes (catalog + segmented content hash + dedupe) and emits the keep/discard list. Don't make the app a 3 TB file mover. Plan: stage bulk on `SanDiskWorkspace` for fast multi-pass triage (LaCie keeps its copy), promote only keepers to `FamilyArchive`.

**Rescue script staged** at `<session scratchpad>/rescue_lacie.sh` — read-only on source, resumable rsync, copies in priority tiers (1: `Movies`/`Pictures`/`ancestry` = irreplaceable; 2: `from-*`/`CheesegraterArchive` = likely duplicated on retired-insurance drives; 3: `ImmichBenchmark`/`Downloads`/`Old PT sessions`). Before running: `sudo pmset -a disksleep 0` (stop mid-copy spin-down), `sudo mdutil -i off /Volumes/LaCieWorkspace` (stop Spotlight head contention), wrap in `caffeinate -s`. `MediaExpansion` needs a second pass.

## Pegasus Media Patrol schedule (set 2026-08-14)

**Weekly, Sunday 10 PM** — set in Promise Utility.app, because **`promiseutil` has NO scheduler**; its full verb list (about/array/battery/bbm/bga/buzz/checktable/clone/config/ctrl/date/enclosure/event/init/logdrv/migrate/mp/pdm/phydrv/rc/rb/sc/spare/stats/subsys/sync/transit/usbflash…) contains no `sched`. CLI can only `-C mp -a start|stop` and report status. Alternative if ever needed: launchd calling the CLI.

A full pass over 4×4TB is ~12–20 h (≈5.5 h/drive sequential, parallel + background-throttled), so it may still be running Monday morning — that's expected, it yields to foreground I/O. **Weekly beats monthly on RAID5**: patrol exists to find latent unreadable sectors *before* a rebuild needs them, which is the most common way RAID5 arrays actually die. (An earlier "monthly" suggestion here was over-cautious and wrong.)

**After each pass, check `sudo promiseutil -C event`** for media errors / sector remaps tied to one physical drive. Rising counts on a single member = source a replacement while redundancy still exists. That check is the entire payoff of running patrol.

Also unconfirmed as of 8/14: whether the array's initial background init ever finished — `sudo promiseutil -C bga -a list`.

## M4 boot-drive space — Finder size illusions (investigated 8/14)

**Finder said `~/Library` = 1.32 TB on a 1 TB SSD. It's a phantom — do NOT act on it.** `~/Library/Containers/Docker` reports **994.69 GB in Finder but 5.6 GB on disk**: Docker Desktop's `Docker.raw` is a sparse image provisioned to ~926 GB (roughly SSD size) that grows on demand. Finder reports the ceiling, `du` reports allocated blocks. **Never purge/reset Docker to reclaim space here — you'd destroy containers to recover 5.6 GB.**

Genuinely real in Containers: **UTM 33 GB** (VM images), **Draw Things 11 GB** (SD model weights). Both reclaimable only if unused.

General rule established: **`df`/`du` count blocks; Finder counts logical size** — it follows symlinks off-volume, counts APFS clones twice, and reports sparse files at maximum. When they disagree, blocks win. Ruled out as causes here: zero local Time Machine snapshots.

**`~/Movies` offloaded to RAID 8/14:** 61 items copied (checksum-verified) to `/Volumes/Projects/MoviesExpansion`, originals replaced with symlinks. Boot volume **93% → 85%, 66 GiB → 136 GiB free**. `MoviesExpansion` is now the agreed convention: movies from Rick's home dir live on the RAID under `Projects`. NOTE: `~/Movies` will now look *bigger* in Finder (61 symlinks followed out to the RAID) — judge by `df` only. Deliberately skipped: app library packages (`.fcpbundle`/`.imovielibrary`, ~43 GB) — relocate those through the app, never via symlink. Still stuck: `Timmy 10th Bday` (5.8 GB) copied+verified to RAID but original undeletable, permission-locked `VIDEO_TS` DVD-rip files.

**FCP symlink constraint on redistribution:** `~/Movies` FCP libraries reference media by absolute path via symlinks. Inventory: 305 → `/Volumes/Untitled` (dead SD card, 2020, in the 28 GB `iMovie Library.imovielibrary` — junk candidate), 1 → `MyBook3Terabytes` (dead), and only **8 live external links** (4 MediaExpansion, 2 CrucialX9, 2 CrucialX10). So redistribution needs a re-point step for 8 links — a checklist item, not a blocker.

**Two network faults found 2026-08-13, unfixed:** `en0` (Studio 10GbE → router) is linked at only **1000baseT**, one tenth of capability — suspect router port or Cat5e cable. `en10` (CalDigit ethernet → Mac Pro cheesegrater) shows **no link at all**, status inactive.

---
## From reference_pegasus32_r4_dext_approval.md

Promise Pegasus32 R4 (Thunderbolt RAID, arrived 2026-08-13 for the storage migration — see [[project_session_2026_08_12_signatures_and_delete_safety]]) came up on the M4 Mac Studio with Thunderbolt attached (blue, TB Bus 0, 40 Gb/s, fw 50.3) but **invisible to Disk Utility, diskutil, and Promise Utility**.

Root cause: the Promise DriverKit extension `com.promise.driverkit.pegasus` (team 268CCUR4WN) was `[activated waiting for user]` — installed+activated but NOT enabled. On Apple Silicon the RAID's block device is published ONLY by this DEXT, so until it's approved nothing enumerates. Rebooting made it look WORSE (dark on reboot, lights after login) because the DEXT can't load until login+approval.

Fix: **System Settings → General → Login Items & Extensions → Driver Extensions → toggle Promise ON** (Touch ID/password). The toggle "wiggles" (appears to reject) but actually takes — re-check with `systemextensionsctl list`, look for `[activated enabled]` with `*` in the enabled column. DEXTs need NO Recovery/reduced-security dance (unlike old kexts).

Diagnosis commands: `systemextensionsctl list` (the smoking gun), `diskutil list external physical`, `ioreg -c IOBlockStorageDevice`. When online: `PromiseSTEX` controller matched+active, `/dev/disk4` = 12 TB.

Factory format is a single 12 TB Apple_HFS (HFS+) volume "Pegasus32 R4". Reformat to APFS before loading media — layout decided 8/13, see [[reference_storage_layout_2026_08_13]].
