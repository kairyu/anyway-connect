import Foundation

// ── The on-link guard, and the only notion of "on-link" in this project ──────
//
// Compiled into BOTH targets, so it must stay Foundation-only — no Network, no
// AppKit, no SystemConfiguration. The daemon links Foundation alone.
//
// Why this file exists at all. The reported incident was a laptop carried from
// work to home: the app had captured `10.0.1.1` as "the physical gateway" on the
// office LAN and replayed it verbatim as the default next hop at home, where the
// link is `192.168.1.0/24`. A default route via an unreachable next hop is not a
// degraded network, it is no network — and it survives until something deletes
// it. On another occasion the vendored vpnc-script's get_default_gw() answered
// utun7's OWN address, `192.168.204.16`, which produced the same blackhole with
// the tunnel already gone.
//
// Both are the same mistake: installing a gateway nobody re-validated against
// the link it is about to be installed on. So every decision about a next hop
// goes through `evaluateDefaultGateway` below, which is PURE — everything it
// knows arrives as a parameter. That is what lets the scratch harness execute
// the whole case table without a tunnel, a daemon, or a route mutation.
//
// The impure collectors live at the bottom, fenced off by name and comment,
// because the purity of everything above them is what the tests rest on.

// MARK: - Address model

/// IPv4 only (the tunnel, the routes and the gateway this app reasons about are
/// all IPv4; see the design's assumption 1). Stored as `UInt32` in HOST byte
/// order so masking is plain arithmetic rather than per-octet juggling.
public struct IPv4: Equatable, Hashable, Codable, CustomStringConvertible {
    public let raw: UInt32

    public init(raw: UInt32) { self.raw = raw }

    /// Strict dotted quad: exactly four decimal octets, each `0...255`, no leading
    /// zeros, no sign, no whitespace, nothing else. So `10.0.1`, `010.0.1.1`,
    /// `+1.2.3.4`, `1.2.3.4.5` and `1.2.3.4 ` are all `nil`.
    ///
    /// Written out rather than delegated, which was the first thing this guard
    /// got wrong: Darwin's `inet_pton(AF_INET, …)` ACCEPTS `010.0.1.1` and
    /// canonicalises it to `10.0.1.1` (verified in the harness, which is how the
    /// case was caught), and `PrivilegedValidation.isValidIPv4` accepts it too.
    /// Strictness is the whole point of this type — it decides what may become a
    /// `route` argument, and a string that two parsers read differently is
    /// exactly how you install or delete the wrong route. `inet_aton` reads
    /// `3.7.35` as `3.7.0.35`, which is the same hazard in the other direction.
    public init?(_ text: String) {
        let octets = text.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var raw: UInt32 = 0
        for octet in octets {
            guard (1...3).contains(octet.count),
                  octet.allSatisfy({ $0.isASCII && $0.isNumber }),
                  octet.count == 1 || octet.first != "0",
                  let value = UInt32(octet), value <= 255
            else { return nil }
            raw = (raw << 8) | value
        }
        self.raw = raw
    }

    /// Canonical `a.b.c.d`. Everything that leaves this type for an argv goes
    /// through here, so the checked string and the executed string cannot differ.
    public var text: String {
        "\((raw >> 24) & 0xff).\((raw >> 16) & 0xff).\((raw >> 8) & 0xff).\(raw & 0xff)"
    }

    public var description: String { text }

    /// `nil` outside `0...32` rather than a clamp: an out-of-range prefix is a
    /// parse failure upstream, and silently treating `/33` as `/32` would turn a
    /// malformed route-table row into a deletable one.
    public static func mask(bits: Int) -> UInt32? {
        guard (0...32).contains(bits) else { return nil }
        return bits == 0 ? 0 : ~UInt32(0) << (32 - UInt32(bits))
    }

    /// Dotted-quad form of a prefix length, for `route -n delete -netmask <m>`.
    public static func maskText(bits: Int) -> String? {
        mask(bits: bits).map { IPv4(raw: $0).text }
    }

