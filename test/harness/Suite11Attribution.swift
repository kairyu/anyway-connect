import Foundation

// Suite 11 — `NetReconcile.tunnelScope`, `TunnelAttribution.decode` and
// `TunnelAttribution.attributionOutcome`, all from literals and no fixtures.
//
// WHY THESE THREE TOGETHER. They are the whole of defect 2's decision layer: one
// function says which tunnels a privileged delete may touch, one decides what an
// external file is allowed to claim, and one decides which interface is ours in
// the first place. Everything impure around them — the 500 ms poll, the writes,
// the queue and its generation counter — exists only to feed them.
//
// THE CASE THIS SUITE EXISTS FOR is case 9, the round trip. The collapse to one
// positive rule was approved on the condition that the address witness actually
// survives being written and read back: if it does not, the scope silently pins
// at dead-only forever and the repair never happens, with every line of the
// mechanism still in place and looking implemented. Case 9 is the assertion that
// fails if `decode` is handed a plain `JSONDecoder()`, and the one that pins the
// session key to a STRING rather than to a `Date` the encoder rounds to whole
// seconds.
//
// Nothing here opens a file. `TunnelAttribution.load`'s descriptor hardening is
// `NetState.load`'s verbatim and is exercised by Suite 9's reasoning, while the
// real record is root-owned under /var/run on the developer's live machine —
// which is why its `path` constant is in the runner's forbidden-reference list.

enum Suite11Attribution {

    /// The record builder the scope cases drive, and the one Suite 5 and Suite 12
    /// share. `startedAt` is fixed and DIAGNOSTIC; `sessionToken` is the key.
    static func attr(ourTunnel: String? = nil,
                     ourTunnelIPv4: String? = nil,
                     note: String? = nil,
                     pid: Int = 4242,
                     token: String = "6F9A1C2E-3B4D-4E5F-8A7B-0C1D2E3F4A5B")
        -> TunnelAttribution {
        TunnelAttribution(startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                          sessionToken: token,
                          tunnelPID: pid,
                          ourTunnel: ourTunnel,
                          ourTunnelIPv4: ourTunnelIPv4,
                          ourTunnelObservedAt: Date(timeIntervalSince1970: 1_700_000_004),
                          attributionNote: note)
    }

    /// The `liveAddress` closure, built from a dictionary so a case reads as
    /// "what the snapshot says right now".
    private static func addr(_ map: [String: String]) -> (String) -> String? {
        { map[$0] }
    }

    /// A valid record as JSON TEXT, any one field overridable — written as text
    /// rather than encoded from the struct so the cases below can be malformed in
    /// ways `JSONEncoder` could not produce.
    private static func json(schema: String = "1",
                             startedAt: String = "\"2025-10-20T09:15:00Z\"",
                             sessionToken: String = "\"SESSION-A\"",
                             tunnelPID: String = "4242",
                             ourTunnel: String = "\"utun7\"",
                             ourTunnelIPv4: String = "\"192.168.204.16\"",
                             ourTunnelObservedAt: String = "\"2025-10-20T09:15:04Z\"",
                             attributionNote: String = "null") -> Data {
        Data("""
        {"schema":\(schema),"startedAt":\(startedAt),"sessionToken":\(sessionToken),\
        "tunnelPID":\(tunnelPID),"ourTunnel":\(ourTunnel),\
        "ourTunnelIPv4":\(ourTunnelIPv4),\
        "ourTunnelObservedAt":\(ourTunnelObservedAt),\
        "attributionNote":\(attributionNote)}
        """.utf8)
    }

