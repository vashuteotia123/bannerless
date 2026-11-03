import Foundation

/// Where a code was found.
public enum CodeOrigin: String, Sendable, Equatable {
    /// An SMS or iMessage, read from Messages.
    case messages
    /// A notification shown on this Mac (from Mail, an iPhone app, a browser…).
    case notification
}

/// A sign-in code found in a message or notification.
public struct PhoneCode: Sendable, Equatable {
    public var code: String
    /// Phone number, sender ID (e.g. "AX-BANKCO"), or the notification's title.
    public var sender: String
    public var receivedAt: Date
    public var rowID: Int64
    public var origin: CodeOrigin = .messages
    /// For notifications: the posting app's bundle identifier.
    public var app: String?

    public init(code: String, sender: String, receivedAt: Date, rowID: Int64, origin: CodeOrigin = .messages, app: String? = nil) {
        self.code = code
        self.sender = sender
        self.receivedAt = receivedAt
        self.rowID = rowID
        self.origin = origin
        self.app = app
    }
}

/// Anything Bannerless can watch for codes: an append-only table
/// read by increasing row id.
public protocol CodeSource: AnyObject, Sendable {
    func checkAccess() -> MessagesAccess
    func latestRowID() throws -> Int64
    func codes(after rowID: Int64, maxAge: TimeInterval, now: Date) throws -> (codes: [PhoneCode], last: Int64)
}

public enum MessagesAccess: Sendable, Equatable {
    case granted
    /// macOS blocks the database until Full Disk Access is granted.
    case needsFullDiskAccess
    /// The database doesn't exist (e.g. Messages has never been set up).
    case noMessagesDatabase
}

public typealias SourceAccess = MessagesAccess

