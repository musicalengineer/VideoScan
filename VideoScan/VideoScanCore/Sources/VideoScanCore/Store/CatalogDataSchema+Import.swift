// CatalogDataSchema+Import.swift (VideoScanCore/Store)
// §8–§10: quarantine, import runs, certifying sidecars, the ledger
// of catalog schema v1.6, verbatim from docs/design/catalog_sqlite_schema_v1.sql.
// See CatalogDataSchema.swift for the rule (raw SQL, character for
// character, interior comments kept) and the migration that runs these.
// Split from the main file along the DDL's own section boundary so each
// file stays readable. For Rick: an `extension` on an enum may hold
// static constants — a namespace continued in a second file.

extension CatalogDataSchema {

    // MARK: - quarantine + 3 indexes, 3 triggers

    static let quarantine: [String] = [
        """
        CREATE TABLE quarantine (
          qid           INTEGER PRIMARY KEY,
          origin        TEXT    NOT NULL CHECK (origin IN ('import','rescan')),
          import_run    TEXT    REFERENCES import_runs(run_id) ON DELETE RESTRICT,                -- F4
          source_ordinal INTEGER CHECK (source_ordinal IS NULL OR source_ordinal >= 0),           -- F4
          json_row_id   TEXT    CHECK (json_row_id IS NULL OR length(json_row_id) = 36),  -- VideoRecord.id, NON-unique
          full_path     TEXT    NOT NULL,
          size_bytes    INTEGER,
          digest        TEXT    CHECK (digest IS NULL OR (length(digest) = 64 AND digest NOT GLOB '*[^0-9a-f]*')),
          -- F10: every whole-file digest the row carried (both, when contentFixity and archiveFixity
          -- disagree). On disagreement `digest` stays NULL: no knowledge identity is selected.
          evidence_digests TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(evidence_digests)),
          sampled_hash  TEXT,                        -- the v1: value, as evidence only
          reason_code   TEXT    NOT NULL CHECK (reason_code IN
                          ('noWholeFileDigest','auditGone','auditNeverSeen','auditCouldNotCheck','auditChanged',
                           'tier5Finding','referenceMovie','fixityDisagree','duplicateId','removedNoDigest',
                           'stillBeingWritten','pathReplaced','unreadable',
                           'unrepresentable')),                        -- fix 2026-10-17 (codex D′ #6): a row a row-local CHECK would refuse
          reason_class  TEXT    NOT NULL GENERATED ALWAYS AS (CASE                                  -- F5
                          WHEN reason_code IN ('auditGone','auditNeverSeen','auditCouldNotCheck',
                                               'noWholeFileDigest','removedNoDigest') THEN 'presence'
                          ELSE 'finding' END) VIRTUAL,
          words         TEXT    NOT NULL,            -- family-app words: what is wrong and what to do
          findings      TEXT    NOT NULL DEFAULT '[]'                                 -- integrity findings for the row
                                CHECK (json_valid(findings) AND json_type(findings) = 'array'),  -- F5 final: an object is not an empty array
          raw_row       TEXT    CHECK (raw_row IS NULL OR json_valid(raw_row)),      -- the full VideoRecordDTO JSON
          quarantined_at INTEGER NOT NULL,
          generation    INTEGER NOT NULL,
          resolved_file_id TEXT REFERENCES files(id) ON DELETE RESTRICT,
          resolved_at   INTEGER,
          resolution    TEXT    CHECK (resolution IN                                                -- F5r3
                          ('foundByDigest','resolvedAsCopy','personDecided','importedAfterHash','resolvedByRule')),
          resolution_note TEXT,                      -- resolvedByRule / personDecided: in words
          resolved_rule TEXT,                        -- F5r3: resolvedByRule — the CatalogConstraints rule name
          resolved_integrity_run TEXT,               -- F5r3: the integrity run id that no longer reports it
          CHECK ((resolved_at IS NULL) = (resolution IS NULL)),
          CHECK (resolution IS NULL OR resolution = 'resolvedByRule' OR resolved_file_id IS NOT NULL),
          CHECK (resolution IS NULL OR resolution NOT IN ('resolvedByRule','personDecided') OR resolution_note IS NOT NULL),
          CHECK ((resolution IS 'resolvedByRule') = (resolved_rule IS NOT NULL AND resolved_integrity_run IS NOT NULL)),  -- F5r3
          CHECK ((resolved_rule IS NULL) = (resolved_integrity_run IS NULL)),                                              -- F5r3
          -- F5 / F5r3: a rescan's byte match resolves a row ONLY when its reason is a presence reason
          -- AND it carries no integrity finding (the CHECK spans both columns). A row WITH findings is
          -- resolved only by resolvedByRule (its rule name + the integrity run that no longer reports it).
          CHECK (resolution IS NULL OR resolution NOT IN ('foundByDigest','resolvedAsCopy')
                 OR (reason_class = 'presence' AND json_array_length(findings) = 0)),
          CHECK (resolution IS NULL OR json_array_length(findings) = 0 OR resolution = 'resolvedByRule'),
          CHECK (origin <> 'import' OR (import_run IS NOT NULL AND source_ordinal IS NOT NULL
                                        AND json_row_id IS NOT NULL AND raw_row IS NOT NULL)),
          CHECK (origin <> 'rescan' OR (import_run IS NULL AND source_ordinal IS NULL)),
          CHECK (reason_code <> 'fixityDisagree' OR (digest IS NULL AND json_array_length(evidence_digests) >= 2))  -- F10
        ) STRICT
        """,
        """
        CREATE UNIQUE INDEX quarantine_by_source ON quarantine(import_run, source_ordinal) WHERE origin = 'import';  -- F4
        CREATE INDEX quarantine_by_json_row ON quarantine(json_row_id) WHERE json_row_id IS NOT NULL
        """,
        """
        CREATE INDEX quarantine_by_digest  ON quarantine(digest) WHERE digest IS NOT NULL
        """,
        """
        CREATE INDEX quarantine_open       ON quarantine(reason_code) WHERE resolved_at IS NULL
        """,
        """
        CREATE TRIGGER quarantine_never_deleted BEFORE DELETE ON quarantine
        BEGIN SELECT RAISE(ABORT, 'quarantine rows are history; resolve, never delete'); END
        """,
        """
        CREATE TRIGGER quarantine_no_replace BEFORE INSERT ON quarantine                            -- F4
        WHEN (NEW.qid IS NOT NULL AND EXISTS (SELECT 1 FROM quarantine WHERE qid = NEW.qid))
          OR (NEW.import_run IS NOT NULL AND EXISTS (SELECT 1 FROM quarantine
                WHERE import_run = NEW.import_run AND source_ordinal = NEW.source_ordinal))
        BEGIN SELECT RAISE(ABORT, 'quarantine rows are history (no replace)'); END
        """,
        """
        CREATE TRIGGER quarantine_resolve_once BEFORE UPDATE ON quarantine
        WHEN OLD.resolved_at IS NOT NULL
          OR NEW.raw_row IS NOT OLD.raw_row OR NEW.json_row_id IS NOT OLD.json_row_id
          OR NEW.digest IS NOT OLD.digest OR NEW.words IS NOT OLD.words
          OR NEW.reason_code IS NOT OLD.reason_code OR NEW.evidence_digests IS NOT OLD.evidence_digests
          OR NEW.import_run IS NOT OLD.import_run OR NEW.source_ordinal IS NOT OLD.source_ordinal
          OR NEW.findings IS NOT OLD.findings     -- F5r3: emptying findings cannot open the byte-match door
        BEGIN SELECT RAISE(ABORT, 'quarantine evidence is immutable; a row is resolved once'); END
        """,
    ]

