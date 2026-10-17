// SchemaDocument.swift — test support for the Store suites: the two design
// documents as DATA. docs/design/catalog_sqlite_schema_v1.sql is the
// source of truth for the schema and catalog_sqlite_schema_v1_checks.sql
// is its reproduction script; both are read from disk at test time, so the
// Swift copy of the DDL (CatalogDataSchema) cannot drift from the document
// without a test saying so.
//
// SQLScript splits a sqlite3-shell script the way the shell does: SQLite's
// own sqlite3_complete() decides where a statement ends (a trigger body's
// inner `;` never splits it), dot-commands (`.print`, `.bail` …) are kept
// as items, and the checks file's `-- F<N> —` block headers are items too.
// ChecksRun then plays such a script against a database, statement by
// statement, with the file's own convention: a `.print '(expected refusal:
// …)'` line means the NEXT statement must be refused; anything else must
// succeed; a `SELECT '<block> ok' WHERE …` row is the block's verdict.
//
// For Rick: sqlite3_complete is the C function the sqlite3 shell calls;
// SQLite3 is imported here only to reach it and the library version. No
// store code imports it — the sensor keeps GRDB and SQLite behind Store/.

import Foundation
import GRDB
import SQLite3
@testable import VideoScanCore

// MARK: - The documents

enum SchemaDocument {

    /// …/VideoScan/VideoScanCore/Tests/VideoScanCoreTests/Store/<this file>
    /// → six levels up is the repository root.
    static var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }

    static var ddlURL: URL { repositoryRoot.appendingPathComponent("docs/design/catalog_sqlite_schema_v1.sql") }
    static var checksURL: URL { repositoryRoot.appendingPathComponent("docs/design/catalog_sqlite_schema_v1_checks.sql") }

    static func ddl() throws -> SQLScript {
        SQLScript(text: try String(contentsOf: ddlURL, encoding: .utf8))
    }

    static func checks() throws -> SQLScript {
        SQLScript(text: try String(contentsOf: checksURL, encoding: .utf8))
    }

    /// What the engine GRDB linked reports (macOS: the system libsqlite3).
    static var engineVersion: String { String(cString: sqlite3_libversion()) }
    static var engineVersionNumber: Int { Int(sqlite3_libversion_number()) }
    /// STRICT tables need 3.37.0 (DDL "Conventions").
    static let strictTablesSince = 3_037_000
}

// MARK: - A sqlite3-shell script as items

enum ScriptItem: Equatable {
    /// `-- F1 — …`, `-- D:530 — …`, `-- N2 — …`, `-- F5 final (…`: the label with its
    /// punctuation removed ("F1", "D530", "F5final"), as the ok rows spell it.
    case blockHeader(String)
    /// A shell dot-command line, verbatim (`.print '…'`, `.bail off`, `.read …`).
    case dotCommand(String)
    /// One complete SQL statement, comments stripped, without its trailing `;`.
    case statement(String)
}

struct SQLScript {
    let items: [ScriptItem]

