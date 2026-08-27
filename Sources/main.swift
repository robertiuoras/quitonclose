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
/// An app that is still burning this much CPU (itself plus its helper
/// processes) with no window open is still finishing something — a reply
/// streaming in, an upload, an export, a save. Quitting it there is the one
/// case where "quit on close" destroys work, so the quit waits until the app
/// goes quiet. Measured 2026-08-20: idle ChatGPT is 0.0% across its 19
/// processes, so a threshold this low still never fires on an idle app.
private let busyCPUPercent: Double = 8

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

// MARK: - GuardDeck Activity feed

/// Appends a confirmed quit to GuardDeck's events.jsonl so every resource action
/// on this Mac — guard kills and QuitOnClose quits alike — reads off one Activity
/// tab. Same contract as guard-gate.mjs logEvent(): history is a nicety, so any
/// failure (no GuardDeck, unwritable dir) is swallowed and the quit stands.
func guardDeckLog(title: String, detail: String) {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/guarddeck")
    let file = dir.appendingPathComponent("events.jsonl")
    let event: [String: Any] = [
        "ts": Int64(Date().timeIntervalSince1970 * 1000),
        "actor": "quitonclose",
        "decision": "auto",
        "title": title,
        "detail": detail,
    ]
    guard FileManager.default.fileExists(atPath: dir.path),
          let json = try? JSONSerialization.data(withJSONObject: event)
    else { return }
    var data = json
    data.append(0x0A)
    // O_APPEND, not seekToEnd()+write(): those are two syscalls, so a concurrent
    // writer (guard-gate.mjs appendFileSync, a second instance) could interleave
    // mid-line. A single O_APPEND write of one small line is atomic — the same
    // contract every guard already relies on for this file.
    let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { return }
    defer { close(fd) }
    _ = data.withUnsafeBytes { raw in write(fd, raw.baseAddress, raw.count) }
}

// MARK: - Window scan and the quit decision

/// One poll's view of an app's windows.
///
/// Dialogs are counted apart from real windows on purpose. An app that answers
/// a quit request with "are you sure?" (ChatGPT and Claude both do, and so does
/// any app with unsaved work) puts a dialog on screen while it has no real
/// window. Counting that dialog as a window made QuitOnClose treat the app as
/// re-opened, so the moment the human pressed "No" the window count fell back
/// to zero and the app was asked to quit again — the prompt reappeared forever.
struct WindowScan: Equatable {
    let real: Int
    let dialogs: Int
}

/// Subroles that mean "this window is asking the human something", not "the
/// human reopened the app".
private let dialogSubroles: Set<String> = [
    kAXDialogSubrole as String,
    kAXSystemDialogSubrole as String,
    kAXFloatingWindowSubrole as String,
]

/// What one poll decided about one enabled app.
enum QuitDecision: Equatable {
    /// Real window on screen: nothing to do, and the app is armed again.
    case hasWindows
    /// The app is asking the human something. Never quit over a dialog, and
    /// never let a dialog re-arm the quit.
    case dialogOpen
    /// Never showed a window under our watch, so it is background-only.
    case neverShowedWindow
    /// Still working with no window. Wait for it to go quiet.
    case busy(Double)
    /// Already asked once and it did not go. Asking again is the pop-up loop.
    case alreadyAsked
    /// Windowless, but not for long enough yet.
    case waitForStreak
    case quit
}

/// Pure so it can be tested without a running app. Order matters: a dialog
/// outranks everything, and "already asked" outranks the streak, so a refused
/// quit is never retried until a real window comes back.
func quitDecision(scan: WindowScan,
                  hadRealWindow: Bool,
                  askedAlready: Bool,
                  streak: Int,
                  cpuPercent: Double?) -> QuitDecision {
    if scan.real > 0 { return .hasWindows }
    if scan.dialogs > 0 { return .dialogOpen }
    if askedAlready { return .alreadyAsked }
    if !hadRealWindow { return .neverShowedWindow }
    if let cpu = cpuPercent, cpu > busyCPUPercent { return .busy(cpu) }
    if streak < zeroPollsBeforeQuit { return .waitForStreak }
    return .quit
}