    // MARK: - import_runs

    static let importRuns: [String] = [
        """
        CREATE TABLE import_runs (
          run_id          TEXT PRIMARY KEY NOT NULL,
          started_at      INTEGER NOT NULL,
          finished_at     INTEGER,
          source_sha256   TEXT NOT NULL CHECK (length(source_sha256) = 64 AND source_sha256 NOT GLOB '*[^0-9a-f]*'),
          source_generation INTEGER NOT NULL,
          integrity_run_id TEXT NOT NULL,           -- integrity-latest.json runID used as the gate
          audit_run_started_at INTEGER NOT NULL,    -- catalog-audit.json startedAt: the per-row results' run (F6)
          -- N1: the snapshot the audit evidence belongs to. The audit saves its auditSeenOn stamps and
          -- records the generation that save produced (`savedGeneration`, A′ adds it with the per-row
          -- results); the integrity report certifies `snapshotGeneration`; the frozen file carries
          -- `source_generation`. All three must be ONE generation, and the audit must have finished
          -- before the integrity run started. Any save in between bumps the generation: refused.
          audit_run_finished_at INTEGER NOT NULL,                                                    -- N1
          audit_generation      INTEGER NOT NULL,   -- catalog-audit.json savedGeneration          -- N1
          integrity_started_at  INTEGER NOT NULL,   -- integrity-latest.json run.startedAt         -- N1
          integrity_generation  INTEGER NOT NULL,   -- integrity-latest.json snapshotGeneration    -- N1
          rows_before     INTEGER NOT NULL DEFAULT 0,
          rows_main       INTEGER NOT NULL DEFAULT 0,
          rows_quarantine INTEGER NOT NULL DEFAULT 0,
          digests_seen    INTEGER NOT NULL DEFAULT 0,
          knowledge_rows  INTEGER NOT NULL DEFAULT 0,
          comparator_ok   INTEGER NOT NULL DEFAULT 0 CHECK (comparator_ok IN (0,1)),
          CHECK (rows_before = rows_main + rows_quarantine),            -- backstop only (F1)
          CHECK (finished_at IS NULL OR comparator_ok = 1),
          CHECK (audit_run_started_at <= audit_run_finished_at),                                     -- N1
          CHECK (audit_run_finished_at < integrity_started_at),                                      -- N1
          CHECK (audit_generation = source_generation AND integrity_generation = source_generation)  -- N1
        ) STRICT, WITHOUT ROWID
        """,
    ]

