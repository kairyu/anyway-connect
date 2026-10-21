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
    /// A tunnel the netstate says was somebody else's.
    case foreignTunnel(String)
    /// No netstate, so (a)/(b) fell back to acting on EVERY utun. Recorded and
    /// logged because of what it can dismantle — see open issue O-9.
    case widenedToAllTunnels([String])
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
    public static func plan(routeTable: String,
                            interfaces: [NetInterface],
                            configdKeys: [String],
                            netstate: NetState?) -> ReconcilePlan {
        var actions: [ReconcileAction] = []
        var kept: [ReconcileKept] = []
        var abort: ReconcileAbort?

        let rows = parseRouteTable(routeTable)

        // ── (a) configd keys (FR-2.5), scoped to tunnels that are not somebody
        // else's. Anchored at both ends with the service component constrained to
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

        let inScope: Set<String>
        if let ns = netstate {
            // Presence decides, not non-emptiness: a netstate with an empty
            // exclusion list is a positive statement that no tunnel was ours to
            // spare, which is different from having no netstate at all.
            let foreign = Set(ns.preexistingTunnels)
            inScope = tunnelNamesSeen.subtracting(foreign)
            kept += foreign.intersection(tunnelNamesSeen).sorted().map { .foreignTunnel($0) }
        } else {
            // FR-2.4/FR-2.5 as written: every utun. Recorded and logged because of
            // what it can dismantle on a machine also running a third-party VPN
            // (open issue O-9).
            inScope = tunnelNamesSeen
            if !inScope.isEmpty { kept.append(.widenedToAllTunnels(inScope.sorted())) }
        }

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
        // snapshot. Both evaluated BEFORE (b), both suppressing (b), (c) and (f),
        // both RETAINING (a) — the configd removals derive solely from the scutil
        // key list and need no route table at all, and on a wedged machine clearing
        // the DNS override is the single most valuable thing we can do.
        //
        // An input we cannot read is a reason NOT to act, never evidence that
        // routes are dead. Without (d″) the planner reads "the snapshot cannot
        // prove this gateway is on-link" as "this gateway is dead", sweeps the whole
        // table, deletes the physical default, and then refuses to install one for
        // the same reason it deleted — NFR-8 inverted into the failure it forbids.
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
        var installCandidateNote: String?
        if !hasUsablePhysicalDefault {
            let candidates = interfaces.filter(isUsablePhysical).map(\.name)
            var target: String?
            if let ns = netstate, candidates.contains(ns.physicalInterface) {
                target = ns.physicalInterface
            } else if let netif = preferredInstallTarget(offered: staleDefaultNetifs,
                                                         interfaces: interfaces) {
                // The link whose default we just removed is the obvious replacement —
                // but only if it is a link at all. Both this rung and the next are fed
                // by lists clause (b) built, and clause (b) records links it has itself
                // judged unusable, so each offer is filtered at the point of USE. Not
                // at the point of record: clause (g) below needs `staleDefaultNetifs`
                // unfiltered, because a stale default on an absent link is still a
                // deletion whose withholding has to be recorded.
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
/// `deriveDefaultGateway` (candidate 3) and by the reconcile planner (the
/// install-target hint and the tunnel scope). `stopTunnel` is the only remover —
/// `reconcile` deliberately leaves it in place, because every later reconcile in
/// the same boot needs its tunnel scope, and a stale advisory is already fenced
/// by FR-1.7's same-interface AND same-subnet precondition and then by the guard.
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
    /// openconnect was spawned — i.e. somebody else's. The planner subtracts
    /// these, so a reconcile cannot dismantle a third-party VPN's default route
    /// or resolver configuration.
    ///
    /// Why the exclusion list and not "our tunnel's name": at the moment this
    /// file is written OUR utun does not exist yet. The netstate is written
    /// milliseconds after `task.run()`, long before openconnect has
    /// authenticated and created its tunnel, and the daemon has no later hook.
    /// The complement is exactly as useful and is knowable now.
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
