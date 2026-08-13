import Cocoa
import ApplicationServices
import ServiceManagement

// MARK: - Config

private let defaultsKey = "enabledBundleIDs"
private let observationsKey = "windowlessSeconds"
private let pollInterval: TimeInterval = 0.5
/// How often every running app (not only the ticked ones) is checked for
/// windows. This is what builds the recommendation, so it can be slow.
private let surveyInterval: TimeInterval = 5
/// An app that has spent this long alive with no window open is an app macOS
/// does not quit on its own, which is exactly what this tool is for.
private let windowlessSecondsToRecommend: Double = 15
/// Number of consecutive zero-window polls before quitting. 2 x 0.5s keeps it
/// feeling instant while surviving the brief window-less moment some apps have
/// while swapping one window for another (e.g. Xcode, Safari tab-to-window).
private let zeroPollsBeforeQuit = 2
/// Never quit an app within this many seconds of launch.
private let launchGrace: TimeInterval = 3

private let neverQuit: Set<String> = [
    "com.apple.finder",
    "com.apple.dock",
    "com.apple.systemuiserver",
    "com.apple.controlcenter",
    "com.apple.notificationcenterui",
    "com.apple.loginwindow",
    Bundle.main.bundleIdentifier ?? "",
]

// MARK: - Advice

/// What the menu suggests for an app.
enum Advice {
    /// Observed staying alive with no windows, so quitting it on close is the
    /// behaviour this tool exists to add.
    case recommended
    /// Keeps doing real work with no window open. Quitting it would stop that.
    case keepsWorking(String)
    /// Not enough evidence yet, or the app already quits itself on last close.
    case unknown

    var note: String {
        switch self {
        case .recommended: return "recommended"
        case .keepsWorking(let why): return why
        case .unknown: return ""
        }
    }
}

/// Apps whose whole point is to keep running without a window. Quitting these
/// on close stops music, downloads, calls, sync or notifications, so they are
/// never recommended even when they sit windowless for hours.
private let keepsWorking: [String: String] = [
    "com.spotify.client": "keeps playing",
    "com.apple.Music": "keeps playing",
    "com.apple.podcasts": "keeps playing",
    "com.apple.TV": "keeps playing",
    "org.videolan.vlc": "keeps playing",
    "com.colliderli.iina": "keeps playing",
    "com.apple.QuickTimePlayerX": "may be recording",
    "com.obsproject.obs-studio": "may be recording",
    "com.loom.desktop": "may be recording",
    "com.hnc.Discord": "calls and alerts",
    "com.tinyspeck.slackmacgap": "calls and alerts",
    "us.zoom.xos": "calls and alerts",
    "com.microsoft.teams2": "calls and alerts",
    "ru.keepcoder.Telegram": "alerts",
    "org.whispersystems.signal-desktop": "alerts",
    "com.facebook.archon": "alerts",
    "com.apple.MobileSMS": "alerts",
    "com.apple.mail": "fetches mail",
    "com.readdle.smartemail-Mac": "fetches mail",
    "com.apple.iCal": "alerts",
    "com.apple.reminders": "alerts",
    "com.flexibits.fantastical2.mac": "alerts",
    "com.valvesoftware.steam": "downloads",
    "com.epicgames.launcher": "downloads",
    "org.qbittorrent.qBittorrent": "downloads",
    "com.transmissionbt.transmission": "downloads",
    "com.apple.Photos": "syncs library",
    "com.apple.iTunes": "keeps playing",
]

/// Same idea, matched on a prefix because these ship under several bundle IDs.
private let keepsWorkingPrefixes: [(String, String)] = [
    ("com.docker", "runs containers"),
    ("com.getdropbox", "syncs files"),
    ("com.google.GoogleDrive", "syncs files"),
    ("com.microsoft.OneDrive", "syncs files"),
    ("com.backblaze", "backs up"),
    ("com.code42", "backs up"),
    ("com.1password", "serves the browser extension"),
    ("com.agilebits", "serves the browser extension"),
    ("com.wireguard", "holds the VPN up"),
    ("net.tunnelblick", "holds the VPN up"),
    ("com.nordvpn", "holds the VPN up"),
    ("com.expressvpn", "holds the VPN up"),
    ("com.tailscale", "holds the VPN up"),
    ("com.parallels", "runs virtual machines"),
    ("com.vmware", "runs virtual machines"),
    ("org.virtualbox", "runs virtual machines"),
]

