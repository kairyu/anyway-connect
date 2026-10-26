#!/bin/sh
#
# Independent derivation of the reconcile sweep's deletion list.
#
# WHY THIS EXISTS. Asserting a count the planner produced against the planner is
# a tautology, so the expected sweep list is re-derived HERE, from the fixture
# text and the paired interface snapshot alone. This script reads NO Swift
# source and calls no planner: it re-implements, in awk,
#
#   (a) the sweep's keep/skip classification — the closed list of reasons at
#       NetReconcile.swift:626-747, not "dead by exclusion";
#   (b) the destination canonicalisation — an explicit dotted quad plus an
#       explicit netmask, never netstat's `10.1/16` shorthand, because `route`'s
#       own parser runs the pre-slash text through inet_aton and would read
#       `3.7.35` as `3.7.0.35`;
#   (c) the ordering — distinct (destination, netmask) pairs in FIRST-SEEN row
#       order, each emitting one unscoped deletion followed by one `-ifscope`
#       deletion per distinct netif in first-seen order.
#
# test/run-swift-harness.sh diffs this output against the committed
# test/harness/expected/<name>.sweep.txt BEFORE compiling, and the harness
# asserts the same list element for element against `commands(for:).sweep`. So a
# planner change that moves the list fails the harness, and a hand-edited
# expected file fails the diff.
#
# The printed form is the complete /sbin/route argv, which is what the daemon
# would execute, so the diff pins the argument shape as well as the membership.
#
# Usage: sh test/harness/derive-expected.sh [--kept] <fixture-name> [interfaces-name]
#
# `<fixture-name>` selects test/fixtures/netstat-rn-inet.<fixture-name>.txt and,
# by default, test/fixtures/interfaces.<fixture-name>.json. The optional second
# argument overrides the snapshot, which `cap-exceeded` needs because it has no
# snapshot of its own (see test/fixtures/README.md).
#
# `--kept` prints the OTHER side of the same classification: one line per
# non-default row the sweep declines to delete, with the reason, in row order.
# That is the clause-(c) slice of the planner's `kept` list, so the harness can
# assert the kept multiset element for element instead of counting it. Clauses
# (b), (f) and (g) are NOT derived here — they are few enough per fixture to
# enumerate by hand in the suite, which is what design.md §7.2 point 4 asks for.
#
# No bitwise builtins are used anywhere below: /usr/bin/awk on macOS is BWK awk,
# which has no and()/or()/compl(). Masking is done as exact double arithmetic —
# every value involved is under 2^32, so it is exact.

set -u

mode=sweep
if [ "${1:-}" = "--kept" ]; then mode=kept; shift; fi

name="${1:-}"
[ -n "$name" ] || { echo "usage: derive-expected.sh [--kept] <fixture-name> [interfaces-name]" >&2; exit 64; }

here=$(dirname "$0")
fixtures="$here/../fixtures"

table="$fixtures/netstat-rn-inet.$name.txt"

# The one fixture without a snapshot of its own. Recorded here as well as in the
# fixtures README so the pairing cannot be lost with the prose.
ifaces_name="${2:-}"
if [ -z "$ifaces_name" ]; then
    case "$name" in
        cap-exceeded) ifaces_name="clean" ;;
        *)            ifaces_name="$name" ;;
    esac
fi
ifaces="$fixtures/interfaces.$ifaces_name.json"

[ -f "$table" ]  || { echo "derive-expected: no such route table: $table" >&2; exit 66; }
[ -f "$ifaces" ] || { echo "derive-expected: no such snapshot: $ifaces" >&2; exit 66; }

