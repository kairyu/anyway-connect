import Foundation

// ── Reading the live network state, as pure functions ────────────────────────
//
// Compiled into BOTH targets, so Foundation-only.
//
// Everything here takes its input as a parameter and returns a value. No
// `Process`, no file I/O, no global reads — with exactly one labelled exception
// (`NetState.load`). That is not tidiness: the machine this code was written on
// is live on the VPN with ~122 static routes, so the only way to test a route
// sweep at all is to feed a checked-in `netstat` capture to a function that
// cannot touch anything.
//
// The split is deliberate and worth keeping: `NetProbe` (in NetGuard.swift) is
// fixed command lines, this file is every decision about what their output
// means, and the daemon is execution with no decisions of its own.

public enum NetReconcile {

    // MARK: - netstat -rn -f inet

    /// One row of the IPv4 routing table.
    public struct RouteEntry: Equatable {
        public enum Destination: Equatable {
            case defaultRoute
            case host(IPv4)
            case network(IPv4, prefixLength: Int)
            /// Kept, never acted on. A destination we cannot name exactly cannot
            /// be named exactly to `route delete` either, and guessing is how you
            /// delete the wrong route. Carries the destination text as printed.
            case unparsable(String)
        }

        public let destination: Destination
        /// As printed: may be `link#15`, a MAC address, or an IPv4 literal.
        public let gatewayText: String
        /// Non-nil ONLY for a strict dotted quad. `nil` is read by the sweep
        /// classifier as "on-link, not via a router".
        public let gateway: IPv4?
        public let flags: String
        public let netif: String

        public init(destination: Destination, gatewayText: String,
                    gateway: IPv4?, flags: String, netif: String) {
            self.destination = destination
            self.gatewayText = gatewayText
            self.gateway = gateway
            self.flags = flags
            self.netif = netif
        }

        public var isHostFlagged: Bool { flags.contains("H") }

        /// RTF_IFSCOPE. Verified live: the destinations that appear twice differ
        /// by exactly this letter — `23.192.46.11/32 … UGSc en0` beside
        /// `… UGScI en0`, and `default … UGScg utun7` (unscoped) beside
        /// `default … UGScIg en0` (scoped). Case-sensitive: the lowercase `i` is
        /// RTF_IFREF and means something else entirely.
        public var isIfScoped: Bool { flags.contains("I") }
    }

    /// Parses `netstat -rn -f inet` output.
    ///
    /// Column indices are DERIVED FROM THE HEADER, never positional. This
    /// machine prints the five-column `Destination Gateway Flags Netif Expire`,
    /// but `LSMinimumSystemVersion` is 13.0 and older `netstat` layouts carry
    /// `Refs`/`Use` between `Flags` and `Netif`. Reading `Netif` as the fourth
    /// field there makes every netif a number: no `utun` default is recognised as
    /// tunnel-like and every scoped deletion is aimed at `-ifscope 0`. A silent
    /// no-op is better than a wrong deletion, but it is still a repair that does
    /// not happen on the OS floor we claim to support.
    ///
    /// Returns `[]` when the header is absent or lacks any of the four columns —
    /// FAIL CLOSED, which §4.3(d′) turns into `abort = .routeTableUnreadable`,
    /// i.e. configd removals only and no route reasoning at all.
    public static func parseRouteTable(_ text: String) -> [RouteEntry] {
        var iDst = -1, iGw = -1, iFlags = -1, iNetif = -1
        var sawHeader = false
        var rows: [RouteEntry] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let firstField = fields.first else { continue }

            if !sawHeader {
                // Everything before the header — the "Routing tables" and
                // "Internet:" banners, blank lines — is skipped.
                guard firstField == "Destination" else { continue }
                iDst = fields.firstIndex(of: "Destination") ?? -1
                iGw = fields.firstIndex(of: "Gateway") ?? -1
                iFlags = fields.firstIndex(of: "Flags") ?? -1
                iNetif = fields.firstIndex(of: "Netif") ?? -1
                guard iDst >= 0, iGw >= 0, iFlags >= 0, iNetif >= 0 else { return [] }
                sawHeader = true
                continue
            }

            // A repeated header (a second address family's section) is not data.
            if firstField == "Destination" { continue }
            let needed = max(max(iDst, iGw), max(iFlags, iNetif)) + 1
            // `Refs`, `Use`, `Expire` and the trailing `!` are read past, never
            // counted on; a row too short to carry the four columns we need is
            // not interpreted at all.
            guard fields.count >= needed else { continue }

            let gatewayText = fields[iGw]
            rows.append(RouteEntry(destination: parseDestination(fields[iDst]),
                                   gatewayText: gatewayText,
                                   gateway: IPv4(gatewayText),
                                   flags: fields[iFlags],
                                   netif: fields[iNetif]))
        }
        return rows
    }

    /// netstat prints ABBREVIATED destinations, with trailing zero octets
    /// dropped, and in two different forms. Both are handled here and nowhere
    /// else.
    private static func parseDestination(_ field: String) -> RouteEntry.Destination {
        if field == "default" { return .defaultRoute }

        if field.contains("/") {
            let parts = field.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let prefix = Int(parts[1]), (0...32).contains(prefix),
                  let addr = paddedIPv4(String(parts[0])),
                  addr.masked(bits: prefix) == addr
            else { return .unparsable(field) }
            // NOTE: rule 4's octet-count cross-check deliberately does NOT apply
            // here. netstat prints the abbreviated address independently of the
            // printed prefix, so `224.0.0/4` — three octets against a /4 — is a
            // real row of the captured fixture. Importing the cross-check would
            // turn it into `.unparsable` and silently change the counts the
            // tests assert.
            return .network(addr, prefixLength: prefix)
        }

        let octets = field.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4 {
            guard let addr = IPv4(field) else { return .unparsable(field) }
            return .host(addr)
        }
        guard (1...3).contains(octets.count), let addr = paddedIPv4(field) else {
            return .unparsable(field)
        }
        // The historical class mask netstat omits: `207.226.132` ⇒ /24,
        // `172.17` ⇒ /16, `10` ⇒ /8. HERE — and only here, because the prefix is
        // INFERRED from the octet count rather than printed — the two are
        // cross-checked against each other.
        let prefix = octets.count * 8
        guard octets.count == (prefix + 7) / 8, addr.masked(bits: prefix) == addr else {
            return .unparsable(field)
        }
        return .network(addr, prefixLength: prefix)
    }

    /// Right-pads an abbreviated address with `.0` to four octets and parses it
    /// strictly. Strictly, so `010.0.1` is a parse failure rather than quietly
    /// becoming something `route` would read differently.
    private static func paddedIPv4(_ s: String) -> IPv4? {
        let octets = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(octets.count) else { return nil }
        let padded = octets.map(String.init) + Array(repeating: "0", count: 4 - octets.count)
        return IPv4(padded.joined(separator: "."))
    }

    // MARK: - Two pure reductions of collector output
    //
    // Both are decisions, and both have a wrong reading that real output rewards,
    // which is why neither lives inside the collector that produces the text.

    /// `scutil` prints DISPLAY lines, not bare keys. Verified live:
    ///
    ///     subKey [2] = State:/Network/Service/utun7/DNS
    ///
    /// Each line is reduced to the text after its FIRST `" = "`, trimmed; a line
    /// without `" = "` is dropped. NO filtering — selecting which services
    /// matter is the planner's job, on bare keys.
    public static func configdKeys(fromScutilOutput text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let r = line.range(of: " = ") else { return nil }
            let key = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : key
        }
    }

    /// `ipconfig getsummary en0` emits three Router-ish lines (verified live):
    ///
    ///     router (ip_mult): {10.0.1.1}
    ///     Router : 10.0.1.1
    ///     RouterARPVerified : TRUE
    ///
    /// so "the Router line" has more than one reading and a prefix match picks
    /// the wrong one. The rule is deliberately narrow: split each line on its
    /// FIRST `":"`, trim both sides, and accept only when the left side is
    /// exactly `Router` (case-sensitive) and the right side is a strict dotted
    /// quad. `router (ip_mult)` and `RouterARPVerified` both fail the left-hand
    /// test; `TRUE` would fail the right-hand one. First match wins.
    public static func parseRouterFromSummary(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1,
                                   omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "Router" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if IPv4(value) != nil { return value }
        }
        return nil
    }
}

// MARK: - The reconcile plan
//
// What a reconcile would do, as a value. The daemon's apply phase is a `switch`
// with no decision of its own, which is the whole point: the risky reasoning —
// "is this route dead", "may this default be deleted", "what do we install
// instead" — is decided here, by a function that cannot touch the system, and is
// asserted against checked-in captures of real route tables.

public enum ReconcileAction: Equatable {
    case removeConfigdKey(String)                                        // FR-2.5
    case deleteTunnelDefaultRoute(netif: String, ifscoped: Bool)         // FR-2.4
    case deleteStalePhysicalDefaultRoute(netif: String, ifscoped: Bool,
                                         reason: GatewayRejection)       // §4.3(b)
    case deleteRoute(RouteDeletion)                                      // FR-2.6 / FR-2.7
    case installDefaultRoute(interface: String)                          // FR-2.8
}

public struct RouteDeletion: Equatable {
    public let destination: String       // canonical dotted quad
    public let netmask: String?          // nil ⇒ host route
    public let ifscope: String?          // nil ⇒ the unscoped form

    public init(destination: String, netmask: String?, ifscope: String?) {
        self.destination = destination
        self.netmask = netmask
        self.ifscope = ifscope
    }
}

/// Diagnostic only; never executed. Present because "we left this alone" is the
/// answer that needs explaining, and because the tests assert the absence of a
/// deletion by asserting what was kept instead.
public enum ReconcileKept: Equatable {
    case onLinkRoute(String)
    case loopback(String)
    case multicast(String)
    case linkLocal(String)
    case gatewayOnLink(String, via: String)
    /// A route whose next hop is still held by a LIVE tunnel interface. Not
    /// deleted, because FR-2.6c forbids deleting a route whose gateway is on-link
    /// for some live interface — a vanished tunnel's address is swept, which is
    /// the common case after a dead tunnel (open issue O-1).
    case tunnelOnLinkGateway(String, via: String)
    /// A route whose next hop sits INSIDE a live physical link's subnet but is not
    /// itself an installable next hop: the link's own address, or that subnet's
    /// network or broadcast address. FR-2.6c forbids deleting it — the gateway IS
    /// on-link for a live interface — even though the guard would refuse to
    /// install it. `why` is the guard's rejection reason, so a test can assert
    /// which of the three it was.
    ///
    /// Recorded separately from `gatewayOnLink` rather than folded into it,
    /// because the two answer different questions: that one says "a usable next
    /// hop", this one says "an unusable next hop we are nonetheless not allowed to
    /// delete". Also see §4.3(b): for a DEFAULT route these same three reasons
    /// authorise deletion. That is not a contradiction — see the comment at the
    /// sweep's classifier.
    case gatewayInLiveSubnet(String, via: String, why: String)
    case unparsable(String)
    /// A default route on a non-tunnel interface that is UNSCOPED and whose next
    /// hop the guard accepts. The thing being protected, and the only thing that
    /// counts as "a usable physical default already exists" in (f).
    case physicalDefaultUsable(netif: String)
    /// A default route on a non-tunnel interface we neither delete nor count as
    /// usable: scoped-only though otherwise fine, a down link, or an `-interface`
    /// default with no IPv4 next hop. `why` is a short fixed string, so a test can
    /// assert it.
    case physicalDefaultUnusable(netif: String, why: String)
    /// A tunnel that was SEEN but is not in scope: it is live, and it is not the
    /// one the attribution record names and witnesses as ours. Whoever it
    /// belongs to, it is left alone.
    ///
    /// The case predates this change set; its sense widened from "named in a
    /// connect-time list" to "seen but not in scope", which is accurate for
    /// every member — see the scope derivation in `plan`.
    case foreignTunnel(String)
    /// The record named a LIVE tunnel as ours and the address witness did not
    /// match it, so the scope narrowed to dead-only. Diagnostic, and the one
    /// record that explains why a lingering interface of ours was not repaired.
    case liveTunnelIdentityUnproven(IdentityUnproven)
    /// (f): the install this plan would have emitted, withheld because an
    /// UNSCOPED default route this plan is not deleting survives on `netif`.
    /// `route -n add default` could then only return EEXIST, so the action's
    /// postcondition is unsatisfiable before it is emitted — and the apply
    /// discards the status it would need to notice (the daemon's two bare
    /// `run(...)` calls, with the transcript line appended unconditionally).
    case installWithheldForSurvivingDefault(netif: String)
    case ambiguousInstallTarget([String])
    /// (g): PHYSICAL default-route deletions this plan dropped because it could
    /// not also install one. The record of the one asymmetry that is never allowed
    /// to resolve the other way.
    case defaultDeletionsWithheld(netifs: [String])
}

