// CatalogDataSchema+Knowledge.swift (VideoScanCore/Store)
// §6: knowledge by digest — sources, curated display values, derived stamps, context, search text
// of catalog schema v1.4, verbatim from docs/design/catalog_sqlite_schema_v1.sql.
// See CatalogDataSchema.swift for the rule (raw SQL, character for
// character, interior comments kept) and the migration that runs these.
// Split from the main file along the DDL's own section boundary so each
// file stays readable. For Rick: an `extension` on an enum may hold
// static constants — a namespace continued in a second file.

extension CatalogDataSchema {

    // MARK: - knowledge_sources + 1 index, 3 triggers

    static let knowledgeSources: [String] = [
        """
        CREATE TABLE knowledge_sources (
          import_run     TEXT    NOT NULL REFERENCES import_runs(run_id) ON DELETE RESTRICT,
          source_ordinal INTEGER NOT NULL CHECK (source_ordinal >= 0),   -- the row's position in catalog.json
          json_row_id    TEXT    NOT NULL,                               -- VideoRecord.id as written (non-unique, F4)
          digest         TEXT    REFERENCES content(digest) ON DELETE RESTRICT, -- NULL: the row had no (agreeing) whole-file digest
          field          TEXT    NOT NULL CHECK (field IN (
                           -- §10b "curated — must survive", and the contract §a C rows:
                           'userNotes','tags','mediaDisposition','starRating','confirmedByUserPeople',
                           'rejectedPeople','userDate','userDateConfidence','userPlace','userPlaceConfidence',
                           'backupAttestations','repairConfirmedDate','footageDecisions','familyMusic',
                           'setAsideReason','archivedAt','archiveFixity','lineage','supersededByID',
                           'mediaReportCard')),
          value_json     TEXT    NOT NULL CHECK (json_valid(value_json)),  -- the DTO value, verbatim (lineage = the
                                                                          -- derivedFrom/derivationKind/cleanup*/trim* object)
          set_at         INTEGER,                                        -- when the value carries a stamp; else NULL
          source         TEXT    NOT NULL DEFAULT 'catalog.json',
          PRIMARY KEY (import_run, source_ordinal, field)
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE INDEX knowledge_sources_by_digest ON knowledge_sources(digest, field) WHERE digest IS NOT NULL
        """,
        """
        CREATE TRIGGER knowledge_sources_no_update BEFORE UPDATE ON knowledge_sources
        BEGIN SELECT RAISE(ABORT, 'knowledge_sources is append-only evidence'); END
        """,
        """
        CREATE TRIGGER knowledge_sources_no_delete BEFORE DELETE ON knowledge_sources
        BEGIN SELECT RAISE(ABORT, 'knowledge_sources is append-only evidence'); END
        """,
        """
        CREATE TRIGGER knowledge_sources_no_replace BEFORE INSERT ON knowledge_sources              -- F4
        WHEN EXISTS (SELECT 1 FROM knowledge_sources WHERE import_run = NEW.import_run
                      AND source_ordinal = NEW.source_ordinal AND field = NEW.field)
        BEGIN SELECT RAISE(ABORT, 'knowledge_sources: a duplicate is a finding, never a replacement'); END
        """,
    ]

    // MARK: - user_dates

    static let userDates: [String] = [
        """
        CREATE TABLE user_dates (
          digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          value       TEXT CHECK (value IS NULL
                                  OR value GLOB '[0-9][0-9][0-9][0-9]'
                                  OR value GLOB '[0-9][0-9][0-9][0-9]-[0-1][0-9]'
                                  OR value GLOB '[0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]'),
          confidence  TEXT CHECK (confidence IS NULL OR confidence IN ('estimated','known')),     -- F3
          set_at      INTEGER,                    -- unknown for imported values (JSON had no stamp)
          conflict    INTEGER NOT NULL DEFAULT 0 CHECK (conflict IN (0,1)),                       -- F2
          CHECK (value IS NOT NULL OR confidence IS NOT NULL OR conflict = 1)
        ) STRICT, WITHOUT ROWID
        """,
    ]

    // MARK: - user_places

    static let userPlaces: [String] = [
        """
        CREATE TABLE user_places (
          digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          place       TEXT CHECK (place IS NULL OR length(trim(place)) > 0),
          confidence  TEXT CHECK (confidence IS NULL OR confidence IN ('estimated','known')),     -- F3
          set_at      INTEGER,
          conflict    INTEGER NOT NULL DEFAULT 0 CHECK (conflict IN (0,1)),                       -- F2
          CHECK (place IS NOT NULL OR confidence IS NOT NULL OR conflict = 1)
        ) STRICT, WITHOUT ROWID
        """,
    ]

