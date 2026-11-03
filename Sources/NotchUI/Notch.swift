import AppKit
import SwiftUI

public enum NotchEvent: Equatable {
    /// A sign-in code. `icon` is an SF Symbol: "message.fill" for texts, "bell.fill" for notifications.
    case code(String, sender: String, icon: String = "message.fill")
    /// Any other notification, shown in place of the macOS banner. `appURL` gives its icon and what a click opens.
    case notification(app: String, title: String, body: String, appURL: URL?)

    var duration: TimeInterval {
        if case .code = self { return 12 }
        return 6
    }

    var isCode: Bool {
        if case .code = self { return true }
        return false
    }
}

/// A borderless panel that can sit over the menu bar.
final class NotchPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows sign-in codes and notifications growing out of the notch of the
/// display you're using (the one with the pointer). On displays without a
/// notch it drops down from the top centre of the menu bar.
@MainActor
public final class NotchController: ObservableObject {
    public static let shared = NotchController()

    /// Called when a notification (not a code) is clicked.
    public var onOpen: ((NotchEvent) -> Void)?

    @Published private(set) var event: NotchEvent?
    @Published private(set) var expanded = false
    @Published private(set) var notchSize = CGSize(width: 190, height: 32)
    @Published var copied = false
    var hovering = false {
        didSet { if !hovering, expanded { scheduleHide(after: 1.5) } }
    }

    static let expandedWidth: CGFloat = 400
    static let contentHeight: CGFloat = 66

    private var panel: NotchPanel?
    private var queue: [NotchEvent] = []
    private var hideWork: DispatchWorkItem?

    public func show(_ e: NotchEvent) {
        if event == nil {
            present(e)
        } else if event?.isCode == false {
            // A plain notification gives way at once; codes wait their turn.
            present(e)
        } else if !queue.contains(e) {
            queue.append(e)
        }
    }

    private func present(_ e: NotchEvent) {
        let panel = ensurePanel()
        position(panel)
        copied = false
        event = e
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { self.expanded = true }
        }
        scheduleHide(after: e.duration)
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.collapse(force: false) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func collapse(force: Bool) {
        if hovering && !force {
            scheduleHide(after: 1.5)
            return
        }
        hideWork?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { expanded = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.expanded else { return }
            self.event = nil
            self.hovering = false
            self.panel?.orderOut(nil)
            if !self.queue.isEmpty { self.present(self.queue.removeFirst()) }
        }
    }

    func copy(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        scheduleHide(after: 1.2)
    }

    /// Clicking the notch copies the code, or opens the notification's app.
    func activate() {
        guard let event else { return }
        switch event {
        case .code(let code, _, _): copy(code)
        case .notification:
            onOpen?(event)
            collapse(force: true)
        }
    }

    // MARK: Window

    private func ensurePanel() -> NotchPanel {
        if let panel { return panel }
        let p = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isMovable = false
        p.hidesOnDeactivate = false
        let host = NSHostingView(rootView: NotchView(controller: self))
        host.sizingOptions = []
        p.contentView = host
        panel = p
        return p
    }

    private func position(_ panel: NSPanel) {
        // The display you're using: the one with the pointer.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0 {
            let left = screen.auxiliaryTopLeftArea?.width ?? 0
            let right = screen.auxiliaryTopRightArea?.width ?? 0
            let w = max(120, frame.width - left - right)
            notchSize = CGSize(width: w, height: screen.safeAreaInsets.top)
        } else {
            notchSize = CGSize(width: 160, height: max(24, NSStatusBar.system.thickness))
        }
        let size = CGSize(width: Self.expandedWidth + 40, height: notchSize.height + Self.contentHeight + 20)
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height),
                       display: true)
    }
}

/// Black shape with square top corners (to meet the bezel) and rounded bottom corners.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let br = min(bottomRadius, r.height / 2, r.width / 2)
        let flare: CGFloat = min(8, r.width / 10)
        p.move(to: CGPoint(x: r.minX - flare, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + flare), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - br))
        p.addQuadCurve(to: CGPoint(x: r.minX + br, y: r.maxY), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - br, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - br), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + flare))
        p.addQuadCurve(to: CGPoint(x: r.maxX + flare, y: r.minY), control: CGPoint(x: r.maxX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchView: View {
    @ObservedObject var controller: NotchController

    var body: some View {
        let n = controller.notchSize
        let open = controller.expanded
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(bottomRadius: open ? 24 : 10)
                    .fill(Color.black)
                    .frame(width: open ? NotchController.expandedWidth : n.width,
                           height: open ? n.height + NotchController.contentHeight : n.height)
                if open, let e = controller.event {
                    content(e)
                        .frame(width: NotchController.expandedWidth - 36, height: NotchController.contentHeight - 8)
                        .padding(.top, n.height + 2)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                }
            }
            .contentShape(Rectangle())
            .onHover { controller.hovering = $0 }
            .onTapGesture { controller.activate() }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func content(_ e: NotchEvent) -> some View {
        switch e {
        case .code(let code, let sender, let icon):
            row(icon: icon, tint: .green, title: code, subtitle: "From \(sender)", mono: true) {
                Button(controller.copied ? "Copied" : "Copy") { controller.copy(code) }
                    .buttonStyle(NotchButtonStyle())
            }
        case .notification(let app, let title, let body, let appURL):
            HStack(spacing: 12) {
                if let appURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                        .resizable()
                        .frame(width: 34, height: 34)
                } else {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(Color.blue.opacity(0.85), in: Circle())
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title.isEmpty ? app : title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if !title.isEmpty, title != app {
                            Text(app).font(.system(size: 11)).opacity(0.5).lineLimit(1)
                        }
                    }
                    if !body.isEmpty {
                        Text(body).font(.system(size: 12)).opacity(0.75).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func row<Trailing: View>(icon: String, tint: Color, title: String, subtitle: String, mono: Bool = false,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.85), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(mono ? .system(size: 18, weight: .bold, design: .monospaced) : .system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle).font(.system(size: 12)).opacity(0.7).lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

struct NotchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.white.opacity(configuration.isPressed ? 0.35 : 0.2), in: Capsule())
            .foregroundStyle(.white)
    }
}