public enum ReconcileAbort: Equatable {
    case sweepCapExceeded(found: Int, cap: Int)
    case routeTableUnreadable
    /// The interface snapshot cannot prove anything on-link — see (d″). Distinct
    /// from `routeTableUnreadable` because the suppressed clauses are the same but
    /// the input that failed is not, and the transcript has to name which.
    case interfaceSnapshotUnusable
}

public struct ReconcilePlan: Equatable {
    public var actions: [ReconcileAction]      // ordered; apply executes in this order
    public var kept: [ReconcileKept]
    public var abort: ReconcileAbort?
    /// The plan-time gateway candidates for the install target, as text, so apply
    /// can log a plan-time/apply-time divergence. Diagnostic only; nil when no
    /// install was emitted.
    public var installCandidateNote: String?

    public init(actions: [ReconcileAction] = [], kept: [ReconcileKept] = [],
                abort: ReconcileAbort? = nil, installCandidateNote: String? = nil) {
        self.actions = actions
        self.kept = kept
        self.abort = abort
        self.installCandidateNote = installCandidateNote
    }

    public var isEmpty: Bool { actions.isEmpty }
}

// THREE UNVERIFIED PLATFORM ASSUMPTIONS, recorded here because this is the type
// that names every command they concern, and it compiles into both targets.
//
// None of them could be checked while this was written: the only machine available
// was live on the VPN with ~122 static routes installed, and confirming any of the
// three requires executing the very mutation it is an assumption about. They are
// assumptions, not observations, and the first real exercise of them is a
// reconcile the user runs deliberately on a machine of their choosing.
//
//  1. `route -n delete default -ifscope <iface>` removes exactly the row scoped to
//     that interface, and never the unscoped default. The whole scoping split in
//     `plan` rests on this: if it silently fell through to the unscoped row it
//     would delete a working physical default while reporting a tunnel cleanup.
//  2. `route -n add default <gw>` fails with EEXIST when a default already exists,
//     rather than replacing it. Every add here is issued unconditionally and its
//     status ignored on that basis (see the daemon's restore, which reports the
//     branch it took instead of the exit status).
//  3. `scutil remove <key>` on a key that is not present is harmless — it may
//     report failure, but it neither removes anything else nor leaves the
//     configd session in a state that breaks the remaining removals in the same
//     open/close batch. The configd keys are read before the batch is built, so
//     this only matters when a key disappears in between.
public enum ReconcileCommand: Equatable {
    /// One scutil invocation for every configd key, stdin = "open\nremove K\n…\nclose\n".
    /// Assumption 3 above: a key that vanished between the read and this batch is
    /// not fatal to the rest of the batch.
    case scutil(stdin: String, keys: [String])
    /// A single deterministic /sbin/route invocation, argv complete. Carries
    /// assumptions 1 (the `-ifscope` deletions) and 2 (the adds) above.
    case route(argv: [String])
    /// The ONLY state-dependent command: delete the unscoped default repeatedly,
    /// but each time only while `route -n get default` still names this interface.
    /// Expressed as a command rather than as argv because its stop condition is
    /// the live table.
    case deleteUnscopedDefaultWhileInterface(netif: String, maxIterations: Int)
    /// Re-probe, derive, guard, install. Daemon-only execution.
    case deriveAndInstallDefault(interface: String)
}

/// Partitioned, not a flat list. `prologue` and `install` are ESSENTIAL and run
/// regardless of elapsed time; `sweep` is best-effort under a deadline. The
/// install is the one command whose omission turns this operation into the very
/// outcome it exists to prevent, so it can never be the thing a budget drops.
public struct ReconcileCommands: Equatable {
    public let prologue: [ReconcileCommand]   // configd + every default-route deletion
    public let sweep: [ReconcileCommand]      // the per-destination deletions
    public let install: [ReconcileCommand]    // .deriveAndInstallDefault, or empty

    public init(prologue: [ReconcileCommand], sweep: [ReconcileCommand],
                install: [ReconcileCommand]) {
        self.prologue = prologue
        self.sweep = sweep
        self.install = install
    }

    public var essential: [ReconcileCommand] { prologue + install }

    /// APPLY ORDER: prologue, then install, then sweep.
    ///
    /// The install is deliberately NOT last. Sweeping first leaves the machine with no
    /// default route for the whole sweep window — a few seconds on a carried-home table
    /// of ~117 destinations — which is the very outage this operation exists to end.
    /// Nothing in the sweep depends on the default being absent: every deletion names
    /// its own destination.
    public var all: [ReconcileCommand] { prologue + install + sweep }
    public var isEmpty: Bool { all.isEmpty }
}

public enum ReconcileGate: Equatable {
    case proceed
    case noop(alivePID: Int32)
}

/// WHICH TUNNELS CLAUSES (a) AND (b) MAY ACT ON, and the whole of defect 2's
/// scope decision:
///
///   reconcile acts on a tunnel IFF its interface is absent from a USABLE
///   interface snapshot — provably dead, so nothing running owns it — OR the
///   attribution record names it as ours AND its live address equals the
///   address we recorded for it.
///
/// There is deliberately no "which tunnels are not ours" list anywhere in this
/// decision. That list is what went wrong: it was written at connect time, read
/// on every reconcile, and deleted by a clean stop, so the protection it gave
/// evaporated exactly when it was needed. The complement is derived from
/// LIVENESS instead, freshly, every time — so a third-party tunnel is protected
/// by being UP rather than by appearing on any list, including one brought up
/// after our connect, or next week.
public enum TunnelScope: Equatable {
    /// The interface snapshot cannot be trusted, so neither "live" nor "dead"
    /// can be established. Act on nothing — route or configd (§3.5.1).
    case none
    /// Act on tunnels absent from the snapshot. `identityUnproven` is
    /// diagnostic: the record named a live tunnel and the witness did not match.
    case deadOnly(identityUnproven: IdentityUnproven?)
    /// Act on tunnels absent from the snapshot, PLUS this live one, which the
    /// record names and whose live address equals the recorded witness.
    case deadPlus(ours: String)
}

/// Why a live tunnel the record claims is ours was nonetheless left alone. Both
/// addresses are carried so the transcript says which comparison failed rather
/// than only that one did.
public struct IdentityUnproven: Equatable {
    public let netif: String
    public let recordedAddress: String?
    public let liveAddress: String?

    public init(netif: String, recordedAddress: String?, liveAddress: String?) {
        self.netif = netif
        self.recordedAddress = recordedAddress
        self.liveAddress = liveAddress
    }
}

extension NetReconcile {

    /// FR-2.7. Bounds DISTINCT swept destinations — not emitted actions and not
    /// netstat rows. Each distinct destination emits one unscoped deletion plus one
    /// deletion per interface it was scoped to, so the worst case for 256 is a few
    /// hundred `route` invocations, additionally bounded by the sweep phase's
    /// budget. 256 covers the observed 117 with headroom.
    public static let sweepCap = 256

    /// FR-2.2's judgement, and the single safety-critical gate in the whole
    /// operation: a reconcile must never run while a tunnel of ours is alive. Pure,
    /// so it is testable with literals — no live tunnel, no installed daemon.
    ///
    /// A frozen-but-alive openconnect counts as alive, which is correct:
    /// dismantling the routing of a tunnel that may still recover is the one thing
    /// this operation must never do.
    public static func gate(pids: [Int32], isAlive: (Int32) -> Bool) -> ReconcileGate {
        if let pid = pids.first(where: isAlive) { return .noop(alivePID: pid) }
        return .proceed
    }
}

// MARK: - What a stop attempt found and achieved

/// Placed immediately after `NetReconcile.gate`, which is the precedent: this
/// file is the "decisions, no I/O" layer compiled into BOTH targets, and `gate`
/// is already a pure safety decision the harness drives from literals. The
/// extension above is closed and reopened below rather than nesting this type,
/// because the daemon, the app and the harness all name it bare.
///
/// PURE throughout: the observations go in and the verdict comes out, so every
/// reply string is assertable without signalling a real process — which is the
/// only way any of this can be tested on the machine it was written on.
///
/// Why it exists. `stopTunnel` used to reply `true` unconditionally: it replied
/// "no tunnel running" when it had only failed to find one, and "stopped
/// (escalated)" after a SIGTERM it never observed the result of. The app then
/// deleted its endpoint record while openconnect was alive, its `pgrep` status
/// poll found the tunnel 8 s later with no endpoint record to name it, and the
/// menu settled on "Connected: ?".
public enum TunnelStop {

    /// What a candidate pid turned out to be. `.gone` is distinguished from
    /// `.unknown` because `proc_pidpath` failing with `ESRCH` is INFORMATION —
    /// the process exited between the liveness check and the probe — while any
    /// other failure means the probe itself told us nothing.
    public enum Identity: Equatable { case ourOpenconnect, notOurs, gone, unknown }

    public struct Targets: Equatable {
        /// Alive, and established as ours. These, and only these, get SIGINT.
        public var signal: [Int32]
        /// Alive and NOT established as ours. Never signalled, and never
        /// evidence that nothing is running.
        public var notOursLive: [Int32]
        /// Alive, ours-or-not unknowable because the probe failed. Never
        /// signalled, and never evidence that nothing is running.
        public var unidentified: [Int32]
        /// Named BY THE PID FILE and either gone or provably dead. The only
        /// evidence that licenses removing that file.
        public var stalePIDFile: [Int32]

        public init(signal: [Int32] = [], notOursLive: [Int32] = [],
                    unidentified: [Int32] = [], stalePIDFile: [Int32] = []) {
            self.signal = signal
            self.notOursLive = notOursLive
            self.unidentified = unidentified
            self.stalePIDFile = stalePIDFile
        }
    }

    public enum Verdict: Equatable {
        /// Nothing of ours was found alive. Nothing was signalled.
        case nothingToStop(clearedStalePIDFile: Bool, notOursLive: [Int32])
        /// Every signalled process was observed to exit. `escalated` means
        /// SIGTERM was needed, so `vpnc-script`'s disconnect may have been cut
        /// short. `unidentified` rides along because a stop that left a live
        /// unidentifiable process behind has NOT established that nothing of
        /// ours runs, and `isSuccess` keys on exactly that.
        case stopped(pids: [Int32], escalated: Bool, unidentified: [Int32])
        /// Signalled, and at least one survivor is alive at the end of the
        /// bound. NOT a success.
        case stuck(pids: [Int32], survivors: [Int32])
        /// A live process was found and could not be established as ours, so it
        /// was NOT signalled. NOT a success: something may be running.
        case unidentified(pids: [Int32])
    }

