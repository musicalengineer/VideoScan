# Hallie as a separate product — HallieKit + Hallie.app

**Status:** PROPOSED 2026-08-17 (Rick: "detach the Hallie Mae archivist as a
separate product which connects to VS seamlessly… make changes while VS is
running… eventually open the archive to family who search by talking to
Hallie"). Companion to `docs/cyberbrain_design.md`,
`docs/family-archivist-design.md`, `docs/hallie_grounded_composition.md`.

## Why

- Different cadence: the archivist changes daily; the catalog engine should not.
- Isolation: a Hallie crash or a model hiccup must never touch catalog.json.
- Audience: family members will use Hallie **read-only**. A cousin's Hallie
  must be able to read the archive and talk, and structurally unable to
  write the catalog.
- Placement: Hallie can run on another Mac (the living-room M1) against the
  same files.

## Three moves

### 1. HallieKit (SwiftPM package) — refactor, no behavior change
Move into one package everything from question to answer:
translation contract (`OllamaQueryTranslator`), `ArchivistQueryAST` + tolerant
decoder, planners/executors (presence, temporal, aggregate, graph/kinship/
familyTree, cross, follow-up resolver, conversation commands, capability
answers), CyberBrain (already in VideoScanCore — HallieKit depends on Core),
grounded composer + verifier, conversation memory, transcript log.

HallieKit talks to media through a **read model** protocol, never
`VideoScanModel`:

```swift
public protocol ArchiveReadModel: Sendable {
    func snapshot() async -> ArchiveSnapshot        // records (value DTOs), people, profiles, GEDCOM, CyberBrain root
    func record(id: UUID) async -> ArchiveRecordDTO?
    func revision() async -> ArchiveRevision         // for cache keys / freshness
}
public protocol ArchiveActions: Sendable {          // side effects the HOST performs
    func play(recordID: UUID, at seconds: Double?) async
    func reveal(recordID: UUID) async
    func showInCatalog(recordID: UUID) async
    func focusFamilyTree(personID: String) async
}
```
VS implements both in-process first (adapters over the existing model).
`hallie` shell CLI links HallieKit + a file-backed read model.

### 2. Hallie.app — own process, own window
- Reads `catalog.json` (OCC/lock contract: read-only, header-probe for
  freshness, the live-reload pattern), POI profiles, GEDCOM, CyberBrain,
  transcripts — all files. **Never writes catalog.json.**
- Owns the Ollama client, conversation memory, transcript log, portrait/
  persona, settings.
- Sends actions to VS over a tiny local channel: `videoscan://show?id=…`,
  `play`, `reveal`, `focus-tree`; VS registers the URL scheme and applies
  them (already has `pendingCatalogSelection` etc.). If VS isn't running,
  Hallie plays/reveals via NSWorkspace itself and says "open VideoScan to
  see it in the catalog".
- Family mode: `--family` / a setting → no CyberBrain writes, no interview
  proposals persisted, privacy ceiling `.family`, transcript log to the
  family member's own home.

### 3. Interview / edit mode lives in Hallie.app
Proposals → confirmation tier → CyberBrain items (own file + lock), per the
interview design in the memo. VS just reads the results.

## Contract discipline
- `ArchiveSnapshot` and DTOs are versioned (`schemaVersion`); Hallie refuses
  newer-than-known with a friendly message.
- Everything Hallie displays is traceable: citations carry record IDs; the
  transcript log carries claim tags (grounded composition).
- Tests: HallieKit gets its own test target with the golden corpus and the
  live eval; VS keeps only adapter tests.

## Sequencing
1. HallieKit extraction (mechanical; ~1 day) — after grounded composition lands.
2. Hallie.app skeleton (window + read model over files + URL actions) — 1–2 days.
3. Family mode + spoken answers (AVSpeechSynthesizer) — small.
4. Interview mode.
