import AppKit

// ── Single-instance guard ────────────────────────────────────────────────────
// Two copies of a menu-bar app are worse than useless: you get two status
// items, two auto-reconnect timers racing to redial the same tunnel, and two
// writers clobbering the same config file — and no way to tell which icon you
// are clicking.
//
// Enforced with an advisory lock (flock) on a file in the state directory
// rather than a PID file or a bundle-identifier check, because:
//   • the kernel drops the lock when the process dies, so a crash or `kill -9`
//     can't strand a stale lock the way a PID file can;
//   • it also covers the binary being run directly, outside the .app bundle,
//     where there is no bundle identifier to match on.
//
// What a redundant launch does is the interesting part. It used to post a
// distributed notification asking the live copy to show Settings, then exit(0)
// silently. That is fine while the menu bar icon is visible — but this app IS
// its icon, and macOS can park a status item off-screen, at which point the
// running copy is invisible AND a fresh launch appears to do nothing at all.
// Silently exiting in that state leaves no way back short of `killall` from a
// terminal. So a redundant launch now says what it found and offers to take over.

enum SingleInstance {
    /// Sent by a redundant launch to ask the live instance to surface itself.
    ///
    /// Derived from the bundle identifier rather than spelled out, so renaming the app's
    /// identity cannot leave two copies talking on different names — which would look
    /// exactly like the handoff silently not working.
    static let showSettingsNotification = Notification.Name(
        (Bundle.main.bundleIdentifier ?? "anywayconnect") + ".showSettings")

    /// Held for the lifetime of the process. Closing it would release the lock.
    private static var lockDescriptor: Int32 = -1

    private static var lockURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/anyway-connect/state/instance.lock")
    }

    /// Attempt to become *the* instance.
    /// - Returns: true if this process may proceed, false if another holds the lock.
    static func acquire() -> Bool {
        // Escape hatch for development: lets a test harness run alongside the
        // installed app. Not used in normal operation.
        if ProcessInfo.processInfo.environment["ANYWAY_SINGLE_INSTANCE"] == "0" { return true }

        let path = lockURL.path
        try? FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        let fd = Darwin.open(path, O_CREAT | O_RDWR, 0o600)
        // If the lock file itself is unusable, fail open rather than refusing to
        // start the app at all.
        guard fd >= 0 else {
            NSLog("AnywayConnect: cannot open instance lock at \(path); continuing unguarded")
            return true
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        lockDescriptor = fd
        // Record who holds it so a later launch can offer to replace us. flock is
        // advisory, so the other process can still read this while we hold the lock.
        // The pid is a courtesy for the UI, never a correctness mechanism — the lock
        // itself is what guarantees exclusivity.
        ftruncate(fd, 0)
        let line = "\(getpid())\n"
        _ = line.withCString { write(fd, $0, strlen($0)) }
        fsync(fd)
        return true
    }

    /// pid recorded by whoever holds the lock, if it is still alive.
    static func holderPID() -> pid_t? {
        guard let text = try? String(contentsOf: lockURL, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1, pid != getpid(),
              kill(pid, 0) == 0
        else { return nil }
        return pid
    }

    /// Ask the instance that already holds the lock to show its Settings window.
    static func handOffToRunningInstance() {
        DistributedNotificationCenter.default().postNotificationName(
            showSettingsNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }

    // MARK: - What a redundant launch offers

    enum Choice { case showSettings, restart, cancel }

    /// Tell the user a copy is already running and let them pick.
    ///
    /// Must be called once AppKit has finished launching — from
    /// applicationDidFinishLaunching, not from main.swift. Before that point
    /// `runModal()` returns immediately without drawing anything, which reproduced the
    /// very "launching does nothing" symptom this dialog exists to cure.
    ///
    /// Activation is still required, or the alert opens behind whatever is frontmost.
    static func askUserWhatToDo() -> Choice {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "AnywayConnect is already running"
        alert.informativeText = """
            Its menu bar icon may be hidden — macOS sometimes places a status item \
            off-screen, and this app has no window of its own.

            Open Settings to reach the copy that is running, or restart it to have the \
            icon placed again.
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .showSettings
        case .alertSecondButtonReturn: return .restart
        default:                       return .cancel
        }
    }

    /// What a *re-launch* offers, as distinct from a redundant second process.
    ///
    /// Finder never starts a second copy of an app that is already running: it sends a
    /// reopen Apple Event to the existing one, so `acquire()` is never consulted and the
    /// dialog above cannot appear. That is why launching the app again looked like it did
    /// nothing at all. Measured on this machine: a second `open` fires the raw
    /// kAEReopenApplication event, while AppKit's `applicationShouldHandleReopen` is not
    /// called for an accessory app — so the event has to be handled directly.
    ///
    /// Quit is offered because this app *is* its menu bar icon. With the icon parked
    /// off-screen there is otherwise no way to quit it short of Activity Monitor, and
    /// quitting then launching again is what gets the icon placed afresh.
    enum ReopenChoice { case showSettings, quit, cancel }

    static func askWhatToDoOnReopen() -> ReopenChoice {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "AnywayConnect is already running"
        alert.informativeText = """
            It has no window of its own — it lives in the menu bar. If you cannot see its \
            icon, macOS may have placed it off-screen.

            Open Settings to reach it, or quit it and launch again to have the icon placed \
            afresh.
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Quit AnywayConnect")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .showSettings
        case .alertSecondButtonReturn: return .quit
        default:                       return .cancel
        }
    }

    /// Stop the running copy and take the lock ourselves.
    ///
    /// Success is defined as *acquiring the lock*, not as the signal being delivered:
    /// the kernel drops the lock when the holder dies, so re-acquiring it is proof the
    /// old process is gone. That also means a stale or wrong pid in the lock file cannot
    /// produce a false success.
    ///
    /// SIGTERM first so the old copy can tear down cleanly, escalating only if it does
    /// not go. This can only ever signal a process of the same user — the lock lives in
    /// the user's own home directory, so no privilege boundary is crossed.
    static func replaceRunningInstance(timeout: TimeInterval = 6) -> Bool {
        if let pid = holderPID() { kill(pid, SIGTERM) }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if acquire() { return true }
            Thread.sleep(forTimeInterval: 0.15)
        }
        if let pid = holderPID() {
            NSLog("AnywayConnect: previous instance \(pid) did not exit on SIGTERM; escalating")
            kill(pid, SIGKILL)
        }
        let hardDeadline = Date().addingTimeInterval(3)
        while Date() < hardDeadline {
            if acquire() { return true }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return false
    }

    /// Shown when Restart could not take over, so the user is not left guessing.
    static func reportRestartFailure() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't restart AnywayConnect"
        alert.informativeText = "The copy that is running did not exit. Quit it from "
            + "Activity Monitor, or run: killall AnywayConnect"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