    /// Does this pid look like OUR openconnect, strongly enough to send it
    /// SIGINT as root? Three conjuncts, all required:
    ///
    ///   1. the caller can name the executable at all — for the daemon that is
    ///      `proc_pidpath` succeeding, which also answers "does this process
    ///      still exist" without a second syscall;
    ///   2. that path names a file whose LAST COMPONENT is exactly
    ///      `openconnect`;
    ///   3. the argv carries BOTH of this app's markers: `--cookie-on-stdin`
    ///      and `--script=<the installed route-wrapper.sh absolute path>`.
    ///
    /// (2) is a basename check and deliberately NOT an equality against
    /// `findOpenconnect()`'s answer. Measured read-only on this machine: the
    /// kernel records `/opt/homebrew/Cellar/openconnect/9.21/bin/openconnect`
    /// while the candidate list returns the `/opt/homebrew/bin` symlink, and the
    /// Cellar component carries a version that changes under `brew upgrade`. An
    /// equality check would REFUSE TO STOP THE REAL TUNNEL; resolving both sides
    /// through `realpath` would refuse a tunnel that was running when the binary
    /// was upgraded. A regex match on a command line is detection, not
    /// verification — the property required is "establish that it is genuinely
    /// our tunnel", and (3) is what establishes it.
    ///
    /// A path separator is required, so argv[0] has to be the absolute path it
    /// is on every transport here (the daemon and the sudo helper both exec
    /// openconnect by absolute path). That is also exact parity with the
    /// helper's `cmd_is_our_openconnect`, whose `*/openconnect` pattern cannot
    /// match a bare name; one predicate across three signalling paths is worth
    /// more than accepting a form this project never produces.
    ///
    /// (3) is the load-bearing conjunct and is STRICTER than the `pgrep`
    /// pattern, which accepts EITHER marker. The script path is a root-owned
    /// file in a root-owned directory that only this app's installer writes,
    /// asserted root-owned before every connect.
    ///
    /// What this does NOT claim: that the binary is trustworthy. It is a
    /// user-writable Homebrew install which the daemon ALREADY execs as root.
    /// This check is not trying to be stronger than that existing trust — it
    /// stops a root SIGINT aimed at an unrelated process: a recycled pid from a
    /// stale file, or a local process that merely matched the argv regex. A
    /// local user can forge argv and a basename, and the consequence is that
    /// their own process receives signals they could already send it. The
    /// security boundary is the listener's per-connection code-signing
    /// requirement, which is not weakened by anything here.
    public static func isOurOpenconnect(execPath: String, command: String,
                                        scriptPath: String) -> Bool {
        guard !execPath.isEmpty, !command.isEmpty, !scriptPath.isEmpty else { return false }
        guard execPath.contains("/"),
              execPath.split(separator: "/").last.map(String.init) == "openconnect"
        else { return false }
        guard command.contains("--cookie-on-stdin") else { return false }
        return command.contains("--script=" + scriptPath)
    }

    /// Classify every candidate by its STATE and by the SOURCE it came from —
    /// the same pid state means different things depending on where the number
    /// was read, and collapsing the two is what made an earlier revision of this
    /// fix unable to clear the very pid file whose staleness caused the incident.
    ///
    /// The source-keyed rules:
    ///
    ///   * `<= 1` from any source is dropped. `kill(0, SIGINT)` signals the
    ///     daemon's own PROCESS GROUP, and `pid_t("0")` parses, so this is a real
    ///     hole rather than a hypothetical one.
    ///   * a PID-FILE entry that is not alive is `stalePIDFile`: the file names a
    ///     dead process, so it IS stale. This is the observed input.
    ///   * a PGREP entry that is not alive is dropped. That output is a snapshot,
    ///     and a pid that exited in between is evidence of nothing.
    ///   * an alive pid equal to the in-memory handle is `signal` with NO
    ///     `identify` call: the daemon spawned it and holds the `Process`.
    ///   * otherwise `identify` decides, and a `.notOurs` or `.unknown` pid that
    ///     is still alive is never signalled and never counted as absence.
    ///
    /// A dead in-memory handle does not claim the pid, so the pid file can still
    /// report it as stale.
    public static func targets(inMemory: Int32?, pidFile: [Int32], pgrep: [Int32],
                               isAlive: (Int32) -> Bool,
                               identify: (Int32) -> Identity) -> Targets {
        enum Source { case inMemory, file, scan }
        var candidates: [(pid: Int32, source: Source)] = []
        if let inMemory { candidates.append((inMemory, .inMemory)) }
        candidates += pidFile.map { ($0, .file) }
        candidates += pgrep.map { ($0, .scan) }

        var t = Targets()
        var claimed = Set<Int32>()
        for (pid, source) in candidates {
            guard pid > 1, !claimed.contains(pid) else { continue }
            let alive = isAlive(pid)

            if source == .inMemory {
                guard alive else { continue }
                claimed.insert(pid)
                t.signal.append(pid)
                continue
            }
            claimed.insert(pid)
            guard alive else {
                if source == .file { t.stalePIDFile.append(pid) }
                continue
            }
            switch identify(pid) {
            case .ourOpenconnect:
                t.signal.append(pid)
            case .gone:
                if source == .file { t.stalePIDFile.append(pid) }
            case .notOurs:
                t.notOursLive.append(pid)
            case .unknown:
                // The argv probe timing out says nothing about liveness, so ask
                // again rather than reporting a pessimistic verdict about a
                // process that has since exited.
                if isAlive(pid) {
                    t.unidentified.append(pid)
                } else if source == .file {
                    t.stalePIDFile.append(pid)
                }
            }
        }
        t.signal.sort(); t.notOursLive.sort()
        t.unidentified.sort(); t.stalePIDFile.sort()
        return t
    }

    /// `found` — the signalled set; `escalated` — still alive after the SIGINT
    /// wait; `survivors` — still alive after the SIGTERM wait.
    ///
    /// Precedence, because the inputs are three observations of a racing system:
    /// nothing signalled but something unidentified is `.unidentified`; a
    /// survivor is `.stuck`.
    public static func verdict(found: [Int32], escalated: [Int32], survivors: [Int32],
                               unidentified: [Int32], notOursLive: [Int32],
                               clearedStalePIDFile: Bool) -> Verdict {
        // survivors ⊆ escalated ⊆ found, enforced by CLAMPING in that order and
        // NOT by trapping: this runs in a root daemon on a teardown path, where a
        // precondition failure would abort the teardown. Everything is sorted
        // before it can reach a message, so the strings are stable.
        let f = found.sorted()
        let e = escalated.filter(f.contains).sorted()
        let s = survivors.filter(e.contains).sorted()
        let u = unidentified.sorted()
        let n = notOursLive.sorted()

        guard !f.isEmpty else {
            if !u.isEmpty { return .unidentified(pids: u) }
            return .nothingToStop(clearedStalePIDFile: clearedStalePIDFile, notOursLive: n)
        }
        if !s.isEmpty { return .stuck(pids: f, survivors: s) }
        return .stopped(pids: f, escalated: !e.isEmpty, unidentified: u)
    }

    /// ONE function for the daemon's log line and for the XPC reply, so the two
    /// cannot drift. The baseline string is "no tunnel of ours running" in every
    /// arm: the old `no tunnel running` asserted something about the whole
    /// machine that this code is in no position to claim.
    public static func message(_ verdict: Verdict) -> String {
        switch verdict {
        case .nothingToStop(let cleared, let notOursLive):
            var m = "no tunnel of ours running"
            if cleared { m += " (cleared a stale pid file)" }
            if !notOursLive.isEmpty {
                m += " (left \(list(notOursLive)) alone: "
                   + "a live openconnect that is not ours)"
            }
            return m
        case .stopped(let pids, let escalated, let unidentified):
            var m = "stopped \(list(pids))"
            if escalated { m += " (escalated to SIGTERM)" }
            if !unidentified.isEmpty {
                m += " (left \(list(unidentified)) unidentified — "
                   + "NOT established as absent)"
            }
            return m
        case .stuck(_, let survivors):
            // The SURVIVORS, not the whole signalled set: naming a pid that did
            // exit alongside one that did not is how a reader ends up chasing
            // the wrong process.
            let one = survivors.count == 1
            return "found \(list(survivors)) and signalled \(one ? "it" : "them"), but "
                 + "\(one ? "it is" : "they are") still running — NOT stopped"
        case .unidentified(let pids):
            return "live \(list(pids)) could not be identified as our openconnect — "
                 + "NOT signalled and NOT stopped"
        }
    }

    /// `.nothingToStop` stays a SUCCESS even with `notOursLive` non-empty:
    /// nothing OF OURS is running, so the app's endpoint record names nothing and
    /// clearing it is right. What changed is that the message no longer asserts
    /// "no tunnel running" about a machine with a live openconnect-shaped process
    /// on it.
    ///
    /// `.stopped` with a non-empty `unidentified` is NOT a success, and that
    /// distinction is load-bearing: found `[42]` with unidentified `[99]` would
    /// otherwise fall through as success, the app would clear its endpoint
    /// record, `isRunning()`'s broad `pgrep` would match 99, and the menu would
    /// read "Connected: ?" again.
    public static func isSuccess(_ verdict: Verdict) -> Bool {
        switch verdict {
        case .nothingToStop: return true
        case .stopped(_, _, let unidentified): return unidentified.isEmpty
        case .stuck, .unidentified: return false
        }
    }

    private static func list(_ pids: [Int32]) -> String {
        pids.count == 1
            ? "pid \(pids[0])"
            : "pids \(pids.map(String.init).joined(separator: ", "))"
    }
}

extension NetReconcile {

    /// The scope decision of `TunnelScope`, as one pure function over injected
    /// snapshots — so every arm of it is assertable from literals, with no live
    /// tunnel, no installed daemon and no file under /var/run.
    ///
    /// `liveTunnels` is the subset of the tunnels the planner has seen that the
    /// interface snapshot still has; `liveAddress` answers "what IPv4 does that
    /// name carry NOW". Both come from the snapshot `plan` already holds.
    ///
    /// Four refusals, in order, each of which narrows and none of which widens:
    ///
    ///   1. an unusable snapshot proves nothing, either way;
    ///   2. no record, or a record that never resolved a name, is no identity
    ///      claim at all;
    ///   3. a named tunnel the snapshot no longer has is already covered by
    ///      `dead`, so the claim adds nothing;
    ///   4. a LIVE name is not enough. The gate has already proved no
    ///      openconnect OF OURS is running, so the reachable reading of "our
    ///      utun7 is live while our openconnect is not" is at least as likely to
    ///      be a recycled utun index as our own lingering interface — on a
    ///      machine that churns ten POINTOPOINT links with no third-party VPN
    ///      installed, that is not exotic. Only the address we recorded while
    ///      the interface was ours distinguishes the two.
    public static func tunnelScope(_ attribution: TunnelAttribution?,
                                   liveTunnels: Set<String>,
                                   liveAddress: (String) -> String?,
                                   snapshotUsable: Bool) -> TunnelScope {
        guard snapshotUsable else { return .none }
        guard let attribution, let ours = attribution.ourTunnel else {
            return .deadOnly(identityUnproven: nil)
        }
        guard liveTunnels.contains(ours) else { return .deadOnly(identityUnproven: nil) }
        let now = liveAddress(ours)
        guard let witness = attribution.ourTunnelIPv4, let now, now == witness else {
            return .deadOnly(identityUnproven:
                IdentityUnproven(netif: ours,
                                 recordedAddress: attribution.ourTunnelIPv4,
                                 liveAddress: now))
        }
        return .deadPlus(ours: ours)
    }

