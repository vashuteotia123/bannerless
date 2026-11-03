import Foundation

/// A structure-only report about the Messages and Notification Center
/// databases, for working out why codes aren't found. It lists tables,
/// columns, app identifiers and payload *shapes* (key names, value types and
/// lengths) but never message text, notification text or codes.
public enum CodeDiagnostics {
    public static func report(notificationPaths: [String] = NotificationCodeReader.candidatePaths,
                              messagesPath: String = MessagesCodeReader.defaultPath,
                              recent: Int = 25) -> String {
        var out: [String] = ["Bannerless diagnostics — \(ISO8601DateFormatter().string(from: Date()))", ""]

        out.append("## Notification Center")
        for p in notificationPaths {
            out.append("path \(p): exists=\(FileManager.default.fileExists(atPath: p))")
        }
        let reader = NotificationCodeReader(paths: notificationPaths)
        out.append("access: \(reader.checkAccess())")
        if let path = notificationPaths.first(where: { FileManager.default.fileExists(atPath: $0) }),
           let db = try? SQLiteDB(path: path, readOnly: true) {
            let tables = (try? db.query("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"))?.compactMap { $0.string("name") } ?? []
            out.append("tables: \(tables.joined(separator: ", "))")
            for t in ["record", "app", "delivered", "displayed", "requests"] where tables.contains(t) {
                let cols = (try? db.query("PRAGMA table_info(\(t))"))?.compactMap { $0.string("name") } ?? []
                let n = (try? db.query("SELECT COUNT(*) AS n FROM \(t)"))?.first?.int("n") ?? -1
                out.append("  \(t) (\(n) rows): \(cols.joined(separator: ", "))")
            }
            if tables.contains("record") {
                let cols = Set((try? db.query("PRAGMA table_info(record)"))?.compactMap { $0.string("name") } ?? [])
                let id = cols.contains("rec_id") ? "rec_id" : "ROWID"
                let hasApp = tables.contains("app") && cols.contains("app_id")
                let sql = "SELECT r.\(id) AS rid, r.data AS data" + (cols.contains("delivered_date") ? ", r.delivered_date AS d" : "")
                    + (hasApp ? ", a.identifier AS app FROM record r LEFT JOIN app a ON a.app_id = r.app_id" : " FROM record r")
                    + " ORDER BY r.\(id) DESC LIMIT \(recent)"
                out.append("")
                out.append("most recent \(recent) notifications (newest first):")
                for r in (try? db.query(sql)) ?? [] {
                    var line = "- #\(r.int("rid") ?? 0) app=\(r.string("app") ?? "?")"
                    if case .double(let d) = r["d"] {
                        line += " age=\(Int(Date().timeIntervalSinceReferenceDate - d))s"
                    }
                    guard let data = r.data("data") else { out.append(line + " data=none"); continue }
                    line += " data=\(data.count)B \(data.prefix(8).map { String(format: "%02x", $0) }.joined())"
                    if let payload = NotificationCodeReader.decode(data) {
                        line += " decoded(title=\(payload.title.count)ch subtitle=\(payload.subtitle.count)ch body=\(payload.body.count)ch)"
                        let found = OneTimeCode.detect(subject: payload.title, body: payload.subtitle + "\n" + payload.body) != nil
                        line += " code=\(found ? "FOUND" : "none")"
                        let all = [payload.title, payload.subtitle, payload.body]
                        if all.joined().contains(where: \.isNumber) {
                            line += "\n    outline: title=\"\(mask(payload.title))\" subtitle=\"\(mask(payload.subtitle))\" body=\"\(mask(payload.body))\""
                        }
                    } else {
                        line += " decoded=FAILED"
                    }
                    out.append(line)
                    if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                        out.append(contentsOf: shape(plist, indent: "    ", depth: 0))
                    }
                }
            }
        } else {
            out.append("could not open the database")
        }

        out.append("")
        out.append("## Apps registered with Notification Center")
        if let path = notificationPaths.first(where: { FileManager.default.fileExists(atPath: $0) }),
           let db = try? SQLiteDB(path: path, readOnly: true) {
            let apps = (try? db.query("SELECT identifier FROM app ORDER BY identifier"))?.compactMap { $0.string("identifier") } ?? []
            out.append(apps.joined(separator: ", "))
        }

        out.append("")
        out.append("## iPhone notifications")
        out.append(contentsOf: iPhoneReport())

        out.append("")
        out.append("## Other notification-related stores (names and sizes only)")
        out.append(contentsOf: candidateStores())

