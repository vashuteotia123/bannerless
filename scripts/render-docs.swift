// Draws the README images (docs/images/*.png): illustrations of Bannerless
// built from the same shapes, sizes and styles as the app's notch.
// All names, apps and codes in them are made up.
//
// Usage: swift scripts/render-docs.swift docs/images
import AppKit
import ImageIO
import SwiftUI

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/images"

// MARK: - Pieces shared with the app (NotchUI)

struct NotchShape: Shape {
    var bottomRadius: CGFloat
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

struct Pill: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(.white.opacity(0.2), in: Capsule())
            .foregroundStyle(.white)
    }
}

/// A made-up app icon: a symbol on a rounded square.
struct AppIcon: View {
    var symbol: String
    var colors: [Color]
    var size: CGFloat = 34
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white))
    }
}

enum Card {
    case notification(icon: AppIcon, app: String, title: String, body: String)
    case code(String, from: String, copied: Bool)
}

struct CardContent: View {
    var card: Card
    var body: some View {
        switch card {
        case .notification(let icon, let app, let title, let body):
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(app).font(.system(size: 11)).opacity(0.5).lineLimit(1)
                    }
                    Text(body).font(.system(size: 12)).opacity(0.75).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
        case .code(let code, let from, let copied):
            HStack(spacing: 12) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(Color.green.opacity(0.85), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(code).font(.system(size: 18, weight: .bold, design: .monospaced))
                    Text("From \(from)").font(.system(size: 12)).opacity(0.7)
                }
                Spacer(minLength: 8)
                Pill(text: copied ? "Copied" : "Copy")
            }
        }
    }
}

/// The notch, open, with a card in it.
struct OpenNotch: View {
    var card: Card
    var notchHeight: CGFloat = 32
    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(bottomRadius: 24).fill(Color.black)
                .frame(width: 400, height: notchHeight + 66)
            CardContent(card: card)
                .frame(width: 364, height: 58)
                .padding(.top, notchHeight + 2)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

// MARK: - The desktop around it (illustrative)

struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.13, green: 0.16, blue: 0.38), Color(red: 0.42, green: 0.25, blue: 0.55),
                                    Color(red: 0.93, green: 0.55, blue: 0.42)], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.18), .clear], center: .init(x: 0.75, y: 0.9), startRadius: 10, endRadius: 420)
        }
    }
}

struct MenuBar: View {
    var height: CGFloat = 32
    var compact = false
    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "apple.logo")
            Text("Finder").fontWeight(.bold)
            if !compact { Text("File"); Text("Edit"); Text("View") }
            Spacer()
            Image(systemName: "bell.badge.fill")
            if !compact { Image(systemName: "wifi"); Image(systemName: "battery.75percent") }
            Text("9:41")
        }
        .font(.system(size: 13))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: height)
        .background(Color.black.opacity(0.22))
    }
}

/// A screen: wallpaper, menu bar, and the notch (closed or open).
struct Screen: View {
    var width: CGFloat = 960
    var height: CGFloat = 200
    var notch = true
    var card: Card?
    var body: some View {
        ZStack(alignment: .top) {
            Wallpaper()
            MenuBar(height: notch ? 32 : 26, compact: width < 600)
            if let card {
                OpenNotch(card: card, notchHeight: notch ? 32 : 26)
            } else if notch {
                NotchShape(bottomRadius: 10).fill(Color.black).frame(width: 190, height: 32)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// An illustration of a standard macOS banner, for the "before" picture.
struct ClassicBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AppIcon(symbol: "bubble.left.fill", colors: [.teal, .blue], size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Maya Chen").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("now").font(.system(size: 11)).opacity(0.55)
                }
                Text("Running 5 minutes late, grab us a table?").font(.system(size: 12)).opacity(0.8)
            }
        }
        .foregroundStyle(.black)
        .padding(12)
        .frame(width: 330)
        .background(Color(white: 0.96).opacity(0.94), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }
}

struct Caption: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.black.opacity(0.45), in: Capsule())
    }
}

