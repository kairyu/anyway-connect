import Foundation

// Suite 1 — the on-link guard's case table.
//
// One row per numbered step in `evaluateDefaultGateway`'s FIXED order
// (NetGuard.swift:249-333), derived from the numbered step comments rather than
// from a recorded transcript. The order is not tidiness: the reason returned
// for a given input is relied upon by two planner clauses and three acceptance
// criteria, so a reordering that left every individual answer plausible would
// still be a defect.
//
// The snapshot is `test/stub-ifconfig.sh`'s `guard` snapshot transcribed into
// `NetInterface` literals, so this suite and the shell parity suite
// (`test/test-onlink-guard.sh`, which runs the same table against the POSIX sh
// port) are driven by the same inputs. If the two ever disagree, one of the two
// guards is wrong and a privileged route decision rests on the difference.

enum Suite01Guard {

    /// `test/stub-ifconfig.sh`'s `guard` snapshot, in its order:
    ///   lo0   127.0.0.1/8        up, loopback
    ///   en0   10.0.1.22/24       up
    ///   en1   no IPv4            up
    ///   en2   192.168.1.2/31     up   (no network or broadcast address exists)
    ///   en3   203.0.113.9/32     up
    ///   en4   10.0.1.40/24       DOWN
    ///   en6   no IPv4            DOWN (unconfigured must beat down)
    ///   utun7 192.168.204.16/32  up, POINTOPOINT — the observed bad gateway
    ///   utun9 10.9.9.9/24        up           — tunnel-like BY NAME only
    /// en5 is deliberately ABSENT.
    static let snapshot: [NetInterface] = [
        oneAddress("lo0", "127.0.0.1", 8, loopback: true),
        oneAddress("en0", "10.0.1.22", 24),
        noAddress("en1"),
        oneAddress("en2", "192.168.1.2", 31),
        oneAddress("en3", "203.0.113.9", 32),
        oneAddress("en4", "10.0.1.40", 24, up: false),
        noAddress("en6", up: false),
        oneAddress("utun7", "192.168.204.16", 32, p2p: true),
        oneAddress("utun9", "10.9.9.9", 24),
    ]