/// Reads new incoming messages from the Messages database (read-only) and
/// picks out one-time codes. Message text is never stored or logged.
///
/// SIM texts appear here when the iPhone has Text Message Forwarding turned on
/// for this Mac; iMessages arrive on their own.
public final class MessagesCodeReader: CodeSource, @unchecked Sendable {
    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db").path
    }

    let path: String
    private var db: SQLiteDB?
    private var columns: Set<String> = []

    public init(path: String = MessagesCodeReader.defaultPath) {
        self.path = path
    }

    public func checkAccess() -> MessagesAccess {
        if !FileManager.default.fileExists(atPath: path) {
            // Without Full Disk Access the folder can't even be listed, so a
            // "missing" file usually means "not allowed" rather than absent.
            let dir = (path as NSString).deletingLastPathComponent
            if FileManager.default.fileExists(atPath: dir),
               (try? FileManager.default.contentsOfDirectory(atPath: dir)) == nil {
                return .needsFullDiskAccess
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
        let d = try SQLiteDB(path: path, readOnly: true)
        columns = Set(try d.query("PRAGMA table_info(message)").compactMap { $0.string("name") })
        guard columns.contains("ROWID") || columns.contains("date") else { throw SQLiteError(message: "unexpected schema") }
        db = d
        return d
    }

    public func latestRowID() throws -> Int64 {
        try open().query("SELECT MAX(ROWID) AS n FROM message").first?.int("n") ?? 0
    }

    /// Codes in incoming messages after `rowID`, skipping anything older than
    /// `maxAge` (so a backlog never floods the notch).
    public func codes(after rowID: Int64, maxAge: TimeInterval = 300, now: Date = Date()) throws -> (codes: [PhoneCode], last: Int64) {
        let d: SQLiteDB
        do { d = try open() } catch { db = nil; throw error }
        var sql = """
            SELECT m.ROWID AS rid, m.text AS text, m.date AS date, h.id AS sender\(columns.contains("attributedBody") ? ", m.attributedBody AS body" : "")
            FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.ROWID > ? AND m.is_from_me = 0
            """
        if columns.contains("item_type") { sql += " AND COALESCE(m.item_type, 0) = 0" }
        if columns.contains("associated_message_type") { sql += " AND COALESCE(m.associated_message_type, 0) = 0" }
        sql += " ORDER BY m.ROWID LIMIT 200"
        let rows: [SQLRow]
        do { rows = try d.query(sql, [rowID]) } catch { db = nil; throw error }

        var last = rowID
        var out: [PhoneCode] = []
        for r in rows {
            let rid = r.int("rid") ?? last
            last = max(last, rid)
            let date = Self.appleDate(r["date"])
            guard now.timeIntervalSince(date) <= maxAge else { continue }
            guard let text = Self.messageText(text: r.string("text"), attributedBody: r.data("body")),
                  let code = OneTimeCode.detect(subject: "", body: text) else { continue }
            out.append(PhoneCode(code: code, sender: r.string("sender") ?? "Messages", receivedAt: date, rowID: rid))
        }
        return (out, last)
    }

    /// Messages stores dates as seconds (older) or nanoseconds (newer) since 2001.
    static func appleDate(_ v: SQLValue) -> Date {
        let raw: Double
        switch v {
        case .int(let i): raw = Double(i)
        case .double(let d): raw = d
        default: return .distantPast
        }
        let seconds = raw > 1e11 ? raw / 1e9 : raw
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    static func messageText(text: String?, attributedBody: Data?) -> String? {
        if let t = text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return t }
        return attributedBody.flatMap(TypedStreamText.firstString)
    }
}

/// Extracts the text of an archived NSAttributedString ("typedstream", the
/// format Messages uses for `attributedBody`) without unarchiving objects:
/// it finds the NSString payload and reads its UTF-8 bytes. Decoding with
/// NSUnarchiver would instantiate classes from data a sender influences.
enum TypedStreamText {
    static func firstString(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        let marker = Array("NSString".utf8)
        var searchFrom = 0
        while let at = find(marker, in: bytes, from: searchFrom) {
            searchFrom = at + marker.count
            // After the class name comes a little bookkeeping, then '+'
            // introduces the string with a variable-length size.
            guard let plus = bytes[searchFrom..<min(bytes.count, searchFrom + 12)].firstIndex(of: 0x2B) else { continue }
            var i = plus + 1
            guard i < bytes.count else { return nil }
            var length = 0
            switch bytes[i] {
            case 0x81:
                guard i + 2 < bytes.count else { return nil }
                length = Int(bytes[i + 1]) | Int(bytes[i + 2]) << 8
                i += 3
            case 0x82:
                guard i + 4 < bytes.count else { return nil }
                length = Int(bytes[i + 1]) | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3]) << 16 | Int(bytes[i + 4]) << 24
                i += 5
            default:
                length = Int(bytes[i])
                i += 1
            }
            guard length > 0, i + length <= bytes.count,
                  let s = String(bytes: bytes[i..<(i + length)], encoding: .utf8) else { continue }
            return s
        }
        return nil
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8], from: Int) -> Int? {
        guard needle.count <= hay.count, from <= hay.count - needle.count else { return nil }
        var i = from
        while i <= hay.count - needle.count {
            if hay[i] == needle[0], Array(hay[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }
}

/// Polls Messages for new codes. Polling a ROWID index once a second costs
/// next to nothing and survives Messages rewriting its database files.
public actor PhoneCodeWatcher {
    private let reader: any CodeSource
    private var task: Task<Void, Never>?
    private var lastRowID: Int64 = 0
    private var onCode: @Sendable (PhoneCode) async -> Void = { _ in }
    private var onAccess: @Sendable (MessagesAccess) async -> Void = { _ in }
    public var interval: TimeInterval = 1.0

    public init(reader: any CodeSource = MessagesCodeReader()) {
        self.reader = reader
    }

    public func setHandlers(onCode: @escaping @Sendable (PhoneCode) async -> Void,
                            onAccess: @escaping @Sendable (MessagesAccess) async -> Void) {
        self.onCode = onCode
        self.onAccess = onAccess
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.loop() }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func loop() async {
        var access = MessagesAccess.noMessagesDatabase
        var announced: MessagesAccess?
        while !Task.isCancelled {
            if access != .granted {
                access = reader.checkAccess()
                if access != announced { announced = access; await onAccess(access) }
                if access == .granted {
                    // Start from now: only codes that arrive from here on.
                    lastRowID = (try? reader.latestRowID()) ?? 0
                } else {
                    try? await Task.sleep(for: .seconds(3))
                    continue
                }
            }
            do {
                let (codes, last) = try reader.codes(after: lastRowID, maxAge: 300, now: Date())
                lastRowID = last
                for c in codes { await onCode(c) }
            } catch {
                access = .noMessagesDatabase // re-check access next round
            }
            try? await Task.sleep(for: .seconds(interval))
        }
    }
}
