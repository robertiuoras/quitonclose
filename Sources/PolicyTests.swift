import Cocoa
import ApplicationServices

func runPolicyTest() -> Int32 {
    _ = NSApplication.shared
    var checks = 0
    var failures = 0
    func check(_ result: Bool, _ title: String) {
        checks += 1
        if !result { failures += 1 }
        print("\(result ? "ok" : "FAIL") \(title)")
    }
    let messages = "com.apple.MobileSMS"
    for id in [messages, "net.whatsapp.WhatsApp", "com.apple.finder", "com.microsoft.rdc.macos"] {
        check(automaticRule(id, idleRule: .idle30) == .idle30, "automatic policy includes \(id)")
    }
    for id in ["com.openai.codex", "com.robert.paneforge", "com.apple.Terminal", "io.tailscale.ipn.macsys", "com.google.Chrome"] {
        check(automaticRule(id, idleRule: .idle30) == .keepOpen, "background work protected: \(id)")
    }
    check(automaticRule("unknown.app", idleRule: .idle30) == .keepOpen, "unknown apps need manual opt-in")
    func decision(id: String = "com.apple.MobileSMS", windows: Int = 1, dialogs: Int = 0,
                  active: Bool = false, idle: Double = 1800, asked: Bool = false,
                  cpu: Double? = 0, audio: Bool = false) -> IdleDecision {
        idleDecision(id: id, realWindows: windows, dialogs: dialogs, active: active,
                     idleFor: idle, timeout: 1800, asked: asked, cpu: cpu, audioRunning: audio)
    }
    check(decision() == .quit, "an unused app with a window can close at the timeout")
    check(decision(windows: 0) == .quit, "an app never opened can close after its full grace")
    check(decision(idle: 1799) == .wait, "does not close before the timeout")
    check(decision(active: true) == .active, "foreground app stays open")
    check(decision(dialogs: 1) == .dialog, "save sheets and dialogs stay open")
    check(decision(asked: true) == .alreadyAsked, "refused quit is not retried over an existing window")
    check(decision(cpu: nil) == .unknown, "unreadable CPU does not authorize idle closure")
    check(decision(cpu: .nan) == .unknown, "invalid CPU does not authorize idle closure")
    check(decision(cpu: 9) == .busy, "busy app stays open")
    check(decision(audio: true) == .wait, "audio activity protects calls and messages")
    check(decision(id: "com.microsoft.rdc.macos") == .protected, "Windows App with a session window stays open")
    check(decision(id: "com.microsoft.rdc.macos", windows: 0) == .quit, "windowless Windows App can close")
    check(idleDecision(id: "com.microsoft.rdc.macos", realWindows: 1, dialogs: 0,
        active: false, idleFor: 1800, timeout: 1800, asked: false, cpu: 0, audioRunning: false,
        allowRemoteWindows: true) == .quit, "explicit Windows App opt-in allows closing idle windows")
    check(decision(id: "com.openai.codex", windows: 0) == .protected, "quiet remote AI work stays open")
    check(decision(id: "com.apple.finder") == .quit, "idle Finder windows reach the close-only action")

    // Exercise actual native menu actions, and restore the exact prior defaults.
    let defaults = UserDefaults.standard
    let keys = ["intelligentClosing", "automaticIdle", "closingRules"]
    let saved = keys.map { defaults.object(forKey: $0) }
    defer {
        for (key, value) in zip(keys, saved) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }
    Store.shared.intelligent = true
    Store.shared.automaticIdle = .idle30
    Store.shared.setRule(messages, .idle15)
    let delegate = AppDelegate()
    let menu = NSMenu()
    delegate.menuNeedsUpdate(menu)
    if let toggle = menu.items.firstIndex(where: { $0.title == "Intelligent closing" }) {
        check(menu.items[toggle].state == .on, "intelligent toggle shows persisted state")
        menu.performActionForItem(at: toggle)
        check(!Store.shared.intelligent, "clicking the native toggle switches to manual")
        check(Store.shared.rule(messages) == .idle15, "switching modes restores the manual rule")
    } else { check(false, "intelligent toggle exists") }
    delegate.menuNeedsUpdate(menu)
    let choice = menu.items.compactMap(\.submenu).flatMap(\.items).first {
        ($0.representedObject as? [String]) == [messages, ClosingRule.idle5.rawValue]
    }
    if let choice, let submenu = choice.menu {
        submenu.performActionForItem(at: submenu.index(of: choice))
        check(Store.shared.rule(messages) == .idle5, "native per-app menu saves a five-minute rule")
        check((defaults.dictionary(forKey: "closingRules")?[messages] as? String) == "idle5", "manual rule is persisted")
    } else { check(false, "Messages manual rule menu exists") }
    Store.shared.intelligent = true
    check(Store.shared.rule(messages) == .idle30, "smart mode uses its own timer")
    Store.shared.intelligent = false
    check(Store.shared.rule(messages) == .idle5, "manual selection survives smart mode")
    print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) policy and native-menu checks; \(failures) failures")
    return failures == 0 ? 0 : 1
}