    // MARK: - stars

    static let stars: [String] = [
        """
        CREATE TABLE stars (
          digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          rating      INTEGER CHECK (rating IS NULL OR rating BETWEEN 1 AND 3),  -- 0 = unrated = no row
          conflict    INTEGER NOT NULL DEFAULT 0 CHECK (conflict IN (0,1)),                       -- F2
          CHECK (rating IS NOT NULL OR conflict = 1)
        ) STRICT, WITHOUT ROWID
        """,
    ]

    // MARK: - user_notes

    static let userNotes: [String] = [
        """
        CREATE TABLE user_notes (
          digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          text        TEXT CHECK (text IS NULL OR length(text) > 0),
          conflict    INTEGER NOT NULL DEFAULT 0 CHECK (conflict IN (0,1)),                       -- F2
          CHECK (text IS NOT NULL OR conflict = 1)
        ) STRICT, WITHOUT ROWID
        """,
    ]

    // MARK: - workflow_tags + 1 index

    static let workflowTags: [String] = [
        """
        CREATE TABLE workflow_tags (              -- a set: the union of the copies' tags (nothing to lose)
          digest      TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          tag         TEXT NOT NULL CHECK (length(trim(tag)) > 0),  -- canonical display form (WorkflowTags)
          PRIMARY KEY (digest, tag)
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE INDEX workflow_tags_by_tag ON workflow_tags(tag COLLATE NOCASE)
        """,
    ]

    // MARK: - people_tags + 1 index

    static let peopleTags: [String] = [
        """
        CREATE TABLE people_tags (
          digest       TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          name         TEXT NOT NULL CHECK (length(trim(name)) > 0),
          kind         TEXT NOT NULL CHECK (kind IN ('detected','suspected','confirmed','rejected')),
          confirmed_at INTEGER,                    -- ConfirmedTag.confirmedAt (confirmed only; earliest of the copies')
          conflict     INTEGER NOT NULL DEFAULT 0 CHECK (conflict IN (0,1)),                      -- F2
          provenance   TEXT CHECK (provenance = 'bound'),                          -- F9 N2 (machine kinds; imported → derived_unverified)
          CHECK ((kind = 'confirmed') = (confirmed_at IS NOT NULL)),
          CHECK ((kind IN ('detected','suspected')) = (provenance IS NOT NULL)),
          PRIMARY KEY (digest, name, kind)
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE INDEX people_tags_by_name ON people_tags(name COLLATE NOCASE, kind)
        """,
    ]

    // MARK: - family_music

    static let familyMusic: [String] = [
        """
        CREATE TABLE family_music (
          digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          performer   TEXT,
          title       TEXT,
          marked_at   INTEGER,
          conflict    INTEGER NOT NULL DEFAULT 0 CHECK (conflict IN (0,1)),                       -- F2
          CHECK (marked_at IS NOT NULL OR conflict = 1)
        ) STRICT, WITHOUT ROWID
        """,
    ]

    // MARK: - backup_attestations

    static let backupAttestations: [String] = [
        """
        CREATE TABLE backup_attestations (        -- a set: every copy's attestation is kept
          digest      TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          kind        TEXT NOT NULL CHECK (kind IN ('cloud','offsite','drive')),
          answer      TEXT NOT NULL CHECK (answer IN ('yes','no','notApplicable')),
          label       TEXT,
          attested_at INTEGER NOT NULL,
          by_whom     TEXT NOT NULL,
          conflict    INTEGER NOT NULL DEFAULT 0 CHECK (conflict IN (0,1)),   -- F2: same kind, different answers
          PRIMARY KEY (digest, kind, attested_at, answer, by_whom)
        ) STRICT, WITHOUT ROWID
        """,
    ]

    // MARK: - footage_decisions + 1 index