/// Total CPU seconds one process has ever used, or nil if it cannot be read
/// (already gone, or another user's process).
func cpuSecondsUsed(_ pid: pid_t) -> Double? {
    var usage = rusage_info_current()
    let ok = withUnsafeMutablePointer(to: &usage) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
            proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
        }
    }
    guard ok == 0 else { return nil }
    return Double(usage.ri_user_time + usage.ri_system_time) / 1_000_000_000
}

/// Every process descended from `root`, `root` included.
///
/// Needed because the apps this matters for are Electron: ChatGPT's own
/// process sat at 0.3% while its renderer and `codex` helper children did the
/// work (measured 2026-08-20, 19 child processes under pid 33753). Reading only
/// the app's own pid would call a busy app idle and quit it mid-answer.
func processTree(_ root: pid_t, maxDepth: Int = 6) -> [pid_t] {
    var buffer = [pid_t](repeating: 0, count: 8192)
    // proc_listallpids returns the NUMBER OF PIDS, not the number of bytes,
    // unlike most of the proc_* family. Dividing by sizeof(pid_t) here silently
    // read only the first quarter of the process table and reported ChatGPT as
    // a single process with no helpers (measured 2026-08-20: 148 of 593).
    let count = proc_listallpids(&buffer, Int32(MemoryLayout<pid_t>.size * buffer.count))
    guard count > 0 else { return [root] }
    let all = buffer.prefix(min(Int(count), buffer.count)).filter { $0 > 0 }

    var children = [pid_t: [pid_t]]()
    for pid in all {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { continue }
        children[pid_t(info.pbsi_ppid), default: []].append(pid)
    }

    var tree = [root]
    var frontier = [root]
    var seen: Set<pid_t> = [root]
    for _ in 0..<maxDepth {
        let next = frontier.flatMap { children[$0] ?? [] }.filter { seen.insert($0).inserted }
        if next.isEmpty { break }
        tree += next
        frontier = next
    }
    return tree
}