    static func run() {
        H.suite("Suite 11 — tunnelScope, TunnelAttribution.decode, attributionOutcome")

        // ── case 1: our interface is GONE. `dead` already covers it, so the
        // record adds nothing — asserted so a reader does not expect
        // `.deadPlus` for the common case.
        H.eq(NetReconcile.tunnelScope(attr(ourTunnel: "utun7"),
                                      liveTunnels: [], liveAddress: addr([:]),
                                      snapshotUsable: true),
             .deadOnly(identityUnproven: nil),
             "case 1  a named tunnel the snapshot no longer has: dead-only, no record")

        // ── case 2: THE WITNESS, in all three directions. This is the decision
        // the whole collapse rests on: the gate has already proved no
        // openconnect of ours is running, so a live utun7 is at least as likely
        // to be a recycled index as our own lingering interface.
        let witnessed = attr(ourTunnel: "utun7", ourTunnelIPv4: "192.168.204.16")
        H.eq(NetReconcile.tunnelScope(witnessed, liveTunnels: ["utun7"],
                                      liveAddress: addr(["utun7": "192.168.204.16"]),
                                      snapshotUsable: true),
             .deadPlus(ours: "utun7"),
             "case 2a the recorded address is still on it: it is ours, act on it")
        H.eq(NetReconcile.tunnelScope(witnessed, liveTunnels: ["utun7"],
                                      liveAddress: addr(["utun7": "10.8.0.3"]),
                                      snapshotUsable: true),
             .deadOnly(identityUnproven: IdentityUnproven(netif: "utun7",
                                                          recordedAddress: "192.168.204.16",
                                                          liveAddress: "10.8.0.3")),
             "case 2b a DIFFERENT address: the index is somebody else's now")
        H.eq(NetReconcile.tunnelScope(attr(ourTunnel: "utun7"), liveTunnels: ["utun7"],
                                      liveAddress: addr(["utun7": "192.168.204.16"]),
                                      snapshotUsable: true),
             .deadOnly(identityUnproven: IdentityUnproven(netif: "utun7",
                                                          recordedAddress: nil,
                                                          liveAddress: "192.168.204.16")),
             "case 2c no recorded witness: a live NAME alone authorises nothing")

        // ── case 3: a live link carrying no IPv4 at all — a utun that lingers
        // un-addressed. The witness cannot match, and both sides are recorded.
        H.eq(NetReconcile.tunnelScope(witnessed, liveTunnels: ["utun7"],
                                      liveAddress: addr([:]), snapshotUsable: true),
             .deadOnly(identityUnproven: IdentityUnproven(netif: "utun7",
                                                          recordedAddress: "192.168.204.16",
                                                          liveAddress: nil)),
             "case 3  live with no address: dead-only, liveAddress nil recorded")

        // ── case 4: no record at all — a pre-change daemon, a failed write, a
        // connect over the sudo-helper transport, or any run after a boot, since
        // /var/run is pruned.
        H.eq(NetReconcile.tunnelScope(nil, liveTunnels: ["utun7"],
                                      liveAddress: addr(["utun7": "192.168.204.16"]),
                                      snapshotUsable: true),
             .deadOnly(identityUnproven: nil),
             "case 4  no record: dead-only, and no identity to report as unproven")
        H.eq(NetReconcile.tunnelScope(attr(note: "timedOut"), liveTunnels: ["utun7"],
                                      liveAddress: addr(["utun7": "192.168.204.16"]),
                                      snapshotUsable: true),
             .deadOnly(identityUnproven: nil),
             "case 4b a record that never resolved a name is no identity claim either")

        // ── case 5: an UNUSABLE snapshot answers `.none` whatever the record
        // says, including a record whose witness would otherwise match. Pins the
        // override of (d″)'s old "retain the configd removals" rationale: with no
        // readable interface list we cannot see whether a third party is live,
        // and clearing somebody's DNS because we are blind is the fail-open
        // direction in the arm where fail-closed matters most.
        H.eq(NetReconcile.tunnelScope(witnessed, liveTunnels: ["utun7"],
                                      liveAddress: addr(["utun7": "192.168.204.16"]),
                                      snapshotUsable: false),
             TunnelScope.none,
             "case 5  snapshotUsable false: .none, even for a matching witness")

        // ── case 6: the scope does NOT depend on the netstate. `writeNetState`
        // returns early and writes nothing when there is no physical default at
        // connect time — i.e. when connecting FROM the wedged state reconcile
        // exists to repair — so keying the scope on the netstate would fail
        // closed hardest in the case with the most to repair.
        let noNetstate = NetReconcile.plan(routeTable: Fixtures.routeTable("live-shape"),
                                           interfaces: Fixtures.interfaces("live-shape"),
                                           configdKeys: [],
                                           netstate: nil,
                                           attribution: witnessed)
        H.eqList(noNetstate.actions,
                 [.deleteTunnelDefaultRoute(netif: "utun7", ifscoped: false),
                  .installDefaultRoute(interface: "en0")],
                 "case 6  attribution with NO netstate: utun7 is still attributable")

        // ── case 7: `decode`'s rejections, each from literal Data, and each one
        // a rejection OF SOMETHING THAT WOULD OTHERWISE PASS.
        guard let base = TunnelAttribution.decode(json()) else {
            H.ok(false, "the baseline record decodes")
            return
        }
        H.ok(true, "the baseline record decodes")
        H.eq(base.ourTunnel, "utun7", "ourTunnel survives")
        H.eq(base.ourTunnelIPv4, "192.168.204.16", "the witness survives")
        H.eq(base.sessionToken, "SESSION-A", "the session token survives")
        H.eq(base.tunnelPID, 4242, "tunnelPID survives")
        H.eq(base.startedAt, Date(timeIntervalSince1970: 1_760_951_700),
             "startedAt decodes as .iso8601")

        H.eq(TunnelAttribution.maxBytes, 64 * 1024, "the cap is 64 KiB")
        let padding = String(repeating: "x", count: TunnelAttribution.maxBytes + 1)
        let oversized = json(sessionToken: "\"\(padding)\"")
        H.ok(oversized.count > TunnelAttribution.maxBytes, "the oversized case is oversized")
        H.ok(TunnelAttribution.decode(oversized) == nil, "oversized: rejected before parsing")

        H.eq(TunnelAttribution.currentSchema, 1, "the current schema is 1")
        H.ok(TunnelAttribution.decode(json(schema: "2")) == nil,
             "schema 2: rejected — an unrecognised schema NARROWS, never widens")
        H.ok(TunnelAttribution.decode(json(schema: "0")) == nil, "schema 0: rejected")
        H.ok(TunnelAttribution.decode(Data()) == nil, "empty data: rejected")
        H.ok(TunnelAttribution.decode(Data("not json at all".utf8)) == nil,
             "non-JSON: rejected")
        H.ok(TunnelAttribution.decode(json().prefix(40)) == nil, "truncated JSON: rejected")
        H.ok(TunnelAttribution.decode(Data("{}".utf8)) == nil, "an empty object: rejected")
        H.ok(TunnelAttribution.decode(json(startedAt: "\"last Tuesday\"")) == nil,
             "a startedAt that is not ISO 8601: rejected — it is strict")
        H.ok(TunnelAttribution.decode(Data("""
             {"schema":1,"sessionToken":"SESSION-A","tunnelPID":4242}
             """.utf8)) == nil,
             "startedAt absent: rejected")
        H.ok(TunnelAttribution.decode(Data("""
             {"schema":1,"startedAt":"2025-10-20T09:15:00Z","sessionToken":"SESSION-A"}
             """.utf8)) == nil,
             "tunnelPID absent: rejected — a record that cannot name its session "
           + "cannot be guarded against a stale observer")
        H.ok(TunnelAttribution.decode(json(tunnelPID: "0")) == nil, "tunnelPID 0: rejected")
        H.ok(TunnelAttribution.decode(json(tunnelPID: "1")) == nil, "tunnelPID 1: rejected")
        H.ok(TunnelAttribution.decode(json(tunnelPID: "\"4242\"")) == nil,
             "a pid that is a string: rejected")
        H.ok(TunnelAttribution.decode(json(sessionToken: "\"\"")) == nil,
             "an EMPTY session token: rejected — it is the session key")
        H.ok(TunnelAttribution.decode(json(sessionToken: "null")) == nil,
             "an absent session token: rejected")
        H.ok(TunnelAttribution.decode(
                json(sessionToken: "\"\(String(repeating: "t", count: 65))\"")) == nil,
             "a token over 64 bytes: rejected")

        // ── case 8: `decode`'s DROPS and truncations, each asserted to leave a
        // USABLE record. The direction is what makes "drop, do not reject" sound
        // here: losing `ourTunnel` or the witness can only remove the single live
        // name from scope, so no field's loss can WIDEN what reconcile touches.
        let hostile = TunnelAttribution.decode(
            json(ourTunnel: "\"en0; route delete default\""))
        H.eq(hostile?.ourTunnel, nil, "a name carrying shell metacharacters: dropped")
        H.eq(hostile?.attributionNote, "invalid", "and said to be invalid")
        H.eq(hostile?.sessionToken, "SESSION-A", "the rest of the record survives")
        H.eq(TunnelAttribution.decode(json(ourTunnel: "\"utunaaaaaaaaaaaa\""))?.ourTunnel,
             nil, "a 16-byte name: dropped (one rule, ^utun[0-9]{1,3}$, on both arms)")
        H.eq(TunnelAttribution.decode(json(ourTunnel: "\"en0\""))?.ourTunnel, nil,
             "a physical link named as our tunnel: dropped")
        H.eq(TunnelAttribution.decode(json(ourTunnel: "\"utun1234\""))?.ourTunnel, nil,
             "four digits: dropped")
        H.eq(TunnelAttribution.decode(json(ourTunnelIPv4: "\"010.0.1.1\""))?.ourTunnelIPv4,
             nil, "a leading-zero witness: dropped — the IPv4(_:) choice, as NetState")
        H.eq(TunnelAttribution.decode(json(ourTunnelIPv4: "\"1.2.3\""))?.ourTunnelIPv4,
             nil, "three octets: dropped")
        H.eq(TunnelAttribution.decode(json(ourTunnelIPv4: "\"1.2.3\""))?.ourTunnel,
             "utun7", "and the NAME survives a dropped witness — it just narrows")
        let lenientDate = TunnelAttribution.decode(
            json(ourTunnelObservedAt: "\"not-a-date\""))
        H.eq(lenientDate?.ourTunnelObservedAt, nil,
             "a malformed ourTunnelObservedAt: FIELD dropped, not the file")
        H.eq(lenientDate?.ourTunnel, "utun7",
             "and the record stays usable — rejecting it over a diagnostic field "
           + "would narrow nothing and lose an otherwise usable attribution")
        let longNote = TunnelAttribution.decode(
            json(attributionNote: "\"\(String(repeating: "n", count: 100))\""))
        H.eq(longNote?.attributionNote?.utf8.count, 64, "a 100-byte note: truncated to 64")
        H.eq(longNote?.ourTunnel, "utun7", "and the file is accepted")

        // ── case 9: THE ROUND TRIP, and ORCHESTRATOR §2's required proof.
        //
        // Written by the pinned encoder, read by `decode`. Two assertions carry
        // it: the TOKEN survives byte for byte, and `startedAt` does NOT — the
        // encoder emits whole seconds, so a Date() with sub-second precision
        // comes back different and `cur.startedAt == startedAt` would have
        // dropped every observer tick ever made, pinning the scope at dead-only
        // with the whole witness mechanism in place and dead.
        let session = TunnelAttribution(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000.25),
            sessionToken: "6F9A1C2E-3B4D-4E5F-8A7B-0C1D2E3F4A5B",
            tunnelPID: 7781,
            ourTunnel: "utun7",
            ourTunnelIPv4: "192.168.204.16",
            ourTunnelObservedAt: Date(timeIntervalSince1970: 1_700_000_004.75),
            attributionNote: nil)
        guard let encoded = try? TunnelAttribution.encoder().encode(session) else {
            H.ok(false, "the pinned encoder encodes")
            return
        }
        H.ok(true, "case 9  the pinned encoder encodes")
        let text = String(decoding: encoded, as: UTF8.self)
        H.ok(text.contains("\"2023-11-14T22:13:20Z\""),
             "case 9  the date is an ISO 8601 literal in WHOLE SECONDS")
        guard let back = TunnelAttribution.decode(encoded) else {
            H.ok(false, "case 9  and it reads back")
            return
        }
        H.ok(true, "case 9  and it reads back")
        H.eq(back.sessionToken, session.sessionToken,
             "case 9  THE SESSION TOKEN SURVIVES EXACTLY — this is the witness's key")
        H.eq(back.ourTunnel, "utun7", "case 9  the name survives")
        H.eq(back.ourTunnelIPv4, "192.168.204.16",
             "case 9  THE WITNESS SURVIVES — the collapse to one rule rests on this")
        H.eq(back.tunnelPID, 7781, "case 9  the pid survives")
        H.ok(back.startedAt != session.startedAt,
             "case 9  startedAt does NOT survive exactly, which is why it is not the key")
        H.eq(Int(back.startedAt.timeIntervalSince1970),
             Int(session.startedAt.timeIntervalSince1970.rounded(.down)),
             "case 9  but it is equal truncated to whole seconds")
        H.eq(Int(back.ourTunnelObservedAt?.timeIntervalSince1970 ?? -1),
             Int((session.ourTunnelObservedAt?.timeIntervalSince1970 ?? -1).rounded(.down)),
             "case 9  and so is the observation time")
        // The assertion that fails if an implementer gives `decode` a plain
        // JSONDecoder(): without .iso8601 on BOTH sides the strict `startedAt`
        // throws and every record with a date is undecodable.
        H.ok((try? JSONDecoder().decode(TunnelAttribution.self, from: encoded)) == nil,
             "case 9  a plain JSONDecoder() cannot read it — .iso8601 is the contract")