# ── Step 1: flatten the snapshot ────────────────────────────────────────────
#
# The fixtures are hand-authored JSON of one restricted shape, so this is a
# brace-depth scan rather than a JSON parser: interface objects open at brace
# depth 1 (the enclosing `[` is not a brace), address objects at depth 2. Field
# extraction is by key, so the order of the keys inside an object does not
# matter.
#
# Emits, one per line:
#   IFACE <name> <isUp> <isLoopback> <isPointToPoint>      (1/0 for each flag)
#   ADDR  <name> <a.b.c.d> <prefixLength>                  (in file order)
flatten_interfaces() {
    awk '
        function jstr(obj, key,   p, r, q) {
            p = index(obj, "\"" key "\":\"")
            if (p == 0) return ""
            r = substr(obj, p + length(key) + 4)
            q = index(r, "\"")
            if (q == 0) return ""
            return substr(r, 1, q - 1)
        }
        function jbool(obj, key,   p) {
            p = index(obj, "\"" key "\":")
            if (p == 0) return 0
            return (substr(obj, p + length(key) + 3, 4) == "true") ? 1 : 0
        }
        function jnum(obj, key,   p, r, i, c, out) {
            p = index(obj, "\"" key "\":")
            if (p == 0) return -1
            r = substr(obj, p + length(key) + 3)
            out = ""
            for (i = 1; i <= length(r); i++) {
                c = substr(r, i, 1)
                if (c < "0" || c > "9") break
                out = out c
            }
            return (out == "") ? -1 : out + 0
        }
        function emit(obj,   nm, p, r, depth, i, c, chunk, addr, plen) {
            nm = jstr(obj, "name")
            if (nm == "") return
            printf "IFACE %s %d %d %d\n", nm, jbool(obj, "isUp"),
                   jbool(obj, "isLoopback"), jbool(obj, "isPointToPoint")
            # The ipv4s array, scanned for its nested objects in file order.
            p = index(obj, "\"ipv4s\":[")
            if (p == 0) return
            r = substr(obj, p + 9)
            depth = 0; chunk = ""
            for (i = 1; i <= length(r); i++) {
                c = substr(r, i, 1)
                if (c == "]" && depth == 0) break
                if (c == "{") { depth++; chunk = (depth == 1) ? "{" : chunk c }
                else if (c == "}") {
                    chunk = chunk c; depth--
                    if (depth == 0) {
                        addr = jstr(chunk, "ipv4"); plen = jnum(chunk, "prefixLength")
                        if (addr != "" && plen >= 0)
                            printf "ADDR %s %s %d\n", nm, addr, plen
                        chunk = ""
                    }
                } else if (depth >= 1) chunk = chunk c
            }
        }
        { s = s $0 }
        END {
            # Safe only because no string value in these fixtures contains
            # whitespace: every one is an interface name or a dotted quad.
            gsub(/[ \t]/, "", s)
            depth = 0; buf = ""
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c == "{") { depth++; buf = (depth == 1) ? "{" : buf c }
                else if (c == "}") {
                    buf = buf c; depth--
                    if (depth == 0) { emit(buf); buf = "" }
                } else if (depth >= 1) buf = buf c
            }
        }
    ' "$1"
}