func keepsWorkingReason(_ bundleID: String) -> String? {
    if let reason = keepsWorking[bundleID] { return reason }
    return keepsWorkingPrefixes.first { bundleID.hasPrefix($0.0) }?.1
}

func advice(for bundleID: String) -> Advice {
    if let reason = keepsWorkingReason(bundleID) { return .keepsWorking(reason) }
    if Store.shared.windowlessSeconds(bundleID) >= windowlessSecondsToRecommend { return .recommended }
    return .unknown
}

// MARK: - Store

final class Store {
    static let shared = Store()
    private(set) var enabled: Set<String>
    /// bundle ID -> seconds observed alive with zero windows. Persisted so the
    /// recommendation is already there the first time the menu is opened after
    /// a reboot, instead of needing a fresh 15 seconds of evidence.
    private var windowless: [String: Double]

    private init() {
        enabled = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
        windowless = (UserDefaults.standard.dictionary(forKey: observationsKey) as? [String: Double]) ?? [:]
    }

    func isEnabled(_ bundleID: String) -> Bool { enabled.contains(bundleID) }

    func windowlessSeconds(_ bundleID: String) -> Double { windowless[bundleID] ?? 0 }

    /// Capped: past the recommendation threshold the exact total is of no use,
    /// and an unbounded number would grow in UserDefaults forever.
    func noteWindowless(_ bundleID: String, seconds: Double) {
        let total = min((windowless[bundleID] ?? 0) + seconds, windowlessSecondsToRecommend * 2)
        guard total != windowless[bundleID] else { return }
        windowless[bundleID] = total
        UserDefaults.standard.set(windowless, forKey: observationsKey)
    }

    /// Drops what was observed about one app. Used when an app is uninstalled
    /// and by the tests, so a test run leaves nothing behind in the defaults.
    func forgetWindowless(_ bundleID: String) {
        guard windowless.removeValue(forKey: bundleID) != nil else { return }
        UserDefaults.standard.set(windowless, forKey: observationsKey)
    }

    func setEnabled(_ bundleID: String, _ on: Bool) {
        if on { enabled.insert(bundleID) } else { enabled.remove(bundleID) }
        UserDefaults.standard.set(Array(enabled).sorted(), forKey: defaultsKey)
    }

    /// Enable without touching UserDefaults. Used by `--selftest` so a test run
    /// never changes the user's saved list.
    func enableEphemeral(_ bundleID: String) { enabled.insert(bundleID) }

}

// MARK: - Debug

/// Set QOC_DEBUG=1 to trace every polling decision. Off by default: the poll
/// runs twice a second against every ticked app.
let debugEnabled = ProcessInfo.processInfo.environment["QOC_DEBUG"] == "1"

func debugLog(_ message: String) {
    guard debugEnabled else { return }
    FileHandle.standardError.write(Data("[qoc] \(message)\n".utf8))
}

// MARK: - Monitor

/// Polls the Accessibility window list of every enabled app and terminates an
/// app the moment its last real window goes away.
///
/// The Accessibility API is used rather than CGWindowList because minimized
/// windows and windows on other Spaces stay in `kAXWindowsAttribute`, so
/// minimizing or switching Space never looks like "no windows left".
final class Monitor {
    private var timer: Timer?
    private var surveyTimer: Timer?
    private var hadWindows = Set<pid_t>()
    private var zeroPolls = [pid_t: Int]()
    private var firstSeen = [pid_t: Date]()

    func start() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        t.tolerance = pollInterval / 3
        timer = t

