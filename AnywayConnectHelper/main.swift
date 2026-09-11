import Foundation

// ── AnywayConnect privileged daemon ──────────────────────────────────────────
//
// Registered by the app through SMAppService and run by launchd as root, on
// demand, reachable only over its Mach service.
//
// This exists to replace `sudo /usr/local/sbin/anyway-root-helper.sh` and the
// NOPASSWD sudoers rule behind it. That rule could be invoked by anything
// running as the desktop user, so its safety depended wholly on the shell
// script's argument checking. Here the listener refuses any peer that isn't our
// Developer-ID-signed app, so an arbitrary process cannot reach these
// operations at all — a categorically stronger position than validating the
// arguments of a caller you can't identify.
//
// Argument validation is still applied, from the shared PrivilegedValidation.
// Authentication decides *who* may ask; validation still decides *what*.
//
// Note what is NOT accepted from the caller: no script paths, no vpnc-script
// path, no pid-file path. Those are fixed below and verified root-owned before
// use, because openconnect executes the --script as root and a caller-supplied
// path there is arbitrary root code execution.

private let libexecDir = "/usr/local/libexec/anyway-connect"
private let routeWrapperPath = libexecDir + "/route-wrapper.sh"
private let vpncScriptPath = libexecDir + "/vpnc-script"
private let pidFilePath = "/var/run/anyway-connect.pid"

/// Searched in a fixed order, never taken from an argument.
private let openconnectCandidates = [
    "/opt/homebrew/bin/openconnect",
    "/usr/local/bin/openconnect",
    "/usr/bin/openconnect",
]

private func log(_ message: String) {
    // Goes to the daemon's launchd stdout/stderr, see the plist.
    FileHandle.standardError.write(Data("[anyway-helper] \(message)\n".utf8))
}

// MARK: - Service

final class PrivilegedService: NSObject, PrivilegedHelperProtocol {

    /// uid of the connected client, so a log file we create stays writable by
    /// the unprivileged app rather than becoming root-owned.
    private let clientUID: uid_t
    private var tunnel: Process?

    init(clientUID: uid_t) {
        self.clientUID = clientUID
        super.init()
    }

    // MARK: Preconditions

    /// Refuse to execute anything a non-root user could have edited. Everything
    /// here runs as root, so a user-writable file would be a straight
    /// privilege escalation — this is why the vpnc-script is used from libexec
    /// and not from Homebrew, whose prefix the desktop user owns.
    private func assertRootOwned(_ path: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return "missing \(path) — run scripts/install-privileged.sh"
        }
        guard (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0 else {
            return "\(path) must be owned by root"
        }
        let perms = (attrs[.posixPermissions] as? NSNumber)?.int16Value ?? 0
        if perms & 0o022 != 0 { return "\(path) is group- or world-writable" }
        return nil
    }

