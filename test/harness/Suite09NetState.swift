import Foundation

// Suite 9 — `NetState.decode` (NetReconcile.swift:1037-1069) and its encoder.
//
// Every case here is literal `Data`. NOTHING in this suite opens a file, and in
// particular nothing reaches `NetState.load`'s default path — the real file is
// root-owned under /var/run on the developer's live machine. That is why the
// `path` constant is in the runner's forbidden-reference list and why `decode`
// was split out of `load` in the first place: the rejection paths are the
// interesting part and they have to be assertable without a file.
//
// The rejection list is read off the code, rejection by rejection, and the
// direction of each one matters: a field whose loss can only NARROW what
// reconcile touches is dropped, and a field whose loss could WIDEN it rejects
// the whole file.

enum Suite09NetState {

    /// A valid record as JSON text, with any one field overridable. Written as
    /// text rather than encoded from a struct so that the cases below can be
    /// malformed in ways `JSONEncoder` could not produce.
    private static func json(schema: String = "1",
                             writtenAt: String = "\"2024-05-01T12:00:00Z\"",
                             physicalInterface: String = "\"en0\"",
                             physicalSubnet: String = "\"192.168.1.0/24\"",
                             advisory: String = "\"192.168.1.1\"",
                             exceptionRoutes: String = "[\"10.0.0.0/8\"]",
                             tunnelPID: String = "4242",
                             preexistingTunnels: String = "[\"utun0\",\"utun1\"]") -> Data {
        Data("""
        {"schema":\(schema),"writtenAt":\(writtenAt),\
        "physicalInterface":\(physicalInterface),"physicalSubnet":\(physicalSubnet),\
        "physicalGatewayAdvisory":\(advisory),"exceptionRoutes":\(exceptionRoutes),\
        "tunnelPID":\(tunnelPID),"preexistingTunnels":\(preexistingTunnels)}
        """.utf8)
    }