    /// Invalid `bits` returns `self` unchanged — callers validate the prefix
    /// before they get here (the parser rejects anything outside `0...32`), and
    /// returning `0.0.0.0` would make an invalid prefix look like a match
    /// against the default route.
    public func masked(bits: Int) -> IPv4 {
        guard let m = IPv4.mask(bits: bits) else { return self }
        return IPv4(raw: raw & m)
    }

    /// Broadcast address of the enclosing prefix. Meaningless at /31 and /32,
    /// which is why step 11 of the guard skips it there (RFC 3021).
    public func broadcast(bits: Int) -> IPv4 {
        guard let m = IPv4.mask(bits: bits) else { return self }
        return IPv4(raw: (raw & m) | ~m)
    }

    public var isUnspecified: Bool { raw == 0 }
    public var isBroadcastAll: Bool { raw == 0xffff_ffff }
    public var isLoopback: Bool { (raw & 0xff00_0000) == 0x7f00_0000 }       // 127/8
    public var isMulticast: Bool { (raw & 0xf000_0000) == 0xe000_0000 }      // 224/4
    public var isLinkLocal: Bool { (raw & 0xffff_0000) == 0xa9fe_0000 }      // 169.254/16

    // Codable as the canonical text, not as a number: the fixtures are
    // hand-authored JSON that a human has to be able to check against a
    // `netstat` capture (design §9.2).
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = IPv4(text) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "not a strict dotted-quad IPv4 address: \(text)"))
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)
    }
}

/// One live interface, as the guard sees it.
///
/// `Codable` on purpose: this is the fixture format for the plan tests
/// (design §9.2), so there is exactly one definition of "what a live interface
/// looked like" and no second `ifconfig` parser anywhere in the tree.
public struct NetInterface: Equatable, Codable {

    /// One IPv4 address of the link, with the prefix length its netmask implies.
    ///
    /// A struct and not the tuple the plan sketches, because a tuple cannot be
    /// `Codable` and the fixtures are JSON. The member names are the tuple's, so
    /// every call site reads the same.
    public struct Address: Equatable, Codable {
        public let ipv4: IPv4
        public let prefixLength: Int
        public init(ipv4: IPv4, prefixLength: Int) {
            self.ipv4 = ipv4
            self.prefixLength = prefixLength
        }
    }

    public let name: String

    /// EVERY IPv4 address the link carries, in `getifaddrs` order.
    ///
    /// All of them, not just the first, because a guard rejection now authorises
    /// a privileged DELETE (§4.3(b)): a default route whose next hop is on-link
    /// for a SECONDARY address of the very link it is installed on would
    /// otherwise classify `gatewayOffLink` and be deleted as stale. The earlier
    /// shape — "first address wins, aliases ignored" — was safe only while a
    /// rejection could do nothing worse than decline to install.
    public let ipv4s: [Address]

    public let isUp: Bool                  // IFF_UP && IFF_RUNNING
    public let isLoopback: Bool            // IFF_LOOPBACK
    public let isPointToPoint: Bool        // IFF_POINTOPOINT

    public init(name: String, ipv4s: [Address], isUp: Bool,
                isLoopback: Bool, isPointToPoint: Bool) {
        self.name = name
        self.ipv4s = ipv4s
        self.isUp = isUp
        self.isLoopback = isLoopback
        self.isPointToPoint = isPointToPoint
    }

    /// Single-address convenience, for the common case and for every hand-built
    /// snapshot in a test.
    public init(name: String, ipv4: IPv4?, prefixLength: Int?, isUp: Bool,
                isLoopback: Bool = false, isPointToPoint: Bool = false) {
        let addrs: [Address]
        if let a = ipv4, let p = prefixLength {
            addrs = [Address(ipv4: a, prefixLength: p)]
        } else {
            addrs = []
        }
        self.init(name: name, ipv4s: addrs, isUp: isUp,
                  isLoopback: isLoopback, isPointToPoint: isPointToPoint)
    }

    /// The link's primary address, i.e. the first `getifaddrs` returned.
    ///
    /// Computed over `ipv4s` rather than stored, so `targetInterfaceMissing`
    /// (AC-5) and `targetInterfaceUnconfigured` (FR-1.2b) keep distinguishing an
    /// absent link from a present-but-un-addressed one exactly as before: an
    /// IPv4-less link is PRESENT with `ipv4 == nil`.
    public var ipv4: IPv4? { ipv4s.first?.ipv4 }
    public var prefixLength: Int? { ipv4s.first?.prefixLength }

