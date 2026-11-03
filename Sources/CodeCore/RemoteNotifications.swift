import Foundation

/// Reads notifications that macOS mirrors from a paired iPhone (iPhone
/// Mirroring / iPhone notifications on Mac), such as Gmail or banking apps,
/// and picks out one-time codes.
///
/// These don't go through Notification Center's database. macOS keeps them as
/// property lists, one folder per paired device:
/// `~/Library/Group Containers/group.com.apple.UserNotifications/Library/
/// UserNotifications/Remote/default/<device>/DeliveredNotifications.plist`.
/// The format isn't documented, so each file is decoded generically: keyed
/// archives are resolved by walking their object graph (no classes are ever
/// instantiated), and any dictionary carrying a title or body counts as a
/// notification. Only notifications that appear after Bannerless starts are
/// checked; notification text is never kept, only a hash to tell new from old.
public final class RemoteNotificationReader: CodeSource, @unchecked Sendable {
    public static var defaultRoot: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.UserNotifications/Library/UserNotifications").path
    }

    public static let fileName = "DeliveredNotifications.plist"

    let root: String
    public var ignoredApps: Set<String>
    /// Per file: its last modification date and the hashes of the notifications it held.
    private var files: [String: (modified: Date, seen: Set<Int>)] = [:]
    private var baselineAt = Date.distantPast
    private var counter: Int64 = 0

    public init(root: String = RemoteNotificationReader.defaultRoot, ignoredApps: Set<String> = []) {
        self.root = root
        self.ignoredApps = ignoredApps
    }

    public func checkAccess() -> MessagesAccess {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            // Without access the parent folder can't be looked into either.
            let parent = (root as NSString).deletingLastPathComponent
            if FileManager.default.fileExists(atPath: parent), (try? FileManager.default.contentsOfDirectory(atPath: parent)) == nil {
                return .needsFullDiskAccess
            }
            return .noMessagesDatabase
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: root)) == nil ? .needsFullDiskAccess : .granted
    }

    /// Remembers everything already delivered, so only new notifications count.
    public func latestRowID() throws -> Int64 {
        files = [:]
        baselineAt = Date()
        for path in Self.storeFiles(under: root) {
            guard let modified = Self.modified(path) else { continue }
            let seen = Set((Self.records(atPath: path) ?? []).map(\.fingerprint))
            files[path] = (modified, seen)
        }
        return counter
    }

    public func codes(after rowID: Int64, maxAge: TimeInterval = 300, now: Date = Date()) throws -> (codes: [PhoneCode], last: Int64) {
        guard checkAccess() == .granted else { throw SQLiteError(message: "no access to iPhone notifications") }
        var out: [PhoneCode] = []
        for path in Self.storeFiles(under: root) {
            guard let modified = Self.modified(path) else { continue }
            let known = files[path]
            if let known, known.modified == modified { continue }
            guard let records = Self.records(atPath: path) else { continue }
            let fingerprints = Set(records.map(\.fingerprint))
            // A device folder that existed before Bannerless started but wasn't
            // readable yet: treat what's in it as old.
            let fresh = known != nil || (Self.created(path) ?? .distantPast) > baselineAt
            files[path] = (modified, fingerprints)
            guard fresh else { continue }
            for r in records where !(known?.seen.contains(r.fingerprint) ?? false) {
                if let app = r.app, ignoredApps.contains(where: { $0.caseInsensitiveCompare(app) == .orderedSame }) { continue }
                if let date = r.date, now.timeIntervalSince(date) > maxAge { continue }
                guard let code = r.code else { continue }
                counter += 1
                out.append(PhoneCode(code: code, sender: r.title.isEmpty ? Self.appName(r.app) : r.title,
                                     receivedAt: now, rowID: counter, origin: .notification, app: r.app))
            }
        }
        return (out, counter)
    }

    // MARK: - Files

    static func storeFiles(under root: String) -> [String] {
        guard let e = FileManager.default.enumerator(atPath: root) else { return [] }
        var out: [String] = []
        while let rel = e.nextObject() as? String {
            if (rel as NSString).lastPathComponent == fileName { out.append((root as NSString).appendingPathComponent(rel)) }
        }
        return out.sorted()
    }

    static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    static func created(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
    }

    /// "com.google.Gmail" -> "Gmail".
    static func appName(_ id: String?) -> String {
        guard let id, let last = id.split(separator: ".").last, !last.isEmpty else { return "iPhone" }
        return String(last)
    }

    // MARK: - Decoding

    public struct Record: Equatable, Sendable {
        public var title = ""
        public var subtitle = ""
        public var body = ""
        public var app: String?
        public var identifier: String?
        public var date: Date?

        public var code: String? {
            OneTimeCode.detect(subject: title, body: [subtitle, body].joined(separator: "\n"))
        }

        var fingerprint: Int {
            var h = Hasher()
            h.combine(identifier)
            h.combine(title)
            h.combine(subtitle)
            h.combine(body)
            h.combine(date)
            return h.finalize()
        }
    }

    static func records(atPath path: String) -> [Record]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return records(from: data)
    }

    /// Every notification in a store file, plain plist or keyed archive.
    public static func records(from data: Data) -> [Record]? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
        let tree = resolveArchive(plist)
        var out: [Record] = []
        collect(tree, context: Record(), into: &out, depth: 0)
        return out
    }

    /// Turns a keyed archive into plain arrays, dictionaries, strings and
    /// dates by following its object references. Anything else is returned as is.
    static func resolveArchive(_ plist: Any) -> Any {
        guard let dict = plist as? [String: Any], let objects = dict["$objects"] as? [Any],
              let top = dict["$top"] as? [String: Any] else { return plist }
        var visiting = Set<Int>()
        if let root = top["root"] { return resolve(root, objects, &visiting, 0) }
        return top.mapValues { resolve($0, objects, &visiting, 0) }
    }

    private static func resolve(_ v: Any, _ objects: [Any], _ visiting: inout Set<Int>, _ depth: Int) -> Any {
        guard depth < 64 else { return NSNull() }
        if let u = uid(v) {
            guard u >= 0, u < objects.count, !visiting.contains(u) else { return NSNull() }
            if let s = objects[u] as? String, s == "$null" { return NSNull() }
            visiting.insert(u)
            defer { visiting.remove(u) }
            return resolve(objects[u], objects, &visiting, depth + 1)
        }
        if let d = v as? [String: Any] {
            if let keys = d["NS.keys"] as? [Any], let values = d["NS.objects"] as? [Any] {
                var out: [String: Any] = [:]
                for (k, val) in zip(keys, values) {
                    if let key = resolve(k, objects, &visiting, depth + 1) as? String {
                        out[key] = resolve(val, objects, &visiting, depth + 1)
                    }
                }
                return out
            }
            if let values = d["NS.objects"] as? [Any] { return values.map { resolve($0, objects, &visiting, depth + 1) } }
            if let s = d["NS.string"] { return resolve(s, objects, &visiting, depth + 1) }
            if let t = d["NS.time"] as? Double { return Date(timeIntervalSinceReferenceDate: t) }
            // Attributed strings keep their text under "NSString".
            if let s = d["NSString"], let text = resolve(s, objects, &visiting, depth + 1) as? String { return text }
            var out: [String: Any] = [:]
            for (k, val) in d where k != "$class" { out[k] = resolve(val, objects, &visiting, depth + 1) }
            return out
        }
        if let a = v as? [Any] { return a.map { resolve($0, objects, &visiting, depth + 1) } }
        return v
    }

    /// A keyed-archive object reference: binary plists give a CFKeyedArchiverUID,
    /// XML ones a {"CF$UID": n} dictionary.
    static func uid(_ v: Any) -> Int? {
        if let d = v as? [String: Any], d.count == 1, let n = d["CF$UID"] as? Int { return n }
        if v is String || v is NSNumber || v is Data || v is Date || v is [Any] || v is [String: Any] { return nil }
        let text = String(describing: v)
        guard text.contains("CFKeyedArchiverUID"), let r = text.range(of: "value = ") else { return nil }
        return Int(text[r.upperBound...].prefix(while: \.isNumber))
    }

    private static let titleKeys = ["title", "titl"]
    private static let subtitleKeys = ["subtitle", "subt"]
    private static let bodyKeys = ["body", "message", "alertbody", "msg"]
    private static let idKeys = ["identifier", "iden", "uuid", "requestidentifier", "notificationidentifier"]
    private static let appKeys = ["app", "appid", "bundleid", "bundleidentifier", "appbundleidentifier", "sectionid",
                                  "sectionidentifier", "sourceidentifier", "sourcebundleidentifier", "originbundleidentifier"]

    /// Any dictionary with a title, subtitle or body is a notification. App,
    /// identifier and date are taken from it or the nearest enclosing dictionary.
    private static func collect(_ v: Any, context: Record, into out: inout [Record], depth: Int) {
        guard depth < 32 else { return }
        if let a = v as? [Any] {
            for x in a { collect(x, context: context, into: &out, depth: depth + 1) }
            return
        }
        guard let d = v as? [String: Any] else { return }
        let lower = Dictionary(d.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        func text(_ keys: [String]) -> String {
            for k in keys { if let s = lower[k] as? String { return s } }
            return ""
        }
        var c = context
        for k in appKeys { if let s = lower[k] as? String, looksLikeBundleID(s) { c.app = s; break } }
        for k in idKeys { if let s = lower[k] as? String, !s.isEmpty { c.identifier = s; break } }
        if let date = lower.first(where: { $0.key.contains("date") && $0.value is Date })?.value as? Date { c.date = date }
        else if let t = lower["date"] as? Double { c.date = Date(timeIntervalSinceReferenceDate: t) }

        let title = text(titleKeys), subtitle = text(subtitleKeys), body = text(bodyKeys)
        if !title.isEmpty || !subtitle.isEmpty || !body.isEmpty {
            c.title = title
            c.subtitle = subtitle
            c.body = body
            out.append(c)
            return
        }
        for k in d.keys.sorted() { collect(d[k]!, context: c, into: &out, depth: depth + 1) }
    }

    static func looksLikeBundleID(_ s: String) -> Bool {
        s.contains(".") && !s.contains(" ") && s.count < 200 && s.first?.isLetter == true
    }
}
