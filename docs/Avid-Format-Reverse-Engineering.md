# Avid Format Reverse Engineering

Technical documentation for VideoScan's native parsers that extract metadata from Avid proprietary binary formats. These parsers enable cataloging of orphaned Avid media — files that can no longer be opened in Media Composer due to lapsed licenses or missing project databases.

## Table of Contents

1. [Background & Motivation](#background--motivation)
2. [MXF Container Format](#mxf-container-format)
3. [MXF Header Fallback Parser](#mxf-header-fallback-parser)
4. [Avid Bin (.avb) Format](#avid-bin-avb-format)
5. [Avid Bin Parser](#avid-bin-parser)
6. [Cross-Referencing Strategy](#cross-referencing-strategy)
7. [References & Sources](#references--sources)

---

## Background & Motivation

Avid Media Composer stores media in a proprietary ecosystem:

- **MXF files** (.mxf) — the actual audio/video essence, one stream per file (OP-Atom)
- **Bin files** (.avb) — project metadata: clip names, timecodes, which MXF files belong to which clip
- **Project files** (.avp) — project-level settings and bin references

When an Avid license lapses, the media files remain on disk but lose their organizational context. The .avb bins are the Rosetta Stone — they map human-readable clip names to the cryptically-named MXF files (e.g., `00042.V14BB54799.mxf`).

Standard tools like ffprobe can read most MXF files, but fail on certain Avid-specific codecs (uncompressed RGB with proprietary pixel packing). VideoScan's native parsers fill both gaps: reading bin metadata and extracting MXF header info when ffprobe can't.

---

## MXF Container Format

### Overview

MXF (Material Exchange Format) is a SMPTE standard (ST 377) container format used throughout the broadcast and post-production industry. Avid uses the **OP-Atom** profile: one essence stream per file.

### File Naming Convention

Avid MXF files follow a predictable naming scheme:

```
NNNNN.{TYPE}{HEXID}.mxf
```

| Component | Meaning | Example |
|-----------|---------|---------|
| `NNNNN` | Sequential clip index | `00042` |
| `A1` | Audio track 1 | `00042.A14B9428AB.mxf` |
| `A2` | Audio track 2 | `00042.A24B9428AB.mxf` |
| `V1` | Video track | `00042.V14BB54799.mxf` |
| `PHYSV01` | Physical (rendered) video | `00000.PHYSV01.C80E34BE8C52A.mxf` |
| `{ClipName}` | Named render output | `Boston.Sequence4C6B6465.mxf` |

The hex ID portion relates to the Avid MobID and can be used for cross-referencing with .avb bin metadata.

### KLV Encoding

MXF files are structured as a sequence of **KLV** (Key-Length-Value) triplets:

```
┌──────────────────┬───────────────┬──────────────────────┐
│  Key (16 bytes)  │ Length (BER)  │  Value (N bytes)     │
│  SMPTE UL        │ 1-9 bytes    │  payload             │
└──────────────────┴───────────────┴──────────────────────┘
```

**Key**: A 16-byte SMPTE Universal Label (UL), always starting with `06.0e.2b.34`. The remaining 12 bytes identify the item type per SMPTE RP 224 (the SMPTE Metadata Registry).

**Length**: BER (Basic Encoding Rules) encoded:
- If first byte < 0x80: length = that byte (short form)
- If first byte = 0x80 | N: next N bytes are the length in big-endian

**Value**: The payload, whose structure depends on the Key.

### Partition Structure

An MXF file has three partitions:

```
┌─────────────────────────┐
│  Header Partition Pack  │  ← file offset 0
│  Header Metadata        │  ← KLV sets describing the content
│  (Primer Pack)          │  ← maps local tags to ULs
│  (Preface, Packages,    │
│   Descriptors, Tracks)  │
├─────────────────────────┤
│  Body Partition(s)      │  ← essence data (audio/video frames)
├─────────────────────────┤
│  Footer Partition        │  ← optional index tables
└─────────────────────────┘
```

All metadata lives in the **Header Partition** (first ~64-256 KB). The parser only reads this region.

### Descriptor Sets

Within the header metadata, **Descriptor** sets describe the essence:

| Descriptor UL Suffix | Type | Contains |
|---------------------|------|----------|
| `...0101.2900` | RGBADescriptor | Uncompressed RGB video |
| `...0101.2800` | CDCIDescriptor | Component (YCbCr) video — DNxHD, DV, etc. |
| `...0101.2700` | GenericPictureDescriptor | Base video descriptor |
| `...0101.4800` | WAVEAudioDescriptor | PCM audio |
| `...0101.4200` | GenericSoundDescriptor | Base audio descriptor |
| `...0101.4700` | AES3AudioDescriptor | AES3 audio |

Descriptors contain **local tag sets** (2-byte tag + 2-byte length + value, all big-endian):

| Tag | Name | Size | Description |
|-----|------|------|-------------|
| `0x3203` | Stored Width | uint32 | Horizontal pixels |
| `0x3202` | Stored Height | uint32 | Vertical pixels |
| `0x3201` | Picture Essence Coding | 16-byte UL | Codec identifier |
| `0x3001` | Sample Rate | rational (2×uint32) | Frame rate as num/den |
| `0x3002` | Container Duration | uint64 | Duration in edit units |
| `0x320E` | Frame Layout | uint8 | 0=progressive, 1=separate fields |
| `0x320D` | Video Line Map | array | Field line positions |
| `0x3401` | Pixel Layout | byte pairs | Component code + bit depth |
| `0x3D07` | Channel Count | uint32 | Audio channels |
| `0x3D03` | Audio Sampling Rate | rational | Sample rate (e.g., 48000/1) |
| `0x3D01` | Quantization Bits | uint32 | Audio bit depth |

### Pixel Layout Encoding

The Pixel Layout tag (`0x3401`) encodes component information as byte pairs terminated by `(0, 0)`:

| Byte | Component |
|------|-----------|
| `0x52` | R (Red) |
| `0x47` | G (Green) |
| `0x42` | B (Blue) |
| `0x41` | A (Alpha) |
| `0x46` | F (Fill/Padding) |
| `0x59` | Y (Luminance) |

Example: `52 0A 47 0A 42 0A 46 02 00 00` = R10 G10 B10 F2 (Avid 10-bit RGB with 2-bit fill)

### Codec Identification via Essence Coding UL

The Picture Essence Coding UL (tag `0x3201`) identifies the codec. Key patterns:

| UL Pattern (bytes 9+) | Codec |
|-----------------------|-------|
| `04.01.02.01...` | Uncompressed video |
| `04.01.02.02.02...` | DV family |
| Contains `03.71` | DNxHD / VC-3 |
| Byte 8 = `0e` | Avid private (uncompressed RGB) |
| Contains `04.01.02.03` | H.264 / AVC |

### Codecs Observed on InternalRaid Volume

| Codec | ffprobe Status | File Pattern | Count |
|-------|---------------|--------------|-------|
| DNxHD | OK | `V14D1B*.mxf` | ~100 |
| DV (dvvideo) | OK | `PHYSV01*.mxf` | ~15 |
| Avid Uncompressed 10-bit RGB | **FAILS** | `V14BB*.mxf` | ~80 |
| PCM Audio (16-bit/48kHz) | Partial* | `A1*.mxf`, `A2*.mxf` | ~220 |

*ffprobe reads the audio MXF but misidentifies streams as `data` type instead of `audio`.

---

## MXF Header Fallback Parser

**File**: `VideoScan/VideoScan/MxfHeaderParser.swift`

### Algorithm

1. **Read header** — mmap first 256KB of the file (covers all header metadata)
2. **Validate** — check for MXF UL prefix `06.0e.2b.34` at offset 0
3. **Walk KLV triplets** — scan for descriptor set keys by matching UL suffixes
4. **Parse local tags** — within each descriptor, extract resolution, codec, duration, etc.
5. **Derive metadata** — compute frame rate from rational sample rate, duration in seconds from edit units, codec label from essence coding UL
6. **Return** — `MxfMetadata` struct with all extracted fields

### When It Runs

Integrated as a fallback in `ScanEngine.probeFile()`:

```
ffprobe succeeds → use ffprobe data (normal path)
ffprobe fails + .mxf extension → MxfHeaderParser.parse() → use MXF header data
ffprobe fails + other extension → mark as "ffprobe failed"
```

### What It Extracts

Even when ffprobe can't decode the codec, the MXF header contains:
- Resolution (e.g., 1920x1080)
- Codec label (e.g., "Avid Uncompressed")
- Frame rate (e.g., 29.97 fps from 30000/1001)
- Duration in seconds
- Pixel format details (e.g., "RGBF 10+10+10+2")
- Audio channel count, sample rate, bit depth

### Limitations

- Does not decode essence data — can identify the codec but not play the file
- Relies on descriptor sets being in the first 256KB (true for all observed Avid OP-Atom files)
- Codec identification is heuristic-based on UL patterns; may return "Unknown" for rare codecs

---

## Avid Bin (.avb) Format

### Overview

Avid bin files (.avb) are binary databases that store clip metadata. They derive from the **OMF (Open Media Framework)** interchange format and use a class-based object serialization scheme.

### File Structure

```
┌─────────────────────────────┐
│  Header (magic + version)   │  2-4 bytes
├─────────────────────────────┤
│  Object Position Table      │  array of file offsets
├─────────────────────────────┤
│  Serialized Objects         │  variable-length class instances
│  ┌───────────────────────┐  │
│  │ FourCC class ID        │  │  e.g., "ABIN", "CMPO", "SCLP"
│  │ Object data            │  │  class-specific fields
│  │ Tagged extensions      │  │  variable-length tag-value pairs
│  └───────────────────────┘  │
└─────────────────────────────┘
```

### Byte Order Detection

The file starts with a 2-byte magic number:
- `0x00 0x11` → little-endian (Intel Mac, most common)
- `0x11 0x00` → big-endian (PowerPC Mac, older files)

The parser auto-detects endianness from this magic number.

### Object Hierarchy

```
Bin (ABIN/BINF)
 └── BinItem
      └── Composition / Mob (CMPO)
           ├── Name (clip name)
           ├── MobID (SMPTE UMID — 32 bytes)
           ├── MobType (CompositionMob, MasterMob, SourceMob)
           └── TrackGroup (TRKG)
                └── Track(s)
                     └── SourceClip (SCLP)
                          ├── Source MobID (reference to another mob)
                          ├── Start position
                          ├── Length
                          └── MediaDescriptor (MDES)
                               ├── Media kind ("picture", "sound")
                               └── MediaFileDescriptor (MDFL)
                                    └── FileLocator (FILE/WINF)
                                         └── File path
```

### Key Class IDs (FourCC)

| FourCC | Class | Purpose |
|--------|-------|---------|
| `ABIN` / `BINF` | Bin | Top-level container |
| `CMPO` | Composition | A clip/sequence (Mob) |
| `SCLP` | SourceClip | Reference to media or another mob |
| `TRKG` | TrackGroup | Collection of tracks in a mob |
| `MDES` | MediaDescriptor | Describes media kind |
| `MDFL` | MediaFileDescriptor | Physical media file info |
| `MDTP` | TapeDescriptor | Tape name for captured media |
| `FILE` / `WINF` | FileLocator | Path to the MXF file on disk |

### MobID / UMID

The MobID is a 32-byte **SMPTE Unique Material Identifier (UMID)** per ST 330. It is the primary key linking bin metadata to MXF files.

Format: `urn:smpte:umid:XXXXXXXX.XXXXXXXX.XXXXXXXX.XXXXXXXX`

Each MXF file also contains its MobID in the header metadata, enabling cross-referencing even when files have been renamed or moved.

### Tagged Extension Fields

After the core fields of each object, Avid appends variable-length tagged extensions:

| Tag | Size | Content |
|-----|------|---------|
| 65 | 1 byte | Boolean |
| 68 | 4 bytes | Int32 |
| 69 | string | String with length prefix |
| 70 | 4 bytes | Object reference |
| 71 | 8 bytes | Int64 |
| 72 | variable | Sub-object (recursive) |
| 73 | variable | Object reference array |
| 76 | variable | Tagged attribute list |

The parser must consume these to advance past each object correctly, even when the specific tags aren't needed.

---

## Avid Bin Parser

**File**: `VideoScan/VideoScan/AvbParser.swift`

### Algorithm

1. **Read file** — load entire .avb file into memory (typically small, <1MB)
2. **Detect endianness** — from 2-byte magic number
3. **Read object table** — array of file offsets to each serialized object
4. **Parse Bin object** — find the ABIN/BINF root, read item count
5. **For each BinItem** — follow the object reference chain:
   - Parse Composition (CMPO) → extract clip name, MobID, mob type
   - Parse TrackGroup (TRKG) → iterate tracks
   - Parse SourceClip (SCLP) → get source mob reference, media kind
   - Parse MediaDescriptor chain → follow to FileLocator for file path
6. **Build clip list** — return `[AvbClip]` with name, MobID, tracks, tape name, edit rate, media paths

### Cross-Referencing with MXF Files

The parser feeds into `VideoScanModel.crossReferenceAvidBins()` which matches clips to scanned MXF records:

**Current strategy (filename stem matching)**:
1. Extract the hex ID from the MXF filename (e.g., `4BB54799` from `00042.V14BB54799.mxf`)
2. Match against file paths stored in .avb FileLocator objects
3. Also match on directory structure (`Avid MediaFiles/MXF/N/`)

**Future strategy (MobID matching)**:
1. Parse MobID from .avb SourceClip references
2. Parse MobID from MXF header metadata (MaterialPackage/SourcePackage)
3. Match on the 32-byte UMID — definitive, survives file renaming

### Reference Source

The .avb parser was reverse-engineered from **pyavb** by Mark Reid (MIT license), a Python library for reading/writing Avid bin files. The binary format understanding was derived from studying pyavb's source code, then reimplemented natively in Swift for distribution as a self-contained Mac app.

- pyavb repository: https://github.com/markreidvfx/pyavb
- License: MIT

---

## Cross-Referencing Strategy

The ultimate goal is to reconstruct the relationship between orphaned Avid media files:

```
.avb bin files ──→ clip names, timecodes, MobIDs
                   ↓
              maps to
                   ↓
.mxf media files ──→ video essence + audio essence (separate files)
                   ↓
              VideoScan correlates
                   ↓
         Audio-only + Video-only → Combined playable clip
```

### Three Layers of Matching

1. **Filename pattern** (immediate) — Match MXF naming convention to clip index
2. **Path matching** (current) — .avb FileLocator paths → MXF file locations
3. **MobID/UMID matching** (planned) — Definitive cross-reference via 32-byte unique IDs

### Handling ffprobe Failures

When ffprobe fails (Avid uncompressed RGB, proprietary codecs):
1. MXF header parser extracts resolution, frame rate, duration, codec label
2. File is cataloged with partial metadata instead of being marked as total failure
3. Cross-referencing still works — the file is in the catalog with its path and metadata

---

## References & Sources

| Resource | URL / Location | Notes |
|----------|---------------|-------|
| SMPTE ST 377-1 | (standard) | MXF File Format Specification |
| SMPTE ST 379-2 | (standard) | MXF OP-Atom (Avid's profile) |
| SMPTE ST 330 | (standard) | UMID — Unique Material Identifier |
| SMPTE RP 224 | (standard) | SMPTE Metadata Registry (UL assignments) |
| pyavb | github.com/markreidvfx/pyavb | Python .avb parser (MIT) — reference impl |
| ffprobe | Homebrew `ffmpeg` package | Primary metadata extraction tool |
| VideoScan MxfHeaderParser | `VideoScan/MxfHeaderParser.swift` | Native Swift MXF KLV parser |
| VideoScan AvbParser | `VideoScan/AvbParser.swift` | Native Swift .avb binary parser |

---

*Last updated: 2026-04-10*
*Authors: Rick B. (architecture & domain expertise), Claude (implementation & format analysis)*