        // ── case 10: `attributionOutcome` from literals. The tick decision is
        // stateless on purpose: a resolved name is still the only new tunnel-like
        // name next tick, so nothing has to remember what the last one said.
        let pre: Set<String> = ["utun0", "utun1", "gif0"]
        func tick(_ names: [String], _ addresses: [String: String] = [:],
                  defaultNetif: String? = nil, alive: Bool = true,
                  elapsed: TimeInterval) -> AttributionTick {
            TunnelAttribution.attributionOutcome(preexisting: pre,
                                                 nowTunnelLike: names,
                                                 addressOf: { addresses[$0] },
                                                 defaultRouteNetif: defaultNetif,
                                                 processAlive: alive,
                                                 elapsed: elapsed,
                                                 deadline: 60)
        }
        H.eq(tick(["utun0", "utun1", "gif0"], elapsed: 3).outcome, .pending,
             "case 10a no new name, process alive, 3 s: pending")
        H.eq(tick(["utun0", "utun1", "gif0", "utun7"],
                  ["utun7": "192.168.204.16"], elapsed: 3).outcome, .resolved("utun7"),
             "case 10b exactly one new tunnel-like name: resolved")
        H.eq(tick(["utun0", "utun1", "gif0", "utun7", "utun9"], elapsed: 3).outcome,
             .pending,
             "case 10c TWO new names at 3 s: pending, NOT terminal — this machine "
           + "churns utuns with no third-party VPN installed")
        H.eq(tick(["utun0", "utun1", "gif0", "utun7", "utun9"],
                  ["utun7": "192.168.204.16"],
                  defaultNetif: "utun7", elapsed: 60).outcome, .resolved("utun7"),
             "case 10d two at the deadline, one holding the UNSCOPED default: that one")
        H.eq(tick(["utun0", "utun1", "gif0", "utun7", "utun9"],
                  defaultNetif: "en0", elapsed: 60).outcome,
             .ambiguous(["utun7", "utun9"]),
             "case 10e two at the deadline, neither holding it: ambiguous")
        H.eq(tick(["utun0", "utun1", "gif0", "utun7", "utun9"],
                  defaultNetif: "utun9", elapsed: 60).outcome, .resolved("utun9"),
             "case 10f the tie-break reads the UNSCOPED default, so the caller's "
           + "answer decides which of the two it is")
        H.eq(tick(["utun0", "utun1", "gif0"], alive: false, elapsed: 3).outcome,
             .processExited,
             "case 10g no new name and the process gone: processExited")
        H.eq(tick(["utun0", "utun1", "gif0"], elapsed: 61).outcome, .timedOut,
             "case 10h no new name at the deadline: timedOut")
        H.eq(tick(["utun0", "utun1", "gif0", "utun7"], ["utun7": "192.168.204.16"],
                  alive: false, elapsed: 3).outcome, .resolved("utun7"),
             "case 10i one new name and the process gone IN THE SAME TICK: resolved — "
           + "the interface appeared and the residue is exactly what reconcile cleans")