        out.append("")
        out.append("## Messages")
        let m = MessagesCodeReader(path: messagesPath)
        out.append("path \(messagesPath): exists=\(FileManager.default.fileExists(atPath: messagesPath)) access: \(m.checkAccess())")
        return out.joined(separator: "\n")
    }

    /// Keeps the layout of a text but none of its content: digits become 9,
    /// other words become x's, except words that commonly sit next to codes.
    public static func mask(_ text: String) -> String {
        let keep: Set<String> = ["otp", "code", "codes", "verification", "verify", "is", "your", "use", "to", "sign", "in",
                                 "signin", "sign-in", "log-in", "login", "log", "one", "time", "one-time", "passcode", "pin", "security", "for",
                                 "do", "not", "share", "valid", "minutes", "mins", "min", "expires", "the", "and", "g",
                                 "gmail", "google", "apple", "account", "confirm", "confirmation", "authentication", "2fa",
                                 "rs", "inr", "txn", "a/c", "card", "debited", "credited", "order", "ref", "id", "with", "anyone"]
        var out = ""
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            if keep.contains(word.lowercased()) { out += word }
            else { out += String(word.map { $0.isNumber ? "9" : ($0.isLetter ? "x" : $0) }) }
            word = ""
        }
        for ch in text {
            if ch.isLetter || ch.isNumber || ch == "/" || ch == "-" { word.append(ch) } else { flush(); out.append(ch == "\n" ? "⏎" : ch) }
        }
        flush()
        return out
    }

    /// The mirrored-iPhone store: file layout, archive classes, and each
    /// notification's app, age and masked outline.
    static func iPhoneReport(root: String = RemoteNotificationReader.defaultRoot, recent: Int = 25) -> [String] {
        let reader = RemoteNotificationReader(root: root)
        var out = ["root \(root): access: \(reader.checkAccess())"]
        for path in RemoteNotificationReader.storeFiles(under: root) {
            let rel = path.replacingOccurrences(of: root + "/", with: "")
            guard let data = FileManager.default.contents(atPath: path) else { out.append("- \(rel): unreadable"); continue }
            let age = RemoteNotificationReader.modified(path).map { "\(Int(Date().timeIntervalSince($0)))s" } ?? "?"
            out.append("- \(rel): \(data.count)B, modified \(age) ago")
            guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
                out.append("    not a property list"); continue
            }
            if let d = plist as? [String: Any], let objects = d["$objects"] as? [Any] {
                let classes = Set(objects.compactMap { ($0 as? [String: Any])?["$classname"] as? String })
                out.append("    keyed archive, \(objects.count) objects, classes: \(classes.sorted().joined(separator: ", "))")
            } else {
                out.append("    plain \(type(of: plist))")
            }
            out.append(contentsOf: shape(RemoteNotificationReader.resolveArchive(plist), indent: "    ", depth: 0).prefix(60))
            let records = RemoteNotificationReader.records(from: data) ?? []
            out.append("    \(records.count) notifications found")
            for r in records.suffix(recent) {
                var line = "    • app=\(r.app ?? "?") id=\(r.identifier == nil ? "no" : "yes")"
                line += " age=\(r.date.map { "\(Int(Date().timeIntervalSince($0)))s" } ?? "?")"
                line += " code=\(r.code == nil ? "none" : "FOUND")"
                if (r.title + r.subtitle + r.body).contains(where: \.isNumber) {
                    line += " outline: title=\"\(mask(r.title))\" subtitle=\"\(mask(r.subtitle))\" body=\"\(mask(r.body))\""
                }
                out.append(line)
            }
        }
        return out
    }

    /// Notification-related databases elsewhere in the user's containers.
    static func candidateStores() -> [String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var out: [String] = []
        let roots = [home.appendingPathComponent("Library/Group Containers"), home.appendingPathComponent("Library/Containers"),
                     home.appendingPathComponent("Library/Application Support")]
        let hints = ["notif", "usernot", "continuity", "mirror", "iphone", "companion", "bulletin"]
        for root in roots {
            guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { out.append("\(root.path): not readable"); continue }
            for n in names where hints.contains(where: { n.lowercased().contains($0) }) {
                let dir = root.appendingPathComponent(n)
                var files: [String] = []
                if let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
                    for case let f as URL in e {
                        let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        let ext = f.pathExtension.lowercased()
                        if size > 0, ["db", "sqlite", "sqlite3", "plist", ""].contains(ext) || f.lastPathComponent == "db" {
                            files.append("\(f.path.replacingOccurrences(of: dir.path + "/", with: "")) \(size)B")
                        }
                        if files.count > 25 { break }
                    }
                }
                out.append("\(root.lastPathComponent)/\(n): \(files.isEmpty ? "(no data files)" : files.joined(separator: ", "))")
            }
        }
        return out
    }

    /// Watches for new notification records for `seconds`, describing each as
    /// it arrives (so quickly dismissed ones are seen too).
    public static func watch(seconds: TimeInterval, paths: [String] = NotificationCodeReader.candidatePaths, log: (String) -> Void) {
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let db = try? SQLiteDB(path: path, readOnly: true) else { log("cannot open notification database"); return }
        var last = (try? db.query("SELECT MAX(rec_id) AS n FROM record"))?.first?.int("n") ?? 0
        log("watching from record #\(last) for \(Int(seconds))s")
        let root = RemoteNotificationReader.defaultRoot
        var iPhoneSeen: [String: Set<Int>] = [:]
        var iPhoneModified: [String: Date] = [:]
        for f in RemoteNotificationReader.storeFiles(under: root) {
            iPhoneSeen[f] = Set((RemoteNotificationReader.records(atPath: f) ?? []).map(\.fingerprint))
            iPhoneModified[f] = RemoteNotificationReader.modified(f)
        }
        log("watching \(iPhoneSeen.count) iPhone notification files")
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            for f in RemoteNotificationReader.storeFiles(under: root) {
                let m = RemoteNotificationReader.modified(f)
                guard m != iPhoneModified[f] else { continue }
                iPhoneModified[f] = m
                let records = RemoteNotificationReader.records(atPath: f) ?? []
                if records.isEmpty { log("\(ISO8601DateFormatter().string(from: Date())) iPhone file changed, 0 notifications decoded") }
                for r in records where !(iPhoneSeen[f]?.contains(r.fingerprint) ?? false) {
                    log("\(ISO8601DateFormatter().string(from: Date())) iPhone app=\(r.app ?? "?") code=\(r.code == nil ? "none" : "FOUND") outline: title=\"\(mask(r.title))\" subtitle=\"\(mask(r.subtitle))\" body=\"\(mask(r.body))\"")
                }
                iPhoneSeen[f] = Set(records.map(\.fingerprint))
            }
            let rows = (try? db.query("SELECT r.rec_id AS rid, r.data AS data, a.identifier AS app FROM record r LEFT JOIN app a ON a.app_id = r.app_id WHERE r.rec_id > ? ORDER BY r.rec_id", [last])) ?? []
            for r in rows {
                last = max(last, r.int("rid") ?? last)
                var line = "\(ISO8601DateFormatter().string(from: Date())) #\(r.int("rid") ?? 0) app=\(r.string("app") ?? "?")"
                if let data = r.data("data"), let p = NotificationCodeReader.decode(data) {
                    let found = OneTimeCode.detect(subject: p.title, body: p.subtitle + "\n" + p.body) != nil
                    line += " code=\(found ? "FOUND" : "none") outline: title=\"\(mask(p.title))\" subtitle=\"\(mask(p.subtitle))\" body=\"\(mask(p.body))\""
                } else {
                    line += " decoded=FAILED"
                }
                log(line)
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        log("done")
    }

    /// Describes a property list's structure: keys, types and sizes only.
    static func shape(_ v: Any, indent: String, depth: Int) -> [String] {
        guard depth < 5 else { return ["\(indent)…"] }
        var out: [String] = []
        if let d = v as? [String: Any] {
            for k in d.keys.sorted() {
                let child = d[k]!
                switch child {
                case let s as String: out.append("\(indent)\(k): String(\(s.count)ch\(s.contains(where: \.isNumber) ? ", digits" : ""))")
                case let a as [Any]:
                    out.append("\(indent)\(k): Array(\(a.count))")
                    if k == "$objects" {
                        let kinds = a.map { x -> String in
                            if let s = x as? String { return "String(\(s.count))" }
                            if x is [String: Any] { return "Dict" }
                            if x is Data { return "Data" }
                            return String(describing: type(of: x))
                        }
                        out.append("\(indent)  [\(kinds.prefix(40).joined(separator: ", "))]")
                    } else if let first = a.first {
                        out += shape(first, indent: indent + "  ", depth: depth + 1)
                    }
                case is [String: Any]:
                    out.append("\(indent)\(k): Dict")
                    out += shape(child, indent: indent + "  ", depth: depth + 1)
                case let data as Data: out.append("\(indent)\(k): Data(\(data.count)B)")
                case is NSNumber: out.append("\(indent)\(k): Number")
                case is Date: out.append("\(indent)\(k): Date")
                default: out.append("\(indent)\(k): \(type(of: child))")
                }
            }
        }
        return out
    }
}