/// CPU seconds used by an app and all of its helper processes.
func treeCPUSecondsUsed(_ root: pid_t) -> Double? {
    let seconds = processTree(root).compactMap(cpuSecondsUsed)
    guard !seconds.isEmpty else { return nil }
    return seconds.reduce(0, +)
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
    /// Apps already asked to quit once that are still here. Cleared only when a
    /// real window comes back, so a "No" on the app's own confirmation dialog
    /// ends the matter instead of starting the next ask.
    private var askedQuit = Set<pid_t>()
    /// Quit requests awaiting confirmation, so GuardDeck's Activity feed records
    /// the OUTCOME (the app really exited), never the attempt — an app that puts
    /// up a save sheet and stays open must not be logged as quit. Entries expire
    /// after `quitLogWindow` so a much later manual quit is not claimed either.
    private var pendingQuit = [pid_t: (name: String, at: Date)]()
    private let quitLogWindow: TimeInterval = 60
    /// pid -> (total CPU seconds, when it was read), for the busy check.
    private var cpuSamples = [pid_t: (seconds: Double, at: Date)]()

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

            // A nil scan means the app did not answer in time. Treat that as
            // "unknown", never as "no windows".
            guard let scan = scanWindows(pid) else {
                debugLog("\(bundleID): no answer from the Accessibility query, poll ignored")
                continue
            }
            // Only sampled while the app is windowless: that is the only moment
            // it can matter, and walking the process table twice a second for
            // every ticked app would not be free.
            let cpu = scan.real == 0 && scan.dialogs == 0 ? cpuPercent(pid) : nil

            if scan.real == 0 && scan.dialogs == 0 && hadWindows.contains(pid) {
                zeroPolls[pid] = (zeroPolls[pid] ?? 0) + 1
            } else if scan.real > 0 {
                zeroPolls[pid] = 0
            }

            guard Date().timeIntervalSince(firstSeen[pid] ?? .distantPast) > launchGrace else { continue }

            let decision = quitDecision(scan: scan,
                                        hadRealWindow: hadWindows.contains(pid),
                                        askedAlready: askedQuit.contains(pid),
                                        streak: zeroPolls[pid] ?? 0,
                                        cpuPercent: cpu)
            debugLog("\(bundleID): real=\(scan.real) dialogs=\(scan.dialogs) "
                     + "cpu=\(cpu.map { String(format: "%.1f%%", $0) } ?? "?") "
                     + "streak=\(zeroPolls[pid] ?? 0) -> \(decision)")

            switch decision {
            case .hasWindows:
                hadWindows.insert(pid)
                // A real window is a fresh chance: whatever happened to the
                // last quit request, the app is being used again.
                askedQuit.remove(pid)
                pendingQuit.removeValue(forKey: pid)
            case .quit:
                zeroPolls[pid] = 0
                hadWindows.remove(pid)
                askedQuit.insert(pid)
                pendingQuit[pid] = (app.localizedName ?? bundleID, Date())
                app.terminate()  // graceful: an app with unsaved work still gets to ask
            case .dialogOpen, .neverShowedWindow, .busy, .alreadyAsked, .waitForStreak:
                break
            }
        }

        // A pid we asked to quit that is no longer running really did exit —
        // that is the moment it becomes a fact worth logging, not before.
        // (Mutating a Swift Dictionary inside `for` is safe: the loop iterates a
        // value-semantics snapshot, not the live storage.)
        for (pid, entry) in pendingQuit where !live.contains(pid) {
            if Date().timeIntervalSince(entry.at) <= quitLogWindow {
                guardDeckLog(title: "Quit \(entry.name)", detail: "last window closed, app exited")
            }
            pendingQuit.removeValue(forKey: pid)
        }
        // An entry past the window can never log, so it has no reason to exist:
        // dropping it also ends the (theoretical) wrong-name-on-pid-reuse case and
        // stops a refused, forever-windowless app pinning an entry for good.
        pendingQuit = pendingQuit.filter { Date().timeIntervalSince($0.value.at) <= quitLogWindow }

        hadWindows.formIntersection(live)
        zeroPolls = zeroPolls.filter { live.contains($0.key) }
        firstSeen = firstSeen.filter { live.contains($0.key) }
        askedQuit.formIntersection(live)
        cpuSamples = cpuSamples.filter { live.contains($0.key) }
    }

    /// Real windows only, for the survey and the self test.
    func windowCount(_ pid: pid_t) -> Int? { scanWindows(pid)?.real }

    func scanWindows(_ pid: pid_t) -> WindowScan? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.3)

        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        guard err == .success, let windows = value as? [AXUIElement] else { return nil }

        var real = 0
        var dialogs = 0
        for window in windows {
            var roleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleRef) == .success,
                  let role = roleRef as? String, role == (kAXWindowRole as String)
            else { continue }

            var subroleRef: CFTypeRef?
            let subrole = AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleRef) == .success
                ? (subroleRef as? String) : nil
            if let subrole, dialogSubroles.contains(subrole) { dialogs += 1 } else { real += 1 }
        }
        return WindowScan(real: real, dialogs: dialogs)
    }

    /// CPU use since the previous poll, as a percentage of one core. Nil on the
    /// first poll for a pid (no baseline yet) or if the process cannot be read.
    func cpuPercent(_ pid: pid_t) -> Double? {
        guard let now = treeCPUSecondsUsed(pid) else { return nil }
        let at = Date()
        defer { cpuSamples[pid] = (now, at) }
        guard let previous = cpuSamples[pid] else { return nil }
        let elapsed = at.timeIntervalSince(previous.at)
        // A clock jump (sleep/wake) or a rewound counter reads as "unknown",
        // never as "idle": an unknown must not authorise a quit.
        guard elapsed > 0.05, now >= previous.seconds else { return nil }
        return (now - previous.seconds) / elapsed * 100
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

// MARK: - CPU probe

/// Prints what the busy check sees for every running app: how many processes
/// the app really is, and what share of one core they are using together.
///
/// Run:  /Applications/QuitOnClose.app/Contents/MacOS/QuitOnClose --cputest
func runCPUTest() -> Never {
    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    var before = [pid_t: Double]()
    for app in apps { before[app.processIdentifier] = treeCPUSecondsUsed(app.processIdentifier) }
    let start = Date()
    Thread.sleep(forTimeInterval: 2)
    let elapsed = Date().timeIntervalSince(start)

    print(String(format: "%-28s %6s %8s", ("app" as NSString).utf8String!,
                 ("procs" as NSString).utf8String!, ("cpu%" as NSString).utf8String!))
    for app in apps {
        let pid = app.processIdentifier
        guard let then = before[pid], let now = treeCPUSecondsUsed(pid) else { continue }
        let percent = (now - then) / elapsed * 100
        let name = (app.localizedName ?? "?").padding(toLength: 28, withPad: " ", startingAt: 0)
        print(String(format: "%@ %6d %8.1f%@", name, processTree(pid).count, percent,
                     percent > busyCPUPercent ? "   <- treated as busy" : ""))
    }
    exit(0)
}

// MARK: - Real app observation

/// Watches what QuitOnClose really does to one installed app: launch it, close
/// its last window, then log every poll for 40s. Nothing is asserted about apps
/// this session does not control; it prints the evidence.
///
/// Run:  /Applications/QuitOnClose.app/Contents/MacOS/QuitOnClose --realtest com.anthropic.claudefordesktop
func runRealTest(_ bundleID: String) -> Never {
    guard AXIsProcessTrusted() else { print("FAIL: no Accessibility permission"); exit(1) }
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
        print("FAIL: \(bundleID) is not installed"); exit(1)
    }
    func running() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID && !$0.isTerminated }
    }
    if running() != nil {
        print("FAIL: \(bundleID) is already running; this test only drives an app it launched itself")
        exit(1)
    }

    let monitor = Monitor()
    Store.shared.enableEphemeral(bundleID)
    monitor.start()

    func wait(seconds: TimeInterval, for check: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if check() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return check()
    }

    print("1. launching \(bundleID) ...")
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in }
    guard wait(seconds: 30, for: { (running()?.processIdentifier).flatMap { (monitor.scanWindows($0)?.real ?? 0) > 0 } ?? false }),
          let app = running()
    else { print("FAIL: it never showed a window"); exit(1) }
    let pid = app.processIdentifier
    print("   pid \(pid), \(processTree(pid).count) processes, windows=\(monitor.scanWindows(pid)!)")

    _ = wait(seconds: launchGrace + 1) { false }

    print("2. closing its last window ...")
    let axApp = AXUIElementCreateApplication(pid)
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let windows = windowsRef as? [AXUIElement], let window = windows.first
    else { print("FAIL: could not read its windows"); exit(1) }
    var closeRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeRef) == .success,
       let closeButton = closeRef, CFGetTypeID(closeButton) == AXUIElementGetTypeID() {
        _ = AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
    } else {
        print("FAIL: its window has no close button"); exit(1)
    }

    print("3. watching for 40s ...")
    var dialogEpisodes = 0
    var dialogUp = false
    let deadline = Date().addingTimeInterval(40)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        if running() == nil { break }
        // An unanswered Accessibility query means the app is busy or on its way
        // out, never "no dialog": breaking here reported a quitting app as
        // still running, which is exactly the lie this observer exists to catch.
        guard let scan = monitor.scanWindows(pid) else { continue }
        if scan.dialogs > 0 && !dialogUp { dialogEpisodes += 1; print("   a dialog appeared (\(scan))") }
        dialogUp = scan.dialogs > 0
    }

    if running() == nil {
        print("RESULT: it quit cleanly, \(dialogEpisodes) confirmation dialog(s) seen")
    } else {
        print("RESULT: still running after 40s, \(dialogEpisodes) confirmation dialog(s) seen")
    }
    if dialogEpisodes > 1 {
        print("FAIL: the confirmation dialog came back \(dialogEpisodes) times")
        exit(1)
    }
    print("PASS: at most one confirmation dialog")
    exit(0)
}

