# BACKLOG — the long form of lines shortened on 2026-11-01

*The Codex docs review (2026-11-01, F06) asked BACKLOG to hold one line per item. These are the lines as they stood, verbatim; each has a one-line summary in `docs/BACKLOG.md` that points here by its heading. When an item becomes the week's theme, its detail moves into STATUS or its design doc.*

## Video LLM, after A0/A1

- Video LLM, after A0/A1 (2026-10-30, `docs/reviews/video_llm_benchmarks.md`): (1) one engine, two samplers — stills for OCR (windows cost 4–6 points), windows for era/room; (2) A2 DONE 2026-10-31: the 8B halves the era error (Rick-dated MAE 3.6 y, inside-range 86 %) and lifts OCR to 95 %; A3 (32B) on the same clips is worse (MAE 5.0 y) at ≈ 5× the cost — seat the 8B, park the 32B unless a 32B-tuned prompt is tried; (3) the era claim must sit under the codec/carrier floor (A1 dates 2020s HEVC footage decades early); (4) re-pick the prompt on clips held out of the corpus (A1's r3 was tuned on 3 in-corpus clips); (5) roomFeatures vocabulary (384 generic strings) is ready for the place-signature retrieval test once Rick labels the 50 places.

## Catalog ▸ Catalog Info

- **Catalog ▸ Catalog Info** (Rick, 2026-11-01: "where does a user see the schema version?" — nowhere today; ⌘I Catalog Info is per volume): one read-only sheet, a dozen lines, each read at open time from the file and the store, never from a cached field — database path and size (+WAL), schema version, current generation, contents / files counts, last commit, last backup (when, where), this Mac's role (master / viewer) and last sync, journal lines waiting / refused, last Verify Catalog verdict and when. Useful without overwhelming; nothing editable.

## UPS wattage menu-bar app

- UPS wattage menu-bar app (Rick 2026-10-27): PowerPanel Personal is Intel-only and its service hangs ("Service Not Ready", port 31111 closed). Tiny native Swift app: IOHIDManager on the CyberPower CP1500PFCRM2U (0764:0601, HID Power Device page 0x84), read PercentLoad/ActivePower, show watts in the menu bar; non-exclusive read so macOS's built-in UPS shutdown keeps working (verify on the unit). Alternative: Homebrew `nut` (arm64, installed 2026-10-27; config in /opt/homebrew/etc/nut): `macosx-ups` (no root) gives charge/runtime/status but NO load; `usbhid-ups` needs root — test `sudo …/usbhid-ups -a cp1500 -d 1 -u root` decides whether it can share the device with powerd. Goal (Rick): live watts + log every ~60 s (SQLite) → weekly and monthly average watts and kWh for everything on the UPS (Ultra, M4, Pegasus, LaCie, displays). Just for fun; skip third-party NUT clients.

## Background helper looks like the app

- Background helper looks like the app (Rick 2026-10-28): the detached Find Tag daemon is VideoScan.app in --find-tag mode, so Activity Monitor shows the same name and icon. Plan: a nested helper bundle `Contents/Helpers/VideoScan Background.app` (own name, own bundle ID, signed "VideoScan Local"; one extra Full Disk Access grant) whose icon is the app icon with a badge drawn by us, not stock art: Rick liked a "process" gear-in-circular-arrows or a checklist-with-clock badge, in a different colour. Weigh it against the single-binary design (shared TCC grants, Vision/CoreML in one binary).

## Put the Ultra to work

- Put the Ultra to work (Rick 2026-10-28: "see some silicon melt… in a productive way"): (1) A/B bigger Hallie brains (qwen2.5:72b, llama3.3:70b) on the 870-question harness, both Macs, same build; (2) a primed prefix: the family-tree summary + catalog facts as a cached long-context prefix (KV/prompt cache), facts still answered from evidence; (3) LoRA fine-tune (mlx-lm, local) for SKILL not facts: question → Hallie query, trained on the harvested corpus; weights hold family names → never in git/cloud; (4) GPU/ANE batch work: vision-LLM scene captions, Whisper segments, faces/Find Tag throughput; (5) the engines Gemini suggested (list from Rick); (6) the `.1999_maybe` stem: output names treat it as an extension.

## Local review models on the night shift

- Local review models on the night shift (Rick 2026-10-30, DECISIONS same date): run Codex's attended pilot once in a Terminal (`VideoScan-wt/attended-model-review`, `tools/model-fitness/attended_review.py --execute`); then the grading set — ≥ 3 historical bugs at pre-fix commits + their fixed versions as controls + one current folder; precision/recall/triage minutes per model; candidates Qwen3-Coder-30B-A3B 4-bit (M4) and Qwen3-Coder-Next 4-bit (Ultra); merge the pilot through the normal gate only after one useful run.

## Nightly UI smoke on the M4

- **Nightly UI smoke on the M4 (ruled 2026-10-28):** first unattended run 10/28 on 457d7e1b: 9/14 passed in 6 min (build 3.5 min). To make it nightly: (1) fix the 5 stale UI tests — Gauntlet02/03/04 drive the removed "Catalog Options" button (Rick names the control they should use now), CatalogKeyboard test8 wants the removed File ▸ Catalog Info, Gauntlet01 needs a synthetic non-family face fixture; (2) add a quit-and-relaunch smoke case; (3) M4 must not lock its screen overnight (XCUITest needs an unlocked session, 2026-07-20) — Rick's setting; (4) launchd UI lane before the 02:00 nightly, sharing its lock; (5) morning digest/metrics line for both Studios. Combine*UITests read the real catalog: keep them out until they use fixtures.

## UI tests, next increments

- **UI tests, next increments (Rick 2026-10-29, "it is important"):** (1) ~~Gauntlet flow 6+: open the Family Map~~ built on `test/ui-family-map`: flow 7 (`Gauntlet07FamilyMapUITests`) behind the `-gauntletFamilyTreeDir` seam and the synthetic `GauntletFamilyTreeFixture`; (2) ~~one repo script~~ built there too: `scripts/m4_run.sh ui|deep|all|status [--host m4|ultra]` (watchdog per plan, lock, `status` summary; the Ultra path is untested until Rick's screen is free; the design's verdict JSON, commit range and `refs/m4run/green` are still to do); (3) the Ultra's UI test builds are ad-hoc signed, so every rebuild re-asks for drive access; sign them with "VideoScan Local" so one Allow sticks (the M4 has no external drives, so it needs nothing). The Ultra now needs no password for Automation Mode (Rick ran `automationmodetool enable-automationmode-without-authentication` and `DevToolsSecurity -enable`, 10/29).

## Hallie benchmark 2026-10-28 follow-ups

- **Hallie benchmark 2026-10-28 follow-ups:** (1) harvest new live questions automatically from BOTH Macs at the nightly (`hallie_harvest_queries.py` is manual; last harvest 10/10; Rick's 10/10–10/27 chats are in the M4's logs) and show "N new questions waiting" in the morning metrics; (2) log per-turn latency in ms in the Hallie turn log so the harness reports median/p90 per question (timestamps are whole seconds); (3) Ollama differs: M4 0.40.12, Ultra 0.40.11 — align before host comparisons; (4) qwen3.8:27b-mlx scores 654/803 on the Ultra twice but 619/626 on the M4, while llama3.3:70b (llama.cpp) scores 604 on both — hypothesis: MLX numerics differ by chip generation; test by running the GGUF qwen build on both; (5) CyberBrain record for Dad Breen points at a stale Ancestry id (`@I342486893646@`) absent from the merged tree — every CyberBrain→tree link for him is broken (Rick's data call); (6) a CyberBrain exact alias "Dad" plus a stale pointer would still fall through to the tree name lookup — guard in `resolveDetailed`; (7) Rick to rule: strict-042 (why a photo is possible — unbuilt) and strict-045 ("how old was Dad" sometimes answered with the date only) were moved to advisory as model-dependent; keep there or pin red in strict.

## M4 real-media testbed

- M4 real-media testbed (Rick 2026-10-28): (1) an old SSD on the M4 holding a curated, expendable partial copy of real family media (every format and every known-awkward case, e.g. raw DV with one-sided sound), marked as a testbed by a marker file; automated tests may WRITE only to a marked testbed (promote, trash, relocate, repair on real media), never anywhere else; never in git, never to a cloud model. (2) The M4 as a read-only viewer of the Ultra's FamilyArchive over file sharing on the Thunderbolt bridge (viewer mode exists; check its speed and the network-volume privacy grant). (3) Overnight UI testing on the M4 against (1): a scripted run that drives every menu item in a copy of the catalog and reports what broke.

## M4 catalog fault-injection testbed

- M4 catalog fault-injection testbed (Rick 10/26): the M4 keeps (1) a continuously synced backup of catalog.sqlite (315 MB today; the viewer's sealed copy may already be it) and (2) a nightly fresh `.backup` copy that a fault suite attacks at production scale — torn/truncated pages, flipped bytes, missing or stale -wal/-shm, FK violations, newer schema, full disk, read-only folder, kill -9 mid-commit — asserting every case is refused in words or recovered, never silent loss. Never in git; stays on the M4.

## A7 measured 2026-10-30

- A7 measured 2026-10-30 (`docs/reviews/household_roster_feasibility.md`): sex + age band alone leaves one candidate for 42 % of tags on Rick-dated files (18 % once the owner's siblings join the roster); every tie is same-sex, same-generation, 1–3 years apart (the two older boys, the two younger boys, owner/brother, spouse/sisters, the two grandfathers). Next rungs: (1) co-presence as a constraint — one identified grandparent settles the couple, two boys in one frame are ordered by height; (2) a model attribute that is identity-bearing (relative height, glasses, face similarity to Rick's confirmed references within one occasion), not a better age guess; (3) data gaps: 54 of 73 Rick-dated files have no People tag, the fifth sibling and the spouse's siblings are missing from the People tab, camera dates agree with Rick's year only 1 in 4.

## Public view / web interface

- **Public view / web interface (Rick 2026-10-30, Charter §5 "Web Interface"; target Jan 2027, may move earlier if family asks):** a Public tab modelled on the Archive page (or folders by decade) showing only media Rick marked "Publish"; the Family Tree with notes, docs and maps in full; Hallie for guests limited to FT and published items; guest entry by link + simple password; the app must know which client is looking. Folds #244 (family web access read-only) and #42 (iPad browse); the family-viewer ruling comes first. Design when Rick says so.