    /// A tunnel, by name as well as by flag. Name-based too because a `utun`
    /// that has just lost its peer can still be IFF_UP without IFF_POINTOPOINT,
    /// and the name is what both vpnc-script and today's snapshot code key on.
    public var isTunnelLike: Bool {
        isPointToPoint || name.hasPrefix("utun") || name.hasPrefix("ppp")
            || name.hasPrefix("ipsec") || name.hasPrefix("gif") || name.hasPrefix("stf")
    }

    /// `"10.0.1.0/24"` for the primary address; `nil` when the link has none.
    /// This is the string FR-1.7's "same subnet" precondition compares.
    public var subnetCIDR: String? {
        guard let a = ipv4, let p = prefixLength, (0...32).contains(p) else { return nil }
        return "\(a.masked(bits: p).text)/\(p)"
    }

    private enum CodingKeys: String, CodingKey {
        case name, ipv4s, isUp, isLoopback, isPointToPoint
    }
}

// MARK: - The guard

/// Why a candidate next hop was refused. The REASON is part of the contract, not
/// a diagnostic: AC-4 wants it distinguishable from the other refusals, AC-6
/// wants the tunnel case named, and both §4.3(b) and §4.3(c) branch on it — (b)
/// deletes a default route only for the reasons that mean "this next hop
/// provably cannot carry traffic", never merely because the guard said no.
public enum GatewayRejection: String, Equatable {
    case malformedInterfaceName      // fails isValidInterface / longer than IFNAMSIZ-1
    case malformedGateway            // not an IPv4 literal, or empty
    case unspecifiedGateway          // 0.0.0.0 or 255.255.255.255
    case targetInterfaceMissing      // absent from the snapshot              (FR-1.2b)
    case targetInterfaceUnconfigured // present, but no IPv4 address/netmask  (FR-1.2b)
    case targetInterfaceIsTunnel     // utun*/ppp*/point-to-point target      (FR-1.8)
    case targetInterfaceDown         // present and addressed, but not up
    case gatewayIsTunnelAddress      // == an address of ANY tunnel iface     (FR-1.2c)
    case gatewayIsOwnAddress         // == an address of the target itself    (FR-1.2d)
    case gatewayOffLink              // outside every subnet of the target    (FR-1.2a)
    case gatewayIsNetworkAddress     // the matched subnet's network address
    case gatewayIsBroadcastAddress   // the matched subnet's broadcast address
}

public enum GatewayVerdict: Equatable {
    case accept(gateway: String, interface: String)
    case reject(GatewayRejection)
}