// MARK: - Dialog test

/// The source of a throwaway app that behaves like ChatGPT and Claude do: it
/// answers a quit request with a confirmation dialog and stays running.
private let victimSource = """
import Cocoa

final class VictimDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var alert: NSAlert?

    func applicationDidFinishLaunching(_ note: Notification) {
        let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 320, height: 160),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "QuitOnClose dialog victim"
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Every quit request is recorded, so the test counts asks rather than
        // inferring them from what is on screen. Counting is the assertion the
        // bug was about: it was asked again and again.
        if let path = ProcessInfo.processInfo.environment["QOC_VICTIM_LOG"] {
            let handle = FileHandle(forWritingAtPath: path)
            handle?.seekToEndOfFile()
            handle?.write(Data("ask\\n".utf8))
            try? handle?.close()
        }

        // Non-blocking on purpose: a runModal would freeze this process's run
        // loop and the test could not press the button back.
        let a = NSAlert()
        a.messageText = "Are you sure you want to quit?"
        a.addButton(withTitle: "Cancel")
        // Ordered front rather than run modally, so the button needs its own
        // action: with no modal session running, an NSAlert button does nothing.
        a.buttons.first?.target = self
        a.buttons.first?.action = #selector(dismiss)
        a.window.makeKeyAndOrderFront(nil)
        alert = a
        return .terminateCancel
    }

    @objc func dismiss() {
        alert?.window.orderOut(nil)
        alert = nil
    }
}

let app = NSApplication.shared
let delegate = VictimDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
"""