        surveyTimer?.invalidate()
        let s = Timer.scheduledTimer(withTimeInterval: surveyInterval, repeats: true) { [weak self] _ in
            self?.survey()
        }
        s.tolerance = surveyInterval / 2
        surveyTimer = s
    }

    /// Watches every app, not only the ticked ones, purely to learn which apps
    /// macOS leaves running with no window. An app that quits itself on last
    /// close never accumulates time here, so it is never recommended.
    private func survey() {
        guard AXIsProcessTrusted() else { return }

        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  !neverQuit.contains(bundleID),
                  app.activationPolicy == .regular,
                  !app.isTerminated,
                  Date().timeIntervalSince(app.launchDate ?? Date()) > launchGrace,
                  let count = windowCount(app.processIdentifier)
            else { continue }

            if count == 0 { Store.shared.noteWindowless(bundleID, seconds: surveyInterval) }
        }
    }

    private func tick() {
        guard AXIsProcessTrusted() else { return }

        var live = Set<pid_t>()
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  !neverQuit.contains(bundleID),
                  Store.shared.isEnabled(bundleID),
                  app.activationPolicy == .regular,
                  !app.isTerminated
            else { continue }

            let pid = app.processIdentifier
            live.insert(pid)
            if firstSeen[pid] == nil { firstSeen[pid] = app.launchDate ?? Date() }

            // A nil count means the app did not answer in time. Treat that as
            // "unknown", never as "no windows".
            guard let count = windowCount(pid) else {
                debugLog("\(bundleID): no answer from the Accessibility query, poll ignored")
                continue
            }
            debugLog("\(bundleID): windows=\(count) seenWindow=\(hadWindows.contains(pid))")

            if count > 0 {
                hadWindows.insert(pid)
                zeroPolls[pid] = 0
                continue
            }

            // Only quit apps that have actually shown a window under our watch,
            // so a freshly launched or background-only app is left alone.
            guard hadWindows.contains(pid) else { continue }
            guard Date().timeIntervalSince(firstSeen[pid] ?? .distantPast) > launchGrace else { continue }

            let streak = (zeroPolls[pid] ?? 0) + 1
            zeroPolls[pid] = streak
            debugLog("\(bundleID): zero-window poll \(streak)/\(zeroPollsBeforeQuit)")
            if streak >= zeroPollsBeforeQuit {
                zeroPolls[pid] = 0
                hadWindows.remove(pid)
                app.terminate()  // graceful: an app with unsaved work still gets to ask
            }
        }

        hadWindows.formIntersection(live)
        zeroPolls = zeroPolls.filter { live.contains($0.key) }
        firstSeen = firstSeen.filter { live.contains($0.key) }
    }

    func windowCount(_ pid: pid_t) -> Int? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.3)

        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        guard err == .success, let windows = value as? [AXUIElement] else { return nil }

        return windows.filter { window in
            var roleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleRef) == .success,
                  let role = roleRef as? String
            else { return false }
            return role == (kAXWindowRole as String)
        }.count
    }
}

// MARK: - Menu row

/// One app row, drawn by hand.
///
/// A plain NSMenuItem closes the menu the instant it is clicked, which makes
/// ticking several apps painfully slow. A menu item that carries a custom view
/// gets the mouse events itself and the menu only closes when something calls
/// `cancelTracking`, so this row can be clicked over and over with the menu
/// staying open. The cost is that highlight and hit-testing are ours to draw.
final class AppRowView: NSView {
    private let bundleID: String
    private let title: String
    private let icon: NSImage?
    private let note: String
    private let recommended: Bool
    private var on: Bool
    private var hovered = false

    static let rowHeight: CGFloat = 24
    static let rowWidth: CGFloat = 330

