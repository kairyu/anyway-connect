import Foundation
// F3: NWPathMonitor is the only interface-change notification that does not require
// polling or a SystemConfiguration dynamic-store subscription. App-only — the daemon's
// sources stay Foundation-only, which is why none of this lives in NetGuard.swift.
import Network

enum VPNState: Equatable {
    case disconnected
    case connecting
    case connected(key: String, host: String)
}

final class VPNRunner {
    static let shared = VPNRunner()

    let stateDir: URL
    let pidFile: URL
    let logFile: URL
    let endpointFile: URL
    var browserWrapperPath = ""
    let rootHelper = "/usr/local/sbin/anyway-root-helper.sh"
    /// Written by the root helper. Root-owned, so it can't be forged by the
    /// unprivileged app to make us signal an arbitrary pid.
    let helperPidFile = URL(fileURLWithPath: "/var/run/anyway-connect.pid")
    let ssoPort = 29786

    private init() {
        // Assigned here rather than inline because the coalescer needs the queue, and a
        // property's default expression cannot read another property of the same object.
        let q = DispatchQueue(label: "me.kairyu.anywayconnect.path", qos: .utility)
        pathQueue = q
        pathCoalescer = Coalescer(window: 3.0, maxDeferral: 10.0, queue: q)

        let home = FileManager.default.homeDirectoryForCurrentUser
        stateDir = home.appendingPathComponent(".config/anyway-connect/state", isDirectory: true)
        pidFile = stateDir.appendingPathComponent("openconnect.pid")
        logFile = stateDir.appendingPathComponent("openconnect.log")
        endpointFile = stateDir.appendingPathComponent("endpoint")
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        sweepStaleCookies()
        // Repair whatever a crash, a forced sleep or a network move left behind, before
        // the user has a chance to notice there is no internet.
        //
        // Off-thread: app launch and menu-bar setup must never wait on a privileged
        // round trip, and NOTHING waits on this dispatch — that is how its 90s worst
        // case stays invisible. `self` is captured DIRECTLY and VPNRunner.shared must
        // never be mentioned in here: naming the lazy static from inside its own
        // initialiser re-enters it and deadlocks.
        //
        // The guards are cheap pre-checks, not the interlock. The daemon re-gates on
        // tunnel liveness and its mutation gate is what actually serialises this against
        // a connect; isBusy() is consulted because a connect launched in the first second
        // of app life would otherwise race a launch reconcile for no reason.
        DispatchQueue.global(qos: .utility).async { [self] in
            // BEFORE the guards, deliberately: this is the first time the transport is
            // measured, and the power deciders read the published snapshot rather than
            // probing from the main thread (pass-5 MEDIUM 6). A tunnel that is already
            // up skips the reconcile below but must not leave the snapshot unmeasured —
            // a sleep arriving in the first seconds of app life would then decide on
            // `.interactiveSudo` and do nothing.
            refreshTransportSnapshot()
            guard !isBusy(), !isRunning() else { return }
            reconcileNow(reason: "launch")
        }
    }

    private var cfg: AppConfig { ConfigStore.shared.config }

    // MARK: - Path auto-detection

    // Locate the openconnect binary: config override, then common brew/system paths, then `which`.
    func openconnectPath() -> String {
        let override = cfg.general.openconnectPath
        if !override.isEmpty, FileManager.default.isExecutableFile(atPath: override) { return override }
        let candidates = ["/opt/homebrew/bin/openconnect", "/usr/local/bin/openconnect", "/usr/bin/openconnect"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        let which = shellCapture("/usr/bin/which", ["openconnect"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return which.isEmpty ? "/opt/homebrew/bin/openconnect" : which
    }

    // Derive csd-post.sh from the openconnect install (…/Cellar/openconnect/<ver>/libexec/openconnect/csd-post.sh).
    func discoverCSDWrapper(profileOverride: String) -> String {
        if !profileOverride.isEmpty, FileManager.default.isExecutableFile(atPath: profileOverride) {
            return profileOverride
        }
        let oc = openconnectPath()
        // Resolve symlinks so we land in the Cellar.
        let real = (try? FileManager.default.destinationOfSymbolicLink(atPath: oc)) ?? oc
        var base = URL(fileURLWithPath: real.hasPrefix("/") ? real : oc)
        // From .../bin/openconnect -> .../ ; search libexec/openconnect/csd-post.sh
        base.deleteLastPathComponent() // bin
        base.deleteLastPathComponent() // prefix
        // Common brew layout: prefix/opt/openconnect or prefix/Cellar/openconnect/*/libexec/...
        let fm = FileManager.default
        var candidates: [String] = []
        // Homebrew opt symlink:
        candidates.append("/opt/homebrew/opt/openconnect/libexec/openconnect/csd-post.sh")
        candidates.append("/usr/local/opt/openconnect/libexec/openconnect/csd-post.sh")
        // Cellar glob:
        for cellar in ["/opt/homebrew/Cellar/openconnect", "/usr/local/Cellar/openconnect"] {
            if let vers = try? fm.contentsOfDirectory(atPath: cellar) {
                for v in vers.sorted().reversed() {
                    candidates.append("\(cellar)/\(v)/libexec/openconnect/csd-post.sh")
                }
            }
        }
        for c in candidates where fm.isExecutableFile(atPath: c) { return c }
        return ""  // not found
    }

    func vpncScriptPath() -> String {
        let override = cfg.general.vpncScript
        if !override.isEmpty { return override }
        for c in ["/opt/homebrew/etc/vpnc/vpnc-script", "/usr/local/etc/vpnc/vpnc-script", "/etc/vpnc/vpnc-script"]
        where FileManager.default.fileExists(atPath: c) { return c }
        return "/opt/homebrew/etc/vpnc/vpnc-script"
    }

    // MARK: - Status

    /// `.connected(key: "?", host: "?")` is DELIBERATE and is not the defect.
    ///
    /// It is the honest answer for a tunnel that is running with no endpoint record
    /// to name it — one launched from a shell, or one started by another session.
    /// The reported "Connected: ?" was a SYMPTOM of `teardownNow()` clearing that
    /// record while openconnect was still alive, and the fix belongs there, not
    /// here: making this arm lie about the tunnel's absence would hide a live
    /// privileged session from the only UI that reports one.
    func currentState() -> VPNState {
        if isRunning() {
            if let line = try? String(contentsOf: endpointFile, encoding: .utf8) {
                let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
                if parts.count >= 2 { return .connected(key: String(parts[0]), host: String(parts[1])) }
            }
            return .connected(key: "?", host: "?")
        }
        return .disconnected
    }

    /// What a daemon stop licenses the app to do next. Declared beside the
    /// transport enum because it is the same kind of thing: a decision about which
    /// transport speaks and what its answer is worth.
    enum TeardownFollowUp: Equatable {
        /// Nothing of ours is running. Clear the bookkeeping and stop here.
        case clearAndReturn
        /// Something may still be running. KEEP the bookkeeping and try the
        /// fallback.
        case keepAndFallThrough(invalidateTransport: Bool)
        /// The daemon answered "no" about the request itself. Keep state, do not
        /// retry on a weaker transport.
        case keepAndReturn
    }

    // MARK: - Privileged transport

    /// How privileged work gets done, in order of preference.
    enum PrivilegedTransport: String {
        /// SMAppService daemon over XPC, authenticated by code-signing
        /// requirement. Preferred: no sudoers rule, and no unidentified caller
        /// can reach it.
        case daemon
        /// The sudoers-granted shell helper. Works, but any process running as
        /// this user can invoke it.
        case sudoHelper
        /// Plain `sudo`, which prompts. Last resort so the app is never simply
        /// unable to connect.
        case interactiveSudo
    }

    /// Cached briefly: choosing the transport can cost an XPC round trip, and the
    /// connect sequence asks more than once. Guarded by `stateLock` — F3 added three
    /// threads that reach this (the launch dispatch, the path queue and the step
    /// executor) while the main thread's connect/disconnect paths do the same.
    private var cachedTransport: (value: PrivilegedTransport, at: Date)?    // stateLock

    /// BLOCKS on a probe when the cache is cold: an XPC round trip, or a `sudo -n` exec.
    /// Never call this from a notification handler — read `cachedTransportSnapshot()`
    /// instead (pass-5 MEDIUM 6).
    func privilegedTransport() -> PrivilegedTransport {
        stateLock.lock()
        if let cached = cachedTransport, Date().timeIntervalSince(cached.at) < 10 {
            // Republished even on a cache hit, so the snapshot a notification handler
            // reads is never older than the last transport decision anything made.
            transportSnapshot = cached.value
            stateLock.unlock()
            return cached.value
        }
        stateLock.unlock()
        // The probe stays OUTSIDE the lock: PrivilegedClient.isUsable() does a round trip
        // with a 3s bound, and holding a lock across it would stall the main thread's
        // connect path behind a path-queue probe. Two threads can race to measure and the
        // later write wins — harmless, since both answers are freshly measured.
        //
        // isUsable() checks registration state first, so this costs nothing
        // until the daemon is actually installed.
        let chosen: PrivilegedTransport
        if PrivilegedClient.shared.isUsable() { chosen = .daemon }
        else if helperIsUsable() { chosen = .sudoHelper }
        else { chosen = .interactiveSudo }
        stateLock.lock()
        cachedTransport = (chosen, Date())
        transportSnapshot = chosen
        stateLock.unlock()
        return chosen
    }

    /// Force re-evaluation, e.g. right after the user installs the daemon, or after a
    /// transport proved unreachable mid-operation.
    func invalidateTransportCache() {
        stateLock.lock(); cachedTransport = nil; stateLock.unlock()
    }

    /// Last measured transport, readable from any thread without blocking.
    ///
    /// `nil` ⇒ nothing has measured yet, and the answer is the one that makes the power
    /// deciders do NOTHING: on `.interactiveSudo` they emit an empty plan, so an event
    /// arriving before the first probe completes is ignored rather than acted on with a
    /// guess. The launch dispatch measures within the first moments of app life.
    private var transportSnapshot: PrivilegedTransport?     // stateLock

    func cachedTransportSnapshot() -> PrivilegedTransport {
        stateLock.lock(); defer { stateLock.unlock() }
        return transportSnapshot ?? .interactiveSudo
    }

    /// Re-measure and republish. BLOCKS — call it from the launch dispatch or the path
    /// queue, never from the main thread.
    ///
    /// Dropping the cache first is what makes this a measurement rather than a read: a
    /// path change is exactly the moment a daemon that was unreachable ten seconds ago
    /// may have come back, and the 10s cache would otherwise answer from before the move.
    func refreshTransportSnapshot() {
        invalidateTransportCache()
        _ = privilegedTransport()
    }

    /// Argument-protocol version this build speaks to the root helper.
    /// 3: `restore-default` takes an INTERFACE instead of a gateway, and `reconcile`
    /// is new. A version-2 helper called with a bare interface name would read it as
    /// the gateway address and refuse — so an older install must fall through to the
    /// prompt rather than be driven with arguments that mean something else.
    private let requiredHelperVersion = 3

    /// True only if the installed helper is present, sudo-granted, and speaks a
    /// compatible argument protocol.
    ///
    /// Without this check an app newer than the installed helper would call it
    /// with arguments that mean something else entirely — the host landing in
    /// the old script-path slot, for instance. Falling back to the
    /// password-prompt path is the safe response.
    func helperIsUsable() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: rootHelper) else { return false }
        // -n: never prompt. A missing sudoers rule fails fast instead of hanging.
        //
        // shellCaptureSplit with a bound, not shellCapture: this is now reached from the
        // launch dispatch and from the reconcile path as well as from a connect, and
        // shellCapture has no timeout at all — a `sudo` wedged on an unreachable LDAP
        // lookup would hang whichever of those called it.
        let r = shellCaptureSplit("/usr/bin/sudo", ["-n", rootHelper, "version"], timeout: 5)
        guard !r.timedOut else { return false }
        let out = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let version = Int(out) else { return false }
        return version >= requiredHelperVersion
    }

    // MARK: - Busy mirror
    //
    // AppDelegate owns the user-visible `busy` flag on the main thread. The launch
    // reconcile below runs on a utility queue and has to consult it, and reaching back
    // into a main-thread Bool from another thread is a plain data race — so the hand-off
    // is explicit and lock-protected instead.

    /// One lock over ALL of VPNRunner's cross-thread mutable state: `busySnapshot`,
    /// `cachedTransport`, `transportSnapshot` and `lastPrimary`. F3 adds three entry
    /// points from threads that never touched this object before — the launch dispatch,
    /// the path callback and AppDelegate's step executor — and they all reach the
    /// transport while the main thread's connect/disconnect paths do the same.
    ///
    /// The XPC probe stays OUTSIDE it — `PrivilegedClient.isUsable()` does a round trip
    /// and must not be held under a lock.
    private let stateLock = NSLock()
    private var busySnapshot = false            // stateLock

    func setBusy(_ value: Bool) {
        stateLock.lock(); busySnapshot = value; stateLock.unlock()
    }

    func isBusy() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return busySnapshot
    }

