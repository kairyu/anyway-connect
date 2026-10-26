import Foundation

// Suite 10 — `TunnelStop`, and the two app-side decisions that consume it.
//
// WHAT THIS SUITE IS FOR. `stopTunnel` used to reply `true` unconditionally: it
// said "no tunnel running" when it had only failed to look in the right place,
// and "stopped (escalated)" after a SIGTERM whose result it never observed. The
// app then deleted its endpoint record while openconnect was alive, its `pgrep`
// status poll found the tunnel 8 s later with nothing to name it, and the menu
// settled on "Connected: ?".
//
// Everything below runs from LITERALS. No process is signalled, no `ps` or
// `pgrep` is executed, no pid file is read — which is the only way any of this
// can be tested on the machine it was written on, where the live tunnel and the
// installed daemon must not be touched. `isAlive` and `identify` are injected,
// so the racing cases are expressible exactly; the signal sequence itself, the
// two waits, the subprocesses, `proc_pidpath` and the XPC round trip are NOT
// unit-testable and are named as such in the verification record.
//
// The measured strings in case 13 come from a read-only probe of the running
// tunnel on this machine, and the first row is the regression test for the
// basename decision: an exec-path EQUALITY check would have failed it and
// refused to stop the real tunnel.

enum Suite10TunnelStop {

    /// The installed route-wrapper path, as a literal rather than through
    /// `PrivilegedInstaller`, so the suite asserts the string the probe actually
    /// measured out of the live openconnect's argv.
    private static let wrapper = "/usr/local/libexec/anyway-connect/route-wrapper.sh"

    /// The real argv, measured read-only from the running tunnel (addresses and
    /// the host are the fixtures README's reserved forms).
    private static let realArgv =
        "/opt/homebrew/bin/openconnect --protocol=anyconnect --cookie-on-stdin "
        + "--timestamp --pid-file=/var/run/anyway-connect.pid "
        + "--script=/usr/local/libexec/anyway-connect/route-wrapper.sh -- vpn.example.com"

    private static func verdict(found: [Int32] = [], escalated: [Int32] = [],
                                survivors: [Int32] = [], unidentified: [Int32] = [],
                                notOursLive: [Int32] = [],
                                cleared: Bool = false) -> TunnelStop.Verdict {
        TunnelStop.verdict(found: found, escalated: escalated, survivors: survivors,
                           unidentified: unidentified, notOursLive: notOursLive,
                           clearedStalePIDFile: cleared)
    }

