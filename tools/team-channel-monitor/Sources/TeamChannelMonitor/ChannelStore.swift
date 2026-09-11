import Foundation
import SQLite3

/// One row per (message, recipient). The monitor is deliberately read-mostly:
/// the only writes go through tools/team-channel.py so validation stays in one place.
struct ChannelRow: Identifiable, Hashable {
    enum Status: Hashable {
        case answered(Date)          // green
        case waiting(TimeInterval)   // yellow — not yet delivered to the agent
        case inProgress(TimeInterval)// yellow — delivered, not yet acknowledged
        case stuck(TimeInterval)     // red — unanswered past the threshold

        var isGreen: Bool { if case .answered = self { return true } else { return false } }
        var isRed: Bool { if case .stuck = self { return true } else { return false } }
    }

    let messageID: Int
    let author: String
    let recipient: String
    let subject: String
    let body: String
    let replyTo: Int?
    let createdAt: Date
    let deliveredAt: Date?
    let acknowledgedAt: Date?
    let repliedAt: Date?
    let nudgedAt: Date?
    let status: Status

    var id: String { "\(messageID):\(recipient)" }
}

struct ChannelSnapshot {
    var rows: [ChannelRow] = []
    var error: String?
    var fetchedAt = Date()

    var red: Int { rows.filter { $0.status.isRed }.count }
    var green: Int { rows.filter { $0.status.isGreen }.count }
    var yellow: Int { rows.count - red - green }
}

enum ChannelDB {
    /// Same default and override as tools/team-channel.py.
    static var path: String {
        if let override = ProcessInfo.processInfo.environment["VIDEOSCAN_TEAM_CHANNEL_DB"], !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        return NSHomeDirectory() + "/Library/Application Support/VideoScan/team-channel/team-channel.sqlite3"
    }

    static let stuckAfter: TimeInterval = 15 * 60
    static let nudgeSubjectPrefix = "Please respond to #"

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return iso.date(from: s)
    }

    /// Today's (local calendar day) message/recipient pairs, newest first.
    static func loadToday(now: Date = Date()) -> ChannelSnapshot {
        var snap = ChannelSnapshot(fetchedAt: now)
        var db: OpaquePointer?
        // A WAL database needs its -shm file even for reads, so a strictly
        // read-only open fails (SQLITE_CANTOPEN) when the process may not
        // create it. Open like the CLI does; nothing here ever writes.
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil)
        guard rc == SQLITE_OK, let db else {
            let why = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite rc \(rc)"
            if let db { sqlite3_close(db) }
            snap.error = "Cannot open team-channel.sqlite3 (\(why)) at \(path)"
            return snap
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)

        let dayStart = Calendar.current.startOfDay(for: now)
        let dayKey: String = {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: dayStart)
        }()

        // Replies and nudges to today's messages, keyed by (message, author).
        var replies: [String: Date] = [:]
        var nudges: [Int: Date] = [:]
        let replySQL = """
            SELECT reply_to, author, subject, created_at FROM messages
             WHERE reply_to IS NOT NULL AND created_at >= ?
            """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, replySQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, dayKey, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let target = Int(sqlite3_column_int64(stmt, 0))
                let author = text(stmt, 1)
                let subject = text(stmt, 2)
                guard let when = parse(text(stmt, 3)) else { continue }
                if author == "rick" && subject.hasPrefix(nudgeSubjectPrefix) {
                    nudges[target] = max(nudges[target] ?? .distantPast, when)
                } else {
                    let key = "\(target):\(author)"
                    replies[key] = max(replies[key] ?? .distantPast, when)
                }
            }
        }
        sqlite3_finalize(stmt)

        let sql = """
            SELECT m.id, m.author, r.recipient, m.subject, m.body, m.reply_to, m.created_at,
                   r.delivered_at, r.acknowledged_at
              FROM messages m JOIN recipients r ON r.message_id = m.id
             WHERE m.created_at >= ?
             ORDER BY m.id DESC, r.recipient
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            snap.error = String(cString: sqlite3_errmsg(db))
            return snap
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, dayKey, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int64(stmt, 0))
            let author = text(stmt, 1)
            let recipient = text(stmt, 2)
            let subject = text(stmt, 3)
            let body = text(stmt, 4)
            let replyTo = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 5))
            guard let created = parse(text(stmt, 6)) else { continue }
            let delivered = parse(text(stmt, 7))
            let acked = parse(text(stmt, 8))
            let replied = replies["\(id):\(recipient)"]

            let status: ChannelRow.Status
            if let done = [acked, replied].compactMap({ $0 }).min() {
                status = .answered(done)
            } else {
                let age = now.timeIntervalSince(created)
                if age >= stuckAfter {
                    status = .stuck(age)
                } else if delivered != nil {
                    status = .inProgress(age)
                } else {
                    status = .waiting(age)
                }
            }
            snap.rows.append(ChannelRow(
                messageID: id, author: author, recipient: recipient, subject: subject, body: body,
                replyTo: replyTo, createdAt: created, deliveredAt: delivered, acknowledgedAt: acked,
                repliedAt: replied, nudgedAt: nudges[id], status: status))
        }
        return snap
    }

    private static func text(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }
}

/// Writes go through the canonical CLI so subject/body/recipient validation lives in one place.
enum ChannelCLI {
    static var script: String {
        if let repo = ProcessInfo.processInfo.environment["VIDEOSCAN_REPO"], !repo.isEmpty {
            return (repo as NSString).expandingTildeInPath + "/tools/team-channel.py"
        }
        return NSHomeDirectory() + "/dev/VideoScan/tools/team-channel.py"
    }

    @discardableResult
    static func run(_ args: [String]) -> (ok: Bool, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", script] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (false, "\(error)") }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus == 0, out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Rick pokes an agent about a message it has not answered.
    static func nudge(_ row: ChannelRow) -> (ok: Bool, output: String) {
        let subject = "\(ChannelDB.nudgeSubjectPrefix)\(row.messageID)"
        let body = "Rick is waiting on #\(row.messageID) from \(row.author): \"\(row.subject)\". Please answer it, or say when you can."
        return run(["post", "--from", "rick", "--to", row.recipient, "--reply-to", "\(row.messageID)",
                    "--subject", subject, "--body", body])
    }

    /// Rick has read a message addressed to him.
    static func ackAsRick(_ row: ChannelRow) -> (ok: Bool, output: String) {
        run(["ack", "--agent", "rick", "\(row.messageID)"])
    }
}