    /// PURE. Drops the tunnel actions of `plan` whose `utunN` has REAPPEARED in a
    /// fresher interface snapshot, returning the filtered plan and one line per
    /// drop.
    ///
    /// Why this exists: "absent from a usable snapshot ⇒ provably dead" is an
    /// inference made at PLAN time about a delete executed later, after the
    /// prologue. A third-party client coming up inside that window would have its
    /// `State:/Network/Service/utunN/{IPv4,DNS}` removed and its default route
    /// deleted on the strength of a snapshot that is no longer true. One extra
    /// `getifaddrs` immediately before the apply bounds the window to the
    /// re-probe, and the filter is here rather than in the daemon so it is
    /// assertable from literals.
    ///
    /// Only those two action kinds NAME a tunnel, so only they are matched against
    /// `present`. The sweep is not attribution-scoped at all — its rule is
    /// on-link-ness — so it is never filtered.
    ///
    /// The install is the exception, and it is filtered for a different reason: not
    /// because it names a tunnel, but because dropping an UNSCOPED tunnel default
    /// deletion puts the plan back into exactly the state clause (f) refuses to
    /// install into. (f) emitted the install because that unscoped row was going to
    /// be deleted; once the deletion is dropped the row survives, the kernel's
    /// `default` slot stays occupied, and `route -n add default <gw>` can only
    /// return EEXIST — which the apply issues bare and then reports as an install
    /// regardless. So (f)'s precondition is re-checked here against the post-drop
    /// action list and the withholding is recorded the same way, under the same
    /// `installWithheldForSurvivingDefault`. Without this the composition of the
    /// two filters reintroduces, at apply time, the false "install default …"
    /// transcript line that (f) exists to remove.
    ///
    /// The routing outcome is unchanged either way — the add fails in both — so
    /// this moves a transcript line from a false claim to a true one and nothing
    /// else. In particular it does NOT re-run clause (g): a stale PHYSICAL default
    /// deletion that (g) let stand because an install was emitted still executes
    /// after that install is withheld here, which leaves the stale row deleted with
    /// no replacement installed. That is the behaviour today as well (the install
    /// already failed with EEXIST, silently), so nothing is made worse, but it is a
    /// real gap in the documented "the removal and the install are one operation"
    /// rule and closing it would change which routes a reconcile leaves behind.
    public static func dropRevivedTunnelActions(_ plan: ReconcilePlan,
                                                present: Set<String>)
        -> (plan: ReconcilePlan, dropped: [String]) {
        var kept: [ReconcileAction] = []
        var dropped: [String] = []
        // In action order, so the netif the withholding names is deterministic: a
        // route table can hold more than one unscoped default row (the
        // `unspecified-default` fixture holds three default rows), so "the revived
        // one" has to be a defined choice rather than a set's first element.
        var revivedUnscopedDefaults: [String] = []
        for action in plan.actions {
            switch action {
            case .removeConfigdKey(let key):
                if let m = matchConfigdKey(key), present.contains(m.tunnel) {
                    dropped.append("\(m.tunnel) is live again: removeConfigdKey \(key)")
                    continue
                }
            case .deleteTunnelDefaultRoute(let netif, let ifscoped):
                if present.contains(netif) {
                    dropped.append("\(netif) is live again: deleteTunnelDefaultRoute"
                                 + (ifscoped ? " -ifscope \(netif)" : " (unscoped)"))
                    if !ifscoped { revivedUnscopedDefaults.append(netif) }
                    continue
                }
            case .deleteStalePhysicalDefaultRoute, .deleteRoute, .installDefaultRoute:
                break
            }
            kept.append(action)
        }
        var filtered = plan
        filtered.actions = kept
        // Only an UNSCOPED drop occupies the slot: `route delete default -ifscope`
        // removes that link's scoped row and leaves `default` itself alone, which is
        // the same distinction (f) draws over `deletedUnscopedDefaultNetifs`.
        if let netif = revivedUnscopedDefaults.first,
           filtered.actions.contains(where: { if case .installDefaultRoute = $0 { return true }
                                              else { return false } }) {
            filtered.actions.removeAll { if case .installDefaultRoute = $0 { return true }
                                         else { return false } }
            filtered.kept.append(.installWithheldForSurvivingDefault(netif: netif))
            // Cleared to keep `installCandidateNote`'s stated contract — nil when no
            // install was emitted — so apply cannot log a gateway divergence for an
            // install that is not in the plan any more.
            filtered.installCandidateNote = nil
            dropped.append("\(netif) is live again: installDefaultRoute withheld — "
                         + "its unscoped default survives, so the install could only return EEXIST")
        }
        return (plan: filtered, dropped: dropped)
    }

    /// The non-tunnel IPv4 default route's interface and gateway, preferring the
    /// unscoped row and falling back to a scoped one, with the subnet filled in
    /// from the interface snapshot. `nil` when there is no such default — which is
    /// what makes `startTunnel` skip writing a netstate rather than write a partial
    /// one.
    public static func physicalDefault(routeTable: String, interfaces: [NetInterface])
        -> (interface: String, gateway: String, subnet: String)? {
        let rows = parseRouteTable(routeTable).filter {
            $0.destination == .defaultRoute && $0.gateway != nil
                && !isTunnelLikeName($0.netif, interfaces)
        }
        guard let row = rows.first(where: { !$0.isIfScoped }) ?? rows.first,
              let gateway = row.gateway,
              let subnet = interfaces.first(where: { $0.name == row.netif })?.subnetCIDR
        else { return nil }
        return (interface: row.netif, gateway: gateway.text, subnet: subnet)
    }

    /// `netif` names a tunnel, whether or not the snapshot still has the link.
    ///
    /// Both halves are needed: a row for a utun that has already vanished still
    /// has to be classified as a tunnel default (FR-2.4), and a point-to-point
    /// link with an unexpected name is still a tunnel.
    private static func isTunnelLikeName(_ netif: String,
                                         _ interfaces: [NetInterface]) -> Bool {
        if let iface = interfaces.first(where: { $0.name == netif }) {
            return iface.isTunnelLike
        }
        for p in ["utun", "ppp", "ipsec", "gif", "stf"] where netif.hasPrefix(p) {
            return true
        }
        return false
    }

    /// Canonical text of a destination, for the kept-record diagnostics and for the
    /// deletion argv. Never netstat's abbreviation: `route`'s own parser runs the
    /// pre-slash text through `inet_aton`, which reads `3.7.35` as `3.7.0.35`.
    private static func displayDestination(_ d: RouteEntry.Destination) -> String {
        switch d {
        case .defaultRoute: return "default"
        case .host(let a): return a.text
        case .network(let a, let p): return "\(a.text)/\(p)"
        case .unparsable(let raw): return raw
        }
    }