    // MARK: - import_items + 2 triggers

    static let importItems: [String] = [
        """
        CREATE TABLE import_items (                                                                  -- F1
          import_run     TEXT    NOT NULL REFERENCES import_runs(run_id) ON DELETE RESTRICT,
          source_file    TEXT    NOT NULL CHECK (source_file IN
                           ('catalog.json','events-decisions.json','ignored-content.json',
                            'media-ledger.jsonl','catalog-audit.json','fullhash-backfill.json',
                            'personfinder_cache.sqlite')),                                           -- F9r3
          source_ordinal INTEGER NOT NULL CHECK (source_ordinal >= 0),
          item_kind      TEXT    NOT NULL CHECK (item_kind IN
                           ('row','event','eventDecision','ignored','ledgerLine','marker','auditResult',
                            'personSearch')),                                                        -- F9r3
          source_key     TEXT,                    -- the id the occurrence carries, verbatim (non-unique)
          -- catalog rows: the §10b curated fields this occurrence carried (non-default), as the importer
          -- decoded them; the comparator re-derives this list from catalog.json independently.
          curated_fields TEXT    NOT NULL DEFAULT '[]' CHECK (json_valid(curated_fields)),
          landed_table   TEXT    NOT NULL CHECK (landed_table IN
                           ('files','quarantine','events','event_decisions','ignored_content','ledger',
                            'job_markers','audit_results','person_searches')),                       -- F9r3
          landed_ref     TEXT    NOT NULL,        -- files.id | quarantine.qid | events.event_id | '' (keyed by run+ordinal)
          PRIMARY KEY (import_run, source_file, source_ordinal),
          CHECK ((source_file = 'catalog.json') = (item_kind = 'row')),
          CHECK (item_kind <> 'row' OR landed_table IN ('files','quarantine')),
          CHECK (item_kind <> 'row' OR json_array_length(curated_fields) >= 0)
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE TRIGGER import_items_no_replace BEFORE INSERT ON import_items
        WHEN EXISTS (SELECT 1 FROM import_items WHERE import_run = NEW.import_run
                      AND source_file = NEW.source_file AND source_ordinal = NEW.source_ordinal)
        BEGIN SELECT RAISE(ABORT, 'import_items: one occurrence, one row'); END
        """,
        """
        CREATE TRIGGER import_items_no_delete BEFORE DELETE ON import_items                          -- fix 2026-10-17 (codex C′ #1)
        BEGIN SELECT RAISE(ABORT, 'import_items is the map of an import; never deleted'); END
        """,
    ]

