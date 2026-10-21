import Foundation

// Suite 13 — clause (f)'s install-target ladder.
//
// WHAT THIS SUITE IS FOR. Rungs 2 and 3 of the ladder read the two netif lists
// clause (b) builds, and clause (b) records links it has itself judged UNUSABLE:
// a link that is absent from the snapshot, a link that is down, a link with no
// IPv4. Taking `.first` of either list therefore selected, on the dual-homed
// transcript, the very interface recorded one branch earlier as
// `physicalDefaultUnusable(netif: "en0", why: "target not addressed")` — and
// rung 4, which would have chosen a healthy `en8`, was never reached. Apply time
// refused every candidate for a missing target, so nothing was installed: safe,
// and the repair silently did not happen.
//
// Rung 2's version was worse than rung 3's, because rung 2's interfaces arrive
// with a deletion attached: with `en9` chosen, clause (g) saw an
// `installDefaultRoute` and did NOT withhold the `en9` deletion, so the prologue
// removed a default row whose replacement provably could not be installed.
//
// Two assertions carry the weight:
//
//   * case 2 runs a BYTE-IDENTICAL route table against two snapshots that differ
//     only in the order of the same two links, and expects two different
//     answers. That is a test that cannot be written against netstat print
//     order, which is what the old `.first` was reading, and it is what makes
//     "prefer the link the kernel lists first" a rule rather than an accident.
//   * case 8 re-asserts `carried-home` and `vpn-up` unchanged. On those fixtures
//     `staleDefaultNetifs` is `["en0"]` and `en0` is usable, so `.first` and
//     `preferredInstallTarget` necessarily agree — if either moves, the filter
//     has changed something it was not supposed to touch.
enum Suite13InstallTarget {
    private static func check(_ fixture: String,
                              interfaces interfacesName: String? = nil,
                              configdKeys: [String] = [],
                              netstate: NetState? = nil,
                              label: String,
                              actions: [ReconcileAction],
                              kept: [ReconcileKept],
                              note: String? = nil) {
        let plan = NetReconcile.plan(
            routeTable: Fixtures.routeTable(fixture),
            interfaces: Fixtures.interfaces(interfacesName ?? fixture),
            configdKeys: configdKeys,
            netstate: netstate,
            attribution: nil)
        H.eqList(plan.actions, actions, "\(label): actions")
        H.eqList(plan.kept, kept, "\(label): kept")
        H.eq(plan.abort, nil, "\(label): nothing aborts")
        H.eq(plan.installCandidateNote, note, "\(label): installCandidateNote")
        // Stated separately from the action list because it is the property
        // defect 3 turns on: choosing an unusable target is only "safe" as long
        // as nothing was deleted on the way to it.
        H.eq(plan.actions.filter {
            if case .deleteStalePhysicalDefaultRoute = $0 { return true } else { return false }
        }.count,
             actions.filter {
                 if case .deleteStalePhysicalDefaultRoute = $0 { return true } else { return false }
             }.count,
             "\(label): the number of physical default deletions")
    }

    /// `dual-default`'s sweep and clause-(c) kept records are IDENTICAL under all
    /// four of its snapshots — the two stale host routes are off-link for every
    /// link in every one of them — which is what lets the four cases share one
    /// pair of committed expected files. The runner re-derives all four and
    /// diffs them, so the identity is checked rather than asserted here.
    private static let dualSweep = Suite05Plan.sweepFromFixture("dual-default")
    private static let dualKept = Suite05Plan.keptFromFixture("dual-default")