    init(bundleID: String, title: String, icon: NSImage?, note: String, recommended: Bool) {
        self.bundleID = bundleID
        self.title = title
        self.icon = icon
        self.note = note
        self.recommended = recommended
        self.on = Store.shared.isEnabled(bundleID)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: Self.rowHeight))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func mouseUp(with event: NSEvent) { toggle() }

    private func toggle() {
        on.toggle()
        Store.shared.setEnabled(bundleID, on)
        needsDisplay = true
    }

    // A menu item that carries a custom view is invisible to VoiceOver unless
    // the view describes itself, so it is spelled out here as a checkbox.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityLabel() -> String? { note.isEmpty ? title : "\(title), \(note)" }
    override func accessibilityValue() -> Any? { on ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool { toggle(); return true }

    override func draw(_ dirtyRect: NSRect) {
        let fg: NSColor = hovered ? .white : .labelColor
        let dim: NSColor = hovered ? NSColor.white.withAlphaComponent(0.75) : .secondaryLabelColor

        if hovered {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }

        let font = NSFont.menuFont(ofSize: 13)
        let small = NSFont.menuFont(ofSize: 10)

        if on {
            ("✓" as NSString).draw(at: NSPoint(x: 13, y: 4), withAttributes: [.font: font, .foregroundColor: fg])
        }

        icon?.draw(in: NSRect(x: 30, y: 4, width: 16, height: 16),
                   from: .zero, operation: .sourceOver, fraction: 1)

        // The note is right-aligned, so the title gets whatever is left.
        var noteWidth: CGFloat = 0
        if !note.isEmpty {
            let colour = recommended
                ? (hovered ? NSColor.white : NSColor.systemGreen)
                : dim
            let attrs: [NSAttributedString.Key: Any] = [.font: small, .foregroundColor: colour]
            noteWidth = (note as NSString).size(withAttributes: attrs).width
            (note as NSString).draw(at: NSPoint(x: bounds.width - noteWidth - 14, y: 6), withAttributes: attrs)
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let titleX: CGFloat = 52
        let titleRect = NSRect(x: titleX, y: 4,
                               width: max(20, bounds.width - titleX - noteWidth - 22),
                               height: 16)
        (title as NSString).draw(in: titleRect, withAttributes: [
            .font: font, .foregroundColor: fg, .paragraphStyle: paragraph,
        ])
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?
    private var lastTrusted: Bool?
    private let monitor = Monitor()
    /// Recommended apps not yet ticked, filled while the menu is built so the
    /// "tick all recommended" item knows what it would turn on.
    private var offToRecommend: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        requestAccessibilityIfNeeded()
        refreshPermissionState()
        // The grant can appear (the user ticks the switch) or vanish (a rebuild
        // changes the code signature and TCC stops matching) at any moment, and
        // there is no notification for either, so the state is polled.
        let t = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshPermissionState()
        }
        t.tolerance = 1
        permissionTimer = t

        monitor.start()
    }

    /// Keeps the menu bar honest: without Accessibility the app quits nothing at
    /// all, and the only previous sign of that was a line inside the menu, which
    /// is invisible until you open it.
    private func refreshPermissionState() {
        let trusted = AXIsProcessTrusted()
        guard trusted != lastTrusted else { return }
        lastTrusted = trusted
        statusItem.button?.image = makeMenuBarImage(warning: !trusted)
        statusItem.button?.appearsDisabled = !trusted
        statusItem.button?.toolTip = trusted
            ? "QuitOnClose"
            : "QuitOnClose is not authorised: no Accessibility permission, so nothing will be quit."
    }

    private func requestAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !AXIsProcessTrusted() {
            let warn = NSMenuItem(title: "Not authorised: nothing is being quit", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            // After a rebuild the switch often still looks ticked while the
            // grant is dead, because TCC matches the old code signature. Ticking
            // it off and on again does not fix that; the entry has to be removed.
            menu.addItem(caption("If QuitOnClose already looks ticked there, remove it with the minus button, then add it again."))
            menu.addItem(.separator())
        }

        menu.addItem(caption("Tick every app that should quit when its last window closes."))
        menu.addItem(caption("The menu stays open, so tick as many as you like."))

        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { app in
                guard let id = app.bundleIdentifier else { return false }
                return !neverQuit.contains(id)
            }
            .sorted { ($0.localizedName ?? "") .localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }

        var listed = Set<String>()
        var recommended: [(String, String, NSImage?)] = []
        var others: [(String, String, NSImage?, String)] = []

        for app in running {
            guard let id = app.bundleIdentifier, listed.insert(id).inserted else { continue }
            let name = app.localizedName ?? id
            switch advice(for: id) {
            case .recommended: recommended.append((id, name, app.icon))
            case .keepsWorking(let why): others.append((id, name, app.icon, why))
            case .unknown: others.append((id, name, app.icon, ""))
            }
        }

        offToRecommend = recommended.map(\.0).filter { !Store.shared.isEnabled($0) }

        if !recommended.isEmpty {
            menu.addItem(.separator())
            menu.addItem(header("Recommended: these stay running with no window"))
            for (id, name, icon) in recommended {
                menu.addItem(row(bundleID: id, title: name, icon: icon, note: "recommended", recommended: true))
            }
        }

        if !others.isEmpty {
            menu.addItem(.separator())
            menu.addItem(header(recommended.isEmpty ? "Running apps" : "Other running apps"))
            for (id, name, icon, why) in others {
                menu.addItem(row(bundleID: id, title: name, icon: icon, note: why, recommended: false))
            }
        }

        // Enabled apps that are not running right now, so they can still be turned off.
        let offline = Store.shared.enabled.subtracting(listed).sorted()
        if !offline.isEmpty {
            menu.addItem(.separator())
            menu.addItem(header("Ticked but not running"))
            for id in offline {
                let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                let name = url.flatMap { FileManager.default.displayName(atPath: $0.path) } ?? id
                let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
                menu.addItem(row(bundleID: id, title: name, icon: icon, note: "", recommended: false))
            }
        }

        menu.addItem(.separator())

        if !offToRecommend.isEmpty {
            let all = NSMenuItem(title: "Tick all \(offToRecommend.count) recommended",
                                 action: #selector(enableAllRecommended), keyEquivalent: "")
            all.target = self
            menu.addItem(all)
        }
        if !Store.shared.enabled.isEmpty {
            let none = NSMenuItem(title: "Untick everything", action: #selector(disableEverything), keyEquivalent: "")
            none.target = self
            menu.addItem(none)
        }

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        let quit = NSMenuItem(title: "Quit QuitOnClose", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func row(bundleID: String, title: String, icon: NSImage?, note: String, recommended: Bool) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = AppRowView(bundleID: bundleID, title: title, icon: icon,
                               note: note, recommended: recommended)
        return item
    }

    private func header(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return item
    }

    private func caption(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        return item
    }

    @objc private func enableAllRecommended() {
        offToRecommend.forEach { Store.shared.setEnabled($0, true) }
    }

    @objc private func disableEverything() {
        let current = Store.shared.enabled
        current.forEach { Store.shared.setEnabled($0, false) }
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
    }

    @objc private func openAccessibilitySettings() {
        requestAccessibilityIfNeeded()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Permission check

private let permCheckURL = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Logs/QuitOnClose-permcheck.log")

enum GUIPermissionState {
    case trusted
    case untrusted
    case unknown(String)
}

/// Answers "is the app the user actually launches authorised?".
///
/// TCC judges the *responsible* process, so a copy of this binary started from a
/// shell is judged as the terminal. The only honest answer comes from a copy
/// launched through Launch Services, which is what `--permcheck` is for: it
/// writes its verdict to a file, because a `open -a` launch has no stdout.
func runPermCheck() -> Never {
    let trusted = AXIsProcessTrusted()
    try? "\(trusted)\n".write(to: permCheckURL, atomically: true, encoding: .utf8)
    print("AXIsProcessTrusted=\(trusted)")
    exit(trusted ? 0 : 1)
}

func guiPermissionState() -> GUIPermissionState {
    try? FileManager.default.removeItem(at: permCheckURL)

    let bundlePath = Bundle.main.bundlePath
    guard bundlePath.hasSuffix(".app") else { return .unknown("not running from an app bundle") }

    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-n", "-g", "-a", bundlePath, "--args", "--permcheck"]
    do { try open.run() } catch { return .unknown("could not launch a copy: \(error.localizedDescription)") }
    open.waitUntilExit()

    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if let text = try? String(contentsOf: permCheckURL, encoding: .utf8) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines) == "true" ? .trusted : .untrusted
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return .unknown("the app-side check did not answer within 10s")
}

// MARK: - Self test

/// End-to-end proof that the real Monitor quits a real app when its last window
/// closes: open TextEdit on a scratch file, press that window's close button
/// through the Accessibility API, then wait for TextEdit to die.
///
/// Run:  /Applications/QuitOnClose.app/Contents/MacOS/QuitOnClose --selftest
func runSelfTest() -> Never {
    // Mirror everything to a log file: when the test is started with `open -a`
    // so that launchd owns the process (the only way TCC judges QuitOnClose
    // itself rather than the shell that spawned it), stdout goes nowhere.
    let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/QuitOnClose-selftest.log")

    func say(_ message: String) {
        print(message)
        let line = message + "\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    func fail(_ message: String) -> Never {
        say("FAIL: \(message)")
        exit(1)
    }

    try? FileManager.default.removeItem(at: logURL)
    say("--- selftest start, AXIsProcessTrusted=\(AXIsProcessTrusted())")

    // A run started from a shell is attributed by TCC to the terminal, so it
    // borrows the terminal's Accessibility grant and reports trusted even when
    // the menu bar app has none. That made this test pass while the real app
    // quit nothing for days (2026-08-14, Acrobat). Ask the app itself, launched
    // the way the user launches it, and believe that answer instead.
    // Asked unconditionally: a tty check cannot tell a shell run from a piped
    // one, and the answer that matters is always the app's own.
    do {
        say("checking the app's own Accessibility grant, not this process's ...")
        switch guiPermissionState() {
        case .trusted:
            say("app-side Accessibility: granted")
        case .untrusted:
            fail("the app itself has no Accessibility permission, so it quits nothing, even though this terminal run reports trusted. Open System Settings > Privacy & Security > Accessibility; if QuitOnClose is listed, remove it with the minus button and add it again, because a rebuild leaves a stale entry that still looks ticked.")
        case .unknown(let why):
            say("warning: could not ask the app itself (\(why)); this run only proves the logic, not the permission.")
        }
    }

    guard AXIsProcessTrusted() else {
        fail("no Accessibility permission. Enable QuitOnClose in System Settings > Privacy & Security > Accessibility, then rerun.")
    }

    let target = "com.apple.TextEdit"
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("quitonclose-selftest.txt")
    try? "QuitOnClose self test\n".write(to: scratch, atomically: true, encoding: .utf8)

    let monitor = Monitor()
    Store.shared.enableEphemeral(target)
    monitor.start()

    func textEdit() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == target && !$0.isTerminated }
    }

    /// Spin the run loop (so the Monitor's timer fires) until `check` is true.
    func wait(seconds: TimeInterval, for check: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if check() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return check()
    }

    textEdit()?.terminate()
    _ = wait(seconds: 5) { textEdit() == nil }

    say("1. opening TextEdit ...")
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) else {
        fail("TextEdit not found on this Mac")
    }
    NSWorkspace.shared.open([scratch], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())

    guard wait(seconds: 20, for: { (textEdit()?.processIdentifier).flatMap { (monitor.windowCount($0) ?? 0) > 0 } ?? false }) else {
        fail("TextEdit never showed a window the Accessibility API could see")
    }
    guard let app = textEdit() else { fail("TextEdit vanished") }
    say("   TextEdit pid \(app.processIdentifier), windows=\(monitor.windowCount(app.processIdentifier) ?? -1)")

    // Let the Monitor's launch grace period elapse, then close the window.
    _ = wait(seconds: launchGrace + 1) { false }

    say("2. closing its last window ...")
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let windows = windowsRef as? [AXUIElement], let window = windows.first
    else { fail("could not read TextEdit's windows") }

    var closeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeRef) == .success,
          let closeButton = closeRef, CFGetTypeID(closeButton) == AXUIElementGetTypeID()
    else { fail("window has no close button") }
    let pressed = AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
    guard pressed == .success else { fail("pressing the close button failed (\(pressed.rawValue))") }

    say("3. waiting for QuitOnClose to terminate it ...")
    let start = Date()
    guard wait(seconds: 10, for: { textEdit() == nil }) else {
        fail("TextEdit is still running 10s after its last window closed")
    }
    say(String(format: "PASS: TextEdit quit %.2fs after its last window closed", Date().timeIntervalSince(start)))
    try? FileManager.default.removeItem(at: scratch)
    exit(0)
}