    init(text: String) {
        var items: [ScriptItem] = []
        var pending = ""
        for rawLine in text.components(separatedBy: "\n") {
            if pending.isEmpty, let header = Self.blockHeader(of: rawLine) {
                items.append(.blockHeader(header))
                continue
            }
            if pending.isEmpty, rawLine.hasPrefix(".") {
                items.append(.dotCommand(rawLine))
                continue
            }
            let line = Self.strippingComment(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            pending += line + "\n"
            if Self.isComplete(pending) {
                items.append(.statement(Self.trimmed(pending)))
                pending = ""
            }
        }
        self.items = items
    }

    var statements: [String] {
        items.compactMap { item in
            if case .statement(let sql) = item { return sql }
            return nil
        }
    }

    /// The names the script's `CREATE TABLE` / `CREATE VIRTUAL TABLE` statements make.
    var tableNames: [String] { createdNames(matching: #/^CREATE (?:VIRTUAL )?TABLE (\w+)/#) }
    var triggerNames: [String] { createdNames(matching: #/^CREATE TRIGGER (\w+)/#) }

    private func createdNames(matching pattern: Regex<(Substring, Substring)>) -> [String] {
        statements.compactMap { sql in sql.firstMatch(of: pattern).map { String($0.1) } }
    }

    // MARK: Normalisation (both sides of a diff go through this)

    /// Comments out, every run of whitespace OUTSIDE a string literal one
    /// space, no trailing `;`. Inside `'…'` nothing is touched (codex C′
    /// #8: `'Backed Up'` and `'Backed  Up'` are two different constants).
    static func normalized(_ sql: String) -> String {
        let stripped = sql.components(separatedBy: "\n").map(strippingComment).joined(separator: "\n")
        var text = ""
        var inQuote = false
        var pendingSpace = false
        for character in stripped {
            if character == "'" { inQuote.toggle() }
            if !inQuote && character.isWhitespace {
                pendingSpace = true
                continue
            }
            if pendingSpace {
                text.append(" ")
                pendingSpace = false
            }
            text.append(character)
        }
        if text.hasSuffix(";") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Cuts a `--` comment off a line, leaving one inside a quoted string alone.
    static func strippingComment(_ line: String) -> String {
        var inQuote = false
        var previous: Character = " "
        for (offset, character) in line.enumerated() {
            if character == "'" { inQuote.toggle() }
            if !inQuote && character == "-" && previous == "-" {
                return String(line.prefix(offset - 1))
            }
            previous = character
        }
        return line
    }

    private static func isComplete(_ text: String) -> Bool {
        sqlite3_complete(text) == 1
    }

    private static func trimmed(_ statement: String) -> String {
        var text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(";") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func blockHeader(of line: String) -> String? {
        guard let match = line.firstMatch(of: #/^-- (F\d+(?:r\d)?|N\d+|C\d+|D:530|F5 final)(?: — | \()/#) else { return nil }
        return String(match.1).replacingOccurrences(of: ":", with: "").replacingOccurrences(of: " ", with: "")
    }
}

// MARK: - Playing the checks file

/// The outcome of one run of the checks script. Every field is what the
/// sqlite3 shell would have printed, captured instead of scrolled past.
struct ChecksRun {

    struct Refusal: Equatable {
        let block: String
        let announcement: String
        let words: String
    }

    struct Problem: CustomStringConvertible {
        let block: String
        let words: String
        var description: String { "[\(block)] \(words)" }
    }

    /// `<label> ok` for every block header seen, in order.
    private(set) var expectedOk: [String] = []
    /// The `… ok` rows the SELECTs returned.
    private(set) var okRows: [String] = []
    /// Every announced refusal, with the engine's words.
    private(set) var refusals: [Refusal] = []
    /// Unannounced errors, statements that were NOT refused, and FAILED rows.
    private(set) var problems: [Problem] = []
    /// The fixture statements the migration had already made (see `seedingReplacedByTheMigration`).
    private(set) var skippedSeeding: [String] = []
    /// EXPLAIN QUERY PLAN outputs, in order.
    private(set) var queryPlans: [String] = []
    /// `integrity_check: …` and `all checks ok (…)`.
    private(set) var summary: [String] = []

    private var block = "fixture"
    private var pendingRefusal: String?

    /// The checks fixture seeds catalog_state (1, 7) and generations (1, 5, …)
    /// by hand. Part 1's migration already wrote both rows (generation 0,
    /// with its `create` history row), so the harness skips these two and
    /// the test brings the generation to 5 through the store's own writes.
    static let seedingReplacedByTheMigration = ["INSERT INTO catalog_state", "INSERT INTO generations "]

    /// Plays every item on ONE connection (the checks file keeps a TEMP table
    /// and reads `changes()`, both connection-local), in order, and returns
    /// what happened. Nothing throws out of here: every refusal is data.
    static func play(_ script: SQLScript, on db: Database) -> ChecksRun {
        var run = ChecksRun()
        for item in script.items { run.handle(item, db) }
        return run
    }

    private mutating func handle(_ item: ScriptItem, _ db: Database) {
        switch item {
        case .blockHeader(let label):
            block = label
            expectedOk.append("\(label) ok")
        case .dotCommand(let text):
            noteAnnouncement(text)
        case .statement(let sql):
            runStatement(sql, db)
        }
    }

    private mutating func noteAnnouncement(_ text: String) {
        guard text.hasPrefix(".print"), let open = text.range(of: "(expected refusal: ") else { return }
        var words = String(text[open.upperBound...])
        if words.hasSuffix(")'") { words.removeLast(2) }
        pendingRefusal = words
    }

    private mutating func runStatement(_ sql: String, _ db: Database) {
        if Self.seedingReplacedByTheMigration.contains(where: { sql.hasPrefix($0) }) {
            skippedSeeding.append(sql)
            return
        }
        if let announcement = pendingRefusal {
            pendingRefusal = nil
            expectRefusal(sql, announcement, db)
            return
        }
        if sql.hasPrefix("SELECT") || sql.hasPrefix("EXPLAIN") {
            query(sql, db)
            return
        }
        do {
            try db.execute(sql: sql)
        } catch {
            problems.append(Problem(block: block, words: "unannounced error: \(Self.words(error)) — \(sql.prefix(90))"))
        }
    }

    private mutating func expectRefusal(_ sql: String, _ announcement: String, _ db: Database) {
        do {
            try db.execute(sql: sql)
            problems.append(Problem(block: block, words: "NOT refused: \(announcement)"))
        } catch {
            refusals.append(Refusal(block: block, announcement: announcement, words: Self.words(error)))
        }
    }

    private mutating func query(_ sql: String, _ db: Database) {
        do {
            let rows = try Row.fetchAll(db, sql: sql)
            if sql.hasPrefix("EXPLAIN") {
                queryPlans.append(rows.map { Self.text($0[3]) }.joined(separator: " | "))
                return
            }
            for row in rows { classify(Self.text(row[0])) }
        } catch {
            problems.append(Problem(block: block, words: "query failed: \(Self.words(error)) — \(sql.prefix(90))"))
        }
    }

    private mutating func classify(_ text: String) {
        if text.hasPrefix("integrity_check: ") || text.hasPrefix("all checks ok") {
            summary.append(text)
        } else if text.hasSuffix(" ok") {
            okRows.append(text)
        } else if text.contains("FAILED") {
            problems.append(Problem(block: block, words: text))
        }
    }

    static func words(_ error: Error) -> String {
        if let engine = error as? DatabaseError { return engine.message ?? engine.description }
        return String(describing: error)
    }

    private static func text(_ value: DatabaseValue) -> String {
        if case .string(let text) = value.storage { return text }
        return ""
    }
}

// MARK: - What the migration made, read back from sqlite_master

struct SchemaInventory {
    private(set) var tables: [String] = []
    private(set) var virtualTables: [String] = []
    /// FTS5's engine-managed shadow tables (`content_text_fts_data` …).
    private(set) var shadowTables: [String] = []
    private(set) var triggers: [String] = []
    /// Named indexes (the UNIQUE/PRIMARY KEY autoindexes carry no sql and are not listed).
    private(set) var indexes: [String] = []
    private(set) var views: [String] = []
    /// name → sql for everything with sql, normalised.
    private(set) var normalizedSQL: [String: String] = [:]

    /// Tables the engine or GRDB own; never in the DDL.
    static let engineOwned: Set<String> = ["grdb_migrations"]
    static let shadowPrefix = "content_text_fts_"

    init(_ db: Database) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT type, name, sql FROM sqlite_master ORDER BY type, name")
        for row in rows {
            let type: String = row[0]
            let name: String = row[1]
            let sql: String? = row[2]
            if let sql { normalizedSQL[name] = SQLScript.normalized(sql) }
            place(type: type, name: name, sql: sql)
        }
    }

    private mutating func place(type: String, name: String, sql: String?) {
        switch type {
        case "table": placeTable(name, sql: sql ?? "")
        case "trigger": triggers.append(name)
        case "view": views.append(name)
        case "index" where sql != nil: indexes.append(name)
        default: break
        }
    }

    private mutating func placeTable(_ name: String, sql: String) {
        if name.hasPrefix("sqlite_") || Self.engineOwned.contains(name) { return }
        if name.hasPrefix(Self.shadowPrefix) {
            shadowTables.append(name)
        } else if sql.hasPrefix("CREATE VIRTUAL TABLE") {
            virtualTables.append(name)
        } else {
            tables.append(name)
        }
    }
}

// MARK: - A small world for the isolation tests

enum SchemaSeed {
    static let volume = "11111111-1111-1111-1111-111111111111"
    static let digestA = String(repeating: "a", count: 64)
    static let digestB = String(repeating: "b", count: 64)
    static let fileOne = "00000000-0000-0000-0000-000000000001"
    static let fileTwo = "00000000-0000-0000-0000-000000000002"

    static let volumeInsert = "INSERT INTO volumes (volume_uuid, case_sensitive) VALUES ('\(volume)', 0)"
    static let contentAInsert = "INSERT INTO content (digest, byte_count, first_seen_at, first_seen_how) VALUES ('\(digestA)', 100, 1700000000, 'rescan')"

    /// A live, hashed, case-insensitive-volume row; `fold` is the app's fold of `path`.
    static func fileInsert(id: String, digest: String, path: String, fold: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? ""
        let directory = String(path.dropLast(name.count + 1))
        return """
        INSERT INTO files (id, content_digest, volume_uuid, volume_case_sensitive, full_path, path_fold, filename, ext, directory,
                           size_bytes, digest_computed_at, digest_source, stream_type, lifecycle, archive_stage)
        VALUES ('\(id)', '\(digest)', '\(volume)', 0, '\(path)', '\(fold)', '\(name)', 'mov', '\(directory)',
                100, 1700000000, 'rescan', 'Video+Audio', 'Cataloged', 'None')
        """
    }

    /// Volume, content a…, and file one at /Volumes/A/Movie.mov.
    static func plant(_ db: Database) throws {
        try db.execute(sql: volumeInsert)
        try db.execute(sql: contentAInsert)
        try db.execute(sql: fileInsert(id: fileOne, digest: digestA, path: "/Volumes/A/Movie.mov", fold: "/volumes/a/movie.mov"))
    }
}
