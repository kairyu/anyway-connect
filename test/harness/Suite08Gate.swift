import Foundation

// Suite 8 — `NetReconcile.gate` (NetReconcile.swift:410-413).
//
// The single safety-critical gate in the whole operation: a reconcile must never
// run while a tunnel of ours is alive. Pure, so it is testable with literals —
// no live tunnel, no installed daemon, which is the only way this could be
// tested at all on the machine it was written on.
//
// A frozen-but-alive openconnect counts as alive, and that is correct:
// dismantling the routing of a tunnel that may still recover is the one thing
// this operation must never do.

enum Suite08Gate {

    static func run() {
        H.suite("Suite 8 — gate(pids:isAlive:)")

        let allDead: (Int32) -> Bool = { _ in false }
        let allAlive: (Int32) -> Bool = { _ in true }

        H.eq(NetReconcile.gate(pids: [], isAlive: allDead), .proceed,
             "no pids: proceed")
        H.eq(NetReconcile.gate(pids: [], isAlive: allAlive), .proceed,
             "no pids: proceed whatever isAlive would have said")
        H.eq(NetReconcile.gate(pids: [111, 222], isAlive: allDead), .proceed,
             "every pid dead: proceed")

        H.eq(NetReconcile.gate(pids: [111, 222], isAlive: { $0 == 222 }),
             .noop(alivePID: 222),
             "one alive: noop, naming it")
        H.eq(NetReconcile.gate(pids: [111, 222], isAlive: allAlive),
             .noop(alivePID: 111),
             "several alive: noop names the FIRST alive pid in the given order")
        H.eq(NetReconcile.gate(pids: [222, 111], isAlive: allAlive),
             .noop(alivePID: 222),
             "`first` is list order, not numeric order")

        // The `[0]` case. `gate` has no floor of its own — it asks `isAlive`
        // about whatever it is given — so pid 0 reaching it produces a noop,
        // i.e. "something is alive, do nothing". That is the SAFE direction, and
        // it is why the floor belongs at the input: `kill(0, 0)` succeeds for the
        // caller's own process group, so a 0 that got this far would stop every
        // reconcile rather than cause a wrong one.
        H.eq(NetReconcile.gate(pids: [0], isAlive: { $0 > 1 }), .proceed,
             "pid 0 with a > 1 floor in isAlive: proceed")
        H.eq(NetReconcile.gate(pids: [0], isAlive: allAlive), .noop(alivePID: 0),
             "pid 0 that isAlive accepts: noop — the safe direction")
        H.eq(NetReconcile.gate(pids: [-1], isAlive: allAlive), .noop(alivePID: -1),
             "and gate applies no sign check of its own either")

        // isAlive is consulted per pid, in order, and short-circuits on the
        // first alive one — `first(where:)`. Asserted because the daemon's real
        // `isAlive` is a syscall per pid.
        var asked: [Int32] = []
        _ = NetReconcile.gate(pids: [1, 2, 3, 4]) { pid in
            asked.append(pid)
            return pid == 2
        }
        H.eqList(asked, [1, 2], "isAlive is asked in order and stops at the first alive pid")
    }
}
