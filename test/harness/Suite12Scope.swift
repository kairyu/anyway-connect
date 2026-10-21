import Foundation

// Suite 12 — the planner under each tunnel scope, against fixtures.
//
// Every case asserts the FULL ORDERED action list and the exact `kept` multiset,
// never a list of absences: "no action names utun9" is only worth something if
// the actions that ARE emitted are pinned at the same time.
//
// THE CASE THE WHOLE CHANGE EXISTS FOR is case 11. Three tunnels are live, one
// of them is ours and witnessed, and the other two are protected — with no list,
// no observation window and no record of them of any kind. The tunnel that
// motivated the previous iteration's positive-attribution ceiling (a third-party
// VPN brought up AFTER our connect, which no connect-time snapshot could
// contain) is protected here by being UP.
//
// Case 12 is its price, stated rather than discovered: the same three tunnels
// with no identity claim produce NO actions at all. Case 16 is the reported
// incident, repaired with no record at all, and the 118/236 list unchanged.
//
// `kept` ordering is part of each expectation: the scope's records first (the
// `.liveTunnelIdentityUnproven` note, then `.foreignTunnel` for every seen
// tunnel not in scope, sorted), then clause (b) in ROW order, then clause (c) in
// row order, then (f)'s withholding or ambiguity record and (g)'s.
//
// Duplicate `.foreignTunnel` records are PRE-EXISTING and unchanged: clause (b)
// appends one for an out-of-scope tunnel's default row, so a foreign tunnel with
// a default row is recorded twice — once by the scope, once by the row. Noted so
// the exact-multiset assertions below are not read as a defect.

enum Suite12Scope {

    private static func check(_ fixture: String,
                              interfaces interfacesName: String? = nil,
                              configdKeys: [String] = [],
                              netstate: NetState? = nil,
                              attribution: TunnelAttribution?,
                              label: String,
                              actions: [ReconcileAction],
                              abort: ReconcileAbort? = nil,
                              kept: [ReconcileKept],
                              note: String? = nil) -> ReconcilePlan {
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
        return plan
    }

    /// "No action anywhere in this plan mentions `name`" — the discrimination
    /// assertion, made over the rendered action rather than over a hand-listed
    /// set of shapes, so a NEW kind of action naming a protected tunnel would
    /// fail it too.
    private static func noActionNames(_ plan: ReconcilePlan, _ name: String,
                                      _ what: String) {
        let offenders = plan.actions.map { String(describing: $0) }
            .filter { $0.contains(name) }
        H.eqList(offenders, [], what)
    }