    static func run() {
        H.suite("Suite 10 — TunnelStop")

        // ── Cases 1-2: nothing of ours was running ──────────────────────────
        let nothing = verdict()
        H.eq(nothing, .nothingToStop(clearedStalePIDFile: false, notOursLive: []),
             "case 1  no observation at all: nothingToStop")
        H.eq(TunnelStop.message(nothing), "no tunnel of ours running",
             "case 1  and the baseline string no longer claims 'no tunnel running'")
        H.ok(TunnelStop.isSuccess(nothing), "case 1  a success")

        let clearedStale = verdict(cleared: true)
        H.eq(clearedStale, .nothingToStop(clearedStalePIDFile: true, notOursLive: []),
             "case 2  a stale pid file was removed")
        H.ok(TunnelStop.message(clearedStale).contains("cleared a stale pid file"),
             "case 2  and the message says so")
        H.ok(TunnelStop.isSuccess(clearedStale), "case 2  still a success")

        // ── Cases 3-4: it stopped ───────────────────────────────────────────
        let stopped = verdict(found: [42])
        H.eq(stopped, .stopped(pids: [42], escalated: false, unidentified: []),
             "case 3  signalled 42 and it exited on the SIGINT")
        H.eq(TunnelStop.message(stopped), "stopped pid 42", "case 3  message")
        H.ok(TunnelStop.isSuccess(stopped), "case 3  a success")

        let escalatedOnly = verdict(found: [42], escalated: [42])
        H.eq(escalatedOnly, .stopped(pids: [42], escalated: true, unidentified: []),
             "case 4  it needed the SIGTERM but it did exit")
        H.ok(TunnelStop.message(escalatedOnly).contains("escalated to SIGTERM"),
             "case 4  and the message says the disconnect script may have been cut short")
        H.ok(TunnelStop.isSuccess(escalatedOnly), "case 4  a success")

        // ── Cases 5-6: .stuck, which the old code could not express ─────────
        let stuck = verdict(found: [42], escalated: [42], survivors: [42])
        H.eq(stuck, .stuck(pids: [42], survivors: [42]),
             "case 5  it survived both signals")
        H.eq(TunnelStop.message(stuck),
             "found pid 42 and signalled it, but it is still running — NOT stopped",
             "case 5  message")
        H.ok(!TunnelStop.isSuccess(stuck), "case 5  NOT a success — this is the defect's core")

        let stuckOfTwo = verdict(found: [42, 43], escalated: [43], survivors: [43])
        H.eq(stuckOfTwo, .stuck(pids: [42, 43], survivors: [43]),
             "case 6  42 exited, 43 did not")
        H.ok(TunnelStop.message(stuckOfTwo).contains("43"),
             "case 6  the message names 43")
        H.ok(!TunnelStop.message(stuckOfTwo).contains("42"),
             "case 6  and NOT 42 — naming a pid that did exit sends the reader after it")
        H.ok(TunnelStop.message(stuckOfTwo).hasSuffix("NOT stopped"),
             "case 6  and it ends NOT stopped")

        // ── Case 7: the clamp, BOTH halves ──────────────────────────────────
        //
        // By clamping and NOT by trapping: this runs in a root daemon on a
        // teardown path, where a precondition failure would abort the teardown.
        let clampSurvivors = verdict(found: [42], escalated: [42], survivors: [42, 99])
        H.eq(clampSurvivors, .stuck(pids: [42], survivors: [42]),
             "case 7a survivors ⊄ escalated is clamped, not trapped on")
        H.ok(!TunnelStop.message(clampSurvivors).contains("99"),
             "case 7a and 99 never reaches a message")
        let clampEscalated = verdict(found: [42, 43], escalated: [], survivors: [43])
        H.eq(clampEscalated, .stopped(pids: [42, 43], escalated: false, unidentified: []),
             "case 7b a survivor that was never escalated clamps to empty: stopped")

        // ── Case 8: order independence ──────────────────────────────────────
        H.eq(TunnelStop.message(verdict(found: [43, 42])),
             TunnelStop.message(verdict(found: [42, 43])),
             "case 8  every list is sorted before it reaches a message")
        H.eq(verdict(found: [43, 42]), verdict(found: [42, 43]),
             "case 8  and the verdict itself is order-independent too")

        // ── Case 9: found nothing, could not identify what it did find ──────
        let unidentified = verdict(unidentified: [99])
        H.eq(unidentified, .unidentified(pids: [99]),
             "case 9  a live pid that could not be established as ours")
        H.eq(TunnelStop.message(unidentified),
             "live pid 99 could not be identified as our openconnect — "
             + "NOT signalled and NOT stopped",
             "case 9  message")
        H.ok(!TunnelStop.isSuccess(unidentified),
             "case 9  NOT a success: something may be running")

        // ── Case 10: precedence ─────────────────────────────────────────────
        //
        // A survivor outranks an unidentified pid. `.stuck`'s payload carries no
        // unidentified list, so the daemon logs those pids on a separate line
        // rather than losing them; the reply and the log line both come from
        // `message`, so they cannot drift.
        let both = verdict(found: [42], escalated: [42], survivors: [42], unidentified: [99])
        H.eq(both, .stuck(pids: [42], survivors: [42]),
             "case 10 survivors non-empty wins over unidentified, not a second verdict")
        H.ok(!TunnelStop.isSuccess(both), "case 10 and it is not a success either way")

        // ── Case 11: a live openconnect that is NOT ours, both halves ───────
        let notOurs = verdict(notOursLive: [99])
        H.eq(notOurs, .nothingToStop(clearedStalePIDFile: false, notOursLive: [99]),
             "case 11a nothing OF OURS runs, so the endpoint record names nothing")
        H.ok(TunnelStop.isSuccess(notOurs),
             "case 11a a SUCCESS — clearing the app's record is right here")
        H.eq(TunnelStop.message(notOurs),
             "no tunnel of ours running (left pid 99 alone: "
             + "a live openconnect that is not ours)",
             "case 11a but the message no longer asserts 'no tunnel running' about the machine")
        H.ok(!TunnelStop.message(notOurs).contains("cleared a stale pid file"),
             "case 11a and it claims no clear it did not make")

        // The same input one layer down: a live `.notOurs` pid from the scan
        // lands in `notOursLive` and NOT in `stalePIDFile`, so the daemon's
        // removal condition is false and the pid file stays.
        let notOursTargets = TunnelStop.targets(
            inMemory: nil, pidFile: [], pgrep: [99],
            isAlive: { _ in true }, identify: { _ in .notOurs })
        H.eqList(notOursTargets.notOursLive, [99], "case 11b it is notOursLive")
        H.eqList(notOursTargets.stalePIDFile, [], "case 11b and stalePIDFile is empty")
        H.eqList(notOursTargets.signal, [], "case 11b and it is never signalled")

        // ── Case 12: `targets`, the source-keyed table ──────────────────────
        targetsTable()

        // ── Case 13: `isOurOpenconnect` against the MEASURED strings ────────
        identityTable()

        // ── Case 14: `teardownFollowUp` ─────────────────────────────────────
        followUpTable()

        // ── Case 15: the app-side filter, as a pure composition ─────────────
        appSideFilter()
    }

