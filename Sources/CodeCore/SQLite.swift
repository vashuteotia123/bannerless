import Foundation
import SQLite3

public enum SQLValue: Sendable, Equatable {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null
}

public protocol SQLConvertible {
    var sqlValue: SQLValue { get }
}

extension Int: SQLConvertible { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLConvertible { public var sqlValue: SQLValue { .int(self) } }
extension UInt32: SQLConvertible { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Double: SQLConvertible { public var sqlValue: SQLValue { .double(self) } }
extension Bool: SQLConvertible { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension String: SQLConvertible { public var sqlValue: SQLValue { .text(self) } }
extension Data: SQLConvertible { public var sqlValue: SQLValue { .blob(self) } }
extension SQLValue: SQLConvertible { public var sqlValue: SQLValue { self } }
extension Optional: SQLConvertible where Wrapped: SQLConvertible {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

public struct SQLRow: Sendable {
    let values: [String: SQLValue]

    public subscript(_ key: String) -> SQLValue { values[key] ?? .null }

    public func string(_ k: String) -> String? {
        switch self[k] {
        case .text(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .blob(let d): return String(data: d, encoding: .utf8)
        case .null: return nil
        }
    }
    public func int(_ k: String) -> Int64? {
        switch self[k] {
        case .int(let i): return i
        case .double(let d): return Int64(d)
        case .text(let s): return Int64(s)
        default: return nil
        }
    }
    public func double(_ k: String) -> Double? {
        switch self[k] {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    public func bool(_ k: String) -> Bool { (int(k) ?? 0) != 0 }
    public func data(_ k: String) -> Data? {
        if case .blob(let d) = self[k] { return d }
        return nil
    }
}

public struct SQLiteError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { "Database error: \(message)" }
}

/// Thread-safe SQLite connection. Every call takes the lock.
public final class SQLiteDB: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            throw SQLiteError(message: msg)
        }
        sqlite3_busy_timeout(db, 5000)
        if !readOnly {
            try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        }
    }

    deinit { sqlite3_close_v2(db) }

    public func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(message: msg)
        }
    }

    @discardableResult
    public func run(_ sql: String, _ args: [SQLConvertible] = []) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw lastError() }
        return sqlite3_last_insert_rowid(db)
    }

    public func changes() -> Int {
        lock.lock(); defer { lock.unlock() }
        return Int(sqlite3_changes(db))
    }

    public func query(_ sql: String, _ args: [SQLConvertible] = []) throws -> [SQLRow] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError() }
            var values: [String: SQLValue] = [:]
            for col in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, col))
                switch sqlite3_column_type(stmt, col) {
                case SQLITE_INTEGER: values[name] = .int(sqlite3_column_int64(stmt, col))
                case SQLITE_FLOAT: values[name] = .double(sqlite3_column_double(stmt, col))
                case SQLITE_TEXT: values[name] = .text(String(cString: sqlite3_column_text(stmt, col)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, col))
                    if let p = sqlite3_column_blob(stmt, col), n > 0 {
                        values[name] = .blob(Data(bytes: p, count: n))
                    } else {
                        values[name] = .blob(Data())
                    }
                default: values[name] = .null
                }
            }
            rows.append(SQLRow(values: values))
        }
        return rows
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ args: [SQLConvertible]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg.sqlValue {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case .blob(let v):
                _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), Self.transient) }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    private func lastError() -> SQLiteError {
        SQLiteError(message: String(cString: sqlite3_errmsg(db)))
    }
}
