import Foundation

// Suite 4 — `NetReconcile.physicalDefault` and `deriveDefaultGateway`.
//
// `physicalDefault` is what makes `startTunnel` skip writing a netstate rather
// than write a partial one, so its `nil` cases matter as much as its answers.
//
// `deriveDefaultGateway` IS the fix for the reported incident, which is why it
// lives in the shared pure layer and is reachable from here at all. Its
// transcript is part of the contract and not a diagnostic: "we did nothing" is
// only a useful answer if it says why, and the daemon logs these lines and
// returns them to the app.

enum Suite04Derivation {

    /// A netstate built from literals. Never read from, or written to, a real
    /// /var/run path — see Support.swift's constraint 2.
    static func netstate(interface: String = "en0",
                         subnet: String = "192.168.1.0/24",
                         advisory: String = "192.168.1.1",
                         tunnels: [String] = []) -> NetState {
        NetState(writtenAt: Date(timeIntervalSince1970: 1_700_000_000),
                 physicalInterface: interface,
                 physicalSubnet: subnet,
                 physicalGatewayAdvisory: advisory,
                 exceptionRoutes: [],
                 tunnelPID: 4242,
                 preexistingTunnels: tunnels)
    }

    static func run() {
        H.suite("Suite 4 — physicalDefault and deriveDefaultGateway")

        // ── physicalDefault: the non-tunnel default's interface and gateway,
        // with the subnet filled in from the snapshot.
        H.eq(tuple(NetReconcile.physicalDefault(routeTable: Fixtures.routeTable("vpn-up"),
                                                interfaces: Fixtures.interfaces("vpn-up"))),
             "en0|10.0.1.1|10.0.1.0/24",
             "vpn-up: the utun7 default is excluded, the scoped en0 row answers")
        H.eq(tuple(NetReconcile.physicalDefault(
                routeTable: Fixtures.routeTable("lingering-utun"),
                interfaces: Fixtures.interfaces("lingering-utun"))),
             "en0|192.168.1.1|192.168.1.0/24",
             "lingering-utun: the unscoped physical default answers")
        // The subnet comes from the LIVE snapshot, not from the row: at home the
        // office default is still printed on en0, and the subnet reported is the
        // home one. That asymmetry is the whole reported incident.
        H.eq(tuple(NetReconcile.physicalDefault(
                routeTable: Fixtures.routeTable("carried-home"),
                interfaces: Fixtures.interfaces("carried-home"))),
             "en0|10.0.1.1|192.168.1.0/24",
             "carried-home: the office gateway against the HOME subnet")

        // Unscoped is preferred over scoped regardless of table order — `??`
        // falls back to the first row only when no unscoped row exists.
        let bothForms = header
            + "\ndefault 10.0.1.1 UGScIg en0"
            + "\ndefault 10.0.1.2 UGScg en0"
        H.eq(tuple(NetReconcile.physicalDefault(routeTable: bothForms,
                                                interfaces: Suite01Guard.snapshot)),
             "en0|10.0.1.2|10.0.1.0/24",
             "the UNSCOPED row wins even when the scoped one is printed first")

        H.ok(NetReconcile.physicalDefault(routeTable: Fixtures.routeTable("two-tunnels"),
                                          interfaces: Fixtures.interfaces("two-tunnels")) == nil,
             "two-tunnels: both defaults are on tunnels, so there is no physical default")
        H.ok(NetReconcile.physicalDefault(routeTable: Fixtures.routeTable("no-default"),
                                          interfaces: Fixtures.interfaces("no-default")) == nil,
             "no-default: nil, which is what makes startTunnel skip the netstate")
        H.ok(NetReconcile.physicalDefault(routeTable: header + "\ndefault link#15 UCSg en0",
                                          interfaces: Suite01Guard.snapshot) == nil,
             "an -interface default has no IPv4 next hop, so it is not a candidate")
        H.ok(NetReconcile.physicalDefault(routeTable: header + "\ndefault 10.0.1.1 UGScg en9",
                                          interfaces: Suite01Guard.snapshot) == nil,
             "a default on a link absent from the snapshot has no subnet to report")
        H.ok(NetReconcile.physicalDefault(routeTable: header + "\ndefault 10.0.1.1 UGScg en1",
                                          interfaces: Suite01Guard.snapshot) == nil,
             "nor does an un-addressed link")

        // ── deriveDefaultGateway: three candidates, FIRST ACCEPT WINNING, with
        // one transcript line per candidate considered.
        let clean = Fixtures.interfaces("clean")

        var d = deriveDefaultGateway(interface: "en0", interfaces: clean,
                                     dhcpRouter: "192.168.1.1",
                                     routeTable: Fixtures.routeTable("clean"),
                                     netstate: netstate())
        H.eq(d.accepted, GatewayDerivation.Accepted(gateway: "192.168.1.1", source: .dhcp),
             "candidate 1: a live DHCP lease wins")
        H.eqList(d.transcript, ["dhcp 192.168.1.1 -> accept"],
                 "and nothing further is considered")

        d = deriveDefaultGateway(interface: "en0", interfaces: clean,
                                 dhcpRouter: "10.0.1.1",
                                 routeTable: Fixtures.routeTable("clean"),
                                 netstate: nil)
        H.eq(d.accepted, GatewayDerivation.Accepted(gateway: "192.168.1.1", source: .routeTable),
             "candidate 2: a stale off-link lease is refused and the table answers")
        H.eqList(d.transcript, ["dhcp 10.0.1.1 -> reject(gatewayOffLink)",
                                "routeTable 192.168.1.1 -> accept"],
                 "and the transcript names the refusal")

        d = deriveDefaultGateway(interface: "en0", interfaces: clean,
                                 dhcpRouter: nil,
                                 routeTable: Fixtures.routeTable("no-default"),
                                 netstate: netstate())
        H.eq(d.accepted, GatewayDerivation.Accepted(gateway: "192.168.1.1", source: .netstateAdvisory),
             "candidate 3: the netstate advisory, same interface AND same subnet")
        H.eqList(d.transcript, ["dhcp (none)", "routeTable (none)",
                                "netstateAdvisory 192.168.1.1 -> accept"],
                 "an absent candidate still gets a transcript line")

        // FR-1.7's two halves, checked separately so the transcript can say
        // which one failed. A carried-home laptop fails the SUBNET half, and
        // that is the reported incident reduced to one comparison.
        d = deriveDefaultGateway(interface: "en0",
                                 interfaces: Fixtures.interfaces("carried-home"),
                                 dhcpRouter: nil,
                                 routeTable: Fixtures.routeTable("carried-home"),
                                 netstate: netstate(subnet: "10.0.1.0/24",
                                                    advisory: "10.0.1.1"))
        H.ok(d.accepted == nil, "THE REPORTED INCIDENT: nothing is acceptable, so nothing is installed")
        H.eqList(d.transcript, ["dhcp (none)",
                                "routeTable 10.0.1.1 -> reject(gatewayOffLink)",
                                "netstateAdvisory 10.0.1.1 -> reject(subnet-mismatch)"],
                 "and all three refusals are named")

        d = deriveDefaultGateway(interface: "en0", interfaces: clean, dhcpRouter: nil,
                                 routeTable: "", netstate: netstate(interface: "en9"))
        H.ok(d.accepted == nil, "a netstate about a DIFFERENT interface contributes nothing")
        H.eqList(d.transcript, ["dhcp (none)", "routeTable (none)",
                                "netstateAdvisory (none)"],
                 "and the same-interface half is reported as absence, not mismatch")

        d = deriveDefaultGateway(interface: "en0", interfaces: clean, dhcpRouter: nil,
                                 routeTable: "", netstate: nil)
        H.ok(d.accepted == nil, "no netstate at all: still refuse (FR-1.9)")
        H.eqList(d.transcript, ["dhcp (none)", "routeTable (none)",
                                "netstateAdvisory (none)"],
                 "three lines even when there was nothing to consider")

        d = deriveDefaultGateway(interface: "en0", interfaces: clean, dhcpRouter: "",
                                 routeTable: "", netstate: nil)
        H.eqList(d.transcript, ["dhcp (none)", "routeTable (none)",
                                "netstateAdvisory (none)"],
                 "an EMPTY dhcp answer is `(none)`, not a malformed candidate")

        // The table candidate takes the FIRST default row for this interface, so
        // a scoped row is an eligible SOURCE — scoping matters to deletion, not
        // to where a gateway may be read from.
        d = deriveDefaultGateway(interface: "en0", interfaces: Suite01Guard.snapshot,
                                 dhcpRouter: nil, routeTable: bothForms, netstate: nil)
        H.eq(d.accepted, GatewayDerivation.Accepted(gateway: "10.0.1.1", source: .routeTable),
             "the scoped row is an eligible gateway SOURCE, and the first row wins")

        // A tunnel target is refused at step 6 before any candidate can help.
        d = deriveDefaultGateway(interface: "utun7", interfaces: Suite01Guard.snapshot,
                                 dhcpRouter: "10.0.1.1", routeTable: "", netstate: nil)
        H.ok(d.accepted == nil, "a tunnel is never a restore target (FR-1.8)")
        H.eq(d.transcript.first, "dhcp 10.0.1.1 -> reject(targetInterfaceIsTunnel)",
             "and the transcript says so by name")
    }

    /// `physicalDefault`'s tuple flattened to one comparable string.
    private static func tuple(_ v: (interface: String, gateway: String, subnet: String)?)
        -> String {
        guard let v else { return "nil" }
        return "\(v.interface)|\(v.gateway)|\(v.subnet)"
    }

    private static let header =
        "Destination        Gateway            Flags               Netif Expire"
}
