import AppKit
import Darwin

// Single-instance guard, run at process entry — before SwiftUI or AppKit starts
// anything. A duplicate launch would otherwise instantiate `ServerController`
// (which shell-outs to resolve binaries, taking seconds) and then sweep the first
// instance's server processes, so it must be blocked here, as early as possible.

private let showMainWindowNotification = Notification.Name("MLXServerShowMainWindow")

private func lockFilePath() -> String {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let dir = appSupport.appendingPathComponent("MLXServer", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("single-instance.lock").path
}

// The descriptor stays open for the app's lifetime; the kernel releases the
// `flock` the moment this process exits (even on a crash), so no stale lock can
// outlive a crashed or killed instance.
let lockFD = open(lockFilePath(), O_CREAT | O_RDWR, 0o644)
if lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    // Another copy is already running: ask it to show itself, then quit this one.
    DistributedNotificationCenter.default().postNotificationName(
        showMainWindowNotification,
        object: nil,
        deliverImmediately: true
    )
    exit(0)
}

MLXServerApp.main()