/// Proves the pop-up loop is gone, against a real app that really refuses.
///
/// Before this fix the confirmation dialog counted as a window, so dismissing
/// it re-armed the quit and the dialog came straight back — the bug Robert hit
/// with ChatGPT and Claude (2026-08-20).
///
/// Run:  /Applications/QuitOnClose.app/Contents/MacOS/QuitOnClose --dialogtest
func runDialogTest() -> Never {
    func say(_ message: String) { print(message) }
    func fail(_ message: String) -> Never { say("FAIL: \(message)"); exit(1) }

    guard AXIsProcessTrusted() else {
        fail("no Accessibility permission for this process, so nothing can be observed")
    }

    let bundleID = "com.quitonclose.test.victim"
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("qoc-dialogtest")
    let appURL = root.appendingPathComponent("Victim.app")
    let macOS = appURL.appendingPathComponent("Contents/MacOS")
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)

    let sourceURL = root.appendingPathComponent("victim.swift")
    try? victimSource.write(to: sourceURL, atomically: true, encoding: .utf8)
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>CFBundleExecutable</key><string>Victim</string>
      <key>CFBundleIdentifier</key><string>\(bundleID)</string>
      <key>CFBundleName</key><string>Victim</string>
      <key>CFBundlePackageType</key><string>APPL</string>
    </dict></plist>
    """
    try? plist.write(to: appURL.appendingPathComponent("Contents/Info.plist"),
                     atomically: true, encoding: .utf8)

    say("1. building the victim app ...")
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    compile.arguments = ["swiftc", "-O", sourceURL.path, "-framework", "Cocoa",
                         "-o", macOS.appendingPathComponent("Victim").path]
    try? compile.run()
    compile.waitUntilExit()
    guard compile.terminationStatus == 0 else { fail("could not compile the victim app (swiftc missing?)") }

    let monitor = Monitor()
    Store.shared.enableEphemeral(bundleID)
    monitor.start()

    func victim() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID && !$0.isTerminated }
    }
    func wait(seconds: TimeInterval, for check: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if check() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return check()
    }

    say("2. launching it ...")
    let logURL = root.appendingPathComponent("asks.log")
    FileManager.default.createFile(atPath: logURL.path, contents: Data())
    func askCount() -> Int {
        ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "")
            .split(separator: "\n").count
    }

    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    config.environment = ["QOC_VICTIM_LOG": logURL.path]
    var launchError: Error?
    NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in launchError = error }
    guard wait(seconds: 20, for: { (victim()?.processIdentifier).flatMap { (monitor.scanWindows($0)?.real ?? 0) > 0 } ?? false })
    else { fail("the victim never showed a window (\(launchError.map { "\($0)" } ?? "no launch error"))") }
    guard let app = victim() else { fail("the victim vanished") }
    let pid = app.processIdentifier
    say("   victim pid \(pid), windows=\(monitor.scanWindows(pid)!)")

    _ = wait(seconds: launchGrace + 1) { false }

    say("3. closing its only window ...")
    let axApp = AXUIElementCreateApplication(pid)
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let windows = windowsRef as? [AXUIElement], let window = windows.first
    else { fail("could not read the victim's windows") }
    var closeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeRef) == .success,
          let closeButton = closeRef, CFGetTypeID(closeButton) == AXUIElementGetTypeID(),
          AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString) == .success
    else { fail("could not press the window's close button") }

    say("4. waiting for QuitOnClose to ask it to quit, and for it to refuse ...")
    guard wait(seconds: 15, for: { askCount() > 0 }) else {
        if victim() == nil { fail("the victim was killed outright; its refusal was never seen") }
        fail("the victim was never asked to quit within 15s")
    }
    guard let asked = monitor.scanWindows(pid) else { fail("lost sight of the victim") }
    say("   asked \(askCount())x; its dialog reads real=\(asked.real) dialogs=\(asked.dialogs)")
    guard asked.real == 0 else { fail("the confirmation dialog is being counted as a real window (real=\(asked.real))") }

    say("5. pressing Cancel, the way a human answers 'no' ...")
    var afterRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &afterRef) == .success,
          let live = afterRef as? [AXUIElement] else { fail("could not re-read the victim's windows") }
    var pressed = false
    for dialog in live {
        var kidsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dialog, kAXChildrenAttribute as CFString, &kidsRef) == .success,
              let kids = kidsRef as? [AXUIElement] else { continue }
        for kid in kids {
            var titleRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(kid, kAXTitleAttribute as CFString, &titleRef)
            if (titleRef as? String) == "Cancel",
               AXUIElementPerformAction(kid, kAXPressAction as CFString) == .success {
                pressed = true
                break
            }
        }
        if pressed { break }
    }
    guard pressed else { fail("could not find the Cancel button in the confirmation dialog") }

    say("6. watching for 15s that it is not asked again ...")
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        if victim() == nil { break }
    }
    let asks = askCount()

    let survived = victim() != nil
    victim()?.forceTerminate()
    try? FileManager.default.removeItem(at: root)

    if asks != 1 { fail("the app was asked to quit \(asks) times; the human answered no after the first") }
    guard survived else { fail("the victim was terminated even though it refused the quit") }
    say("PASS: asked once, refused once, never asked again; the victim is still running")
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

    // --- the quit decision -------------------------------------------------
    let windowed = WindowScan(real: 1, dialogs: 0)
    let bare = WindowScan(real: 0, dialogs: 0)
    let asking = WindowScan(real: 0, dialogs: 1)

    check(quitDecision(scan: bare, hadRealWindow: true, askedAlready: false,
                       streak: zeroPollsBeforeQuit, cpuPercent: 0) == .quit,
          "an idle app that showed a window and then closed it is quit")
    check(quitDecision(scan: bare, hadRealWindow: true, askedAlready: false,
                       streak: 1, cpuPercent: 0) == .waitForStreak,
          "one zero-window poll is not enough")
    check(quitDecision(scan: asking, hadRealWindow: true, askedAlready: false,
                       streak: 99, cpuPercent: 0) == .dialogOpen,
          "an app showing a dialog is never quit")
    check(quitDecision(scan: asking, hadRealWindow: false, askedAlready: true,
                       streak: 99, cpuPercent: 0) == .dialogOpen,
          "the app's own 'are you sure?' does not count as a reopened window")
    check(quitDecision(scan: bare, hadRealWindow: true, askedAlready: true,
                       streak: 99, cpuPercent: 0) == .alreadyAsked,
          "an app that was already asked once is never asked again")
    check(quitDecision(scan: bare, hadRealWindow: true, askedAlready: false,
                       streak: 99, cpuPercent: busyCPUPercent + 10) == .busy(busyCPUPercent + 10),
          "an app still working with no window is left alone")
    check(quitDecision(scan: bare, hadRealWindow: true, askedAlready: false,
                       streak: 99, cpuPercent: nil) == .quit,
          "an unreadable CPU figure does not block the quit forever")
    check(quitDecision(scan: windowed, hadRealWindow: false, askedAlready: true,
                       streak: 99, cpuPercent: 0) == .hasWindows,
          "a real window re-arms an app that refused an earlier quit")
    check(quitDecision(scan: bare, hadRealWindow: false, askedAlready: false,
                       streak: 99, cpuPercent: 0) == .neverShowedWindow,
          "an app that never showed a window is left alone")

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
        print("PASS: 4 menu checks, 5 advice checks and 9 quit-decision checks")
        exit(0)
    }
    print("FAILED: \(failures.count) — \(failures.joined(separator: "; "))")
    exit(1)
}

if CommandLine.arguments.contains("--permcheck") {
    runPermCheck()
}

if let index = CommandLine.arguments.firstIndex(of: "--realtest") {
    runRealTest(CommandLine.arguments.count > index + 1
                ? CommandLine.arguments[index + 1] : "com.anthropic.claudefordesktop")
}

if CommandLine.arguments.contains("--cputest") {
    runCPUTest()
}

if CommandLine.arguments.contains("--dialogtest") {
    runDialogTest()
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
