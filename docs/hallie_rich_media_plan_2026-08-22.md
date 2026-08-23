# Hallie rich media — overnight plan (2026-08-22 → 23)

Rick (Sat 21:00): *"enhance Hallie so she can handle rich media such as showing the family tree… restrict it to simple cases… Breen family crest… 'show Rick's maternal line back 5 generations', 'show the family tree for the Breen / Hudson / Latta family'… 'tell me about David McGill' shows a photo if one exists, else Hallie prompts: do you have a photo? put it here… trace the family back to England or Ireland… Family Tree part of the app connected to GEDCOM locally, later FamilySearch."*

## Ground rules (unchanged)
- Deterministic Swift composes facts; the LLM only phrases (docs/hallie_grounded_composition.md). **Attachments are presentation, never evidence** — nothing in an attachment reaches the translator prompt or the fact basis (same rule `ArchivistBiographyPhoto` already follows).
- No invented genealogy. Every lineage card is built from GEDCOM pointers and carries them as `evidenceIDs`. Public surname history lives in a data table, not control flow (codex #609).
- Work in worktrees; the shared tree stays on `main`. Branches: `feature/hallie-rich-media` (Claude), `feature/family-assets` (codex), `feature/family-tree-gedcom` (Claude's feature-dev agent).

## What exists (read 21:00)
| Piece | State |
|---|---|
| `GedcomFamilyGraph` (VideoScanCore) | names, sex, BIRT/DEAT/MARR dates, families; `relatives(.father/.mother/.siblings/.children/.spouse)`. **No PLAC, no multi-generation walks.** |
| `ArchivistGraphExecutor+Kinship` | single hop, extended hops, surname summary (`familyTreeSurnameResult` → text + "open Family Tree" chip). |
| `ArchivistMessage.biographyPhoto` | one POI cover photo on biography answers (Mac chat + shell). Web page: none. |
| `FamilyTreeDemoView` | **hard-coded demo people**; not connected to GEDCOM. Tab exists in ContentView. |
| `ArchivistCapabilityQuestion` | knows the word "gedcom" as a topic cue only — Hallie cannot explain what it is. |
| `scripts/hallie_eval.py` + `tests/hallie_eval_corpus.json` | 200-Q harness; add lineage cases. |
| GEDCOM location | `App Support/VideoScan/family-tree/originals/*.ged` (newest wins). |

## Shared contract — `HallieAttachment` (Claude writes first; everyone compiles against it)

```swift
// HallieTurnExecutor.swift
enum HallieAttachment: Sendable, Equatable {
    /// A verified image file (POI cover, or a person photo from the asset store).
    case photo(HalliePhotoAttachment)          // fileURL, caption, personName, crop
    /// A family crest/emblem for a surname, from the asset store.
    case crest(surname: String, fileURL: URL)
    /// Ordered generations walking UP from a root (maternal/paternal/both).
    case lineage(HallieLineageCard)            // title, root, generations: [[PersonCard]], line: .maternal/.paternal/.both
    /// A descendant outline walking DOWN from one or more roots, depth-limited.
    case tree(HallieTreeCard)                  // title, roots: [TreeNode] (node = PersonCard + spouses + children)
    /// "Do you have a photo of X? Put it here." with the folder to reveal.
    case photoRequest(personName: String, folderURL: URL)
}
struct HalliePersonCard: Sendable, Equatable { let gedcomID: String; let name: String; let years: String?; let birthPlace: String?; let photoURL: URL? }
```
- `HallieTurnExecutor.Result.attachments: [HallieAttachment]` (default `[]`). `ArchivistMessage.attachments` likewise; `biographyPhoto` becomes `.photo` (kept as a computed shim during the night, removed once all three renderers read `attachments`).
- Renderers: Mac chat (`HallieAttachmentView`), web page (`/api/attachment/<token>` for images; lineage/tree as nested HTML lists — no canvas drawing on the iPad tonight), shell (`HallieShellCLI+Render`: text outline so the eval harness can grade presence).

## Work split

### Claude (feature/hallie-rich-media) — tonight
1. Contract above + three renderers reading `attachments`.
2. `GedcomFamilyGraph`: parse `2 PLAC` for BIRT/DEAT (`birthPlace`, `deathPlace`, verbatim); `ancestorLine(of:line:generations:)`, `descendants(of:depth:)`, `rootAncestors(surname:)` (surname holders with no recorded parents), `originTrail(of:)` (ancestor walk collecting places; country match on last place component — Ireland/England/Scotland/Wales/Germany/Italy/Canada… table).
3. Question routes (parser + AST + executor): "maternal/paternal/mother's/father's line back N generations", "family tree for the X family / starting with the Lattas", "trace the family back to Ireland/England", "what is GEDCOM / where does your family tree come from" (capability answer: file name, people/families count, modified date, folder).
4. Biography answers attach `.photo` from POI cover **or** codex's asset store; when neither exists attach `.photoRequest` with the person folder (folder created on demand so Reveal in Finder works).
5. Eval corpus: 12 lineage/attachment cases; run the 200-Q harness before/after; no regression allowed.

### codex (feature/family-assets) — tonight
1. `FamilyAssetStore` (pure, injectable `root` + `cacheRoot`). **Rick 21:40: originals live in the Master Archive** — production root `<MasterArchiveRoot>/Family Tree/` (People/, Crests/, GEDCOM/) so photos and crests get the RAID's 3-2-1 protection; fallback root `App Support/VideoScan/family-tree/assets/` when no Master Archive is designated; `App Support/VideoScan/family-tree/thumbs/` = derived thumbnails only (so Hallie shows a face when the RAID is unmounted). The archive tree is app-managed (`excludingMasterArchiveFiles`); nothing here is added to the catalog scan.
   - `crests/<Surname>.{png,jpg,heic}` → `crestURL(surname:)` (case/diacritic-insensitive; "Breen" first, Rick supplies the image).
   - `people/<gedcomID>/` and `people/<normalized-name>/` → `photoURLs(for person:)` (regular, non-symlink image files only; same hardening as `ArchivistBiographyPhoto.resolve`).
   - `folderForPhotoRequest(person:)` creates the folder and returns it.
   - Tests: isolation (temp root), poisoned state (symlink, non-image, nested), unknown surname.
2. Family Tree tab **Crests pane** (sidebar section): lists crests found, "Add crest…" (NSOpenPanel copy into `crests/`), "Reveal in Finder". Keep it small.
3. `docs/familysearch_api_notes.md`: what the FamilySearch API needs (developer key, OAuth2, sandbox vs production, Person/Ancestry/Descendancy endpoints, rate limits, terms) and a recommended local-first design (GEDCOM stays source of truth; FamilySearch IDs stored as `_FSFTID`/custom tags). **Research only, no code, no credentials.**
4. Surname-history table: move `HallieSurnameReference`'s Breen entry into a `[Surname: Entry]` table (Hudson, Latta, McGill entries only if a public source is cited; otherwise leave them out).

### feature-dev agent (feature/family-tree-gedcom) — tonight, Claude-directed
Replace `FamilyTreeDemoView`'s demo data with a live model over `GedcomFamilyGraph`:
- `FamilyTreeLiveModel`: load newest GEDCOM (same loader); people list with search; selected root; layout = ancestors up (3 generations) and descendants down (2) on the existing canvas/card/line views; cards show name, years, surname, photo via an injected `photoProvider: (GedcomFamilyGraph.Person) -> NSImage?` (codex's store plugs in later; nil tonight).
- Incoming focus from Hallie chips (`ftHighlightedPersonName`, `ftIncomingSearchText`) selects the matching GEDCOM person.
- Demo data stays as the fallback when no `.ged` is present, with a one-line banner: "Demo tree — drop your GEDCOM in family-tree/originals".
- FamilySearch match cards become a single "Not connected to FamilySearch yet" card. No fake matches.
- Tests: a synthetic GEDCOM fixture (3 generations, a PLAC line, one person with no parents); layout is a pure function; 5k-person scale budget.

## Merge order (tomorrow morning, Rick)
1. `feature/hallie-rich-media` (contract + routes) 2. `feature/family-assets` (compiles against contract) 3. `feature/family-tree-gedcom`. Each: green suites + codex review + Rick.

## Not tonight
FamilySearch API calls; drawing trees on the iPad (HTML outline only); any LLM-phrased genealogy; drawing on the iPad; FamilySearch calls. (Photos/crests DO live in the Master Archive — Rick's 21:40 decision.)
