import Cocoa
import ApplicationServices
import ServiceManagement

// MARK: - Config

private let defaultsKey = "enabledBundleIDs"
private let pollInterval: TimeInterval = 0.5
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

// MARK: - Store

final class Store {
    static let shared = Store()
    private(set) var enabled: Set<String>

    private init() {
        enabled = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
    }

    func isEnabled(_ bundleID: String) -> Bool { enabled.contains(bundleID) }

    /// Enable without touching UserDefaults. Used by `--selftest` so a test run
    /// never changes the user's saved list.
    func enableEphemeral(_ bundleID: String) { enabled.insert(bundleID) }

    func toggle(_ bundleID: String) {
        if enabled.contains(bundleID) {
            enabled.remove(bundleID)
        } else {
            enabled.insert(bundleID)
        }
        UserDefaults.standard.set(Array(enabled).sorted(), forKey: defaultsKey)
    }
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
            guard let count = windowCount(pid) else { continue }

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

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = Monitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "xmark.rectangle", accessibilityDescription: "QuitOnClose")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        requestAccessibilityIfNeeded()
        monitor.start()
    }

    private func requestAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !AXIsProcessTrusted() {
            let warn = NSMenuItem(title: "Accessibility permission needed", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        let header = NSMenuItem(title: "Quit when last window closes:", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { app in
                guard let id = app.bundleIdentifier else { return false }
                return !neverQuit.contains(id)
            }
            .sorted { ($0.localizedName ?? "") .localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }

        var listed = Set<String>()
        for app in running {
            guard let id = app.bundleIdentifier, listed.insert(id).inserted else { continue }
            menu.addItem(appItem(title: app.localizedName ?? id, bundleID: id, icon: app.icon))
        }

        // Enabled apps that are not running right now, so they can still be turned off.
        let offline = Store.shared.enabled.subtracting(listed).sorted()
        if !offline.isEmpty {
            menu.addItem(.separator())
            let sub = NSMenuItem(title: "Enabled but not running", action: nil, keyEquivalent: "")
            sub.isEnabled = false
            menu.addItem(sub)
            for id in offline {
                let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                let name = url.flatMap { FileManager.default.displayName(atPath: $0.path) } ?? id
                let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
                menu.addItem(appItem(title: name, bundleID: id, icon: icon))
            }
        }

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        let quit = NSMenuItem(title: "Quit QuitOnClose", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func appItem(title: String, bundleID: String, icon: NSImage?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(toggleApp(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = bundleID
        item.state = Store.shared.isEnabled(bundleID) ? .on : .off
        if let icon {
            let small = icon.copy() as! NSImage
            small.size = NSSize(width: 16, height: 16)
            item.image = small
        }
        return item
    }

    @objc private func toggleApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        Store.shared.toggle(bundleID)
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

// MARK: - Self test

/// End-to-end proof that the real Monitor quits a real app when its last window
/// closes: open TextEdit on a scratch file, press that window's close button
/// through the Accessibility API, then wait for TextEdit to die.
///
/// Run:  /Applications/QuitOnClose.app/Contents/MacOS/QuitOnClose --selftest
func runSelfTest() -> Never {
    func fail(_ message: String) -> Never {
        print("FAIL: \(message)")
        exit(1)
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

    print("1. opening TextEdit ...")
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) else {
        fail("TextEdit not found on this Mac")
    }
    NSWorkspace.shared.open([scratch], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())

    guard wait(seconds: 20, for: { (textEdit()?.processIdentifier).flatMap { (monitor.windowCount($0) ?? 0) > 0 } ?? false }) else {
        fail("TextEdit never showed a window the Accessibility API could see")
    }
    guard let app = textEdit() else { fail("TextEdit vanished") }
    print("   TextEdit pid \(app.processIdentifier), windows=\(monitor.windowCount(app.processIdentifier) ?? -1)")

    // Let the Monitor's launch grace period elapse, then close the window.
    _ = wait(seconds: launchGrace + 1) { false }

    print("2. closing its last window ...")
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

    print("3. waiting for QuitOnClose to terminate it ...")
    let start = Date()
    guard wait(seconds: 10, for: { textEdit() == nil }) else {
        fail("TextEdit is still running 10s after its last window closed")
    }
    print(String(format: "PASS: TextEdit quit %.2fs after its last window closed", Date().timeIntervalSince(start)))
    try? FileManager.default.removeItem(at: scratch)
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    runSelfTest()
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
