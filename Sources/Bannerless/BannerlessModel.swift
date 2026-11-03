import AppKit
import CodeCore
import NotchUI
import ServiceManagement
import SwiftUI

struct RecentNotification: Identifiable {
    let id = UUID()
    let app: String
    let title: String
    let body: String
    let appURL: URL?
    let at: Date
}

struct RecentCode: Identifiable, Equatable {
    let id = UUID()
    let code: String
    let sender: String
    let origin: CodeOrigin
    let at: Date
}

@MainActor
final class BannerlessModel: ObservableObject {
    static let shared = BannerlessModel()

    private let messages = PhoneCodeWatcher(reader: MessagesCodeReader())
    private let notificationsReader = NotificationCodeReader()
    private lazy var notifications = PhoneCodeWatcher(reader: notificationsReader)
    /// Notifications mirrored from the iPhone (Gmail, bank apps, …) live in a separate store.
    private let iPhoneReader = RemoteNotificationReader()
    private lazy var iPhoneNotifications = PhoneCodeWatcher(reader: iPhoneReader)
    /// Reads banners as they appear: the fastest route, for every notification.
    private let banners = BannerWatcher()
    @Published var bannersTrusted: Bool?

    @Published var messagesAccess: SourceAccess?
    @Published var macNotificationsAccess: SourceAccess?
    @Published var iPhoneNotificationsAccess: SourceAccess?

    /// Both notification stores, shown as one source.
    var notificationsAccess: SourceAccess? {
        let all = [macNotificationsAccess, iPhoneNotificationsAccess]
        if all.contains(.granted) { return .granted }
        if all.contains(.needsFullDiskAccess) { return .needsFullDiskAccess }
        return all.compactMap { $0 }.first
    }
    /// Kept in memory only, never written anywhere.
    @Published var recent: [RecentCode] = []
    /// Notifications shown in the notch (and closed in macOS), in memory only.
    @Published var recentNotifications: [RecentNotification] = []
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    @AppStorage("messagesEnabled") var messagesEnabled = true { didSet { restart() } }
    @AppStorage("notificationsEnabled") var notificationsEnabled = true { didSet { restart() } }
    @AppStorage("autoCopy") var autoCopy = false
    /// Show every notification in the notch instead of as a macOS banner.
    @AppStorage("allInNotch") var allInNotch = true { didSet { restart() } }
    @AppStorage("paused") var paused = false { didSet { restart() } }
    @AppStorage("didShowSetup") var didShowSetup = false

    private var seen: [String: Date] = [:]
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        NotchController.shared.onOpen = { e in
            if case .notification(_, _, _, let url?) = e { NSWorkspace.shared.open(url) }
        }
        restart()
    }

    func restart() {
        Task {
            await messages.stop()
            await notifications.stop()
            await iPhoneNotifications.stop()
            banners.stop()
            bannersTrusted = nil
            messagesAccess = nil
            macNotificationsAccess = nil
            iPhoneNotificationsAccess = nil
            guard !paused else { return }
            if messagesEnabled {
                await messages.setHandlers(
                    onCode: { c in await MainActor.run { BannerlessModel.shared.found(c) } },
                    onAccess: { a in await MainActor.run { BannerlessModel.shared.messagesAccess = a } })
                await messages.start()
            }
            if notificationsEnabled {
                banners.takeOver = allInNotch
                banners.onBanner = { b, code in BannerlessModel.shared.banner(b, code: code) }
                banners.onTrusted = { t in BannerlessModel.shared.bannersTrusted = t }
                banners.start()
                // Messages notifications would duplicate what's read from Messages directly.
                let ignored: Set<String> = messagesEnabled ? ["com.apple.MobileSMS", "com.apple.iChat"] : []
                notificationsReader.ignoredApps = ignored
                iPhoneReader.ignoredApps = ignored
                await notifications.setHandlers(
                    onCode: { c in await MainActor.run { BannerlessModel.shared.found(c) } },
                    onAccess: { a in await MainActor.run { BannerlessModel.shared.macNotificationsAccess = a } })
                await notifications.start()
                await iPhoneNotifications.setHandlers(
                    onCode: { c in await MainActor.run { BannerlessModel.shared.found(c) } },
                    onAccess: { a in await MainActor.run { BannerlessModel.shared.iPhoneNotificationsAccess = a } })
                await iPhoneNotifications.start()
            }
        }
    }

    var needsSetup: Bool {
        (messagesEnabled && messagesAccess == .needsFullDiskAccess)
            || (notificationsEnabled && (notificationsAccess == .needsFullDiskAccess || bannersTrusted == false))
    }

    func allowAccessibility() {
        BannerWatcher.requestAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    var isWatching: Bool {
        !paused && (messagesAccess == .granted || notificationsAccess == .granted || bannersTrusted == true)
    }

    func found(_ c: PhoneCode) {
        // The same code often arrives twice (SMS and email, or banner and Messages).
        let now = Date()
        seen = seen.filter { now.timeIntervalSince($0.value) < 120 }
        guard seen[c.code] == nil else { return }
        seen[c.code] = now
        let sender = Self.friendly(c.sender)
        recent.insert(RecentCode(code: c.code, sender: sender, origin: c.origin, at: now), at: 0)
        recent = Array(recent.prefix(8))
        if autoCopy { copy(c.code) }
        NotchController.shared.show(.code(c.code, sender: sender, icon: c.origin == .notification ? "bell.fill" : "message.fill"))
    }

    func banner(_ b: BannerWatcher.Banner, code: String?) {
        if let code {
            found(PhoneCode(code: code, sender: b.title.isEmpty ? b.app : b.title, receivedAt: Date(),
                            rowID: 0, origin: .notification, app: b.app))
            return
        }
        guard allInNotch else { return }
        let url = Self.appURL(named: b.app)
        let body = [b.subtitle, b.body].filter { !$0.isEmpty && $0 != b.title }.joined(separator: " — ")
        recentNotifications.insert(RecentNotification(app: b.app, title: b.title, body: body, appURL: url, at: Date()), at: 0)
        recentNotifications = Array(recentNotifications.prefix(10))
        NotchController.shared.show(.notification(app: b.app, title: b.title, body: body, appURL: url))
    }

    func open(_ n: RecentNotification) {
        if let url = n.appURL { NSWorkspace.shared.open(url) }
    }

    /// Finds an app on this Mac by its display name ("Mail", "Script Editor").
    /// iPhone-only apps have none.
    static func appURL(named name: String) -> URL? {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }), let url = running.bundleURL {
            return url
        }
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                    NSHomeDirectory() + "/Applications"]
        for dir in dirs {
            let path = "\(dir)/\(name).app"
            if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    func copy(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Bannerless: launch at login: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// "AX-BANKCO" -> "BANKCO"; everything else unchanged.
    static func friendly(_ s: String) -> String {
        if let dash = s.firstIndex(of: "-"), s.count <= 12, s[..<dash].count == 2,
           s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
            return String(s[s.index(after: dash)...])
        }
        return s
    }
}