# ── Step 2: classify and order ──────────────────────────────────────────────
flatten_interfaces "$ifaces" | awk -v cap=256 -v mode="$mode" '
    # ---- address arithmetic, no bitwise builtins ----------------------------

    # Strict dotted quad, matching IPv4.init?(_:) at NetGuard.swift:48 exactly:
    # four decimal octets, each 0...255, NO leading zeros, nothing else. The
    # strictness is the point — inet_pton accepts `010.0.1.1` and canonicalises
    # it, so a looser reader here would classify a row the planner refuses.
    function ip2num(t,   n, a, i, o, v) {
        n = split(t, a, ".")
        if (n != 4) return -1
        v = 0
        for (i = 1; i <= 4; i++) {
            o = a[i]
            if (o !~ /^[0-9]{1,3}$/) return -1
            if (length(o) > 1 && substr(o, 1, 1) == "0") return -1
            if (o + 0 > 255) return -1
            v = v * 256 + (o + 0)
        }
        return v
    }
    # netstat abbreviates by dropping trailing zero octets; paddedIPv4
    # (NetReconcile.swift:177) right-pads and then parses STRICTLY.
    function padded(t,   n, a, i, out) {
        n = split(t, a, ".")
        if (n < 1 || n > 4) return -1
        out = a[1]
        for (i = 2; i <= n; i++) out = out "." a[i]
        for (i = n + 1; i <= 4; i++) out = out ".0"
        return ip2num(out)
    }
    function num2ip(v) {
        return sprintf("%d.%d.%d.%d", int(v / 16777216), int(v / 65536) % 256,
                       int(v / 256) % 256, v % 256)
    }
    function blocksize(p) { return 2 ^ (32 - p) }
    function network(v, p) { return int(v / blocksize(p)) * blocksize(p) }
    function broadcast(v, p) { return network(v, p) + blocksize(p) - 1 }
    function masktext(p) { return (p == 0) ? "0.0.0.0" : num2ip(4294967296 - blocksize(p)) }

    function is_loopback(v)  { return v >= 2130706432 && v < 2147483648 }   # 127/8
    function is_multicast(v) { return v >= 3758096384 && v < 4026531840 }   # 224/4
    function is_linklocal(v) { return v >= 2851995648 && v < 2852061184 }   # 169.254/16
    function is_bcast_all(v) { return v == 4294967295 }

    # One line per row the sweep declines to delete, in row order — the
    # clause-(c) slice of the planner `kept` list. Silent in sweep mode.
    function keep(line) { if (mode == "kept") print line }

    function tunnel_like(i) {
        return ifP2P[i] || ifName[i] ~ /^(utun|ppp|ipsec|gif|stf)/
    }
    # isUsablePhysical (NetReconcile.swift:835): up, not a tunnel, not the
    # loopback, and carrying at least one IPv4. lo0 is excluded although the
    # design predicate does not name it, because lo0 is always up and addressed.
    function usable_physical(i) {
        return ifUp[i] && !tunnel_like(i) && !ifLoop[i] && (addrCount[i] > 0)
    }

    # evaluateDefaultGateway (NetGuard.swift:249-333), in its FIXED step order.
    # Returns the verdict name. Steps 4/5/6/7 cannot fire for a target chosen by
    # usable_physical, but they are written out so the order is checkable.
    function guard(gw, i,   j, k, p, a, m, mp) {
        if (ifName[i] == "" || length(ifName[i]) > 15 ||
            ifName[i] !~ /^[a-z0-9]+$/)              return "malformedInterfaceName"
        if (gw < 0)                                  return "malformedGateway"
        if (gw == 0 || is_bcast_all(gw))             return "unspecifiedGateway"
        if (!(i in ifName))                          return "targetInterfaceMissing"
        if (addrCount[i] == 0)                       return "targetInterfaceUnconfigured"
        if (tunnel_like(i))                          return "targetInterfaceIsTunnel"
        if (!ifUp[i])                                return "targetInterfaceDown"
        # Step 8: ANY address of ANY tunnel-like link in the snapshot, whatever
        # the target is. This is the observed vpnc-script failure, reported by
        # its own name.
        for (j = 1; j <= nIface; j++) {
            if (!tunnel_like(j)) continue
            for (k = 1; k <= addrCount[j]; k++)
                if (addrIP[j, k] == gw)              return "gatewayIsTunnelAddress"
        }
        for (k = 1; k <= addrCount[i]; k++)
            if (addrIP[i, k] == gw)                  return "gatewayIsOwnAddress"
        # Step 10: on-link for ANY (address, prefix) pair the link carries; the
        # MATCHED pair is what step 11 then reasons about.
        m = -1
        for (k = 1; k <= addrCount[i]; k++) {
            p = addrLen[i, k]
            if (p < 0 || p > 32) continue
            if (network(gw, p) == network(addrIP[i, k], p)) { m = addrIP[i, k]; mp = p; break }
        }
        if (m < 0)                                   return "gatewayOffLink"
        if (mp <= 30) {
            if (gw == network(m, mp))                return "gatewayIsNetworkAddress"
            if (gw == broadcast(m, mp))              return "gatewayIsBroadcastAddress"
        }
        return "accept"
    }

    # ---- the flattened snapshot -------------------------------------------
    $1 == "IFACE" {
        nIface++
        ifName[nIface] = $2; ifUp[nIface] = $3 + 0
        ifLoop[nIface] = $4 + 0; ifP2P[nIface] = $5 + 0
        addrCount[nIface] = 0
        idxOf[$2] = nIface
        next
    }
    $1 == "ADDR" {
        i = idxOf[$2]
        if (i == "") next
        addrCount[i]++
        addrIP[i, addrCount[i]] = ip2num($3)
        addrLen[i, addrCount[i]] = $4 + 0
        next
    }

    # ---- the route table ---------------------------------------------------
    # Column indices are derived from the HEADER, never positional: older
    # netstat layouts carry Refs/Use between Flags and Netif, and reading Netif
    # as the fourth field there makes every netif a number.
    !sawHeader {
        if ($1 != "Destination") next
        for (i = 1; i <= NF; i++) col[$i] = i
        if (!("Destination" in col) || !("Gateway" in col) ||
            !("Flags" in col) || !("Netif" in col)) {
            print "derive-expected: route table header lacks a needed column" > "/dev/stderr"
            exit 65
        }
        sawHeader = 1
        next
    }
    $1 == "Destination" { next }
    {
        needed = col["Destination"]
        if (col["Gateway"] > needed) needed = col["Gateway"]
        if (col["Flags"] > needed) needed = col["Flags"]
        if (col["Netif"] > needed) needed = col["Netif"]
        if (NF < needed) next

        dstField = $(col["Destination"])
        gwField  = $(col["Gateway"])
        netif    = $(col["Netif"])

        if (dstField == "default") next          # clause (b), not the sweep
        nRow++

        # parseDestination (NetReconcile.swift:116-171). `kind` is net/host/bad.
        kind = "bad"; dstAddr = -1; plen = -1
        if (index(dstField, "/") > 0) {
            n = split(dstField, parts, "/")
            if (n == 2 && parts[2] ~ /^[0-9]+$/ && parts[2] + 0 <= 32) {
                a = padded(parts[1]); p = parts[2] + 0
                # No octet-count cross-check here: netstat prints the
                # abbreviated address independently of the printed prefix, so
                # `224.0.0/4` is a real row.
                if (a >= 0 && network(a, p) == a) { kind = "net"; dstAddr = a; plen = p }
            }
        } else {
            n = split(dstField, oct, ".")
            if (n == 4) {
                a = ip2num(dstField)
                if (a >= 0) { kind = "host"; dstAddr = a }
            } else if (n >= 1 && n <= 3) {
                a = padded(dstField); p = n * 8
                # HERE the prefix is INFERRED from the octet count, so the two
                # are cross-checked against each other.
                if (a >= 0 && network(a, p) == a) { kind = "net"; dstAddr = a; plen = p }
            }
        }
        # displayDestination (NetReconcile.swift:412): the canonical printed
        # form, which is what every kept record carries.
        if (kind == "bad") dst = dstField
        else if (kind == "host") dst = num2ip(dstAddr)
        else dst = num2ip(dstAddr) "/" plen

        # The keep ladder, in the planner order. `first match decides`.
        if (kind == "bad") { keep("unparsable " dst); next }

        gw = ip2num(gwField)
        if (gw < 0) { keep("onLinkRoute " dst); next }   # link#N or a MAC
        if (netif == "lo0" || is_loopback(dstAddr)) { keep("loopback " dst); next }
        # 255.255.255.255 is classified with the multicast group rather than
        # given a category of its own.
        if (is_multicast(dstAddr) || is_bcast_all(dstAddr)) { keep("multicast " dst); next }
        if (is_linklocal(dstAddr)) { keep("linkLocal " dst); next }

        # The on-link question is answered by the GUARD, classified on a CLOSED
        # LIST of keep reasons. First usable physical link whose verdict is not
        # "off-link or about the link" decides.
        kept = ""
        for (i = 1; i <= nIface; i++) {
            if (!usable_physical(i)) continue
            v = guard(gw, i)
            if (v == "accept") { kept = "gatewayOnLink " dst " via " num2ip(gw); break }
            if (v == "gatewayIsTunnelAddress") {
                kept = "tunnelOnLinkGateway " dst " via " num2ip(gw); break
            }
            if (v == "gatewayIsOwnAddress" || v == "gatewayIsNetworkAddress" ||
                v == "gatewayIsBroadcastAddress") {
                kept = "gatewayInLiveSubnet " dst " via " num2ip(gw) " why " v; break
            }
            # gatewayOffLink, and the verdicts about the LINK rather than the
            # next hop: try the next link.
        }
        if (kept != "") { keep(kept); next }

        # Swept. Reduced to DISTINCT (destination, netmask) pairs before any
        # action exists, because a destination printed in both scoped and
        # unscoped form would otherwise emit two byte-identical deletions.
        dstText = num2ip(dstAddr)
        maskText = (kind == "net") ? masktext(plen) : ""
        key = dstText "|" maskText
        if (!(key in seenKey)) {
            seenKey[key] = 1
            nKey++; keyOrder[nKey] = key
            keyDst[key] = dstText; keyMask[key] = maskText
            keyNifN[key] = 0
        }
        found = 0
        for (i = 1; i <= keyNifN[key]; i++) if (keyNif[key, i] == netif) { found = 1; break }
        if (!found) { keyNifN[key]++; keyNif[key, keyNifN[key]] = netif }
    }

    END {
        if (nIface == 0) {
            print "derive-expected: the snapshot flattened to no interfaces" > "/dev/stderr"
            exit 65
        }
        if (mode != "sweep") exit 0
        # FR-2.7: the cap bounds DISTINCT swept destinations, and exceeding it
        # aborts the SWEEP — so the expected deletion list is empty, not
        # truncated.
        if (nKey > cap) {
            printf "derive-expected: sweep cap exceeded (%d > %d); no deletions expected\n",
                   nKey, cap > "/dev/stderr"
            exit 0
        }
        for (i = 1; i <= nKey; i++) {
            key = keyOrder[i]
            if (keyMask[key] == "")
                base = "-n delete -host " keyDst[key]
            else
                base = "-n delete -net " keyDst[key] " -netmask " keyMask[key]
            print base
            # `route delete -net X` removes only the unscoped entry; the
            # interface-scoped duplicate survives it and still wins, which is
            # why both are emitted.
            for (j = 1; j <= keyNifN[key]; j++) print base " -ifscope " keyNif[key, j]
        }
    }
' - "$table"