/// The menu bar menu, drawn as an illustration.
struct MenuIllustration: View {
    struct Row: Identifiable { let id = UUID(); var text: String; var check = false; var dim = false; var mono = false; var chevron = false; var header = false }
    let rows: [Row?] = [
        Row(text: "Showing notifications in the notch", dim: true),
        nil,
        Row(text: "Recent — click to copy", dim: true, header: true),
        Row(text: "482913   Acme Bank · 9:41 AM", mono: true),
        Row(text: "731 604   Example Store · 9:12 AM", mono: true),
        Row(text: "Recent Notifications", chevron: true),
        nil,
        Row(text: "Texts and iMessages", check: true),
        Row(text: "Notifications", check: true),
        Row(text: "Show All Notifications in the Notch", check: true),
        Row(text: "Copy Codes Automatically"),
        Row(text: "Pause"),
        nil,
        Row(text: "Setup and Permissions…"),
        Row(text: "Open at Login", check: true),
        Row(text: "Show a Test Code"),
        nil,
        Row(text: "Quit Bannerless"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                if let row {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).opacity(row.check ? 1 : 0).frame(width: 14)
                        Text(row.text)
                            .font(row.header ? .system(size: 11, weight: .semibold) : .system(size: 13))
                            .opacity(row.dim ? 0.5 : 1)
                        Spacer()
                        if row.chevron { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).opacity(0.6) }
                    }
                    .padding(.horizontal, 8).frame(height: 24)
                } else {
                    Rectangle().fill(.white.opacity(0.12)).frame(height: 1).padding(.vertical, 5).padding(.horizontal, 8)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(6)
        .frame(width: 320)
        .background(Color(white: 0.16).opacity(0.97), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }
}

// MARK: - Scenes

let chat = AppIcon(symbol: "bubble.left.fill", colors: [.teal, .blue])
let calendar = AppIcon(symbol: "calendar", colors: [.orange, .red])

@MainActor
func scenes() -> [(String, AnyView)] {
    [
        ("logo", AnyView(
            AppIcon(symbol: "bell.badge.fill", colors: [Color(red: 0.49, green: 0.42, blue: 1), Color(red: 0.29, green: 0.18, blue: 0.79)], size: 120)
                .padding(4)
        )),
        ("notification", AnyView(
            Screen(card: .notification(icon: chat, app: "Chat", title: "Maya Chen", body: "Running 5 minutes late, grab us a table?"))
        )),
        ("notification-long", AnyView(
            Screen(card: .notification(icon: calendar, app: "Calendar", title: "Design review in 10 minutes",
                                       body: "Room 4B · with Sam, Priya and Alex. Bring the updated onboarding flow and the launch checklist."))
        )),
        ("code", AnyView(
            Screen(card: .code("482913", from: "Acme Bank", copied: false))
        )),
        ("code-copied", AnyView(
            Screen(card: .code("482913", from: "Acme Bank", copied: true))
        )),
        ("external-display", AnyView(
            Screen(notch: false, card: .notification(icon: chat, app: "Chat", title: "Maya Chen", body: "Running 5 minutes late, grab us a table?"))
        )),
        ("before-after", AnyView(
            HStack(spacing: 20) {
                ZStack(alignment: .topTrailing) {
                    Screen(width: 470, height: 230)
                    ClassicBanner().padding(.top, 42).padding(.trailing, 12)
                }
                .overlay(alignment: .bottomLeading) { Caption(text: "macOS banner").padding(14) }
                ZStack(alignment: .top) {
                    Screen(width: 470, height: 230, card: .notification(icon: chat, app: "Chat", title: "Maya Chen",
                                                                        body: "Running 5 minutes late, grab us a table?"))
                }
                .overlay(alignment: .bottomLeading) { Caption(text: "With Bannerless").padding(14) }
            }
        )),
        ("menu", AnyView(
            ZStack(alignment: .topTrailing) {
                Screen(width: 960, height: 520)
                MenuIllustration().padding(.top, 34).padding(.trailing, 150)
            }
        )),
    ]
}

// MARK: - Animation (docs/images/demo.gif)