    // MARK: - Case 12

    private static func targetsTable() {
        // Dictionary-backed, so every arm of the table is expressible: 7 is ours,
        // 8 is somebody else's, 9 cannot be probed, 10 has exited under the probe.
        let identities: [Int32: TunnelStop.Identity] = [
            7: .ourOpenconnect, 8: .notOurs, 9: .unknown, 10: .gone,
        ]
        var identifyCalls: [Int32] = []
        let identify: (Int32) -> TunnelStop.Identity = { pid in
            identifyCalls.append(pid)
            return identities[pid] ?? .unknown
        }

        // The floor. `kill(0, SIGINT)` signals the daemon's own process group and
        // `pid_t("0")` parses, so a 0 in that root-owned file is a real hole.
        let floored = TunnelStop.targets(inMemory: nil, pidFile: [0, 1], pgrep: [0],
                                         isAlive: { _ in true }, identify: identify)
        H.eq(floored, TunnelStop.Targets(), "case 12a pid 0 and 1 are dropped from every source")

        // The in-memory handle: this process's own child, and the daemon holds the
        // `Process`. Signalled with NO identify call — asserted by the counter,
        // because the real `identify` is two syscalls and a subprocess.
        identifyCalls = []
        let inMemory = TunnelStop.targets(inMemory: 42, pidFile: [], pgrep: [],
                                          isAlive: { _ in true }, identify: identify)
        H.eqList(inMemory.signal, [42], "case 12b the in-memory pid is signalled")
        H.eqList(identifyCalls, [], "case 12b and identify was never asked about it")

        H.eqList(TunnelStop.targets(inMemory: nil, pidFile: [], pgrep: [7],
                                    isAlive: { _ in true }, identify: identify).signal,
                 [7], "case 12c a pgrep pid identified as ours is signalled")

        let foreign = TunnelStop.targets(inMemory: nil, pidFile: [], pgrep: [8],
                                         isAlive: { _ in true }, identify: identify)
        H.eqList(foreign.notOursLive, [8],
                 "case 12d a live pgrep pid that is NOT ours: notOursLive")
        H.eqList(foreign.signal, [],
                 "case 12d and it is NOT signalled — the identity rule, asserted")

        H.eqList(TunnelStop.targets(inMemory: nil, pidFile: [7], pgrep: [],
                                    isAlive: { _ in true }, identify: identify).signal,
                 [7], "case 12e a pid-file pid identified as ours is signalled")

        H.eqList(TunnelStop.targets(inMemory: nil, pidFile: [10], pgrep: [],
                                    isAlive: { _ in true }, identify: identify).stalePIDFile,
                 [10], "case 12f a pid-file pid whose probe returned ESRCH: stalePIDFile")

        // THE OBSERVED INPUT, and the case an earlier revision of this fix
        // dropped before `identify` could see it — so it would not have cleared
        // the very file whose staleness caused the incident.
        identifyCalls = []
        let deadInFile = TunnelStop.targets(inMemory: nil, pidFile: [55], pgrep: [],
                                            isAlive: { _ in false }, identify: identify)
        H.eqList(deadInFile.stalePIDFile, [55],
                 "case 12g a pid-file pid that isAlive calls dead: stalePIDFile")
        H.eqList(identifyCalls, [],
                 "case 12g without a probe — the file naming a dead pid IS the evidence")

        let deadInScan = TunnelStop.targets(inMemory: nil, pidFile: [], pgrep: [55],
                                            isAlive: { _ in false }, identify: identify)
        H.eq(deadInScan, TunnelStop.Targets(),
             "case 12h a dead pgrep pid is dropped: that output is a snapshot")

        H.eqList(TunnelStop.targets(inMemory: nil, pidFile: [], pgrep: [9],
                                    isAlive: { _ in true }, identify: identify).unidentified,
                 [9], "case 12i .unknown and still alive: unidentified, never signalled")

        // The re-check. An argv probe that timed out says nothing about liveness,
        // so a pid that has since exited must not produce a pessimistic verdict.
        var aliveAnswers = 0
        let vanishing: (Int32) -> Bool = { _ in
            aliveAnswers += 1
            return aliveAnswers == 1
        }
        let vanishedFile = TunnelStop.targets(inMemory: nil, pidFile: [9], pgrep: [],
                                              isAlive: vanishing, identify: identify)
        H.eqList(vanishedFile.stalePIDFile, [9],
                 "case 12j .unknown, alive then dead, from the FILE: stalePIDFile")
        H.eqList(vanishedFile.unidentified, [],
                 "case 12j and not reported as unidentified")
        aliveAnswers = 0
        let vanishedScan = TunnelStop.targets(inMemory: nil, pidFile: [], pgrep: [9],
                                              isAlive: vanishing, identify: identify)
        H.eq(vanishedScan, TunnelStop.Targets(),
             "case 12k the same from the SCAN: dropped")

        // One classification per pid, whichever sources name it.
        let everywhere = TunnelStop.targets(inMemory: 7, pidFile: [7], pgrep: [7],
                                            isAlive: { _ in true }, identify: identify)
        H.eqList(everywhere.signal, [7], "case 12l the same pid in all three sources: signal once")
        H.eqList(everywhere.stalePIDFile, [], "case 12l and nothing else")

        // A DEAD in-memory handle does not claim the pid, so the file can still
        // report it stale — the two sources mean different things about it.
        let deadHandle = TunnelStop.targets(inMemory: 55, pidFile: [55], pgrep: [],
                                            isAlive: { _ in false }, identify: identify)
        H.eqList(deadHandle.stalePIDFile, [55],
                 "case 12m a dead in-memory pid that the file also names: stalePIDFile")

        // The whole table at once, which is what the daemon really hands it.
        let mixed = TunnelStop.targets(inMemory: 42, pidFile: [0, 7, 10, 55],
                                       pgrep: [8, 9, 43],
                                       isAlive: { $0 != 55 }, identify: identify)
        H.eqList(mixed.signal, [7, 42], "case 12n mixed: only ours is signalled")
        H.eqList(mixed.notOursLive, [8], "case 12n mixed: notOursLive")
        H.eqList(mixed.unidentified, [9, 43], "case 12n mixed: unidentified")
        H.eqList(mixed.stalePIDFile, [10, 55], "case 12n mixed: stalePIDFile")
    }

