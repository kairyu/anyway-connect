import Foundation

// Suite 3 — the configd key reduction and `matchConfigdKey`.
//
// `matchConfigdKey` (NetReconcile.swift) is `private static`, so it is driven
// through the ONE observable it feeds: clause (a) of `plan`, which emits one
// `.removeConfigdKey` per key it matches. The route table is deliberately empty
// so clause (d′) aborts — the configd removals are appended BEFORE the abort
// check, precisely because they derive solely from the scutil key list and need
// no route table at all. On a wedged machine clearing the DNS override is the
// single most valuable thing the daemon can do, so this is the behaviour worth
// pinning.
//
// The snapshot below is ONE USABLE PHYSICAL LINK and no tunnel, which is this
// suite's minimum input rather than a detail: the tunnel scope acts on a tunnel
// only when it is absent from a snapshot that is itself usable, so an EMPTY
// snapshot — which this suite used to pass — now means `.none` and no removals
// at all. That is the fail-closed direction and it is asserted in its own right
// at the end of this suite, and in Suite 5's (d″) case and Suite 12's case 17.
//
// The anchoring matters more than it looks: on a real machine the UUID-named
// service IS the resolver configuration. A pattern that matched it would have
// reconcile delete the machine's own DNS.

enum Suite03ConfigdKeys {

    /// One usable physical link, no tunnel: every `utunN` a key names is
    /// therefore absent from a usable snapshot, i.e. provably dead and in scope.
    private static let liveEn0 = [oneAddress("lo0", "127.0.0.1", 8, loopback: true),
                                  oneAddress("en0", "10.0.1.22", 24)]

    /// Every key this suite offers is emitted as a removal if, and only if,
    /// `matchConfigdKey` accepts it.
    private static func removals(_ keys: [String]) -> [String] {
        NetReconcile.plan(routeTable: "", interfaces: liveEn0, configdKeys: keys,
                          netstate: nil, attribution: nil)
            .actions.compactMap {
                if case .removeConfigdKey(let k) = $0 { return k } else { return nil }
            }
    }

    static func run() {
        H.suite("Suite 3 — configdKeys(fromScutilOutput:) and matchConfigdKey")

        // ── The reduction. `scutil` prints DISPLAY lines, not bare keys: each
        // line is reduced to the text after its FIRST " = ", trimmed, and a line
        // without " = " is dropped. NO filtering here — selecting which services
        // matter is the planner's job, on bare keys.
        H.eqList(Fixtures.scutilKeys("vpn-up"),
                 ["State:/Network/Service/11111111-2222-3333-4444-555555555555/DNS",
                  "State:/Network/Service/11111111-2222-3333-4444-555555555555/IPv4",
                  "State:/Network/Service/utun7/DNS",
                  "State:/Network/Service/utun7/IPv4"],
                 "scutil-keys.vpn-up reduces to 4 bare keys, UUID service included")
        H.eq(Fixtures.scutilKeys("two-tunnels").count, 6,
             "scutil-keys.two-tunnels reduces to 6 bare keys")
        H.eqList(NetReconcile.configdKeys(fromScutilOutput:
                    "  subKey [0] = State:/Network/Service/utun7/DNS\n"
                  + "no equals sign here\n"
                  + "  subKey [1] =   \n"
                  + "  a = b = c\n"),
                 ["State:/Network/Service/utun7/DNS", "b = c"],
                 "a line without \" = \" is dropped; an empty value is dropped; only the FIRST split")

        // ── Both kinds accepted, and IPv4 BEFORE DNS per utun — the same order
        // the installed vpnc-script uses in its own removal heredoc.
        H.eqList(removals(["State:/Network/Service/utun7/DNS",
                           "State:/Network/Service/utun7/IPv4"]),
                 ["State:/Network/Service/utun7/IPv4",
                  "State:/Network/Service/utun7/DNS"],
                 "both kinds accepted, emitted IPv4 then DNS regardless of input order")
        H.eqList(removals(["State:/Network/Service/utun7/IPv4",
                           "State:/Network/Service/utun0/IPv4"]),
                 ["State:/Network/Service/utun0/IPv4",
                  "State:/Network/Service/utun7/IPv4"],
                 "tunnels in ascending name order")

        // ── The `{1,3}` digit bound.
        H.eqList(removals(["State:/Network/Service/utun999/IPv4"]),
                 ["State:/Network/Service/utun999/IPv4"], "utun999 is accepted")
        H.eqList(removals(["State:/Network/Service/utun1234/IPv4"]), [],
                 "utun1234 is rejected — the service component is utun + 1 to 3 digits")
        H.eqList(removals(["State:/Network/Service/utun/IPv4"]), [],
                 "utun with no digits is rejected")

        // ── The UUID-named service. On a real machine this is the REAL resolver
        // configuration, so it must never match.
        H.eqList(removals(Fixtures.scutilKeys("vpn-up")),
                 ["State:/Network/Service/utun7/IPv4",
                  "State:/Network/Service/utun7/DNS"],
                 "the UUID-named service in scutil-keys.vpn-up is REJECTED")
        H.eqList(removals(Fixtures.scutilKeys("two-tunnels")),
                 ["State:/Network/Service/utun0/IPv4",
                  "State:/Network/Service/utun0/DNS",
                  "State:/Network/Service/utun7/IPv4",
                  "State:/Network/Service/utun7/DNS"],
                 "two-tunnels: both utuns, UUID service still rejected")

        // ── Both anchors, tested by prefixing and suffixing a valid key.
        H.eqList(removals(["XState:/Network/Service/utun7/IPv4"]), [],
                 "a prefixed key is rejected (the ^ anchor)")
        H.eqList(removals(["State:/Network/Service/utun7/IPv4X"]), [],
                 "a suffixed key is rejected (the $ anchor)")
        H.eqList(removals([" State:/Network/Service/utun7/IPv4"]), [],
                 "a leading space is rejected")
        H.eqList(removals(["Setup:/Network/Service/utun7/IPv4"]), [],
                 "the Setup: domain is not the State: domain")
        H.eqList(removals(["State:/Network/Service/utun7/Proxies"]), [],
                 "only the IPv4 and DNS kinds")
        H.eqList(removals(["State:/Network/Service/utun7/IPv4/Extra"]), [],
                 "a deeper key is rejected")

        // ── And the contract this suite leans on: the removals survive the
        // fail-closed abort.
        let p = NetReconcile.plan(routeTable: "", interfaces: liveEn0,
                                  configdKeys: ["State:/Network/Service/utun7/DNS"],
                                  netstate: nil, attribution: nil)
        H.eq(p.abort, .routeTableUnreadable, "an unreadable table aborts")
        H.eq(p.actions.count, 1, "and the configd removal is retained anyway")

        // ── The OTHER fail-closed abort does not retain it, and that asymmetry
        // is deliberate: with no usable interface in the snapshot we cannot see
        // whether a third party is live, and the key we would remove is
        // somebody's resolver configuration.
        let blind = NetReconcile.plan(routeTable: "", interfaces: [],
                                      configdKeys: ["State:/Network/Service/utun7/DNS"],
                                      netstate: nil, attribution: nil)
        H.eq(blind.abort, .routeTableUnreadable,
             "an unreadable table is still reported first")
        H.eqList(blind.actions, [],
                 "but with NO usable interface the removal is not emitted at all")
    }
}
