# Provenance — the designed schema changes, as drafted 2026-10-26 (cut from `docs/design/provenance.md`, 2026-11-01)

Status: archived — 2026-11-01. Cut from the live design by the Codex docs review (F02). What shipped differs: v13 is `v8_provenance_roles` (Set Role, 2026-10-26), and v14 is `v9_provenance_assertions` — the `provenance_assertions` table and its veto trigger only (DECISIONS 2026-11-01, "nothing else in v14"). The `picture_prints`, `content_excerpts`, carrier and capture-table DDL below is a draft for migrations not yet numbered or approved; the live design (`docs/design/provenance.md`, "Data model") lists them and links here.

The text below is the section as it stood, verbatim.

## Data model — schema changes (all additive; **each needs Rick's approval**, rule 6)

Phase A: **none.** Phase B: v13. Phase C: v14. Ledger kinds (`captured`, `carrierInspected`, `provenanceConfirmed`,
`transferSuperseded`, `excerptConfirmed`) are values in `ledger.kind` (plain TEXT), appended at the end of
`MediaLedgerEvent.Kind` — no migration.

### v13 `v8_picture_prints` (Phase B) — needs Rick's approval

```sql
-- The catalog's stamp for a v2 picture timeline; the hashes stay in picture-prints.sqlite.
-- Mirrors sound_prints. The 4 v1 rows in perceptual_prints are left as they are.
CREATE TABLE picture_prints (
  digest          TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  engine_version  INTEGER NOT NULL CHECK (engine_version >= 2),
  outcome         TEXT    NOT NULL CHECK (outcome IN ('fingerprinted','noPicture')),
  seconds         INTEGER NOT NULL CHECK (seconds >= 0),          -- timeline length
  usable_seconds  INTEGER NOT NULL CHECK (usable_seconds BETWEEN 0 AND seconds),  -- quality >= 50
  complete        INTEGER NOT NULL CHECK (complete IN (0,1)),
  crop            TEXT,                                           -- 'w:h:x:y' applied; NULL = none
  computed_at     INTEGER NOT NULL,
  sidecar_key     TEXT NOT NULL GENERATED ALWAYS AS ('sha256:' || digest) VIRTUAL,
  CHECK (outcome = 'fingerprinted' OR (seconds = 0 AND usable_seconds = 0))
) STRICT;
```

A failed decode is **not** stamped (listed on the job, retried next run), as for sound.

Sidecar `picture-prints.sqlite` (not a catalog migration; versioned by its own `schema` table):

```sql
CREATE TABLE schema (version INTEGER NOT NULL);           -- 1
CREATE TABLE prints (
  content_digest TEXT    NOT NULL,                        -- 'sha256:<hex>' only
  size_bytes     INTEGER NOT NULL,
  engine_version INTEGER NOT NULL,
  recipe_id      INTEGER NOT NULL,                        -- FNV-1a over every knob, as audio
  computed_at    INTEGER NOT NULL,
  source_path    TEXT    NOT NULL,
  seconds        INTEGER NOT NULL,
  complete       INTEGER NOT NULL,
  crop           TEXT,
  blob           BLOB    NOT NULL,                        -- "VSPT" v1: header, then per second: hash 32 B + quality u8
  PRIMARY KEY (content_digest, size_bytes, engine_version)
) WITHOUT ROWID;
```

### v14 `v9_provenance` (Phase C) — needs Rick's approval

The pattern is the one the catalog already uses for dates (`user_dates` beside `inferred_dates`): **typed tables hold
what Rick confirmed; `provenance_assertions` holds every machine draft, every human decision and every veto, append-only.**
Confirming writes both in one commit. Display = the typed value if Rick set it, else the best inferred assertion that
no rejection vetoes (`ProvenanceResolver`, pure).

