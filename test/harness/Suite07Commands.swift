import Foundation

// Suite 7 — `NetReconcile.commands(for:)` (NetReconcile.swift:891-968).
//
// Formatting the argv is a DECISION, not plumbing, which is why it lives in the
// pure layer: the whole `inet_aton` argument-shape reasoning is here, and so is
// the scoped/unscoped split that rests on platform assumption 1.
//
// The PARTITION is the other half of the contract. `prologue` and `install` are
// essential and run regardless of elapsed time; `sweep` is best-effort under a
// deadline. The install is the one command whose omission turns this operation
// into the very outcome it exists to prevent, so it can never be the thing a
// budget drops — and it is deliberately NOT last, because sweeping first would
// leave the machine with no default route for the whole sweep window.

enum Suite07Commands {

    private static func commands(_ fixture: String, interfaces: String? = nil,
                                 configdKeys: [String] = []) -> ReconcileCommands {
        NetReconcile.commands(for: NetReconcile.plan(
            routeTable: Fixtures.routeTable(fixture),
            interfaces: Fixtures.interfaces(interfaces ?? fixture),
            configdKeys: configdKeys,
            netstate: nil))
    }

    static func run() {
        H.suite("Suite 7 — commands(for:)")

        // ── carried-home: the full partition.
        let home = commands("carried-home")
        H.eqList(home.prologue,
                 [.deleteUnscopedDefaultWhileInterface(netif: "utun7", maxIterations: 8),
                  .route(argv: ["-n", "delete", "default", "-ifscope", "en0"])],
                 "prologue: the UNSCOPED tunnel default and the SCOPED stale physical one")
        H.eqList(home.install, [.deriveAndInstallDefault(interface: "en0")],
                 "install: re-probe, derive, guard, install — daemon-only execution")
        H.eq(home.sweep.count, 236, "sweep: the 236 per-destination deletions")
        H.eqList(home.all, home.prologue + home.install + home.sweep,
                 "APPLY ORDER is prologue, then install, then sweep")
        H.eqList(home.essential, home.prologue + home.install,
                 "essential is prologue + install, never the sweep")
        H.eq(home.isEmpty, false, "and the whole thing is non-empty")

        // ── The scoped/unscoped split, which is the whole reason the plan
        // classifies per ROW. `route -n delete default` names no interface: it
        // deletes whatever the kernel currently answers for the unscoped
        // default, so a blind delete aimed at a SCOPED row could remove the
        // wrong one. A `-ifscope`d row is deleted by name, which is unambiguous;
        // an unscoped row is deleted only while the current default still IS
        // that interface.
        let twoTunnels = commands("two-tunnels",
                                  configdKeys: Fixtures.scutilKeys("two-tunnels"))
        H.eqList(Array(twoTunnels.prologue.dropFirst()),
                 [.deleteUnscopedDefaultWhileInterface(netif: "utun7", maxIterations: 8),
                  .route(argv: ["-n", "delete", "default", "-ifscope", "utun0"])],
                 "utun7's unscoped row is state-dependent; utun0's scoped row is by name")

        // ── ONE batched scutil invocation for every key, with open/remove/close
        // on stdin. Batched rather than one call per key because each `scutil`
        // start-up is a configd session, and platform assumption 3 is that a key
        // that vanished between the read and this batch is not fatal to the rest.
        let batchedKeys: [String] = ["State:/Network/Service/utun0/IPv4",
                                     "State:/Network/Service/utun0/DNS",
                                     "State:/Network/Service/utun7/IPv4",
                                     "State:/Network/Service/utun7/DNS"]
        var batchedStdin = "open\n"
        for key in batchedKeys { batchedStdin += "remove \(key)\n" }
        batchedStdin += "close\n"
        H.eq(twoTunnels.prologue.first,
             ReconcileCommand.scutil(stdin: batchedStdin, keys: batchedKeys),
             "one scutil call, stdin = open / remove each key / close")
        H.eq(twoTunnels.prologue.filter {
                if case .scutil = $0 { return true } else { return false }
             }.count, 1,
             "exactly one, never one per key")
        H.ok(!commands("clean").prologue.contains {
                if case .scutil = $0 { return true } else { return false }
             },
             "and no scutil command at all when there are no keys to remove")

        // ── EXPLICIT netmasks, never netstat's shorthand. `route`'s parser runs
        // the pre-slash text through inet_aton, so `-net 100.68.0/16` would mean
        // `100.68.0.0`... but `-net 3.7.35` would mean `3.7.0.35`, a route that
        // was never in the table. Both forms are checked here.
        let sweep = home.sweep.map(argvLine)
        H.ok(sweep.contains("-n delete -net 100.68.0.0 -netmask 255.255.0.0"),
             "a /16 printed as `100.68.0/16` becomes an explicit address and netmask")
        H.ok(sweep.contains("-n delete -net 100.64.0.0 -netmask 255.255.0.0"),
             "and so does the class-masked `100.64`")
        H.ok(sweep.contains("-n delete -host 10.0.1.51"),
             "a host route is `-host` with no netmask")
        H.ok(!sweep.contains { $0.contains("/") },
             "NO entry carries a slash — netstat's abbreviation never reaches argv")

        // ── The `-ifscope` suffix is last, after the destination and netmask.
        let scoped = sweep.filter { $0.contains(" -ifscope ") }
        H.eq(scoped.count, 118, "118 scoped deletions")
        H.ok(scoped.allSatisfy { $0.hasSuffix(" -ifscope en0") || $0.hasSuffix(" -ifscope utun7") },
             "and every one ends with its -ifscope argument")

        // ── A plan that installs nothing produces an empty `install`, and the
        // `deriveAndInstallDefault` command is the ONLY thing that may appear
        // there.
        let clean = commands("clean")
        H.eqList(clean.install, [], "clean: nothing to install")
        H.eqList(clean.all, [], "clean: no commands at all")
        H.eq(clean.isEmpty, true, "clean: the empty-plan complement")

        // ── An aborted sweep still produces its prologue and install, which is
        // the point of aborting the SWEEP rather than the reconcile.
        let capped = commands("cap-exceeded", interfaces: "clean")
        H.eqList(capped.prologue,
                 [.route(argv: ["-n", "delete", "default", "-ifscope", "en0"])],
                 "cap-exceeded: the dead default is still deleted")
        H.eqList(capped.install, [.deriveAndInstallDefault(interface: "en0")],
                 "cap-exceeded: and a working one still installed")
        H.eqList(capped.sweep, [], "cap-exceeded: only the sweep is given up")
    }
}
