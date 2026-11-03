import AppKit
import ApplicationServices
import CodeCore

/// Reads notification banners the moment macOS shows them, through the
/// Accessibility interface of Notification Center's own process. This covers
/// every banner on the Mac: Mac apps, websites and notifications mirrored from
/// the iPhone. It's instant, unlike Notification Center's database, which
/// macOS writes several seconds after the banner appears.
///
/// Needs the Accessibility permission. Only banners are read (role
/// "AXNotificationCenterBanner", never inside the Notification Center history
/// list, which is recognised by its heading). With
/// `takeOver`, each banner is closed once read so it appears only in the notch;
/// macOS then doesn't keep it in Notification Center.
@MainActor
final class BannerWatcher {
    static let notificationCenter = "com.apple.notificationcenterui"

    /// Every new banner, with its code if it has one.
    var onBanner: (Banner, String?) -> Void = { _, _ in }
    var onTrusted: (Bool) -> Void = { _ in }
    /// Close each macOS banner once read, so it's shown only in the notch.
    var takeOver = false

    private var timer: Timer?
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    /// Banner identifiers already handled, with when they were first seen.
    private var seen: [String: Date] = [:]
    private var baselined = false
    private var retrying = false
    private var registered = false
    private var lastTrusted: Bool?

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's "allow Accessibility" prompt (only the first time).
    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func start() {
        guard timer == nil else { return }
        // Events trigger scans right away; this timer is a fallback and re-checks the permission.
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        detach()
        baselined = false
        seen = [:]
        lastTrusted = nil
    }

    private func tick() {
        let trusted = AXIsProcessTrusted()
        if trusted != lastTrusted { lastTrusted = trusted; onTrusted(trusted) }
        guard trusted else { detach(); baselined = false; return }
        // Registering can fail if it happens just as the permission is granted; retry until it holds.
        if observer != nil, !registered { detach() }
        attachIfNeeded()
        scan()
    }

    // MARK: - Events

