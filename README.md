# Bannerless

Every notification on your Mac, in the notch instead of a banner. Nobody owns it.

macOS banners slide in from the corner of whichever screen is the main display. Bannerless takes each one the
moment it's created, before it's drawn, and shows it in the notch of the display you're using instead. When a
notification holds a sign-in code, the notch shows the code with a **Copy** button. Your recent notifications
and codes sit in the menu bar.

- **Public domain** ([Unlicense](UNLICENSE)). Copy it, fork it, rename it. No permission needed.
- **No account, no server, no telemetry.** Everything happens on this Mac, and nothing is stored on disk.
- **Install and use.** Build it yourself with one command. No Apple Developer ID involved.

## Install

You need macOS 14 or later and Apple's free Command Line Tools (`xcode-select --install`).

```bash
git clone <this repo> bannerless && cd bannerless
make install          # builds, copies to /Applications, opens it
```

Bannerless lives in the menu bar (🔔), has no Dock icon, and opens at login.

## Set up

1. **Accessibility:** on first launch macOS asks; click **Open System Settings** and switch Bannerless on (or
   System Settings → Privacy & Security → Accessibility → add Bannerless). This is what lets it take banners and
   show them in the notch.
2. **Full Disk Access:** System Settings → Privacy & Security → Full Disk Access → add Bannerless. This lets it
   catch codes from texts and from notifications that never showed a banner (for example in a Focus).
3. **Codes from texts (optional):** on the iPhone, Settings → Apps → Messages → **Text Message Forwarding** →
   turn on this Mac, and open Messages on the Mac once.
4. **iPhone notifications (optional):** System Settings → Notifications → **iPhone notifications**, and on the
   iPhone, Settings → Notifications → an app → **Show on Mac**.

Builds are ad-hoc signed, so macOS treats each new build as a new app: after updating, remove Bannerless from
Accessibility and Full Disk Access with **–** and add it again with **+**.

## How it works

| Source | What it gives | Speed |
|---|---|---|
| **Notification banners** (Accessibility) | Every banner on the Mac: Mac apps, websites, iPhone notifications. Each one is moved off-screen and closed as it's created, then shown in the notch. | Instant |
| **Texts and iMessages** (Messages database, read-only) | Codes from SMS and iMessage. | About a second |
| **Mac notifications** (Notification Center database, read-only) | Codes from notifications that didn't show a banner. | About 5 seconds (macOS saves in batches) |
| **iPhone notifications** (mirrored-notification store, read-only) | Codes from iPhone notifications that didn't show a banner. | When macOS saves them |

A code that arrives by more than one route is shown once. Only items that arrive after Bannerless starts are
checked, and anything older than five minutes is ignored.

The code finder handles common formats: "482913 is your code", "Your OTP is 4821", `G-552891`, `123-456`,
Android's `<#>` prefix, and bank texts with amounts (Rs, INR, ₹) or masked card numbers next to the code.

### Trade-offs

- A banner Bannerless takes over isn't kept in Notification Center's list; macOS drops a banner closed this way.
  The menu's **Recent Notifications** keeps your last ten, in memory only.
- The banner's own buttons (Reply, Snooze, …) aren't available. Click the notch card to open the app.
- A notification's sound still plays: macOS plays it before any app can act.
- On a macOS language other than English, banners are still hidden and shown in the notch, but can't be closed
  (the close action is found by its English name). They time out off-screen and stay in Notification Center.
- Built and tested on macOS 26. macOS doesn't document Notification Center's layout, so a future update could
  change it; the diagnostics below help find out what changed.
- Turn off **Show All Notifications in the Notch** to get macOS banners back; codes still appear in the notch.

## Diagnostics

If something doesn't show up, Bannerless can write a structure-only report (table names, which app posted recent
notifications, field sizes, and masked outlines with digits as `9` and words as `x`, never the actual text):

```bash
open -n -a Bannerless --args --diagnose ~/Desktop/bannerless-report.txt
open -n -a Bannerless --args --diagnose-watch 120 ~/Desktop/bannerless-watch.txt   # live, for 2 minutes
```

## Develop

```bash
make test     # code detection, Messages, Notification Center and iPhone-store readers
make run      # build the .app and open it
```

```
Sources/CodeCore/     finding codes; reading Messages, Notification Center and the iPhone store
Sources/NotchUI/      the notch panel
Sources/Bannerless/   the menu bar app and the banner watcher
scripts/              build-app.sh (ad-hoc signed .app), install.sh
```