    static func run() {
        H.suite("Suite 9 — NetState.decode")

        // ── The baseline, so every rejection below is a rejection OF SOMETHING
        // THAT WOULD OTHERWISE PASS.
        guard let base = NetState.decode(json()) else {
            H.ok(false, "the baseline record decodes")
            return
        }
        H.ok(true, "the baseline record decodes")
        H.eq(base.physicalInterface, "en0", "physicalInterface survives")
        H.eq(base.physicalSubnet, "192.168.1.0/24", "physicalSubnet survives")
        H.eq(base.physicalGatewayAdvisory, "192.168.1.1", "the advisory survives")
        H.eq(base.tunnelPID, 4242, "tunnelPID survives")
        H.eqList(base.preexistingTunnels, ["utun0", "utun1"], "the exclusion list survives")
        H.eqList(base.exceptionRoutes, ["10.0.0.0/8"], "exceptionRoutes survive")
        H.eq(base.writtenAt, Date(timeIntervalSince1970: 1_714_564_800),
             "writtenAt decodes as .iso8601, which is the cross-implementation contract")

        // ── The round trip through the pinned encoder. Stated once so a writer
        // and a reader cannot disagree about the date format.
        guard let data = try? NetState.encoder().encode(base) else {
            H.ok(false, "the pinned encoder encodes")
            return
        }
        H.ok(true, "the pinned encoder encodes")
        H.eq(NetState.decode(data), base, "and the record survives a round trip unchanged")
        H.ok(String(decoding: data, as: UTF8.self).contains("\"2024-05-01T12:00:00Z\""),
             "with the date as an ISO 8601 literal, not a number")

        // ── The size cap, in the pure half so it is testable. A truncated route
        // table read as authoritative is how a sweep decides the whole internet
        // is unreachable; the same logic applies to a state file.
        H.eq(NetState.maxBytes, 64 * 1024, "the cap is 64 KiB")
        let padding = String(repeating: "x", count: NetState.maxBytes + 1)
        let oversized = json(exceptionRoutes: "[\"\(padding)\"]")
        H.ok(oversized.count > NetState.maxBytes, "the oversized case really is oversized")
        H.ok(NetState.decode(oversized) == nil, "oversized: rejected before parsing")

        // ── A future schema is IGNORED by an older daemon rather than mis-read.
        // Equality, not `<=`: a schema 2 writer may mean something different by
        // the same field names.
        H.eq(NetState.currentSchema, 1, "the current schema is 1")
        H.ok(NetState.decode(json(schema: "2")) == nil, "schema 2: rejected")
        H.ok(NetState.decode(json(schema: "0")) == nil, "schema 0: rejected")

        // ── Structural failures.
        H.ok(NetState.decode(Data()) == nil, "empty data: rejected")
        H.ok(NetState.decode(Data("not json at all".utf8)) == nil, "non-JSON: rejected")
        H.ok(NetState.decode(json().prefix(40)) == nil, "truncated JSON: rejected")
        H.ok(NetState.decode(Data("{}".utf8)) == nil, "an empty object: rejected")
        H.ok(NetState.decode(json(writtenAt: "\"last Tuesday\"")) == nil,
             "a date that is not ISO 8601: rejected")
        H.ok(NetState.decode(json(tunnelPID: "\"4242\"")) == nil,
             "a pid that is a string: rejected")

        // ── `physicalInterface` must satisfy `isRestoreTargetInterface`. The
        // file is root-owned, so this is defence in depth — but it costs four
        // lines and means a corrupted write can never reach `route`.
        H.ok(NetState.decode(json(physicalInterface: "\"utun7\"")) == nil,
             "a utun as the restore target: rejected (FR-1.8)")
        H.ok(NetState.decode(json(physicalInterface: "\"ppp0\"")) == nil,
             "nor a ppp link")
        H.ok(NetState.decode(json(physicalInterface: "\"EN0\"")) == nil,
             "nor an upper-case name")
        H.ok(NetState.decode(json(physicalInterface: "\"\"")) == nil,
             "nor an empty name")
        H.ok(NetState.decode(json(physicalInterface: "\"enaaaaaaaaaaaaaaa\"")) == nil,
             "nor a name longer than IFNAMSIZ-1")
        H.ok(NetState.decode(json(physicalInterface: "\"en0; route delete default\"")) == nil,
             "nor anything carrying shell metacharacters")

        // ── `physicalGatewayAdvisory` is checked with `IPv4(_:) != nil`, NOT
        // with `PrivilegedValidation.isValidIPv4`: the latter accepts
        // `010.0.1.1` and `+1.2.3.4`, which the guard would later reject as
        // malformed — so accepting them here would store a value that can only
        // ever produce a refusal, and hide the reason one layer away from it.
        H.ok(NetState.decode(json(advisory: "\"010.0.1.1\"")) == nil,
             "a leading-zero advisory: rejected here, not later")
        H.ok(NetState.decode(json(advisory: "\"+1.2.3.4\"")) == nil,
             "a signed advisory: rejected")
        H.ok(NetState.decode(json(advisory: "\"10.0.1\"")) == nil,
             "three octets: rejected")
        H.ok(NetState.decode(json(advisory: "\"\"")) == nil, "empty: rejected")
        H.ok(NetState.decode(json(advisory: "\"link#15\"")) == nil,
             "an -interface gateway is not an advisory")

        // ── `preexistingTunnels` entries are DROPPED rather than fatal: a bad
        // name in this list can only NARROW what reconcile touches, so dropping
        // it is the conservative direction, and rejecting the file outright would
        // discard an otherwise usable record.
        H.eqList(NetState.decode(json(preexistingTunnels:
                    "[\"utun0\",\"UTUN1\",\"\",\"utun2\",\"enaaaaaaaaaaaaaaa\"]"))?
                    .preexistingTunnels ?? ["decode failed"],
                 ["utun0", "utun2"],
                 "invalid exclusion-list entries are dropped, the record survives")
        H.eqList(NetState.decode(json(preexistingTunnels: "[]"))?.preexistingTunnels
                    ?? ["decode failed"],
                 [],
                 "an EMPTY exclusion list is a positive statement, not a missing one")

        // ── `physicalSubnet` is deliberately NOT validated: it is only ever
        // compared for equality against a canonically computed `subnetCIDR`, so a
        // malformed value can only fail to match, which is the safe direction.
        H.eq(NetState.decode(json(physicalSubnet: "\"not a subnet\""))?.physicalSubnet,
             "not a subnet",
             "a malformed subnet is accepted — it can only fail to match")

        // ── And the field that must be present: a missing key is a decode
        // failure, not a default.
        H.ok(NetState.decode(Data("""
             {"schema":1,"writtenAt":"2024-05-01T12:00:00Z","physicalSubnet":"192.168.1.0/24",\
             "physicalGatewayAdvisory":"192.168.1.1","exceptionRoutes":[],"tunnelPID":1,\
             "preexistingTunnels":[]}
             """.utf8)) == nil,
             "a missing physicalInterface: rejected")
    }
}