/// Decides whether `candidate` may be installed as the default next hop for
/// `targetInterface`.
///
/// PURE: no `Process`, no file I/O, no global state. Everything it knows arrives
/// in `interfaces`. That is not a stylistic preference — it is what makes the
/// 17-row case table executable in a harness on a machine that is live on the
/// VPN, which is the only way this code could be tested at all.
///
/// The evaluation order below is FIXED and must not be reordered for tidiness;
/// the reason returned for a given input is relied upon by two planner clauses
/// and three acceptance criteria.
public func evaluateDefaultGateway(candidate: String,
                                   targetInterface: String,
                                   interfaces: [NetInterface]) -> GatewayVerdict {

    // 1. The interface name is about to become an argv element for a root
    //    `route` invocation, so it is validated before anything else looks at it.
    //    IFNAMSIZ - 1 is the kernel's own limit.
    guard !targetInterface.isEmpty, targetInterface.utf8.count <= 15,
          PrivilegedValidation.isValidInterface(targetInterface) else {
        return .reject(.malformedInterfaceName)
    }

    // 2. Strict dotted quad, so `010.0.1.1` is refused here rather than meaning
    //    something different to `route` than it did to us.
    guard let gw = IPv4(candidate) else { return .reject(.malformedGateway) }

    // 3. Neither of these is a next hop, and both are accepted by sloppier
    //    validators as "an IPv4 address".
    if gw.isUnspecified || gw.isBroadcastAll { return .reject(.unspecifiedGateway) }

    // 4/5. Absent from the snapshot vs present-but-un-addressed are DIFFERENT
    //    answers (AC-5 vs FR-1.2b) and §4.3(b) treats both as "the snapshot
    //    cannot tell", never as "the route is dead". Step 5 precedes step 7, so
    //    an IPv4-less link that is also down reports `unconfigured`.
    guard let target = interfaces.first(where: { $0.name == targetInterface }) else {
        return .reject(.targetInterfaceMissing)
    }
    guard !target.ipv4s.isEmpty else { return .reject(.targetInterfaceUnconfigured) }

    // 6. FR-1.8: the whole operation exists to restore a PHYSICAL default, and a
    //    tunnel is never a legitimate target for it. Before step 7, so a dead
    //    utun reports the tunnel reason rather than "down".
    if target.isTunnelLike { return .reject(.targetInterfaceIsTunnel) }

    // 7. A down link cannot carry the traffic we would be pointing at it.
    guard target.isUp else { return .reject(.targetInterfaceDown) }

    // 8. The real observed failure, reported by its own name: vpnc-script's
    //    get_default_gw() answered utun7's own 192.168.204.16 as the "physical"
    //    gateway. Calling that merely "off-link" would hide the mechanism, and
    //    §4.3(c) needs this reason to classify the sweep. Address-only
    //    comparison — a utun with no netmask in the snapshot still counts — and
    //    across EVERY address of the tunnel, for step 9's reason.
    for iface in interfaces where iface.isTunnelLike {
        if iface.ipv4s.contains(where: { $0.ipv4 == gw }) {
            return .reject(.gatewayIsTunnelAddress)
        }
    }

    // 9. The target's own address is not a next hop. ANY of its addresses: a
    //    secondary address is just as much "ourselves" as the primary.
    if target.ipv4s.contains(where: { $0.ipv4 == gw }) {
        return .reject(.gatewayIsOwnAddress)
    }

    // 10. On-link for ANY (address, prefix) pair the link carries. The matched
    //     pair is what step 11 then reasons about: a candidate can only be the
    //     network or broadcast address of the subnet it actually sits in.
    guard let match = target.ipv4s.first(where: { pair in
        guard (0...32).contains(pair.prefixLength) else { return false }
        return gw.masked(bits: pair.prefixLength) == pair.ipv4.masked(bits: pair.prefixLength)
    }) else {
        return .reject(.gatewayOffLink)
    }

    // 11. Skipped at /31 and /32, where neither address exists (RFC 3021) and
    //     steps 9-10 have already covered every degenerate case: at /32 the only
    //     in-subnet address IS the interface's own, so anything else is already
    //     `gatewayOffLink`.
    if match.prefixLength <= 30 {
        if gw == match.ipv4.masked(bits: match.prefixLength) {
            return .reject(.gatewayIsNetworkAddress)
        }
        if gw == match.ipv4.broadcast(bits: match.prefixLength) {
            return .reject(.gatewayIsBroadcastAddress)
        }
    }

    // 12. Re-canonicalised from the parse, so the string we checked and the
    //     string we hand to `route` cannot diverge.
    return .accept(gateway: gw.text, interface: targetInterface)
}

// MARK: - The derivation ladder

public enum GatewaySource: String, Equatable { case dhcp, routeTable, netstateAdvisory }

public struct GatewayDerivation: Equatable {
    public struct Accepted: Equatable {
        public let gateway: String
        public let source: GatewaySource
        public init(gateway: String, source: GatewaySource) {
            self.gateway = gateway
            self.source = source
        }
    }

    /// `nil` ⇒ nothing acceptable was found and the caller MUST NOT touch
    /// routing at all (FR-1.9). Not "install the old value anyway" — that is the
    /// bug this file exists to remove.
    public let accepted: Accepted?

    /// One line per candidate considered, accepted or rejected, in order. Goes
    /// to the daemon log and back to the app in the reply, because "we did
    /// nothing" is only a useful answer if it says why.
    public let transcript: [String]

    public init(accepted: Accepted?, transcript: [String]) {
        self.accepted = accepted
        self.transcript = transcript
    }
}

