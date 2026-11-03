import Foundation
import Testing
@testable import CodeCore

/// A folder shaped like macOS's mirrored-iPhone notification store.
final class FakeRemoteStore {
    let root: String
    let file: String
    var entries: [[String: Any]] = []
    let keyed: Bool

    init(keyed: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("UserNotifications-\(UUID().uuidString)").path
        let dir = (root as NSString).appendingPathComponent("Remote/default/\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        file = (dir as NSString).appendingPathComponent(RemoteNotificationReader.fileName)
        self.keyed = keyed
        try save()
    }

    func add(app: String, title: String, body: String, at date: Date = Date()) throws {
        if keyed {
            entries.append(["bundleIdentifier": app, "identifier": UUID().uuidString, "date": date,
                            "content": ["title": title, "subtitle": "", "body": NSAttributedString(string: body)]])
        } else {
            entries.append(["app": app, "date": date.timeIntervalSinceReferenceDate,
                            "req": ["titl": title, "body": body, "iden": UUID().uuidString]])
        }
        try save()
    }

    private func save() throws {
        let data = keyed
            ? try NSKeyedArchiver.archivedData(withRootObject: entries as NSArray, requiringSecureCoding: false)
            : try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
        // Make sure the modification date moves on.
        Thread.sleep(forTimeInterval: 0.01)
        try data.write(to: URL(fileURLWithPath: file))
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file)
    }
}

@Suite struct RemoteNotificationTests {
    @Test func decodesKeyedArchives() throws {
        let store = try FakeRemoteStore()
        try store.add(app: "com.google.Gmail", title: "Google", body: "G-552891 is your Google verification code.")
        let records = try #require(RemoteNotificationReader.records(atPath: store.file))
        #expect(records.count == 1)
        #expect(records.first?.app == "com.google.Gmail")
        #expect(records.first?.title == "Google")
        #expect(records.first?.date != nil)
        #expect(records.first?.code == "552891")
    }

    @Test func onlyNewNotificationsCount() throws {
        for keyed in [true, false] {
            let store = try FakeRemoteStore(keyed: keyed)
            try store.add(app: "com.google.Gmail", title: "Google", body: "Your code is 111222")
            let reader = RemoteNotificationReader(root: store.root)
            #expect(reader.checkAccess() == .granted)
            let start = try reader.latestRowID()

            var result = try reader.codes(after: start)
            #expect(result.codes.isEmpty)

            try store.add(app: "com.google.Gmail", title: "Google", body: "Your verification code is 482913")
            result = try reader.codes(after: result.last)
            #expect(result.codes.map(\.code) == ["482913"], "keyed=\(keyed)")
            #expect(result.codes.first?.origin == .notification)
            #expect(result.codes.first?.sender == "Google")

            // Nothing changed: nothing new.
            #expect(try reader.codes(after: result.last).codes.isEmpty)
        }
    }

    @Test func skipsOldAndIgnoredNotifications() throws {
        let store = try FakeRemoteStore()
        let reader = RemoteNotificationReader(root: store.root, ignoredApps: ["com.apple.MobileSMS"])
        _ = try reader.latestRowID()
        try store.add(app: "com.apple.mobilesms", title: "Bank", body: "OTP is 765432")
        try store.add(app: "com.example.bank", title: "Bank", body: "OTP is 345678", at: Date().addingTimeInterval(-3600))
        try store.add(app: "com.example.bank", title: "Bank", body: "Your order 4521 has shipped")
        #expect(try reader.codes(after: 0).codes.isEmpty)
    }

    @Test func missingStoreIsNotAnError() {
        let reader = RemoteNotificationReader(root: "/nonexistent/UserNotifications")
        #expect(reader.checkAccess() == .noMessagesDatabase)
    }
}
