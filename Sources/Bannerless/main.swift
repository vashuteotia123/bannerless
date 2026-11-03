// Bannerless: every notification on this Mac shown in the notch instead of as a
// banner, with a Copy button when it holds a sign-in code. Public domain. No servers, no accounts.
import CodeCore
import Foundation

// `open -a Bannerless --args --diagnose /path/report.txt` writes a structure-only
// report (no message or notification text) and quits. It's started through
// `open` so it runs with Bannerless's own Full Disk Access.
if let i = CommandLine.arguments.firstIndex(of: "--diagnose") {
    let path = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : NSTemporaryDirectory() + "bannerless-diagnostics.txt"
    try? CodeDiagnostics.report().write(toFile: path, atomically: true, encoding: .utf8)
    exit(0)
}
// `open -n -a Bannerless --args --diagnose-watch 120 /path/watch.txt` logs each new
// notification's outline (masked text) as it arrives, then quits.
if let i = CommandLine.arguments.firstIndex(of: "--diagnose-watch") {
    let args = CommandLine.arguments
    let seconds = i + 1 < args.count ? Double(args[i + 1]) ?? 120 : 120
    let path = i + 2 < args.count ? args[i + 2] : NSTemporaryDirectory() + "bannerless-watch.txt"
    FileManager.default.createFile(atPath: path, contents: nil)
    let handle = FileHandle(forWritingAtPath: path)
    CodeDiagnostics.watch(seconds: seconds) { line in handle?.write(Data((line + "\n").utf8)) }
    try? handle?.close()
    exit(0)
}

BannerlessApp.main()