    /// PURE. No `Process`, no file I/O, no global reads: everything arrives as a
    /// parameter, which is what makes the plan assertable against checked-in
    /// fixtures.
    ///
    /// Clause letters are the design's and are kept for every cross-reference:
    /// (a) configd keys, (d′)/(d″) the two fail-closed aborts, (b) default routes,
    /// (c) the sweep, (d) the cap, (f) the install, (e) the empty-plan complement,
    /// (g) the final withholding pass.
    ///
    /// `attribution` has NO default value, deliberately: every caller must say
    /// whether it has an identity claim to offer, because "I forgot to pass it"
    /// and "there is no record" must not look the same in a privileged delete's
    /// scope decision. Both answers are safe — absence is dead-only — but only
    /// one of them is a decision.
    public static func plan(routeTable: String,
                            interfaces: [NetInterface],
                            configdKeys: [String],
                            netstate: NetState?,
                            attribution: TunnelAttribution?) -> ReconcilePlan {
        var actions: [ReconcileAction] = []
        var kept: [ReconcileKept] = []
        var abort: ReconcileAbort?

        let rows = parseRouteTable(routeTable)

        // ── (a) configd keys (FR-2.5), scoped to the tunnels the scope below
        // admits. Anchored at both ends with the service component constrained to
        // `utun` + digits, so a UUID-named physical service — which on a real
        // machine is the REAL resolver configuration — can never match.
        var keyByTunnel: [String: [String: String]] = [:]   // utun -> ("IPv4"/"DNS") -> key
        for key in configdKeys {
            guard let m = matchConfigdKey(key) else { continue }
            keyByTunnel[m.tunnel, default: [:]][m.kind] = key
        }

        // The tunnel scope, shared by (a) and (b).
        var tunnelNamesSeen = Set(interfaces.filter(\.isTunnelLike).map(\.name))
        for row in rows where row.netif.range(of: "^utun[0-9]{1,3}$",
                                              options: .regularExpression) != nil {
            tunnelNamesSeen.insert(row.netif)
        }
        tunnelNamesSeen.formUnion(keyByTunnel.keys)

        // Which of the tunnels we have seen does the snapshot still have? The two
        // sets partition `tunnelNamesSeen` when the snapshot is usable.
        //
        // `dead` is gated on the snapshot being usable — the same predicate (d″)
        // aborts on below — because "absent from a snapshot we cannot read" is not
        // evidence of anything. That is (d′)/(d″)'s rule applied to a third input:
        // an input we cannot read is a reason NOT to act, never evidence that
        // routes are dead.
        //
        // The netstate is NOT consulted here any more. Its `preexistingTunnels`
        // was a connect-time snapshot of somebody else's tunnels, read on every
        // reconcile and deleted by a clean stop, so after the ordinary disconnect
        // — the one path that reaches a reconcile — the scope fell back to EVERY
        // utun on the machine. That fallback is gone; nothing widens.
        let present = Set(interfaces.map(\.name))
        let snapshotUsable = interfaces.contains(where: isUsablePhysical)
        let liveTunnels = tunnelNamesSeen.intersection(present)
        let dead = snapshotUsable ? tunnelNamesSeen.subtracting(present) : []

        // ONE scope set drives both (a) and (b), as it did before this change.
        let inScope: Set<String>
        switch tunnelScope(attribution, liveTunnels: liveTunnels,
                           liveAddress: { n in interfaces.first { $0.name == n }?.ipv4?.text },
                           snapshotUsable: snapshotUsable) {
        case .none:
            inScope = []
        case .deadOnly(let unproven):
            inScope = dead
            if let unproven { kept.append(.liveTunnelIdentityUnproven(unproven)) }
        case .deadPlus(let ours):
            inScope = dead.union([ours])
        }
        kept += tunnelNamesSeen.subtracting(inScope).sorted().map { .foreignTunnel($0) }

        // Stable order: IPv4 before DNS per utun, ascending by name — the same order
        // the installed vpnc-script uses in its own removal heredoc.
        for tunnel in keyByTunnel.keys.sorted() where inScope.contains(tunnel) {
            for kind in ["IPv4", "DNS"] {
                if let key = keyByTunnel[tunnel]?[kind] {
                    actions.append(.removeConfigdKey(key))
                }
            }
        }

        // ── (d′) an unreadable route table, and (d″) an unusable interface
        // snapshot. Both evaluated BEFORE (b), both suppressing (b), (c) and (f).
        //
        // An input we cannot read is a reason NOT to act, never evidence that
        // routes are dead. Without (d″) the planner reads "the snapshot cannot
        // prove this gateway is on-link" as "this gateway is dead", sweeps the whole
        // table, deletes the physical default, and then refuses to install one for
        // the same reason it deleted — NFR-8 inverted into the failure it forbids.
        //
        // (d′) STILL RETAINS (a): the configd removals derive solely from the
        // scutil key list and need no route table at all, and on a wedged machine
        // clearing the DNS override is the single most valuable thing we can do.
        //
        // (d″) NO LONGER DOES, and that is a deliberate override of the rationale
        // this comment used to carry for both. With an unusable interface snapshot
        // the scope above is `.none`, so `inScope` is empty and the (a) loop emits
        // nothing in fact. The stricter reading is the intended one: a
        // `State:/Network/Service/utunN/{IPv4,DNS}` removal is a privileged delete
        // of another product's resolver configuration, and in this state the thing
        // we cannot read is precisely the interface list, so we cannot see whether
        // a third party is live. "Clear somebody's DNS because we are blind" is the
        // fail-open direction in the arm where fail-closed matters most.
        //
        // What that costs is bounded, and the cases were checked rather than
        // asserted: after a boot there are no `State:` keys to clear (they live in
        // configd's volatile store), a daemon restarted mid-session still has a
        // readable snapshot and so repairs through `dead`, and the remaining case —
        // a wedged machine whose getifaddrs raced — is transient, recorded as
        // `.interfaceSnapshotUnusable` and repaired by the next run.
        if rows.isEmpty {
            abort = .routeTableUnreadable
        } else if !interfaces.contains(where: isUsablePhysical) {
            abort = .interfaceSnapshotUnusable
        }

        guard abort == nil else {
            return ReconcilePlan(actions: actions, kept: kept, abort: abort)
        }

        // ── (b) default routes (FR-2.4, and the stale physical default). Classified
        // per ROW, not per interface: the scoped and unscoped forms are separate
        // rows needing different deletion argv.
        var staleDefaultNetifs: [String] = []
        var keptPhysicalDefaultNetifs: [String] = []
        var hasUsablePhysicalDefault = false

        for row in rows where row.destination == .defaultRoute {
            if isTunnelLikeName(row.netif, interfaces) {
                if inScope.contains(row.netif) {
                    actions.append(.deleteTunnelDefaultRoute(netif: row.netif,
                                                             ifscoped: row.isIfScoped))
                } else {
                    kept.append(.foreignTunnel(row.netif))
                }
                continue
            }
            switch evaluateDefaultGateway(candidate: row.gatewayText,
                                          targetInterface: row.netif,
                                          interfaces: interfaces) {
            case .accept:
                if row.isIfScoped {
                    // Correct for that link, so never deleted — but it does not
                    // serve unbound traffic, so (f) must still install the unscoped
                    // form. This is the live machine's actual shape.
                    kept.append(.physicalDefaultUnusable(netif: row.netif,
                                                         why: "ifscope-only"))
                    keptPhysicalDefaultNetifs.append(row.netif)
                } else {
                    kept.append(.physicalDefaultUsable(netif: row.netif))
                    hasUsablePhysicalDefault = true
                }

            case .reject(let reason):
                switch reason {
                case .targetInterfaceDown:
                    // The link may come back with the same subnet and revalidate the
                    // route; deleting a dormant-but-plausible default buys nothing,
                    // and the install would refuse for the same reason.
                    kept.append(.physicalDefaultUnusable(netif: row.netif,
                                                         why: "link down"))
                    keptPhysicalDefaultNetifs.append(row.netif)

                case .targetInterfaceMissing, .targetInterfaceUnconfigured:
                    // The SAME reason as `targetInterfaceDown`: both verdicts
                    // describe the snapshot, not the next hop. An up-but-un-addressed
                    // link is a link mid-DHCP — the normal state in the window the
                    // path monitor fires in — and a missing link is a failed or raced
                    // getifaddrs. Neither is evidence that the route is dead.
                    kept.append(.physicalDefaultUnusable(netif: row.netif,
                                                         why: "target not addressed"))
                    keptPhysicalDefaultNetifs.append(row.netif)

                case .malformedGateway, .malformedInterfaceName:
                    // An `-interface` default (gateway `link#N`) is legitimate and we
                    // cannot reason about it; keeping is the safe direction.
                    kept.append(.physicalDefaultUnusable(netif: row.netif,
                                                         why: "no IPv4 next hop"))
                    keptPhysicalDefaultNetifs.append(row.netif)

                case .targetInterfaceIsTunnel:
                    // Unreachable: the tunnel branch above ran first. Kept rather
                    // than deleted anyway, because an unreachable branch that
                    // deletes routes is not a branch worth leaving behind.
                    kept.append(.physicalDefaultUnusable(netif: row.netif,
                                                         why: "tunnel target"))

                case .gatewayOffLink, .gatewayIsTunnelAddress, .gatewayIsOwnAddress,
                     .unspecifiedGateway, .gatewayIsNetworkAddress,
                     .gatewayIsBroadcastAddress:
                    // THE CARRIED-HOME BLACKHOLE. Every reason here describes a next
                    // hop that cannot carry traffic ON THAT LINK, so deleting the row
                    // costs nothing that works and is a precondition for installing
                    // one that does.
                    //
                    // It does NOT follow that the link is present, up and addressed —
                    // an earlier version of this comment claimed exactly that and was
                    // wrong. `unspecifiedGateway` is returned at step 3 of
                    // `evaluateDefaultGateway` and `malformedGateway` at step 2, both
                    // BEFORE the interface lookup at NetGuard.swift:276, so a
                    // `default 0.0.0.0 … en9` row still lands here with `en9` absent
                    // or down. That is why the install-target ladder below filters
                    // `staleDefaultNetifs` through `isUsablePhysical` at the point of
                    // use rather than trusting this list to name a usable link.
                    // `evaluateDefaultGateway` also never tests `isLoopback` while
                    // `isUsablePhysical` does, so the same membership filter catches a
                    // `default … lo0` row with no separate rule.
                    actions.append(.deleteStalePhysicalDefaultRoute(
                        netif: row.netif, ifscoped: row.isIfScoped, reason: reason))
                    staleDefaultNetifs.append(row.netif)
                }
            }
        }

        // ── (c) the sweep (FR-2.6, FR-2.7). First match decides.
        var sweptOrder: [RouteDeletion] = []            // the unscoped key, in first-seen order
        var sweptNetifs: [String: [String]] = [:]       // "dst|mask" -> distinct netifs
        func sweepKey(_ d: RouteDeletion) -> String { "\(d.destination)|\(d.netmask ?? "")" }

        for row in rows where row.destination != .defaultRoute {
            let dst = displayDestination(row.destination)

            if case .unparsable = row.destination {
                // A destination we cannot name exactly cannot be named exactly to
                // `route delete` either (§4.2 rule 5).
                kept.append(.unparsable(dst))
                continue
            }
            guard let gw = row.gateway else {
                // link#N, a MAC, an `-interface` route: this IS the LAN on-link
                // route (FR-2.6a). Matched before the destination categories, so on
                // a real table the multicast/link-local rows classify here — which
                // is harmless, since every one of them is kept either way.
                kept.append(.onLinkRoute(dst))
                continue
            }
            if row.netif == "lo0" || destinationAddress(row.destination)?.isLoopback == true {
                kept.append(.loopback(dst))
                continue
            }
            if let addr = destinationAddress(row.destination) {
                // 255.255.255.255 is classified with the multicast group rather than
                // given a category of its own: it is kept, and the tests assert the
                // absence of a deletion.
                if addr.isMulticast || addr.isBroadcastAll {
                    kept.append(.multicast(dst)); continue
                }
                if addr.isLinkLocal { kept.append(.linkLocal(dst)); continue }
            }

            // The on-link question is answered by THE GUARD, classified on its
            // rejection reason — the guard never accepts against a tunnel target, so
            // acceptance alone cannot express the lingering-utun case. Reusing it
            // means the sweep and the restore cannot drift: a gateway the guard would
            // refuse to install is exactly a gateway the sweep considers dead.
            // CLASSIFIED ON A CLOSED LIST OF REASONS, never by exclusion. "Dead by
            // default:" deleted a route whose next hop is INSIDE a live link's
            // subnet — the link's own address (step 9 fires before the on-link test
            // at step 10, so such a route never reaches it), the subnet's network
            // address or its broadcast address — all three of which FR-2.6c forbids
            // deleting, and the first of which survived or not depending on whether
            // some OTHER link happened to share the subnet.
            //
            // WHY THIS IS NOT §4.3(b)'s RULE, and must not be "harmonised" with it:
            // (b) deletes a DEFAULT route for exactly these reasons, and is right to.
            // A default route is the one route whose destination guarantees that
            // keeping a dead one blackholes the whole machine, and (b) never deletes
            // one without installing a replacement in the same operation. The sweep
            // has neither property: it deletes an exception route whose destination
            // is some specific prefix, it installs nothing in its place, and FR-2.6c
            // draws its line at on-link-ness rather than at usability. Same reasons,
            // different rules, both deliberate.
            var verdictKept = false
            for iface in interfaces where isUsablePhysical(iface) {
                switch evaluateDefaultGateway(candidate: gw.text,
                                              targetInterface: iface.name,
                                              interfaces: interfaces) {
                case .accept:
                    kept.append(.gatewayOnLink(dst, via: gw.text))
                    verdictKept = true
                case .reject(.gatewayIsTunnelAddress):
                    // Fires only while a tunnel in the snapshot still HOLDS that
                    // address, so a vanished utun's address falls through to swept —
                    // the intended behaviour and the common case after a dead tunnel.
                    kept.append(.tunnelOnLinkGateway(dst, via: gw.text))
                    verdictKept = true
                // The three in-subnet-but-unusable reasons, spelled out one arm
                // each so the recorded `why` is the guard's own answer rather than
                // a second derivation of it.
                case .reject(.gatewayIsOwnAddress):
                    kept.append(.gatewayInLiveSubnet(
                        dst, via: gw.text,
                        why: GatewayRejection.gatewayIsOwnAddress.rawValue))
                    verdictKept = true
                case .reject(.gatewayIsNetworkAddress):
                    kept.append(.gatewayInLiveSubnet(
                        dst, via: gw.text,
                        why: GatewayRejection.gatewayIsNetworkAddress.rawValue))
                    verdictKept = true
                case .reject(.gatewayIsBroadcastAddress):
                    kept.append(.gatewayInLiveSubnet(
                        dst, via: gw.text,
                        why: GatewayRejection.gatewayIsBroadcastAddress.rawValue))
                    verdictKept = true
                case .reject(.gatewayOffLink), .reject(.malformedGateway),
                     .reject(.unspecifiedGateway), .reject(.malformedInterfaceName),
                     .reject(.targetInterfaceMissing), .reject(.targetInterfaceUnconfigured),
                     .reject(.targetInterfaceIsTunnel), .reject(.targetInterfaceDown):
                    // Off-link for this link, or a verdict about the LINK rather
                    // than the next hop (unreachable here: `isUsablePhysical` has
                    // already excluded every one of those, and the name was taken
                    // from the snapshot). Try the next link; a route nothing can
                    // reach falls through to swept.
                    continue
                }
                break
            }
            if verdictKept { continue }

            // Swept. Reduced to DISTINCT (destination, netmask) pairs before any
            // action is created: emitting per row would produce two byte-identical
            // deletions for every destination that appears in both scoped and
            // unscoped form.
            let deletion = RouteDeletion(destination: destinationAddress(row.destination)?.text
                                                      ?? dst,
                                         netmask: destinationNetmask(row.destination),
                                         ifscope: nil)
            let key = sweepKey(deletion)
            if sweptNetifs[key] == nil {
                sweptNetifs[key] = []
                sweptOrder.append(deletion)
            }
            if !(sweptNetifs[key] ?? []).contains(row.netif) {
                sweptNetifs[key]?.append(row.netif)
            }
        }

        // ── (d) the cap (FR-2.7). Aborting the SWEEP rather than the whole
        // reconcile is deliberate: clearing the DNS hijack, removing a dead default
        // and installing a working one are the bounded actions that turn "no
        // internet" into "internet", and refusing them because the route table is
        // pathological would be the wrong failure.
        if sweptOrder.count > sweepCap {
            abort = .sweepCapExceeded(found: sweptOrder.count, cap: sweepCap)
        } else {
            for deletion in sweptOrder {
                actions.append(.deleteRoute(deletion))
                for netif in sweptNetifs[sweepKey(deletion)] ?? [] {
                    // `route delete -net X` removes only the unscoped entry; the
                    // interface-scoped duplicate survives it and still wins.
                    actions.append(.deleteRoute(RouteDeletion(destination: deletion.destination,
                                                             netmask: deletion.netmask,
                                                             ifscope: netif)))
                }
            }
        }

        // ── (f) install a usable physical default (FR-2.8). Emitted whenever no
        // unscoped, guard-accepted physical default is left once (b) has had its
        // say. The gate depends on NOTHING ELSE — not on whether (a), (b) or (c)
        // emitted anything, and not on what the sweep found.
        //
        // There is deliberately no "the plan is otherwise non-empty" conjunct: with
        // one, a machine whose only fault is a MISSING default route produced an
        // empty plan and no install — exactly the state the vendored script's own
        // teardown leaves behind.
        //
        // (f) PRECONDITION, and it is about an action's POSTCONDITION rather than
        // about which link to choose: an unscoped default this plan is not
        // deleting is still the kernel's answer for `default`, so
        // `route -n add default <gw>` can only return EEXIST. The apply issues
        // that add bare and appends `install default …` to the transcript
        // unconditionally, so the install would be reported as done when it was
        // refused by the kernel. Withhold it, and SAY it was withheld.
        //
        // The predicate is over every unscoped default ROW, whatever kind of link
        // it is on, not only over tunnels: a kept physical default (a down link,
        // an `-interface` row with no IPv4 next hop) occupies the slot exactly as
        // a protected tunnel's does. The common reason to be here is the new one —
        // a live tunnel we cannot witness keeps its unscoped default — but the
        // reason does not change the arithmetic.
        //
        // Scoped deletions do not count: `route delete default -ifscope <n>`
        // removes that link's scoped row and leaves the unscoped slot occupied.
        let deletedUnscopedDefaultNetifs: Set<String> = Set(actions.compactMap {
            switch $0 {
            case .deleteTunnelDefaultRoute(let netif, let ifscoped),
                 .deleteStalePhysicalDefaultRoute(let netif, let ifscoped, _):
                return ifscoped ? nil : netif
            default:
                return nil
            }
        })
        let survivingUnscopedDefault = rows.first {
            $0.destination == .defaultRoute && !$0.isIfScoped
                && !deletedUnscopedDefaultNetifs.contains($0.netif)
        }

        var installCandidateNote: String?
        if !hasUsablePhysicalDefault {
            if let row = survivingUnscopedDefault {
                kept.append(.installWithheldForSurvivingDefault(netif: row.netif))
            } else {
                let candidates = interfaces.filter(isUsablePhysical).map(\.name)
                var target: String?
                if let ns = netstate, candidates.contains(ns.physicalInterface) {
                    target = ns.physicalInterface
                } else if let netif = preferredInstallTarget(offered: staleDefaultNetifs,
                                                             interfaces: interfaces) {
                    // The link whose default we just removed is the obvious
                    // replacement — but only if it is a link at all. Both this rung
                    // and the next are fed by lists clause (b) built, and clause (b)
                    // records links it has itself judged unusable, so each offer is
                    // filtered at the point of USE. Not at the point of record:
                    // clause (g) below needs `staleDefaultNetifs` unfiltered, because
                    // a stale default on an absent link is still a deletion whose
                    // withholding has to be recorded.
                    target = netif
                } else if let netif = preferredInstallTarget(offered: keptPhysicalDefaultNetifs,
                                                             interfaces: interfaces) {
                    target = netif
                } else if candidates.count == 1 {
                    target = candidates[0]
                } else if candidates.count > 1 {
                    kept.append(.ambiguousInstallTarget(candidates.sorted()))
                }
                if let target {
                    actions.append(.installDefaultRoute(interface: target))
                    installCandidateNote = self.installCandidateNote(interface: target,
                                                                     rows: rows,
                                                                     interfaces: interfaces,
                                                                     netstate: netstate)
                }
            }
        }

        // ── (g) the asymmetry, and it is load-bearing: never delete a default that
        // could carry traffic without installing one. (e) and (f) partition the
        // state space on "a usable physical default exists", but (f)'s target
        // selection can still fail after (b) has decided to delete something.
        //
        // Only the PHYSICAL deletion is withheld. FR-2.4 is unconditional and the
        // gate has already proved no tunnel of ours is alive, so a default via that
        // utun provably cannot carry traffic: withholding it would leave THAT route
        // as the machine's default — guaranteed no internet, and not repairable
        // until the next reconcile. Deleting it leaves no default, which is
        // recoverable.
        if actions.contains(where: { if case .deleteStalePhysicalDefaultRoute = $0 { return true }
                                     else { return false } }),
           !actions.contains(where: { if case .installDefaultRoute = $0 { return true }
                                      else { return false } }),
           !hasUsablePhysicalDefault {
            actions.removeAll { if case .deleteStalePhysicalDefaultRoute = $0 { return true }
                                else { return false } }
            kept.append(.defaultDeletionsWithheld(netifs: staleDefaultNetifs))
        }

        return ReconcilePlan(actions: actions, kept: kept, abort: abort,
                             installCandidateNote: installCandidateNote)
    }