    static let footageDecisions: [String] = [
        """
        CREATE TABLE footage_decisions (
          decision_id    INTEGER PRIMARY KEY,
          import_run     TEXT REFERENCES import_runs(run_id) ON DELETE RESTRICT,   -- NULL: decided after cutover
          source_ordinal INTEGER,                  -- the owning row's position in catalog.json
          row_id         TEXT NOT NULL,            -- the row that carried footageDecisions
          other_row_id   TEXT NOT NULL,            -- FootageDecision.otherID
          digest         TEXT REFERENCES content(digest) ON DELETE RESTRICT,
          other_digest   TEXT REFERENCES content(digest) ON DELETE RESTRICT,
          verdict        TEXT NOT NULL CHECK (verdict IN ('same','notSame')),
          decided_at     INTEGER NOT NULL,
          CHECK (row_id <> other_row_id),          -- two rows; their digests may be equal            -- F3
          CHECK ((import_run IS NULL) = (source_ordinal IS NULL)),
          UNIQUE (import_run, source_ordinal, other_row_id, decided_at)
        ) STRICT
        """,
        """
        CREATE INDEX footage_decisions_by_digest ON footage_decisions(digest, other_digest)
        """,
    ]

    // MARK: - dispositions

    static let dispositions: [String] = [
        """
        CREATE TABLE dispositions (
          digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          disposition TEXT CHECK (disposition IS NULL OR disposition IN
                        ('Important','Recoverable','Suspected Junk','Confirmed Junk')),  -- 'Unreviewed' = no row
          conflict    INTEGER NOT NULL DEFAULT 0 CHECK (conflict IN (0,1)),                       -- F2
          CHECK (disposition IS NOT NULL OR conflict = 1)
        ) STRICT, WITHOUT ROWID
        """,
    ]

    // MARK: - sound_prints

    static let soundPrints: [String] = [
        """
        CREATE TABLE sound_prints (                -- AudioFingerprintStamp; landmarks stay in audio-fingerprints.sqlite
          digest          TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          engine_version  INTEGER NOT NULL CHECK (engine_version >= 1),
          outcome         TEXT    NOT NULL CHECK (outcome IN ('fingerprinted','noAudio')),
          analyzed_s      REAL    NOT NULL CHECK (analyzed_s >= 0),
          complete        INTEGER NOT NULL CHECK (complete IN (0,1)),
          landmarks       INTEGER NOT NULL CHECK (landmarks >= 0),
          blob_bytes      INTEGER NOT NULL CHECK (blob_bytes >= 0),
          computed_at     INTEGER NOT NULL,
          -- the sidecar's self-describing key; decoding a stamp INTO a digest strips this prefix
          sidecar_key     TEXT    NOT NULL GENERATED ALWAYS AS ('sha256:' || digest) VIRTUAL,
          CHECK (outcome = 'fingerprinted' OR (landmarks = 0 AND blob_bytes = 0))
        ) STRICT
        """,
    ]

    // MARK: - perceptual_prints

    static let perceptualPrints: [String] = [
        """
        CREATE TABLE perceptual_prints (           -- StoredPerceptualFingerprint (carries sizeBytes only)
          digest          TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          algorithm_version INTEGER NOT NULL CHECK (algorithm_version >= 1),
          hashes_b64      TEXT    NOT NULL,
          duration_s      REAL    NOT NULL,
          computed_at     INTEGER NOT NULL,
          provenance      TEXT    NOT NULL DEFAULT 'bound' CHECK (provenance = 'bound')  -- F9
        ) STRICT, WITHOUT ROWID
        """,
    ]

    // MARK: - captions + 2 triggers

    static let captions: [String] = [
        """
        CREATE TABLE captions (                    -- sceneCaptions / ocrDateCandidates / ocrText
          digest      TEXT    NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          kind        TEXT    NOT NULL CHECK (kind IN ('scene','ocrDate','ocrText')),
          seq         INTEGER NOT NULL CHECK (seq >= 0),   -- array order is meaningful (§9.3)
          at_s        REAL    NOT NULL,                     -- SceneCaption.timestamp
          text        TEXT    NOT NULL,
          provenance  TEXT    NOT NULL DEFAULT 'bound' CHECK (provenance = 'bound'),  -- F9
          PRIMARY KEY (digest, kind, seq)
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE TRIGGER captions_bound_dedupe BEFORE INSERT ON captions                               -- N2
        WHEN EXISTS (SELECT 1 FROM captions c WHERE c.digest = NEW.digest AND c.kind = NEW.kind AND c.seq = NEW.seq
                      AND c.text = NEW.text AND c.at_s = NEW.at_s)
        BEGIN SELECT RAISE(IGNORE); END
        """,
        """
        CREATE TRIGGER captions_bound_conflict BEFORE INSERT ON captions                             -- N2
        WHEN EXISTS (SELECT 1 FROM captions c WHERE c.digest = NEW.digest AND c.kind = NEW.kind AND c.seq = NEW.seq
                      AND (c.text IS NOT NEW.text OR c.at_s IS NOT NEW.at_s))
        BEGIN SELECT RAISE(ABORT, 'derived conflict: two bound values for one (digest, kind, seq) — move both to derived_unverified'); END
        """,
    ]