    private func findOpenconnect() -> String? {
        openconnectCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The only log this daemon will ever write, derived from the connected client's
    /// uid rather than taken from the message it sent.
    ///
    /// The home prefix is resolved with realpath, deliberately, while everything below
    /// it is left alone. The split matters: /Users and the home directory entry itself
    /// are root-owned, so a symlink there is an administrator's decision and following
    /// it is fine — whereas `.config/anyway-connect/state/openconnect.log` sits in
    /// territory the desktop user (and therefore an attacker running as them) can
    /// rewrite, so those components must never be followed. Resolving the whole path
    /// instead would quietly defeat that; resolving none of it would refuse to log at
    /// all on any machine whose home is reached through a link, since the open below
    /// rejects symlinks in every component.
    private var expectedLogPath: String? {
        guard let pw = getpwuid(clientUID), let dir = pw.pointee.pw_dir else { return nil }
        let home = String(cString: dir)
        guard home.hasPrefix("/"), !home.contains("..") else { return nil }
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(home, &buf) != nil else { return nil }
        return String(cString: buf) + "/.config/anyway-connect/state/openconnect.log"
    }

    /// Append handle for the app's log. The hardening lives in PrivilegedFile so the
    /// app's test harness can exercise this exact code rather than a copy of it.
    private func logHandle(_ path: String) -> FileHandle? {
        switch PrivilegedFile.openAppendOnly(path: path, owner: clientUID) {
        case .opened(let fd):
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        case .refused(let why):
            log("refusing to open log \(path): \(why)")
            return nil
        }
    }

    // MARK: PrivilegedHelperProtocol

    func version(reply: @escaping (Int) -> Void) {
        reply(kPrivilegedProtocolVersion)
    }

    func startTunnel(protocolName: String,
                     host: String,
                     fingerprint: String,
                     resolve: String,
                     autoAddLocalSubnet: Bool,
                     exceptionRoutes: [String],
                     logPath: String,
                     cookie: String,
                     reply: @escaping (Bool, String) -> Void) {

        // Validate before touching anything, so a bad argument is reported as
        // such rather than as a missing install.
        guard PrivilegedValidation.isValidProtocol(protocolName) else {
            return reply(false, "bad protocol '\(protocolName)'")
        }
        guard PrivilegedValidation.isValidHost(host) else {
            return reply(false, "bad host '\(host)'")
        }
        guard PrivilegedValidation.isValidFingerprint(fingerprint) else {
            return reply(false, "bad fingerprint")
        }
        guard PrivilegedValidation.isValidResolve(resolve) else {
            return reply(false, "bad resolve '\(resolve)'")
        }
        for route in exceptionRoutes where !PrivilegedValidation.isValidCIDR(route) {
            return reply(false, "bad exception route '\(route)'")
        }
        guard !cookie.isEmpty else { return reply(false, "empty cookie") }
        // The log path used to be accepted on the caller's word, checked only for
        // "absolute, no .., ends in .log". That was a root-write redirection: those
        // three properties are all satisfied by a symlink, and the directory holding
        // it belongs to the desktop user, so any process running as that user could
        // point openconnect's root-owned stdout at a file of its choosing — or have
        // root CREATE one anywhere and hand ownership over, which is a straight path
        // to privilege escalation via, say, a LaunchDaemon plist.
        //
        // So the path is no longer information: it is derived from the connected
        // client's uid and the caller's value merely has to agree with it.
        guard let logTarget = expectedLogPath else {
            return reply(false, "cannot resolve the calling user's home directory")
        }
        // The caller's value is not rejected on mismatch, it is simply not used: the
        // two can legitimately differ by an unresolved home prefix, and refusing would
        // turn that into a failed connect rather than a cosmetic difference. Reported
        // so a genuine divergence is visible instead of silent.
        let pathNote = logPath == logTarget ? ""
            : " (ignored requested log path \(logPath), using \(logTarget))"

        if let problem = assertRootOwned(routeWrapperPath) { return reply(false, problem) }
        if let problem = assertRootOwned(vpncScriptPath) { return reply(false, problem) }
        guard let openconnect = findOpenconnect() else {
            return reply(false, "openconnect not found")
        }

        if isTunnelAlive() { return reply(false, "a tunnel is already running") }

        var args = ["--protocol=\(protocolName)", "--cookie-on-stdin", "--timestamp",
                    "--pid-file=\(pidFilePath)"]
        if fingerprint != "-" { args.append("--servercert=\(fingerprint)") }
        if resolve != "-" { args.append("--resolve=\(resolve)") }
        args.append("--script=\(routeWrapperPath)")
        // "--" ends option parsing, so a host can never be read as a flag.
        args.append("--")
        args.append(host)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: openconnect)
        task.arguments = args
        var env = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "ANYWAY_AUTO_SUBNET": autoAddLocalSubnet ? "1" : "0",
            "ANYWAY_VPNC_SCRIPT": vpncScriptPath,
        ]
        if !exceptionRoutes.isEmpty {
            env["ANYWAY_EXCEPTION_ROUTES"] = exceptionRoutes.joined(separator: " ")
        }
        task.environment = env

        let stdinPipe = Pipe()
        task.standardInput = stdinPipe
        // If the log cannot be opened safely, drop the output rather than retrying
        // with an unchecked open — but say so, because a silently vanishing log is
        // a support trap and it is also the signal that someone tampered with it.
        var logNote = pathNote
        if let handle = logHandle(logTarget) {
            task.standardOutput = handle
            task.standardError = handle
        } else {
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            logNote += " (tunnel log disabled: \(logTarget) could not be opened safely)"
        }

        do {
            try task.run()
        } catch {
            return reply(false, "could not launch openconnect: \(error.localizedDescription)")
        }
        // The cookie arrives over XPC and goes straight into the pipe: unlike
        // the shell path it never touches the filesystem at all.
        stdinPipe.fileHandleForWriting.write(Data((cookie + "\n").utf8))
        try? stdinPipe.fileHandleForWriting.close()

