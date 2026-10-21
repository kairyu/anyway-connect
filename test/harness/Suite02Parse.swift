import Foundation

// Suite 2 — `NetReconcile.parseRouteTable` (NetReconcile.swift:76-171).
//
// Cases derived from the parser's own documented rules: column indices from the
// HEADER rather than positionally, `gatewayText` kept VERBATIM, and netstat's
// TWO abbreviation rules — the slash form, where the printed prefix is
// authoritative and the octet count is deliberately NOT cross-checked, and the
// class-masked form, where the prefix is INFERRED from the octet count and the
// two ARE cross-checked.
//
// The fail-closed return of `[]` is asserted too: it is what clause (d′) turns
// into `abort = .routeTableUnreadable`, i.e. configd removals only and no route
// reasoning at all.

enum Suite02Parse {

    static func run() {
        H.suite("Suite 2 — parseRouteTable")

        // ── Row counts, as the fixtures stand. Counted from the fixture text
        // and not from the parser: every non-banner line carrying at least the
        // four needed columns is a row.
        H.eq(NetReconcile.parseRouteTable(Fixtures.routeTable("clean")).count, 9,
             "clean has 9 rows")
        H.eq(NetReconcile.parseRouteTable(Fixtures.routeTable("vpn-up")).count, 140,
             "vpn-up has 140 rows")
        H.eq(NetReconcile.parseRouteTable(Fixtures.routeTable("carried-home")).count, 146,
             "carried-home has 146 rows (vpn-up plus the home link's own)")
        H.eq(NetReconcile.parseRouteTable(Fixtures.routeTable("lingering-utun")).count, 14,
             "lingering-utun has 14 rows")
        H.eq(NetReconcile.parseRouteTable(Fixtures.routeTable("link-down")).count, 8,
             "link-down has 8 rows")
        H.eq(NetReconcile.parseRouteTable(Fixtures.routeTable("no-default")).count, 7,
             "no-default has 7 rows")
        H.eq(NetReconcile.parseRouteTable(Fixtures.routeTable("two-physical")).count, 9,
             "two-physical has 9 rows")
        H.eq(NetReconcile.parseRouteTable(Fixtures.routeTable("two-tunnels")).count, 10,
             "two-tunnels has 10 rows")
        // 300 synthetic destinations, plus the default and the on-link row.
        H.eq(NetReconcile.parseRouteTable(Fixtures.routeTable("cap-exceeded")).count, 302,
             "cap-exceeded has 302 rows")

        // ── The whole first row of `clean`, field by field.
        let clean = NetReconcile.parseRouteTable(Fixtures.routeTable("clean"))
        H.eq(clean[0], NetReconcile.RouteEntry(destination: .defaultRoute,
                                               gatewayText: "192.168.1.1",
                                               gateway: IPv4("192.168.1.1"),
                                               flags: "UGScg", netif: "en0"),
             "clean[0] is the unscoped default, every field")

        // ── `isIfScoped` is RTF_IFSCOPE, read from the flag string. Verified
        // live: the destinations that appear twice differ by exactly this
        // letter. Case-sensitive — the lowercase `i` is RTF_IFREF and means
        // something else entirely.
        let home = NetReconcile.parseRouteTable(Fixtures.routeTable("carried-home"))
        H.eq(home[0].netif, "utun7", "carried-home[0] is the tunnel default")
        H.eq(home[0].isIfScoped, false, "UGScg is NOT scoped")
        H.eq(home[1].netif, "en0", "carried-home[1] is the office default on en0")
        H.eq(home[1].isIfScoped, true, "UGScIg IS scoped")
        H.eq(home[2].isIfScoped, false, "UCSc is not scoped")
        H.eq(home[3].isIfScoped, true, "UCScI is the scoped duplicate of the same prefix")
        H.eq(home[2].destination, home[3].destination,
             "the scoped and unscoped duplicates name the SAME destination")
        H.eq(NetReconcile.parseRouteTable(
                header + "\n10.0.0.0/8 10.0.1.1 UGSci en0").first?.isIfScoped, false,
             "a lowercase i is RTF_IFREF, not RTF_IFSCOPE")

        // ── `gatewayText` VERBATIM, with `gateway` non-nil ONLY for a strict
        // dotted quad. `nil` is read by the sweep classifier as "on-link, not
        // via a router", so this is the distinction the whole sweep turns on.
        H.eq(home[2].gatewayText, "link#15", "an -interface row keeps `link#15` verbatim")
        H.ok(home[2].gateway == nil, "and parses to no IPv4")
        let mac = home.first { $0.gatewayText.contains(":") }
        H.eq(mac?.gatewayText, "0:0:5e:0:53:1", "a MAC gateway is kept verbatim too")
        H.ok(mac?.gateway == nil, "and parses to no IPv4")
        H.eq(home[6].gatewayText, "10.0.1.1", "a dotted-quad gateway is kept verbatim")
        H.eq(home[6].gateway, IPv4("10.0.1.1"), "and parses")

        // ── Every destination kind.
        H.eq(home[1].destination, .defaultRoute, "`default` is .defaultRoute")
        H.eq(home[6].destination, .host(IPv4("10.0.1.51")!),
             "a bare four-octet destination is .host")
        H.eq(home[2].destination, .network(IPv4("10.0.1.0")!, prefixLength: 24),
             "`10.0.1/24`: the printed prefix wins, the address is right-padded")
        H.eq(home[4].destination, .network(IPv4("10.0.1.1")!, prefixLength: 32),
             "`10.0.1.1/32` is .network at /32, NOT .host — the slash form decides")
        H.eq(home[8].destination, .network(IPv4("100.64.0.0")!, prefixLength: 16),
             "`100.64`: the class mask netstat omits, inferred from two octets")
        H.eq(NetReconcile.parseRouteTable(header + "\n100.68.0/16 10.0.1.1 UGSc en0")
                .first?.destination,
             .network(IPv4("100.68.0.0")!, prefixLength: 16),
             "`100.68.0/16`: three octets against a /16 is a REAL row, not unparsable")
        H.eq(NetReconcile.parseRouteTable(header + "\n224.0.0/4 link#15 UmCS en0")
                .first?.destination,
             .network(IPv4("224.0.0.0")!, prefixLength: 4),
             "`224.0.0/4`: three octets against a /4 — no octet-count cross-check here")
        H.eq(NetReconcile.parseRouteTable(header + "\n127 127.0.0.1 UCS lo0")
                .first?.destination,
             .network(IPv4("127.0.0.0")!, prefixLength: 8),
             "`127`: one octet infers /8")
        H.eq(NetReconcile.parseRouteTable(header + "\n207.226.132 10.0.1.1 UGSc en0")
                .first?.destination,
             .network(IPv4("207.226.132.0")!, prefixLength: 24),
             "`207.226.132`: three octets infer /24")

        // ── `.unparsable` — kept, never acted on. A destination we cannot name
        // exactly cannot be named exactly to `route delete` either.
        for bad in ["10.0.1.1/33", "010.0.1/24", "10.0.1.5/24", "1.2.3.4.5",
                    "nonsense", "10.0.1.1/", "/24"] {
            H.eq(NetReconcile.parseRouteTable(header + "\n\(bad) 10.0.1.1 UGSc en0")
                    .first?.destination,
                 .unparsable(bad), "unparsable: \(bad)")
        }

        // ── FAIL CLOSED. `[]` when the header is absent or lacks any of the
        // four columns we need; a short row is skipped rather than interpreted.
        H.eq(NetReconcile.parseRouteTable("").count, 0, "empty text: no rows")
        H.eq(NetReconcile.parseRouteTable("Routing tables\n\nInternet:\n").count, 0,
             "banners with no header: no rows")
        H.eq(NetReconcile.parseRouteTable(
                "Destination Gateway Flags Expire\ndefault 10.0.1.1 UGScg\n").count, 0,
             "a header with no Netif column: fail closed")
        H.eq(NetReconcile.parseRouteTable(
                "Destination Gateway Netif Expire\ndefault 10.0.1.1 en0\n").count, 0,
             "a header with no Flags column: fail closed")
        H.eq(NetReconcile.parseRouteTable(header + "\ndefault 10.0.1.1\n").count, 0,
             "a row too short to carry the four columns is skipped")

        // ── The second address family's repeated header is not data.
        H.eq(NetReconcile.parseRouteTable(
                header + "\ndefault 10.0.1.1 UGScg en0\n" + header + "\n").count, 1,
             "a repeated header is skipped, not parsed as a row")

        // ── Columns come from the header, so an older netstat layout with
        // Refs/Use between Flags and Netif still reads Netif correctly. Getting
        // this wrong makes every netif a number: no utun default is recognised
        // as tunnel-like and every scoped deletion is aimed at `-ifscope 0`.
        let older = "Destination Gateway Flags Refs Use Netif Expire\n"
                  + "default 10.0.1.1 UGScg 12 340 en0\n"
        H.eq(NetReconcile.parseRouteTable(older).first?.netif, "en0",
             "the Refs/Use layout still yields netif en0")
        H.eq(NetReconcile.parseRouteTable(older).first?.flags, "UGScg",
             "and the flags are still the flag string")

        // ── The trailing `!` (RTF_BLACKHOLE's print) is read past, never
        // counted on.
        H.eq(NetReconcile.parseRouteTable(header + "\n192.168.1/24 link#15 UCSc en0 !")
                .first?.netif, "en0",
             "a trailing ! does not shift the netif column")
    }

    /// The five-column header this machine prints.
    private static let header =
        "Destination        Gateway            Flags               Netif Expire"
}
