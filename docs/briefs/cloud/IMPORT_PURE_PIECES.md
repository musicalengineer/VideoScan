# Cloud brief — Step D′ pure pieces: record mapping, import gate, comparator (VideoScan, 2026-10-17)

Linux cloud session, NO Xcode, no Swift toolchain: you cannot compile. Write Swift against the frozen
contract exactly as written; the Mac proves it. Mismatches cost a round trip, so cite the contract line for
every decision and prefer the simplest Swift that a `swift build` on macOS 15 / Swift 6.2 will accept
(no exotic macros; `Codable` + plain structs; one condition per `#expect`). Branch `feat/import-pure`
from main; commit by explicit path; message starting `feat(import): pure pieces —`; push the branch, never main.

Read first: `docs/design/catalog_contract_freeze_2026_10_17.md` (ALL of it — §a inventory, §b nested, §e
identity, §f gate + precedence, §g reconciliation), `docs/design/catalog_sqlite_schema_v1.sql` (v1.3),
`docs/design/catalog_sqlite_migration_2026_10_16.md` §10–§10d, the JSON store and record:
`VideoScan/VideoScan/Model/VideoRecord*.swift`, `Catalog/CatalogStore*.swift` (versions v1–v6 and their
golden fixtures under `VideoScan/VideoScanTests/` — find them), and the existing Core test style in
`VideoScan/VideoScanCore/Tests/VideoScanCoreTests/` (Swift Testing, `TimingBudget`, one condition per `#expect`).

Deliverables — ALL in `VideoScan/VideoScanCore/Sources/VideoScanCore/Import/` (new) and tests in
`VideoScan/VideoScanCore/Tests/VideoScanCoreTests/Import/`. PURE Swift only: no GRDB import, no SQLite, no
Foundation file I/O except reading fixture files in tests. The GRDB layer (another agent) will consume these.

1. **`CatalogRecordDTO`** — one `Codable`, `Sendable`, `Equatable` struct per table-shaped value of the
   contract: `FileRow` (the narrow `files` row), `ContentRow`, the nested evidence structs (fixity, audit stamp,
   scan context, sound stamp, removal marker…), and the knowledge values (curated: stars, user date/place/
   notes/tags, people confirmed/rejected, set-aside, promotion, lineage, footage decisions, report cards;
   derived: captions, transcripts, OCR, detected/suspected people, inferred dates, dossiers, dup candidates,
   A/V pairs). Field names follow the DDL column names. Include `init(record: VideoRecordJSON)` where
   `VideoRecordJSON` is a `Decodable` mirror of the JSON row for ALL 129 keys (the inventory lists them with
   optionality) — the importer decodes JSON into `VideoRecordJSON`, never into the app's `VideoRecord` class.
   Tests: decode every golden fixture v1–v6 → `VideoRecordJSON` → DTOs with zero data loss (every key in the
   fixture appears in some DTO or in the retained `raw` — assert by re-encoding and comparing key sets);
   enum raw values match the DDL CHECK lists (pin each enum's raw values against the DDL text read from
   the file at test time).
2. **`ImportGate`** — `static func decide(_ input: ImportGate.Input) -> Landing` where `Input` carries the
   per-row evidence named in §f (marker, audit result + the row's own stamp within the run window (N1),
   digest state incl. fixities-disagree, tier-5 findings with needsDecision, duplicate-id flag) and `Landing`
   is `.main(tombstoned: Bool)` / `.quarantine(reason: ReasonCode, words: String, findings: [Finding])`.
   Precedence exactly as §f (first match wins): duplicateId → fixityDisagree → marker set → audit result →
   digest → tier-5 → tier-4-only. Also `static func runLevelRefusals(_:) -> [RunRefusal]` for the run-level
   list in §f (JSON version, report outcome/certified/hash/generation, findings cap, tiers notRun, audit
   missing/partial/order, open plans, one writer). Tests: ONE test per row of the §f table (name the row),
   one per precedence collision, one per run-level refusal; the words are pinned verbatim from the contract.
3. **`ImportComparator`** — `static func compare(json: JSONSide, sqlite: SQLiteSide) -> Verdict` over two
   plain value inputs (the caller fills them: the JSON side re-decoded independently; the SQLite side as
   plain arrays of ids/digests/values): every JSON row occurrence exactly once in files ∪ quarantine by
   (run, ordinal); every distinct whole-file digest in content; every curated value present by digest or in
   raw_row (per §10b field list and §f comparator paragraph); every event member key, ledger line, ignored
   entry accounted for. `Verdict.ok` or `.misses([Miss])` with words per miss. Tests: a clean pair passes;
   one test per miss class (drop a row, drop a digest, drop one curated value, drop an event member, a
   duplicate landing).
4. **`PoisonedCatalogFixture`** — a builder that writes a small catalog.json (plus audit marker + integrity
   report JSON) with named shapes: a dead link row, a never-seen row, a sampled-only row, a changed-size row,
   a duplicate id pair, disagreeing fixities, two rows differing only by case, a supersession cycle, a
   reference-movie row, a tombstoned row with digest, a curated row with stars + user date on two copies with
   conflicting values. Used by 2 and 3 and by the Mac-side importer tests later.

Manifest: add the new test files to `scripts/gauntlet/manifest.json` with explicit test names (stage unit;
copy the sibling Core entries' shape). First line of your final answer:
`Files: <N> | DTO types: <N> | Gate tests: <N> | Comparator tests: <N> | Unverified (could not compile): yes`.