/// One frame of the demo: the notch opening by `open` (0…1) with a card,
/// and an optional pointer.
struct DemoFrame: View {
    var open: CGFloat
    var card: Card?
    var pointer: CGPoint?
    var pressed = false
    var body: some View {
        let w = 190 + (400 - 190) * open
        let h = 32 + 66 * open
        ZStack(alignment: .top) {
            // Calmer than the stills' wallpaper: a GIF stores every frame whole.
            LinearGradient(colors: [Color(red: 0.16, green: 0.17, blue: 0.36), Color(red: 0.36, green: 0.24, blue: 0.5)],
                           startPoint: .leading, endPoint: .trailing)
            MenuBar(height: 32, compact: true)
            ZStack(alignment: .top) {
                NotchShape(bottomRadius: 10 + 14 * open).fill(Color.black).frame(width: w, height: h)
                if let card, open > 0.55 {
                    CardContent(card: card)
                        .frame(width: 364, height: 58)
                        .padding(.top, 34)
                        .opacity(Double((open - 0.55) / 0.45))
                        .foregroundStyle(.white)
                }
            }
            .shadow(color: .black.opacity(0.35 * open), radius: 18, y: 8)
            if let pointer {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 1.5)
                    .scaleEffect(pressed ? 0.85 : 1)
                    .position(pointer)
            }
        }
        .frame(width: 640, height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

@MainActor
func writeDemoGIF(to path: String) {
    let fps = 15.0
    func ease(_ t: Double) -> CGFloat { let t = min(max(t, 0), 1); return CGFloat(1 - pow(1 - t, 3)) }
    let message = Card.notification(icon: chat, app: "Chat", title: "Maya Chen", body: "Running 5 minutes late, grab us a table?")
    let rest = CGPoint(x: 590, y: 128), copyButton = CGPoint(x: 452, y: 72), away = CGPoint(x: 540, y: 120)
    var frames: [DemoFrame] = []
    func add(_ seconds: Double, _ make: (Double) -> DemoFrame) {
        let n = Int(seconds * fps)
        for i in 0..<n { frames.append(make(Double(i) / Double(max(n - 1, 1)))) }
    }
    add(0.6) { _ in DemoFrame(open: 0, card: nil, pointer: rest) }
    add(0.4) { t in DemoFrame(open: ease(t), card: message, pointer: rest) }
    add(2.2) { _ in DemoFrame(open: 1, card: message, pointer: rest) }
    add(0.35) { t in DemoFrame(open: 1 - ease(t), card: message, pointer: rest) }
    add(0.6) { _ in DemoFrame(open: 0, card: nil, pointer: rest) }
    let code = Card.code("482913", from: "Acme Bank", copied: false)
    add(0.4) { t in DemoFrame(open: ease(t), card: code, pointer: rest) }
    add(0.5) { _ in DemoFrame(open: 1, card: code, pointer: rest) }
    add(0.7) { t in
        let k = ease(t)
        return DemoFrame(open: 1, card: code, pointer: CGPoint(x: rest.x + (copyButton.x - rest.x) * k, y: rest.y + (copyButton.y - rest.y) * k))
    }
    add(0.15) { _ in DemoFrame(open: 1, card: code, pointer: copyButton, pressed: true) }
    let copied = Card.code("482913", from: "Acme Bank", copied: true)
    add(0.4) { t in
        let k = ease(t)
        return DemoFrame(open: 1, card: copied, pointer: CGPoint(x: copyButton.x + (away.x - copyButton.x) * k, y: copyButton.y + (away.y - copyButton.y) * k))
    }
    add(1.3) { _ in DemoFrame(open: 1, card: copied, pointer: away) }
    add(0.35) { t in DemoFrame(open: 1 - ease(t), card: copied, pointer: away) }
    add(0.8) { _ in DemoFrame(open: 0, card: nil, pointer: away) }

    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, "com.compuserve.gif" as CFString, frames.count, nil) else { return }
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps]] as CFDictionary
    for f in frames {
        let r = ImageRenderer(content: f.environment(\.colorScheme, .dark))
        r.scale = 1.5
        if let cg = r.cgImage { CGImageDestinationAddImage(dest, cg, frameProps) }
    }
    CGImageDestinationFinalize(dest)
    print("✓ \(path) (\(frames.count) frames)")
}

// MARK: - Output

@MainActor
func write(_ view: some View, to path: String, scale: CGFloat = 2) {
    let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
    renderer.scale = scale
    guard let cg = renderer.cgImage else { print("✗ \(path)"); return }
    let rep = NSBitmapImageRep(cgImage: cg)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("✓ \(path)")
}

MainActor.assumeIsolated {
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    for (name, view) in scenes() {
        write(view.padding(1), to: "\(outDir)/\(name).png")
    }
    writeDemoGIF(to: "\(outDir)/demo.gif")
}
