// ObservationsScope.swift (VideoScanCore/Observations) — WHICH files the
// Observations window reads (docs/design/file_dossier_view.md Part II, §II.2).
//
// Four scopes, each one SQL predicate over `files` with ONE bound argument
// (`argument`): everything (every live file), a selection (files.id values
// passed as one JSON array to json_each — a 20k selection is one parameter,
// never 20k), a folder (a directory and everything under it), and a finished
// pass (every content with an observation stamped at or after the pass
// started — exact, no list of files to keep).
//
// (For Rick: a tagged union with a `words` accessor; the store turns it
// into a WHERE clause once per query.)

import Foundation

public enum ObservationsScope: Sendable, Equatable, Hashable {
    /// Every live file in the catalog (a removed file is not the collection).
    case everything
    /// A selection: `files.id` values (as the catalog's records carry them). Removed rows named here still count (greyed).
    case files([String])
    /// A directory and everything under it (`files.directory`), live files only.
    case folder(String)
    /// Every live content with an observation stamped at or after this Unix time (a finished pass).
    case since(Int64)

    /// The header's words.
    public var words: String {
        switch self {
        case .everything: return "everything in the catalog"
        case .files(let ids): return "\(ids.count.formatted()) selected file\(ids.count == 1 ? "" : "s")"
        case .folder(let path): return "the folder \(path)"
        case .since(let at):
            return "this pass (observations since \(TechnicalReading.dayAndTime(Date(timeIntervalSince1970: TimeInterval(at)))))"
        }
    }

    /// The one bound argument of the predicate (`?1`): the ids as JSON, the folder, the time; nil for everything.
    public var argument: String? {
        switch self {
        case .everything: return nil
        case .files(let ids):
            // Memory: 38 B per id; 100k ids ≈ 3.8 MB, once per query.
            let data = (try? JSONSerialization.data(withJSONObject: ids)) ?? Data("[]".utf8)
            return String(bytes: data, encoding: .utf8) ?? "[]"
        case .folder(let path): return path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        case .since(let at): return String(at)
        }
    }

    /// The predicate over a `files` row aliased `f`, with the argument as `?1`.
    public var predicateSQL: String {
        switch self {
        case .everything:
            // `?1` is always bound (NULL here), so every query has the same first argument.
            return "f.removal_state IS NULL AND ?1 IS NULL"
        case .files:
            return "f.id IN (SELECT value FROM json_each(?1))"
        case .folder:
            return "f.removal_state IS NULL AND (f.directory = ?1 OR substr(f.directory, 1, length(?1) + 1) = ?1 || '/')"
        case .since:
            return """
                f.removal_state IS NULL AND (
                    EXISTS (SELECT 1 FROM caption_runs c WHERE c.digest = f.content_digest AND c.made_at >= CAST(?1 AS INTEGER))
                 OR EXISTS (SELECT 1 FROM transcripts t WHERE t.digest = f.content_digest AND t.made_at >= CAST(?1 AS INTEGER))
                 OR EXISTS (SELECT 1 FROM dossiers d WHERE d.digest = f.content_digest AND d.processed_at >= CAST(?1 AS INTEGER))
                 OR EXISTS (SELECT 1 FROM provenance_assertions a WHERE a.subject_kind = 'content' AND a.subject_id = f.content_digest
                              AND a.at >= CAST(?1 AS INTEGER)))
                """
        }
    }
}