    // MARK: - derived_unverified + 1 index, 4 triggers

    static let derivedUnverified: [String] = [
        """
        CREATE TABLE derived_unverified (
          digest         TEXT    NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          kind           TEXT    NOT NULL CHECK (kind IN (
                           'scene','ocrDate','ocrText',            -- captions (seq = array index)
                           'captionRun','transcript','dossier','inferredDate',
                           'audioCheck','videoCheck','reportCard','perceptualPrint','footageMembership',
                           'detectedPerson','suspectedPerson')),   -- seq = array index; value = the name
          seq            INTEGER NOT NULL DEFAULT 0 CHECK (seq >= 0),
          source_json_row_id TEXT NOT NULL CHECK (length(source_json_row_id) = 36),
          value_json     TEXT    NOT NULL CHECK (json_valid(value_json)),   -- the DTO value, verbatim
          stamp_json     TEXT    NOT NULL DEFAULT '{}' CHECK (json_valid(stamp_json)), -- model / date / size it carried
          import_run     TEXT    REFERENCES import_runs(run_id) ON DELETE RESTRICT,
          source_ordinal INTEGER,
          conflict       INTEGER NOT NULL DEFAULT 0 CHECK (conflict IN (0,1)),
          CHECK ((import_run IS NULL) = (source_ordinal IS NULL)),
          PRIMARY KEY (digest, kind, seq, source_json_row_id)
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE INDEX derived_unverified_by_source ON derived_unverified(import_run, source_ordinal) WHERE import_run IS NOT NULL
        """,
        """
        CREATE TRIGGER derived_unverified_no_replace BEFORE INSERT ON derived_unverified             -- N2
        WHEN EXISTS (SELECT 1 FROM derived_unverified d WHERE d.digest = NEW.digest AND d.kind = NEW.kind
                      AND d.seq = NEW.seq AND d.source_json_row_id = NEW.source_json_row_id)
        BEGIN SELECT RAISE(ABORT, 'derived_unverified: a duplicate is a finding, never a replacement'); END
        """,
        """
        CREATE TRIGGER derived_unverified_flags_conflict AFTER INSERT ON derived_unverified           -- N2
        WHEN EXISTS (SELECT 1 FROM derived_unverified d WHERE d.digest = NEW.digest AND d.kind = NEW.kind
                      AND d.seq = NEW.seq AND d.source_json_row_id <> NEW.source_json_row_id
                      AND d.value_json IS NOT NEW.value_json)
        BEGIN
          UPDATE derived_unverified SET conflict = 1
           WHERE digest = NEW.digest AND kind = NEW.kind AND seq = NEW.seq AND conflict = 0
             AND EXISTS (SELECT 1 FROM derived_unverified o WHERE o.digest = NEW.digest AND o.kind = NEW.kind
                          AND o.seq = NEW.seq AND o.value_json IS NOT derived_unverified.value_json);
        END
        """,
        """
        CREATE TRIGGER derived_unverified_only_flag BEFORE UPDATE ON derived_unverified              -- N2
        WHEN NEW.digest IS NOT OLD.digest OR NEW.kind IS NOT OLD.kind OR NEW.seq IS NOT OLD.seq
          OR NEW.source_json_row_id IS NOT OLD.source_json_row_id OR NEW.value_json IS NOT OLD.value_json
          OR NEW.stamp_json IS NOT OLD.stamp_json OR NEW.import_run IS NOT OLD.import_run
          OR NEW.source_ordinal IS NOT OLD.source_ordinal OR NEW.conflict < OLD.conflict
        BEGIN SELECT RAISE(ABORT, 'derived_unverified is evidence: only conflict may rise'); END
        """,
        """
        CREATE TRIGGER derived_unverified_no_delete BEFORE DELETE ON derived_unverified              -- N2
        BEGIN SELECT RAISE(ABORT, 'derived_unverified is evidence; regeneration writes a bound row beside it'); END
        """,
    ]

    // MARK: - caption_runs

