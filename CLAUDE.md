# VideoScan Project

## Manager role
When operating in this repo, you are the Manager. Read .claude/MANAGER.md for your protocol. Manager directs the activity of the sub-agents so the director (Rick) of this project can maintain the high-level view and direct agents to perform in their respective areas. Most especially, the QA and testing sub agents need to make sure we have no regressions and they can also look on GH for stats and CI and code metrics. 

## Overview
Personal video cataloging and person-finding suite for organizing family home videos across multiple storage volumes. Three components work together to catalog, search by face, and compile clips.

## Components

### 1. VideoScan.py (Python CLI)
- Scans volumes/folders recursively for video files (40+ formats)
- Extracts metadata via ffprobe (duration, codecs, resolution, frame rate, bitrate, color space, etc.)
- Generates Excel spreadsheet with catalog, summary stats, and skipped files
- Partial MD5 hashing for duplicate detection
- Color-coded rows by stream type (video+audio, video-only, audio-only)

### 2. PersonFinder.swift (Swift CLI)
- Standalone command-line face recognition tool
- Uses Apple Vision framework for face detection and feature printing
- Scans videos frame-by-frame, matches faces against reference photos
- Extracts clips containing matched person via ffmpeg
- Compiles clips into single video or decade-based chapter videos
- Configurable: match threshold (0.52), face confidence (0.55), frame step (5), concurrency (4)

### 3. VideoScan macOS App (SwiftUI)
- **Tab 1 - Catalog:** Scan volumes, display searchable results, correlate audio/video-only files, combine tracks, export CSV
- **Tab 2 - Person Finder:** Multi-job parallel face recognition, Apple Photos integration, configurable thresholds, real-time console per job, results table with Finder reveal
- Targets macOS 13+

## Key Files

| File | Purpose |
|------|---------|
| `scripts/VideoScan.py` | Python video catalog generator |
| `scripts/VideoScan.sh` | Bash wrapper for Python script |
| `scripts/face_recognize.py` | dlib-based face recognition engine (called by Swift app) |
| `scripts/fd_diagnostic.py` | Tier-1 dlib vs FaceNet confusion-matrix diagnostic; emits embeddings.npz |
| `scripts/fd_scan_volume.py` | Tier-1 single-volume person scanner using FaceNet+MTCNN |
| `scripts/find_person.py` | Multi-volume interactive person search CLI (CSV+HTML output) |
| `swift_cli/PersonFinder.swift` | Standalone Swift CLI for person finding |
| `swift_cli/FaceDetect.swift` | Face detection utilities |
| `swift_cli/FaceDiagnose.swift` | Face detection diagnostics CLI |
| `VideoScan/VideoScan/VideoScanApp.swift` | SwiftUI app entry point, about window |
| `VideoScan/VideoScan/ContentView.swift` | Tab UI, catalog view, combine dialog |
| `VideoScan/VideoScan/VideoScanModel.swift` | Core scanning, ffprobe, CSV export, audio/video correlation |
| `VideoScan/VideoScan/PersonFinderModel.swift` | Multi-job face recognition engine, reference loading, job lifecycle |
| `VideoScan/VideoScan/PersonFinderView.swift` | Person finder UI (reference bar, settings, jobs, results) |
| `tests/run_personfinder_tests.py` | Manifest-driven test runner for face recognition |
| `tests/personfinder_cases.json` | Test case definitions and expectations |

## Tech Stack
- **Languages:** Python 3, Swift 5
- **Frameworks:** SwiftUI, Vision, AVFoundation, CoreImage, CoreGraphics, Combine
- **External tools:** ffmpeg, ffprobe (via subprocess/Process)
- **Python libs:** openpyxl (Excel), hashlib (MD5)
- **Build:** Xcode

