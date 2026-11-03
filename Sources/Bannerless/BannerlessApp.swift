import AppKit
import CodeCore
import NotchUI
import SwiftUI

final class BannerlessDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app: no Dock icon even when run as a bare executable.
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            let model = BannerlessModel.shared
            model.start()
            // First run: switch on launch at login and show setup once access is known.
            if !model.didShowSetup {
                model.setLaunchAtLogin(true)
                // Puts Bannerless in the Accessibility list, ready to switch on.
                if !BannerWatcher.isTrusted { BannerWatcher.requestAccess() }
                try? await Task.sleep(for: .seconds(1.5))
                model.didShowSetup = true
                SetupWindow.show()
            }
        }
    }
}

struct BannerlessApp: App {
    @NSApplicationDelegateAdaptor(BannerlessDelegate.self) var delegate
    @StateObject private var model = BannerlessModel.shared

    var body: some Scene {
        MenuBarExtra {
            BannerlessMenu().environmentObject(model)
        } label: {
            Image(systemName: model.needsSetup ? "bell.slash" : (model.isWatching ? "bell.badge.fill" : "bell"))
        }
    }
}

struct BannerlessMenu: View {
    @EnvironmentObject var model: BannerlessModel

    var body: some View {
        if model.paused {
            Text("Paused")
        } else if model.needsSetup {
            Text("Needs a permission — open Setup")
        } else if model.isWatching {
            Text("Showing notifications in the notch")
        } else {
            Text("Starting…")
        }
        Divider()
        if model.recent.isEmpty {
            Text("Codes you receive appear here").foregroundStyle(.secondary)
        } else {
            Section("Recent — click to copy") {
                ForEach(model.recent) { c in
                    Button("\(c.code)   \(c.sender) · \(c.at.formatted(date: .omitted, time: .shortened))") { model.copy(c.code) }
                }
            }
        }
        if !model.recentNotifications.isEmpty {
            Menu("Recent Notifications") {
                ForEach(model.recentNotifications) { n in
                    Button("\(n.title.isEmpty ? n.app : n.title) · \(n.app) · \(n.at.formatted(date: .omitted, time: .shortened))") { model.open(n) }
                }
            }
        }
        Divider()
        Toggle("Texts and iMessages", isOn: $model.messagesEnabled)
        Toggle("Notifications", isOn: $model.notificationsEnabled)
        Toggle("Show All Notifications in the Notch", isOn: $model.allInNotch)
        Toggle("Copy Codes Automatically", isOn: $model.autoCopy)
        Toggle("Pause", isOn: $model.paused)
        Divider()
        Button("Setup and Permissions…") { SetupWindow.show() }
        Toggle("Open at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        Button("Show a Test Code") { NotchController.shared.show(.code("482913", sender: "Bannerless")) }
        Divider()
        Button("Quit Bannerless") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// A plain AppKit window, so it works from a menu bar app without a Dock icon.
enum SetupWindow {
    @MainActor private static var window: NSWindow?

    @MainActor static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Bannerless"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SetupView().environmentObject(BannerlessModel.shared))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SetupView: View {
    @EnvironmentObject var model: BannerlessModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(LinearGradient(colors: [.indigo, .purple], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bannerless").font(.title2.bold())
                    Text("Every notification in the notch. Codes one click away.").foregroundStyle(.secondary)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    statusRow("Texts and iMessages", enabled: model.messagesEnabled, access: model.messagesAccess)
                    statusRow("Notifications (saved)", enabled: model.notificationsEnabled, access: model.notificationsAccess)
                    HStack {
                        Text("Notification banners (instant)")
                        Spacer()
                        if !model.notificationsEnabled {
                            Text("Off").foregroundStyle(.secondary)
                        } else {
                            switch model.bannersTrusted {
                            case true?: Label("Watching", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            case false?: Label("Needs Accessibility", systemImage: "lock.fill").foregroundStyle(.orange)
                            case nil: Label("Checking…", systemImage: "hourglass").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            VStack(alignment: .leading, spacing: 10) {
                step(1, "On your iPhone: Settings → Apps → Messages → Text Message Forwarding, and turn on this Mac. iMessages need nothing extra.")
                step(2, "On this Mac, open Messages once and sign in with the same Apple Account.")
                step(3, "Give Bannerless Full Disk Access. macOS keeps Messages and Notification Center private; this lets Bannerless catch codes from texts and notifications even when no banner is shown. Nothing is stored.")
                step(4, "Give Bannerless Accessibility access, so it can take each notification banner (Mac apps, websites, iPhone notifications) the moment it appears and show it in the notch instead. It only touches notification banners.")
            }

            HStack {
                Button("Open Full Disk Access") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
                .buttonStyle(.borderedProminent)
                Button("Allow Accessibility") { model.allowAccessibility() }
                    .buttonStyle(.borderedProminent)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                Spacer()
                Button("Check Again") { model.restart() }
            }
            Text("In each list, click + and choose Bannerless. After an update, switch it off and on again in both.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Spacer()
                Button("Show a Test Code") { NotchController.shared.show(.code("482913", sender: "Bannerless")) }
            }
        }
        .padding(24)
        .frame(width: 560, height: 600)
    }

    private func statusRow(_ title: String, enabled: Bool, access: SourceAccess?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if !enabled {
                Text("Off").foregroundStyle(.secondary)
            } else {
                switch access {
                case .granted?: Label("Watching", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .needsFullDiskAccess?: Label("Needs Full Disk Access", systemImage: "lock.fill").foregroundStyle(.orange)
                case .noMessagesDatabase?: Label("Not set up on this Mac", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case nil: Label("Checking…", systemImage: "hourglass").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.caption.bold()).frame(width: 20, height: 20).background(Color.accentColor.opacity(0.2), in: Circle())
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