/// FR-1.6/FR-1.7's candidate ladder. PURE — the caller collects `dhcpRouter`,
/// `routeTable` and `netstate`; this decides. It lives here, in the shared pure
/// layer, rather than in the daemon, precisely because it IS the fix for the
/// reported incident and therefore has to be reachable from the harness.
///
/// Candidates, first `accept` winning:
///   1. `dhcpRouter` — the re-derived value FR-1.6 demands; a live lease wins.
///   2. the route table's existing IPv4 default for `interface` — covers
///      statically configured links, where `ipconfig` says nothing. Ordered
///      after DHCP so a live lease beats a possibly-stale table row, and the
///      guard re-validates it against the link's CURRENT subnet, so a leftover
///      from another network is rejected rather than reinstalled.
///   3. `netstate.physicalGatewayAdvisory` — only when the netstate names this
///      same interface AND the same subnet. That conjunction is FR-1.7 verbatim,
///      and its absence is what blackholed the carried-home laptop.
public func deriveDefaultGateway(interface: String,
                                 interfaces: [NetInterface],
                                 dhcpRouter: String?,
                                 routeTable: String,
                                 netstate: NetState?) -> GatewayDerivation {
    var transcript: [String] = []

    func consider(_ source: GatewaySource, _ candidate: String?) -> GatewayDerivation.Accepted? {
        guard let candidate, !candidate.isEmpty else {
            transcript.append("\(source.rawValue) (none)")
            return nil
        }
        switch evaluateDefaultGateway(candidate: candidate,
                                      targetInterface: interface,
                                      interfaces: interfaces) {
        case .accept(let gateway, _):
            transcript.append("\(source.rawValue) \(candidate) -> accept")
            return .init(gateway: gateway, source: source)
        case .reject(let reason):
            transcript.append("\(source.rawValue) \(candidate) -> reject(\(reason.rawValue))")
            return nil
        }
    }

    if let a = consider(.dhcp, dhcpRouter) {
        return GatewayDerivation(accepted: a, transcript: transcript)
    }

    // Both the scoped (`UGScIg en0`) and the unscoped row are eligible as a
    // gateway SOURCE; scoping matters only to deletion and to "is a usable
    // default present" (§4.3). First row in table order wins — the guard
    // re-validates whichever it is, so the choice cannot install something the
    // table did not already claim.
    let tableGateway = NetReconcile.parseRouteTable(routeTable).first { row in
        row.destination == .defaultRoute && row.netif == interface && row.gateway != nil
    }?.gateway?.text
    if let a = consider(.routeTable, tableGateway) {
        return GatewayDerivation(accepted: a, transcript: transcript)
    }

    // FR-1.7's two halves, checked separately so the transcript can say which
    // one failed: a carried-home laptop fails the subnet half, and that is the
    // reported incident reduced to one comparison.
    if let ns = netstate, ns.physicalInterface == interface {
        let live = interfaces.first(where: { $0.name == interface })?.subnetCIDR
        if let live, live == ns.physicalSubnet {
            if let a = consider(.netstateAdvisory, ns.physicalGatewayAdvisory) {
                return GatewayDerivation(accepted: a, transcript: transcript)
            }
        } else {
            transcript.append("\(GatewaySource.netstateAdvisory.rawValue) "
                              + "\(ns.physicalGatewayAdvisory) -> reject(subnet-mismatch)")
        }
    } else {
        transcript.append("\(GatewaySource.netstateAdvisory.rawValue) (none)")
    }

    return GatewayDerivation(accepted: nil, transcript: transcript)
}

// MARK: - Impure collectors
//
// EVERYTHING BELOW THIS LINE TOUCHES THE LIVE SYSTEM.
//
// Nothing above it does, and the scratch harness is forbidden from referencing
// `NetProbe` at all (design §9.1) — it shells out at the machine the developer
// is connected on. Every REDUCTION of this output into a decision lives in the
// pure layer (`NetReconcile`), so each collector is a fixed command line plus
// one function call. That is what lets the harness test the parsing without
// running the commands.

