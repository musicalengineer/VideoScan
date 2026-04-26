# VideoScan Project

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