    private func attachIfNeeded() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.notificationCenter).first else {
            detach(); return
        }
        guard app.processIdentifier != observedPID || observer == nil else { return }
        detach()
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<BannerWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated {
                me.hideAtOnce(element)
                me.bannerEvent()
            }
        }
        guard AXObserverCreate(app.processIdentifier, callback, &obs) == .success, let obs else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let me = Unmanaged.passUnretained(self).toOpaque()
        var ok = 0
        for n in [kAXWindowCreatedNotification, kAXCreatedNotification, kAXLayoutChangedNotification] {
            let r = AXObserverAddNotification(obs, element, n as CFString, me)
            if r == .success || r == .notificationAlreadyRegistered { ok += 1 }
        }
        registered = ok > 0
        // Common modes, so banners are handled even while a menu is open.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
        observedPID = app.processIdentifier
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        registered = false
        observer = nil
        observedPID = 0
    }

    /// A banner's window appeared: read and close it at once, before it has
    /// slid into view, and look again a few times in case it filled in late.
    /// The first thing done for a new window or element: if it's (or holds) a
    /// new banner, move its window off-screen before anything else, ahead of
    /// reading its text, so it's never drawn on screen.
    private func hideAtOnce(_ element: AXUIElement) {
        guard takeOver, baselined else { return }
        let window: AXUIElement
        if string(element, kAXRoleAttribute) == kAXWindowRole {
            // A brand-new window isn't drawn yet: move it first and check after,
            // putting it straight back if it isn't a new banner (e.g. the
            // Notification Center list opening).
            guard string(element, kAXSubroleAttribute) == "AXSystemDialog",
                  let origin = point(element, kAXPositionAttribute), origin.x > -20000 else { return }
            setPosition(element, CGPoint(x: -30000, y: -30000))
            if let id = firstBannerID(in: element, depth: 0), seen[id] == nil {
                hidden.append((element, origin, [id], Date(), nil))
                scheduleRestore()
            } else {
                setPosition(element, origin)
            }
            return
        } else if string(element, kAXSubroleAttribute) == "AXNotificationCenterBanner" {
            var w: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &w) == .success, let w,
                  CFGetTypeID(w) == AXUIElementGetTypeID() else { return }
            window = w as! AXUIElement
        } else {
            return
        }
        guard let id = firstBannerID(in: window, depth: 0), seen[id] == nil else { return }
        hide(window, banner: id)
    }

    /// Like `find`, but stops at the first banner and reads nothing else.
    private func firstBannerID(in element: AXUIElement, depth: Int) -> String? {
        guard depth < 10 else { return nil }
        let id = string(element, kAXIdentifierAttribute)
        if let id {
            if id.hasPrefix("widget-") { return nil }
            if id == "AXNotificationListItems", children(element).contains(where: { string($0, kAXRoleAttribute) == "AXHeading" }) { return nil }
        }
        if string(element, kAXSubroleAttribute) == "AXNotificationCenterBanner" { return id ?? "?" }
        for c in children(element) { if let found = firstBannerID(in: c, depth: depth + 1) { return found } }
        return nil
    }

    private func bannerEvent() {
        scan()
        guard !retrying else { return }
        retrying = true
        for ms in [15, 40, 90, 180] {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { [weak self] in
                MainActor.assumeIsolated {
                    self?.scan()
                    if ms == 180 { self?.retrying = false }
                }
            }
        }
    }

    // MARK: - Reading banners

    struct Banner {
        var element: AXUIElement
        var window: AXUIElement
        var id: String
        var app: String
        var title = ""
        var subtitle = ""
        var body = ""
    }

    private func scan() {
        guard observedPID != 0 else { return }
        let app = AXUIElementCreateApplication(observedPID)
        var banners: [Banner] = []
        for window in children(app) where string(window, kAXRoleAttribute) == kAXWindowRole {
            find(in: window, window: window, depth: 0, into: &banners)
        }
        let now = Date()
        seen = seen.filter { now.timeIntervalSince($0.value) < 3600 }
        let fresh = banners.filter { seen[$0.id] == nil && !($0.title + $0.subtitle + $0.body).isEmpty }
        for b in fresh { seen[b.id] = now }
        // What's on screen when Bannerless starts is old. Many unseen ones at once
        // means the Notification Center list was opened, not new arrivals.
        guard baselined else { baselined = true; return }
        guard fresh.count <= 3 else { return }
        for b in fresh {
            let code = OneTimeCode.detect(subject: b.title, body: [b.subtitle, b.body].joined(separator: "\n"))
            if takeOver {
                hide(b.window, banner: b.id)
                close(b.element)
            }
            onBanner(b, code)
        }
    }

    /// Moves the banner's window off-screen. Done as the window is created,
    /// before it's drawn, so the macOS banner is never seen; closing alone
    /// still lets it play for about a second.
    ///
    /// The window can also hold notifications Bannerless leaves alone (alerts
    /// that stay until clicked), so it's moved back once the banner is gone.
    private func hide(_ window: AXUIElement, banner id: String) {
        if let i = hidden.firstIndex(where: { CFEqual($0.window, window) }) {
            hidden[i].banners.insert(id)
        } else {
            guard let origin = point(window, kAXPositionAttribute), origin.x > -20000 else { return }
            hidden.append((window, origin, [id], Date(), nil))
        }
        setPosition(window, CGPoint(x: -30000, y: -30000))
        scheduleRestore()
    }

    private var hidden: [(window: AXUIElement, origin: CGPoint, banners: Set<String>, since: Date, goneAt: Date?)] = []
    private var restoreScheduled = false

    private func scheduleRestore() {
        guard !restoreScheduled, !hidden.isEmpty else { return }
        restoreScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.restoreScheduled = false
                self.restoreFinished()
                self.scheduleRestore()
            }
        }
    }

    /// Once a hidden banner is gone, its window is left where it is if nothing
    /// else is in it (macOS deletes it after the closing animation; moving it
    /// back early shows that animation). If an alert shares the window, it's
    /// moved back only after the animation has played off-screen.
    private func restoreFinished() {
        let now = Date()
        for i in hidden.indices where hidden[i].goneAt == nil {
            var inside: [Banner] = []
            find(in: hidden[i].window, window: hidden[i].window, depth: 0, into: &inside)
            if !inside.contains(where: { hidden[i].banners.contains($0.id) }) { hidden[i].goneAt = now }
        }
        hidden.removeAll { entry in
            if let gone = entry.goneAt {
                guard now.timeIntervalSince(gone) > 0.8 else { return false }
                if hasNotifications(entry.window) { setPosition(entry.window, entry.origin) }
                return true
            }
            // Never strand anything off-screen for long.
            guard now.timeIntervalSince(entry.since) > 10 else { return false }
            if hasNotifications(entry.window) { setPosition(entry.window, entry.origin) }
            return true
        }
    }

    /// Whether a window (still) shows any notification: banner, stack or alert.
    private func hasNotifications(_ element: AXUIElement, depth: Int = 0) -> Bool {
        guard depth < 10 else { return false }
        if string(element, kAXSubroleAttribute)?.hasPrefix("AXNotificationCenter") == true { return true }
        return children(element).contains { hasNotifications($0, depth: depth + 1) }
    }

    private func setPosition(_ window: AXUIElement, _ p: CGPoint) {
        var p = p
        if let value = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
    }

    private func point(_ e: AXUIElement, _ attribute: String) -> CGPoint? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    /// The banner's own "Close" action, the same as its ✕ button. Action names
    /// are localised; where it isn't found the banner simply times out
    /// off-screen and stays in Notification Center's list.
    private func close(_ element: AXUIElement) {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let action = (names as? [String])?.first(where: { $0.hasPrefix("Name:Close") }) else { return }
        AXUIElementPerformAction(element, action as CFString)
    }

    private func find(in element: AXUIElement, window: AXUIElement, depth: Int, into out: inout [Banner]) {
        guard depth < 10 else { return }
        // Desktop widgets live in Notification Center's windows too; skip them.
        // So does the Notification Center list, whose items look just like banners:
        // never read or close those.
        if let id = string(element, kAXIdentifierAttribute) {
            if id.hasPrefix("widget-") { return }
            // Live banners share this container with on-screen alerts; the
            // history list is the one with a heading ("Notification Center").
            if id == "AXNotificationListItems", children(element).contains(where: { string($0, kAXRoleAttribute) == "AXHeading" }) { return }
        }
        if string(element, kAXSubroleAttribute) == "AXNotificationCenterBanner" {
            let description = string(element, kAXDescriptionAttribute) ?? ""
            let id = string(element, kAXIdentifierAttribute) ?? description
            var b = Banner(element: element, window: window, id: id, app: description.components(separatedBy: ", ").first ?? "Notification")
            var texts: [String] = []
            collectTexts(element, depth: 0, banner: &b, texts: &texts)
            if b.title.isEmpty && b.subtitle.isEmpty && b.body.isEmpty {
                // Older layouts: unlabeled texts, or only the combined description.
                b.body = texts.isEmpty ? description : texts.joined(separator: "\n")
            }
            out.append(b)
            return
        }
        for c in children(element) { find(in: c, window: window, depth: depth + 1, into: &out) }
    }

    private func collectTexts(_ element: AXUIElement, depth: Int, banner: inout Banner, texts: inout [String]) {
        guard depth < 6 else { return }
        for c in children(element) {
            if string(c, kAXRoleAttribute) == kAXStaticTextRole, let value = string(c, kAXValueAttribute) {
                switch string(c, kAXIdentifierAttribute) {
                case "title": banner.title = value
                case "subtitle": banner.subtitle = value
                case "body": banner.body = value
                default: texts.append(value)
                }
            } else {
                collectTexts(c, depth: depth + 1, banner: &banner, texts: &texts)
            }
        }
    }

    private func children(_ e: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
        return (v as? [AXUIElement]) ?? []
    }

    private func string(_ e: AXUIElement, _ attribute: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return nil }
        return v as? String
    }
}