        tunnel = task
        writePIDFile(task.processIdentifier)
        log("tunnel started pid=\(task.processIdentifier) host=\(host)\(logNote)")
        reply(true, "started pid \(task.processIdentifier)\(logNote)")
    }

    func stopTunnel(reply: @escaping (Bool, String) -> Void) {
        let pids = knownPIDs()
        guard !pids.isEmpty else { return reply(true, "no tunnel running") }

        // SIGINT asks openconnect to tear the tunnel down gracefully, which
        // includes running the route script for "disconnect" to remove its
        // routes. Escalating on a fixed timer interrupted that mid-spawn
        // ("Failed to spawn script ... Interrupted system call") and left routes
        // behind, so wait for it and only escalate if genuinely stuck.
        for pid in pids { kill(pid, SIGINT) }
        var waited = 0.0
        while waited < 10.0, pids.contains(where: { isAlive($0) }) {
            usleep(250_000); waited += 0.25
        }
        let stubborn = pids.filter { isAlive($0) }
        if !stubborn.isEmpty {
            log("still alive after 10s, escalating to SIGTERM: \(stubborn)")
            for pid in stubborn { kill(pid, SIGTERM) }
        }
        tunnel = nil
        try? FileManager.default.removeItem(atPath: pidFilePath)
        reply(true, stubborn.isEmpty ? "stopped" : "stopped (escalated)")
    }

    func tunnelStatus(reply: @escaping (Bool, Int) -> Void) {
        let pid = knownPIDs().first { isAlive($0) }
        reply(pid != nil, Int(pid ?? 0))
    }

    func restoreDefaultRoute(gateway: String, interface: String,
                             reply: @escaping (Bool, String) -> Void) {
        guard PrivilegedValidation.isValidIPv4(gateway) else {
            return reply(false, "bad gateway '\(gateway)'")
        }
        if !interface.isEmpty, !PrivilegedValidation.isValidInterface(interface) {
            return reply(false, "bad interface '\(interface)'")
        }
        run("/sbin/route", ["-n", "delete", "default"])
        if !interface.isEmpty {
            run("/sbin/route", ["-n", "add", "default", gateway, "-ifscope", interface])
        }
        run("/sbin/route", ["-n", "add", "default", gateway])
        log("restored default via \(gateway) \(interface)")
        reply(true, "restored default via \(gateway)")
    }

    // MARK: Process helpers

    private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    private func isTunnelAlive() -> Bool { knownPIDs().contains { isAlive($0) } }

    /// The in-memory handle is the fast path; the pid file covers the case where
    /// launchd restarted this daemon while the tunnel kept running (openconnect
    /// is reparented to launchd rather than dying with us).
    private func knownPIDs() -> [pid_t] {
        var pids: [pid_t] = []
        if let task = tunnel, task.isRunning { pids.append(task.processIdentifier) }
        if let text = try? String(contentsOfFile: pidFilePath, encoding: .utf8),
           let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            if !pids.contains(pid) { pids.append(pid) }
        }
        return pids
    }

    private func writePIDFile(_ pid: pid_t) {
        try? "\(pid)\n".write(toFile: pidFilePath, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func run(_ path: String, _ args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return -1 }
        task.waitUntilExit()
        return task.terminationStatus
    }
}

// MARK: - Listener

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The whole point of this daemon: only our correctly-signed app may
        // talk to it. Without this any local process could drive root
        // operations, which is precisely the weakness of a NOPASSWD sudo rule.
        guard let requirement = clientCodeRequirement() else {
            // No team means we cannot identify callers at all; refuse rather
            // than accept an unauthenticated peer with root powers.
            log("refusing connection: this build is not Developer ID signed")
            return false
        }
        connection.setCodeSigningRequirement(requirement)

        connection.exportedInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
        connection.exportedObject = PrivilegedService(clientUID: connection.effectiveUserIdentifier)
        connection.resume()
        log("accepted connection from uid \(connection.effectiveUserIdentifier)")
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: currentCodeIdentity()?.identifier ?? "")
listener.delegate = delegate
log("listening on \(currentCodeIdentity()?.identifier ?? "<unsigned>") (protocol v\(kPrivilegedProtocolVersion))")
listener.resume()
RunLoop.main.run()