        // ── finding 4's two extra cases: the ADDRESS rule, which is the half
        // the previous iteration declared no type for. A utun appears before
        // vpnc-script assigns its address, so the name and the witness land on
        // different ticks and the observer must keep going to get the second.
        let nameOnly = tick(["utun0", "utun1", "gif0", "utun7"], elapsed: 1)
        H.eq(nameOnly.outcome, .resolved("utun7"), "case 10j tick 1: the name resolves")
        H.eq(nameOnly.ourTunnelIPv4, nil, "case 10j tick 1: no address yet")
        H.eq(nameOnly.attributionNote, "pending", "case 10j tick 1: note pending")
        let addressed = tick(["utun0", "utun1", "gif0", "utun7"],
                             ["utun7": "192.168.204.16"], elapsed: 1.5)
        H.eq(addressed.outcome, .resolved("utun7"),
             "case 10k tick 2: the SAME name is re-emitted — the decision is stateless")
        H.eq(addressed.ourTunnelIPv4, "192.168.204.16", "case 10k tick 2: the witness lands")
        H.eq(addressed.attributionNote, nil, "case 10k tick 2: and the note clears")
        let never = tick(["utun0", "utun1", "gif0", "utun7"], elapsed: 60)
        H.eq(never.outcome, .resolved("utun7"),
             "case 10l resolved but never addressed at the deadline: still our name")
        H.eq(never.ourTunnelIPv4, nil, "case 10l with no witness")
        H.eq(never.attributionNote, "addressPending",
             "case 10l and the note says which of the two is missing — the session "
           + "degrades to dead-only, and says so")
    }
}