/// Bounded capture of a fixed absolute path.
///
/// Internal, not private, because the daemon's `livePIDs()` needs the same
/// bounded runner and a second copy of this is a second set of timeout bugs.
/// The shape is deliberately the same judgement `VPNRunner.shellCapture` makes:
/// a fixed `PATH`, `/dev/null` on stdin unless given something, a wall-clock
/// bound, and a cap on how much output we are willing to hold.
///
/// A timeout or a non-zero exit yields `""` — never a partial parse. A truncated
/// route table read as authoritative is exactly how a sweep decides the whole
/// internet is unreachable.
@discardableResult
func capture(_ launchPath: String, _ args: [String],
             stdin: String? = nil,
             timeout: TimeInterval = 5,
             outputCap: Int = 1 << 20) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: launchPath)
    task.arguments = args
    // Fixed and minimal: these run as root in the daemon, and an inherited PATH
    // is caller-supplied input.
    task.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

    let outPipe = Pipe()
    task.standardOutput = outPipe
    // Discarded rather than merged: every caller parses stdout positionally, and
    // a warning interleaved into a route table is a parse error waiting to be
    // read as data.
    task.standardError = FileHandle.nullDevice

    let inPipe: Pipe? = stdin == nil ? nil : Pipe()
    task.standardInput = inPipe ?? FileHandle.nullDevice

    do { try task.run() } catch { return "" }

    if let inPipe, let stdin {
        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        try? inPipe.fileHandleForWriting.close()
    }

    // Drained off this thread so the wait below can be bounded; reading inline
    // is what makes a timeout unenforceable.
    var data = Data()
    let lock = NSLock()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        let handle = outPipe.fileHandleForReading
        var buf = Data()
        while buf.count < outputCap {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buf.append(chunk)
        }
        lock.lock(); data = buf; lock.unlock()
        group.leave()
    }

    if group.wait(timeout: .now() + timeout) == .timedOut {
        task.terminate()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
        }
        _ = group.wait(timeout: .now() + 3)
        return ""
    }
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { return "" }
    lock.lock(); let out = data; lock.unlock()
    return String(data: out.prefix(outputCap), encoding: .utf8) ?? ""
}

public enum NetProbe {