    // MARK: - audit_results + 1 index, 7 triggers (incl. import_runs')

    static let auditResults: [String] = [
        """
        CREATE TABLE audit_results (                                                                 -- F6 N1
          import_run     TEXT    NOT NULL REFERENCES import_runs(run_id) ON DELETE RESTRICT,
          source_ordinal INTEGER NOT NULL CHECK (source_ordinal >= 0),   -- position in catalog-audit.json's rows
          json_row_id    TEXT    NOT NULL,
          result         TEXT    NOT NULL CHECK (result IN ('present','gone','neverSeen','couldNotCheck','changed','link')),
          detail         TEXT    NOT NULL DEFAULT '{}' CHECK (json_valid(detail)),  -- errno, link component, stamp seen
          judged_path    TEXT,                     -- N1: the path the audit judged (required unless present)
          row_full_path  TEXT    NOT NULL,         -- N1: the row's fullPath in the frozen catalog.json
          row_audit_seen_at INTEGER,               -- N1: the row's auditSeenOn.seenAt; NULL = no stamp
          accepted       INTEGER NOT NULL CHECK (accepted IN (0,1)),                                 -- N1
          CHECK (result = 'present' OR judged_path IS NOT NULL),                                     -- N1
          PRIMARY KEY (import_run, source_ordinal)
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE INDEX audit_results_by_row ON audit_results(import_run, json_row_id)
        """,
        """
        CREATE TRIGGER audit_results_bound_to_snapshot BEFORE INSERT ON audit_results               -- N1
        WHEN NEW.accepted IS NOT (
          SELECT CASE WHEN NEW.result = 'present'
                      THEN (NEW.row_audit_seen_at IS NOT NULL
                            AND NEW.row_audit_seen_at BETWEEN r.audit_run_started_at AND r.audit_run_finished_at)
                      ELSE (NEW.judged_path IS NEW.row_full_path) END
            FROM import_runs r WHERE r.run_id = NEW.import_run)
        BEGIN SELECT RAISE(ABORT, 'audit_results.accepted must follow the snapshot rule (N1)'); END
        """,
        """
        CREATE TRIGGER audit_results_no_update BEFORE UPDATE ON audit_results                       -- N1
        BEGIN SELECT RAISE(ABORT, 'audit results are evidence'); END
        """,
        """
        CREATE TRIGGER audit_results_no_delete BEFORE DELETE ON audit_results                       -- fix 2026-10-17 (codex C′ #1)
        BEGIN SELECT RAISE(ABORT, 'audit results are evidence'); END
        """,
        """
        CREATE TRIGGER import_runs_open_first BEFORE INSERT ON import_runs
        WHEN NEW.finished_at IS NOT NULL OR NEW.comparator_ok <> 0
        BEGIN SELECT RAISE(ABORT, 'an import run starts open; it is finished by the comparator'); END
        """,
        """
        CREATE TRIGGER import_runs_finish_checks_rows                                                -- F1
        BEFORE UPDATE OF finished_at ON import_runs
        WHEN NEW.finished_at IS NOT NULL AND OLD.finished_at IS NULL AND (
             -- counters equal the map (the counters cannot be supplied independently)
             NEW.rows_before     <> (SELECT count(*) FROM import_items WHERE import_run = NEW.run_id AND item_kind = 'row')
          OR NEW.rows_main       <> (SELECT count(*) FROM import_items WHERE import_run = NEW.run_id AND item_kind = 'row' AND landed_table = 'files')
          OR NEW.rows_quarantine <> (SELECT count(*) FROM import_items WHERE import_run = NEW.run_id AND item_kind = 'row' AND landed_table = 'quarantine')
          OR NEW.knowledge_rows  <> (SELECT count(*) FROM knowledge_sources WHERE import_run = NEW.run_id)
          -- every landing exists, and no two rows landed on one files row
          OR EXISTS (SELECT 1 FROM import_items i WHERE i.import_run = NEW.run_id AND i.landed_table = 'files'
                      AND NOT EXISTS (SELECT 1 FROM files f WHERE f.id = i.landed_ref))
          OR EXISTS (SELECT landed_ref FROM import_items WHERE import_run = NEW.run_id AND landed_table = 'files'
                      GROUP BY landed_ref HAVING count(*) > 1)
          OR EXISTS (SELECT 1 FROM import_items i WHERE i.import_run = NEW.run_id AND i.landed_table = 'quarantine'
                      AND NOT EXISTS (SELECT 1 FROM quarantine q WHERE q.import_run = i.import_run
                                       AND q.source_ordinal = i.source_ordinal AND q.qid = CAST(i.landed_ref AS INTEGER)))
          OR EXISTS (SELECT 1 FROM import_items i WHERE i.import_run = NEW.run_id AND i.landed_table = 'events'
                      AND NOT EXISTS (SELECT 1 FROM events e WHERE e.event_id = i.landed_ref
                                       AND e.import_run = i.import_run AND e.source_ordinal = i.source_ordinal))
          OR EXISTS (SELECT 1 FROM import_items i WHERE i.import_run = NEW.run_id AND i.landed_table = 'event_decisions'
                      AND NOT EXISTS (SELECT 1 FROM event_decisions d WHERE d.import_run = i.import_run AND d.source_ordinal = i.source_ordinal))
          OR EXISTS (SELECT 1 FROM import_items i WHERE i.import_run = NEW.run_id AND i.landed_table = 'ignored_content'
                      AND NOT EXISTS (SELECT 1 FROM ignored_content g WHERE g.import_run = i.import_run AND g.source_ordinal = i.source_ordinal))
          OR EXISTS (SELECT 1 FROM import_items i WHERE i.import_run = NEW.run_id AND i.landed_table = 'ledger'
                      AND NOT EXISTS (SELECT 1 FROM ledger l WHERE l.import_run = i.import_run AND l.source_ordinal = i.source_ordinal))
          OR EXISTS (SELECT 1 FROM import_items i WHERE i.import_run = NEW.run_id AND i.landed_table = 'job_markers'
                      AND NOT EXISTS (SELECT 1 FROM job_markers j WHERE j.import_run = i.import_run
                                       AND j.source_file = i.source_file AND j.source_ordinal = i.source_ordinal))
          OR EXISTS (SELECT 1 FROM import_items i WHERE i.import_run = NEW.run_id AND i.landed_table = 'audit_results'
                      AND NOT EXISTS (SELECT 1 FROM audit_results a WHERE a.import_run = i.import_run AND a.source_ordinal = i.source_ordinal))
          OR EXISTS (SELECT 1 FROM import_items i WHERE i.import_run = NEW.run_id AND i.landed_table = 'person_searches'  -- F9r3
                      AND NOT EXISTS (SELECT 1 FROM person_searches s WHERE s.import_run = i.import_run AND s.source_ordinal = i.source_ordinal))
          -- every curated field an occurrence carried has its verbatim knowledge_sources row
          OR EXISTS (SELECT 1 FROM import_items i, json_each(i.curated_fields) cf
                      WHERE i.import_run = NEW.run_id AND i.item_kind = 'row'
                        AND NOT EXISTS (SELECT 1 FROM knowledge_sources k WHERE k.import_run = i.import_run
                                         AND k.source_ordinal = i.source_ordinal AND k.field = cf.value))
          -- every lineage / supersession value is an edge or a pending edge (never dropped)
          OR EXISTS (SELECT 1 FROM knowledge_sources k WHERE k.import_run = NEW.run_id AND k.field = 'lineage'
                      AND NOT EXISTS (SELECT 1 FROM lineage_pending p WHERE p.import_run = k.import_run
                                       AND p.source_ordinal = k.source_ordinal AND p.relation = 'derivedFrom')
                      AND NOT (k.digest IS NOT NULL AND EXISTS (SELECT 1 FROM lineage l WHERE l.child_digest = k.digest))
                      AND NOT (k.digest IS NOT NULL AND EXISTS (SELECT 1 FROM archive_copies a JOIN files f ON f.id = a.file_id
                                                                 WHERE f.content_digest = k.digest)))
          OR EXISTS (SELECT 1 FROM knowledge_sources k WHERE k.import_run = NEW.run_id AND k.field = 'supersededByID'
                      AND NOT EXISTS (SELECT 1 FROM lineage_pending p WHERE p.import_run = k.import_run
                                       AND p.source_ordinal = k.source_ordinal AND p.relation = 'supersededBy')
                      AND NOT (k.digest IS NOT NULL AND EXISTS (SELECT 1 FROM supersessions s WHERE s.retired_digest = k.digest)))
          -- every footage decision of an occurrence is a footage_decisions row
          OR EXISTS (SELECT 1 FROM knowledge_sources k, json_each(k.value_json) d
                      WHERE k.import_run = NEW.run_id AND k.field = 'footageDecisions'
                        AND NOT EXISTS (SELECT 1 FROM footage_decisions fd WHERE fd.import_run = k.import_run
                                         AND fd.source_ordinal = k.source_ordinal
                                         AND fd.other_row_id = json_extract(d.value, '$.otherID'))))
        BEGIN SELECT RAISE(ABORT, 'import run cannot finish: an occurrence, a landing or a curated value is unaccounted for'); END
        """,
        """
        CREATE TRIGGER import_runs_finished_is_final BEFORE UPDATE ON import_runs
        WHEN OLD.finished_at IS NOT NULL
        BEGIN SELECT RAISE(ABORT, 'a finished import run is history'); END
        """,
        """
        CREATE TRIGGER import_runs_no_delete BEFORE DELETE ON import_runs                            -- fix 2026-10-17 (codex C′ #1)
        BEGIN SELECT RAISE(ABORT, 'an import run is history; never deleted'); END
        """,
    ]

