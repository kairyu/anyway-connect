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

    // MARK: Serialisation of route-affecting work

    /// Serialises ALL route-affecting privileged work — reconcile against reconcile,
    /// reconcile against restoreDefaultRoute, and reconcile against startTunnel.
    ///
    /// Static, not per-instance: the listener creates one PrivilegedService per
    /// connection, so an instance lock would not serialise two concurrent callers.
    ///
    /// Named for what it has to cover rather than for reconcile. The reconcile gate is a
    /// point-in-time check, so without this a user pressing Connect during a launch-time
    /// reconcile gets openconnect installing routes while the sweep deletes them and the
    /// install re-points the default.
    ///
    /// A SEMAPHORE, not an NSLock, and that is a deliberate choice of primitive: NSLock
    /// is documented as requiring the unlock to come from the thread that locked, and
    /// these three operations do not all acquire and release on one thread — reconcile
    /// and restoreDefaultRoute acquire on `mutationQueue` and reply from it, while
    /// startTunnel acquires on the XPC handler thread. DispatchSemaphore has no such
    /// thread affinity, and `wait(timeout:)` gives both shapes needed from one object:
    /// `.now()` for "refuse immediately" and `.now() + 5` for a short bounded wait.
    /// Cross-thread `signal()` is explicitly supported; cross-thread `NSLock.unlock()`
    /// is undefined behaviour — and this is the lock that keeps a route sweep out of a
    /// connect, in a root daemon.
    private static let mutationGate = DispatchSemaphore(value: 1)

    /// Serves reconcile AND restoreDefaultRoute; serial, so the two cannot interleave
    /// even before the gate is consulted. Two reconciles (launch plus wake) are
    /// therefore serialised rather than refused: the second re-probes and plans against
    /// the table the first left, which on any machine the first repaired is an empty
    /// plan and a sub-second no-op.
    private static let mutationQueue =
        DispatchQueue(label: "me.kairyu.anywayconnect.privhelper.mutation")

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

        // Join the mutation gate, so a Connect cannot spawn openconnect into a running
        // reconcile — the sweep would delete the routes openconnect is installing and
        // the install would re-point the default underneath it.
        //
        // A timed wait rather than `.now()`: a short wait absorbs the common overlap (a
        // launch reconcile on a mostly-clean table finishes in well under a second),
        // while a 5 s ceiling keeps the failure honest and bounded instead of queueing a
        // connect behind a 60 s sweep. The app surfaces this message through its
        // existing connect-failure path, and treats it as TERMINAL rather than falling
        // back to the ungated shell `tunnel` subcommand.
        //
        // Taken on the XPC handler thread, which is safe here because this body is short
        // and nothing the app polls is queued behind it. The semaphore, not NSLock, is
        // what makes acquiring here and releasing elsewhere legitimate.
        guard Self.mutationGate.wait(timeout: .now() + 5) == .success else {
            return reply(false, "a reconcile is in progress; try again in a moment")
        }
        defer { Self.mutationGate.signal() }

        // The snapshot has to be taken BEFORE openconnect rewrites routing — once the
        // tunnel is up, the physical default is gone and there is nothing left to record.
        let preIfaces = NetProbe.interfaces()
        let preRoutes = NetProbe.routeTable()
        let preDefault = NetReconcile.physicalDefault(routeTable: preRoutes,
                                                      interfaces: preIfaces)
        // Somebody else's tunnels. Recorded as a COMPLEMENT rather than "our utun"
        // because at this moment our utun does not exist yet: openconnect has not
        // authenticated, let alone created it, and the daemon has no later hook.
        let preTunnels = preIfaces.filter { $0.isTunnelLike }.map(\.name)

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
        writeNetState(preDefault, exceptionRoutes: exceptionRoutes,
                      pid: task.processIdentifier, preexistingTunnels: preTunnels)
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
        // The ONLY remover of the netstate. Reconcile deliberately leaves it: every
        // later reconcile in this boot needs its tunnel scope and install hint, and a
        // stale advisory is already fenced by the same-interface-and-subnet precondition
        // and then by the guard.
        try? FileManager.default.removeItem(atPath: NetState.path)
        reply(true, stubborn.isEmpty ? "stopped" : "stopped (escalated)")
    }

    func tunnelStatus(reply: @escaping (Bool, Int) -> Void) {
        let pid = knownPIDs().first { isAlive($0) }
        reply(pid != nil, Int(pid ?? 0))
    }

    /// Validation on the handler thread; everything after it on `mutationQueue`.
    ///
    /// The hop is not tidiness. This body is four NetProbe collectors at 5 s plus up to
    /// three `route` calls at 5 s — the 30 s worst case the client timeout is derived
    /// from — so running it synchronously would head-of-line block the `version()`
    /// probes behind it (1.5 s and 3 s timeouts) and flip the app's transport to sudo in
    /// the middle of a teardown. The gate is then acquired on that queue, so acquire and
    /// release happen on one thread.
    ///
    /// The empty-interface case the old implementation tolerated is gone: with no
    /// interface there is nothing to derive from, so it is a validation failure rather
    /// than a half-restore.
    func restoreDefaultRoute(interface: String, reply: @escaping (Bool, String) -> Void) {
        guard PrivilegedValidation.isValidInterface(interface),
              PrivilegedValidation.isRestoreTargetInterface(interface) else {
            return reply(false, "bad interface '\(interface)'")
        }
        Self.mutationQueue.async { self.restoreLocked(interface: interface, reply: reply) }
    }

    private func restoreLocked(interface: String, reply: @escaping (Bool, String) -> Void) {
        guard Self.mutationGate.wait(timeout: .now() + 5) == .success else {
            return reply(false, "a privileged route mutation is in progress; retry")
        }
        defer { Self.mutationGate.signal() }

        // No gateway was transmitted, so there is nothing to replay: the next hop is
        // derived here, from this machine as it is now, and must pass the guard.
        let ifaces = NetProbe.interfaces()
        let derivation = deriveDefaultGateway(interface: interface,
                                              interfaces: ifaces,
                                              dhcpRouter: NetProbe.dhcpRouter(for: interface),
                                              routeTable: NetProbe.routeTable(),
                                              netstate: NetState.load())
        guard let accepted = derivation.accepted else {
            // No candidate survived the guard, so NO route command runs at all. Not even
            // the delete: leaving a wrong default in place is recoverable, whereas
            // deleting the only default and then failing to install one is the blackhole
            // this change exists to prevent.
            let why = "refusing to restore default via \(interface): "
                    + derivation.transcript.joined(separator: "; ")
            log(why)
            return reply(false, why)
        }

        // The precondition is re-checked HERE, privileged-side, rather than trusted from
        // the app (which evaluates it too, but only to avoid a pointless round trip).
        // The daemon trusts no caller-established fact, and an untargeted
        // `route delete default` on a host with Ethernet AND Wi-Fi up would otherwise
        // delete a perfectly good default via en1 and replace it with one via en0.
        let current = NetProbe.currentDefaultInterface()
        let currentIsTunnel = current.flatMap { name in
            ifaces.first { $0.name == name }?.isTunnelLike
        } ?? false
        let mayDeleteUnscoped = (current == nil) || (current == interface) || currentIsTunnel
        if mayDeleteUnscoped {
            run("/sbin/route", ["-n", "delete", "default"], timeout: 5)
        }
        // The scoped form is always (re)installed: naming -ifscope <interface> cannot
        // affect another interface's routing, and an EEXIST here is harmless.
        run("/sbin/route", ["-n", "add", "default", accepted.gateway, "-ifscope", interface],
            timeout: 5)
        // Unconditional, and EXPECTED to fail with EEXIST when another link owns the
        // unscoped default — that is why the branch is reported rather than the status.
        // It is also the add that restores service for ordinary traffic, so skipping it
        // when the delete above was declined would leave the repair half-done.
        run("/sbin/route", ["-n", "add", "default", accepted.gateway], timeout: 5)

        let note = mayDeleteUnscoped
            ? "replaced the unscoped default (was \(current ?? "none"))"
            : "left the unscoped default via \(current ?? "?") alone (EEXIST expected)"
        log("restored default via \(accepted.gateway) \(interface): \(note) "
            + "[\(derivation.transcript.joined(separator: "; "))]")
        reply(true, "restored default via \(accepted.gateway) (\(interface)) "
                  + "from \(accepted.source.rawValue); \(note)")
    }

    // MARK: Reconcile

    func reconcile(dryRun: Bool, reply: @escaping (Bool, String) -> Void) {
        // Reply from a worker so the XPC handler returns immediately. NSXPC delivers one
        // connection's messages serially and the client caches a single connection, so a
        // long synchronous apply here would head-of-line block `version()` — whose
        // callers use 1.5 s and 3 s timeouts — and flip the app's transport to sudo while
        // Settings showed "no reply from daemon" for the duration.
        //
        // The gate is acquired INSIDE the worker, so acquire and release happen on the
        // same queue. One hop costs nothing and buys a primitive whose ownership rules
        // are not being bent.
        Self.mutationQueue.async {
            guard Self.mutationGate.wait(timeout: .now()) == .success else {
                return reply(false, "a privileged route mutation is in progress")
            }
            defer { Self.mutationGate.signal() }

            // The single safety-critical gate. A frozen-but-alive openconnect counts as
            // alive, which is correct: dismantling the routing of a tunnel that may
            // still recover is the one thing this operation must never do.
            switch NetReconcile.gate(pids: self.livePIDs(), isAlive: self.isAlive) {
            case .noop(let pid):
                let message = "tunnel alive (pid \(pid)) — nothing to do"
                log("reconcile: gate=noop, \(message)")
                // (true, …): nothing failed and there was nothing to do, so a wake
                // handler must not treat this as an error.
                return reply(true, message)
            case .proceed:
                break
            }

            let plan = NetReconcile.plan(routeTable: NetProbe.routeTable(),
                                         interfaces: NetProbe.interfaces(),
                                         configdKeys: NetProbe.configdServiceKeys(),
                                         netstate: NetState.load())
            log("reconcile: gate=proceed, plan \(plan.actions.count) actions, "
                + "\(plan.kept.count) kept, abort=\(plan.abort.map(String.init(describing:)) ?? "none")"
                + (dryRun ? " [DRY RUN]" : ""))
            // Only the kept entries that record a DECISION about scope or withholding.
            // The per-route ones are the other hundred-odd and are already summarised by
            // the count above; printing them all would bury the three that matter.
            for kept in plan.kept {
                switch kept {
                case .foreignTunnel, .widenedToAllTunnels, .ambiguousInstallTarget,
                     .physicalDefaultUnusable, .defaultDeletionsWithheld:
                    log("reconcile:   \(kept)")
                default:
                    continue
                }
            }

            let transcript = self.applyReconcile(plan, dryRun: dryRun)
            // The full transcript always goes to the log; only the reply is capped.
            for line in transcript { log("reconcile:   \(line)") }
            // The netstate is deliberately NOT removed here — stopTunnel owns its
            // lifetime. Deleting it would disarm its tunnel scope and install-target
            // hint for the rest of the boot, so the next wake and the next Wi-Fi hop
            // would plan widened to every utun on the machine.
            reply(true, Self.cap(transcript))
        }
    }

    /// 8 KiB, head kept: a 256-route transcript is longer than anything worth carrying
    /// over XPC, and the part that explains what happened is at the top.
    private static func cap(_ lines: [String], limit: Int = 8 * 1024) -> String {
        var kept: [String] = []
        var size = 0
        for (index, line) in lines.enumerated() {
            if size + line.utf8.count + 1 > limit {
                return kept.joined(separator: "\n")
                    + "\n… (\(lines.count - index) more lines in the daemon log)"
            }
            kept.append(line)
            size += line.utf8.count + 1
        }
        return kept.joined(separator: "\n")
    }

    /// Execution of a plan, and the ONLY place in the tree that runs a mutating route or
    /// scutil command. Nothing compiled into the app can reach this, which is what makes
    /// "the app cannot mutate routing" checkable by inspection rather than by argument.
    private func applyReconcile(_ plan: ReconcilePlan, dryRun: Bool) -> [String] {
        var lines: [String] = []
        let cmds = NetReconcile.commands(for: plan)

        // Phase 1 — ESSENTIAL. Budgeted only so a pathological machine cannot hold the
        // mutation gate forever; the realistic content is one scutil call and 2-18
        // route calls.
        runPhase(cmds.prologue, label: "prologue", budget: 15, into: &lines, dryRun: dryRun,
                 installCandidateNote: plan.installCandidateNote)

        // Phase 2 — ESSENTIAL, unconditional, and deliberately BEFORE the sweep. With
        // the install last, the machine sat with the tunnel default deleted and no
        // replacement for the whole sweep window — seconds of exactly the outage this
        // operation exists to end. No deadline check precedes this loop.
        runPhase(cmds.install, label: "install", budget: nil, into: &lines, dryRun: dryRun,
                 installCandidateNote: plan.installCandidateNote)

        // Phase 3 — BEST EFFORT. A carried-home sweep is ~117 destinations ≈ 234 route
        // invocations. Exhausting the budget truncates the sweep and NOTHING ELSE; the
        // stale exception routes left behind are inert, because the default they were
        // exceptions to has already been replaced.
        let swept = runPhase(cmds.sweep, label: "sweep", budget: 20, into: &lines,
                             dryRun: dryRun,
                             installCandidateNote: plan.installCandidateNote)
        if swept < cmds.sweep.count {
            lines.append("budget exhausted after \(swept)/\(cmds.sweep.count) sweep "
                       + "deletions; the install already ran")
        }
        return lines
    }

    /// Returns how many commands it executed. The deadline, when there is one, is checked
    /// BETWEEN commands — each individual command is bounded by its own `run` timeout, so
    /// a wedged `route` cannot overrun the phase by more than one command's worth.
    @discardableResult
    private func runPhase(_ commands: [ReconcileCommand], label: String,
                          budget: TimeInterval?, into lines: inout [String],
                          dryRun: Bool, installCandidateNote: String?) -> Int {
        let deadline = budget.map { Date().addingTimeInterval($0) }
        var executed = 0
        for command in commands {
            if let deadline, Date() >= deadline { break }
            switch command {
            case .scutil(let stdin, let keys):
                lines.append(record(dryRun,
                                    "scutil remove \(keys.count) keys "
                                    + "(\(keys.joined(separator: ", ")))",
                                    { self.run("/usr/sbin/scutil", [], stdin: stdin,
                                               timeout: 10) }))

            case .route(let argv):
                lines.append(record(dryRun, "route \(argv.joined(separator: " "))",
                                    { self.run("/sbin/route", argv, timeout: 5) }))

            case .deleteUnscopedDefaultWhileInterface(let netif, let maxIterations):
                // The one state-dependent command: delete the unscoped default, but only
                // while the kernel still answers this interface for it. Bounded, because
                // a kernel that keeps answering the same interface after a successful
                // delete would otherwise spin here forever.
                var removed = 0
                while removed < maxIterations,
                      NetProbe.currentDefaultInterface() == netif {
                    guard !dryRun else {
                        lines.append("would: route -n delete default (on \(netif))")
                        break
                    }
                    guard run("/sbin/route", ["-n", "delete", "default"], timeout: 5) == 0 else {
                        break
                    }
                    removed += 1
                }
                lines.append("unscoped default on \(netif): \(removed) removed; current "
                           + "default now " + (NetProbe.currentDefaultInterface() ?? "none"))

            case .deriveAndInstallDefault(let iface):
                // Re-probe. The plan's inputs were the CLASSIFICATION snapshot; the
                // prologue has since deleted routes, so candidate 2 must be read from
                // the table as the prologue left it, not as the planner saw it.
                let derivation = deriveDefaultGateway(
                    interface: iface,
                    interfaces: NetProbe.interfaces(),
                    dhcpRouter: NetProbe.dhcpRouter(for: iface),
                    routeTable: NetProbe.routeTable(),
                    netstate: NetState.load())
                lines.append("install default (\(iface)) plan-time candidates: "
                           + (installCandidateNote ?? "n/a"))
                lines += derivation.transcript.map { "  apply-time: \($0)" }
                guard let accepted = derivation.accepted else {
                    lines.append("install default (\(iface)) REFUSED — routing left as "
                               + "the prologue left it")
                    break                                 // no route call at all
                }
                if !dryRun {
                    // Scoped first, then unscoped. An EEXIST on the scoped add is
                    // expected and harmless when a correct -ifscope row survived; the
                    // UNSCOPED add is the one that restores service for ordinary traffic.
                    run("/sbin/route", ["-n", "add", "default", accepted.gateway,
                                        "-ifscope", iface], timeout: 5)
                    run("/sbin/route", ["-n", "add", "default", accepted.gateway], timeout: 5)
                }
                lines.append((dryRun ? "would: " : "")
                           + "install default \(accepted.gateway) (\(iface)) "
                           + "from \(accepted.source.rawValue)")
            }
            executed += 1
        }
        if let deadline, Date() >= deadline, executed < commands.count {
            lines.append("\(label): budget of \(Int(budget ?? 0))s exhausted")
        }
        return executed
    }

    /// Prefixes `would: ` and executes NOTHING when `dryRun` is set; otherwise appends the
    /// exit status. A non-zero exit on one command never stops the rest — the actions are
    /// independent repairs, and `route`'s "not in table" is a normal answer here.
    private func record(_ dryRun: Bool, _ description: String, _ body: () -> Int32) -> String {
        guard !dryRun else { return "would: \(description)" }
        let status = body()
        return "\(description) -> \(status == 0 ? "ok" : "rc=\(status)")"
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

    /// The reconcile gate's input, widened at the INPUT only — the pure gate itself is
    /// untouched.
    ///
    /// `knownPIDs()` reads the in-memory handle (always nil here: the listener builds a
    /// fresh PrivilegedService per connection) and /var/run/anyway-connect.pid, which
    /// `stopTunnel` removes even when it had to escalate to SIGTERM and the process
    /// survived. A reparented, still-live openconnect would therefore be invisible and
    /// the sweep could run under a live tunnel.
    ///
    /// `pgrep` is the same judgement the app already makes, by the same pattern, so the
    /// two cannot drift — and it can only make the gate MORE conservative. `capture` is
    /// the shared bounded runner (fixed absolute path, fixed PATH, 5 s, output capped,
    /// null stdin), so there is no second process helper here either.
    private func livePIDs() -> [pid_t] {
        var pids = Set(knownPIDs())
        let out = capture("/usr/bin/pgrep",
                          ["-f", "openconnect .*(route-wrapper\\.sh|--cookie-on-stdin)"],
                          timeout: 5)
        pids.formUnion(out.split(whereSeparator: \.isNewline).compactMap {
            pid_t($0.trimmingCharacters(in: .whitespaces))
        })
        return pids.sorted()
    }

    private func writePIDFile(_ pid: pid_t) {
        try? "\(pid)\n".write(toFile: pidFilePath, atomically: true, encoding: .utf8)
    }

    /// Record what the physical network looked like before this tunnel existed.
    ///
    /// Atomic, and it fails SILENTLY to the caller but loudly to the log: a missing
    /// netstate only degrades a later reconcile, and must never fail a connect.
    ///
    /// `O_EXCL|O_NOFOLLOW` on the temp file, because /var/run is group-writable by
    /// `daemon` and a member of that group could otherwise squat the temp name between
    /// the unlink and the open. O_EXCL turns that into a failed write rather than a
    /// hijacked one. Created 0600 and widened to 0644 through the DESCRIPTOR once the
    /// content is ours — the unprivileged app reads this file, and its own hardening is
    /// ownership-based.
    private func writeNetState(_ physical: (interface: String, gateway: String, subnet: String)?,
                               exceptionRoutes: [String],
                               pid: pid_t,
                               preexistingTunnels: [String]) {
        guard let physical else {
            // A tunnel-scope-only record would be useful, but `decode` rejects an empty
            // physicalInterface and carrying a second shape of this file is not worth
            // it. Say so rather than leave a silent gap.
            log("no physical default route at connect time — no netstate written; a later "
                + "reconcile will plan without a tunnel scope or an install hint")
            return
        }
        let state = NetState(writtenAt: Date(),
                             physicalInterface: physical.interface,
                             physicalSubnet: physical.subnet,
                             physicalGatewayAdvisory: physical.gateway,
                             exceptionRoutes: exceptionRoutes,
                             tunnelPID: Int(pid),
                             preexistingTunnels: preexistingTunnels)
        guard let data = try? NetState.encoder().encode(state) else {
            log("could not encode netstate — skipped")
            return
        }
        let tmp = NetState.path + ".tmp"
        unlink(tmp)                                   // ENOENT is the expected case
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            log("could not open \(tmp): \(String(cString: strerror(errno))) — no netstate")
            return
        }
        var ok = true
        data.withUnsafeBytes { raw in
            var written = 0
            while written < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: written), raw.count - written)
                guard n > 0 else { ok = false; return }
                written += n
            }
        }
        if ok { ok = fchmod(fd, 0o644) == 0 }
        close(fd)
        guard ok, rename(tmp, NetState.path) == 0 else {
            unlink(tmp)
            log("could not write netstate: \(String(cString: strerror(errno)))")
            return
        }
        log("netstate: \(physical.interface) \(physical.subnet) via \(physical.gateway), "
            + "pre-existing tunnels [\(preexistingTunnels.joined(separator: ", "))]")
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

    /// Same shape as `run(_:_:)`, plus a wall-clock bound and optional stdin.
    ///
    /// The bound is what keeps the mutation gate releasable: every command the reconcile
    /// apply runs goes through here, so a wedged `route` or `scutil` can hold the gate
    /// for its own timeout and no longer. `-2` is the overrun, distinct from `-1`'s
    /// "could not even launch" and from any status a child could return.
    ///
    /// stdin is a parameter because `scutil` takes its commands there and nowhere else.
    @discardableResult
    private func run(_ path: String, _ args: [String],
                     stdin: String? = nil, timeout: TimeInterval) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        let inPipe: Pipe? = stdin == nil ? nil : Pipe()
        task.standardInput = inPipe ?? FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in done.signal() }
        do { try task.run() } catch { return -1 }

        if let inPipe, let stdin {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            kill(task.processIdentifier, SIGKILL)
            // Bounded: SIGKILL cannot be caught, so this returns promptly. Capped anyway
            // rather than waited on unconditionally.
            _ = done.wait(timeout: .now() + 2)
            log("killed \(path) after \(Int(timeout))s")
            return -2
        }
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