    static let captionRuns: [String] = [
        """
        CREATE TABLE caption_runs (                -- sceneCaptionModel / sceneCaptionDate
          digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          model       TEXT NOT NULL,
          made_at     INTEGER NOT NULL,
          provenance  TEXT NOT NULL DEFAULT 'bound' CHECK (provenance = 'bound')     -- F9
        ) STRICT, WITHOUT ROWID
        """,
    ]

    // MARK: - transcripts

    static let transcripts: [String] = [
        """
        CREATE TABLE transcripts (
          digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          text        TEXT NOT NULL,                -- '' = ran, found no speech (distinct from no row)
          model       TEXT,
          made_at     INTEGER,
          provenance  TEXT NOT NULL DEFAULT 'bound' CHECK (provenance = 'bound')     -- F9
        ) STRICT, WITHOUT ROWID
        """,
    ]

    // MARK: - dossiers

    static let dossiers: [String] = [
        """
        CREATE TABLE dossiers (
          digest       TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          processed_at INTEGER NOT NULL,
          processed_by TEXT    NOT NULL,
          provenance   TEXT    NOT NULL DEFAULT 'bound' CHECK (provenance = 'bound')  -- F9
        ) STRICT, WITHOUT ROWID
        """,
    ]

    // MARK: - inferred_dates

    static let inferredDates: [String] = [
        """
        CREATE TABLE inferred_dates (
          digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          date_at     INTEGER,                      -- NULL with a reason = "examined, no evidence"
          confidence  REAL    CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
          source      TEXT,                         -- NULL | 'catch-up' | 'propagated from <uuid>' | 'folder-year'
          range_start INTEGER,
          range_end   INTEGER,
          reason      TEXT,
          provenance  TEXT    NOT NULL DEFAULT 'bound' CHECK (provenance = 'bound'),  -- F9
          CHECK ((range_start IS NULL) = (range_end IS NULL)),
          CHECK (range_start IS NULL OR range_start <= range_end),
          CHECK (date_at IS NOT NULL OR reason IS NOT NULL)
        ) STRICT, WITHOUT ROWID
        """,
    ]

    // MARK: - media_checks

    static let mediaChecks: [String] = [
        """
        CREATE TABLE media_checks (                -- Verify Audio / Verify Video / Check Media report card
          digest      TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          kind        TEXT NOT NULL CHECK (kind IN ('audio','video','reportCard')),
          status      TEXT NOT NULL,
          note        TEXT NOT NULL DEFAULT '',
          checked_at  INTEGER,
          card        TEXT CHECK (card IS NULL OR json_valid(card)),   -- MediaReportCard, reportCard only
          provenance  TEXT NOT NULL DEFAULT 'bound' CHECK (provenance = 'bound'),   -- F9
          CHECK (kind <> 'audio'      OR status IN ('ok','damaged')),
          CHECK (kind <> 'video'      OR status IN ('ok','warning','broken')),
          CHECK (kind <> 'reportCard' OR (status IN ('quick','full') AND card IS NOT NULL)),
          PRIMARY KEY (digest, kind)
        ) STRICT, WITHOUT ROWID
        """,
    ]

    // MARK: - regen_context

    static let regenContext: [String] = [
        """
        CREATE TABLE regen_context (
          import_run     TEXT    NOT NULL REFERENCES import_runs(run_id) ON DELETE RESTRICT,
          source_ordinal INTEGER NOT NULL CHECK (source_ordinal >= 0),
          json_row_id    TEXT    NOT NULL,
          digest         TEXT    REFERENCES content(digest) ON DELETE RESTRICT,
          kind           TEXT    NOT NULL CHECK (kind IN (
                           'folderDate',      -- inferredDateSource 'folder-year' + its reason (the folder may be gone)
                           'donorDate')),     -- 'propagated from <uuid>' + reason; the donor row id verbatim
                           -- F9r3: r2's 'personSearched' (read from detected/suspected names) is REMOVED:
                           -- those are a search's OUTPUTS (hits), not its inputs; a zero-hit search left
                           -- none. Search evidence is `person_searches` below.
          value_json     TEXT    NOT NULL CHECK (json_valid(value_json)),
          reason         TEXT,
          PRIMARY KEY (import_run, source_ordinal, kind, value_json)
        ) STRICT, WITHOUT ROWID
        """,
    ]

    // MARK: - legacy_pair_ids + 1 index