    /// ONE literal, used by `isRunning()` and by `teardownNow()`'s fallback
    /// discovery. Hoisted because the second of those now FILTERS what it finds
    /// through `TunnelStop.isOurOpenconnect` and must scan for the same thing it
    /// filters; its twin is the daemon's `openconnectPattern`, and the harness
    /// runner asserts there is exactly one occurrence of it in each file.
    static let openconnectPattern = "openconnect .*(route-wrapper\\.sh|--cookie-on-stdin)"

    func isRunning() -> Bool {
        !shellCapture("/usr/bin/pgrep", ["-f", Self.openconnectPattern])
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Path monitor (F3)
    //
    // The reported incident needs something to NOTICE that the machine moved. Nothing in
    // this app did: the 8s refresh() poll only ever asked "is openconnect alive", which
    // is still true with every route pointing at a gateway two networks away.

    private let pathQueue: DispatchQueue
    private let pathMonitor = NWPathMonitor()
    /// 3s quiet period, 10s ceiling: a Wi-Fi roam or a wake emits a burst of updates, and
    /// reconciling per update would mean several privileged sweeps for one move.
    private let pathCoalescer: Coalescer

    /// The physical interface the last accepted path update named. `nil` until the first
    /// observation, which is why `decidePathChange` has a `.record` verdict at all.
    private var lastPrimary: String?            // stateLock

    /// Set by AppDelegate in `applicationDidFinishLaunching`. Invoked on `pathQueue`,
    /// i.e. NOT on main — the callee hops to main itself.
    var onNetworkChange: ((_ newPrimary: String) -> Void)?

    /// Started from AppDelegate, not from `init`: the handler calls back into AppDelegate,
    /// so the app must be past launch before updates can arrive.
    func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in self?.handlePathUpdate(path) }
        pathMonitor.start(queue: pathQueue)
    }

    func stopPathMonitor() {
        pathCoalescer.cancel()
        pathMonitor.cancel()
    }

    private func handlePathUpdate(_ path: NWPath) {
        let names = path.availableInterfaces.map(\.name)
        stateLock.lock(); let previous = lastPrimary; stateLock.unlock()
        // `state:` is an autoclosure, so currentState() — a pgrep through the UNTIMED
        // shellCapture — runs only if the decision actually reaches the step that needs
        // it, i.e. only on a genuine change of physical primary. A burst of updates for
        // one move costs one read, not one per callback.
        let decision = Self.decidePathChange(previousPrimary: previous,
                                             availableInterfaces: names,
                                             satisfied: path.status == .satisfied,
                                             state: currentState(),
                                             busy: isBusy())
        switch decision {
        case .record(let primary):
            stateLock.lock(); lastPrimary = primary; stateLock.unlock()
            NSLog("AnywayConnect: path primary recorded \(primary) interfaces=\(names)")
        case .ignore(let why):
            // NFR-7: every ignore is logged, with the full ordered interface list, so a
            // wrong primary pick is visible in one line rather than inferred.
            NSLog("AnywayConnect: path update ignored (\(why.rawValue)) interfaces=\(names)")
        case .trigger(let primary):
            stateLock.lock(); lastPrimary = primary; stateLock.unlock()
            NSLog("AnywayConnect: path change \(previous ?? "-") -> \(primary) interfaces=\(names)")
            pathCoalescer.submit { [weak self] in
                guard let self else { return }
                // On pathQueue, off main: re-measure the transport right before the
                // handler reads the snapshot, since the move itself may have changed
                // what is reachable.
                self.refreshTransportSnapshot()
                self.onNetworkChange?(primary)
            }
        }
    }

    /// Why a path update was not acted on. Raw values are the log text.
    enum PathIgnore: String {
        case unsatisfied, noPhysicalInterface, unchanged, busyOrConnecting
    }

    enum PathDecision: Equatable {
        case trigger(primary: String)
        case record(primary: String)      // first observation: remember, do not act
        case ignore(PathIgnore)
    }

    /// Pure, and `static` so a harness reaches it without `VPNRunner.shared` — touching
    /// that lazy static runs a real launch reconcile.
    ///
    /// `state` is an `@autoclosure` for cost, not for taste: it is evaluated only at step
    /// 5, so the four cheap verdicts never pay for a subprocess. Callers pass a plain
    /// value, including the harness.
    static func decidePathChange(previousPrimary: String?,
                                 availableInterfaces: [String],
                                 satisfied: Bool,
                                 state: @autoclosure () -> VPNState,
                                 busy: Bool) -> PathDecision {
        // 1. Nothing to re-dial onto, and Wi-Fi dropping for two seconds mid-roam must
        //    not start a teardown.
        guard satisfied else { return .ignore(.unsatisfied) }

        // 2. The primary is the first NON-tunnel entry. Filtering INSIDE the pure
        //    function is what makes "utun7 appears ⇒ no trigger" an assertion about
        //    shipped logic rather than about the caller.
        guard let primary = availableInterfaces.first(where: { !isTunnelLikeName($0) }) else {
            return .ignore(.noPhysicalInterface)
        }

        // 3. A first observation is not a change.
        guard let previous = previousPrimary else { return .record(primary: primary) }

        // 4. Our own tunnel coming up or going down moves the path repeatedly without
        //    moving the physical primary (FR-3.2).
        if previous == primary { return .ignore(.unchanged) }

        // 5. WITHOUT RECORDING, so a change ignored because we were mid-connect is seen
        //    again on the next update instead of being swallowed.
        if busy || state() == .connecting { return .ignore(.busyOrConnecting) }

        return .trigger(primary: primary)
    }

    /// The name half of `NetInterface.isTunnelLike`, and only the name half: `NWPath`
    /// hands out interface names, never flags, so the point-to-point test cannot apply
    /// here. A deliberate copy rather than a call — `NetInterface` needs a snapshot this
    /// code path has no reason to collect.
    private static func isTunnelLikeName(_ name: String) -> Bool {
        for p in ["utun", "ppp", "ipsec", "gif", "stf"] where name.hasPrefix(p) { return true }
        return false
    }

    // MARK: - Auth-group discovery

    /// Pull the group list out of openconnect's output: `GROUP: [a|b|c]:`.
    ///
    /// Shared by the deliberate probe and by connect-failure handling, because they
    /// are the same phenomenon. The probe works precisely *because* a rejected
    /// authgroup makes openconnect print the valid list, so a real connect that
    /// fails on a wrong group prints it too — and that output is the most reliable
    /// statement of what the gateway will accept.
    static func parseAdvertisedGroups(_ output: String) -> [String] {
        guard let r = output.range(of: "GROUP: [", options: .caseInsensitive) else { return [] }
        let rest = output[r.upperBound...]
        guard let close = rest.firstIndex(of: "]") else { return [] }
        return rest[rest.startIndex..<close]
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // Query a gateway for its available auth groups. Runs the CSD/posture step
    // first if a wrapper is available (many gateways won't show the group list
    // until posture passes). Parses the "GROUP: [a|b|c]:" prompt.
    func fetchAuthGroups(host: String, protocolName: String, csdWrapper: String,
                         completion: @escaping ([String], String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let oc = self.openconnectPath()
            // Passing an invalid --authgroup makes openconnect print the valid
            // list and stop before the browser SSO step.
            var parts = ["echo | \(self.shq(oc)) --protocol=\(self.shq(protocolName)) --authgroup='___probe___'"]
            let wrapper = self.discoverCSDWrapper(profileOverride: csdWrapper)
            if !wrapper.isEmpty { parts.append("--csd-wrapper=\(self.shq(wrapper))") }
            parts.append(self.shq(host))
            let cmd = parts.joined(separator: " ") + " 2>&1 | head -60"
            let out = self.shellCapture("/bin/sh", ["-c", cmd], extraPATH: true)

            let groups = Self.parseAdvertisedGroups(out)
            // Diagnostic hint for the UI when nothing parsed.
            var hint = ""
            if groups.isEmpty {
                if out.range(of: "CSD hostscan", options: .caseInsensitive) != nil {
                    hint = "Gateway requires a posture (CSD) check first. Enable “Handle posture (CSD) checks” and try again."
                } else if out.range(of: "SSO", options: .caseInsensitive) != nil
                            || out.range(of: "external browser", options: .caseInsensitive) != nil {
                    hint = "Gateway uses SSO with no selectable group — leave Auth group blank."
                } else {
                    hint = "No group list advertised — you can usually leave Auth group blank."
                }
            }
            DispatchQueue.main.async { completion(groups, hint) }
        }
    }

    // MARK: - Connect

    /// Outcome of a connect attempt.
    ///
    /// Richer than `(Bool, String)` so a wrong-auth-group failure can be offered as
    /// something the user can fix. Everything except `advertisedGroups` is
    /// informational; a non-empty `advertisedGroups` means "this host rejected the
    /// configured group and stated what it will accept".
    struct ConnectResult {
        let ok: Bool
        let message: String
        var endpointKey: String = ""
        var host: String = ""
        var currentAuthgroup: String = ""
        var advertisedGroups: [String] = []
    }

    func connect(profile: Profile, endpointKey key: String, force: Bool,
                 completion: @escaping (ConnectResult) -> Void) {
        guard let ep = profile.endpoints.first(where: { $0.key == key }) else {
            completion(ConnectResult(ok: false, message: "unknown endpoint '\(key)'"))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            if self.isRunning() {
                if force { self.teardownNow(); Thread.sleep(forTimeInterval: 1.0) }
                else {
                    DispatchQueue.main.async {
                        completion(ConnectResult(ok: false, message: "session already running"))
                    }
                    return
                }
            }
            for _ in 0..<3 { if !self.portBusy(self.ssoPort) { break }; Thread.sleep(forTimeInterval: 2.0) }

            // First auth attempt with the profile's current CSD setting.
            var csdEnabled = profile.csdEnabled
            var result = self.authenticate(endpoint: ep, profile: profile, csdEnabled: csdEnabled)

            // Auto-CSD-on-demand: if the server asked for hostscan and we didn't
            // send a wrapper, enable it and retry once.
            if !result.success, result.output.range(of: "CSD hostscan", options: .caseInsensitive) != nil,
               !csdEnabled {
                csdEnabled = true
                // Persist the discovery so future connects skip the retry.
                ConfigStore.shared.update { c in
                    if let i = c.profiles.firstIndex(where: { $0.id == profile.id }) {
                        c.profiles[i].csdEnabled = true
                    }
                }
                result = self.authenticate(endpoint: ep, profile: profile, csdEnabled: true)
            }

            guard result.success, let cookie = result.vars["COOKIE"], !cookie.isEmpty else {
                // Name the two aborts explicitly. Both leave openconnect's output
                // truncated mid-progress, so its last line describes nothing useful.
                let last: String
                if result.cancelled {
                    last = "cancelled"
                } else if result.timedOut {
                    last = "timed out after \(Int(Self.kAuthTimeout))s waiting for sign-in"
                } else {
                    last = result.output.split(separator: "\n").last.map(String.init)
                        ?? "authentication failed"
                }
                // A wrong auth group doesn't degrade, it fails outright — and the
                // failure output states exactly which groups this host accepts.
                // Carry that out rather than discarding it into a one-line message:
                // it turns an opaque failure into a fixable one. Only offered when
                // the configured value genuinely isn't among them, so a failure
                // that happened for some other reason doesn't suggest a no-op.
                let advertised = Self.parseAdvertisedGroups(result.output)
                let current = profile.effectiveAuthgroup(for: ep)
                let actionable = !advertised.isEmpty && !advertised.contains(current)
                DispatchQueue.main.async {
                    completion(ConnectResult(ok: false, message: last,
                                             endpointKey: ep.key, host: ep.host,
                                             currentAuthgroup: current,
                                             advertisedGroups: actionable ? advertised : []))
                }
                return
            }
            // ── Phase-2 target selection ────────────────────────────────────
            // CRITICAL: the SSO cookie is bound to the *exact gateway node*
            // that issued it. These gateways commonly sit behind a rotating
            // DNS pool (one observed gateway resolved to three different
            // IPs across three attempts), so re-resolving the hostname in
            // phase 2 can land on a DIFFERENT node, which rejects the cookie:
            //     Got inappropriate HTTP CONNECT response: HTTP/1.1 401 …
            //     Cookie was rejected by server; exiting.
            //
            // openconnect reports the node it authenticated against in HOST
            // (an IP address when the name resolved to a rotating address) and,
            // in that case, also emits RESOLVE='<hostname>:<ip>'.
            //
            // Candidate order:
            //   1) the node's IP, addressed directly. --servercert=<fingerprint>
            //      pins trust, so skipping hostname/CA validation is safe and
            //      node affinity is guaranteed. This is the proven-working path.
            //   2) hostname + --resolve=<hostname>:<ip> — same node, but with a
            //      matching SNI/Host header for gateways that require it.
            //   3) the configured hostname via fresh DNS — last resort only.
            let fingerprint = result.vars["FINGERPRINT"] ?? "-"
            let resolve = result.vars["RESOLVE"] ?? "-"
            let authHost = (result.vars["HOST"] ?? "").trimmingCharacters(in: .whitespaces)

            var resolveHost = "", resolveIP = ""
            if resolve != "-", let colon = resolve.firstIndex(of: ":") {
                resolveHost = String(resolve[..<colon])
                resolveIP = String(resolve[resolve.index(after: colon)...])
            }

            // The authenticated node's address, and a name that maps to it.
            var nodeIP = Self.isIPLiteral(authHost) ? authHost : ""
            if nodeIP.isEmpty { nodeIP = resolveIP }
            var nodeName = resolveHost
            if nodeName.isEmpty, !authHost.isEmpty, !Self.isIPLiteral(authHost) { nodeName = authHost }
            if nodeName.isEmpty, let urlStr = result.vars["CONNECT_URL"],
               let u = URL(string: urlStr), let h = u.host, !Self.isIPLiteral(h) { nodeName = h }
            if nodeName.isEmpty { nodeName = ep.host }

            var candidates: [(host: String, resolve: String, note: String)] = []
            if !nodeIP.isEmpty {
                candidates.append((nodeIP, "-", "authenticated node \(nodeIP)"))
            }
            if !nodeIP.isEmpty, !nodeName.isEmpty, nodeName != nodeIP {
                candidates.append((nodeName, "\(nodeName):\(nodeIP)", "\(nodeName) pinned to \(nodeIP)"))
            }
            let lastResort = authHost.isEmpty ? ep.host : authHost
            if !candidates.contains(where: { $0.host == lastResort }) {
                candidates.append((lastResort, "-", "\(lastResort) via fresh DNS"))
            }

            // Safety: snapshot the physical default route BEFORE the tunnel
            // rewrites it, so we can restore connectivity if the tunnel fails
            // and openconnect dies without running its disconnect teardown.
            let savedDefault = self.snapshotDefaultRoute()

            self.truncateLog()
            self.appendLog("""
                [anyway] phase 1 OK — endpoint '\(key)' (\(ep.host))
                [anyway]   HOST=\(authHost.isEmpty ? "-" : authHost) RESOLVE=\(resolve) \
                FINGERPRINT=\(fingerprint == "-" ? "-" : "present") COOKIE=<\(cookie.count) bytes>
                [anyway]   phase-2 candidates: \(candidates.map { $0.note }.joined(separator: " → "))
                """)

            var ok = false
            var connectHost = candidates.first?.host ?? ep.host

            for (index, cand) in candidates.enumerated() {
                connectHost = cand.host
                self.appendLog("[anyway] phase 2 attempt \(index + 1)/\(candidates.count): \(cand.note)")
                // Record "<key> <display host> <actual target>". The menu shows
                // field 2, so a raw node IP never leaks into the UI; field 3
                // keeps the node we actually dialled for diagnostics.
                try? "\(key) \(ep.host) \(cand.host)"
                    .write(to: self.endpointFile, atomically: true, encoding: .utf8)

                let mark = self.logLength()
                if let blocked = self.launchTunnelDetached(
                    cookie: cookie, fingerprint: fingerprint, resolve: cand.resolve,
                    host: cand.host, profile: profile) {
                    // A local privilege problem, not a bad node. Trying the other
                    // candidates would waste thirty seconds and then report the
                    // misleading "no tunnel confirmation".
                    try? FileManager.default.removeItem(at: self.endpointFile)
                    self.restoreDefaultRoute(savedDefault)
                    DispatchQueue.main.async {
                        completion(ConnectResult(ok: false, message: blocked,
                                                 endpointKey: ep.key, host: ep.host))
                    }
                    return
                }

                var rejected = false
                for _ in 0..<20 {
                    let tail = self.readLog(from: mark)
                    if tail.range(of: "Configured as|Connected as|ESP session established|Established DTLS|CSTP connected|Established connection",
                                  options: .regularExpression) != nil { ok = true; break }
                    // Bail out early on a definitive cookie rejection so we can
                    // try the next candidate instead of burning 10 seconds.
                    if tail.range(of: "Cookie was rejected|401 Unauthorized|Cookie is no longer valid",
                                  options: .regularExpression) != nil { rejected = true; break }
                    Thread.sleep(forTimeInterval: 0.5)
                }
                if ok { break }

                // FAILURE-TEARDOWN GUARD: this attempt never confirmed.
                // openconnect may have partially rewritten routing then exited
                // on error, leaving the default route pointing at a dead tunnel
                // = no network until reboot. Force teardown and restore the
                // saved physical default route before the next attempt.
                self.teardownNow()
                self.restoreDefaultRoute(savedDefault)
                self.appendLog("[anyway] attempt \(index + 1) failed\(rejected ? " (cookie rejected by this node)" : " (no tunnel confirmation)")")
                if index + 1 < candidates.count { Thread.sleep(forTimeInterval: 1.0) }
            }

            if ok {
                self.appendLog("[anyway] tunnel established via \(connectHost)")
            } else {
                try? FileManager.default.removeItem(at: self.endpointFile)
                self.appendLog("[anyway] all phase-2 candidates failed; network restored")
            }

            let finalHost = connectHost
            DispatchQueue.main.async {
                completion(ConnectResult(
                    ok: ok,
                    message: ok ? "Connected: \(ep.host) (via \(finalHost))"
                                : "Tunnel failed — network restored (see Logs)",
                    endpointKey: ep.key, host: ep.host))
            }
        }
    }

    // True for a bare IPv4/IPv6 literal (as opposed to a DNS name).
    static func isIPLiteral(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }

    private struct AuthResult {
        var success: Bool
        var vars: [String: String]
        var output: String
        /// Ran past `kAuthTimeout` without the child exiting.
        var timedOut = false
        /// The user asked to stop.
        var cancelled = false
    }

    /// How long to wait for `openconnect --authenticate` before giving up.
    ///
    /// Generous because the middle of this step is a browser SSO round trip —
    /// password plus MFA — which legitimately takes a while. But it must be
    /// bounded: openconnect waits indefinitely if the user never finishes, and
    /// with no limit the read below blocked for five hours in practice, leaving
    /// the app permanently "connecting" with no way out.
    private static let kAuthTimeout: TimeInterval = 180

    // MARK: - Cancellation

    private let cancelLock = NSLock()
    private var cancellableChild: Process?
    private var childWasCancelled = false

    private func setCancellable(_ p: Process?) {
        cancelLock.lock()
        cancellableChild = p
        if p != nil { childWasCancelled = false }
        cancelLock.unlock()
    }

    private func consumeCancelledFlag() -> Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        let was = childWasCancelled
        childWasCancelled = false
        return was
    }

    /// True when there was something to stop.
    ///
    /// Kills the authentication child so its pipes reach EOF, which is what lets
    /// the blocked reader return and the connect complete. Terminating the child is
    /// the only lever: the reader itself is parked in `read(2)` and cannot be
    /// interrupted from the Swift side.
    @discardableResult
    func cancelInFlight() -> Bool {
        cancelLock.lock()
        let child = cancellableChild
        if child != nil { childWasCancelled = true }
        cancelLock.unlock()
        guard let p = child, p.isRunning else { return false }
        appendLog("[anyway] cancelling authentication (pid \(p.processIdentifier))")
        p.terminate()
        // SIGTERM first so it can clean up; SIGKILL if it ignores us, because a
        // surviving child keeps the pipe open and the reader stays blocked.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3) {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        return true
    }

    /// `endpoint` rather than a bare host so the auth group can be resolved per
    /// gateway: the group list is configured on the appliance, so two endpoints in
    /// one profile can legitimately need different values.
    private func authenticate(endpoint: Endpoint, profile: Profile, csdEnabled: Bool) -> AuthResult {
        let host = endpoint.host
        let oc = openconnectPath()
        var args = ["--protocol=\(profile.protocolName)",
                    "--external-browser=\(browserWrapperPath)",
                    "--authenticate"]
        let authgroup = profile.effectiveAuthgroup(for: endpoint)
        if !authgroup.isEmpty { args.append("--authgroup=\(authgroup)") }
        if csdEnabled {
            let wrapper = discoverCSDWrapper(profileOverride: profile.csdWrapper)
            if !wrapper.isEmpty { args.append("--csd-wrapper=\(wrapper)") }
        }
        args.append(host)
        // Parse the KEY='VALUE' block from stdout ONLY. openconnect writes
        // progress and errors to stderr; funnelling both into one pipe lets
        // stderr interleave mid-line and corrupt the cookie. This mirrors the
        // shell's `$(…)` capture, which is what the reference flow relied on.
        let (out, err, timedOut) = shellCaptureSplit(oc, args, extraPATH: true,
                                                     timeout: Self.kAuthTimeout,
                                                     cancellable: true)
        let vars = parseAuthOutput(out)
        let ok = (vars["COOKIE"]?.isEmpty == false)
        return AuthResult(success: ok, vars: vars, output: out + err,
                          timedOut: timedOut, cancelled: consumeCancelledFlag())
    }

    // MARK: - Exception routes

    /// Expand the user's exception list into numeric CIDRs.
    ///
    /// The routing table only holds addresses, so a host name has to be resolved
    /// into something it can carry. That happens here — in the unprivileged app,
    /// *before* the tunnel exists, so answers come from the normal resolver and
    /// not from the VPN's DNS — and only numeric CIDRs are ever handed to the
    /// root helper. The helper's validation therefore stays strictly numeric,
    /// which is what keeps arbitrary strings out of a root context.
    ///
    /// This is a snapshot, and deliberately so: a host that moves address later,
    /// or one behind a CDN answering with a rotating set, will not stay
    /// excluded. Anything load-balanced wants an explicit CIDR instead.
    func expandExceptionRoutes(_ entries: [String]) -> (routes: [String], notes: [String]) {
        var routes: [String] = []
        var notes: [String] = []
        for raw in entries {
            let entry = raw.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { continue }
            if entry.contains("/") { routes.append(entry); continue }
            if Self.isIPLiteral(entry) {
                // A bare address is a single host.
                routes.append(entry.contains(":") ? entry : "\(entry)/32")
                continue
            }
            let addrs = resolveIPv4(entry)
            if addrs.isEmpty {
                notes.append("could not resolve '\(entry)' — skipped")
            } else {
                routes.append(contentsOf: addrs.map { "\($0)/32" })
                notes.append("resolved \(entry) -> \(addrs.joined(separator: ", "))")
            }
        }
        var seen = Set<String>()
        return (routes.filter { seen.insert($0).inserted }, notes)
    }

    /// Whether an exception-list entry is something we can turn into a route.
    ///
    /// Accepts a CIDR block, a bare address, or a host name. The settings UI
    /// checks against this before storing: an unparseable entry previously made
    /// the root helper refuse the *entire tunnel*, with the reason visible only
    /// in the log.
    static func isValidExceptionEntry(_ s: String) -> Bool {
        // IPv4 only, on purpose. The route wrapper installs exceptions via the
        // physical *IPv4* gateway and the root helper validates them as numeric
        // IPv4, so accepting a v6 entry here would only move the failure to
        // connect time — which is the trap this check exists to close.
        if s.contains(":") { return false }
        if s.contains("/") {
            let parts = s.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let len = Int(parts[1]) else { return false }
            let addr = String(parts[0])
            guard isIPLiteral(addr) else { return false }
            return (0...32).contains(len)
        }
        if isIPLiteral(s) { return true }
        // Host name: dot-separated labels of ASCII alphanumerics and hyphens.
        guard s.contains("."), !s.hasPrefix("."), !s.hasSuffix(".") else { return false }
        for label in s.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.isEmpty, label.count <= 63,
                  !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
            for ch in label where !(ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-")) {
                return false
            }
        }
        return true
    }

    /// IPv4 only: `route add -net` needs `-inet6` for v6, and mixing families
    /// silently would install nothing useful.
    private func resolveIPv4(_ host: String) -> [String] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0,
                             ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let head = result else { return [] }
        defer { freeaddrinfo(head) }
        var out: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = head
        while let cur = node {
            if let sa = cur.pointee.ai_addr {
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var addr = sin.pointee.sin_addr
                    _ = inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
                }
                let s = String(cString: buf)
                if !s.isEmpty { out.append(s) }
            }
            node = cur.pointee.ai_next
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// Write the session cookie to a file only the owner can read.
    ///
    /// Created at mode 0600 by `open` rather than written and then chmodded: the old
    /// `write(to:atomically:)` + `setAttributes` pair left the cookie briefly
    /// world-readable, because the atomic write lands a fresh file at the umask
    /// default before the permissions are tightened. O_EXCL|O_NOFOLLOW additionally
    /// refuse to write through anything already sitting at that path.
    private func stageCookie(_ cookie: String) -> URL? {
        Self.stageCookie(cookie, in: stateDir)
    }

    /// Directory-parameterised so tests can exercise the real implementation without
    /// writing into the user's live state directory.
    static func stageCookie(_ cookie: String, in dir: URL) -> URL? {
        let url = dir.appendingPathComponent(".cookie.\(UUID().uuidString)")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let bytes = Array((cookie + "\n").utf8)
        var written = 0
        while written < bytes.count {
            let n = bytes[written...].withUnsafeBufferPointer {
                write(fd, $0.baseAddress, $0.count)
            }
            guard n > 0 else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            written += n
        }
        return url
    }

    /// Delete cookie files left by earlier runs.
    ///
    /// A staged cookie is consumed by openconnect within milliseconds of a connect, so
    /// anything still here is debris — and it is debris that reauthenticates. Builds
    /// before the daemon path stopped staging cookies could accumulate one per
    /// connect, so this also clears the backlog on first launch of a fixed build.
    private func sweepStaleCookies() { Self.sweepCookies(in: stateDir) }

    @discardableResult
    static func sweepCookies(in dir: URL) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var removed = 0
        for name in entries where name.hasPrefix(".cookie.") {
            if (try? fm.removeItem(at: dir.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }

    /// Returns nil when the tunnel was launched, or a reason it could not be.
    ///
    /// The reason matters: a local privilege problem is not something a different
    /// gateway node can fix, so the caller stops instead of retrying every
    /// candidate and reporting "no tunnel confirmation" thirty seconds later.
    private func launchTunnelDetached(cookie: String, fingerprint: String, resolve: String,
                                      host: String, profile: Profile) -> String? {
        let proto = profile.protocolName
        let transport = privilegedTransport()

        // Daemon path: no shell, no temp cookie file, no sudo. The cookie goes
        // straight down the XPC channel into openconnect's stdin.
        //
        // THERE IS EXACTLY ONE FAILURE RETURN BELOW THAT SKIPS THE SUDO PATH, and it is
        // taken on `.refused`. The reason is what the sudo path actually is: the helper's
        // `tunnel` subcommand `exec`s openconnect with no liveness check and no lock, so
        // falling through after a refusal spawns a tunnel into whatever made the daemon
        // say no — in practice the mutation gate held by a launch or wake reconcile, i.e.
        // openconnect installing routes while a sweep deletes them. A refusal is an
        // answer, and the honest response is to fail the connect with the daemon's own
        // message. `.unreachable` still falls through, exactly as before: a daemon that
        // said nothing is not a daemon that said no.
        if transport == .daemon {
            let expandedForDaemon = expandExceptionRoutes(profile.lanAccess.manualExceptionRoutes)
            for note in expandedForDaemon.notes { appendLog("[anyway]   exception route: \(note)") }
            let outcome = PrivilegedClient.shared.startTunnel(
                protocolName: proto, host: host, fingerprint: fingerprint, resolve: resolve,
                autoAddLocalSubnet: profile.lanAccess.autoAddLocalSubnet,
                exceptionRoutes: expandedForDaemon.routes,
                logPath: logFile.path, cookie: cookie)
            appendLog("[anyway] privileged daemon: \(outcome.message)")
            switch outcome {
            case .ok:
                return nil
            case .refused(let message):
                return message
            case .failed(let message):
                // Behaves as `.refused` does, and for the same reason: the daemon
                // spawned nothing, so the ungated sudo `exec` must not run into
                // whatever state it left. The daemon's startTunnel produces no
                // `.failed` today — this arm exists so that adding one later is a
                // one-line change here and not a silent fall-through to sudo.
                return message
            case .unreachable:
                appendLog("[anyway] daemon unreachable — falling back to sudo")
                invalidateTransportCache()
            }
        }

        // Only the shell paths need the cookie on stdin, and stdin is /dev/null for a
        // detached process — so it has to come from a file. Staged HERE rather than at
        // the top of this function: previously it was written unconditionally and the
        // daemon path returned before any cleanup, so every daemon-backed connect left
        // a still-valid session cookie in the state directory indefinitely. The daemon
        // hands the cookie over in-band and now genuinely never writes it to disk.
        guard let cookieTmp = stageCookie(cookie) else {
            return "Could not stage credentials securely"
        }

        let useHelper = helperIsUsable()
        let autoSubnet = profile.lanAccess.autoAddLocalSubnet ? "1" : "0"
        // No vpncScriptPath() here any more: the interactive path now passes the
        // root-owned PrivilegedInstaller.vpncScript, so the discovered Homebrew
        // location is not what gets handed to a root openconnect.
        let expanded = expandExceptionRoutes(profile.lanAccess.manualExceptionRoutes)
        for note in expanded.notes { appendLog("[anyway]   exception route: \(note)") }
        let excRoutes = expanded.routes.joined(separator: ",")
        let excArg = excRoutes.isEmpty ? "-" : excRoutes
        let logPath = logFile.path

        let cmd: String
        if useHelper {
            // The helper deliberately takes no paths: it hardcodes the route
            // wrapper, the vpnc-script and the pid file, all root-owned. Passing
            // them in was an arbitrary-root-code-execution hole, since anything
            // running as this user can invoke the helper without a password.
            // `exec < $C` opens the cookie, then it is unlinked immediately: the
            // descriptor stays valid, so openconnect still reads it, but the file is
            // gone from the filesystem within milliseconds instead of lingering for
            // the whole session as it did when the rm trailed the tunnel. The trap
            // covers the case where the redirect itself fails.
            cmd = "C=\(shq(cookieTmp.path)); trap 'rm -f \"$C\"' EXIT; exec < \"$C\"; rm -f \"$C\"; " +
                  "exec sudo \(shq(rootHelper)) tunnel \(shq(proto)) \(shq(fingerprint)) \(shq(resolve)) " +
                  "\(shq(host)) \(shq(autoSubnet)) \(shq(excArg)) " +
                  ">> \(shq(logPath)) 2>&1"
        } else {
            // Last resort: no daemon, no sudo-granted helper. openconnect runs as
            // root here, so the --script it executes must be root-owned. This path
            // used to pass the copy inside the app bundle, which the desktop user
            // can rewrite — the one place that handed root a file the other two
            // backends deliberately refuse. Use the same root-owned copy they use,
            // and decline if it isn't installed rather than widening the hole.
            guard PrivilegedInstaller.state().supportFilesReady else {
                appendLog("[anyway] no privileged backend is installed, and the root-owned "
                        + "support files are missing. Refusing to run a user-writable script "
                        + "as root. Install a method in Settings > General.")
                try? FileManager.default.removeItem(at: cookieTmp)
                return "No privileged method installed — set one up in Settings ▸ General"
            }

            // Bounded and honest about what it needs. sudo has no terminal here
            // (stdin is the cookie file), so it can only authenticate where Touch
            // ID is wired into sudo; elsewhere it fails, and the reason lands in
            // the log rather than being discarded.
            appendLog("[anyway] no privileged method installed — trying an interactive sudo. "
                    + "This needs authentication and won't work unattended; install the "
                    + "daemon or the root helper in Settings > General for background use.")

            let oc = openconnectPath()
            var a = "--protocol=\(proto) --cookie-on-stdin --timestamp --pid-file=\(shq(pidFile.path))"
            if fingerprint != "-" { a += " --servercert=\(shq(fingerprint))" }
            if resolve != "-" { a += " --resolve=\(shq(resolve))" }
            a += " --script=\(shq(PrivilegedInstaller.routeWrapper)) \(shq(host))"
            let envp = "ANYWAY_AUTO_SUBNET=\(shq(autoSubnet)) "
                     + "ANYWAY_VPNC_SCRIPT=\(shq(PrivilegedInstaller.vpncScript)) "
                     + "ANYWAY_EXCEPTION_ROUTES=\(shq(excRoutes.replacingOccurrences(of: ",", with: " "))) "
            cmd = "C=\(shq(cookieTmp.path)); trap 'rm -f \"$C\"' EXIT; exec < \"$C\"; rm -f \"$C\"; " +
                  "exec sudo \(envp)\(shq(oc)) \(a) >> \(shq(logPath)) 2>&1"
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "( \(cmd) ) </dev/null >/dev/null 2>&1 &"]
        task.environment = detachedEnv()
        try? task.run()
        task.waitUntilExit()
        return nil
    }

    // MARK: - Disconnect

    func disconnect(completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.teardownNow()
            DispatchQueue.main.async { completion() }
        }
    }

    /// Bring the tunnel down and wait for it. Internal, not private, because F3's power
    /// handlers need a teardown that is synchronous: a will-sleep observer has to finish
    /// the work before the machine suspends, and `disconnect(completion:)`'s hop to main
    /// would never run. Same body as before, under a name that says what callers use it
    /// for — `disconnect(completion:)` still wraps it for the UI.
    /// What the daemon's answer licenses. PURE, and factored out so the table that
    /// encodes "do not clear on a stop that stopped nothing" is testable.
    static func teardownFollowUp(_ outcome: PrivilegedOutcome) -> TeardownFollowUp {
        switch outcome {
        // `.ok` covers both "nothing of ours was running" and "stopped it", and
        // clearing is correct for both: in each, no tunnel of ours is running, so
        // the endpoint record names nothing. The fix is not "never clear" — it is
        // "clear only when the absence of a tunnel of ours has been ESTABLISHED
        // rather than assumed".
        case .ok:          return .clearAndReturn
        case .failed:      return .keepAndFallThrough(invalidateTransport: false)
        case .unreachable: return .keepAndFallThrough(invalidateTransport: true)
        case .refused:     return .keepAndReturn
        }
    }

    /// Which of `candidates` is one of OUR openconnects, judged from a single
    /// batched `ps -ww -o pid=,command=`. PURE, so the filter is assertable over
    /// literal `ps` output instead of by signalling something.
    ///
    /// argv[0] is the strongest thing an UNPRIVILEGED caller can read —
    /// `proc_pidpath` against a root-owned process returns EPERM, and every
    /// openconnect this project starts runs as root — and the two argv markers
    /// carry the weight either way.
    ///
    /// Fails CLOSED: a pid with no readable line is refused, not signalled.
    static func ourOpenconnects(among candidates: [Int32], psOutput: String,
                                scriptPath: String)
        -> (verified: [Int32], refused: [Int32]) {
        var verified: [Int32] = []
        for line in psOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 1,
                                    omittingEmptySubsequences: true)
            guard fields.count == 2,
                  let pid = Int32(fields[0].trimmingCharacters(in: .whitespaces)),
                  candidates.contains(pid) else { continue }
            let command = fields[1].trimmingCharacters(in: .whitespaces)
            guard TunnelStop.isOurOpenconnect(
                      execPath: String(command.split(separator: " ").first ?? ""),
                      command: command,
                      scriptPath: scriptPath) else { continue }
            if !verified.contains(pid) { verified.append(pid) }
        }
        return (verified.sorted(), candidates.filter { !verified.contains($0) }.sorted())
    }

    /// Is any of these pids still alive?
    ///
    /// On `/bin/ps`, NEVER on `kill(pid, 0)`. This app runs as the desktop user and
    /// every openconnect it starts runs as root, so `kill(root_pid, 0)` returns
    /// EPERM — "alive, but not yours" read as "dead" — and the caller would then
    /// clear the endpoint record out from under a LIVE tunnel, which is the exact
    /// defect this change exists to remove. `ps -p` lists a process whatever its
    /// owner. If a `kill(0)` is ever reintroduced anywhere app-side,
    /// `errno == EPERM` MUST be treated as ALIVE.
    ///
    /// Bounded at 3 s, and a TIMEOUT counts as alive: on no evidence the
    /// bookkeeping is kept rather than discarded. A `ps` that cannot be launched at
    /// all is indistinguishable from "none of them exist" through
    /// `shellCaptureSplit`, which discards the exit status; that is the one gap,
    /// and `/bin/ps` missing is not a state this app can do anything useful in.
    private func anyStillAlive(_ pids: [Int32]) -> Bool {
        guard !pids.isEmpty else { return false }
        let csv = pids.map(String.init).joined(separator: ",")
        let result = shellCaptureSplit("/bin/ps", ["-o", "pid=", "-p", csv], timeout: 3)
        if result.timedOut {
            appendLog("[anyway] ps timed out checking \(csv) — treating them as still alive")
            return true
        }
        return result.out.split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            .contains { pids.contains($0) }
    }

    func teardownNow() {
        // Set in the `.failed` arm ONLY. `.unreachable` means the daemon said
        // nothing at all, which is no evidence that something is running, so an
        // empty `verified` after it may still clear.
        var daemonSaidSomethingMayRun = false

        if privilegedTransport() == .daemon {
            let outcome = PrivilegedClient.shared.stopTunnel()
            appendLog("[anyway] privileged daemon stop: \(outcome.message)")
            switch Self.teardownFollowUp(outcome) {
            case .clearAndReturn:
                try? FileManager.default.removeItem(at: endpointFile)
                return
            case .keepAndReturn:
                appendLog("[anyway] daemon refused the stop — endpoint record kept")
                return
            case .keepAndFallThrough(let invalidate):
                if case .failed = outcome { daemonSaidSomethingMayRun = true }
                appendLog("[anyway] daemon stop did not stop the tunnel — "
                        + "endpoint record kept, falling back to sudo")
                if invalidate { invalidateTransportCache() }
            }
        }
        var pids: [String] = []
        // The helper writes a root-owned pid file; the no-helper fallback writes
        // one in the state dir. pgrep below covers both regardless.
        for url in [helperPidFile, pidFile] {
            if let s = try? String(contentsOf: url, encoding: .utf8) {
                pids += s.split(whereSeparator: { $0.isNewline || $0 == " " }).map(String.init)
            }
        }
        pids += shellCapture("/usr/bin/pgrep", ["-f", Self.openconnectPattern])
            .split(whereSeparator: { $0.isNewline }).map(String.init)
        // `> 1` for the same reason the daemon applies it: `sudo kill -INT 0` would
        // signal this app's own process group.
        let unique = Array(Set(pids.compactMap { Int32($0) }.filter { $0 > 1 })).sorted()

        // No transport signals a pid it has not identified. The daemon refuses to
        // signal one it cannot establish as ours, and this path must not undo that
        // one layer up — it signals as root through sudo. ONE batched bounded call
        // for every candidate: the unbounded `shellCapture` must not be used on a
        // teardown path, and one `ps` per pid is unbudgeted too.
        var verified: [Int32] = []
        if !unique.isEmpty {
            let probe = shellCaptureSplit(
                "/bin/ps",
                ["-ww", "-o", "pid=,command=", "-p", unique.map(String.init).joined(separator: ",")],
                timeout: 3)
            let filtered = Self.ourOpenconnects(among: unique, psOutput: probe.out,
                                                scriptPath: PrivilegedInstaller.routeWrapper)
            verified = filtered.verified
            // Named BY NUMBER, because that is the information the user needs to
            // finish by hand. The cost of the rule, stated rather than buried: an
            // unreadable `ps` refuses everything and the app's last resort is gone.
            // That is the fail-closed direction, and it is the one to be wrong in.
            for pid in filtered.refused {
                appendLog("[anyway] refusing to signal pid \(pid): not our openconnect")
            }
        }

        if !verified.isEmpty {
            let argv = verified.map(String.init)
            if helperIsUsable() {
                _ = shellCapture("/usr/bin/sudo", ["-n", rootHelper, "stop"] + argv)
            } else {
                // Same reasoning as the root helper's stop: give the graceful
                // teardown time to run its disconnect script before escalating.
                _ = shellCapture("/usr/bin/sudo", ["kill", "-INT"] + argv)
                var waited = 0.0
                while waited < 10.0, anyStillAlive(verified) {
                    Thread.sleep(forTimeInterval: 0.25); waited += 0.25
                }
                if anyStillAlive(verified) {
                    _ = shellCapture("/usr/bin/sudo", ["kill", "-TERM"] + argv)
                }
            }
        }

        // The SAME defect lived on this path: it cleared unconditionally after the
        // kill sequence, whether or not anything died. Gated on the pids actually
        // signalled, and NOT on isRunning() — that is the broad `pgrep`, so an
        // unrelated openconnect carrying either marker would keep the endpoint
        // record indefinitely and `currentState()` would return
        // `.connected(key: "?", host: "?")` forever: the user's transient symptom
        // made permanent.
        //
        // The second clause is the fail-closed decision holding at the LAST branch
        // rather than only at the first: an empty `verified` after the daemon said
        // "something may still be running" means nobody could identify it, which is
        // not evidence of absence.
        let stillAlive = anyStillAlive(verified)
        if !stillAlive && !(daemonSaidSomethingMayRun && verified.isEmpty) {
            try? FileManager.default.removeItem(at: pidFile)
            try? FileManager.default.removeItem(at: endpointFile)
        } else if stillAlive {
            appendLog("[anyway] openconnect still running after the fallback stop — "
                    + "endpoint record kept")
        } else {
            appendLog("[anyway] the daemon found something it could not stop and this "
                    + "transport could not identify it either — absence was never "
                    + "established, so the endpoint record is kept")
        }
    }

    // MARK: - Helpers

    func readLog() -> String {
        (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
    }

    // Byte offset of the end of the log, used to scope a read to one attempt.
    private func logLength() -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFile.path),
              let size = attrs[.size] as? Int else { return 0 }
        return size
    }

    // Read only the portion of the log written after `offset`.
    private func readLog(from offset: Int) -> String {
        guard let data = try? Data(contentsOf: logFile) else { return "" }
        guard offset < data.count else { return "" }
        return String(data: data.subdata(in: offset..<data.count), encoding: .utf8) ?? ""
    }

    private func truncateLog() {
        try? Data().write(to: logFile, options: .atomic)
    }

    // Append a diagnostic line. Phase 1 runs entirely in-process, so without
    // this the log only ever showed phase-2 output, making auth-side problems
    // invisible. Never log the cookie itself — only its length.
    private static let logStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private func appendLog(_ text: String) {
        // Stamp every line, not just the first: these are interleaved with
        // openconnect's own output, and correlating them needs a clock.
        let stamp = Self.logStamp.string(from: Date())
        let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
        let line = body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "[\(stamp)] \($0)" }
            .joined(separator: "\n") + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: logFile) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        } else {
            try? data.write(to: logFile, options: .atomic)
        }
    }

    // MARK: - Default-route safety (snapshot/restore)

    /// What was true about the physical default route before the tunnel touched it.
    ///
    /// This replaces a `"gw|iface"` string, and the replacement is the fix rather than
    /// tidying: one string carrying two meanings is how a gateway address captured on
    /// the office LAN survived long enough to be replayed at home, where it blackholed
    /// the machine. Here the address is explicitly an *advisory* — named so it cannot be
    /// mistaken for something installable — and the interface, which is the only thing
    /// still worth transmitting, stands on its own.
    struct DefaultRouteSnapshot: Equatable {
        /// "" ⇒ nothing trustworthy was captured, and restore does nothing.
        let interface: String
        /// The interface's subnet at snapshot time, e.g. "10.0.1.0/24". This is what
        /// makes "same network as when we snapshotted" a question that can be asked.
        let subnet: String
        /// DIAGNOSTIC ONLY. Never transmitted to the daemon and never installed —
        /// logged so a divergence between what the app expected and what the daemon
        /// derived is visible in one line.
        let gatewayAdvisory: String

        var isEmpty: Bool { interface.isEmpty }
        static let none = DefaultRouteSnapshot(interface: "", subnet: "", gatewayAdvisory: "")
    }

    /// Identify the physical default route's interface, and record the subnet it was on.
    ///
    /// Still `route -n get default` for the interface — that is the kernel's own answer
    /// to "where does ordinary traffic go" — but the subnet comes from the interface
    /// snapshot, which is the only place a prefix length exists.
    func snapshotDefaultRoute() -> DefaultRouteSnapshot {
        let out = shellCapture("/sbin/route", ["-n", "get", "default"])
        var gw = "", ifc = ""
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("gateway:") { gw = t.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("interface:") { ifc = t.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces) }
        }
        // Refusing a tunnel target is the same rule the daemon applies, by the same
        // predicate, so the two cannot drift: restoring the "physical" default onto a
        // utun is the failure this change exists to stop.
        guard !ifc.isEmpty, PrivilegedValidation.isRestoreTargetInterface(ifc) else {
            return .none
        }
        let subnet = NetProbe.interfaces().first { $0.name == ifc }?.subnetCIDR ?? ""
        return DefaultRouteSnapshot(interface: ifc, subnet: subnet, gatewayAdvisory: gw)
    }

    /// Restore the physical default route if it was clobbered by a failed tunnel.
    ///
    /// The snapshot no longer says *what* to install, only *where*. Each transport
    /// derives the next hop from the live system and refuses rather than guess.
    func restoreDefaultRoute(_ snapshot: DefaultRouteSnapshot) {
        guard !snapshot.isEmpty else { return }
        let iface = snapshot.interface

        // Cheap app-side pre-check, kept to avoid a pointless privileged round trip.
        // Not a safety boundary: the daemon re-checks the same precondition itself,
        // because it trusts no fact a caller claims to have established.
        let current = shellCapture("/sbin/route", ["-n", "get", "default"])
        let onTunnel = current.range(of: "interface: utun", options: .regularExpression) != nil
        let noDefault = current.range(of: "gateway:") == nil
        guard onTunnel || noDefault else { return }  // physical default already fine

        // Say out loud what the app thought the gateway was and what the guard makes of
        // it. The advisory is never installed, so this line is the only place a
        // divergence between app expectation and privileged derivation becomes visible.
        let advisory = snapshot.gatewayAdvisory
        if !advisory.isEmpty {
            switch evaluateDefaultGateway(candidate: advisory, targetInterface: iface,
                                          interfaces: NetProbe.interfaces()) {
            case .accept:
                appendLog("[anyway] restore target \(iface): advisory \(advisory) -> accept; "
                        + "deriving privileged-side anyway")
            case .reject(let why):
                appendLog("[anyway] restore target \(iface): advisory \(advisory) -> "
                        + "reject(\(why.rawValue)); deriving privileged-side")
            }
        }

        if privilegedTransport() == .daemon {
            switch PrivilegedClient.shared.restoreDefaultRoute(interface: iface) {
            case .ok(let message):
                appendLog("[anyway] privileged daemon restore: \(message)")
                return
            case .refused(let message):
                // The guard said no, and a refusal is an ANSWER. Retrying it on the
                // sudo helper — which runs a weaker, shell-side copy of the same guard —
                // would be bypassing the check that just spoke. Logged verbatim because
                // the message carries the derivation transcript.
                appendLog("[anyway] privileged daemon refused the restore: \(message)")
                return
            case .failed(let message):
                // The daemon ran it and the postcondition did not hold, which is
                // not an answer about the request — so the helper may legitimately
                // try, and the transport cache is NOT dropped because the daemon is
                // healthy. Not produced by this call today.
                appendLog("[anyway] privileged daemon restore did not take effect "
                        + "(\(message)) — falling back to sudo")
            case .unreachable(let message):
                appendLog("[anyway] privileged daemon unreachable (\(message)) — "
                        + "falling back to sudo")
                invalidateTransportCache()
            }
        }

        if helperIsUsable() {
            // No gateway argument: the helper derives and guards it the same way.
            // Judged by the FINAL-LINE SENTINEL, not by an exit status —
            // shellCaptureSplit discards terminationStatus, so there is no status to
            // read, and inferring success from empty stderr would be worse than
            // reading the verdict the helper prints on purpose.
            //
            // The sentinel is sought in STDOUT's last line, not in `out + err`: the
            // helper's guard writes its rejection reasons to stderr, and a *successful*
            // derivation that rejected its first candidate before accepting the second
            // emits exactly that — so concatenating the streams would leave a guard line
            // last and report a completed restore as unconfirmed. Both streams are still
            // logged; only the verdict is read from the stream that carries it.
            let r = shellCaptureSplit("/usr/bin/sudo", ["-n", rootHelper, "restore-default", iface],
                                      timeout: 30)
            let text = (r.out + r.err).trimmingCharacters(in: .whitespacesAndNewlines)
            let verdict = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.timedOut {
                appendLog("[anyway] helper restore-default \(iface): timed out after 30s")
            } else if verdict.hasSuffix("restore-default: ok") {
                appendLog("[anyway] helper restore-default \(iface): ok\n\(text)")
            } else {
                // The helper's stderr carries the guard's reasons. Not retried further:
                // the only weaker transport left prompts for a password.
                appendLog("[anyway] helper restore-default \(iface) did not confirm:\n\(text)")
            }
            return
        }

        // Last resort, and the one place the guard is enforced app-side only (O-3):
        // there is no privileged backend to derive in, so the app derives, and acts
        // only on an acceptance.
        let derivation = deriveDefaultGateway(interface: iface,
                                              interfaces: NetProbe.interfaces(),
                                              dhcpRouter: NetProbe.dhcpRouter(for: iface),
                                              routeTable: NetProbe.routeTable(),
                                              netstate: NetState.load())
        guard let accepted = derivation.accepted else {
            appendLog("[anyway] refusing to restore default via \(iface): "
                    + derivation.transcript.joined(separator: "; "))
            return
        }
        _ = shellCapture("/usr/bin/sudo",
                         ["/sbin/route", "-n", "change", "default", accepted.gateway])
        appendLog("[anyway] restored default via \(accepted.gateway) (\(iface)) "
                + "from \(accepted.source.rawValue) [interactive sudo]")
    }

    // MARK: - Reconcile

    /// Ask the privileged side to sweep leftover VPN routing/DNS state and put a usable
    /// physical default back.
    ///
    /// Nothing is decided here: the daemon re-gates on tunnel liveness, derives every
    /// address itself and guards every install. This function only chooses a transport
    /// and reports what came back.
    @discardableResult
    func reconcileNow(reason: String) -> PrivilegedOutcome {
        switch privilegedTransport() {
        case .daemon:
            let outcome = PrivilegedClient.shared.reconcile()
            appendLog("[anyway] reconcile (\(reason)): \(outcome.message)")
            // Only a transport failure is grounds for trying something else. A refusal
            // is an answer — the same split as the restore, and for the same reason.
            if case .unreachable = outcome {
                invalidateTransportCache()
                return reconcileViaHelper(reason: reason)
            }
            return outcome

        case .sudoHelper:
            return reconcileViaHelper(reason: reason)

        case .interactiveSudo:
            // This runs unattended — app launch, wake, a Wi-Fi hop — and a password
            // prompt there is useless as well as hostile. NOTHING IS MUTATED on this
            // arm: it logs and returns.
            let message = "reconcile unavailable: no non-interactive privileged backend"
            appendLog("[anyway] \(message)")
            return .refused(message)
        }
    }

    private func reconcileViaHelper(reason: String) -> PrivilegedOutcome {
        guard helperIsUsable() else {
            return .refused("reconcile unavailable: no non-interactive privileged backend")
        }
        // shellCaptureSplit, not shellCapture: the latter has no timeout, and this call
        // becomes a blocking step in the wake sequence — an unbounded wait there would
        // stall the redial. 90s matches the XPC bound and the daemon's phase arithmetic.
        let r = shellCaptureSplit("/usr/bin/sudo", ["-n", rootHelper, "reconcile"], timeout: 90)
        let message = (r.out + r.err).trimmingCharacters(in: .whitespacesAndNewlines)
        if r.timedOut {
            appendLog("[anyway] reconcile (\(reason)) via helper: timed out after 90s")
            return .refused("reconcile timed out after 90s")
        }
        appendLog("[anyway] reconcile (\(reason)) via helper: \(message)")
        // The helper's LAST STDOUT LINE is its verdict. shellCaptureSplit discards the
        // child's exit status, so there is no status to read here, and inferring success
        // from an empty stderr would be worse than reading the sentinel the helper
        // prints on purpose — the sweep notice and the guard's reasons both go to stderr
        // on runs that succeed, so the streams must not be concatenated before this test.
        let verdict = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return verdict.hasSuffix("reconcile: ok") ? .ok(message) : .refused(message)
    }

    private func parseAuthOutput(_ out: String) -> [String: String] {
        var result: [String: String] = [:]
        // openconnect --authenticate prints one KEY='VALUE' per LINE. Values
        // (notably COOKIE) can contain ';' and other punctuation, so we must
        // split on newlines ONLY — never on ';' — and strip just the outer
        // single quotes.
        for rawLine in out.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            guard key.range(of: "^[A-Z_]+$", options: .regularExpression) != nil else { continue }
            var val = String(line[line.index(after: eq)...])
            if val.hasPrefix("'") && val.hasSuffix("'") && val.count >= 2 {
                val = String(val.dropFirst().dropLast())
            }
            result[key] = val
        }
        return result
    }

    private func portBusy(_ port: Int) -> Bool {
        !shellCapture("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func detachedEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/opt/curl/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        return env
    }

    @discardableResult
    private func shellCapture(_ launchPath: String, _ args: [String], extraPATH: Bool = false) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        if extraPATH { task.environment = detachedEnv() }
        let pipe = Pipe()
        task.standardOutput = pipe; task.standardError = pipe
        do { try task.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // Run a command capturing stdout and stderr SEPARATELY.
    // Internal rather than private so a scratch harness can exercise the timeout
    // and cancellation paths directly; there is no unit-test target for this app.
    func shellCaptureSplit(_ launchPath: String, _ args: [String],
                                   extraPATH: Bool = false,
                                   timeout: TimeInterval? = nil,
                                   cancellable: Bool = false)
        -> (out: String, err: String, timedOut: Bool) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        if extraPATH { task.environment = detachedEnv() }
        let outPipe = Pipe(), errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        // A menu-bar app has no usable stdin; give the child /dev/null so a
        // prompt fails fast instead of hanging the connect forever.
        task.standardInput = FileHandle.nullDevice
        do { try task.run() } catch { return ("", "", false) }
        if cancellable { setCancellable(task) }
        defer { if cancellable { setCancellable(nil) } }

        // Drain both pipes concurrently — reading one to EOF first can deadlock
        // once the other fills its buffer, and openconnect is chatty on stderr.
        // Both reads run off this thread so the wait below can be bounded; reading
        // one inline is what made the timeout impossible to enforce.
        var outData = Data(), errData = Data()
        let lock = NSLock()
        let group = DispatchGroup()
        for (pipe, isOut) in [(outPipe, true), (errPipe, false)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock(); if isOut { outData = d } else { errData = d }; lock.unlock()
                group.leave()
            }
        }

        var timedOut = false
        if let t = timeout {
            if group.wait(timeout: .now() + t) == .timedOut {
                timedOut = true
                task.terminate()
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3) {
                    if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                }
                // Bounded: killing the child closes the pipes, so the readers
                // finish. Capped anyway so a grandchild holding the pipe open
                // cannot re-create the original hang.
                _ = group.wait(timeout: .now() + 6)
            }
        } else {
            group.wait()
        }
        // Only safe once the child is known to have exited; after a timeout it may
        // still be dying, and waiting on it would reintroduce the block.
        if !timedOut { task.waitUntilExit() }

        lock.lock(); let o = outData, e = errData; lock.unlock()
        return (String(data: o, encoding: .utf8) ?? "",
                String(data: e, encoding: .utf8) ?? "", timedOut)
    }

    private func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// Trailing-edge debouncer with a hard ceiling (FR-3.4).