## Data & Reference Files
- `tests/fixtures/photos/` — Reference photos for unit tests
- `tests/fixtures/videos/` — Test video clips
- `assets/app_photos/` — Sample photos for app UI and about screen collage
- `assets/icon_previews/` — App icon concept previews
- Generated outputs: Excel catalogs (`.xlsx`), CSV reports (`Donna_report_*.csv`)

## Primary Use Case
Finding "Donna" across a large family home video collection. The project is dedicated to/inspired by Donna.

## Architecture Notes
- Person Finder uses parallel job processing — each scan target (volume/folder) runs as an independent job
- Face matching uses Vision framework's feature print distance (lower = closer match)
- Clip extraction groups consecutive face hits into segments, then uses ffmpeg to trim
- Video compilation uses ffmpeg concat demuxer
- Decade-chapter generation infers decade from file metadata/path

## Current Status
<!-- Update this section as work progresses -->
- Active development as of March 2026
- Core features operational: cataloging, face detection, clip extraction, compilation
- Recent work focused on PersonFinderModel and PersonFinderView

## Known Issues / TODOs
<!-- Add items here as they come up -->
-

## Design Decisions
<!-- Document non-obvious choices here -->
-

## Notes for Claude
<!-- Instructions for AI assistance -->
- This is a personal project — prioritize reliability with large video libraries
- macOS-native capabilities preferred (Vision, AVFoundation) over cross-platform alternatives
- ffmpeg/ffprobe are required external dependencies

## Build mode policy

- **Debug** for rapid dev iteration — Rick's solo edit/build/run loops AND paired RD sessions with Claude. Incremental compiles are 5–15s instead of ~3 min. Default when in doubt.
- **Release** for: (1) automated tests where production parity matters (TestDriver Smoke/Diagnostic, CI, perf baselines), (2) manual demo / family-facing runs, (3) bugs that only reproduce under the optimizer.
- Build-settings notes: Debug's `ONLY_ACTIVE_ARCH` should be `YES` (M1/M4 → arm64 only). Release keeps `SWIFT_COMPILATION_MODE = wholemodule` — that's the right call for production but is why Release rebuilds are slow on a one-line change.
- Adopted 2026-05-23 after a slow-Xcode investigation. Supersedes the prior "always Release" practice.


# VideoScan — Agent Team Configuration

This section augments the existing project CLAUDE.md. Append it (or merge as appropriate).

## Operating model

Rick is the Director (CTO). The main Claude Code session is the Manager. Six specialized subagents handle specific concerns:

- `feature-dev` — Swift/SwiftUI implementation
- `bug-fix` — diagnostic and remediation work
- `testing` — XCTest / Swift Testing
- `qa` — code review (read-only)
- `performance` — profiling and optimization
- `metrics` — codebase measurements

Subagent definitions are in `.claude/agents/`. The Manager protocol is in `.claude/agents/MANAGER.md`.

## Autonomy

Subagents operate in **full auto** within `~/dev/VideoScan` and `~/Library/Logs/VideoScan/`. They will not:
- Touch files outside those paths
- Run `git push` or other remote git operations
- Delete files (move to repo `.trash/` instead)
- Run unbounded memory operations

## Reporting style

Manager uses **adaptive** reporting: verbose for novel work, summary for routine work. Rick can switch modes mid-session by saying "verbose" or "summary."

## When to invoke each agent

Direct invocation by Rick uses the `/` form (slash commands defined in `.claude/commands/`). Manager invocation uses the Task tool with the agent name.

Common patterns:
- New feature → feature-dev → testing → qa → performance
- Bug report → bug-fix → testing (regression) → qa
- Hardening → metrics → qa → performance (Manager triages findings)
- Quick health check → metrics only

## Escalation

Manager stops and asks Rick before:
- Architectural decisions (new deps, threading model, schema changes)
- Non-additive SQLite schema changes
- Replacing the ExecuteShellCommand pattern
- Anything affecting existing recovered MXF pair data
- Anything affecting log file paths or formats