    // MARK: - integrity_runs

    static let integrityRuns: [String] = [
        """
        CREATE TABLE integrity_runs (              -- integrity-*.json per tier (IntegrityReport.swift)
          run_id        TEXT    NOT NULL,
          tier          INTEGER NOT NULL CHECK (tier BETWEEN 0 AND 6),
          verified_at   INTEGER,
          generation    INTEGER,
          result        TEXT    NOT NULL,
          checked       INTEGER NOT NULL DEFAULT 0,
          passed        INTEGER NOT NULL DEFAULT 0,
          needs_decision INTEGER NOT NULL DEFAULT 0,
          could_not_check INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (run_id, tier)
        ) STRICT, WITHOUT ROWID
        """,
    ]

    // MARK: - job_markers + 1 trigger

    static let jobMarkers: [String] = [
        """
        CREATE TABLE job_markers (                 -- catalog-audit.json, fullhash-backfill.json (F1), sound-print backfill, freshness
          job           TEXT    NOT NULL CHECK (job IN ('audit','fullHash','soundPrint','freshness','verifyCatalog')),
          scope         TEXT    NOT NULL,          -- '*', a volume UUID, a path prefix
          started_at    INTEGER NOT NULL,
          finished_at   INTEGER,
          outcome       TEXT    CHECK (outcome IN ('completed','stopped','failed')),
          generation    INTEGER NOT NULL,          -- the generation the stamp certifies
          detail        TEXT    NOT NULL DEFAULT '{}' CHECK (json_valid(detail)),  -- verbatim file body (hashedSoFar, counts, marked …)
          import_run    TEXT    REFERENCES import_runs(run_id) ON DELETE RESTRICT,   -- F1
          source_file   TEXT,
          source_ordinal INTEGER,
          CHECK ((import_run IS NULL) = (source_file IS NULL) AND (import_run IS NULL) = (source_ordinal IS NULL)),
          PRIMARY KEY (job, scope, started_at)
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE TRIGGER job_markers_no_delete BEFORE DELETE ON job_markers                            -- fix 2026-10-17 (codex C′ #1)
        BEGIN SELECT RAISE(ABORT, 'job markers are history; never deleted'); END
        """,
    ]

