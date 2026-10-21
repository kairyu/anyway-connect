import Foundation

// Suite 5 — `NetReconcile.plan` on every committed fixture.
//
// HOW THE EXPECTATIONS WERE OBTAINED, because that is the only thing that makes
// this suite worth anything. Asserting a value the planner produced against the
// planner is a tautology, so:
//
//  * the clause-(c) slice of `kept` — one record per non-default row the sweep
//    declines to delete, in row order — is re-derived from the fixture text by
//    `test/harness/derive-expected.sh --kept <fixture>`, committed under
//    `test/harness/expected/<fixture>.kept.txt`, and diffed against a fresh
//    derivation by `test/run-swift-harness.sh` BEFORE this binary is compiled;
//  * the clause-(c) DELETIONS are re-derived the same way into
//    `expected/<fixture>.sweep.txt` and asserted in full by Suite 6;
//  * the scope record, the clause-(b) records and the clause-(f)/(g) records are
//    few enough per fixture to enumerate by hand from the fixture text, which is
//    what design.md §7.2 point 4 asks for. They are written out below with the
//    row that produces each.
//
// So `kept` is asserted as the exact ordered multiset, and the ordering is part
// of it: the scope record is appended first, then clause (b) in row order, then
// clause (c) in row order, then (f)'s ambiguity record and (g)'s withholding
// record.

enum Suite05Plan {

    /// The clause-(c) kept records, re-derived from the fixture by
    /// `derive-expected.sh --kept` and rendered back into `ReconcileKept`. The
    /// rendering is deliberately total: an unrecognised line is a failure rather
    /// than a silently skipped assertion.
    static func keptFromFixture(_ name: String) -> [ReconcileKept] {
        Fixtures.expected("\(name).kept.txt").map { line in
            let f = line.split(separator: " ").map(String.init)
            switch (f.first, f.count) {
            case ("onLinkRoute", 2):          return .onLinkRoute(f[1])
            case ("loopback", 2):             return .loopback(f[1])
            case ("multicast", 2):            return .multicast(f[1])
            case ("linkLocal", 2):            return .linkLocal(f[1])
            case ("unparsable", 2):           return .unparsable(f[1])
            case ("gatewayOnLink", 4):        return .gatewayOnLink(f[1], via: f[3])
            case ("tunnelOnLinkGateway", 4):  return .tunnelOnLinkGateway(f[1], via: f[3])
            case ("gatewayInLiveSubnet", 6):  return .gatewayInLiveSubnet(f[1], via: f[3],
                                                                         why: f[5])
            default:
                FileHandle.standardError.write(
                    Data("harness: unrecognised kept line: \(line)\n".utf8))
                exit(70)
            }
        }
    }

    /// The clause-(c) deletions, re-derived the same way, as plan ACTIONS.
    static func sweepFromFixture(_ name: String) -> [ReconcileAction] {
        Fixtures.expected("\(name).sweep.txt").map { line in
            let a = line.split(separator: " ").map(String.init)
            // `-n delete -net D -netmask M [-ifscope N]` or `-n delete -host D [-ifscope N]`
            var destination = "", netmask: String?, ifscope: String?
            var i = 2
            while i < a.count {
                switch a[i] {
                case "-net", "-host": destination = a[i + 1]; i += 2
                case "-netmask":      netmask = a[i + 1]; i += 2
                case "-ifscope":      ifscope = a[i + 1]; i += 2
                default:
                    FileHandle.standardError.write(
                        Data("harness: unrecognised sweep line: \(line)\n".utf8))
                    exit(70)
                }
            }
            return .deleteRoute(RouteDeletion(destination: destination, netmask: netmask,
                                              ifscope: ifscope))
        }
    }

    private static func check(_ fixture: String,
                              interfaces interfacesName: String? = nil,
                              configdKeys: [String] = [],
                              netstate: NetState? = nil,
                              label: String,
                              actions: [ReconcileAction],
                              abort: ReconcileAbort? = nil,
                              kept: [ReconcileKept],
                              note: String? = nil) {
        let plan = NetReconcile.plan(
            routeTable: Fixtures.routeTable(fixture),
            interfaces: Fixtures.interfaces(interfacesName ?? fixture),
            configdKeys: configdKeys,
            netstate: netstate)
        H.eqList(plan.actions, actions, "\(label): actions")
        H.eq(plan.abort, abort, "\(label): abort")
        H.eqList(plan.kept, kept, "\(label): kept")
        H.eq(plan.installCandidateNote, note, "\(label): installCandidateNote")
    }

