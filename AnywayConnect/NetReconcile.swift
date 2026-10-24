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