    // MARK: - ledger + 3 indexes, 3 triggers

    static let ledger: [String] = [
        """
        CREATE TABLE ledger (
          seq          INTEGER PRIMARY KEY,         -- rowid; never reused (no DELETE)
          at           INTEGER NOT NULL,
          generation   INTEGER NOT NULL,
          kind         TEXT    NOT NULL,            -- MediaLedgerEvent.event, verbatim (MediaLedgerEvent.swift:35)
          actor        TEXT    NOT NULL,            -- rick | tidy | promote | angel | app
          record_id    TEXT    NOT NULL,            -- the line's recordID — NOT an FK: an old line may name a quarantined row
          content_key  TEXT    NOT NULL,            -- verbatim 'h:<v1…>' | 'p:<md5>:<size>' | '' — sampled, never identity
          digest       TEXT    REFERENCES content(digest) ON DELETE RESTRICT,  -- via record_id's JSON whole-file digest only (F7)
          path         TEXT    NOT NULL,
          payload      TEXT    NOT NULL CHECK (json_valid(payload)),   -- the JSONL line, verbatim
          imported     INTEGER NOT NULL DEFAULT 0 CHECK (imported IN (0,1)),
          import_run   TEXT    REFERENCES import_runs(run_id) ON DELETE RESTRICT,   -- F4
          source_ordinal INTEGER,                   -- the line number (0-based) in the JSONL
          CHECK ((import_run IS NULL) = (source_ordinal IS NULL)),
          CHECK (imported = (import_run IS NOT NULL))
        ) STRICT
        """,
        """
        CREATE INDEX ledger_by_record ON ledger(record_id)
        """,
        """
        CREATE INDEX ledger_by_digest ON ledger(digest)
        """,
        """
        CREATE UNIQUE INDEX ledger_by_source ON ledger(import_run, source_ordinal) WHERE import_run IS NOT NULL
        """,
        """
        CREATE TRIGGER ledger_no_update BEFORE UPDATE ON ledger
        BEGIN SELECT RAISE(ABORT, 'the ledger is append-only'); END
        """,
        """
        CREATE TRIGGER ledger_no_delete BEFORE DELETE ON ledger
        BEGIN SELECT RAISE(ABORT, 'the ledger is append-only'); END
        """,
        """
        CREATE TRIGGER ledger_no_replace BEFORE INSERT ON ledger
        WHEN (NEW.seq IS NOT NULL AND EXISTS (SELECT 1 FROM ledger WHERE seq = NEW.seq))
          OR (NEW.import_run IS NOT NULL AND EXISTS (SELECT 1 FROM ledger
                WHERE import_run = NEW.import_run AND source_ordinal = NEW.source_ordinal))
        BEGIN SELECT RAISE(ABORT, 'the ledger is append-only (no replace)'); END
        """,
    ]
}
