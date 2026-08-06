// Debug probe: prints the window count QuitOnClose would see for every running
// GUI app. Build:  swiftc -O -o /tmp/axprobe Tests/axprobe.swift -framework Cocoa
import Cocoa
import ApplicationServices

func windowCount(_ pid: pid_t) -> Int? {
    let axApp = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(axApp, 0.3)
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
    guard err == .success, let windows = value as? [AXUIElement] else { return nil }
    return windows.filter { window in
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String else { return false }
        return role == (kAXWindowRole as String)
    }.count
}

print("AXIsProcessTrusted: \(AXIsProcessTrusted())")
for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
    let name = app.localizedName ?? "?"
    let count = windowCount(app.processIdentifier).map(String.init) ?? "nil (no AX access)"
    print("\(name.padding(toLength: 28, withPad: " ", startingAt: 0)) windows=\(count)")
}