    /// A link the guard could plausibly accept a next hop for: up, not a tunnel,
    /// IPv4-addressed — and not the loopback.
    ///
    /// Loopback is excluded although §4.3's predicate does not name it, because
    /// `lo0` is always present, up and addressed: counting it would make (d″)
    /// unreachable on every real machine and would put `lo0` in every
    /// `ambiguousInstallTarget` list.
    private static func isUsablePhysical(_ iface: NetInterface) -> Bool {
        iface.isUp && !iface.isTunnelLike && !iface.isLoopback && iface.ipv4 != nil
    }

    /// Among `offered`, the first entry that is also a usable physical link — in
    /// INTERFACE SNAPSHOT order, never route-table order.
    ///
    /// The snapshot's order is part of its contract: `NetProbe.interfaces()` builds
    /// an explicit `order` array (NetGuard.swift:568) and returns `order.map { … }`
    /// (:600-608) precisely so `getifaddrs(3)` order survives. Route-table order, by
    /// contrast, is a statement about a text format rather than about the links: the
    /// old `.first` on clause (b)'s lists resolved a dual-homed tie by whichever
    /// physical default configd happened to print first, which nothing could assert.
    /// Being wrong here is bounded — the gateway is re-derived and re-guarded at
    /// apply time, no physical default is deleted on this path, and both links keep
    /// their `-ifscope` rows.
    ///
    /// Internal rather than private so the harness can drive it from literals;
    /// `plan`'s clause (f) is the only production caller.
    static func preferredInstallTarget(offered: [String],
                                       interfaces: [NetInterface]) -> String? {
        let offeredSet = Set(offered)
        return interfaces.lazy
            .filter(isUsablePhysical)
            .map(\.name)
            .first { offeredSet.contains($0) }
    }

    private static func matchConfigdKey(_ key: String) -> (tunnel: String, kind: String)? {
        let pattern = "^State:/Network/Service/(utun[0-9]{1,3})/(IPv4|DNS)$"
        guard let r = try? NSRegularExpression(pattern: pattern),
              let m = r.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)),
              let tunnel = Range(m.range(at: 1), in: key),
              let kind = Range(m.range(at: 2), in: key)
        else { return nil }
        return (String(key[tunnel]), String(key[kind]))
    }

    private static func destinationAddress(_ d: RouteEntry.Destination) -> IPv4? {
        switch d {
        case .host(let a): return a
        case .network(let a, _): return a
        case .defaultRoute, .unparsable: return nil
        }
    }

    private static func destinationNetmask(_ d: RouteEntry.Destination) -> String? {
        switch d {
        case .network(_, let p): return IPv4.maskText(bits: p)
        case .host, .defaultRoute, .unparsable: return nil
        }
    }

    /// Exactly `"routeTable <gw|none>; netstateAdvisory <gw|none|subnet-mismatch>"`.
    ///
    /// Candidate 1 of the derivation ladder (the DHCP router) is deliberately
    /// absent: `plan` takes no `dhcpRouter`, because that candidate is apply-time
    /// only — the daemon re-probes it immediately before installing, which is the
    /// whole point of FR-1.6.
    private static func installCandidateNote(interface: String,
                                             rows: [RouteEntry],
                                             interfaces: [NetInterface],
                                             netstate: NetState?) -> String {
        let tableGateway = rows.first {
            $0.destination == .defaultRoute && $0.netif == interface && $0.gateway != nil
        }?.gateway?.text ?? "none"

        var advisory = "none"
        if let ns = netstate, ns.physicalInterface == interface {
            let live = interfaces.first(where: { $0.name == interface })?.subnetCIDR
            advisory = (live != nil && live == ns.physicalSubnet)
                ? ns.physicalGatewayAdvisory : "subnet-mismatch"
        }
        return "routeTable \(tableGateway); netstateAdvisory \(advisory)"
    }

    /// Formatting the argv is a DECISION, not plumbing — §4.2's `inet_aton`
    /// reasoning lives entirely in the argument shape — so it goes in the pure
    /// layer and only execution stays in the daemon. That is also what makes
    /// "apply is a switch with no branch of its own" literally true.
    public static func commands(for plan: ReconcilePlan) -> ReconcileCommands {
        var prologue: [ReconcileCommand] = []
        var sweep: [ReconcileCommand] = []
        var install: [ReconcileCommand] = []

        // configd first so DNS comes back, then the default-route deletions so traffic
        // stops entering a dead next hop. The partition is what the phases execute, and
        // they run prologue -> install -> sweep (see ReconcileCommands.all): the install
        // precedes the sweep so the machine is never without a default for the whole
        // sweep window.
        let keys: [String] = plan.actions.compactMap {
            if case .removeConfigdKey(let k) = $0 { return k } else { return nil }
        }
        if !keys.isEmpty {
            let stdin = "open\n" + keys.map { "remove \($0)\n" }.joined() + "close\n"
            prologue.append(.scutil(stdin: stdin, keys: keys))
        }

        for action in plan.actions {
            switch action {
            case .removeConfigdKey:
                continue                                   // already emitted, as one call

            case .deleteTunnelDefaultRoute(let netif, let ifscoped),
                 .deleteStalePhysicalDefaultRoute(let netif, let ifscoped, _):
                // Split by scoping. `route -n delete default` names no interface: it
                // deletes whatever the kernel currently answers for the unscoped
                // default, so a blind delete aimed at a SCOPED row could remove the
                // wrong one. A -ifscope'd row is deleted by name, which is
                // unambiguous; an unscoped row is deleted only while the current
                // default still IS that interface.
                if ifscoped {
                    prologue.append(.route(argv: ["-n", "delete", "default",
                                                  "-ifscope", netif]))
                } else {
                    prologue.append(.deleteUnscopedDefaultWhileInterface(netif: netif,
                                                                         maxIterations: 8))
                }

            case .deleteRoute(let d):
                // EXPLICIT netmask, never netstat's shorthand: `route`'s parser runs
                // the pre-slash text through inet_aton, so `3.7.35` would mean
                // `3.7.0.35` — a route that was never in the table, leaving the real
                // one in place.
                var argv = ["-n", "delete"]
                if let netmask = d.netmask {
                    argv += ["-net", d.destination, "-netmask", netmask]
                } else {
                    argv += ["-host", d.destination]
                }
                if let ifscope = d.ifscope { argv += ["-ifscope", ifscope] }
                sweep.append(.route(argv: argv))

            case .installDefaultRoute(let interface):
                install.append(.deriveAndInstallDefault(interface: interface))
            }
        }
        return ReconcileCommands(prologue: prologue, sweep: sweep, install: install)
    }
}

