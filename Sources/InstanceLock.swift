import Foundation
import Darwin
import Cocoa

// Keep the descriptor open for the lifetime of the process. flock is atomic,
// unlike checking NSWorkspace then racing another launch to create a menu.
final class InstanceLock {
    private var descriptor: Int32 = -1

    init?() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask)[0]
            .appendingPathComponent("QuitOnClose", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch { return nil }
        descriptor = open(directory.appendingPathComponent("instance.lock").path,
                          O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            descriptor = -1
            return nil
        }
    }

    deinit { if descriptor >= 0 { close(descriptor) } }
}

func stopExistingInstances() -> Int32 {
    let apps = NSWorkspace.shared.runningApplications.filter {
        $0.bundleIdentifier == "com.quitonclose.app" && $0.processIdentifier > 0
            && $0.processIdentifier != getpid() && !$0.isTerminated
    }
    let group = DispatchGroup()
    let sources = apps.map { app -> DispatchSourceProcess in
        group.enter()
        let source = DispatchSource.makeProcessSource(identifier: app.processIdentifier,
            eventMask: .exit, queue: .global())
        source.setEventHandler { group.leave() }
        source.resume()
        return source
    }
    defer { sources.forEach { $0.cancel() } }
    // Only our stateless menu processes, never any application being managed.
    // Apple-event termination can be denied for a shell-launched installer.
    for app in apps { _ = kill(app.processIdentifier, SIGTERM) }
    // Kernel exit events avoid polling and ensure the old lock is released.
    // A just-exited process can still answer kill(pid, 0) until launchd reaps
    // it. The kernel exit event proves its descriptors (and lock) are released.
    let stopped = group.wait(timeout: .now() + 5) == .success
    print(stopped ? "Existing QuitOnClose instances stopped" : "Stop failed; existing installation retained")
    return stopped ? 0 : 1
}
