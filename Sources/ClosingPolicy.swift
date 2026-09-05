import Foundation

enum ClosingRule: String, CaseIterable {
    case keepOpen, onClose, idle5, idle15, idle30, idle60

    var seconds: TimeInterval? {
        switch self {
        case .keepOpen, .onClose: return nil
        case .idle5: return 300
        case .idle15: return 900
        case .idle30: return 1800
        case .idle60: return 3600
        }
    }

    var title: String {
        switch self {
        case .keepOpen: return "Keep open"
        case .onClose: return "After the last window closes"
        default: return "After \(Int(seconds! / 60)) minutes unused"
        }
    }
}

let remoteDesktopApps: Set<String> = ["com.microsoft.rdc.macos", "com.microsoft.windowsapp"]
let idleApps: Set<String> = [
    "com.apple.finder", "com.apple.MobileSMS", "net.whatsapp.WhatsApp",
    "com.apple.Notes", "com.apple.Preview", "com.apple.ActivityMonitor",
    "com.apple.AppStore", "com.apple.Passwords", "com.apple.systempreferences",
    "com.apple.iCal", "com.apple.reminders", "com.apple.mail",
    "com.microsoft.Word", "com.microsoft.Excel", "com.apple.iWork.Numbers",
]

// These can be doing valuable remote/background work at zero local CPU.
// A manual idle rule must not turn a missing work signal into permission to quit.
func protectedWork(_ id: String) -> Bool {
    let exact: Set<String> = [
        "com.openai.codex", "com.openai.chat", "com.anthropic.claudefordesktop",
        "com.robert.paneforge", "com.personalagent.app", "com.apple.Terminal",
        "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", "com.apple.Safari", "com.google.Chrome",
        "org.mozilla.firefox", "com.microsoft.edgemac", "company.thebrowser.Browser",
    ]
    return exact.contains(id) || ["com.docker", "com.getdropbox", "com.google.GoogleDrive",
        "com.microsoft.OneDrive", "com.backblaze", "com.code42", "com.wireguard",
        "net.tunnelblick", "com.nordvpn", "com.expressvpn", "com.tailscale",
        "io.tailscale", "com.parallels", "com.vmware", "org.virtualbox",
        "com.jetbrains"].contains { id.hasPrefix($0) }
}

func automaticRule(_ id: String, idleRule: ClosingRule) -> ClosingRule {
    if protectedWork(id) { return .keepOpen }
    if idleApps.contains(id) || remoteDesktopApps.contains(id) { return idleRule }
    // Unknown apps require explicit opt-in; a window count cannot tell whether
    // a new app is a worker, a call, or merely an idle utility.
    return .keepOpen
}

enum IdleDecision: Equatable {
    case wait, unknown, active, dialog, alreadyAsked, protected, busy, quit
}

func idleDecision(id: String, realWindows: Int, dialogs: Int, active: Bool,
                  idleFor: TimeInterval, timeout: TimeInterval, asked: Bool,
                  cpu: Double?, audioRunning: Bool, allowRemoteWindows: Bool = false) -> IdleDecision {
    if active { return .active }
    if dialogs > 0 { return .dialog }
    if asked { return .alreadyAsked }
    if protectedWork(id) || (remoteDesktopApps.contains(id) && realWindows > 0 && !allowRemoteWindows) { return .protected }
    if idleFor < timeout || audioRunning { return .wait }
    guard let cpu, cpu.isFinite, cpu >= 0 else { return .unknown }
    if cpu > 8 { return .busy }
    return .quit
}
