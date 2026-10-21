import Foundation

// Suite 6 — the sweep list, in full and in order.
//
// THIS IS THE SUITE THE VERIFICATION RECORD RESTS ON. The chain is:
//
//   derive-expected.sh  ≡  expected/<fixture>.sweep.txt   (diffed by the runner,
//                                                          before compiling)
//   expected/<fixture>.sweep.txt  ≡  commands(for: plan).sweep   (asserted here)
//
// so the planner's output and an independent re-derivation from the fixture text
// are pinned to each other ELEMENT FOR ELEMENT. A planner change that moves the
// list fails here; a hand-edited expected file fails the runner's diff; a
// derivation that drifts fails both.
//
// The comparison is against the full /sbin/route argv rather than against
// `RouteDeletion`, so the ARGUMENT SHAPE is pinned too: §4.2's `inet_aton`
// reasoning lives entirely in the argument shape, and a sweep that emitted
// `-net 3.7.35` instead of `-net 3.7.35.0 -netmask 255.255.255.0` would delete a
// route that was never in the table while leaving the real one in place.

enum Suite06Sweep {

    private static func sweepArgv(_ fixture: String, interfaces: String? = nil,
                                  configdKeys: [String] = []) -> [String] {
        let plan = NetReconcile.plan(routeTable: Fixtures.routeTable(fixture),
                                     interfaces: Fixtures.interfaces(interfaces ?? fixture),
                                     configdKeys: configdKeys,
                                     netstate: nil)
        return NetReconcile.commands(for: plan).sweep.map(argvLine)
    }

    static func run() {
        H.suite("Suite 6 — the full ordered sweep list")

        // ── carried-home: the reported incident, 118 distinct swept
        // destinations and 2N = 236 deletions.
        let home = Fixtures.expected("carried-home.sweep.txt")
        H.eq(home.count, 236, "the independently derived list is 236 entries")
        H.eq(home.filter { !$0.contains(" -ifscope ") }.count, 118,
             "of which 118 are the unscoped deletions, i.e. N = 118 distinct destinations")
        H.eq(home.filter { $0.contains(" -ifscope ") }.count, 118,
             "and 118 are scoped — so every swept destination is on exactly ONE netif")
        H.eq(Set(home).count, 236, "with no duplicate action")
        H.eqList(sweepArgv("carried-home"), home,
                 "carried-home: the planner's sweep matches it element for element")

        // ── vpn-up: the SAME table on the office LAN, where nothing is swept.
        // Every gateway in it is reachable, so the correct list is EMPTY — this
        // is the discrimination test for the whole classifier, not a vacuous
        // case. If the sweep ever produces an entry here it is deleting a route
        // that works.
        H.eq(Fixtures.expected("vpn-up.sweep.txt").count, 0,
             "vpn-up's independently derived list is empty")
        H.eqList(sweepArgv("vpn-up", configdKeys: Fixtures.scutilKeys("vpn-up")),
                 [], "vpn-up: the planner sweeps nothing")

        // ── lingering-utun: the kept case and the swept case of the same shape.
        // The two routes via utun7's LIVE address are kept; the two via the
        // vanished utun8 address are swept, each emitting the unscoped deletion
        // followed by the `-ifscope utun8` one.
        H.eqList(sweepArgv("lingering-utun"),
                 Fixtures.expected("lingering-utun.sweep.txt"),
                 "lingering-utun: 2 destinations, 4 deletions, in first-seen order")

        // ── Every other committed fixture sweeps nothing, and that is asserted
        // rather than assumed.
        for fixture in ["clean", "link-down", "no-default", "two-physical", "two-tunnels"] {
            H.eqList(sweepArgv(fixture), Fixtures.expected("\(fixture).sweep.txt"),
                     "\(fixture): sweep matches the derivation")
        }
        H.eqList(sweepArgv("cap-exceeded", interfaces: "clean"),
                 Fixtures.expected("cap-exceeded.sweep.txt"),
                 "cap-exceeded: the SWEEP aborts, so the list is empty rather than truncated")

        // ── The first and last entries spelled out, so a reader can check the
        // ordering rule against the fixture by eye: distinct (destination,
        // netmask) pairs in FIRST-SEEN row order, each emitting one unscoped
        // deletion followed by one `-ifscope` deletion per distinct netif.
        H.eq(home.first, "-n delete -host 10.0.1.51",
             "the first swept destination is the first eligible row of the table")
        H.eq(home[1], "-n delete -host 10.0.1.51 -ifscope en0",
             "immediately followed by its scoped twin")
        H.eq(home[2], "-n delete -host 10.0.1.77",
             "then the next destination, not the next netif")
    }
}