    static func run() {
        H.suite("Suite 13 — the install-target ladder")

        // ── case 1: both links usable, both defaults `-ifscope`-only. Neither
        // row serves unbound traffic, so (f) must install the unscoped form, and
        // the snapshot lists en0 first.
        check("dual-default", label: "dual-default (en0 first)",
              actions: dualSweep + [.installDefaultRoute(interface: "en0")],
              kept: [.physicalDefaultUnusable(netif: "en0", why: "ifscope-only"),
                     .physicalDefaultUnusable(netif: "en8", why: "ifscope-only")]
                  + dualKept,
              note: "routeTable 10.0.1.1; netstateAdvisory none")

        // ── case 2: THE SAME TABLE, the same two links, the other snapshot
        // order. A planner reading netstat print order answers en0 here and
        // fails. Note that `kept` is unchanged: clause (b) records in ROW order,
        // which is the table's, while the ladder prefers in SNAPSHOT order.
        check("dual-default", interfaces: "dual-default.reversed",
              label: "dual-default (en8 first — the preference is a RULE)",
              actions: dualSweep + [.installDefaultRoute(interface: "en8")],
              kept: [.physicalDefaultUnusable(netif: "en0", why: "ifscope-only"),
                     .physicalDefaultUnusable(netif: "en8", why: "ifscope-only")]
                  + dualKept,
              note: "routeTable 192.168.1.1; netstateAdvisory none")

        // ── case 3: DEFECT 3'S PRIMARY CASE, and the measured dual-homed
        // transcript. en0 is absent from the snapshot while its route rows
        // persist; rung 3 used to offer `en0` and the install was refused at
        // apply time with `targetInterfaceMissing`.
        check("dual-default", interfaces: "dual-default.en0-absent",
              label: "dual-default (en0 absent from the snapshot)",
              actions: dualSweep + [.installDefaultRoute(interface: "en8")],
              kept: [.physicalDefaultUnusable(netif: "en0", why: "target not addressed"),
                     .physicalDefaultUnusable(netif: "en8", why: "ifscope-only")]
                  + dualKept,
              note: "routeTable 192.168.1.1; netstateAdvisory none")

        // ── case 4: the same trap with the link merely DOWN, which is the arm
        // of clause (b) a real unplugged cable lands in.
        check("dual-default", interfaces: "dual-default.en0-down",
              label: "dual-default (en0 present but down)",
              actions: dualSweep + [.installDefaultRoute(interface: "en8")],
              kept: [.physicalDefaultUnusable(netif: "en0", why: "link down"),
                     .physicalDefaultUnusable(netif: "en8", why: "ifscope-only")]
                  + dualKept,
              note: "routeTable 192.168.1.1; netstateAdvisory none")

        // ── case 5: both pre-lookup rejection reasons in one table, which is
        // where the comment this change corrected was wrong. `0.0.0.0` on en9 is
        // `unspecifiedGateway` (step 3) and `link#7` on en7 is `malformedGateway`
        // (step 2); both are returned BEFORE the interface lookup, so neither
        // link has to exist — and neither does.
        //
        // THE ANSWER MOVED when clause (f) gained its postcondition precondition,
        // and this is the one existing expectation that moved with it. The `en7`
        // row is UNSCOPED and is KEPT ("no IPv4 next hop"), so after `en9`'s
        // deletion the kernel would still answer `default` with it and
        // `route -n add default 192.168.1.1` could only return EEXIST. The
        // install is therefore withheld rather than emitted and reported as done,
        // and clause (g) then withholds `en9`'s deletion too, because its
        // replacement is not being installed. Nothing is deleted, nothing is
        // installed, and both decisions are recorded — which is the honest answer
        // to a table holding two unscoped defaults, a shape the fixture is
        // synthetic precisely because a real kernel does not hold it.
        //
        // The ladder itself is unchanged and still answers `en8` when it is
        // asked, which case 9 below asserts directly from literals.
        check("unspecified-default", label: "unspecified-default",
              actions: [],
              kept: [.physicalDefaultUnusable(netif: "en7", why: "no IPv4 next hop"),
                     .physicalDefaultUnusable(netif: "en8", why: "ifscope-only")]
                  + Suite05Plan.keptFromFixture("unspecified-default")
                  + [.installWithheldForSurvivingDefault(netif: "en7"),
                     .defaultDeletionsWithheld(netifs: ["en9"])])

        // ── case 7: rungs 4 and 5 are untouched by this change, so the
        // dual-homed state with NO default row at all still refuses to guess.
        check("two-physical", label: "two-physical (rungs 4-5 unchanged)",
              actions: [],
              kept: Suite05Plan.keptFromFixture("two-physical")
                  + [.ambiguousInstallTarget(["en0", "en1"])])

        // ── case 8: the two large fixtures, unchanged. `staleDefaultNetifs` is
        // `["en0"]` on both and en0 is usable, so the filter cannot move either
        // answer — and the full ordered 236-entry deletion list is asserted
        // again here, against the independently derived file, because it is the
        // one list a mistake in the ladder could plausibly disturb.
        let home = NetReconcile.plan(routeTable: Fixtures.routeTable("carried-home"),
                                     interfaces: Fixtures.interfaces("carried-home"),
                                     configdKeys: [], netstate: nil, attribution: nil)
        H.ok(home.actions.contains(.installDefaultRoute(interface: "en0")),
             "carried-home still installs en0")
        H.eqList(NetReconcile.commands(for: home).sweep.map(argvLine),
                 Fixtures.expected("carried-home.sweep.txt"),
                 "carried-home's 236 deletions are element-for-element unchanged")
        // vpn-up's install needs the witness now: with its utun7 live and
        // unattributed, the unscoped default it holds is the kernel's answer for
        // `default` and the install is withheld. Under `.deadPlus` the tunnel
        // default is deleted first, so the slot is free and the LADDER's answer
        // — en0, the only usable physical link — is unchanged, which is what this
        // case is here to re-assert.
        let office = NetReconcile.plan(routeTable: Fixtures.routeTable("vpn-up"),
                                       interfaces: Fixtures.interfaces("vpn-up"),
                                       configdKeys: Fixtures.scutilKeys("vpn-up"),
                                       netstate: nil,
                                       attribution: Suite11Attribution.attr(
                                           ourTunnel: "utun7",
                                           ourTunnelIPv4: "192.168.204.16"))
        H.ok(office.actions.contains(.installDefaultRoute(interface: "en0")),
             "vpn-up still installs en0")
        H.eqList(NetReconcile.commands(for: office).sweep.map(argvLine), [],
                 "vpn-up still sweeps nothing")

        // ── case 9: `preferredInstallTarget` in isolation, from literals. The
        // function is internal rather than private exactly so this block can
        // exist; `plan` is its only production caller.
        let forward = [oneAddress("lo0", "127.0.0.1", 8, loopback: true),
                       oneAddress("en0", "10.0.1.42", 24),
                       oneAddress("en8", "192.168.1.42", 24)]
        let reverse = [forward[0], forward[2], forward[1]]
        H.eq(NetReconcile.preferredInstallTarget(offered: ["en8", "en0"],
                                                 interfaces: forward), "en0",
             "the OFFERED order does not decide: the snapshot does")
        H.eq(NetReconcile.preferredInstallTarget(offered: ["en8", "en0"],
                                                 interfaces: reverse), "en8",
             "the same offered list against the reversed snapshot")
        H.eq(NetReconcile.preferredInstallTarget(
                offered: ["en0"],
                interfaces: [forward[0], oneAddress("en0", "10.0.1.42", 24, up: false)]),
             nil, "a link that is down is never a target")
        H.eq(NetReconcile.preferredInstallTarget(offered: ["en0"],
                                                 interfaces: [forward[0]]),
             nil, "nor a link absent from the snapshot")
        H.eq(NetReconcile.preferredInstallTarget(offered: [], interfaces: forward),
             nil, "an empty offer yields nothing rather than the first usable link")
        H.eq(NetReconcile.preferredInstallTarget(offered: ["lo0"], interfaces: forward),
             nil, "nor lo0 — `evaluateDefaultGateway` never tests isLoopback, so a "
                + "`default … lo0` row would otherwise be offered")
        H.eq(NetReconcile.preferredInstallTarget(
                offered: ["utun7"],
                interfaces: [forward[0], oneAddress("utun7", "192.168.204.16", 32, p2p: true)]),
             nil, "nor a live tunnel")
        H.eq(NetReconcile.preferredInstallTarget(offered: ["en0"],
                                                 interfaces: [forward[0], noAddress("en0")]),
             nil, "nor a link mid-DHCP with no IPv4")
    }
}