    // MARK: - Case 13

    private static func identityTable() {
        func ours(_ execPath: String, _ command: String,
                  script: String = wrapper) -> Bool {
            TunnelStop.isOurOpenconnect(execPath: execPath, command: command,
                                        scriptPath: script)
        }

        // THE REGRESSION TEST for the basename decision. The kernel records the
        // version-numbered Cellar realpath while the candidate list the daemon
        // execs from returns the /opt/homebrew/bin symlink, so an exec-path
        // equality check would have refused to stop the real tunnel — and the
        // Cellar component moves on every `brew upgrade openconnect`.
        H.ok(ours("/opt/homebrew/Cellar/openconnect/9.21/bin/openconnect", realArgv),
             "case 13a the measured Cellar realpath with the real argv: ACCEPTED")
        H.ok(ours("/opt/homebrew/bin/openconnect", realArgv),
             "case 13b the symlink form — which is also what the app reads out of ps")

        H.ok(!ours("/bin/zsh", realArgv),
             "case 13c /bin/zsh: rejected whatever its argv says")
        H.ok(!ours("/usr/bin/openconnect-wrapper", realArgv),
             "case 13d openconnect-wrapper: the basename is not exactly openconnect")
        H.ok(!ours("openconnect", realArgv),
             "case 13e a bare relative name: rejected, which is parity with the "
             + "helper's */openconnect and a form no transport here produces")

        let noCookie = realArgv.replacingOccurrences(of: " --cookie-on-stdin", with: "")
        H.ok(!ours("/opt/homebrew/bin/openconnect", noCookie),
             "case 13f argv missing --cookie-on-stdin")
        let noScript = realArgv.replacingOccurrences(
            of: " --script=/usr/local/libexec/anyway-connect/route-wrapper.sh", with: "")
        H.ok(!ours("/opt/homebrew/bin/openconnect", noScript),
             "case 13g argv missing --script=")
        H.ok(!ours("/opt/homebrew/bin/openconnect",
                   realArgv.replacingOccurrences(
                       of: "/usr/local/libexec/anyway-connect/route-wrapper.sh",
                       with: "/tmp/evil.sh")),
             "case 13h --script=/tmp/evil.sh: the marker is the INSTALLED path, not any path")
        H.ok(!ours("/usr/bin/grep", "grep openconnect --cookie-on-stdin"),
             "case 13i a grep for openconnect is not an openconnect")

        H.ok(!ours("", ""), "case 13j empty strings")
        H.ok(!ours("", realArgv), "case 13k no exec path: the kernel could not name it")
        H.ok(!ours("/opt/homebrew/bin/openconnect", ""), "case 13l no argv at all")
        H.ok(!ours("/opt/homebrew/bin/openconnect", realArgv, script: ""),
             "case 13m an empty script path matches nothing — it must not match everything")
    }