    /// Live interface snapshot via `getifaddrs(3)`. No shelling out: `ifconfig`'s
    /// output has already cost this project one arithmetic bug
    /// (`route-wrapper.sh`'s "0x2.: invalid arithmetic operator"), and AF_INET
    /// sockaddrs carry the mask directly.
    ///
    /// SNAPSHOT CONTRACT, stated because several decisions rest on it.
    /// `getifaddrs` returns one entry per (interface, address family); this returns
    ///   - exactly ONE `NetInterface` per distinct interface NAME present in
    ///     `getifaddrs`, INCLUDING links that carry only AF_LINK or AF_INET6
    ///     entries and no AF_INET — those appear with `ipv4s == []`, never omitted;
    ///   - flags taken from any entry for that name (they are per-link, not
    ///     per-family);
    ///   - EVERY AF_INET address of the link, in `getifaddrs` order, in `ipv4s`.
    ///     The earlier contract said the first address won and aliases were
    ///     ignored, calling that "the safe direction". It is no longer safe: a
    ///     rejection can now authorise a privileged delete, so a router on an
    ///     alias subnet must be seen as on-link rather than reported off-link.
    ///     That is why `ipv4s` is an array.
    ///
    /// Why the first two clauses are load-bearing. (1) §3.2 steps 4 and 5 can only
    /// distinguish `targetInterfaceMissing` (AC-5) from
    /// `targetInterfaceUnconfigured` (FR-1.2b) if an IPv4-less link is PRESENT
    /// with `ipv4 == nil` — and since the fixtures are hand-written JSON, an
    /// AF_INET-only collector would disagree with them while every suite passed.
    /// (2) §4.3(a)'s tunnel scope reads `isTunnelLike` interfaces out of this
    /// snapshot, and `utun0…utun6`, `gif0` and `stf0` on the target machine are
    /// up, POINTOPOINT and IPv6-only: under an AF_INET-only collector
    /// `preexistingTunnels` is empty there and every third-party tunnel falls
    /// into reconcile's scope.
    ///
    /// A `getifaddrs` failure yields `[]`. For `restoreDefaultRoute` that is the
    /// safe direction (every guard evaluation then rejects
    /// `targetInterfaceMissing` and nothing is installed); inside `reconcile` it
    /// is NOT safe on its own, which is why §4.3(d″) aborts on an unusable
    /// snapshot before any route reasoning happens.
    public static func interfaces() -> [NetInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        // Insertion order preserved deliberately: `ipv4s.first` is "the primary
        // address" and the whole point is that it is the one the kernel listed
        // first, not an arbitrary dictionary order.
        var order: [String] = []
        var flags: [String: UInt32] = [:]
        var addrs: [String: [NetInterface.Address]] = [:]

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: ptr.pointee.ifa_name)
            if flags[name] == nil {
                order.append(name)
                flags[name] = ptr.pointee.ifa_flags
            }
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            // No netmask means no subnet, and a guessed class mask here would be
            // a guess the guard then treats as fact. Skip the address instead.
            guard let nm = ptr.pointee.ifa_netmask, nm.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            let maskRaw = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            // Contiguity check: a non-contiguous mask has no prefix length, and
            // reconstructing one from the bit count would silently widen or
            // narrow the subnet the guard compares against.
            let bits = maskRaw.nonzeroBitCount
            guard IPv4.mask(bits: bits) == maskRaw else { continue }
            addrs[name, default: []].append(.init(ipv4: IPv4(raw: addr), prefixLength: bits))
        }

        return order.map { name in
            let f = flags[name] ?? 0
            return NetInterface(
                name: name,
                ipv4s: addrs[name] ?? [],
                isUp: (f & UInt32(IFF_UP)) != 0 && (f & UInt32(IFF_RUNNING)) != 0,
                isLoopback: (f & UInt32(IFF_LOOPBACK)) != 0,
                isPointToPoint: (f & UInt32(IFF_POINTOPOINT)) != 0)
        }
    }

    /// `/usr/sbin/netstat -rn -f inet`, raw text. Parsed by
    /// `NetReconcile.parseRouteTable`, never here.
    public static func routeTable() -> String {
        capture("/usr/sbin/netstat", ["-rn", "-f", "inet"])
    }

    /// Dynamic-store keys for the IPv4/DNS services, ENUMERATED — never guessed.
    /// `scutil` takes its command on stdin and nothing else.
    public static func configdServiceKeys() -> [String] {
        NetReconcile.configdKeys(fromScutilOutput:
            capture("/usr/sbin/scutil", [],
                    stdin: "list State:/Network/Service/[^/]+/(DNS|IPv4)\n"))
    }

    /// Current router for one interface, in a fixed order:
    ///   1. `ipconfig getoption <iface> router` — trimmed, must satisfy `IPv4(_:)`
    ///   2. `parseRouterFromSummary(ipconfig getsummary <iface>)`
    /// Both answer only for DHCP-configured links; a statically configured
    /// interface yields `nil` here and is covered by `deriveDefaultGateway`'s
    /// candidate 2.
    public static func dhcpRouter(for iface: String) -> String? {
        guard PrivilegedValidation.isValidInterface(iface) else { return nil }
        let option = capture("/usr/sbin/ipconfig", ["getoption", iface, "router"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if IPv4(option) != nil { return option }
        return NetReconcile.parseRouterFromSummary(
            capture("/usr/sbin/ipconfig", ["getsummary", iface]))
    }

    /// `/sbin/route -n get default`'s `interface:` line, or `nil`.
    ///
    /// Verified live: with BOTH an unscoped default via `utun7` and a scoped
    /// default via `en0` present, this answers `utun7` — i.e. it reports the route
    /// ordinary (unbound) traffic will use, which is exactly the stop condition
    /// the conditional unscoped-default deletion needs (§4.4). Used to make
    /// default-route deletion targeted and to re-check `restoreDefaultRoute`'s
    /// precondition privileged-side — NEVER to choose a gateway.
    public static func currentDefaultInterface() -> String? {
        let text = capture("/sbin/route", ["-n", "get", "default"])
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "interface" else { continue }
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            return PrivilegedValidation.isValidInterface(name) ? name : nil
        }
        return nil
    }
}