    static func run() {
        H.suite("Suite 1 — evaluateDefaultGateway, one row per step")
        let s = snapshot

        // ── The four literal rows the whole verification record rests on.
        // These are `test/test-onlink-guard.sh:75-78` element for element; the
        // acceptance criterion names them individually, so they are asserted
        // individually rather than folded into the step rows below.
        H.eq(guardVerdict("10.0.1.1", "en0", s), "accept",
             "AC-3  en0 10.0.1.1 -> accept")
        H.eq(guardVerdict("192.168.1.1", "en0", s), "gatewayOffLink",
             "AC-4  en0 192.168.1.1 -> gatewayOffLink")
        H.eq(guardVerdict("10.0.1.1", "en5", s), "targetInterfaceMissing",
             "AC-5  en5 10.0.1.1 -> targetInterfaceMissing")
        H.eq(guardVerdict("192.168.204.16", "en0", s), "gatewayIsTunnelAddress",
             "AC-6  en0 192.168.204.16 -> gatewayIsTunnelAddress")

        // ── Step 1: the interface name, validated BEFORE anything else looks
        // at it, because it is about to become an argv element for a root
        // `route` invocation. IFNAMSIZ - 1 is the kernel's own limit.
        H.eq(guardVerdict("10.0.1.1", "", s), "malformedInterfaceName",
             "step 1  an empty name")
        H.eq(guardVerdict("10.0.1.1", "EN0", s), "malformedInterfaceName",
             "step 1  not lowercase alphanumeric")
        H.eq(guardVerdict("10.0.1.1", "enaaaaaaaaaaaaaaa", s), "malformedInterfaceName",
             "step 1  longer than IFNAMSIZ-1")
        H.eq(guardVerdict("10.0.1.1", "en-0", s), "malformedInterfaceName",
             "step 1  a hyphen is not an interface character")

        // ── Step 2: a STRICT dotted quad. `inet_pton` accepts `010.0.1.1` and
        // canonicalises it, and `inet_aton` reads `10.0.1` as `10.0.0.1`; a
        // string two parsers read differently is how you delete the wrong route.
        H.eq(guardVerdict("link#9", "en0", s), "malformedGateway",
             "step 2  an -interface row's `link#N`")
        H.eq(guardVerdict("010.0.1.1", "en0", s), "malformedGateway",
             "step 2  a leading zero")
        H.eq(guardVerdict("+1.2.3.4", "en0", s), "malformedGateway",
             "step 2  a signed octet")
        H.eq(guardVerdict("", "en0", s), "malformedGateway",
             "step 2  the empty string")
        H.eq(guardVerdict("10.0.1", "en0", s), "malformedGateway",
             "step 2  three octets")
        H.eq(guardVerdict("10.0.1.1.5", "en0", s), "malformedGateway",
             "step 2  five octets")
        H.eq(guardVerdict("999.999.999.999", "en0", s), "malformedGateway",
             "step 2  octets over 255")
        H.eq(guardVerdict("nope", "en0", s), "malformedGateway",
             "step 2  not an address at all")
        H.eq(guardVerdict("10.0.1.1 ", "en0", s), "malformedGateway",
             "step 2  trailing whitespace")

        // ── Step 3: neither of these is a next hop, and both are accepted by
        // sloppier validators as "an IPv4 address". BEFORE the interface lookup,
        // which is why clause (b) cannot read these reasons as "the link is
        // present, up and addressed".
        H.eq(guardVerdict("0.0.0.0", "en0", s), "unspecifiedGateway",
             "step 3  0.0.0.0")
        H.eq(guardVerdict("255.255.255.255", "en0", s), "unspecifiedGateway",
             "step 3  255.255.255.255")
        H.eq(guardVerdict("0.0.0.0", "en5", s), "unspecifiedGateway",
             "step 3  reported for an ABSENT link too — steps 2 and 3 precede the lookup")
        H.eq(guardVerdict("link#7", "en5", s), "malformedGateway",
             "step 2  likewise: a malformed gateway outranks a missing link")

        // ── Steps 4/5: absent from the snapshot and present-but-un-addressed
        // are DIFFERENT answers, and clause (b) treats both as "the snapshot
        // cannot tell", never as "the route is dead".
        H.eq(guardVerdict("10.0.1.1", "en1", s), "targetInterfaceUnconfigured",
             "step 5  present with no IPv4")
        H.eq(guardVerdict("10.0.1.1", "en6", s), "targetInterfaceUnconfigured",
             "step 5  unaddressed AND down reports unconfigured — step 5 precedes step 7")

        // ── Step 6: a tunnel is never a legitimate target for restoring a
        // PHYSICAL default (FR-1.8). Before step 7, so a dead utun reports the
        // tunnel reason rather than "down".
        H.eq(guardVerdict("10.0.1.1", "utun7", s), "targetInterfaceIsTunnel",
             "step 6  a POINTOPOINT target")
        H.eq(guardVerdict("10.0.1.1", "utun9", s), "targetInterfaceIsTunnel",
             "step 6  tunnel-like BY NAME, without the flag")

        // ── Step 7.
        H.eq(guardVerdict("10.0.1.1", "en4", s), "targetInterfaceDown",
             "step 7  present, addressed, down")

        // ── Step 8: the real observed failure, reported by its own name — the
        // vendored vpnc-script answered utun7's OWN 192.168.204.16 as the
        // "physical" gateway. Across EVERY address of EVERY tunnel-like link,
        // whatever the target is.
        H.eq(guardVerdict("10.9.9.9", "en0", s), "gatewayIsTunnelAddress",
             "step 8  utun9's address, and utun9 is tunnel-like by name only")
        H.eq(guardVerdict("192.168.204.16", "en2", s), "gatewayIsTunnelAddress",
             "step 8  outranks the on-link test for a different target too")

        // ── Step 9: the target's own address is not a next hop — ANY of its
        // addresses, because a secondary address is as much "ourselves" as the
        // primary.
        H.eq(guardVerdict("10.0.1.22", "en0", s), "gatewayIsOwnAddress",
             "step 9  the target's own address")

        // ── Step 10: on-link for ANY (address, prefix) pair the link carries.
        H.eq(guardVerdict("10.0.1.5", "en0", s), "accept",
             "step 10 a different in-subnet address")
        H.eq(guardVerdict("192.168.1.0", "en2", s), "gatewayOffLink",
             "step 10 masks to a DIFFERENT /31")
        H.eq(guardVerdict("203.0.113.10", "en3", s), "gatewayOffLink",
             "step 10 at /32 only the own address is in-subnet")

        // ── Step 11, and its /31-and-/32 skip (RFC 3021).
        H.eq(guardVerdict("10.0.1.0", "en0", s), "gatewayIsNetworkAddress",
             "step 11 the matched subnet's network address")
        H.eq(guardVerdict("10.0.1.255", "en0", s), "gatewayIsBroadcastAddress",
             "step 11 the matched subnet's broadcast address")
        H.eq(guardVerdict("192.168.1.3", "en2", s), "accept",
             "step 11 skipped at /31: the peer is neither network nor broadcast")
        H.eq(guardVerdict("203.0.113.9", "en3", s), "gatewayIsOwnAddress",
             "step 11 at /32 step 9 has already answered")

        // ── Step 12: re-canonicalised from the parse, so the string we checked
        // and the string we hand to `route` cannot diverge. The payload is part
        // of the contract — the daemon installs `gateway`, not `candidate`.
        H.eq(evaluateDefaultGateway(candidate: "10.0.1.1", targetInterface: "en0",
                                    interfaces: s),
             .accept(gateway: "10.0.1.1", interface: "en0"),
             "step 12 accept carries the canonical gateway and the interface")

        // ── Secondary addresses. A rejection now authorises a privileged
        // DELETE, so a router on an ALIAS subnet of the very link it is
        // installed on must be seen as on-link rather than reported off-link.
        // That is why `ipv4s` is an array and not one address.
        let aliased: [NetInterface] = [
            NetInterface(name: "en0",
                         ipv4s: [.init(ipv4: IPv4("10.0.1.22")!, prefixLength: 24),
                                 .init(ipv4: IPv4("172.16.5.1")!, prefixLength: 24)],
                         isUp: true, isLoopback: false, isPointToPoint: false),
        ]
        H.eq(guardVerdict("172.16.5.9", "en0", aliased), "accept",
             "aliases on-link for a SECONDARY address is accepted, not swept")
        H.eq(guardVerdict("172.16.5.1", "en0", aliased), "gatewayIsOwnAddress",
             "aliases a secondary address is as much `ourselves` as the primary")
        H.eq(guardVerdict("172.16.5.0", "en0", aliased), "gatewayIsNetworkAddress",
             "aliases step 11 reasons about the MATCHED pair, not the primary")
        H.eq(guardVerdict("10.0.1.22", "en0", aliased), "gatewayIsOwnAddress",
             "aliases the primary is still itself")

        // ── The empty snapshot. Every evaluation must reject, which is what
        // makes a failed `getifaddrs` the safe direction for an INSTALL.
        H.eq(guardVerdict("10.0.1.1", "en0", []), "targetInterfaceMissing",
             "empty snapshot installs nothing")
    }
}