///
/// Injectable rather than hard-coded so a harness can give it a 0.2s window instead of
/// waiting three seconds per assertion; the production values live at the one call site.
final class Coalescer {
    private let window: TimeInterval
    private let maxDeferral: TimeInterval
    private let queue: DispatchQueue

    private let lock = NSLock()
    /// Bumped by every submit and by `cancel()`. A scheduled fire that no longer matches
    /// has been superseded and returns without running — cheaper and less error-prone
    /// than cancelling DispatchWorkItems, and it cannot leave two timers alive at once.
    private var generation = 0                  // lock
    private var pending: (() -> Void)?          // lock
    private var burstStart: Date?               // lock

    /// - Parameters:
    ///   - window: quiet period after the LAST submit before the work runs.
    ///   - maxDeferral: ceiling measured from the FIRST submit of a burst. Without it a
    ///     roam that emits updates faster than `window` defers the work indefinitely —
    ///     which is precisely the carry-home case this exists to serve.
    ///   - queue: where the work runs. Never main: the work blocks on privileged calls.
    init(window: TimeInterval, maxDeferral: TimeInterval, queue: DispatchQueue) {
        self.window = window
        self.maxDeferral = maxDeferral
        self.queue = queue
    }

    /// Latest submission wins: the work is replaced, not queued, so a burst runs the most
    /// recent view of the world exactly once.
    func submit(_ work: @escaping () -> Void) {
        let now = Date()
        lock.lock()
        pending = work
        generation += 1
        let mine = generation
        if burstStart == nil { burstStart = now }
        let ceiling = burstStart!.addingTimeInterval(maxDeferral)
        lock.unlock()
        let trailing = now.addingTimeInterval(window)
        let delay = max(0, min(trailing, ceiling).timeIntervalSince(now))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.fire(mine) }
    }

    func cancel() {
        lock.lock()
        generation += 1
        pending = nil
        burstStart = nil
        lock.unlock()
    }

    private func fire(_ mine: Int) {
        lock.lock()
        guard mine == generation, let work = pending else { lock.unlock(); return }
        pending = nil
        burstStart = nil
        lock.unlock()
        work()
    }
}