// MARK: - The persisted netstate

/// What the daemon knew about the physical network at the moment this session's
/// openconnect was spawned.
///
/// Fixed path, not pid-keyed. Written by the daemon at `startTunnel`, read by
/// `deriveDefaultGateway` (candidate 3) and by the reconcile planner's
/// install-target hint — and NOT, any more, by its tunnel scope, which is
/// `TunnelAttribution`'s business and liveness's. `stopTunnel` is the only
/// remover — `reconcile` deliberately leaves it in place, because every later
/// reconcile in the same boot can still use its install hint, and a stale
/// advisory is already fenced by FR-1.7's same-interface AND same-subnet
/// precondition and then by the guard.
///
/// What it deliberately does NOT contain: no cookie, no gateway host name or
/// address from the authenticated node, no `--resolve` value, no log path, no
/// user name. The LAN gateway, the subnet and the list of `utun` interfaces are
/// facts `netstat -rn` and `ifconfig` already expose to every local process, so
/// the file widens nothing.
public struct NetState: Codable, Equatable {
    public static let path = "/var/run/anyway-connect.netstate.json"

    /// Named `currentSchema`, not `schema`: a static and an instance member of
    /// the same name is a compile risk not worth taking next to `Codable`
    /// synthesis.
    public static let currentSchema = 1

    /// Size cap, in the pure half so it is testable.
    public static let maxBytes = 64 * 1024

    public var schema: Int
    public var writtenAt: Date
    public var physicalInterface: String
    public var physicalSubnet: String
    /// DIAGNOSTIC, plus FR-1.7's third-choice fallback. Never installed without
    /// passing the guard against the link's CURRENT subnet.
    public var physicalGatewayAdvisory: String
    /// CIDRs this session ASKED FOR, already validated. FR-2.9 wants the
    /// session's routes captured; this records the request, which is a knowing
    /// approximation of "installed" — openconnect and the vendored script decide
    /// what actually lands. It is diagnostic only and deliberately NOT an input
    /// to the plan (the sweep classifies routes by on-link-ness, not by
    /// provenance), so nothing reads it and no post-connect capture hook is
    /// missing.
    public var exceptionRoutes: [String]
    public var tunnelPID: Int
    /// Tunnel-like interfaces that ALREADY EXISTED when this session's
    /// openconnect was spawned — i.e. somebody else's.
    ///
    /// WRITE-ONLY. **The planner no longer reads this field at all**, and an
    /// earlier version of this comment — "the planner subtracts these, so a
    /// reconcile cannot dismantle a third-party VPN's default route or resolver
    /// configuration" — described a protection that is not implemented here any
    /// more. It never held in the case that mattered: the list is deleted with
    /// the netstate by a clean stop, which is the ordinary way to reach a
    /// reconcile at all, and a tunnel brought up AFTER this file was written was
    /// never in it. The complement is derived from LIVENESS on every reconcile
    /// instead (see `TunnelScope`), so it cannot go stale and cannot be deleted.
    ///
    /// Retained, and still written, for schema stability alone: removing it
    /// would force a `NetState` schema bump and break the sudo helper's own
    /// parser for no gain, and its write cost is one `getifaddrs` the daemon
    /// already does.
    public var preexistingTunnels: [String]

    public init(schema: Int = NetState.currentSchema,
                writtenAt: Date,
                physicalInterface: String,
                physicalSubnet: String,
                physicalGatewayAdvisory: String,
                exceptionRoutes: [String],
                tunnelPID: Int,
                preexistingTunnels: [String]) {
        self.schema = schema
        self.writtenAt = writtenAt
        self.physicalInterface = physicalInterface
        self.physicalSubnet = physicalSubnet
        self.physicalGatewayAdvisory = physicalGatewayAdvisory
        self.exceptionRoutes = exceptionRoutes
        self.tunnelPID = tunnelPID
        self.preexistingTunnels = preexistingTunnels
    }

    /// The fixed encoder both sides use. Stated once so a writer and a reader
    /// cannot disagree about the date format.
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    /// PURE: schema check, size cap and field re-validation, with NO file I/O —
    /// so every rejection path is assertable from literal `Data`.
    public static func decode(_ data: Data) -> NetState? {
        guard data.count <= maxBytes else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard var state = try? d.decode(NetState.self, from: data) else { return nil }

        // A future schema 2 is IGNORED by an older daemon rather than mis-read.
        guard state.schema == currentSchema else { return nil }

        // The file is root-owned, so this is defence in depth — but it costs four
        // lines and means a corrupted write can never reach `route`.
        guard PrivilegedValidation.isRestoreTargetInterface(state.physicalInterface) else {
            return nil
        }
        // `IPv4(_:) != nil`, NOT `PrivilegedValidation.isValidIPv4`: the latter
        // accepts `010.0.1.1` and `+1.2.3.4`, which the guard would later reject
        // as malformed — so accepting them here would store a value that can only
        // ever produce a refusal, and hide the reason one layer away from it.
        guard IPv4(state.physicalGatewayAdvisory) != nil else { return nil }

        // Invalid entries are DROPPED rather than fatal: a bad name in this list
        // can only NARROW what reconcile touches, so dropping it is the
        // conservative direction, and rejecting the file outright would discard an
        // otherwise usable record.
        state.preexistingTunnels = state.preexistingTunnels.filter {
            PrivilegedValidation.isValidInterface($0) && $0.utf8.count <= 15
        }

        // `physicalSubnet` is deliberately not validated here: it is only ever
        // compared for equality against a canonically computed `subnetCIDR`, so a
        // malformed value can only fail to match, which is the safe direction.
        return state
    }

    /// Impure wrapper: descriptor hardening, then `decode`. `nil` for absent,
    /// unreadable, wrong-owner, oversized, truncated, non-JSON or
    /// schema-mismatched. Never throws out of a caller — `reconcile` and
    /// `deriveDefaultGateway` must work without it, which includes every run after
    /// a reboot, since `/var/run` is pruned at boot.
    ///
    /// `/var/run` is `drwxrwxr-x root:daemon`, so the checks are made through the
    /// DESCRIPTOR and never by looking the path up a second time.
    public static func load(path: String = NetState.path) -> NetState? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              st.st_uid == 0,                       // written by root, or not trusted
              (st.st_mode & 0o022) == 0,            // not group- or world-writable
              st.st_size <= off_t(maxBytes)
        else { return nil }

        // Read through the SAME descriptor that was just verified. Re-opening the
        // path here — even via FileHandle — would look it up a second time and
        // hand back exactly the race the `fstat` was for.
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count <= maxBytes {
            let n = read(fd, &buf, buf.count)
            if n < 0 { return nil }
            if n == 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        return decode(data)
    }
}

// MARK: - The persisted tunnel attribution

/// One observation tick's answer to "which interface is ours, and what address
/// is it carrying". Pure data: `observeOurTunnel` computes it, the daemon's
/// writer applies it, and the harness asserts it from literals.
public enum AttributionOutcome: Equatable {
    /// Nothing decided YET — keep polling. Not terminal, and deliberately the
    /// answer to "two or more new tunnel-like names": macOS creates and
    /// destroys `utun`s for its own services, so churn inside our window is at
    /// least as likely as a third party.
    case pending
    case resolved(String)
    case ambiguous([String])
    case processExited
    case timedOut
}

/// An `AttributionOutcome` plus the two things the record needs written beside
/// it. Declared as one type because the name and the address resolve on
/// DIFFERENT ticks — a `utun` appears before `vpnc-script` assigns its address —
/// so an outcome alone cannot carry the witness, which is the whole point of
/// recording it.
///
/// `attributionNote` rides here rather than being re-derived by the writer
/// because only this decision knows whether the deadline has passed: a resolved
/// name with no address yet is `"pending"` mid-window and `"addressPending"` at
/// the deadline, and those are different facts about the same outcome.
public struct AttributionTick: Equatable {
    public let outcome: AttributionOutcome
    public let ourTunnelIPv4: String?
    public let attributionNote: String?

    public init(outcome: AttributionOutcome, ourTunnelIPv4: String?,
                attributionNote: String?) {
        self.outcome = outcome
        self.ourTunnelIPv4 = ourTunnelIPv4
        self.attributionNote = attributionNote
    }
}

/// WHO OUR TUNNEL IS — its interface name and the IPv4 address it carried while
/// it was ours.
///
/// Separate from `NetState`, in its own file with its own lifetime, because the
/// two answer different questions over different spans. `NetState` says "our
/// tunnel may have left residue, and here is the physical network it displaced",
/// and is correctly deleted by a clean stop. This says "utun7 was ours and it
/// carried 192.168.204.16", which must OUTLIVE the stop or a lingering
/// interface of ours can never be attributed. One file holding both is the
/// defect: the stop deleted the record, and with it the scope.
///
/// There is no "which tunnels are not ours" field, deliberately: that is derived
/// from liveness on every reconcile, so it cannot go stale.
///
/// Lifetime, in full: `startTunnel` unlinks it and writes a fresh record with a
/// fresh `sessionToken`; the observer rewrites it on the ticks that resolve the
/// name and then the address; the stop path never touches it; `/var/run` is
/// pruned at boot. Absence means "no identity claim", which is dead-only — and
/// absence is therefore also the failure path of its own write.
public struct TunnelAttribution: Codable, Equatable {
    public static let path = "/var/run/anyway-connect.tunnels.json"

    /// Named `currentSchema`, not `schema`, for the same reason `NetState` does.
    public static let currentSchema = 1
    public static let maxBytes = 64 * 1024

    /// `attributionNote` is capped rather than rejected, so the limit lives here
    /// beside the one that rejects.
    public static let maxNoteBytes = 64
    /// A `UUID().uuidString` is 36 bytes; 64 leaves room without leaving room
    /// for a log-injection payload.
    public static let maxTokenBytes = 64