```sql
-- C1: machine evidence that one content's picture/sound lies inside (or equals, or overlaps) another's.
-- No direction: 'inner'/'outer' are geometry, not generation (ruling 2026-09-23).
CREATE TABLE content_excerpts (
  seq            INTEGER PRIMARY KEY,
  inner_digest   TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  outer_digest   TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  verdict        TEXT NOT NULL CHECK (verdict IN ('same','contained','overlap')),
  proof          TEXT NOT NULL CHECK (proof IN ('sound','picture','both')),
  inner_start_s  REAL NOT NULL, inner_end_s REAL NOT NULL,
  outer_start_s  REAL NOT NULL, outer_end_s REAL NOT NULL,
  offset_s       REAL NOT NULL,                 -- inner's t=0 in outer's timeline
  coverage       REAL NOT NULL CHECK (coverage BETWEEN 0 AND 1),
  matched        INTEGER NOT NULL CHECK (matched >= 0),   -- landmarks or seconds
  sound_recipe   INTEGER,                        -- AudioFingerprint recipeID
  picture_engine INTEGER,                        -- picture_prints.engine_version
  found_at       INTEGER NOT NULL,
  CHECK (inner_digest <> outer_digest),
  CHECK (inner_start_s < inner_end_s AND outer_start_s < outer_end_s),
  CHECK (verdict = 'contained' OR inner_digest < outer_digest),        -- one canonical row for symmetric verdicts
  CHECK ((proof = 'picture') = (sound_recipe IS NULL)),
  CHECK ((proof = 'sound') = (picture_engine IS NULL)),
  UNIQUE (inner_digest, outer_digest, proof, sound_recipe, picture_engine)
) STRICT;
CREATE INDEX content_excerpts_by_outer ON content_excerpts(outer_digest);
CREATE TRIGGER content_excerpts_no_update BEFORE UPDATE ON content_excerpts
BEGIN SELECT RAISE(ABORT, 'content_excerpts is append-only evidence'); END;
CREATE TRIGGER content_excerpts_no_delete BEFORE DELETE ON content_excerpts
BEGIN SELECT RAISE(ABORT, 'content_excerpts is append-only evidence'); END;

-- C2: every value the machine proposes or Rick decides, per field, append-only.
CREATE TABLE provenance_assertions (
  seq           INTEGER PRIMARY KEY,
  subject_kind  TEXT NOT NULL CHECK (subject_kind IN ('content','carrier','captureEvent','captureSetup','excerpt')),
  subject_id    TEXT NOT NULL,                  -- digest hex, or the entity's UUID
  field         TEXT NOT NULL,                  -- 'role','carrier','tapeYear','format','digitizedOn','excerptOf',…
  value         TEXT NOT NULL,
  state         TEXT NOT NULL CHECK (state IN ('inferred','confirmed','corrected','rejected')),
  by            TEXT NOT NULL CHECK (by = 'rick' OR by GLOB 'machine:*'),  -- 'machine:<engine>:<version>'
  at            INTEGER NOT NULL,
  confidence    REAL CHECK (confidence BETWEEN 0 AND 1),
  evidence_json TEXT NOT NULL CHECK (json_valid(evidence_json)),
  CHECK ((state = 'inferred') = (by GLOB 'machine:*')),            -- only the machine infers; only Rick decides
  CHECK (state <> 'inferred' OR confidence IS NOT NULL)
) STRICT;
CREATE INDEX provenance_assertions_by_subject
  ON provenance_assertions(subject_kind, subject_id, field, value, seq);
-- The veto: a value whose latest human decision is 'rejected' can never be re-proposed.
-- IGNORE (not ABORT) so a batch of drafts survives; the writer reads changes() and logs "vetoed".
CREATE TRIGGER provenance_assertions_veto BEFORE INSERT ON provenance_assertions
WHEN NEW.state = 'inferred' AND (
  SELECT state FROM provenance_assertions
   WHERE subject_kind = NEW.subject_kind AND subject_id = NEW.subject_id
     AND field = NEW.field AND value = NEW.value AND state <> 'inferred'
   ORDER BY seq DESC LIMIT 1) = 'rejected'
BEGIN SELECT RAISE(IGNORE); END;
CREATE TRIGGER provenance_assertions_no_update BEFORE UPDATE ON provenance_assertions
BEGIN SELECT RAISE(ABORT, 'provenance_assertions is append-only'); END;
CREATE TRIGGER provenance_assertions_no_delete BEFORE DELETE ON provenance_assertions
BEGIN SELECT RAISE(ABORT, 'provenance_assertions is append-only'); END;

-- C2: the confirmed records (10/23 deep dive shape). Rows are never deleted; a correction updates the
-- typed row AND appends 'rejected'(old) + 'corrected'(new) assertions in the same commit.
CREATE TABLE capture_setups (
  setup_id        TEXT PRIMARY KEY NOT NULL,
  name            TEXT NOT NULL,
  coding_history  TEXT NOT NULL,                -- EBU R98 lines, one per stage
  software        TEXT, operator TEXT,
  active_from     INTEGER, active_to INTEGER,
  created_at      INTEGER NOT NULL
) STRICT, WITHOUT ROWID;
CREATE TABLE carriers (
  carrier_id      TEXT PRIMARY KEY NOT NULL,
  shelf_number    TEXT UNIQUE,                  -- Rick's label on the cassette; the human key
  format          TEXT NOT NULL CHECK (format IN ('VHS','VHS-C','S-VHS','Hi8','Video8','Digital8','MiniDV','DV',
                    'Betamax','DVD','8mm film','Super 8mm film','Audio cassette','other','unknown')),
  format_detail   TEXT,
  generation      TEXT NOT NULL DEFAULT 'Original' CHECK (generation IN ('Original','Dub','Duplicate','unknown')),
  label_text      TEXT,
  label_photo_digest TEXT REFERENCES content(digest) ON DELETE RESTRICT,
  tape_year       INTEGER CHECK (tape_year BETWEEN 1900 AND 2100),
  year_label      TEXT,
  videographer    TEXT,
  kept            INTEGER CHECK (kept IN (0,1)),
  condition       TEXT CHECK (condition IN ('good','fair','poor','damaged','unknown')),
  condition_notes TEXT,
  inspected_at    INTEGER,
  created_at      INTEGER NOT NULL
) STRICT, WITHOUT ROWID;
CREATE TABLE capture_events (
  event_id        TEXT PRIMARY KEY NOT NULL,
  carrier_id      TEXT NOT NULL REFERENCES carriers(carrier_id) ON DELETE RESTRICT,
  setup_id        TEXT REFERENCES capture_setups(setup_id) ON DELETE RESTRICT,
  captured_at     INTEGER, captured_until INTEGER,
  take            INTEGER NOT NULL DEFAULT 1 CHECK (take >= 1),
  signal_notes    TEXT,
  created_at      INTEGER NOT NULL,
  CHECK (captured_until IS NULL OR captured_at <= captured_until)
) STRICT, WITHOUT ROWID;
CREATE INDEX capture_events_by_carrier ON capture_events(carrier_id);
CREATE TABLE carrier_spans (
  digest           TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  carrier_id       TEXT NOT NULL REFERENCES carriers(carrier_id) ON DELETE RESTRICT,
  capture_event_id TEXT REFERENCES capture_events(event_id) ON DELETE RESTRICT,
  file_start_s     REAL NOT NULL, file_end_s REAL NOT NULL,
  confirmed_at     INTEGER NOT NULL,
  CHECK (file_start_s >= 0 AND file_start_s < file_end_s),
  PRIMARY KEY (digest, carrier_id, file_start_s)
) STRICT, WITHOUT ROWID;
CREATE INDEX carrier_spans_by_carrier ON carrier_spans(carrier_id);
CREATE TABLE file_provenance (
  digest               TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  role                 TEXT NOT NULL CHECK (role IN ('preservation','access','edit','test','bornDigital','unknown')),
  digitized_on         INTEGER,
  superseded_by_digest TEXT REFERENCES content(digest) ON DELETE RESTRICT,
  superseded_reason    TEXT,
  confirmed_at         INTEGER NOT NULL,
  CHECK (superseded_by_digest IS NULL OR superseded_by_digest <> digest),
  CHECK ((superseded_by_digest IS NULL) = (superseded_reason IS NULL))
) STRICT, WITHOUT ROWID;
CREATE TRIGGER carriers_no_delete BEFORE DELETE ON carriers
BEGIN SELECT RAISE(ABORT, 'carriers rows are never deleted'); END;
-- (same no_delete trigger on capture_setups, capture_events, carrier_spans, file_provenance)
```

Role codes are ours; `Provenance.csv` writes the PBCore word beside each (`preservation` → `Preservation`, `access` →
`Copy: Access`, `edit` → `Master: production`, `test` → `Work tapes`, `bornDigital` → `Original`).