// A real Cocoa app, with only that fixture passed into the production monitor.
// Advancing the decision clock avoids a five-minute sleep; AX, CPU sampling and
// graceful termination remain real. This does not assert the installed TCC grant.
func runIdleTest(_ appURL: URL) -> Int32 {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    guard AXIsProcessTrusted() else { print("BLOCKED: test host needs Accessibility"); return 2 }
    let id = "com.quitonclose.test.idlevictim"
    guard Bundle(url: appURL)?.bundleIdentifier == id else { print("FAIL: wrong fixture"); return 1 }
    let defaults = UserDefaults.standard
    let keys = ["intelligentClosing", "closingRules"]
    let saved = keys.map { defaults.object(forKey: $0) }
    defer {
        for (key, value) in zip(keys, saved) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }
    Store.shared.intelligent = false
    Store.shared.setRule(id, .idle5)
    func wait(_ seconds: Double, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return condition()
    }
    let originalFront = NSWorkspace.shared.frontmostApplication
    for mode in ["window", "bare", "refuse"] {
        let log = appURL.deletingLastPathComponent().appendingPathComponent("asks-\(mode).log")
        do { try Data().write(to: log) } catch { print("FAIL: fixture log"); return 1 }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.arguments = [mode]
        configuration.environment = ["QOC_TEST_ASKS": log.path]
        var victim: NSRunningApplication?
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
            victim = app
            if let error { print("fixture launch: \(error)") }
        }
        guard wait(10, until: { victim != nil }), let victim else { print("FAIL: launch"); return 1 }
        defer { if kill(victim.processIdentifier, 0) == 0 { victim.forceTerminate() } } // fixture only
        let monitor = Monitor()
        guard wait(5, until: { monitor.windowCount(victim.processIdentifier) == (mode == "bare" ? 0 : 1) }) else {
            print("FAIL: AX fixture window scan"); return 1
        }
        guard !victim.isActive else { print("FAIL: fixture unexpectedly frontmost"); return 1 }
        let start = Date()
        monitor.tick([victim], now: start)
        monitor.tick([victim], now: start.addingTimeInterval(299))
        guard kill(victim.processIdentifier, 0) == 0 else { print("FAIL: early quit"); return 1 }
        monitor.tick([victim], now: start.addingTimeInterval(300)) // CPU baseline
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        monitor.tick([victim], now: start.addingTimeInterval(301))
        guard wait(5, until: { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("ask") }) else {
            print("FAIL: no graceful quit for \(mode)"); return 1
        }
        if mode == "refuse" {
            // A quit dialog can activate its owner. That must not clear the
            // refusal latch, even once the foreground timer expires again.
            if let originalFront {
                victim.activate(options: [])
                guard wait(3, until: { victim.isActive }) else { print("FAIL: activate fixture"); return 1 }
                monitor.tick([victim], now: start.addingTimeInterval(302))
                originalFront.activate(options: [])
                guard wait(3, until: { !victim.isActive }) else { print("FAIL: restore foreground"); return 1 }
                monitor.tick([victim], now: start.addingTimeInterval(603))
            }
            for second in 604...609 { monitor.tick([victim], now: start.addingTimeInterval(Double(second))) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            guard (try? String(contentsOf: log, encoding: .utf8)) == "ask\n",
                  kill(victim.processIdentifier, 0) == 0 else { print("FAIL: refused quit repeated"); return 1 }
        } else {
            guard wait(5, until: { kill(victim.processIdentifier, 0) != 0 }) else { print("FAIL: fixture still running"); return 1 }
        }
        print("PASS: production monitor / real \(mode) fixture")
    }
    return 0
}
