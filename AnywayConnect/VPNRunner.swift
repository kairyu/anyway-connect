import Foundation

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
        let home = FileManager.default.homeDirectoryForCurrentUser
        stateDir = home.appendingPathComponent(".config/anyway-connect/state", isDirectory: true)
        pidFile = stateDir.appendingPathComponent("openconnect.pid")
        logFile = stateDir.appendingPathComponent("openconnect.log")
        endpointFile = stateDir.appendingPathComponent("endpoint")
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        sweepStaleCookies()
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
    /// connect sequence asks more than once.
    private var cachedTransport: (value: PrivilegedTransport, at: Date)?

    func privilegedTransport() -> PrivilegedTransport {
        if let cached = cachedTransport, Date().timeIntervalSince(cached.at) < 10 {
            return cached.value
        }
        // isUsable() checks registration state first, so this costs nothing
        // until the daemon is actually installed.
        let chosen: PrivilegedTransport
        if PrivilegedClient.shared.isUsable() { chosen = .daemon }
        else if helperIsUsable() { chosen = .sudoHelper }
        else { chosen = .interactiveSudo }
        cachedTransport = (chosen, Date())
        return chosen
    }

    /// Force re-evaluation, e.g. right after the user installs the daemon.
    func invalidateTransportCache() { cachedTransport = nil }

    /// Argument-protocol version this build speaks to the root helper.
    private let requiredHelperVersion = 2

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
        let out = shellCapture("/usr/bin/sudo", ["-n", rootHelper, "version"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let version = Int(out) else { return false }
        return version >= requiredHelperVersion
    }

    func isRunning() -> Bool {
        !shellCapture("/usr/bin/pgrep", ["-f", "openconnect .*(route-wrapper\\.sh|--cookie-on-stdin)"])
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                if force { self.disconnectSync(); Thread.sleep(forTimeInterval: 1.0) }
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
                self.disconnectSync()
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
        if transport == .daemon {
            let expandedForDaemon = expandExceptionRoutes(profile.lanAccess.manualExceptionRoutes)
            for note in expandedForDaemon.notes { appendLog("[anyway]   exception route: \(note)") }
            let result = PrivilegedClient.shared.startTunnel(
                protocolName: proto, host: host, fingerprint: fingerprint, resolve: resolve,
                autoAddLocalSubnet: profile.lanAccess.autoAddLocalSubnet,
                exceptionRoutes: expandedForDaemon.routes,
                logPath: logFile.path, cookie: cookie)
            appendLog("[anyway] privileged daemon: \(result.message)")
            if result.ok { return nil }
            // Fall through to the sudo paths rather than failing outright.
            appendLog("[anyway] daemon start failed — falling back to sudo")
            invalidateTransportCache()
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
            self.disconnectSync()
            DispatchQueue.main.async { completion() }
        }
    }

    private func disconnectSync() {
        if privilegedTransport() == .daemon {
            let result = PrivilegedClient.shared.stopTunnel()
            appendLog("[anyway] privileged daemon stop: \(result.message)")
            if result.ok {
                try? FileManager.default.removeItem(at: endpointFile)
                return
            }
            appendLog("[anyway] daemon stop failed — falling back to sudo")
            invalidateTransportCache()
        }
        var pids: [String] = []
        // The helper writes a root-owned pid file; the no-helper fallback writes
        // one in the state dir. pgrep below covers both regardless.
        for url in [helperPidFile, pidFile] {
            if let s = try? String(contentsOf: url, encoding: .utf8) {
                pids += s.split(whereSeparator: { $0.isNewline || $0 == " " }).map(String.init)
            }
        }
        pids += shellCapture("/usr/bin/pgrep", ["-f", "openconnect .*(route-wrapper\\.sh|--cookie-on-stdin)"])
            .split(whereSeparator: { $0.isNewline }).map(String.init)
        let unique = Array(Set(pids.filter { !$0.isEmpty && Int($0) != nil }))
        if !unique.isEmpty {
            if helperIsUsable() {
                _ = shellCapture("/usr/bin/sudo", ["-n", rootHelper, "stop"] + unique)
            } else {
                // Same reasoning as the root helper's stop: give the graceful
                // teardown time to run its disconnect script before escalating.
                _ = shellCapture("/usr/bin/sudo", ["kill", "-INT"] + unique)
                var waited = 0.0
                while waited < 10.0, isRunning() {
                    Thread.sleep(forTimeInterval: 0.25); waited += 0.25
                }
                if isRunning() {
                    _ = shellCapture("/usr/bin/sudo", ["kill", "-TERM"] + unique)
                }
            }
        }
        try? FileManager.default.removeItem(at: pidFile)
        try? FileManager.default.removeItem(at: endpointFile)
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

    // Capture the current physical default gateway + interface as "gw|iface".
    func snapshotDefaultRoute() -> String {
        let out = shellCapture("/sbin/route", ["-n", "get", "default"])
        var gw = "", ifc = ""
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("gateway:") { gw = t.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("interface:") { ifc = t.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces) }
        }
        // Only trust a physical interface (en*/bridge*), not a tunnel (utun*).
        if ifc.hasPrefix("utun") { return "" }
        return gw.isEmpty ? "" : "\(gw)|\(ifc)"
    }

    // Restore the physical default route if it was clobbered by a failed tunnel.
    func restoreDefaultRoute(_ snapshot: String) {
        guard !snapshot.isEmpty else { return }
        let parts = snapshot.split(separator: "|").map(String.init)
        guard let gw = parts.first, !gw.isEmpty else { return }
        let iface = parts.count > 1 ? parts[1] : ""

        // Only act if the current default is missing or points at a tunnel.
        let current = shellCapture("/sbin/route", ["-n", "get", "default"])
        let onTunnel = current.range(of: "interface: utun", options: .regularExpression) != nil
        let noDefault = current.range(of: "gateway:") == nil
        guard onTunnel || noDefault else { return }  // physical default already fine

        if privilegedTransport() == .daemon {
            let result = PrivilegedClient.shared.restoreDefaultRoute(gateway: gw, interface: iface)
            if result.ok {
                NSLog("AnywayConnect: \(result.message)")
                return
            }
            invalidateTransportCache()
        }
        if helperIsUsable() {
            var args = ["-n", rootHelper, "restore-default", gw]
            if !iface.isEmpty { args.append(iface) }
            _ = shellCapture("/usr/bin/sudo", args)
        } else {
            _ = shellCapture("/usr/bin/sudo", ["/sbin/route", "-n", "change", "default", gw])
        }
        NSLog("AnywayConnect: restored default route via \(gw) \(iface)")
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