    static func run() {
        H.suite("Suite 12 — the planner under each tunnel scope")

        let witnessedUtun7 = Suite11Attribution.attr(ourTunnel: "utun7",
                                                     ourTunnelIPv4: "192.168.204.16")
        let lateKeys = Fixtures.scutilKeys("late-tunnel")

        // ── case 11: THE DISCRIMINATION TEST. utun0, utun7 and utun9 are all
        // live, each with a default row and a pair of configd keys. utun7 is ours
        // and witnessed; the other two are somebody else's and the planner has
        // never heard of them.
        let late = check("late-tunnel", configdKeys: lateKeys,
                         attribution: witnessedUtun7,
                         label: "case 11 late-tunnel under .deadPlus(utun7)",
                         actions: [.removeConfigdKey("State:/Network/Service/utun7/IPv4"),
                                   .removeConfigdKey("State:/Network/Service/utun7/DNS"),
                                   .deleteTunnelDefaultRoute(netif: "utun7", ifscoped: false),
                                   .installDefaultRoute(interface: "en0")],
                         kept: [.foreignTunnel("utun0"), .foreignTunnel("utun9"),
                                .foreignTunnel("utun0"), .foreignTunnel("utun9")]
                             + Suite05Plan.keptFromFixture("late-tunnel"),
                         note: "routeTable none; netstateAdvisory none")
        noActionNames(late, "utun9",
                      "case 11 NO action names utun9 — not its default route, not either key")
        noActionNames(late, "utun0", "case 11 nor utun0")

        // ── case 12: the same fixtures with no identity claim. All three are
        // live, so NOTHING is in scope and the plan is empty — the fail-closed
        // cost pinned on the fixture where it bites hardest. The install is
        // withheld as well, because utun7's unscoped default survives and
        // `route add default` could then only return EEXIST.
        check("late-tunnel", configdKeys: lateKeys, attribution: nil,
              label: "case 12 late-tunnel under .deadOnly",
              actions: [],
              kept: [.foreignTunnel("utun0"), .foreignTunnel("utun7"),
                     .foreignTunnel("utun9"),
                     .foreignTunnel("utun7"), .foreignTunnel("utun0"),
                     .foreignTunnel("utun9")]
                  + Suite05Plan.keptFromFixture("late-tunnel")
                  + [.installWithheldForSurvivingDefault(netif: "utun7")])

        // ── case 13: CLAUSE (f) RE-GATED, on the shape the live machine is
        // actually in — an unscoped default on utun7 beside a scoped en0 default.
        // With utun7 protected, no deletion frees the unscoped slot, so the
        // install is withheld AND SAID to be withheld, rather than emitted and
        // then reported as done by an apply that discards `route`'s EEXIST.
        //
        // No `.defaultDeletionsWithheld`: there is no stale physical default in
        // this table for (g) to withhold.
        check("live-shape", attribution: nil,
              label: "case 13 live-shape under .deadOnly",
              actions: [],
              kept: [.foreignTunnel("utun7"),
                     .foreignTunnel("utun7"),
                     .physicalDefaultUnusable(netif: "en0", why: "ifscope-only")]
                  + Suite05Plan.keptFromFixture("live-shape")
                  + [.installWithheldForSurvivingDefault(netif: "utun7")])

        // ── case 14: 13 plus clause (g)'s composition, which the re-gating is
        // the only thing that changes — so it is asserted rather than reasoned
        // about. A stale physical default on en8 via a dead gateway is now
        // withheld too: (g) keys on the presence of an install, and there is
        // none. Nothing is deleted, nothing is installed, and both decisions are
        // recorded.
        check("live-shape.stale-en8", attribution: nil,
              label: "case 14 live-shape.stale-en8 under .deadOnly",
              actions: [],
              kept: [.foreignTunnel("utun7"),
                     .foreignTunnel("utun7"),
                     .physicalDefaultUnusable(netif: "en0", why: "ifscope-only")]
                  + Suite05Plan.keptFromFixture("live-shape.stale-en8")
                  + [.installWithheldForSurvivingDefault(netif: "utun7"),
                     .defaultDeletionsWithheld(netifs: ["en8"])])

        // ── case 15: `lingering-utun` under both witness outcomes — the fixture
        // the capability exists for, one field apart. Its `utun7` carries
        // 192.168.204.16 (read, not assumed), and `scutil-keys.two-tunnels.txt`
        // is named explicitly because no `scutil-keys.lingering-utun.txt`
        // exists; its `utun0` keys name a tunnel that is in neither the table nor
        // the snapshot, so `utun0` is DEAD and its keys are removed under both
        // outcomes. That is the dead-tunnel rule doing its job beside the witness
        // rule, in one plan.
        let twoTunnelKeys = Fixtures.scutilKeys("two-tunnels")
        check("lingering-utun", configdKeys: twoTunnelKeys, attribution: witnessedUtun7,
              label: "case 15a lingering-utun, witness MATCHES",
              actions: [.removeConfigdKey("State:/Network/Service/utun0/IPv4"),
                        .removeConfigdKey("State:/Network/Service/utun0/DNS"),
                        .removeConfigdKey("State:/Network/Service/utun7/IPv4"),
                        .removeConfigdKey("State:/Network/Service/utun7/DNS"),
                        .deleteTunnelDefaultRoute(netif: "utun7", ifscoped: true)]
                  + Suite05Plan.sweepFromFixture("lingering-utun"),
              kept: [.physicalDefaultUsable(netif: "en0")]
                  + Suite05Plan.keptFromFixture("lingering-utun"))

        check("lingering-utun", configdKeys: twoTunnelKeys,
              attribution: Suite11Attribution.attr(ourTunnel: "utun7",
                                                   ourTunnelIPv4: "10.8.0.3"),
              label: "case 15b the SAME fixture, witness DIFFERS",
              actions: [.removeConfigdKey("State:/Network/Service/utun0/IPv4"),
                        .removeConfigdKey("State:/Network/Service/utun0/DNS")]
                  + Suite05Plan.sweepFromFixture("lingering-utun"),
              kept: [.liveTunnelIdentityUnproven(
                         IdentityUnproven(netif: "utun7",
                                          recordedAddress: "10.8.0.3",
                                          liveAddress: "192.168.204.16")),
                     .foreignTunnel("utun7"),
                     .physicalDefaultUsable(netif: "en0"),
                     .foreignTunnel("utun7")]
                  + Suite05Plan.keptFromFixture("lingering-utun"))

        // ── case 16: THE REPORTED INCIDENT, repaired with NO record at all.
        // `utun7` has a default row and is absent from the snapshot, so it is
        // dead under every scope, and the full 118/236 sweep list is unchanged —
        // asserted against the independently derived file, element for element.
        let home = check("carried-home", attribution: nil,
                         label: "case 16 carried-home under .deadOnly",
                         actions: [.deleteTunnelDefaultRoute(netif: "utun7",
                                                             ifscoped: false),
                                   .deleteStalePhysicalDefaultRoute(
                                       netif: "en0", ifscoped: true,
                                       reason: .gatewayOffLink)]
                             + Suite05Plan.sweepFromFixture("carried-home")
                             + [.installDefaultRoute(interface: "en0")],
                         kept: [.foreignTunnel("gif0"), .foreignTunnel("stf0"),
                                .foreignTunnel("utun0"), .foreignTunnel("utun1"),
                                .foreignTunnel("utun2")]
                             + Suite05Plan.keptFromFixture("carried-home"),
                         note: "routeTable 10.0.1.1; netstateAdvisory none")
        H.eqList(NetReconcile.commands(for: home).sweep.map(argvLine),
                 Fixtures.expected("carried-home.sweep.txt"),
                 "case 16 and the 236 deletions are element-for-element unchanged")

        // ── case 17: `.none` via an unusable snapshot. The plan aborts at (d″)
        // as it did before — and, the decided part, emits NO configd removals
        // either. Reversing that decision shows up here as a test change.
        check("carried-home", interfaces: "lo0-only",
              configdKeys: Fixtures.scutilKeys("vpn-up"),
              attribution: witnessedUtun7,
              label: "case 17 carried-home against lo0 alone",
              actions: [],
              abort: .interfaceSnapshotUnusable,
              kept: [.foreignTunnel("utun7")])

        // ── case 18: the everyday fixture under both answers. Under
        // `.deadPlus` this is today's plan, byte for byte; under `.deadOnly` the
        // live utun7 is skipped entirely and the install is withheld because its
        // unscoped default survives.
        check("vpn-up", configdKeys: Fixtures.scutilKeys("vpn-up"),
              attribution: witnessedUtun7,
              label: "case 18a vpn-up under .deadPlus(utun7)",
              actions: [.removeConfigdKey("State:/Network/Service/utun7/IPv4"),
                        .removeConfigdKey("State:/Network/Service/utun7/DNS"),
                        .deleteTunnelDefaultRoute(netif: "utun7", ifscoped: false),
                        .installDefaultRoute(interface: "en0")],
              kept: [.foreignTunnel("gif0"), .foreignTunnel("stf0"),
                     .foreignTunnel("utun0"), .foreignTunnel("utun1"),
                     .foreignTunnel("utun2"), .foreignTunnel("utun3"),
                     .foreignTunnel("utun4"), .foreignTunnel("utun5"),
                     .foreignTunnel("utun6"),
                     .physicalDefaultUnusable(netif: "en0", why: "ifscope-only")]
                  + Suite05Plan.keptFromFixture("vpn-up"),
              note: "routeTable 10.0.1.1; netstateAdvisory none")

        check("vpn-up", configdKeys: Fixtures.scutilKeys("vpn-up"), attribution: nil,
              label: "case 18b vpn-up under .deadOnly",
              actions: [],
              kept: [.foreignTunnel("gif0"), .foreignTunnel("stf0"),
                     .foreignTunnel("utun0"), .foreignTunnel("utun1"),
                     .foreignTunnel("utun2"), .foreignTunnel("utun3"),
                     .foreignTunnel("utun4"), .foreignTunnel("utun5"),
                     .foreignTunnel("utun6"), .foreignTunnel("utun7"),
                     .foreignTunnel("utun7"),
                     .physicalDefaultUnusable(netif: "en0", why: "ifscope-only")]
                  + Suite05Plan.keptFromFixture("vpn-up")
                  + [.installWithheldForSurvivingDefault(netif: "utun7")])

        // ── finding 8's case: `dropRevivedTunnelActions`. "Absent from a usable
        // snapshot ⇒ provably dead" is decided against the CLASSIFICATION
        // snapshot, and the deletes it authorises run after the prologue — so a
        // third-party client coming up inside that window would have its resolver
        // keys removed on the strength of a snapshot that is no longer true.
        let planned = ReconcilePlan(
            actions: [.removeConfigdKey("State:/Network/Service/utun9/IPv4"),
                      .removeConfigdKey("State:/Network/Service/utun9/DNS"),
                      .removeConfigdKey("State:/Network/Service/utun7/DNS"),
                      .deleteTunnelDefaultRoute(netif: "utun9", ifscoped: false),
                      .deleteTunnelDefaultRoute(netif: "utun7", ifscoped: true),
                      .deleteStalePhysicalDefaultRoute(netif: "en0", ifscoped: true,
                                                       reason: .gatewayOffLink),
                      .deleteRoute(RouteDeletion(destination: "100.64.5.10",
                                                 netmask: nil, ifscope: nil)),
                      .installDefaultRoute(interface: "en0")],
            kept: [.foreignTunnel("utun0")],
            abort: nil,
            installCandidateNote: "routeTable 10.0.1.1; netstateAdvisory none")

        // `utun9`'s dropped default is the UNSCOPED one, so the install clause (f)
        // emitted on the strength of that deletion goes with it: the composition of
        // finding 8's drop with finding 6's withholding, which is the seam between
        // the two and the one case neither finding states on its own.
        let revived = NetReconcile.dropRevivedTunnelActions(planned, present: ["en0", "utun9"])
        H.eqList(revived.plan.actions,
                 [.removeConfigdKey("State:/Network/Service/utun7/DNS"),
                  .deleteTunnelDefaultRoute(netif: "utun7", ifscoped: true),
                  .deleteStalePhysicalDefaultRoute(netif: "en0", ifscoped: true,
                                                   reason: .gatewayOffLink),
                  .deleteRoute(RouteDeletion(destination: "100.64.5.10",
                                             netmask: nil, ifscope: nil))],
                 "finding 8: a utun that REAPPEARED loses its keys and its default route")
        H.eq(revived.dropped.count, 4, "finding 8: three drops, plus the install they invalidate")
        H.ok(revived.dropped.allSatisfy { $0.contains("utun9") },
             "finding 8: and each names the tunnel that came back")
        H.eqList(revived.plan.kept,
                 planned.kept + [.installWithheldForSurvivingDefault(netif: "utun9")],
                 "the seam: the withholding is RECORDED, under (f)'s own case")
        H.eq(revived.plan.installCandidateNote, nil,
             "and the install note is cleared with it — nil when no install is emitted")
        H.ok(revived.dropped.contains { $0.contains("installDefaultRoute withheld") },
             "and the reason is logged, not inferred from a shorter action list")

        // The mirror: the same revival, but the surviving default is `-ifscope`d.
        // `route delete default -ifscope utun9` leaves `default` itself alone, so the
        // slot the install needs is free and the install must STAND. Without this
        // row, "drop the install whenever a tunnel came back" would pass too.
        let scopedOnly = ReconcilePlan(
            actions: [.deleteTunnelDefaultRoute(netif: "utun9", ifscoped: true),
                      .installDefaultRoute(interface: "en0")],
            kept: [], abort: nil,
            installCandidateNote: "routeTable 10.0.1.1; netstateAdvisory none")
        let scopedRevived = NetReconcile.dropRevivedTunnelActions(scopedOnly, present: ["en0", "utun9"])
        H.eqList(scopedRevived.plan.actions, [.installDefaultRoute(interface: "en0")],
                 "a SCOPED drop does not occupy the default slot, so the install stands")
        H.eqList(scopedRevived.plan.kept, [],
                 "and nothing is withheld, so nothing is recorded")
        H.eq(scopedRevived.plan.installCandidateNote, scopedOnly.installCandidateNote,
             "and the install note survives with the install it describes")

        let unchanged = NetReconcile.dropRevivedTunnelActions(planned, present: ["en0"])
        H.eqList(unchanged.plan.actions, planned.actions,
                 "finding 8: the ordinary case — nothing came back, nothing is dropped")
        H.eqList(unchanged.dropped, [], "finding 8: and nothing is logged")
        H.eqList(unchanged.plan.kept, planned.kept, "finding 8: `kept` is untouched")
        H.eq(unchanged.plan.installCandidateNote, planned.installCandidateNote,
             "finding 8: and so is the install note")
    }
}