    static func run() {
        H.suite("Suite 5 — plan on every committed fixture")

        // ── clean: a machine with nothing to repair. The one row of clause (b)
        // is `default 192.168.1.1 UGScg en0`, unscoped and guard-accepted, so it
        // is the thing being protected and (f) emits no install.
        check("clean", label: "clean",
              actions: [],
              kept: [.physicalDefaultUsable(netif: "en0")] + keptFromFixture("clean"))

        // ── no-default: the state the vendored script's own teardown leaves
        // behind. No clause-(b) row at all, and (f) still installs — there is
        // deliberately no "the plan is otherwise non-empty" conjunct.
        check("no-default", label: "no-default",
              actions: [.installDefaultRoute(interface: "en0")],
              kept: keptFromFixture("no-default"),
              note: "routeTable none; netstateAdvisory none")

        // ── two-physical: two usable links and no default row, so (f) has no
        // way to choose and records the ambiguity instead of guessing.
        check("two-physical", label: "two-physical",
              actions: [],
              kept: keptFromFixture("two-physical")
                  + [.ambiguousInstallTarget(["en0", "en1"])])

        // ── link-down: en0 is addressed but NOT up, so its default is kept
        // ("the link may come back with the same subnet"), and en1 is the only
        // usable link.
        //
        // NOTE FOR THE NEXT CHANGE: the install target below is `en0` — the very
        // link clause (b) has just classified unusable. That IS defect 3
        // (design.md §4.1): rung 3 of the ladder reads `keptPhysicalDefaultNetifs`
        // without filtering it through `isUsablePhysical`. This suite asserts the
        // UNMODIFIED behaviour on purpose, because the harness has to be proved
        // against the unmodified planner first. The defect-3 fix changes this
        // one expectation to `en1`.
        check("link-down", label: "link-down",
              actions: [.installDefaultRoute(interface: "en0")],
              kept: [.physicalDefaultUnusable(netif: "en0", why: "link down")]
                  + keptFromFixture("link-down"),
              note: "routeTable 10.0.1.1; netstateAdvisory none")

        // ── lingering-utun: utun7 is still addressed with no tunnel process.
        // The two routes via its LIVE address are kept (FR-2.6c: the gateway is
        // on-link for a live interface), and the two via the vanished utun8
        // address are swept — the kept case and the swept case of the same shape.
        check("lingering-utun", label: "lingering-utun",
              actions: [.deleteTunnelDefaultRoute(netif: "utun7", ifscoped: true)]
                  + sweepFromFixture("lingering-utun"),
              kept: [.widenedToAllTunnels(["utun7", "utun8"]),
                     .physicalDefaultUsable(netif: "en0")]
                  + keptFromFixture("lingering-utun"))

        // ── two-tunnels, no netstate: FR-2.4/FR-2.5 as written, i.e. every
        // utun. Recorded as `widenedToAllTunnels` because of what it can
        // dismantle on a machine also running a third-party VPN.
        check("two-tunnels", configdKeys: Fixtures.scutilKeys("two-tunnels"),
              label: "two-tunnels (no netstate)",
              actions: [.removeConfigdKey("State:/Network/Service/utun0/IPv4"),
                        .removeConfigdKey("State:/Network/Service/utun0/DNS"),
                        .removeConfigdKey("State:/Network/Service/utun7/IPv4"),
                        .removeConfigdKey("State:/Network/Service/utun7/DNS"),
                        .deleteTunnelDefaultRoute(netif: "utun7", ifscoped: false),
                        .deleteTunnelDefaultRoute(netif: "utun0", ifscoped: true),
                        .installDefaultRoute(interface: "en0")],
              kept: [.widenedToAllTunnels(["utun0", "utun7"])]
                  + keptFromFixture("two-tunnels"),
              note: "routeTable none; netstateAdvisory none")

        // ── two-tunnels WITH a netstate naming utun0 as somebody else's. THE
        // DISCRIMINATION TEST: no action names utun0 — not its default route,
        // not either of its configd keys — and it appears in `kept` instead.
        // Twice, because the scope derivation and clause (b) each record it.
        check("two-tunnels", configdKeys: Fixtures.scutilKeys("two-tunnels"),
              netstate: Suite04Derivation.netstate(tunnels: ["utun0"]),
              label: "two-tunnels (utun0 is foreign)",
              actions: [.removeConfigdKey("State:/Network/Service/utun7/IPv4"),
                        .removeConfigdKey("State:/Network/Service/utun7/DNS"),
                        .deleteTunnelDefaultRoute(netif: "utun7", ifscoped: false),
                        .installDefaultRoute(interface: "en0")],
              kept: [.foreignTunnel("utun0"), .foreignTunnel("utun0")]
                  + keptFromFixture("two-tunnels"),
              note: "routeTable none; netstateAdvisory 192.168.1.1")

        // ── carried-home: THE REPORTED INCIDENT. The surviving
        // `default 10.0.1.1 UGScIg en0` row is the blackhole; utun7 is gone from
        // the snapshot, so it is dead under every scope and its default is
        // deleted unconditionally (FR-2.4). 236 sweep deletions, then the
        // install that makes the deletion safe.
        check("carried-home", label: "carried-home",
              actions: [.deleteTunnelDefaultRoute(netif: "utun7", ifscoped: false),
                        .deleteStalePhysicalDefaultRoute(netif: "en0", ifscoped: true,
                                                         reason: .gatewayOffLink)]
                  + sweepFromFixture("carried-home")
                  + [.installDefaultRoute(interface: "en0")],
              kept: [.widenedToAllTunnels(["gif0", "stf0", "utun0", "utun1", "utun2",
                                           "utun7"])]
                  + keptFromFixture("carried-home"),
              note: "routeTable 10.0.1.1; netstateAdvisory none")

        // ── vpn-up: the SAME table on the office LAN. Nothing is swept, because
        // every gateway in it is reachable — 10.0.1.1 is on-link for en0,
        // 10.0.1.22 is en0's own address, and 192.168.204.16 is held by a LIVE
        // utun7. The en0 default is scoped-only, so it is kept and (f) still
        // installs the unscoped form. This is the live machine's actual shape.
        check("vpn-up", configdKeys: Fixtures.scutilKeys("vpn-up"), label: "vpn-up",
              actions: [.removeConfigdKey("State:/Network/Service/utun7/IPv4"),
                        .removeConfigdKey("State:/Network/Service/utun7/DNS"),
                        .deleteTunnelDefaultRoute(netif: "utun7", ifscoped: false),
                        .installDefaultRoute(interface: "en0")],
              kept: [.widenedToAllTunnels(["gif0", "stf0", "utun0", "utun1", "utun2",
                                           "utun3", "utun4", "utun5", "utun6", "utun7"]),
                     .physicalDefaultUnusable(netif: "en0", why: "ifscope-only")]
                  + keptFromFixture("vpn-up"),
              note: "routeTable 10.0.1.1; netstateAdvisory none")

        // ── cap-exceeded: 300 distinct destinations via a dead gateway. The
        // SWEEP aborts, not the whole reconcile — clearing the DNS hijack,
        // removing a dead default and installing a working one are the bounded
        // actions that turn "no internet" into "internet". Paired with
        // interfaces.clean.json, which has no utun and whose en0 is
        // 192.168.1.42/24 (see test/fixtures/README.md).
        check("cap-exceeded", interfaces: "clean", label: "cap-exceeded",
              actions: [.deleteStalePhysicalDefaultRoute(netif: "en0", ifscoped: true,
                                                         reason: .gatewayOffLink),
                        .installDefaultRoute(interface: "en0")],
              abort: .sweepCapExceeded(found: 300, cap: 256),
              kept: keptFromFixture("cap-exceeded"),
              note: "routeTable 10.0.1.1; netstateAdvisory none")
        H.eq(NetReconcile.sweepCap, 256, "the cap bounds DISTINCT destinations at 256")

        // ── (d′) and (d″): the two fail-closed aborts. Both suppress (b), (c)
        // and (f) and both RETAIN (a), and they are distinct cases because the
        // transcript has to name which input failed.
        var p = NetReconcile.plan(routeTable: "not a route table",
                                  interfaces: Fixtures.interfaces("clean"),
                                  configdKeys: ["State:/Network/Service/utun7/DNS"],
                                  netstate: nil)
        H.eq(p.abort, .routeTableUnreadable, "(d′) an unreadable table")
        H.eqList(p.actions, [.removeConfigdKey("State:/Network/Service/utun7/DNS")],
                 "(d′) retains the configd removals and emits nothing else")

        p = NetReconcile.plan(routeTable: Fixtures.routeTable("carried-home"),
                              interfaces: [oneAddress("lo0", "127.0.0.1", 8,
                                                      loopback: true)],
                              configdKeys: ["State:/Network/Service/utun7/DNS"],
                              netstate: nil)
        H.eq(p.abort, .interfaceSnapshotUnusable,
             "(d″) lo0 alone is not a usable snapshot — otherwise (d″) is unreachable")
        H.eqList(p.actions, [.removeConfigdKey("State:/Network/Service/utun7/DNS")],
                 "(d″) sweeps nothing, deletes no default, installs nothing")

        p = NetReconcile.plan(routeTable: Fixtures.routeTable("carried-home"),
                              interfaces: [], configdKeys: [], netstate: nil)
        H.eq(p.abort, .interfaceSnapshotUnusable,
             "(d″) an empty snapshot: a failed getifaddrs is not evidence of dead routes")

        // ── Clause (f) rung 2 reads `staleDefaultNetifs.first` with NO
        // usability filter, and clause (g) is therefore UNREACHABLE on this
        // planner: a stale deletion can only exist when `staleDefaultNetifs` is
        // non-empty, and a non-empty `staleDefaultNetifs` always yields rung 2 a
        // target, so the "deleted without installing" condition cannot arise.
        //
        // The case below makes both facts visible at once. `unspecifiedGateway`
        // is returned at step 3, BEFORE the interface lookup, so the row's link
        // need not exist — and `en9` is absent from the snapshot, yet it is
        // chosen as the install target over the two links that are present and
        // addressed. That is defect 3 (design.md §4.2) at rung 2, and filtering
        // rung 2 through `isUsablePhysical` is what will make clause (g)
        // reachable.
        let header = "Destination        Gateway            Flags               Netif Expire"
        let twoLinks = [oneAddress("lo0", "127.0.0.1", 8, loopback: true),
                        oneAddress("en0", "192.168.1.42", 24),
                        oneAddress("en1", "192.168.2.42", 24)]
        p = NetReconcile.plan(routeTable: header + "\ndefault 0.0.0.0 UGScg en9",
                              interfaces: twoLinks, configdKeys: [], netstate: nil)
        H.eqList(p.actions,
                 [.deleteStalePhysicalDefaultRoute(netif: "en9", ifscoped: false,
                                                   reason: .unspecifiedGateway),
                  .installDefaultRoute(interface: "en9")],
                 "rung 2 picks the ABSENT en9 over two live links (defect 3's hazard)")
        H.eqList(p.kept, [], "and records no ambiguity, because rung 2 answered first")
        H.eq(p.abort, nil, "the snapshot is usable, so nothing aborts")

        // The netstate hint outranks rung 2 — but only when it names a link the
        // snapshot can actually use.
        p = NetReconcile.plan(routeTable: header + "\ndefault 0.0.0.0 UGScg en9",
                              interfaces: twoLinks, configdKeys: [],
                              netstate: Suite04Derivation.netstate(interface: "en1",
                                                                   subnet: "192.168.2.0/24",
                                                                   advisory: "192.168.2.1"))
        H.eqList(p.actions,
                 [.deleteStalePhysicalDefaultRoute(netif: "en9", ifscoped: false,
                                                   reason: .unspecifiedGateway),
                  .installDefaultRoute(interface: "en1")],
                 "rung 1: a netstate naming a usable candidate wins")
        H.eq(p.installCandidateNote, "routeTable none; netstateAdvisory 192.168.2.1",
             "and the note records what apply time will be compared against")
    }
}
