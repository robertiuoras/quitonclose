import Cocoa

@main
final class IdleVictim: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("bare") { return }
        window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 240, height: 100),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window?.title = "QuitOnClose test fixture"
        window?.orderFront(nil)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let path = ProcessInfo.processInfo.environment["QOC_TEST_ASKS"] {
            let handle = FileHandle(forWritingAtPath: path)
            handle?.seekToEndOfFile()
            handle?.write(Data("ask\n".utf8))
            try? handle?.close()
        }
        return CommandLine.arguments.contains("refuse") ? .terminateCancel : .terminateNow
    }
    static func main() {
        let app = NSApplication.shared
        let delegate = IdleVictim()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
