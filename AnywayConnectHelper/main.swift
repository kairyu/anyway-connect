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

// MARK: - The two /var/run state files

/// The hardened writer for BOTH state files — the netstate and the attribution
/// record — so there is not a second copy of this hardening to keep in step.
///
/// Atomic, and it fails SILENTLY to the caller but loudly to the log: a missing
/// state file only degrades a later reconcile, and must never fail a connect.
///
/// `O_EXCL | O_NOFOLLOW` on the temp file, because /var/run is group-writable by
/// `daemon` and a member of that group could otherwise squat the temp name
/// between the unlink and the open. O_EXCL turns that into a failed write rather
/// than a hijacked one — which is why a failed write is an anticipated path here
/// and not a hypothetical one. Created 0600 and widened to 0644 through the
/// DESCRIPTOR once the content is ours: the unprivileged app reads these files,
/// and its own hardening is ownership-based.
///
/// A free function rather than a method because the attribution observer runs
/// from inside a queue closure, where only a free or static function can be
/// called bare.
@discardableResult
private func writeStateFile(path: String, data: Data, label: String) -> Bool {
    let tmp = path + ".tmp"
    unlink(tmp)                                   // ENOENT is the expected case
    let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else {
        log("could not open \(tmp): \(String(cString: strerror(errno))) — no \(label)")
        return false
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
    guard ok, rename(tmp, path) == 0 else {
        unlink(tmp)
        log("could not write \(label): \(String(cString: strerror(errno)))")
        return false
    }
    return true
}

/// Writes THIS session's attribution record: who we are, before we know which
/// interface is ours.
///
/// The caller unlinks the path first, so absence — the fail-closed state — is
/// what a failed write leaves behind rather than the previous session's claim.
/// `ourTunnel` is nil and the note is "pending" until the observer resolves it.
private func writeAttributionRecord(pid: pid_t, startedAt: Date, token: String) -> Bool {
    let record = TunnelAttribution(startedAt: startedAt,
                                   sessionToken: token,
                                   tunnelPID: Int(pid),
                                   attributionNote: "pending")
    guard let data = try? TunnelAttribution.encoder().encode(record) else {
        log("could not encode the attribution record — reconcile will plan dead-only")
        return false
    }
    return writeStateFile(path: TunnelAttribution.path, data: data, label: "attribution record")
}

/// Applies one observation tick to the record and writes it back.
///
/// A FREE FUNCTION at file scope, like `observeOurTunnel`, and for the same
/// reason: it is called bare inside a queue closure, which only compiles for a
/// free or static function, and an instance member would retain the
/// per-connection `PrivilegedService` past its connection.
private func writeAttribution(_ record: inout TunnelAttribution, _ tick: AttributionTick) {
    switch tick.outcome {
    case .resolved(let name):
        record.ourTunnel = name
        record.ourTunnelObservedAt = Date()
        // Only ever SET, never cleared by a later tick: once witnessed, the
        // address is the fact that lets a lingering interface be attributed.
        if let address = tick.ourTunnelIPv4 { record.ourTunnelIPv4 = address }
    case .pending, .ambiguous, .processExited, .timedOut:
        record.ourTunnel = nil
        record.ourTunnelIPv4 = nil
    }
    record.attributionNote = tick.attributionNote
    guard let data = try? TunnelAttribution.encoder().encode(record) else {
        log("could not encode the attribution record — leaving the previous one")
        return
    }
    guard writeStateFile(path: TunnelAttribution.path, data: data,
                         label: "attribution record") else { return }
    log("attribution: \(tick.outcome) ourTunnel=\(record.ourTunnel ?? "nil") "
        + "ipv4=\(record.ourTunnelIPv4 ?? "nil") note=\(record.attributionNote ?? "nil")")
}

/// The netif holding the UNSCOPED default right now, for the ambiguity
/// tie-break only. Read through the shared bounded `capture` runner, once, at
/// the deadline — never on every tick.
private func unscopedDefaultNetifNow() -> String? {
    NetReconcile.parseRouteTable(NetProbe.routeTable())
        .first { $0.destination == .defaultRoute && !$0.isIfScoped }?.netif
}

/// Watch for OUR tunnel to appear, then keep watching until it carries an
/// address.
///
/// This is the hook `preexistingTunnels` existed because the daemon did not
/// have: at `startTunnel` time our `utun` does not exist yet — the record is
/// written milliseconds after `task.run()`, before openconnect has
/// authenticated — so the one positive fact worth recording cannot be recorded
/// then. It can be recorded 500 ms to a few seconds later, from inside the
/// daemon, with no new XPC operation and therefore no protocol bump.
///
/// FREE FUNCTION at file scope (not a method on PrivilegedService): the listener
/// builds one service per XPC connection, so a method would need an explicit
/// `self.` inside the queue closure and would retain the service past the
/// connection. Everything it needs arrives as a parameter. It executes no
/// process in the common case, mutates no routing, takes no lock and never
/// touches the mutation gate.
///
/// It does NOT stop at `.resolved`: a `utun` appears before `vpnc-script`
/// assigns its address, so the witness lands on a later tick than the name. It
/// keeps polling until the resolved name carries an IPv4 — or the deadline
/// passes, leaving `"addressPending"` and a session that degrades to dead-only.
///
/// 60 s is a ceiling, not an expectation: the cookie is already on stdin when
/// `task.run()` happens, so authentication is done. The top-end cost is 120
/// `getifaddrs` calls spread over a minute plus, on the ambiguous path only, one
/// `netstat`.
private func observeOurTunnel(pid: pid_t, startedAt: Date, preexisting: Set<String>,
                              deadline: TimeInterval = 60,
                              onTick: @escaping (AttributionTick) -> Void) {
    let began = Date()
    log("observing for our tunnel: pid \(pid), session started "
        + "\(ISO8601DateFormatter().string(from: startedAt)), deadline \(Int(deadline))s")
    // Seeded with what `startTunnel` has just written, so an unchanged tick
    // writes nothing: the record is rewritten when the ANSWER changes, not 120
    // times per session.
    var last: AttributionTick? = AttributionTick(outcome: .pending, ourTunnelIPv4: nil,
                                                 attributionNote: "pending")
    while true {
        let elapsed = Date().timeIntervalSince(began)
        let interfaces = NetProbe.interfaces()
        let nowTunnelLike = interfaces.filter(\.isTunnelLike).map(\.name)
        let newNames = nowTunnelLike.filter { !preexisting.contains($0) }
        // Read ONLY when it can decide something: at the deadline, with a tie.
        let defaultNetif = (elapsed >= deadline && newNames.count >= 2)
            ? unscopedDefaultNetifNow() : nil

        let tick = TunnelAttribution.attributionOutcome(
            preexisting: preexisting,
            nowTunnelLike: nowTunnelLike,
            addressOf: { name in interfaces.first { $0.name == name }?.ipv4?.text },
            defaultRouteNetif: defaultNetif,
            // kill(pid, 0) from ROOT, where it means what it says. The app-side
            // liveness check cannot use it — openconnect runs as root and the
            // app as uid 504, so EPERM there reads a live tunnel as dead.
            processAlive: kill(pid, 0) == 0,
            elapsed: elapsed,
            deadline: deadline)

        if tick != last {
            onTick(tick)
            last = tick
        }
        switch tick.outcome {
        case .ambiguous, .processExited, .timedOut:
            return
        case .resolved:
            if tick.ourTunnelIPv4 != nil { return }      // name AND witness: done
        case .pending:
            break
        }
        if elapsed >= deadline { return }
        Thread.sleep(forTimeInterval: 0.5)
    }
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

    /// EVERY write to the attribution record goes through this queue, and the
    /// generation counter lives on it too.
    ///
    /// One writer FAMILY — the observer — because the stop path does not touch
    /// that record at all, so there is no second read-modify-write writer to
    /// order against. What this does close is the reconnect interleave: the app
    /// auto-reconnects on its 8 s poll and the listener builds a fresh service
    /// per connection, so without the counter a session-A observer could write
    /// `timedOut` over session B's record forty seconds later.
    private static let attributionQueue =
        DispatchQueue(label: "me.kairyu.anywayconnect.privhelper.attribution")
    /// `attributionQueue` only.
    private static var attributionGeneration = 0

    /// The 500 ms polling loop runs HERE instead, so a 60 s observation never
    /// occupies the writing queue.
    private static let observerQueue =
        DispatchQueue(label: "me.kairyu.anywayconnect.privhelper.observer")

    /// ONE literal, because the reconcile gate ("do not touch routing") and the
    /// stop ("what to signal") must agree about what an openconnect of ours
    /// looks like. Its twin is `VPNRunner.openconnectPattern`; the harness
    /// runner asserts there is exactly one occurrence of it in each file.
    ///
    /// Note it is weaker than `TunnelStop.isOurOpenconnect`, which requires BOTH
    /// markers: this is the SCAN, and identity is established afterwards.
    private static let openconnectPattern =
        "openconnect .*(route-wrapper\\.sh|--cookie-on-stdin)"

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

        // The attribution record, and the observer that fills it in.
        //
        // UNLINK FIRST. Absence is the fail-closed state, so the previous
        // session's claim is retired BEFORE this one is written: a failed write
        // must never leave a record describing a session that has ended —
        // possibly with a witness address the next reconcile would read as this
        // session's identity. The write failure is designed for rather than
        // hypothetical (writeStateFile's O_EXCL), and it must never fail a
        // connect: we log it and still reply `started pid N`.
        unlink(TunnelAttribution.path)
        let pid = task.processIdentifier
        let startedAt = Date()
        let sessionToken = UUID().uuidString
        if !writeAttributionRecord(pid: pid, startedAt: startedAt, token: sessionToken) {
            log("no attribution record for this session — reconcile will plan dead-only")
        }
        // Captured by value for the observer: nothing it touches may be read off
        // the per-connection service, which goes away with the connection.
        let preTunnelSet = Set(preTunnels)
        Self.attributionQueue.async {
            // Bumped unconditionally, including after a failed write: it is what
            // retires the PREVIOUS session's observer, and that has to happen
            // whether or not this session got a record.
            Self.attributionGeneration += 1
            let mine = Self.attributionGeneration
            Self.observerQueue.async {
                observeOurTunnel(pid: pid, startedAt: startedAt,
                                 preexisting: preTunnelSet) { tick in
                    Self.attributionQueue.async {
                        guard mine == Self.attributionGeneration else {
                            log("attribution tick dropped: superseded by a newer session")
                            return
                        }
                        // NEVER a Date comparison: the pinned encoder emits whole
                        // seconds, so `startedAt` cannot be a session key. The
                        // token can, and is.
                        guard var current = TunnelAttribution.load(note: { log($0) }),
                              current.tunnelPID == Int(pid),
                              current.sessionToken == sessionToken else {
                            log("attribution tick dropped: the record on disk is not ours")
                            return
                        }
                        writeAttribution(&current, tick)
                    }
                }
            }
        }

        log("tunnel started pid=\(task.processIdentifier) host=\(host)\(logNote)")
        reply(true, "started pid \(task.processIdentifier)\(logNote)")
    }

    /// Runs OFF the XPC handler thread and NOT under `mutationGate`.
    ///
    /// Off the gate: a stop must never be refused because a reconcile holds it. It
    /// is safe without it — reconcile's own gate no-ops while an openconnect is
    /// alive, and once one is dead this function only signals pids and removes two
    /// small files.
    ///
    /// Off the handler thread: the body is now a `pgrep` (5 s), an optional `ps`
    /// (3 s), a 10 s SIGINT wait and a 5 s SIGTERM wait, so running it inline would
    /// head-of-line block the app's `version()` probes (1.5 s and 3 s) and flip the
    /// transport to sudo in the middle of a teardown.
    ///
    /// CONCURRENT, not a serial queue of its own. Two stops can genuinely be in
    /// flight: `handleWillSleep` calls `boundedTeardown(limit: 5)`, which returns on
    /// expiry BY DESIGN and lets its `teardownNow()` carry on, and a wake sequence or
    /// a menu Disconnect then issues a second `stopTunnel`. On a serial queue the
    /// second would wait behind the first — 23 + 23 = 46 s against the client's
    /// 30 s — and be reported as an unreachable daemon, dropping the transport cache
    /// for a reason unrelated to the daemon's health.
    ///
    /// Concurrency cannot shorten the graceful window, which is the property the
    /// signal sequence depends on: each stop waits its own 10 s from its own SIGINT,
    /// so the earliest possible SIGTERM is still 10 s after the earliest SIGINT. A
    /// late stop's SIGINT arriving mid-wait is harmless and cannot pull an
    /// escalation forward. Everything else it touches is per-connection (`tunnel` is
    /// an instance property of a per-connection service), idempotent (`kill` of a
    /// gone pid is `ESRCH`, an absent file is the desired end state) or fenced
    /// below.
    func stopTunnel(reply: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { self.stopNow(reply: reply) }
    }

    private func stopNow(reply: @escaping (Bool, String) -> Void) {
        let targets = TunnelStop.targets(
            inMemory: tunnel?.isRunning == true ? tunnel?.processIdentifier : nil,
            pidFile: pidsFromFile(),
            pgrep: pgrepPIDs(),
            isAlive: isAlive,
            identify: { self.identifyPID($0) })

        guard !targets.signal.isEmpty else {
            // Nothing of ours is running. A pid file naming only gone-or-dead
            // entries is removed; one naming a LIVE process — unidentifiable, or
            // identified as somebody else's — is not, because the reply would
            // otherwise claim a clear on evidence the file never carried.
            //
            // Note what this does NOT affect: the reconcile gate. `livePIDs()`
            // unions the file with the `pgrep` scan, so a live foreign openconnect
            // keeps the gate shut whether or not the file names it. The removal
            // decision is about the truthfulness of the reply, not about the gate.
            var cleared = false
            if !targets.stalePIDFile.isEmpty,
               targets.unidentified.isEmpty, targets.notOursLive.isEmpty {
                cleared = removePIDFile(stoppedPIDs: [])
            }
            let verdict = TunnelStop.verdict(found: [], escalated: [], survivors: [],
                                             unidentified: targets.unidentified,
                                             notOursLive: targets.notOursLive,
                                             clearedStalePIDFile: cleared)
            cleanUpStateAfterStop(verdict, stoppedPIDs: [])
            log("stop: \(TunnelStop.message(verdict))")
            return reply(TunnelStop.isSuccess(verdict), TunnelStop.message(verdict))
        }

        // UNCHANGED signal sequence. SIGINT asks openconnect to tear the tunnel
        // down gracefully, which includes running the route script for "disconnect"
        // to remove its routes. Escalating on a fixed timer interrupted that
        // mid-spawn ("Failed to spawn script ... Interrupted system call") and left
        // routes behind, so wait for it and only escalate if genuinely stuck.
        // NEVER SIGKILL: an interrupted vpnc-script is how this project produced
        // orphaned routes and a stale DNS override.
        for pid in targets.signal { kill(pid, SIGINT) }
        var waited = 0.0
        while waited < 10.0, targets.signal.contains(where: { isAlive($0) }) {
            usleep(250_000); waited += 0.25
        }
        let escalated = targets.signal.filter { isAlive($0) }
        if !escalated.isEmpty {
            log("still alive after 10s, escalating to SIGTERM: \(escalated)")
            for pid in escalated { kill(pid, SIGTERM) }
            // The ONE addition to the sequence: a bounded wait AFTER the SIGTERM.
            // Without it "did it exit" is unanswerable, and the old code simply
            // assumed yes — which is how a process that survived both signals was
            // still reported as "stopped (escalated)".
            var termWaited = 0.0
            while termWaited < 5.0, escalated.contains(where: { isAlive($0) }) {
                usleep(250_000); termWaited += 0.25
            }
        }

        let verdict = TunnelStop.verdict(found: targets.signal,
                                         escalated: escalated,
                                         survivors: escalated.filter { isAlive($0) },
                                         unidentified: targets.unidentified,
                                         notOursLive: targets.notOursLive,
                                         clearedStalePIDFile: false)
        tunnel = nil
        cleanUpStateAfterStop(verdict, stoppedPIDs: targets.signal)
        log("stop: \(TunnelStop.message(verdict))")
        // A live process that is not ours cannot be carried by `.stuck`'s payload,
        // so it is logged rather than lost. Log only — the reply and the log line
        // both come from `TunnelStop.message`, so they cannot drift.
        if !targets.notOursLive.isEmpty {
            log("stop: left \(targets.notOursLive) alone — live openconnects that are not ours")
        }
        reply(TunnelStop.isSuccess(verdict), TunnelStop.message(verdict))
    }

    /// The single owner of both state-file removals, keyed to the verdict.
    ///
    /// The one removal that does not happen here is the `.nothingToStop` arm's,
    /// because there its RESULT is an input to the verdict
    /// (`clearedStalePIDFile`) and so has to happen before the verdict exists. It
    /// goes through the same `removePIDFile(stoppedPIDs:)`, called with an empty
    /// list — "remove it only if every pid it names is dead".
    ///
    /// TWO /var/run state files, and this path owns the lifetime of exactly ONE
    /// of them.
    ///
    ///   * netstate.json — "our tunnel may have left residue, and here is the
    ///     physical network it displaced". Removed HERE, and only here:
    ///     reconcile deliberately leaves it, because a later reconcile in this
    ///     boot can still use its install hint, and a stale advisory is already
    ///     fenced by the same-interface-and-subnet precondition and then by the
    ///     guard.
    ///   * tunnels.json — "utun7 was ours and it carried 192.168.204.16".
    ///     NEVER touched here, deliberately. It has to OUTLIVE the stop or a
    ///     lingering interface of ours can never be attributed, which is the one
    ///     repair the scope rule keeps. Its lifetime belongs to `startTunnel`
    ///     (unlink, then write) and to /var/run's pruning at boot.
    ///
    /// Conflating the two is the defect that split fixes: one file holding both
    /// meant a clean disconnect deleted the scope, so the next reconcile planned
    /// against every utun on the machine.
    private func cleanUpStateAfterStop(_ verdict: TunnelStop.Verdict,
                                       stoppedPIDs: [pid_t]) {
        switch verdict {
        case .nothingToStop:
            // The pid file was dealt with above. The netstate is LEFT ALONE: this
            // stop found no tunnel of ours, so it has no evidence about whether a
            // previous session's residue exists, and deleting a record on the
            // strength of having observed nothing is the defect class this whole
            // change is about.
            break

        case .stopped(_, let escalated, _):
            _ = removePIDFile(stoppedPIDs: stoppedPIDs)
            guard !escalated else {
                log("netstate kept: the stop escalated to SIGTERM, so vpnc-script's "
                    + "reason=disconnect may have been cut short — which is the exact "
                    + "mechanism that produced this project's orphaned routes, and a "
                    + "later reconcile needs the record to repair them")
                return
            }
            // Only OUR session's netstate. The stop is asynchronous and the app's
            // bounded teardown returns before it finishes, so a connect inside
            // that window can have written a newer one — and unlinking that would
            // silently cost the new session its install hint for the rest of the
            // boot.
            guard let state = NetState.load() else { return }
            guard stoppedPIDs.contains(pid_t(state.tunnelPID)) else {
                log("netstate kept: it names pid \(state.tunnelPID), which this stop did "
                    + "not stop — a newer session wrote it")
                return
            }
            try? FileManager.default.removeItem(atPath: NetState.path)

        case .stuck, .unidentified:
            // The pid file names a process that is still running, and the reconcile
            // gate reads that file.
            log("pid file and netstate kept: a process they name is still running")
        }
    }

    /// NO CALLER today, and left on `knownPIDs()` unchanged on purpose. Were it
    /// ever wired up, note the asymmetry documented on `isTunnelAlive()`: these
    /// three discovery functions answer three different questions and must not be
    /// "harmonised" into one.
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
                                         netstate: NetState.load(),
                                         attribution: TunnelAttribution.load(note: {
                                             log("reconcile:   \($0)")
                                         }))
            log("reconcile: gate=proceed, plan \(plan.actions.count) actions, "
                + "\(plan.kept.count) kept, abort=\(plan.abort.map(String.init(describing:)) ?? "none")"
                + (dryRun ? " [DRY RUN]" : ""))
            // "Absent from a usable snapshot ⇒ provably dead" was decided against the
            // CLASSIFICATION snapshot, and the deletes it authorises run after the
            // prologue. A third-party client coming up inside that window would have
            // its resolver keys removed and its default route deleted on the strength
            // of a snapshot that is no longer true, so the inference is re-checked
            // against a fresh one immediately before anything executes. One extra
            // getifaddrs per reconcile.
            let fresh = Set(NetProbe.interfaces().map(\.name))
            let bounded = NetReconcile.dropRevivedTunnelActions(plan, present: fresh)
            for drop in bounded.dropped { log("reconcile:   dropped — \(drop)") }

            // Only the kept entries that record a DECISION about scope or withholding.
            // The per-route ones are the other hundred-odd and are already summarised by
            // the count above; printing them all would bury the three that matter.
            //
            // Logged from the BOUNDED plan and after the drops, not from the plan as
            // first built: the re-probe can add an
            // `installWithheldForSurvivingDefault` of its own when it drops the
            // unscoped tunnel-default deletion that (f)'s install depended on, and a
            // withholding that is not logged is the same kind of silence this change
            // set exists to remove. The counts on the summary line above stay
            // plan-time; the `dropped —` lines account for the difference.
            for kept in bounded.plan.kept {
                switch kept {
                case .foreignTunnel, .liveTunnelIdentityUnproven, .ambiguousInstallTarget,
                     .installWithheldForSurvivingDefault, .physicalDefaultUnusable,
                     .defaultDeletionsWithheld:
                    log("reconcile:   \(kept)")
                default:
                    continue
                }
            }

            let transcript = self.applyReconcile(bounded.plan, dryRun: dryRun)
            // The full transcript always goes to the log; only the reply is capped.
            for line in transcript { log("reconcile:   \(line)") }
            // NEITHER state file is removed here.
            //
            //   * netstate.json — stopTunnel owns its lifetime. Deleting it would
            //     disarm its install-target hint for the rest of the boot.
            //   * tunnels.json — nothing but the next startTunnel ever removes it, so
            //     a lingering utun of ours stays attributable across as many
            //     reconciles as it takes for its interface to go.
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

    /// DELIBERATELY left on `knownPIDs()` rather than widened to `livePIDs()`.
    ///
    /// This gates `startTunnel`'s "a tunnel is already running" refusal, and
    /// widening it to an argv scan would let any process the desktop user can run
    /// present a matching command line and block connecting. The asymmetry
    /// between the three discovery functions is the enforcement, not an oversight:
    ///
    ///   `pgrep` evidence is trusted to say "do not touch routing". It is never
    ///   trusted to say "you may not connect", and it is trusted to say "this is
    ///   what to signal" only after `identifyPID` agrees.
    private func isTunnelAlive() -> Bool { knownPIDs().contains { isAlive($0) } }

    /// The in-memory handle is the fast path; the pid file covers the case where
    /// launchd restarted this daemon while the tunnel kept running (openconnect
    /// is reparented to launchd rather than dying with us).
    private func knownPIDs() -> [pid_t] {
        var pids: [pid_t] = []
        if let task = tunnel, task.isRunning { pids.append(task.processIdentifier) }
        for pid in pidsFromFile() where !pids.contains(pid) { pids.append(pid) }
        return pids
    }

    /// EVERY pid the file names, as a list rather than an optional, because
    /// THREE writers share that one path: this daemon (`writePIDFile`),
    /// openconnect itself through `--pid-file`, and the sudo helper through the
    /// same flag. A partially-written or doubled file is therefore conceivable,
    /// and with a single optional the stale-file / not-ours-live distinction in
    /// `TunnelStop.targets` has an unreachable branch.
    private func pidsFromFile() -> [pid_t] {
        guard let text = try? String(contentsOfFile: pidFilePath, encoding: .utf8) else {
            return []
        }
        var pids: [pid_t] = []
        for field in text.split(whereSeparator: { $0.isNewline || $0 == " " }) {
            guard let pid = pid_t(field.trimmingCharacters(in: .whitespaces)) else { continue }
            // The floor lives HERE, at the parse, so `livePIDs()` and the stop
            // both inherit it. `kill(0, SIGINT)` signals this daemon's own
            // process group and `pid_t("0")` parses, and a 0 in that file also
            // makes `kill(0, 0)` succeed — which would have left the reconcile
            // gate reading "a tunnel is alive" for the rest of the boot. Logged
            // because somebody writing 0 into a root-owned file is a real event.
            guard pid > 1 else {
                log("ignoring pid \(pid) from \(pidFilePath): 0 and 1 are never a tunnel")
                continue
            }
            if !pids.contains(pid) { pids.append(pid) }
        }
        return pids
    }

    /// The argv scan, as the daemon's only copy. `capture` is the shared bounded
    /// runner (fixed absolute path, fixed PATH, 5 s, output capped, null stdin).
    private func pgrepPIDs() -> [pid_t] {
        capture("/usr/bin/pgrep", ["-f", Self.openconnectPattern], timeout: 5)
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 > 1 }
    }

    /// Establish identity BEFORE signalling as root. `proc_pidpath` is evaluated
    /// first because it carries the liveness answer and distinguishes `ESRCH`
    /// ("it exited between the liveness check and here", which is information)
    /// from a probe that is simply broken.
    ///
    /// `-ww` so the argv cannot be width-truncated. Measured, this tunnel's argv
    /// is 264 bytes and both forms return all of it, but the `--script=` conjunct
    /// would fail SILENTLY on a longer argv if it were ever clipped, and the flag
    /// that removes the question costs nothing. `capture` yields "" on a non-zero
    /// exit or a timeout, which is why the path probe comes first.
    private func identifyPID(_ pid: pid_t) -> TunnelStop.Identity {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else {
            if errno == ESRCH { return .gone }
            log("proc_pidpath(\(pid)) failed: \(String(cString: strerror(errno)))")
            return .unknown
        }
        let command = capture("/bin/ps", ["-ww", "-o", "command=", "-p", String(pid)],
                              timeout: 3)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            log("no argv for pid \(pid): identity cannot be established, so it is not signalled")
            return .unknown
        }
        return TunnelStop.isOurOpenconnect(execPath: String(cString: buf),
                                           command: command,
                                           scriptPath: routeWrapperPath)
            ? .ourOpenconnect : .notOurs
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
    /// two cannot drift — and it can only make the gate MORE conservative. One scan
    /// implementation and one `> 1` floor, both inherited from `pgrepPIDs()` and
    /// `pidsFromFile()`, so the gate and the stop cannot disagree about what they saw.
    private func livePIDs() -> [pid_t] {
        Set(knownPIDs()).union(pgrepPIDs()).sorted()
    }

    private func writePIDFile(_ pid: pid_t) {
        try? "\(pid)\n".write(toFile: pidFilePath, atomically: true, encoding: .utf8)
    }

    /// True iff the pid file is gone afterwards.
    ///
    /// Re-reads the file before unlinking, because the stop is asynchronous and the
    /// app's bounded teardown returns before it finishes: a newer session's
    /// openconnect may have rewritten this one shared path through `--pid-file` in
    /// the meantime, and removing it then would blind the reconcile gate and
    /// `isTunnelAlive()`'s connect refusal to a LIVE tunnel.
    ///
    /// An EMPTY `stoppedPIDs` therefore means "remove it only if every pid it
    /// names is dead", which is exactly what the `.nothingToStop` arm wants.
    private func removePIDFile(stoppedPIDs: [pid_t]) -> Bool {
        let named = pidsFromFile()
        guard !named.isEmpty else {
            // Unreadable, absent, or naming nothing parseable. Absent is the
            // desired end state and is reported as such; a file we cannot reason
            // about is left alone rather than unlinked on no evidence.
            return !FileManager.default.fileExists(atPath: pidFilePath)
        }
        let keep = named.filter { !stoppedPIDs.contains($0) && isAlive($0) }
        guard keep.isEmpty else {
            log("pid file kept: it names \(keep), which this stop did not stop")
            return false
        }
        do {
            try FileManager.default.removeItem(atPath: pidFilePath)
            return true
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileNoSuchFileError { return true }
            log("could not remove \(pidFilePath): \(error.localizedDescription)")
            return false
        }
    }

    /// Record what the physical network looked like before this tunnel existed.
    ///
    /// Atomic, and it fails SILENTLY to the caller but loudly to the log: a missing
    /// netstate only degrades a later reconcile, and must never fail a connect. The
    /// descriptor hardening lives in `writeStateFile`, which both state files go
    /// through so there is only one copy of it to keep in step.
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
        guard writeStateFile(path: NetState.path, data: data, label: "netstate") else { return }
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