    static let legacyPairIds: [String] = [
        """
        CREATE TABLE legacy_pair_ids (
          import_run     TEXT    NOT NULL REFERENCES import_runs(run_id) ON DELETE RESTRICT,
          source_ordinal INTEGER NOT NULL CHECK (source_ordinal >= 0),
          json_row_id    TEXT    NOT NULL,
          digest         TEXT    REFERENCES content(digest) ON DELETE RESTRICT,
          paired_with_id TEXT,                     -- pairedWithID verbatim
          pair_group_id  TEXT,                     -- pairGroupID verbatim
          event_member_keys TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(event_member_keys)),
          CHECK (paired_with_id IS NOT NULL OR pair_group_id IS NOT NULL),
          PRIMARY KEY (import_run, source_ordinal)
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE INDEX legacy_pair_ids_by_group ON legacy_pair_ids(pair_group_id)
        """,
    ]

    // MARK: - person_searches + 2 indexes, 3 triggers

    static let personSearches: [String] = [
        """
        CREATE TABLE person_searches (
          search_id      INTEGER PRIMARY KEY,
          digest         TEXT    REFERENCES content(digest) ON DELETE RESTRICT,  -- NULL: no main row with a digest at that path
          person_id      TEXT    CHECK (person_id IS NULL OR length(person_id) = 36),  -- POIProfile.uuid; pf_cache names only
          person_name    TEXT    NOT NULL CHECK (length(trim(person_name)) > 0),
          searched_at    INTEGER NOT NULL,         -- pf_cache.cached_at (REAL seconds, floored)
          engine         TEXT    NOT NULL,
          threshold      REAL    NOT NULL,
          hits           INTEGER NOT NULL CHECK (hits >= 0),
          outcome        TEXT    NOT NULL CHECK (outcome IN ('searched','unreadable')),  -- :1162 caches an
                                                   -- unreadable file as 0 hits, 0 s, 0 fps: NOT a zero-hit search
          source_json_row_id TEXT,                 -- the catalog row whose fullPath + sizeBytes the cache key named
          provenance     TEXT    NOT NULL CHECK (provenance IN ('bound','unverified')),
          source_key     TEXT    NOT NULL DEFAULT '{}' CHECK (json_valid(source_key)),  -- the pf_cache key, verbatim
          import_run     TEXT    REFERENCES import_runs(run_id) ON DELETE RESTRICT,
          source_ordinal INTEGER,
          CHECK ((import_run IS NULL) = (source_ordinal IS NULL)),
          CHECK (import_run IS NULL OR provenance = 'unverified'),
          CHECK (provenance <> 'bound' OR digest IS NOT NULL),
          CHECK (outcome = 'searched' OR hits = 0)
        ) STRICT
        """,
        """
        CREATE UNIQUE INDEX person_searches_by_source ON person_searches(import_run, source_ordinal) WHERE import_run IS NOT NULL
        """,
        """
        CREATE INDEX person_searches_by_digest ON person_searches(digest, person_name COLLATE NOCASE)
        """,
        """
        CREATE TRIGGER person_searches_no_update BEFORE UPDATE ON person_searches                    -- F9r3
        BEGIN SELECT RAISE(ABORT, 'person_searches is append-only evidence'); END
        """,
        """
        CREATE TRIGGER person_searches_no_delete BEFORE DELETE ON person_searches                    -- F9r3
        BEGIN SELECT RAISE(ABORT, 'person_searches is append-only evidence'); END
        """,
        """
        CREATE TRIGGER person_searches_no_replace BEFORE INSERT ON person_searches                   -- F9r3
        WHEN (NEW.search_id IS NOT NULL AND EXISTS (SELECT 1 FROM person_searches WHERE search_id = NEW.search_id))
          OR (NEW.import_run IS NOT NULL AND EXISTS (SELECT 1 FROM person_searches
                WHERE import_run = NEW.import_run AND source_ordinal = NEW.source_ordinal))
        BEGIN SELECT RAISE(ABORT, 'person_searches: a duplicate is a finding, never a replacement'); END
        """,
    ]

    // MARK: - content_text_fts

    static let contentTextFts: [String] = [
        """
        CREATE VIRTUAL TABLE content_text_fts USING fts5(
          text,
          digest UNINDEXED,
          kind UNINDEXED,
          seq UNINDEXED,
          provenance UNINDEXED,
          source_json_row_id UNINDEXED,
          tokenize = 'unicode61 remove_diacritics 2'
        )
        """,
    ]
}