// MARK: - Menu test

/// Proves the two menu promises without a human clicking anything:
///
/// 1. The advice engine sorts apps the way it claims to.
/// 2. Clicking a row toggles it and the menu stays open, which is the whole
///    point of drawing rows by hand instead of using plain NSMenuItems.
///
/// Run:  /Applications/QuitOnClose.app/Contents/MacOS/QuitOnClose --menutest
/// Needs no permissions: the click is an NSEvent posted into this process's own
/// queue, which the menu's tracking loop pulls from, not a system-wide CGEvent.
func runMenuTest() -> Never {
    var failures: [String] = []
    func check(_ condition: Bool, _ what: String) {
        print("\(condition ? "ok  " : "FAIL") \(what)")
        if !condition { failures.append(what) }
    }

    // --- advice engine -----------------------------------------------------
    let spotify = "com.spotify.client"
    if case .keepsWorking(let why) = advice(for: spotify) {
        check(why == "keeps playing", "Spotify is never recommended (\(why))")
    } else {
        check(false, "Spotify is never recommended")
    }
    if case .keepsWorking = advice(for: "com.docker.docker") {
        check(true, "prefix match catches Docker")
    } else {
        check(false, "prefix match catches Docker")
    }

    let fake = "com.quitonclose.test.fakeapp"
    Store.shared.forgetWindowless(fake)
    if case .unknown = advice(for: fake) {
        check(true, "an app with no evidence is not recommended")
    } else {
        check(false, "an app with no evidence is not recommended")
    }
    Store.shared.noteWindowless(fake, seconds: windowlessSecondsToRecommend + 1)
    if case .recommended = advice(for: fake) {
        check(true, "an app seen windowless past the threshold is recommended")
    } else {
        check(false, "an app seen windowless past the threshold is recommended")
    }
    for _ in 0..<50 { Store.shared.noteWindowless(fake, seconds: 60) }
    check(Store.shared.windowlessSeconds(fake) <= windowlessSecondsToRecommend * 2,
          "the observation total is capped, so it cannot grow forever")
    // Evidence for a made-up app must not linger in the real defaults.
    Store.shared.forgetWindowless(fake)

    // --- the menu itself ---------------------------------------------------
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    let rowID = "com.quitonclose.test.menu"
    Store.shared.setEnabled(rowID, false)

    let menu = NSMenu()
    let row = AppRowView(bundleID: rowID, title: "Menu test row", icon: nil,
                         note: "recommended", recommended: true)
    let item = NSMenuItem()
    item.view = row
    menu.addItem(item)
    menu.addItem(NSMenuItem(title: "a plain item below it", action: nil, keyEquivalent: ""))

    var clicksLanded = 0
    var cancelledByTest = false
    var tickedAfterFirstClick = false

    // Two clicks, so a menu that closes on the first is caught for certain.
    for (index, delay) in [0.8, 1.4].enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let window = row.window else { return }
            if index == 1 { tickedAfterFirstClick = Store.shared.isEnabled(rowID) }
            let point = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)

            // Menu tracking hit-tests the real cursor, not the event location,
            // so a click posted where the pointer is not reads as a click
            // outside the menu and dismisses it. Put the pointer on the row.
            let onScreen = window.convertPoint(toScreen: point)
            if let main = NSScreen.screens.first {
                CGWarpMouseCursorPosition(CGPoint(x: onScreen.x, y: main.frame.height - onScreen.y))
                CGAssociateMouseAndMouseCursorPosition(1)
            }

            for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 90_000 + index, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0) else { continue }
                NSApp.postEvent(event, atStart: false)
            }
            clicksLanded += 1
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
        cancelledByTest = true
        menu.cancelTrackingWithoutAnimation()
    }

    let start = Date()
    menu.popUp(positioning: nil, at: NSPoint(x: 400, y: 400), in: nil)
    let openFor = Date().timeIntervalSince(start)

    check(clicksLanded == 2, "both clicks were delivered while the menu was open (\(clicksLanded)/2)")
    check(cancelledByTest && openFor > 2.0,
          String(format: "the menu stayed open through the clicks (open %.2fs, closed by the test: %@)",
                 openFor, cancelledByTest ? "yes" : "no"))
    check(tickedAfterFirstClick, "the first click ticked the row")
    check(!Store.shared.isEnabled(rowID), "the second click unticked it again")

    Store.shared.setEnabled(rowID, false)

    if failures.isEmpty {
        print("PASS: 4 menu checks and 5 advice checks")
        exit(0)
    }
    print("FAILED: \(failures.count) — \(failures.joined(separator: "; "))")
    exit(1)
}

if CommandLine.arguments.contains("--permcheck") {
    runPermCheck()
}

if CommandLine.arguments.contains("--menutest") {
    runMenuTest()
}

if CommandLine.arguments.contains("--selftest") {
    runSelfTest()
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
