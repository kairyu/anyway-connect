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

    /// `attribution` defaults to `nil` HERE, in the harness, because that is the
    /// answer most of these fixtures are about: a plan with no identity claim,
    /// which is dead-only. `NetReconcile.plan` itself takes no default, so the
    /// daemon cannot reach that state by omission.
    private static func check(_ fixture: String,
                              interfaces interfacesName: String? = nil,
                              configdKeys: [String] = [],
                              netstate: NetState? = nil,
                              attribution: TunnelAttribution? = nil,
                              label: String,
                              actions: [ReconcileAction],
                              abort: ReconcileAbort? = nil,
                              kept: [ReconcileKept],
                              note: String? = nil) {
        let plan = NetReconcile.plan(
            routeTable: Fixtures.routeTable(fixture),
            interfaces: Fixtures.interfaces(interfacesName ?? fixture),
            configdKeys: configdKeys,
            netstate: netstate,
            attribution: attribution)
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
        // The install target is `en1`, NOT the `en0` whose default row clause
        // (b) just classified unusable: rung 3 offers `en0` and the ladder
        // filters that offer through `isUsablePhysical` at the point of use, so
        // rung 4 is reached and the one usable link is chosen. Until the defect-3
        // fix this expectation was `en0` with the note `routeTable 10.0.1.1`, and
        // the install was then refused at apply time — safe, and no repair. The
        // note is `routeTable none` because en1 has no default row to inherit a
        // gateway from; apply time derives one from the live DHCP lease.
        check("link-down", label: "link-down",
              actions: [.installDefaultRoute(interface: "en1")],
              kept: [.physicalDefaultUnusable(netif: "en0", why: "link down")]
                  + keptFromFixture("link-down"),
              note: "routeTable none; netstateAdvisory none")

        // ── lingering-utun: utun7 is still addressed with no tunnel process.
        // The two routes via its LIVE address are kept (FR-2.6c: the gateway is
        // on-link for a live interface), and the two via the vanished utun8
        // address are swept — the kept case and the swept case of the same shape.
        //
        // With NO identity claim, the live utun7 is out of scope and its default
        // route is left alone: the only tunnel acted on is the vanished `utun8`,
        // which has no default row of its own. Suite 12 case 15 drives the same
        // fixture with the witness, where utun7's default IS deleted.
        check("lingering-utun", label: "lingering-utun (no attribution)",
              actions: sweepFromFixture("lingering-utun"),
              kept: [.foreignTunnel("utun7"),
                     .physicalDefaultUsable(netif: "en0"),
                     .foreignTunnel("utun7")]
                  + keptFromFixture("lingering-utun"))

        // ── two-tunnels, no identity claim: both utuns are LIVE, so neither is
        // in scope and the plan is empty. The install is withheld too — utun7's
        // unscoped default survives, so `route add default` could only EEXIST.
        check("two-tunnels", configdKeys: Fixtures.scutilKeys("two-tunnels"),
              label: "two-tunnels (no attribution)",
              actions: [],
              kept: [.foreignTunnel("utun0"), .foreignTunnel("utun7"),
                     .foreignTunnel("utun7"), .foreignTunnel("utun0")]
                  + keptFromFixture("two-tunnels")
                  + [.installWithheldForSurvivingDefault(netif: "utun7")])

        // ── two-tunnels WITH an attribution record naming utun7 as ours and
        // witnessing its address. THE DISCRIMINATION TEST: no action names utun0
        // — not its default route, not either of its configd keys — and it
        // appears in `kept` instead. Twice, because the scope derivation and
        // clause (b) each record it.
        check("two-tunnels", configdKeys: Fixtures.scutilKeys("two-tunnels"),
              attribution: Suite11Attribution.attr(ourTunnel: "utun7",
                                                   ourTunnelIPv4: "192.168.204.16"),
              label: "two-tunnels (utun7 is ours and witnessed)",
              actions: [.removeConfigdKey("State:/Network/Service/utun7/IPv4"),
                        .removeConfigdKey("State:/Network/Service/utun7/DNS"),
                        .deleteTunnelDefaultRoute(netif: "utun7", ifscoped: false),
                        .installDefaultRoute(interface: "en0")],
              kept: [.foreignTunnel("utun0"), .foreignTunnel("utun0")]
                  + keptFromFixture("two-tunnels"),
              note: "routeTable none; netstateAdvisory none")

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
              kept: [.foreignTunnel("gif0"), .foreignTunnel("stf0"),
                     .foreignTunnel("utun0"), .foreignTunnel("utun1"),
                     .foreignTunnel("utun2")]
                  + keptFromFixture("carried-home"),
              note: "routeTable 10.0.1.1; netstateAdvisory none")

        // ── vpn-up: the SAME table on the office LAN. Nothing is swept, because
        // every gateway in it is reachable — 10.0.1.1 is on-link for en0,
        // 10.0.1.22 is en0's own address, and 192.168.204.16 is held by a LIVE
        // utun7. The en0 default is scoped-only, so it is kept.
        //
        // With no identity claim every one of the ten tunnels is live and out of
        // scope, so the plan is empty and the install is withheld: utun7's
        // unscoped default is still the kernel's answer for `default`. Suite 12
        // case 18 drives the same fixture with the witness, which reproduces
        // today's plan exactly.
        check("vpn-up", configdKeys: Fixtures.scutilKeys("vpn-up"),
              label: "vpn-up (no attribution)",
              actions: [],
              kept: [.foreignTunnel("gif0"), .foreignTunnel("stf0"),
                     .foreignTunnel("utun0"), .foreignTunnel("utun1"),
                     .foreignTunnel("utun2"), .foreignTunnel("utun3"),
                     .foreignTunnel("utun4"), .foreignTunnel("utun5"),
                     .foreignTunnel("utun6"), .foreignTunnel("utun7"),
                     .foreignTunnel("utun7"),
                     .physicalDefaultUnusable(netif: "en0", why: "ifscope-only")]
                  + keptFromFixture("vpn-up")
                  + [.installWithheldForSurvivingDefault(netif: "utun7")])

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
        // and (f), and they are distinct cases because the transcript has to name
        // which input failed. They now differ in what they retain, and the
        // asymmetry is the decided part:
        //
        //   * (d′) RETAINS (a). The configd removals derive solely from the
        //     scutil key list and need no route table at all, and on a wedged
        //     machine clearing the DNS override is the most valuable thing we can
        //     do. The interface snapshot is readable here, so `dead` is real.
        //   * (d″) RETAINS NOTHING, because the scope is `.none`: with no
        //     readable interface list we cannot see whether a third party is
        //     live, and the key we would remove is somebody's resolver
        //     configuration.
        var p = NetReconcile.plan(routeTable: "not a route table",
                                  interfaces: Fixtures.interfaces("clean"),
                                  configdKeys: ["State:/Network/Service/utun7/DNS"],
                                  netstate: nil, attribution: nil)
        H.eq(p.abort, .routeTableUnreadable, "(d′) an unreadable table")
        H.eqList(p.actions, [.removeConfigdKey("State:/Network/Service/utun7/DNS")],
                 "(d′) retains the configd removals — utun7 is absent from a USABLE "
               + "snapshot, so it is dead and its key configures nothing")

        p = NetReconcile.plan(routeTable: Fixtures.routeTable("carried-home"),
                              interfaces: [oneAddress("lo0", "127.0.0.1", 8,
                                                      loopback: true)],
                              configdKeys: ["State:/Network/Service/utun7/DNS"],
                              netstate: nil, attribution: nil)
        H.eq(p.abort, .interfaceSnapshotUnusable,
             "(d″) lo0 alone is not a usable snapshot — otherwise (d″) is unreachable")
        H.eqList(p.actions, [],
                 "(d″) sweeps nothing, deletes no default, installs nothing — AND "
               + "emits no configd removal either")
        H.eqList(p.kept, [.foreignTunnel("utun7")],
                 "(d″) every tunnel it saw is recorded as out of scope")

        p = NetReconcile.plan(routeTable: Fixtures.routeTable("carried-home"),
                              interfaces: [], configdKeys: [], netstate: nil,
                              attribution: nil)
        H.eq(p.abort, .interfaceSnapshotUnusable,
             "(d″) an empty snapshot: a failed getifaddrs is not evidence of dead routes")

        // ── Clause (g) is REACHABLE, and this is the case that reaches it.
        //
        // `unspecifiedGateway` is returned at step 3, BEFORE the interface
        // lookup, so the row's link need not exist — and `en9` is absent from
        // the snapshot. While rung 2 read `staleDefaultNetifs.first` unfiltered
        // it answered `en9`, which meant (i) the install could never land, and
        // (ii) clause (g) saw an `installDefaultRoute` and therefore did NOT
        // withhold the `en9` deletion: a privileged delete with a provably
        // unsatisfiable replacement. Rung 2 now filters its offer, so this plan
        // reaches rung 5, records the genuine ambiguity between the two live
        // links, and (g) withholds the deletion — nothing is deleted and nothing
        // is installed, which is the correct answer to "which of these two
        // networks should carry your traffic?".
        let header = "Destination        Gateway            Flags               Netif Expire"
        let twoLinks = [oneAddress("lo0", "127.0.0.1", 8, loopback: true),
                        oneAddress("en0", "192.168.1.42", 24),
                        oneAddress("en1", "192.168.2.42", 24)]
        p = NetReconcile.plan(routeTable: header + "\ndefault 0.0.0.0 UGScg en9",
                              interfaces: twoLinks, configdKeys: [], netstate: nil,
                              attribution: nil)
        H.eqList(p.actions, [],
                 "rung 2 no longer offers the ABSENT en9, so nothing is deleted either")
        H.eqList(p.kept, [.ambiguousInstallTarget(["en0", "en1"]),
                          .defaultDeletionsWithheld(netifs: ["en9"])],
                 "rung 5 records the ambiguity and clause (g) withholds the en9 deletion")
        H.eq(p.abort, nil, "the snapshot is usable, so nothing aborts")

        // The netstate hint outranks rung 2 — but only when it names a link the
        // snapshot can actually use.
        p = NetReconcile.plan(routeTable: header + "\ndefault 0.0.0.0 UGScg en9",
                              interfaces: twoLinks, configdKeys: [],
                              netstate: Suite04Derivation.netstate(interface: "en1",
                                                                   subnet: "192.168.2.0/24",
                                                                   advisory: "192.168.2.1"),
                              attribution: nil)
        H.eqList(p.actions,
                 [.deleteStalePhysicalDefaultRoute(netif: "en9", ifscoped: false,
                                                   reason: .unspecifiedGateway),
                  .installDefaultRoute(interface: "en1")],
                 "rung 1: a netstate naming a usable candidate wins")
        H.eq(p.installCandidateNote, "routeTable none; netstateAdvisory 192.168.2.1",
             "and the note records what apply time will be compared against")
    }
}
