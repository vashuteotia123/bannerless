import Foundation
import Testing
@testable import CodeCore

/// A database shaped like Notification Center's (app + record tables, plist payloads).
final class FakeNotificationDB {
    let path: String
    let db: SQLiteDB

    init(withAppTable: Bool = true) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usernoted-\(UUID().uuidString)/db2")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("db").path
        db = try SQLiteDB(path: path)
        if withAppTable {
            try db.exec("""
            CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier VARCHAR, badge INTEGER);
            CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, uuid BLOB, data BLOB,
                request_date REAL, request_last_date REAL, delivered_date REAL, presented BOOL, style INTEGER, snooze_fire_date REAL);
            """)
        } else {
            try db.exec("CREATE TABLE record (rec_id INTEGER PRIMARY KEY, data BLOB, delivered_date REAL);")
        }
    }

    @discardableResult
    func add(app: String, title: String, subtitle: String = "", body: String, at date: Date = Date(), keyed: Bool = false) throws -> Int64 {
        let payload: Data
        if keyed {
            let archive: [String: Any] = ["$archiver": "NSKeyedArchiver", "$version": 100000,
                                          "$objects": ["$null", title, subtitle, body, "NSMutableDictionary"], "$top": [:] as [String: Any]]
            payload = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
        } else {
            let plist: [String: Any] = ["app": app, "date": date.timeIntervalSinceReferenceDate,
                                        "req": ["titl": title, "subt": subtitle, "body": body, "iden": UUID().uuidString]]
            payload = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        }
        let cols = Set(try db.query("PRAGMA table_info(record)").compactMap { $0.string("name") })
        if cols.contains("app_id") {
            let id = try db.query("SELECT app_id FROM app WHERE identifier = ?", [app]).first?.int("app_id")
                ?? (try db.run("INSERT INTO app (identifier, badge) VALUES (?, 0)", [app]))
            return try db.run("INSERT INTO record (app_id, data, delivered_date) VALUES (?, ?, ?)",
                              [id, payload, date.timeIntervalSinceReferenceDate])
        }
        return try db.run("INSERT INTO record (data, delivered_date) VALUES (?, ?)", [payload, date.timeIntervalSinceReferenceDate])
    }
}

@Suite struct NotificationCodeTests {
    @Test func findsCodesInNewNotifications() throws {
        let fake = try FakeNotificationDB()
        try fake.add(app: "com.apple.mail", title: "Old", body: "Your code is 100200")
        let reader = NotificationCodeReader(paths: [fake.path], ignoredApps: ["com.apple.MobileSMS"])
        #expect(reader.checkAccess() == .granted)
        let start = try reader.latestRowID()

        try fake.add(app: "com.apple.mail", title: "Acme", subtitle: "482913 is your Acme sign-in code", body: "Use it within 10 minutes.")
        try fake.add(app: "com.google.Chrome", title: "Gmail", body: "Your verification code is 739204")
        try fake.add(app: "com.apple.mobilesms", title: "BANKCO", body: "OTP 118833")      // read via Messages instead (ids are stored lowercased)
        try fake.add(app: "com.apple.mail", title: "Ana", body: "Lunch at 1230 in room 4410?")
        try fake.add(app: "com.apple.mail", title: "Late", body: "Your code is 551100", at: Date().addingTimeInterval(-3600))

        let (codes, last) = try reader.codes(after: start)
        #expect(codes.map(\.code) == ["482913", "739204"])
        #expect(codes.map(\.sender) == ["Acme", "Gmail"])
        #expect(codes.allSatisfy { $0.origin == .notification })
        #expect(codes.first?.app == "com.apple.mail")
        #expect(last == start + 5)
    }

    @Test func handlesKeyedArchivePayloadsAndOlderLayouts() throws {
        let fake = try FakeNotificationDB(withAppTable: false)
        let reader = NotificationCodeReader(paths: [fake.path])
        #expect(reader.checkAccess() == .granted)
        try fake.add(app: "x", title: "Bank", body: "Your one-time passcode is 640021", keyed: true)
        #expect(try reader.codes(after: 0).codes.map(\.code) == ["640021"])
    }

    @Test func decodesPayload() throws {
        let plist: [String: Any] = ["app": "com.apple.mail", "req": ["titl": "T", "subt": "S", "body": "B"]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        #expect(NotificationCodeReader.decode(data) == .init(app: "com.apple.mail", title: "T", subtitle: "S", body: "B"))
        #expect(NotificationCodeReader.decode(Data("not a plist".utf8)) == nil)
    }

    @Test func reportsAccessProblems() throws {
        #expect(NotificationCodeReader(paths: ["/nonexistent-\(UUID().uuidString)/db2/db"]).checkAccess() == .noMessagesDatabase)
        let fake = try FakeNotificationDB()
        let container = ((fake.path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: container)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: container) }
        #expect(NotificationCodeReader(paths: [fake.path]).checkAccess() == .needsFullDiskAccess)
    }

    actor Seen {
        var codes: [String] = []
        func add(_ c: String) { codes.append(c) }
    }

    @Test func watcherWorksWithNotifications() async throws {
        let fake = try FakeNotificationDB()
        let watcher = PhoneCodeWatcher(reader: NotificationCodeReader(paths: [fake.path]))
        let seen = Seen()
        await watcher.setHandlers(onCode: { await seen.add($0.code) }, onAccess: { _ in })
        await watcher.start()
        try await Task.sleep(for: .milliseconds(300))
        try fake.add(app: "com.apple.mail", title: "Northwind", body: "482913 is your Northwind sign-in code")
        var waited = 0
        while await seen.codes.isEmpty && waited < 40 { try await Task.sleep(for: .milliseconds(100)); waited += 1 }
        await watcher.stop()
        #expect(await seen.codes == ["482913"])
    }

    @Test func maskKeepsLayoutButNoContent() {
        #expect(CodeDiagnostics.mask("482913 is your Northwind sign-in code") == "999999 is your xxxxxxxxx sign-in code")
        #expect(CodeDiagnostics.mask("Rs.2500 debited\nCall 1800") == "Rs.9999 debited⏎xxxx 9999")
    }
}
