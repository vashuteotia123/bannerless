import Darwin
import Foundation

/// Reads notifications shown on this Mac from Notification Center's own
/// database (read-only) and picks out one-time codes. This covers Mail, other
/// mail apps, browsers, and iPhone app notifications that macOS shows here.
///
/// macOS offers no public API for other apps' notifications. The database is
/// protected by Full Disk Access, the same permission Messages needs. Its
/// layout isn't documented, so this reads it defensively: tables and columns
/// are discovered at runtime, and each notification's payload is decoded as a
/// plain property list (no object unarchiving).
public final class NotificationCodeReader: CodeSource, @unchecked Sendable {
    /// Known locations, newest macOS first.
    public static var candidatePaths: [String] {
        var paths = [FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db").path]
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_DIR, &buf, buf.count) > 0 {
            paths.append(String(cString: buf) + "com.apple.notificationcenter/db2/db")
        }
        return paths
    }

    let paths: [String]
    /// Notifications from these apps are skipped (e.g. Messages, which is read directly).
    public var ignoredApps: Set<String>
    private var db: SQLiteDB?
    private var recordColumns: Set<String> = []
    private var hasAppTable = false

    public init(paths: [String] = NotificationCodeReader.candidatePaths, ignoredApps: Set<String> = []) {
        self.paths = paths
        self.ignoredApps = ignoredApps
    }

    private var existingPath: String? { paths.first { FileManager.default.fileExists(atPath: $0) } }

    public func checkAccess() -> MessagesAccess {
        guard existingPath != nil else {
            // The protected folder can't even be looked into without access.
            for p in paths {
                let dir = ((p as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
                if FileManager.default.fileExists(atPath: dir),
                   (try? FileManager.default.contentsOfDirectory(atPath: dir)) == nil {
                    return .needsFullDiskAccess
                }
            }
            return .noMessagesDatabase
        }
        do {
            _ = try latestRowID()
            return .granted
        } catch {
            db = nil
            return .needsFullDiskAccess
        }
    }

    private func open() throws -> SQLiteDB {
        if let db { return db }
        guard let path = existingPath else { throw SQLiteError(message: "no notification database") }
        let d = try SQLiteDB(path: path, readOnly: true)
        recordColumns = Set(try d.query("PRAGMA table_info(record)").compactMap { $0.string("name") })
        guard recordColumns.contains("data") else { throw SQLiteError(message: "unexpected notification schema") }
        let appColumns = Set(try d.query("PRAGMA table_info(app)").compactMap { $0.string("name") })
        hasAppTable = appColumns.contains("identifier") && appColumns.contains("app_id") && recordColumns.contains("app_id")
        db = d
        return d
    }

    private var idColumn: String { recordColumns.contains("rec_id") ? "rec_id" : "ROWID" }

    public func latestRowID() throws -> Int64 {
        try open().query("SELECT MAX(\(idColumn)) AS n FROM record").first?.int("n") ?? 0
    }

    public func codes(after rowID: Int64, maxAge: TimeInterval = 300, now: Date = Date()) throws -> (codes: [PhoneCode], last: Int64) {
        let d: SQLiteDB
        do { d = try open() } catch { db = nil; throw error }
        let dateColumn = ["delivered_date", "request_date"].first(where: recordColumns.contains)
        var sql = "SELECT r.\(idColumn) AS rid, r.data AS data"
        if let dateColumn { sql += ", r.\(dateColumn) AS date" }
        if hasAppTable { sql += ", a.identifier AS app FROM record r LEFT JOIN app a ON a.app_id = r.app_id" } else { sql += " FROM record r" }
        sql += " WHERE r.\(idColumn) > ? ORDER BY r.\(idColumn) LIMIT 200"
        let rows: [SQLRow]
        do { rows = try d.query(sql, [rowID]) } catch { db = nil; throw error }

        var last = rowID
        var out: [PhoneCode] = []
        for r in rows {
            let rid = r.int("rid") ?? last
            last = max(last, rid)
            guard let data = r.data("data"), let n = Self.decode(data) else { continue }
            let app = r.string("app") ?? n.app
            if let app, ignoredApps.contains(where: { $0.caseInsensitiveCompare(app) == .orderedSame }) { continue }
            if dateColumn != nil {
                let date = Self.date(r["date"]) ?? now
                guard now.timeIntervalSince(date) <= maxAge else { continue }
            }
            // The title is often the sender or subject; the body holds the code.
            guard let code = OneTimeCode.detect(subject: n.title, body: [n.subtitle, n.body].joined(separator: "\n")) else { continue }
            out.append(PhoneCode(code: code, sender: n.title.isEmpty ? (app ?? "Notification") : n.title,
                                 receivedAt: now, rowID: rid, origin: .notification, app: app))
        }
        return (out, last)
    }

    /// Notification Center stores dates as seconds since 2001.
    static func date(_ v: SQLValue) -> Date? {
        switch v {
        case .double(let d): return Date(timeIntervalSinceReferenceDate: d)
        case .int(let i): return Date(timeIntervalSinceReferenceDate: Double(i))
        default: return nil
        }
    }

    public struct Payload: Equatable, Sendable {
        public var app: String?
        public var title: String
        public var subtitle: String
        public var body: String
    }

    /// Decodes a notification payload. Plain plists keep their structure
    /// ("req" → "titl"/"subt"/"body"); keyed archives fall back to joining
    /// every string they contain, which is enough to find a code.
    static func decode(_ data: Data) -> Payload? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
        if let dict = plist as? [String: Any] {
            if let objects = dict["$objects"] as? [Any] {
                let strings = objects.compactMap { $0 as? String }.filter { $0 != "$null" && !$0.hasPrefix("NS") }
                return Payload(app: nil, title: "", subtitle: "", body: strings.joined(separator: "\n"))
            }
            let req = (dict["req"] as? [String: Any]) ?? dict
            func text(_ keys: [String]) -> String {
                for k in keys { if let s = req[k] as? String { return s } }
                return ""
            }
            let payload = Payload(app: dict["app"] as? String,
                                  title: text(["titl", "title"]),
                                  subtitle: text(["subt", "subtitle"]),
                                  body: text(["body", "message"]))
            return payload.title.isEmpty && payload.body.isEmpty && payload.subtitle.isEmpty ? nil : payload
        }
        return nil
    }
}
