import Foundation
import ServiceManagement

// ── App side of the privileged channel ───────────────────────────────────────
//
// Wraps two things: registering the launchd daemon through SMAppService, and
// talking to it over XPC.
//
// The calls are exposed synchronously because VPNRunner drives the connect
// sequence step by step on a background queue, and an async API there would just
// mean reimplementing the same waiting with more moving parts. Every call is
// bounded by a timeout so a wedged daemon degrades to the sudo fallback instead
// of hanging the connect.

final class PrivilegedClient {
    static let shared = PrivilegedClient()

    private let lock = NSLock()
    private var connection: NSXPCConnection?

    private init() {}

    // MARK: - Registration

    var service: SMAppService {
        SMAppService.daemon(plistName: "\(privilegedDaemonLabel()).plist")
    }

    var status: SMAppService.Status { service.status }

    /// Whether this build *could* register the daemon, as opposed to simply never having
    /// done so.
    ///
    /// Decided by the only two things that actually determine it: a signing identity to
    /// authenticate with, and a plist to register. Everything else is a matter of state.
    var canRegister: Bool {
        guard currentCodeIdentity() != nil else { return false }
        let plist = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Library/LaunchDaemons/\(privilegedDaemonLabel()).plist")
        return FileManager.default.fileExists(atPath: plist.path)
    }

    /// The status with `.notFound` folded into `.notRegistered` where registering is
    /// possible — which is what the UI should act on.
    ///
    /// SMAppService returns `.notFound` when it holds no record of the service at all,
    /// and that covers two situations needing opposite treatment: a build that cannot
    /// register (unsigned, or missing its plist), and a build that simply has not
    /// registered yet. `.notRegistered` turns out to mean something narrower — the state
    /// after an explicit unregister — so a bundle identifier that has never registered
    /// reports `.notFound` forever.
    ///
    /// Renaming the app to a new identifier put it in exactly that state, and reporting
    /// it as "unavailable in this build" greyed out the Install button, leaving no way to
    /// install the daemon at all. Confirmed by probe: a signed, never-registered bundle
    /// reports `.notFound` both from /tmp and from the user's home, so the status on its
    /// own cannot tell the two apart.
    var effectiveStatus: SMAppService.Status {
        let raw = status
        return (raw == .notFound && canRegister) ? .notRegistered : raw
    }

    /// Human-readable state, for the Settings pane.
    var statusDescription: String {
        switch status {
        // Kept short deliberately. These land in a status label next to a fixed
        // 320pt control column, and the old requiresApproval string was ~339pt
        // wide — long enough to stretch the pane on its own. Where to approve is
        // the "Open Login Items…" button's job, not this label's.
        case .notRegistered:    return "Not installed"
        case .enabled:          return "Installed and enabled"
        case .requiresApproval: return "Waiting for approval"
        case .notFound:         return "Not found"
        @unknown default:       return "Unknown"
        }
    }

