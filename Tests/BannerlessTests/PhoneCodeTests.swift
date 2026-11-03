import AppKit
import Foundation
import Testing
@testable import CodeCore

/// Builds a database with the parts of the Messages schema Bannerless reads.
final class FakeMessagesDB {
    let path: String
    let db: SQLiteDB

    init() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("msgs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("chat.db").path
        db = try SQLiteDB(path: path)
        try db.exec("""
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL, service TEXT);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT, text TEXT, attributedBody BLOB,
            handle_id INTEGER DEFAULT 0, date INTEGER, is_from_me INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0,
            associated_message_type INTEGER DEFAULT 0, service TEXT);
        """)
    }

    @discardableResult
    func add(_ text: String, from sender: String = "AX-BANKCO", fromMe: Bool = false, asBody: Bool = false,
             at date: Date = Date(), reaction: Bool = false) throws -> Int64 {
        let h = try db.query("SELECT ROWID FROM handle WHERE id = ?", [sender]).first?.int("ROWID")
            ?? (try db.run("INSERT INTO handle (id, service) VALUES (?, 'SMS')", [sender]))
        let ns = Int64(date.timeIntervalSinceReferenceDate * 1e9)
        let body: SQLValue = asBody ? .blob(Self.archive(text)) : .null
        let plain: SQLValue = asBody ? .null : .text(text)
        return try db.run("INSERT INTO message (text, attributedBody, handle_id, date, is_from_me, associated_message_type) VALUES (?, ?, ?, ?, ?, ?)",
                          [plain, body, h, ns, fromMe, reaction ? 2000 : 0])
    }

    /// The same typedstream encoding Messages uses for attributedBody.
    static func archive(_ s: String) -> Data {
        NSArchiver.archivedData(withRootObject: NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 12)]))
    }
}

@Suite struct PhoneCodeTests {
    @Test func decodesTypedStreamWithoutUnarchiving() {
        let short = "Your code is 482913"
        #expect(TypedStreamText.firstString(FakeMessagesDB.archive(short)) == short)
        let long = String(repeating: "Long message text. ", count: 20) + "OTP 739204"
        #expect(TypedStreamText.firstString(FakeMessagesDB.archive(long)) == long)
        let unicode = "आपका OTP 551203 है 🙂"
        #expect(TypedStreamText.firstString(FakeMessagesDB.archive(unicode)) == unicode)
        #expect(TypedStreamText.firstString(Data("garbage".utf8)) == nil)
    }

    @Test func convertsAppleDates() {
        let d = Date(timeIntervalSinceReferenceDate: 800_000_000)
        #expect(abs(MessagesCodeReader.appleDate(.int(800_000_000)).timeIntervalSince(d)) < 1)
        #expect(abs(MessagesCodeReader.appleDate(.int(800_000_000 * 1_000_000_000)).timeIntervalSince(d)) < 1)
    }

    @Test func readsOnlyNewIncomingCodes() throws {
        let fake = try FakeMessagesDB()
        try fake.add("123456 is your OTP for login. Do not share it with anyone.")
        let reader = MessagesCodeReader(path: fake.path)
        #expect(reader.checkAccess() == .granted)
        let start = try reader.latestRowID()

        try fake.add("Use 7391 as your FoodCo verification code", from: "VM-FOODCO")
        try fake.add("Your code is 999111", fromMe: true)                       // sent by me
        try fake.add("Loved “Your code is 222333”", reaction: true)             // a tapback
        try fake.add("G-552891 is your Google verification code.", from: "22000", asBody: true) // newer macOS: text only in attributedBody
        try fake.add("Dinner at 8?", from: "+15551234567")                       // no code
        try fake.add("Your code is 640021", at: Date().addingTimeInterval(-3600)) // too old

        let (codes, last) = try reader.codes(after: start)
        #expect(codes.map(\.code) == ["7391", "552891"])
        #expect(codes.map(\.sender) == ["VM-FOODCO", "22000"])
        #expect(last == start + 6)
        #expect(try reader.codes(after: last).codes.isEmpty)
    }

    @Test func reportsMissingDatabase() {
        let reader = MessagesCodeReader(path: "/nonexistent-\(UUID().uuidString)/chat.db")
        #expect(reader.checkAccess() == .noMessagesDatabase)
    }

    @Test func reportsBlockedDatabase() throws {
        let fake = try FakeMessagesDB()
        let dir = (fake.path as NSString).deletingLastPathComponent
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir) }
        #expect(MessagesCodeReader(path: fake.path).checkAccess() == .needsFullDiskAccess)
    }

    @Test(arguments: [
        ("Dear Customer, OTP for txn of INR 5,000.00 at AMAZON on card XX1234 is 482913. Valid for 10 mins.", "482913"),
        ("Rs.2500 debited. OTP to approve: 118833. Do not share.", "118833"),
        ("Your WhatsApp code: 123-456. Don't share this code with others", "123456"),
        ("Your Apple Account code is: 774920. Do not share it with anyone.\n\n@apple.com #774920 %apple.com", "774920"),
        ("G-552891 is your Google verification code.", "552891"),
        ("<#> 4821 is your Zomato OTP. Do not share it. abcXYZ123", "4821"),
    ])
    func findsSMSCodes(text: String, expected: String) {
        #expect(OneTimeCode.detect(subject: "", body: text) == expected)
    }

    @Test(arguments: [
        "Your A/c XX1234 is debited for Rs.500.00 on 01-11-26. Avl Bal: Rs.12,000.",
        "Your order #482913 has shipped and arrives Thursday.",
        "Call 18005550100 for help with your account.",
    ])
    func ignoresSMSNonCodes(text: String) {
        #expect(OneTimeCode.detect(subject: "", body: text) == nil)
    }

    actor Seen {
        var codes: [String] = []
        var access: [MessagesAccess] = []
        func add(_ c: String) { codes.append(c) }
        func add(_ a: MessagesAccess) { access.append(a) }
    }

    @Test func watcherAnnouncesNewCodesOnly() async throws {
        let fake = try FakeMessagesDB()
        try fake.add("Your code is 111222")  // already there before watching
        let watcher = PhoneCodeWatcher(reader: MessagesCodeReader(path: fake.path))
        let seen = Seen()
        await watcher.setHandlers(onCode: { await seen.add($0.code) }, onAccess: { await seen.add($0) })
        await watcher.start()
        try await Task.sleep(for: .milliseconds(400))
        try fake.add("Your Uber code is 4471. Never share this code.", from: "UBER")
        var waited = 0
        while await seen.codes.isEmpty && waited < 40 {
            try await Task.sleep(for: .milliseconds(100)); waited += 1
        }
        await watcher.stop()
        #expect(await seen.codes == ["4471"])
        #expect(await seen.access == [.granted])
    }
}