    public var schema: Int
    /// DIAGNOSTIC ONLY, and this is load-bearing. It is NOT the session key: the
    /// pinned encoder emits `.iso8601`, i.e. whole seconds, so a `Date()` with
    /// sub-second precision never survives the round trip and an observer
    /// guarding on `cur.startedAt == startedAt` would drop every tick it ever
    /// made — leaving `ourTunnel` nil forever and pinning the scope at
    /// dead-only, which is exactly the mechanism the witness exists to avoid.
    public var startedAt: Date
    /// THE SESSION KEY. `UUID().uuidString`, written once by `startTunnel` and
    /// compared as a string, so the comparison cannot be lost to a date format.
    /// The app auto-reconnects on an 8 s poll and the listener builds a fresh
    /// service per connection, so without this a session-A observer could write
    /// `timedOut` over session B's record forty seconds later.
    public var sessionToken: String
    /// openconnect's pid for THIS session, checked beside the token.
    public var tunnelPID: Int
    /// OUR tunnel's interface name, observed after openconnect created it.
    /// `nil` ⇒ not yet observed, or unresolvable ⇒ dead-only.
    public var ourTunnel: String?
    /// The primary IPv4 `ourTunnel` carried when we observed it. THE WITNESS
    /// that distinguishes our own lingering interface from a recycled `utun`
    /// index: a live interface with this name but a different address is not
    /// ours. `nil` ⇒ the name resolved but no address was ever seen on it, which
    /// narrows to dead-only.
    public var ourTunnelIPv4: String?
    public var ourTunnelObservedAt: Date?
    /// Why `ourTunnel`/`ourTunnelIPv4` is nil, when it is: "pending",
    /// "addressPending", "processExited", "ambiguous", "timedOut", "invalid".
    /// Diagnostic only; nothing reads it for a decision.
    public var attributionNote: String?

    public init(schema: Int = TunnelAttribution.currentSchema,
                startedAt: Date,
                sessionToken: String,
                tunnelPID: Int,
                ourTunnel: String? = nil,
                ourTunnelIPv4: String? = nil,
                ourTunnelObservedAt: Date? = nil,
                attributionNote: String? = nil) {
        self.schema = schema
        self.startedAt = startedAt
        self.sessionToken = sessionToken
        self.tunnelPID = tunnelPID
        self.ourTunnel = ourTunnel
        self.ourTunnelIPv4 = ourTunnelIPv4
        self.ourTunnelObservedAt = ourTunnelObservedAt
        self.attributionNote = attributionNote
    }

    /// Spelled out rather than synthesized, because `init(from:)` below is
    /// custom and a key list that drifts from the field list is the kind of
    /// mistake no test would catch.
    enum CodingKeys: String, CodingKey {
        case schema, startedAt, sessionToken, tunnelPID
        case ourTunnel, ourTunnelIPv4, ourTunnelObservedAt, attributionNote
    }

    /// CUSTOM, because the two date fields need DIFFERENT strictness and
    /// synthesized `Codable` cannot express that: a malformed date in ANY field
    /// throws and rejects the whole file, which would make "the field is
    /// dropped" unreachable.
    ///
    ///   * `startedAt` is strict — a record that cannot say when its session
    ///     began is not a record of a session;
    ///   * `ourTunnelObservedAt` is lenient (`try?`) — it is diagnostic only,
    ///     and rejecting a whole record over it would NARROW nothing and LOSE an
    ///     otherwise usable attribution.
    ///
    /// `encode(to:)` stays synthesized: the writer has no such asymmetry.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        sessionToken = try c.decode(String.self, forKey: .sessionToken)
        tunnelPID = try c.decode(Int.self, forKey: .tunnelPID)
        ourTunnel = try c.decodeIfPresent(String.self, forKey: .ourTunnel)
        ourTunnelIPv4 = try c.decodeIfPresent(String.self, forKey: .ourTunnelIPv4)
        ourTunnelObservedAt = try? c.decodeIfPresent(Date.self, forKey: .ourTunnelObservedAt)
        attributionNote = try c.decodeIfPresent(String.self, forKey: .attributionNote)
    }

    /// REUSED, not copied: one statement of the date format for both state
    /// files, so a writer and a reader — including the sudo helper's `awk`
    /// reader — cannot disagree about it.
    public static func encoder() -> JSONEncoder { NetState.encoder() }

    /// PURE: size cap, schema check and field re-validation, with NO file I/O —
    /// so every rejection path is assertable from literal `Data`.
    ///
    /// `dateDecodingStrategy = .iso8601`, matching the encoder. That pairing is
    /// the cross-implementation contract: a plain `JSONDecoder()` here would
    /// silently make every record with a date undecodable, i.e. would turn the
    /// whole mechanism off while leaving it looking implemented.
    ///
    /// WHICH FAILURES REJECT THE FILE AND WHICH DROP A FIELD is decided by one
    /// rule: no field's loss may WIDEN scope. Dropping `ourTunnel` or
    /// `ourTunnelIPv4` can only remove the single live name from scope, so those
    /// are dropped; the schema, the pid, `startedAt` and the token identify the
    /// session itself, so those reject.
    public static func decode(_ data: Data) -> TunnelAttribution? {
        guard data.count <= maxBytes else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard var rec = try? d.decode(TunnelAttribution.self, from: data) else { return nil }

        // An unrecognised schema NARROWS reconcile, never widens it: a future
        // schema 2 is ignored rather than mis-parsed. Equality, as NetState does.
        guard rec.schema == currentSchema else { return nil }
        guard rec.tunnelPID > 1 else { return nil }
        guard !rec.sessionToken.isEmpty,
              rec.sessionToken.utf8.count <= maxTokenBytes else { return nil }

        // ONE rule for `ourTunnel` on both arms of this fix (the shell reader
        // applies the same pattern): `matchConfigdKey`'s own service pattern.
        // The name reaches a root `route` argv as `-ifscope <name>` and a
        // `State:/Network/Service/<name>/…` key, and those two paths already rely
        // on exactly this shape.
        if let t = rec.ourTunnel,
           t.range(of: "^utun[0-9]{1,3}$", options: .regularExpression) == nil {
            rec.ourTunnel = nil
            rec.attributionNote = "invalid"
        }
        // `IPv4(_:) != nil`, NOT `PrivilegedValidation.isValidIPv4` — the same
        // choice `NetState.decode` makes, so `010.0.1.1` and `1.2.3` are
        // rejected here rather than stored as a witness that can never match.
        if let a = rec.ourTunnelIPv4, IPv4(a) == nil { rec.ourTunnelIPv4 = nil }

        if var note = rec.attributionNote, note.utf8.count > maxNoteBytes {
            // By character, so a truncation cannot split a UTF-8 scalar.
            while note.utf8.count > maxNoteBytes { note.removeLast() }
            rec.attributionNote = note
        }
        return rec
    }

    /// Impure wrapper: descriptor hardening, then `decode`. `nil` for absent,
    /// unreadable, wrong-owner, oversized, truncated, non-JSON or
    /// schema-mismatched — every one of which means dead-only.
    ///
    /// The hardening is `NetState.load`'s, verbatim and for the same reason:
    /// `/var/run` is `drwxrwxr-x root:daemon`, so every check is made through
    /// the DESCRIPTOR and the content is read through that same descriptor
    /// rather than by looking the path up a second time.
    ///
    /// `note` exists because this file compiles into BOTH targets and neither
    /// has a shared logger, while the one thing worth logging here is a
    /// distinction: "absent" is the ordinary post-boot state, "present but
    /// rejected" is a tampered or corrupt file and must be visible rather than
    /// silently equal to a missing one. The daemon passes its own `log`.
    public static func load(path: String = TunnelAttribution.path,
                            note: (String) -> Void = { _ in }) -> TunnelAttribution? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            note("no attribution record at \(path) — reconcile plans dead-only")
            return nil
        }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              st.st_uid == 0,                       // written by root, or not trusted
              (st.st_mode & 0o022) == 0,            // not group- or world-writable
              st.st_size <= off_t(maxBytes)
        else {
            note("attribution record at \(path) REJECTED by the descriptor checks "
               + "— reconcile plans dead-only")
            return nil
        }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count <= maxBytes {
            let n = read(fd, &buf, buf.count)
            if n < 0 {
                note("attribution record at \(path) could not be read — dead-only")
                return nil
            }
            if n == 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        guard let rec = decode(data) else {
            note("attribution record at \(path) present but REJECTED by decode "
               + "— reconcile plans dead-only")
            return nil
        }
        return rec
    }

    /// PURE. One observation tick's decision, from injected facts only.
    ///
    /// `nowTunnelLike` is every tunnel-like name in the current snapshot, in
    /// snapshot order; `preexisting` is the set captured before `task.run()`.
    /// `addressOf` answers "what IPv4 does that name carry now", and
    /// `defaultRouteNetif` the netif holding the UNSCOPED default — read once,
    /// at the deadline, and only when it can break a tie.
    ///
    /// The function is STATELESS on purpose: a name that has resolved is still
    /// the only new tunnel-like name on the next tick, so later ticks re-emit
    /// `.resolved(sameName)` and fill in the address as soon as it appears.
    /// Nothing has to remember what the last tick said.
    ///
    /// Two orderings in it are decisions rather than style:
    ///
    ///   * one new name is answered BEFORE liveness, so "the interface appeared
    ///     and the process died in the same tick" resolves. The name is still
    ///     the right attribution, and its residue is exactly what reconcile has
    ///     to clean up;
    ///   * ambiguity is NOT terminal before the deadline. This machine carries
    ///     nine `utun`s and a `gif0` with no third-party VPN installed, because
    ///     macOS churns `utun`s for its own services, so two new names inside
    ///     our window is at least as likely to be that churn as a third party.
    public static func attributionOutcome(preexisting: Set<String>,
                                          nowTunnelLike: [String],
                                          addressOf: (String) -> String?,
                                          defaultRouteNetif: String?,
                                          processAlive: Bool,
                                          elapsed: TimeInterval,
                                          deadline: TimeInterval) -> AttributionTick {
        let new = nowTunnelLike.filter { !preexisting.contains($0) }
        let atDeadline = elapsed >= deadline

        func resolved(_ name: String) -> AttributionTick {
            guard let address = addressOf(name) else {
                // The name is ours either way; only the WITNESS is missing, and
                // without it this session degrades to dead-only. Said in the
                // note so the transcript names which of the two it was.
                return AttributionTick(outcome: .resolved(name), ourTunnelIPv4: nil,
                                       attributionNote: atDeadline ? "addressPending"
                                                                   : "pending")
            }
            return AttributionTick(outcome: .resolved(name), ourTunnelIPv4: address,
                                   attributionNote: nil)
        }

        if new.count == 1 { return resolved(new[0]) }

        if new.count >= 2 {
            guard atDeadline else {
                return AttributionTick(outcome: .pending, ourTunnelIPv4: nil,
                                       attributionNote: "pending")
            }
            // The tie-break: the gate has already proved no other tunnel of ours
            // is alive, and the physical default was the unscoped one before we
            // started, so an unscoped default on a brand-new `utun` is our own
            // vpnc-script's OverridePrimary at work.
            let holders = new.filter { $0 == defaultRouteNetif }
            if holders.count == 1 { return resolved(holders[0]) }
            return AttributionTick(outcome: .ambiguous(new.sorted()), ourTunnelIPv4: nil,
                                   attributionNote: "ambiguous")
        }

        if !processAlive {
            return AttributionTick(outcome: .processExited, ourTunnelIPv4: nil,
                                   attributionNote: "processExited")
        }
        if atDeadline {
            return AttributionTick(outcome: .timedOut, ourTunnelIPv4: nil,
                                   attributionNote: "timedOut")
        }
        return AttributionTick(outcome: .pending, ourTunnelIPv4: nil,
                               attributionNote: "pending")
    }
}