    /// Registering is what prompts the user to approve the background item.
    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    /// Replace any existing registration with the daemon in this bundle.
    ///
    /// `unregister()` returns before launchd has finished tearing the job down, so an
    /// immediate `register()` fails with "Operation not permitted" — which looked like
    /// the update had failed when it had in fact done half the work, leaving the
    /// button on "Install" so that a second click (by which time the teardown had
    /// settled) succeeded. Neither step is retried blindly: wait for the status to
    /// actually reach `.notRegistered`, then register, and only retry the register
    /// while launchd is still refusing.
    ///
    /// Must not be called on the main thread — it blocks. `runPrivileged` guarantees
    /// that by running its work on a background queue.
    func reregister() throws {
        // Registered but not yet approved is NOT something re-registering fixes: the
        // registration is already correct and only the user's toggle is outstanding.
        // Tearing it down would strand us — unregister() succeeds, register() is then
        // refused for the same reason, and we end up with no registration at all.
        if effectiveStatus == .requiresApproval {
            throw RegistrationRefused(underlying: SimpleReason(
                "the daemon is registered but still waiting for approval"))
        }
        // effectiveStatus throughout, so a first install on a never-registered
        // identifier — which reports .notFound, not .notRegistered — takes the "nothing
        // to tear down" path. Reading the raw status here meant a first install tried to
        // unregister a service that had never existed, then waited five seconds for a
        // .notRegistered it could never reach, and provoked exactly the refusal the
        // waiting was meant to avoid.
        if effectiveStatus != .notRegistered {
            try? unregister()
            let deadline = Date().addingTimeInterval(5)
            while effectiveStatus != .notRegistered, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        // Bounded, and it gives up the moment a register succeeds. A genuinely
        // impossible registration (an unsigned build, say) still ends in a throw,
        // just a couple of seconds later.
        var lastError: Error?
        let deadline = Date().addingTimeInterval(3)
        repeat {
            do { try register(); return } catch { lastError = error }
            // Judged by the state macOS ends up in, not by what the call returned.
            // register() can throw and still have created the registration — the user
            // then saw "Couldn't install the privileged daemon" over a daemon that was
            // installed and merely waiting for approval. Same principle as restarting the
            // app: trust the observable result, not the API's word for it.
            if isRegistered { return }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        if isRegistered { return }
        if let lastError { throw RegistrationRefused(underlying: lastError) }
    }

    /// True once macOS holds a registration, whether or not it has been approved yet.
    /// `.requiresApproval` counts: the registration exists and only the user's toggle is
    /// outstanding, which is a successful install and not a failed one.
    private var isRegistered: Bool {
        let s = status
        return s == .enabled || s == .requiresApproval
    }

    /// `register()` failing persistently is usually not a race — it is macOS declining
    /// because the background item's Background Task Management disposition is
    /// `disabled`, which is what the user sees as a bare "Operation not permitted".
    /// No amount of retrying moves that, and the raw message gives no clue what to do,
    /// so say where the switch is.
    /// Carries a plain explanation where there is no underlying system error to quote.
    struct SimpleReason: LocalizedError {
        let text: String
        init(_ text: String) { self.text = text }
        var errorDescription: String? { text }
    }

    struct RegistrationRefused: LocalizedError {
        let underlying: Error
        var errorDescription: String? {
            "macOS refused to register the background daemon: "
            + underlying.localizedDescription
            + "\n\nThis usually means its background item is switched off. Open "
            + "System Settings ▸ General ▸ Login Items & Extensions, enable "
            + "AnywayConnect under “Allow in the Background”, then try again."
        }
    }

    // MARK: - Connection

    private func currentProxy(_ onError: @escaping (Error) -> Void) -> PrivilegedHelperProtocol? {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            // .privileged: the peer is a root launchd daemon.
            let c = NSXPCConnection(machServiceName: privilegedDaemonLabel(), options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
            // Refuse to talk to anything that isn't our signed daemon, so a
            // hijacked Mach name can't impersonate it.
            // Fail closed: ad-hoc signed builds have no team, so there is no
            // requirement to enforce and the daemon path must not be used.
            guard let requirement = daemonCodeRequirement() else {
                NSLog("AnywayConnect: unsigned build — refusing to use the privileged daemon")
                return nil
            }
            c.setCodeSigningRequirement(requirement)
            let drop: () -> Void = { [weak self] in
                guard let self = self else { return }
                self.lock.lock(); self.connection = nil; self.lock.unlock()
            }
            c.invalidationHandler = drop
            c.interruptionHandler = drop
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? PrivilegedHelperProtocol
    }

    /// Run one XPC call, blocking up to `timeout`. Returns nil on timeout or
    /// transport failure, which callers treat as "fall back to sudo".
    private func call<T>(timeout: TimeInterval = 5,
                         _ body: (PrivilegedHelperProtocol, @escaping (T) -> Void) -> Void) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: T?
        var failed = false

        guard let proxy = currentProxy({ error in
            NSLog("AnywayConnect: privileged XPC error: \(error.localizedDescription)")
            failed = true
            semaphore.signal()
        }) else { return nil }

        body(proxy) { value in
            result = value
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut { return nil }
        return failed ? nil : result
    }

    // MARK: - Operations

    /// Protocol version the installed daemon speaks, or nil if unreachable.
    func daemonVersion() -> Int? {
        call(timeout: 3) { proxy, done in proxy.version(reply: { done($0) }) }
    }

    /// Key for the test override below. Deliberately verbose so it is obvious in
    /// `defaults read` what it is and that it isn't a normal setting.
    static let expectedVersionOverrideKey = "DebugExpectedProtocolVersion"

    /// Protocol version this build demands of the daemon.
    ///
    /// Normally `kPrivilegedProtocolVersion`. It can be overridden at runtime
    /// because `PrivilegedProtocol.swift` compiles into *both* the app and the
    /// daemon — bumping the constant would move the daemon's answer too, so the
    /// mismatch could never be observed. Overriding only the app's expectation
    /// produces a genuine version disagreement against the real installed daemon:
    ///
    ///   defaults write me.kairyu.anywayconnect DebugExpectedProtocolVersion 2
    ///   defaults delete me.kairyu.anywayconnect DebugExpectedProtocolVersion
    ///
    /// Values below the real version are ignored: the override exists to demand
    /// *more* than the daemon offers, never to accept less, so it cannot be used
    /// to weaken the compatibility check.
    var expectedProtocolVersion: Int {
        let v = UserDefaults.standard.integer(forKey: Self.expectedVersionOverrideKey)
        return v > kPrivilegedProtocolVersion ? v : kPrivilegedProtocolVersion
    }

    /// True when a test override is raising the bar above what this build ships.
    var expectedVersionIsOverridden: Bool {
        expectedProtocolVersion != kPrivilegedProtocolVersion
    }

    /// Whether the installed daemon speaks a protocol this build can use.
    enum Compatibility: Equatable {
        case unreachable
        case current(version: Int)
        case outdated(version: Int, expected: Int)
    }

    private var cachedCompat: (value: Compatibility, at: Date)?

    /// The version check, in the form the UI needs: not just the number, but
    /// whether it is usable. Reporting the raw version was misleading — an
    /// outdated daemon answers `version` perfectly well, so the status looked
    /// healthy while isUsable() was rejecting it and connects fell back to sudo.
    ///
    /// Safe to call from a repeating UI poll: short timeout and a brief cache, so
    /// a hung daemon cannot stall the main thread every couple of seconds.
    func daemonCompatibility() -> Compatibility {
        lock.lock()
        let cached = cachedCompat
        lock.unlock()
        if let c = cached, Date().timeIntervalSince(c.at) < 4 { return c.value }

        // Deliberately outside the lock: call() acquires it to build the proxy.
        let probed: Int? = call(timeout: 1.5) { proxy, done in proxy.version(reply: { done($0) }) }
        let result: Compatibility
        switch probed {
        case .none:
            result = .unreachable
        case .some(let v) where v >= expectedProtocolVersion:
            result = .current(version: v)
        case .some(let v):
            result = .outdated(version: v, expected: expectedProtocolVersion)
        }
        lock.lock()
        cachedCompat = (result, Date())
        lock.unlock()
        return result
    }

    func invalidateVersionCache() {
        lock.lock()
        cachedCompat = nil
        lock.unlock()
    }

    /// True only when the daemon is registered, reachable, and speaks a
    /// compatible protocol. Anything else means use the sudo path.
    func isUsable() -> Bool {
        guard status == .enabled else { return false }
        guard let version = daemonVersion() else { return false }
        return version >= expectedProtocolVersion
    }

    func startTunnel(protocolName: String, host: String, fingerprint: String, resolve: String,
                     autoAddLocalSubnet: Bool, exceptionRoutes: [String],
                     logPath: String, cookie: String) -> (ok: Bool, message: String) {
        let result: (Bool, String)? = call(timeout: 20) { proxy, done in
            proxy.startTunnel(protocolName: protocolName, host: host, fingerprint: fingerprint,
                              resolve: resolve, autoAddLocalSubnet: autoAddLocalSubnet,
                              exceptionRoutes: exceptionRoutes, logPath: logPath,
                              cookie: cookie) { ok, message in done((ok, message)) }
        }
        guard let result = result else { return (false, "privileged daemon did not respond") }
        return result
    }

    func stopTunnel() -> (ok: Bool, message: String) {
        // Generous: the daemon waits up to 10s for a graceful teardown.
        let result: (Bool, String)? = call(timeout: 20) { proxy, done in
            proxy.stopTunnel { ok, message in done((ok, message)) }
        }
        guard let result = result else { return (false, "privileged daemon did not respond") }
        return result
    }

    func tunnelStatus() -> (running: Bool, pid: Int)? {
        let result: (Bool, Int)? = call(timeout: 3) { proxy, done in
            proxy.tunnelStatus { running, pid in done((running, pid)) }
        }
        guard let result = result else { return nil }
        return (result.0, result.1)
    }

    func restoreDefaultRoute(gateway: String, interface: String) -> (ok: Bool, message: String) {
        let result: (Bool, String)? = call(timeout: 10) { proxy, done in
            proxy.restoreDefaultRoute(gateway: gateway, interface: interface) { ok, message in
                done((ok, message))
            }
        }
        guard let result = result else { return (false, "privileged daemon did not respond") }
        return result
    }
}
