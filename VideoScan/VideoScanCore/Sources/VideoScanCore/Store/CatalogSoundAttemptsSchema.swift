// CatalogSoundAttemptsSchema.swift (VideoScanCore/Store)
// Schema v1.14, migration `v10_sound_attempts` — GH #416 part 2 (Rick
// approved option B, 2026-11-03: "I'll take your recommendation B").
// ADDITIVE ONLY — one new table and the schema version raised to 15 so a
// build that does not know the table refuses the file instead of writing
// around it. Verbatim in docs/design/catalog_sqlite_schema_v1.sql §19
// (CatalogDataSchemaTests diffs the two).
//
// `sound_attempts` — one row per content digest: Fingerprint Sound tried
// this content's sound `attempts` times at `engine_version` and got no
// print (`outcome` of the last try: heard sound but too little to make a
// landmark, or ffmpeg could not decode it). The plan skips a content after
// AudioFingerprintAttempt.cap (3) tries at the CURRENT engine version; a row
// from an older engine counts as 0. Keyed like `sound_prints` (the content's
// 64-hex digest, no "sha256:" prefix; a sampled v1: key never gets a row).
// Written only by the commit door (CatalogCommitBody → upsertSoundAttempt,
// which never lowers a count), deleted when the content's sound print is
// written (`replaceSoundPrint`). Not append-only: it is a counter, not
// evidence; the evidence is the job's FAILED / HEARD TOO LITTLE log lines.
//
// Worst-case size: one row per content with sound that would not print —
// ~1,100 on Rick's catalog today, ≤ 1 row per content ever (PRIMARY KEY).
//
// (For Rick: a per-key retry counter table, PRIMARY KEY = the content.)

enum CatalogSoundAttemptsSchema {

    /// Names are permanent: renaming one re-runs it.
    static let migrationID = "v10_sound_attempts"

    /// `catalog_state.schema_version` once this migration has run.
    static let schemaVersion = 15

    static let statements: [String] = [
        """
        CREATE TABLE sound_attempts (              -- v1.14: tries that gave no sound print, per content (AudioFingerprintAttempt)
          digest          TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          engine_version  INTEGER NOT NULL CHECK (engine_version >= 1),
          outcome         TEXT    NOT NULL CHECK (outcome IN ('heardTooLittle','failed')),
          attempts        INTEGER NOT NULL CHECK (attempts >= 1),
          last_at         INTEGER NOT NULL,
          detail          TEXT
        ) STRICT
        """,
    ]

    /// Run after `statements`, inside the same migration.
    static let versionBump: [String] = [
        "UPDATE catalog_state SET schema_version = \(schemaVersion) WHERE singleton = 1",
        "PRAGMA user_version = \(schemaVersion)",
    ]
}