    // MARK: - Case 14

    private static func followUpTable() {
        // The table that encodes "do not clear on a stop that stopped nothing".
        H.eq(VPNRunner.teardownFollowUp(.ok("stopped pid 42")), .clearAndReturn,
             "case 14a .ok: the absence of a tunnel of ours was ESTABLISHED, so clear")
        H.eq(VPNRunner.teardownFollowUp(.failed("… NOT stopped")),
             .keepAndFallThrough(invalidateTransport: false),
             "case 14b .failed: keep the record, try the fallback, keep the transport cache")
        H.eq(VPNRunner.teardownFollowUp(.unreachable("no reply")),
             .keepAndFallThrough(invalidateTransport: true),
             "case 14c .unreachable: keep the record, and the cached transport is suspect")
        H.eq(VPNRunner.teardownFollowUp(.refused("a mutation is in progress")),
             .keepAndReturn,
             "case 14d .refused is an ANSWER: do not retry on a weaker transport")
    }

    // MARK: - Case 15

    private static func appSideFilter() {
        // The daemon refuses to signal a pid it cannot identify, and this path
        // must not undo that one layer up: it signals as root through sudo.
        // Driven as a pure composition over three `ps -ww -o pid=,command=`
        // lines, and asserted over the FILTER rather than by signalling anything.
        let psOutput = """
        \(42) \(realArgv)
        \(43) /opt/homebrew/bin/openconnect --protocol=anyconnect --cookie-on-stdin -- vpn.example.com
        \(44)
        """
        let filtered = VPNRunner.ourOpenconnects(among: [42, 43, 44], psOutput: psOutput,
                                                 scriptPath: wrapper)
        H.eqList(filtered.verified, [42],
                 "case 15a only the pid whose argv carries BOTH markers survives")
        H.eqList(filtered.refused, [43, 44],
                 "case 15a and the rest are refused — named by number in the app's log")

        // Fails CLOSED. An unreadable `ps` refuses everything and the app's last
        // resort is gone; that is the direction to be wrong in, and the cost is
        // stated rather than buried.
        let blind = VPNRunner.ourOpenconnects(among: [42, 43], psOutput: "",
                                              scriptPath: wrapper)
        H.eqList(blind.verified, [], "case 15b no ps output: nothing is signalled")
        H.eqList(blind.refused, [42, 43], "case 15b every candidate is refused")

        // A line for a pid nobody asked about cannot smuggle itself in.
        let uninvited = VPNRunner.ourOpenconnects(among: [42], psOutput: "99 \(realArgv)",
                                                  scriptPath: wrapper)
        H.eqList(uninvited.verified, [],
                 "case 15c a ps line outside the candidate set is ignored")
        H.eqList(uninvited.refused, [42], "case 15c and the candidate is still refused")
    }
}
