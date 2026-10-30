#!/bin/sh
#
# anyway-diag — answer one question, fast: is the network broken because of
# AnywayConnect, or because of something else on this machine?
#
#   sh scripts/anyway-diag.sh          # or, installed:  anyway-diag.sh
#   sh scripts/anyway-diag.sh --quick  # skip the unified-log queries (~4s total)
#
# WHY THIS EXISTS
#
# Twice now this laptop has been carried home asleep and woken up with a live
# Wi-Fi link, a good address, a good gateway, a good resolver — and no network.
# Both times the cure was a reboot. The second one (2026-10-21) was investigated
# read-only for a day, and it was NOT this app: Cisco Secure Client's socket
# filter extension failed 43,928 socket writes with errno 49 ("Can't assign
# requested address") from the instant of the lid-open wake until the reboot,
# with zero such errors before the sleep and zero after it. Routing, addressing
# and DNS were all healthy.
#
# Establishing that took a day of log archaeology. The whole point of this
# script is to say it in half a minute, so the next incident costs a coffee
# rather than a day — and so the answer is not a guess.
#
# WHAT IT IS NOT
#
# It is not a repair tool and it never will be. It reads; it never writes.
# Not one `route add/delete/change`, not one mutating `scutil`, not one
# `networksetup -set*`, not one `ifconfig` write, no `launchctl
# load/unload/bootout/kickstart`, no signals to the app, the daemon or
# openconnect, and nothing written outside its own evidence directory.
# It does not read ~/.config/anyway-connect/config.json at all — that file
# holds credentials. It needs no sudo and will never prompt for a password.
# Run it mid-incident without reading it first; that is what it is for.
#
# The one place it signals a process is its own bounded child, in `bounded()`
# below, which is how "never hang" is implemented. Nothing else.
#
# HOW THE ON-LINK CHECK WORKS
#
# Every "is this next hop on-link?" question is answered by `guard()` in the
# awk block below. It is this script's own check: twelve steps in a fixed
# order, each rejection with its own name, so a verdict always says which
# step refused the next hop. The route-table parsing finds its columns from
# the `netstat -rn` header row rather than assuming fixed positions, so a
# column macOS adds or reorders cannot shift every reading by one.

set -u

QUICK=0
WANT_PMSET=1
for arg in "$@"; do
    case "$arg" in
        --quick)   QUICK=1 ;;
        --no-pmset) WANT_PMSET=0 ;;
        -h|--help)
            cat <<'USAGE'
anyway-diag — read-only network triage for AnywayConnect

  --quick      skip the unified-log queries (extension errors, DNS telemetry).
               Much faster, but drops the single most useful discriminator.
  --no-pmset   skip `pmset -g log`, which is slow on a loaded machine.
  -h, --help   this text.

Writes an evidence bundle to ~/Library/Logs/anyway-connect/diag-<timestamp>/ and
prints its path. That location SURVIVES A REBOOT, which matters because the
standard recovery for most of what this script diagnoses is a reboot. The ten
most recent bundles are kept; older ones are pruned.
Exit status: 0 clean, 1 this app's fault, 2 not this app, 3 cannot tell.
USAGE
            exit 0 ;;
        *) echo "anyway-diag: unknown option $arg (try --help)" >&2; exit 64 ;;
    esac
done

# ── Evidence bundle ─────────────────────────────────────────────────────────
# Created before anything else, because the very first thing we do is rescue a
# log that is about to be destroyed. See immediately below.
#
# NOT /tmp. This script used to write here to /tmp/anyway-diag-<stamp>/, and on
# 2026-10-22 that cost the whole bundle: the script correctly diagnosed Cisco's
# socket filter extension and correctly recommended a reboot as the last resort,
# the user rebooted two minutes later, and the reboot took the evidence with it.
# The script diagnoses conditions whose standard recovery is a reboot, so it
# cannot store its evidence anywhere a reboot wipes — it would destroy its own
# output precisely when it had been most useful.
#
# ~/Library/Logs/<app>/ is the conventional macOS location for exactly this:
# user-readable, survives reboots, no privileges needed, and already where a
# user (or Console.app) goes looking for an application's logs. The alternative
# considered was ~/.local/state/; it would work equally well, but nothing else
# on a Mac looks there, and `open ~/Library/Logs/anyway-connect` is a thing the
# user can be told to do.
DIAG_ROOT="$HOME/Library/Logs/anyway-connect"
STAMP=$(date +%Y%m%d-%H%M%S)
BUNDLE="$DIAG_ROOT/diag-$STAMP"
mkdir -p "$BUNDLE" || { echo "anyway-diag: cannot create $BUNDLE" >&2; exit 70; }
chmod 700 "$BUNDLE" 2>/dev/null

# ── Retention ───────────────────────────────────────────────────────────────
# A persistent directory grows without bound, so keep the N most recent bundles
# and drop the rest. This runs on the user's own machine, in their home
# directory, where an over-broad delete would be unforgivable — so the deletion
# is deliberately paranoid rather than clever:
#
#   * the candidate list comes from a literal glob, never from `find`, never
#     from `ls`: the fixed prefix "diag-" plus the exact 8-then-6 digit stamp
#     shape this script itself writes. A directory named anything else in
#     DIAG_ROOT cannot match, and DIAG_ROOT itself is never a candidate.
#   * every path is re-validated immediately before `rm`, against DIAG_ROOT
#     plus one path component of that same shape.
#   * symlinks are skipped, so nothing can be deleted outside the tree.
#   * `rm -rf` is only ever handed one of those validated leaf paths. The
#     parent is never passed to rm, with or without a glob.
#
# Prints the basename of each directory it removed, one per line.
RETAIN=10
prune_bundles() {
    p_root=$1; p_keep=$2
    [ -d "$p_root" ] || return 0
    p_list=""
    for p_dir in "$p_root"/diag-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]; do
        # Also skips the unexpanded glob itself, which is not a directory.
        [ -d "$p_dir" ] || continue
        if [ -L "$p_dir" ]; then continue; fi
        p_list="$p_list$p_dir
"
    done
    p_total=$(printf '%s' "$p_list" | grep -c . 2>/dev/null)
    [ "${p_total:-0}" -gt "$p_keep" ] || return 0
    p_drop=$((p_total - p_keep))
    # The stamp sorts lexically exactly as it sorts chronologically, so the
    # oldest bundles are the first p_drop lines.
    printf '%s' "$p_list" | sort | head -n "$p_drop" | while read -r p_old; do
        # Re-validate the exact string about to be deleted: DIAG_ROOT, one
        # slash, and one component of the stamp shape. Belt and braces.
        p_base=${p_old##*/}
        [ "$p_old" = "$p_root/$p_base" ] || continue
        case "$p_base" in
            diag-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
            *) continue ;;
        esac
        [ -d "$p_old" ] || continue
        if [ -L "$p_old" ]; then continue; fi
        rm -rf -- "$p_old" 2>/dev/null && printf '%s\n' "$p_base"
    done
}
# Run now, after the new bundle exists, so the current run is counted and is
# always among the ones kept (its stamp is the highest). Captured rather than
# printed, because it belongs in the report, which does not exist yet.
PRUNED=$(prune_bundles "$DIAG_ROOT" "$RETAIN")
PRUNED_N=$(printf '%s' "$PRUNED" | grep -c . 2>/dev/null)

# URGENT, AND FIRST: ~/.config/anyway-connect/state/openconnect.log is
# TRUNCATED ON EVERY CONNECT (VPNRunner.truncateLog). If the user reconnects
# while reading this script's output — the obvious thing to try during an
# incident — the only timestamped record of the session that broke is gone.
# So it is copied before a single probe runs. The same goes, less urgently, for
# /var/log/anyway-connect-helper.log, which is the ONLY log in this system that
# survives a reboot.
OC_LOG="$HOME/.config/anyway-connect/state/openconnect.log"
[ -r "$OC_LOG" ] && cp "$OC_LOG" "$BUNDLE/openconnect.log" 2>/dev/null
[ -r /var/log/anyway-connect-helper.log ] \
    && cp /var/log/anyway-connect-helper.log "$BUNDLE/anyway-connect-helper.log" 2>/dev/null

# ── Bounded execution ───────────────────────────────────────────────────────
# macOS ships no timeout(1), and this script has to survive being run on a
# machine where the network is dead and half the system daemons are blocked on
# it. `pmset -g log` has previously taken longer than a 120-second shell here.
# So every command that could conceivably block goes through this: run it in
# the background, poll, and if the bound expires take it out and report
# "(timed out)" rather than hanging the user's terminal.
#
# bounded <seconds> <outfile> <command> [args...]   -> 0 ok, 124 timed out
bounded() {
    b_secs=$1; b_out=$2; shift 2
    : >"$b_out"
    "$@" >"$b_out" 2>/dev/null &
    b_pid=$!
    b_i=0
    b_lim=$((b_secs * 10))
    while [ "$b_i" -lt "$b_lim" ]; do
        kill -0 "$b_pid" 2>/dev/null || break
        sleep 0.1
        b_i=$((b_i + 1))
    done
    if kill -0 "$b_pid" 2>/dev/null; then
        # Only ever our own child, started three lines up. The whole group is
        # wrapped in `2>/dev/null` and not just the `kill`s: the SHELL prints
        # "Terminated: 15" when it reaps a signalled job, and that line would
        # otherwise land in the middle of the report.
        {
            kill -TERM "$b_pid"
            sleep 0.3
            kill -KILL "$b_pid"
            wait "$b_pid"
        } 2>/dev/null
        return 124
    fi
    wait "$b_pid" 2>/dev/null
    return 0
}

# ── Presentation ────────────────────────────────────────────────────────────
section() { printf '\n== %s\n' "$1"; }
line()    { printf '     %s\n' "$1"; }
concl()   { printf '  -> %s\n' "$1"; }

# Everything printed goes through this. Belt and braces: each collector already
# avoids the sensitive fields, and then this strips the two shapes that are easy
# to leak by accident anyway — link-layer addresses (from `arp`, and from the
# multicast/ARP rows in `netstat -rn`) and configd service UUIDs. The route
# table, the subnets and the gateways are NOT redacted: they are the evidence.
redact() {
    sed -l -E \
        -e 's/[0-9a-fA-F]{1,2}(:[0-9a-fA-F]{1,2}){5}/<mac-redacted>/g' \
        -e 's/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/<uuid-redacted>/g'
}

# ── The route/interface analyser ────────────────────────────────────────────
# One awk program, fed the raw `ifconfig -a` and `netstat -rn -f inet` captures
# as files. It emits a flat, greppable reduction that the shell then formats:
#
#   ABORT <reason>                                        fail-closed
#   IFACE <name> <up> <tunnel> <subnet-or-->              one per live link
#   DEF   <netif> <gateway> <scoped> <tunnel> <verdict>   one per default row
#   LEFT  <destination> <gateway> <netif>                 a route to nowhere
#   STAT  rows=.. defaults=.. leftover=.. kept=.. unparsable=..
#
# It is one program rather than a shell loop over 150 rows for a reason: a
# fork-per-row is slow, and more importantly the IPv4 arithmetic and the guard
# have to exist exactly once, or this script grows its own second opinion.
# shellcheck disable=SC2016  # single-quoted on purpose: this is an awk program,
# and `$1`, `$NF` and friends must reach awk, not the shell.
ANALYSE_AWK='
# ---- IPv4 arithmetic. Each function uses its own variable prefix because awk
#      has no locals and these do call each other.
function ip2n(s,   n, p, i, o, v) {
    n = split(s, p, ".")
    if (n != 4) return -1
    v = 0
    for (i = 1; i <= 4; i++) {
        o = p[i]
        if (o !~ /^[0-9]+$/) return -1
        if (length(o) < 1 || length(o) > 3) return -1
        if (length(o) > 1 && substr(o, 1, 1) == "0") return -1   # a leading zero is rejected: 010.0.1.1
        if (o + 0 > 255) return -1
        v = v * 256 + (o + 0)
    }
    return v
}
function n2ip(v,   a, b, c, d) {
    a = int(v / 16777216); b = int(v / 65536) % 256
    c = int(v / 256) % 256; d = v % 256
    return a "." b "." c "." d
}
function netof(a, bits,   d) {
    if (bits <= 0) return 0
    if (bits >= 32) return a
    d = 2 ^ (32 - bits)
    return int(a / d) * d
}
function bcastof(a, bits,   d) {
    if (bits <= 0) return 4294967295
    if (bits >= 32) return a
    d = 2 ^ (32 - bits)
    return int(a / d) * d + d - 1
}
function hex2n(h,   v, i, c, digits) {
    sub(/^0[xX]/, "", h)
    digits = "0123456789abcdef"
    h = tolower(h)
    if (h == "") return -1
    v = 0
    for (i = 1; i <= length(h); i++) {
        c = index(digits, substr(h, i, 1)) - 1
        if (c < 0) return -1
        v = v * 16 + c
    }
    return v
}
# Prefix length of a netmask, or -1 if the mask is not contiguous. Same
# judgement as NetProbe.interfaces(): a non-contiguous mask has no prefix
# length, and reconstructing one from the bit count would silently widen or
# narrow the subnet the guard then compares against, so the address is dropped.
function maskbits(m,   b) {
    if (m == 0) return 0
    for (b = 32; b >= 1; b--) if (m == 4294967296 - 2 ^ (32 - b)) return b
    return -1
}
function tunnelish(name, p2p) {
    if (p2p) return 1
    return (name ~ /^(utun|ppp|ipsec|gif|stf)/) ? 1 : 0
}

# ---- The guard. The ORDER IS FIXED and must not be tidied: the reason
#      returned for a given input is what this script branches on below.
function guard(g, t,   gn, i, nm, j, mi, mp, pb) {
    # 1. the interface name (PrivilegedValidation.isValidInterface + IFNAMSIZ-1)
    if (t == "" || length(t) > 15 || t !~ /^[0-9a-z]+$/) return "malformedInterfaceName"
    # 2. strict dotted quad
    gn = ip2n(g)
    if (gn < 0) return "malformedGateway"
    # 3. neither of these is a next hop
    if (gn == 0 || gn == 4294967295) return "unspecifiedGateway"
    # 4/5. absent vs present-but-un-addressed are DIFFERENT answers
    if (!(t in ifseen)) return "targetInterfaceMissing"
    if (nad[t] + 0 == 0) return "targetInterfaceUnconfigured"
    # 6. a tunnel is never a legitimate target for a physical default
    if (istun[t]) return "targetInterfaceIsTunnel"
    # 7. a down link cannot carry what we would point at it
    if (!ifup[t]) return "targetInterfaceDown"
    # 8. the gateway is some tunnels OWN address (the observed vpnc-script bug)
    for (i = 1; i <= nif; i++) {
        nm = iforder[i]
        if (!istun[nm]) continue
        for (j = 1; j <= nad[nm]; j++) if (adv[nm, j] == gn) return "gatewayIsTunnelAddress"
    }
    # 9. the targets own address, any of them
    for (j = 1; j <= nad[t]; j++) if (adv[t, j] == gn) return "gatewayIsOwnAddress"
    # 10. on-link for ANY (address, prefix) the link carries
    mi = 0
    for (j = 1; j <= nad[t]; j++) {
        pb = adp[t, j]
        if (pb < 0 || pb > 32) continue
        if (netof(gn, pb) == netof(adv[t, j], pb)) { mi = j; break }
    }
    if (mi == 0) return "gatewayOffLink"
    # 11. skipped at /31 and /32, where neither address exists (RFC 3021)
    mp = adp[t, mi]
    if (mp <= 30) {
        if (gn == netof(adv[t, mi], mp)) return "gatewayIsNetworkAddress"
        if (gn == bcastof(adv[t, mi], mp)) return "gatewayIsBroadcastAddress"
    }
    return "accept"
}

# The reachability ladder: a gateway is alive if the guard accepts
# it for ANY live, addressed, non-tunnel link, and "on a tunnel" if the guard
# stops at step 8. Anything else is a route to nowhere. Note that a VANISHED
# utun`s address falls through to nowhere, which is the intended answer and the
# common case after a dead tunnel.
function reachable(g,   i, nm, v) {
    for (i = 1; i <= nif; i++) {
        nm = iforder[i]
        if (istun[nm] || !ifup[nm] || nad[nm] + 0 == 0) continue
        v = guard(g, nm)
        if (v == "accept") return "onlink:" nm
        if (v == "gatewayIsTunnelAddress") return "tunnel"
    }
    return "nowhere"
}

BEGIN {
    # ---- ifconfig -a -> the interface snapshot ----------------------------
    nif = 0
    cur = ""
    while ((getline ln < IFF) > 0) {
        if (ln ~ /^[0-9a-z]+:[ \t]*flags=/) {
            cur = ln; sub(/:.*/, "", cur)
            lt = index(ln, "<"); gt = index(ln, ">")
            fl = (lt > 0 && gt > lt) ? "," substr(ln, lt + 1, gt - lt - 1) "," : ","
            iforder[++nif] = cur
            ifseen[cur] = 1
            # IFF_UP && IFF_RUNNING, exactly as NetProbe computes isUp.
            ifup[cur] = (index(fl, ",UP,") > 0 && index(fl, ",RUNNING,") > 0) ? 1 : 0
            iflo[cur] = (index(fl, ",LOOPBACK,") > 0) ? 1 : 0
            istun[cur] = tunnelish(cur, (index(fl, ",POINTOPOINT,") > 0) ? 1 : 0)
            nad[cur] = 0
            continue
        }
        if (cur == "" ) continue
        # ifconfig indents address lines with a TAB, so splitting on runs of
        # whitespace without stripping first puts an empty string in f[1] and
        # every address is silently dropped -- which reads as
        # "interfaceSnapshotUnusable" and condemns the whole route analysis.
        sub(/^[ \t]+/, "", ln)
        n = split(ln, f, /[ \t]+/)
        if (n < 3 || f[1] != "inet") continue
        a = ip2n(f[2])
        if (a < 0) continue
        mask = ""
        for (i = 3; i < n; i++) if (f[i] == "netmask") { mask = f[i + 1]; break }
        if (mask == "") continue
        mv = (index(mask, ".") > 0) ? ip2n(mask) : hex2n(mask)
        if (mv < 0) continue
        bits = maskbits(mv)
        if (bits < 0) continue
        j = ++nad[cur]
        adv[cur, j] = a
        adp[cur, j] = bits
    }
    close(IFF)

    # (d-double-prime): an empty snapshot cannot prove anything on-link, and
    # would condemn the entire route table. Fail closed instead.
    live = 0
    for (i = 1; i <= nif; i++) {
        nm = iforder[i]
        if (!istun[nm] && ifup[nm] && nad[nm] + 0 > 0) live++
    }
    if (live == 0) { print "ABORT interfaceSnapshotUnusable"; exit }

    # ---- netstat -rn -f inet -> rows --------------------------------------
    # Column indices are DERIVED FROM THE HEADER, never assumed positional:
    # older netstat layouts carry Refs/Use between Flags and Netif, and reading
    # Netif as field 4 there makes every netif a number -- no utun default is
    # ever recognised and every scoped deletion aims at -ifscope 0. If any of
    # the four columns is missing we abort rather than guess.
    ci = cg = cf = cn = 0
    rows = ndef = nleft = nkept = nunp = 0
    while ((getline ln < RT) > 0) {
        if (ci == 0) {
            if (ln !~ /^Destination/) continue
            n = split(ln, f, /[ \t]+/)
            for (i = 1; i <= n; i++) {
                if (f[i] == "Destination") ci = i
                else if (f[i] == "Gateway") cg = i
                else if (f[i] == "Flags")   cf = i
                else if (f[i] == "Netif")   cn = i
            }
            if (ci == 0 || cg == 0 || cf == 0 || cn == 0) {
                print "ABORT routeTableUnreadable"; exit
            }
            maxc = ci; if (cg > maxc) maxc = cg
            if (cf > maxc) maxc = cf
            if (cn > maxc) maxc = cn
            continue
        }
        n = split(ln, f, /[ \t]+/)
        if (n < maxc) continue
        dst = f[ci]; gw = f[cg]; flags = f[cf]; netif = f[cn]
        if (dst == "" || netif == "") continue
        rows++
        netifseen[netif] = 1
        # RTF_IFSCOPE is the capital I. The lowercase i is RTF_IFREF and means
        # something else entirely.
        scoped = (index(flags, "I") > 0) ? 1 : 0
        gwn = ip2n(gw)

        if (dst == "default") {
            ndef++
            tun = (netif in ifseen) ? istun[netif] : tunnelish(netif, 0)
            v = tun ? "tunnelDefault" : guard(gw, netif)
            print "DEF", netif, gw, scoped, tun, v
            continue
        }

        # ---- the leftover-route check, first match decides ---------------
        # A gateway that is not an IPv4 literal (link#N, a MAC, an -interface
        # route) is the LAN on-link row: kept, never counted.
        if (gwn < 0) { nkept++; continue }
        if (netif == "lo0") { nkept++; continue }

        # Canonicalise the destination. netstat abbreviates
        # by dropping trailing zero octets, and anything we cannot name exactly
        # is never counted as leftover -- a destination we cannot name cannot be
        # named to `route delete` either.
        pfx = -1; base = dst
        if (index(dst, "/") > 0) {
            split(dst, sp, "/")
            base = sp[1]; pfx = sp[2]
            if (pfx !~ /^[0-9]+$/ || pfx + 0 > 32) { nunp++; continue }
            pfx = pfx + 0
            no = split(base, bo, ".")
            while (no < 4) { base = base ".0"; no++ }
            dn = ip2n(base)
            if (dn < 0 || netof(dn, pfx) != dn) { nunp++; continue }
            dtext = n2ip(dn) "/" pfx
        } else {
            no = split(dst, bo, ".")
            if (no == 4) {
                dn = ip2n(dst)
                if (dn < 0) { nunp++; continue }
                dtext = n2ip(dn); pfx = 32
            } else if (no >= 1 && no <= 3) {
                # The class mask netstat omits. Only here is the prefix INFERRED
                # from the octet count, so only here is it cross-checked.
                pfx = no * 8
                base = dst
                while (no < 4) { base = base ".0"; no++ }
                dn = ip2n(base)
                if (dn < 0 || netof(dn, pfx) != dn) { nunp++; continue }
                dtext = n2ip(dn) "/" pfx
            } else { nunp++; continue }
        }

        # Loopback / multicast / link-local / all-ones: never ours, never counted.
        if (dn >= 2130706432 && dn < 2147483648) { nkept++; continue }   # 127/8
        if (dn >= 3758096384 && dn < 4026531840) { nkept++; continue }   # 224/4
        if (dn >= 2851995648 && dn < 2852061184) { nkept++; continue }   # 169.254/16
        if (dn == 4294967295) { nkept++; continue }

        r = reachable(gw)
        if (r == "nowhere") { nleft++; print "LEFT", dtext, gw, netif }
        else nkept++
    }
    close(RT)
    if (ci == 0) { print "ABORT routeTableUnreadable"; exit }

    # The link list is emitted here, AFTER the route table has been read, so it
    # can be filtered by relevance. This machine has fourteen up-but-un-addressed
    # links (anpi0-2, en1-6, bridge0, ap1, awdl0, llw0) and eight dormant system
    # utuns; listing all of them buries the two or three links the routing
    # question is actually about. So: every link with an IPv4, plus any
    # un-addressed link the route table points at — which is precisely the
    # un-addressed link that could matter (a tunnel still being routed to, or a
    # physical link mid-DHCP that a default still names).
    for (i = 1; i <= nif; i++) {
        nm = iforder[i]
        if (!ifup[nm]) continue
        if (nad[nm] + 0 == 0 && !(nm in netifseen)) continue
        if (nad[nm] + 0 == 0) s = "- (no IPv4)"
        else s = n2ip(netof(adv[nm, 1], adp[nm, 1])) "/" adp[nm, 1]
        print "IFACE", nm, ifup[nm], istun[nm], s
    }
    print "STAT", "rows=" rows, "defaults=" ndef, "leftover=" nleft, \
          "kept=" nkept, "unparsable=" nunp
}
'

# ── Collectors ──────────────────────────────────────────────────────────────
ifconfig -a >"$BUNDLE/ifconfig.txt" 2>/dev/null
netstat -rn -f inet >"$BUNDLE/netstat-rn.txt" 2>/dev/null
scutil --dns >"$BUNDLE/scutil-dns.txt" 2>/dev/null
# `list` on stdin and nothing else. scutil is perfectly capable of removing
# these keys; it is never asked to.
printf 'list\n' | scutil >"$BUNDLE/scutil-list.txt" 2>/dev/null
bounded 5 "$BUNDLE/systemextensions.txt" systemextensionsctl list

# The archived captures get the same redaction as the printed report, BEFORE
# anything parses them — the bundle is meant to be attachable, `netstat -rn`
# carries link-layer addresses in its ARP and multicast rows, and `scutil list`
# is wall-to-wall configd service UUIDs. Redacting first also means the analyser
# sees exactly the bytes that were archived, so a disagreement between the
# report and the bundle is impossible. A redacted gateway stops parsing as an
# IPv4 literal, which is the same classification ("on-link, not via a router")
# a MAC gateway had anyway.
for cap in ifconfig.txt netstat-rn.txt scutil-dns.txt scutil-list.txt \
           systemextensions.txt; do
    [ -s "$BUNDLE/$cap" ] || continue
    redact <"$BUNDLE/$cap" >"$BUNDLE/$cap.red" 2>/dev/null \
        && mv "$BUNDLE/$cap.red" "$BUNDLE/$cap"
done

awk -v IFF="$BUNDLE/ifconfig.txt" -v RT="$BUNDLE/netstat-rn.txt" \
    "$ANALYSE_AWK" </dev/null >"$BUNDLE/analysis.txt" 2>/dev/null

# ── The one unified-log query ───────────────────────────────────────────────
# Sections 6 and 7 both need log data, and `log show` is by far the most
# expensive thing this script does — several seconds of real CPU each time. So
# there is ONE query covering every process either section cares about, counted
# two different ways afterwards. Someone running this has a machine on fire;
# halving the wait is worth the wider predicate.
#
# The window is short on purpose. The incident's rate was 1,000-3,000 errno-49
# failures per MINUTE, so five minutes is ample to see a storm, and a longer
# window makes the query slower precisely when the machine is least able to
# afford it. Widen it here if a post-mortem needs more.
EXT_WINDOW="5m"
UNIFIED_OK=0
if [ "$QUICK" -eq 0 ]; then
    if bounded 40 "$BUNDLE/.unified.log" log show --last "$EXT_WINDOW" --predicate \
       'process CONTAINS "acsockext" OR process CONTAINS "falcon" OR process CONTAINS "Falcon" OR process CONTAINS "reveal" OR process CONTAINS "fortidlp" OR process CONTAINS "FortiDLP" OR process CONTAINS "filter-sysex" OR process CONTAINS "nesessionmanager" OR process CONTAINS "neagent" OR process == "mDNSResponder" OR process == "symptomsd"'
    then
        UNIFIED_OK=1
    fi
fi

# ══════════════════════════════════════════════════════════════════════════
main() {

printf 'anyway-diag — read-only network triage for AnywayConnect\n'
printf '%s\n' '----------------------------------------------------------------'
printf 'This output is REDACTED so it can be pasted into a bug report. Omitted:\n'
printf '  the --servercert pin and anything from config.json (never read at all),\n'
printf '  MAC addresses, configd service UUIDs, the Wi-Fi SSID, and the names of\n'
printf '  the /etc/resolver files and search domains (counts are reported instead).\n'
printf 'Kept, because they are the evidence: interface addresses, subnets,\n'
printf 'gateways, route destinations and resolver addresses.\n'
printf 'Nothing here was modified. No sudo was used.\n'

# ── 1. Identity and timing ────────────────────────────────────────────────
section "1. Identity and timing"
line "now:        $(date '+%Y-%m-%d %H:%M:%S %z')"
line "host os:    $(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null) ($(uname -m))"

# `{ sec = 1761098974, usec = 0 } Wed Oct 22 ...` — anchored on the brace,
# because a greedy `.*sec = ` matches `usec = ` and reports a 1970 boot time.
BOOTSEC=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ *sec = \([0-9]*\).*/\1/p')
if [ -n "${BOOTSEC:-}" ]; then
    line "booted:     $(date -r "$BOOTSEC" '+%Y-%m-%d %H:%M:%S') ($(( ( $(date +%s) - BOOTSEC ) / 3600 ))h $(( ( ( $(date +%s) - BOOTSEC ) % 3600 ) / 60 ))m ago)"
else
    line "booted:     (unavailable)"
fi

# The carry-home signature is a LONG sleep followed by a recent wake. pmset is
# the only source for that, and it is also the slowest thing here: on a loaded
# machine `pmset -g log` has taken longer than a two-minute shell. So it is
# bounded, and only the sleep/wake lines are kept in the bundle.
SLEEP_AT=""; WAKE_AT=""; SLEPT_FOR=""
if [ "$WANT_PMSET" -eq 1 ]; then
    # 12 seconds, and no apology if it expires. `pmset -g log` has no filter
    # option — it renders the entire power log (45,000 lines here, 6-8 seconds
    # of CPU on a quiet machine) and has previously outlasted a two-minute
    # shell on this one. It is also the least load-bearing section in the
    # script: it reports the carry-home PATTERN, and no verdict depends on it.
    # So it gets the shortest leash of anything here.
    if bounded 12 "$BUNDLE/.pmset.raw" pmset -g log; then
        # pmset's fourth whitespace field is the event type. Keyed on that
        # rather than on the message text, so a maintenance `DarkWake` is never
        # mistaken for the lid-open `Wake` that is the signature we want.
        awk '$4 == "Sleep" || $4 == "Wake" || $4 == "DarkWake"' "$BUNDLE/.pmset.raw" \
            2>/dev/null | tail -40 >"$BUNDLE/pmset-sleepwake.txt"
        # The pair that matters is "the last full wake, and the sleep it woke
        # FROM" — not the last sleep in the file, which is usually a later
        # maintenance sleep and makes every gap look like zero minutes.
        PMPAIR=$(awk '$4 == "Sleep" { s = $1 " " $2 }
                      $4 == "Wake"  { w = $1 " " $2; ws = s }
                      END { print w "|" ws }' "$BUNDLE/.pmset.raw" 2>/dev/null)
        WAKE_AT=${PMPAIR%%|*}
        SLEEP_AT=${PMPAIR##*|}
        rm -f "$BUNDLE/.pmset.raw"
        if [ -n "$WAKE_AT" ]; then
            line "last wake:  $WAKE_AT"
            W=$(date -j -f '%Y-%m-%d %H:%M:%S' "$WAKE_AT" +%s 2>/dev/null)
            [ -n "${W:-}" ] && line "            ($(( ( $(date +%s) - W ) / 60 )) minutes ago)"
        else
            line "last wake:  (none found in pmset log)"
        fi
        if [ -n "$SLEEP_AT" ]; then
            line "slept at:   $SLEEP_AT"
            S=$(date -j -f '%Y-%m-%d %H:%M:%S' "$SLEEP_AT" +%s 2>/dev/null)
            if [ -n "${S:-}" ] && [ -n "${W:-}" ] && [ "$W" -gt "$S" ]; then
                SLEPT_FOR=$(( (W - S) / 60 ))
                line "            asleep for $SLEPT_FOR minutes before that wake"
            fi
        fi
    else
        line "sleep/wake: (timed out — pmset -g log did not finish in 12s;"
        line "            pass --no-pmset to skip it. No verdict depends on this.)"
    fi
else
    line "sleep/wake: (skipped, --no-pmset)"
fi

if [ -n "${W:-}" ] && [ "$(( ( $(date +%s) - W ) / 60 ))" -le 30 ] \
   && [ -n "$SLEPT_FOR" ] && [ "$SLEPT_FOR" -ge 60 ]; then
    concl "woke $(( ( $(date +%s) - W ) / 60 ))m ago after a ${SLEPT_FOR}m sleep — this is the carry-home pattern both incidents followed."
else
    concl "no recent long-sleep-then-wake transition stands out."
fi

# ── 2. This app's state ───────────────────────────────────────────────────
section "2. AnywayConnect's own state"

APP_BUNDLE_V=""
for cand in /Applications/AnywayConnect.app "$HOME/Applications/AnywayConnect.app"; do
    [ -d "$cand" ] || continue
    APP_BUNDLE_V=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
                   "$cand/Contents/Info.plist" 2>/dev/null)
    APP_SHORT_V=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
                  "$cand/Contents/Info.plist" 2>/dev/null)
    line "installed:  $cand  ${APP_SHORT_V:-?} (build ${APP_BUNDLE_V:-?})"
    break
done
[ -n "$APP_BUNDLE_V" ] || line "installed:  no AnywayConnect.app found in /Applications or ~/Applications"

APP_PID=$(pgrep -x AnywayConnect 2>/dev/null | head -1)
if [ -n "${APP_PID:-}" ]; then
    APP_PATH=$(ps -p "$APP_PID" -o comm= 2>/dev/null)
    line "app:        running pid $APP_PID since $(ps -p "$APP_PID" -o lstart= 2>/dev/null)"
    line "            $APP_PATH"
else
    line "app:        not running"
fi

# The daemon's identity matters as much as its liveness: `launchctl print` is
# read-only and names the bundle the running daemon actually came out of, which
# is how you tell a stale daemon from the one the installed app would register.
HELPER_LABEL="me.kairyu.anywayconnect.privhelper"
bounded 5 "$BUNDLE/launchctl-print.txt" launchctl print "system/$HELPER_LABEL"
redact <"$BUNDLE/launchctl-print.txt" >"$BUNDLE/launchctl-print.red" 2>/dev/null \
    && mv "$BUNDLE/launchctl-print.red" "$BUNDLE/launchctl-print.txt"
HELPER_PID=$(pgrep -f "$HELPER_LABEL" 2>/dev/null | head -1)
if [ -n "${HELPER_PID:-}" ]; then
    line "daemon:     running pid $HELPER_PID since $(ps -p "$HELPER_PID" -o lstart= 2>/dev/null)"
    HELPER_PV=$(sed -n 's/.*parent bundle version *= *//p' "$BUNDLE/launchctl-print.txt" 2>/dev/null | head -1)
    HELPER_STATE=$(sed -n 's/^[[:space:]]*state *= *//p' "$BUNDLE/launchctl-print.txt" 2>/dev/null | head -1)
    line "            launchd state ${HELPER_STATE:-?}, parent bundle version ${HELPER_PV:-?}"
    if [ -n "$APP_BUNDLE_V" ] && [ -n "${HELPER_PV:-}" ] && [ "$APP_BUNDLE_V" != "$HELPER_PV" ]; then
        line "            MISMATCH: the installed app is $APP_BUNDLE_V but the running daemon came from $HELPER_PV"
    fi
else
    line "daemon:     not running (it is launched on demand, so this is normal while idle)"
fi

# openconnect's PARENT is load-bearing, not trivia: a tunnel started under a
# `sudo` chain cannot be stopped by the privileged daemon, so a stale sudo-born
# openconnect is a wedge the app cannot clear by itself.
OC_PID=$(pgrep -x openconnect 2>/dev/null | head -1)
OC_RUNNING=0
OC_PARENTAGE="none"
if [ -n "${OC_PID:-}" ]; then
    OC_RUNNING=1
    OC_PPID=$(ps -p "$OC_PID" -o ppid= 2>/dev/null | tr -d ' ')
    OC_PARENT=$(ps -p "${OC_PPID:-1}" -o comm= 2>/dev/null)
    line "openconnect: running pid $OC_PID since $(ps -p "$OC_PID" -o lstart= 2>/dev/null)"
    line "            parent pid ${OC_PPID:-?}: ${OC_PARENT:-?}"
    case "${OC_PARENT:-}" in
        *privhelper*) OC_PARENTAGE="daemon"
            line "            parented to the privileged daemon — the daemon can stop it" ;;
        *sudo*|*anyway-root-helper*) OC_PARENTAGE="sudo"
            line "            parented to a SUDO chain — the privileged daemon cannot stop this tunnel" ;;
        *) OC_PARENTAGE="other"
            line "            parent is neither the daemon nor a sudo chain; attribution unclear" ;;
    esac
else
    line "openconnect: not running"
fi

f=/var/run/anyway-connect.pid
if [ -e "$f" ]; then
    line "state file: $f  ($(wc -c <"$f" | tr -d ' ') bytes, $(date -r "$f" '+%Y-%m-%d %H:%M:%S'))"
    cp "$f" "$BUNDLE/$(basename "$f")" 2>/dev/null
else
    line "state file: $f  ABSENT"
fi

PIDFILE_PID=""
[ -r /var/run/anyway-connect.pid ] && PIDFILE_PID=$(tr -d ' \n' </var/run/anyway-connect.pid 2>/dev/null)
if [ -n "$PIDFILE_PID" ] && [ "$OC_RUNNING" -eq 0 ]; then
    line "            the pid file names $PIDFILE_PID but no openconnect is alive — stale pid file"
fi

if [ "$OC_RUNNING" -eq 1 ]; then
    concl "a tunnel is up (openconnect pid $OC_PID, parentage: $OC_PARENTAGE)."
else
    concl "no tunnel is up; anything VPN-shaped left in the route table or in configd is leftover."
fi

# ── 3. Routing correctness ────────────────────────────────────────────────
section "3. Routing — default routes and leftovers"

ABORT=$(sed -n 's/^ABORT //p' "$BUNDLE/analysis.txt" 2>/dev/null | head -1)
STALE_DEFAULTS=0
USABLE_DEFAULTS=0
TUNNEL_DEFAULTS=0
TUNNEL_DEFAULT_IFS=""
LEFTOVER=0

if [ -n "${ABORT:-}" ]; then
    line "could not analyse: $ABORT"
    concl "ROUTING INCONCLUSIVE — the route table or the interface snapshot could not be read."
else
    sed -n 's/^IFACE //p' "$BUNDLE/analysis.txt" | while read -r inm iup itun isub; do
        [ "$iup" = "1" ] || continue
        if [ "$itun" = "1" ]; then
            line "link:       $inm  $isub  (tunnel)"
        else
            line "link:       $inm  $isub"
        fi
    done

    while read -r netif gw scoped tun verdict; do
        [ -n "${netif:-}" ] || continue
        SCOPE_NOTE="unscoped"
        [ "$scoped" = "1" ] && SCOPE_NOTE="-ifscope $netif"
        if [ "$tun" = "1" ]; then
            TUNNEL_DEFAULTS=$((TUNNEL_DEFAULTS + 1))
            TUNNEL_DEFAULT_IFS="$TUNNEL_DEFAULT_IFS $netif"
            line "default via $gw dev $netif [$SCOPE_NOTE] — tunnel default"
            continue
        fi
        case "$verdict" in
            accept)
                if [ "$scoped" = "1" ]; then
                    line "default via $gw dev $netif [$SCOPE_NOTE] — next hop on-link, but SCOPED: it does not serve unbound traffic"
                else
                    USABLE_DEFAULTS=$((USABLE_DEFAULTS + 1))
                    line "default via $gw dev $netif [$SCOPE_NOTE] — next hop on-link: USABLE"
                fi ;;
            targetInterfaceDown)
                line "default via $gw dev $netif [$SCOPE_NOTE] — link down; kept, not evidence the route is dead" ;;
            targetInterfaceMissing|targetInterfaceUnconfigured)
                line "default via $gw dev $netif [$SCOPE_NOTE] — target not addressed (mid-DHCP?); kept, the snapshot cannot tell" ;;
            malformedGateway|malformedInterfaceName)
                line "default via $gw dev $netif [$SCOPE_NOTE] — no IPv4 next hop (an -interface default); kept" ;;
            *)
                STALE_DEFAULTS=$((STALE_DEFAULTS + 1))
                line "default via $gw dev $netif [$SCOPE_NOTE] — BLACKHOLE: $verdict" ;;
        esac
    done <<EOF
$(sed -n 's/^DEF //p' "$BUNDLE/analysis.txt")
EOF

    LEFTOVER=$(sed -n 's/^STAT .*leftover=\([0-9]*\).*/\1/p' "$BUNDLE/analysis.txt")
    LEFTOVER=${LEFTOVER:-0}
    ROWS=$(sed -n 's/^STAT rows=\([0-9]*\).*/\1/p' "$BUNDLE/analysis.txt")
    UNPARSABLE=$(sed -n 's/^STAT .*unparsable=\([0-9]*\).*/\1/p' "$BUNDLE/analysis.txt")
    line ""
    line "route table: ${ROWS:-?} IPv4 rows, ${UNPARSABLE:-0} unparsable (never acted on)"
    line "routes whose gateway is on-link for NO live interface: $LEFTOVER"
    if [ "$LEFTOVER" -gt 0 ]; then
        sed -n 's/^LEFT //p' "$BUNDLE/analysis.txt" | head -15 \
            | while read -r d g n; do line "    $d via $g dev $n"; done
        [ "$LEFTOVER" -gt 15 ] && line "    ... and $((LEFTOVER - 15)) more (all of them are in the bundle)"
        line "  this is the leftover-route signature from the 2026-10-13 incident: VPN"
        line "  split-routes pointing at a gateway that existed on the network we left."
    fi

    # The classic wedge, stated separately because it is the one shape that is
    # unambiguously ours: traffic aimed down a tunnel with nothing on the end.
    if [ "$TUNNEL_DEFAULTS" -gt 0 ] && [ "$OC_RUNNING" -eq 0 ]; then
        line "  !! default route(s) via$TUNNEL_DEFAULT_IFS with NO openconnect running."
    fi

    if [ "$STALE_DEFAULTS" -gt 0 ]; then
        concl "ROUTING BROKEN — $STALE_DEFAULTS default route(s) point at a next hop that provably cannot carry traffic."
    elif [ "$TUNNEL_DEFAULTS" -gt 0 ] && [ "$OC_RUNNING" -eq 0 ]; then
        concl "ROUTING BROKEN — the default route goes down a tunnel and no tunnel process is alive."
    elif [ "$USABLE_DEFAULTS" -eq 0 ] && [ "$TUNNEL_DEFAULTS" -eq 0 ]; then
        concl "ROUTING BROKEN — there is no usable unscoped default route at all."
    elif [ "$LEFTOVER" -gt 0 ]; then
        concl "default routing is correct; $LEFTOVER leftover route(s) blackhole only those destinations."
    else
        concl "routing is correct: a usable default, and every gateway on-link somewhere."
    fi
fi

# ── 4. DNS correctness ───────────────────────────────────────────────────
section "4. DNS configuration"

R1=$(awk '/^resolver #1$/{f=1;next} /^resolver #/{f=0} f' "$BUNDLE/scutil-dns.txt" 2>/dev/null)
R1_NS=$(printf '%s\n' "$R1" | sed -n 's/.*nameserver\[[0-9]*\] : //p' | tr '\n' ' ' | sed 's/ *$//')
R1_SD=$(printf '%s\n' "$R1" | grep -c 'search domain\[' 2>/dev/null)
if [ -n "${R1_NS:-}" ]; then
    line "resolver #1 nameservers: $R1_NS"
    line "resolver #1 search domains: ${R1_SD:-0} (names omitted — corporate)"
else
    line "resolver #1: NO NAMESERVERS (nothing to ask)"
fi

UTUN_KEYS=$(grep -cE 'State:/Network/Service/utun[0-9]{1,3}/(IPv4|DNS)$' "$BUNDLE/scutil-list.txt" 2>/dev/null)
UTUN_KEYS=${UTUN_KEYS:-0}
if [ "$UTUN_KEYS" -gt 0 ]; then
    grep -oE 'State:/Network/Service/utun[0-9]{1,3}/(IPv4|DNS)$' "$BUNDLE/scutil-list.txt" 2>/dev/null \
        | while read -r k; do line "configd key: $k"; done
    if [ "$OC_RUNNING" -eq 1 ]; then
        line "            expected: a tunnel is up, and this is how its resolver is published."
    else
        line "            NOT expected: no tunnel is running, so this is the OverridePrimary"
        line "            hijack left behind — DNS is pointed at resolvers reachable only"
        line "            through a tunnel that no longer exists."
    fi
else
    line "configd:    no State:/Network/Service/utun*/{IPv4,DNS} keys — no DNS override present"
fi

# Two pre-existing hazards on this machine that are NOT from this app. They are
# called out because a user who finds them while hunting a VPN problem will
# otherwise reasonably suspect the VPN client. The app writes neither: it has
# no `networksetup -setdnsservers` or `-setsearchdomains` call anywhere
# (verify-bundle.sh asserts the vendored vpnc-script's two calls stay guarded).
RESOLVER_N=$(find /etc/resolver -type f -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
if [ "${RESOLVER_N:-0}" -gt 0 ]; then
    line "PRE-EXISTING, not ours: $RESOLVER_N file(s) in /etc/resolver/ pin corporate"
    line "            domains to VPN-only resolvers. Root-owned, MDM-placed, survive"
    line "            reboots. Those domains are unresolvable whenever the VPN is down."
fi
WIFI_SVC=$(networksetup -listallnetworkservices 2>/dev/null | grep -i 'wi-fi' | head -1)
if [ -n "${WIFI_SVC:-}" ]; then
    SD_RAW=$(networksetup -getsearchdomains "$WIFI_SVC" 2>/dev/null)
    SD_IPS=$(printf '%s\n' "$SD_RAW" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
             | tr '\n' ' ' | sed 's/ *$//')
    if [ -n "${SD_IPS:-}" ]; then
        line "PRE-EXISTING, not ours: the Wi-Fi service's SearchDomains contain IP"
        line "            literals ($SD_IPS). Those are addresses in a list of domain"
        line "            suffixes — a misconfiguration that generates junk lookups."
    fi
fi

if [ -z "${R1_NS:-}" ]; then
    concl "DNS BROKEN — resolver #1 has no nameserver."
elif [ "$UTUN_KEYS" -gt 0 ] && [ "$OC_RUNNING" -eq 0 ]; then
    concl "DNS BROKEN — a tunnel DNS override is in configd with no tunnel behind it."
else
    concl "DNS configuration is coherent for the current tunnel state."
fi

# ── 5. Does data actually flow ───────────────────────────────────────────
section "5. Does data actually flow (bounded probes)"

# Each probe is reported on its own line, because WHICH one fails is the whole
# answer: gateway-but-no-IP and IP-but-no-DNS are different faults at different
# layers, and lumping them into "no internet" is what sends people to a reboot.
ACTIVE_GW=$(route -n get default 2>/dev/null | sed -n 's/^[[:space:]]*gateway: //p' | head -1)
ACTIVE_IF=$(route -n get default 2>/dev/null | sed -n 's/^[[:space:]]*interface: //p' | head -1)
line "active default: ${ACTIVE_GW:-none} dev ${ACTIVE_IF:-none}  (what the kernel picks)"

# The physical gateway, i.e. the one that has to answer for anything to work at
# all. Taken from the analysis so it is the same row the guard judged.
PHYS_GW=$(sed -n 's/^DEF //p' "$BUNDLE/analysis.txt" 2>/dev/null \
          | awk '$4 == 0 && $5 == "accept" { print $2; exit }')
[ -z "${PHYS_GW:-}" ] && PHYS_GW=$(sed -n 's/^DEF //p' "$BUNDLE/analysis.txt" 2>/dev/null \
          | awk '$4 == 0 { print $2; exit }')

GW_OK=unknown
if [ -n "${PHYS_GW:-}" ]; then
    ARP_HIT=$(arp -n "$PHYS_GW" 2>/dev/null | grep -c 'at .* on ')
    if [ "${ARP_HIT:-0}" -gt 0 ]; then
        line "arp $PHYS_GW: resolved (the link and L2 are alive)"
    else
        line "arp $PHYS_GW: no entry"
    fi
    if bounded 4 "$BUNDLE/.ping-gw" ping -c1 -t2 -n "$PHYS_GW"; then
        if grep -q '1 packets received' "$BUNDLE/.ping-gw" 2>/dev/null; then
            GW_OK=yes; line "ping $PHYS_GW (physical gateway): reply"
        else
            GW_OK=no;  line "ping $PHYS_GW (physical gateway): NO reply"
        fi
    else
        GW_OK=no; line "ping $PHYS_GW (physical gateway): (timed out)"
    fi
    rm -f "$BUNDLE/.ping-gw"
else
    line "ping: no physical default gateway to probe"
fi

IP_OK=unknown
if bounded 5 "$BUNDLE/.ping-ip" ping -c1 -t2 -n 1.1.1.1; then
    if grep -q '1 packets received' "$BUNDLE/.ping-ip" 2>/dev/null; then
        IP_OK=yes; line "ping 1.1.1.1 (a literal IP, no DNS involved): reply"
    else
        IP_OK=no;  line "ping 1.1.1.1 (a literal IP, no DNS involved): NO reply"
    fi
else
    IP_OK=no; line "ping 1.1.1.1: (timed out)"
fi
rm -f "$BUNDLE/.ping-ip"
[ "$IP_OK" = no ] && line "            note: some corporate and VPN paths drop ICMP by policy, so a"
[ "$IP_OK" = no ] && line "            failure here is suggestive rather than conclusive on its own."

# Deliberately dscacheutil and not `dig`: dscacheutil goes through
# mDNSResponder, which is the path that actually died in the incident. `dig`
# talks to the resolver directly and would have answered "fine" while the
# machine was unusable.
DNS_OK=unknown
if bounded 6 "$BUNDLE/.dns" dscacheutil -q host -a name example.com; then
    if grep -q 'ip_address' "$BUNDLE/.dns" 2>/dev/null; then
        DNS_OK=yes; line "resolve example.com (via mDNSResponder): answered"
    else
        DNS_OK=no;  line "resolve example.com (via mDNSResponder): NO answer"
    fi
else
    DNS_OK=no; line "resolve example.com: (timed out)"
fi
rm -f "$BUNDLE/.dns"

# The ladder is ordered by how much each result PROVES, not by layer. A
# successful resolution proves sockets work end to end, so it outranks a failed
# ping — which only ever proves that ICMP did not come back, and plenty of
# corporate paths drop ICMP as policy. Reading it the other way round would
# report a healthy machine as broken, which is how a diagnostic loses its
# reader.
FLOW="unknown"
if [ "$DNS_OK" = yes ]; then
    FLOW="ok"
    if [ "$IP_OK" = yes ]; then
        concl "data flows at every layer probed."
    else
        concl "data flows (a name resolved end to end); the ICMP failure above is policy, not a fault."
    fi
elif [ "$IP_OK" = yes ]; then
    FLOW="dns"
    concl "a literal IP answers and DNS does not — the fault is at the resolver layer."
elif [ "$GW_OK" = yes ]; then
    FLOW="beyond"
    concl "the gateway answers but nothing beyond it does — forwarding or upstream, not the link."
elif [ "$GW_OK" = no ]; then
    FLOW="link"
    concl "neither the gateway nor anything past it answers — first hop, or the wrong gateway."
else
    concl "probe results are mixed; read the lines above rather than a summary."
fi

# ── 6. Third-party network extensions ───────────────────────────────────
section "6. Third-party network/endpoint extensions"

# THE DISCRIMINATOR. Five third-party network/endpoint extensions besides ours
# run on this machine, and at least one of them has wedged it.
#
# Cisco's socket filter deserves the specific note: `acsockext` sits in the data
# path for EVERY socket whenever Cisco Secure Client is installed, whether or
# not a Cisco VPN session is connected. That is exactly how it took down a
# machine whose user was not using Cisco at all — the user had only
# AnywayConnect and openconnect running, and the extension still failed every
# flow write with errno 49 for 33 minutes.
if [ -s "$BUNDLE/systemextensions.txt" ]; then
    grep -E '^\*|^[[:space:]]*\*' "$BUNDLE/systemextensions.txt" 2>/dev/null \
        | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /\(.*\/.*\)/) { print $(i-1), $i; break } }' \
        | grep -E 'cisco|crowdstrike|reveal|fortidlp|GlobalThreatList|kairyu' \
        | while read -r b v; do line "loaded:     $b $v"; done
else
    line "loaded:     (systemextensionsctl list unavailable)"
fi

EXT_WORST=0
EXT_WORST_NAME=""
EXT_QUIET=""
if [ "$QUICK" -eq 1 ]; then
    line "errors:     (skipped, --quick)"
    concl "EXTENSION ERRORS NOT CHECKED — rerun without --quick for the discriminator."
else
    if [ "$UNIFIED_OK" -eq 1 ]; then
        for ext in com.cisco.anyconnect.macos.acsockext \
                   com.crowdstrike.falcon \
                   uk.ava.reveal.agent.net \
                   uk.ava.reveal.agent.eps \
                   fortidlp \
                   GlobalThreatListEndpointClient.filter-sysex \
                   nesessionmanager \
                   neagent; do
            TOT=$(grep -c "$ext" "$BUNDLE/.unified.log" 2>/dev/null)
            # Named even when silent, so the reader can see it was CHECKED and
            # found quiet, rather than wonder whether it was looked at.
            if [ "${TOT:-0}" -eq 0 ]; then
                EXT_QUIET="$EXT_QUIET $ext"
                continue
            fi
            # errno 49, EADDRNOTAVAIL. This one count identified the entire
            # 2026-10-21 incident: 43,928 of them in 33 minutes, against zero
            # in the comparable window before the sleep and zero after the
            # reboot.
            E49=$(grep "$ext" "$BUNDLE/.unified.log" 2>/dev/null | grep -c 'assign requested')
            ERRS=$(grep "$ext" "$BUNDLE/.unified.log" 2>/dev/null \
                   | grep -cE ' (Error|Fault) +0x|failed with error|Too many open files')
            line "$ext:"
            line "    $TOT log lines in the last $EXT_WINDOW; ${ERRS:-0} error/fault; ${E49:-0} errno-49 \"can't assign requested address\""
            if [ "${E49:-0}" -gt "$EXT_WORST" ]; then
                EXT_WORST=$E49
                EXT_WORST_NAME=$ext
            fi
        done
        [ -n "$EXT_QUIET" ] \
            && line "checked and silent in this window:$EXT_QUIET"
        line ""
        line "raw extension log lines are deliberately NOT kept in the bundle (they"
        line "name hosts and binaries — browsing history by another name). To see them"
        line "yourself; this line is safe to paste into fish as-is:"
        line "    log show --last 5m --predicate 'process CONTAINS \"acsockext\"' | grep \"assign requested\""
    else
        line "errors:     (the unified-log query did not finish — see section 7)"
    fi

    if [ "$EXT_WORST" -gt 100 ]; then
        concl "$EXT_WORST_NAME is failing socket operations with errno 49 ($EXT_WORST in $EXT_WINDOW) — this is the 2026-10-21 signature."
    elif [ "$EXT_WORST" -gt 0 ]; then
        concl "$EXT_WORST_NAME logged $EXT_WORST errno-49 failure(s) in $EXT_WINDOW — a trickle, not a storm."
    else
        concl "no extension is throwing errno-49 socket failures."
    fi
fi

# ── 7. DNS and stall telemetry ──────────────────────────────────────────
section "7. DNS and stall telemetry"

# The ratio, not the raw counts, is the signal. In the incident mDNSResponder
# sent 14,027 queries and got 2 acceptable answers (0.01%) with ~1,500
# "all out" symptoms; the healthy baseline minutes later was 891/828 (93%).
# That pair of numbers is the clearest objective evidence that a network is
# dead while its configuration is perfect.
MD_SENT=0; MD_OK=0; STALLS=0; TELE="skipped"
if [ "$QUICK" -eq 1 ]; then
    line "(skipped, --quick)"
else
    if [ "$UNIFIED_OK" -eq 1 ]; then
        TELE="ok"
        MD_SENT=$(grep -c 'byte query' "$BUNDLE/.unified.log" 2>/dev/null)
        MD_OK=$(grep -c 'Received acceptable' "$BUNDLE/.unified.log" 2>/dev/null)
        STALLS=$(grep -cE 'all out|Data Stall score' "$BUNDLE/.unified.log" 2>/dev/null)
        {
            printf 'window: last %s\n' "$EXT_WINDOW"
            printf 'mDNSResponder queries sent:       %s\n' "${MD_SENT:-0}"
            printf 'mDNSResponder acceptable answers: %s\n' "${MD_OK:-0}"
            printf 'symptomsd all-out / data-stall:   %s\n' "${STALLS:-0}"
        } >"$BUNDLE/dns-telemetry.txt"
        line "mDNSResponder: ${MD_SENT:-0} queries sent, ${MD_OK:-0} acceptable answers"
        if [ "${MD_SENT:-0}" -gt 0 ]; then
            RATIO=$(( MD_OK * 100 / MD_SENT ))
            line "               answer ratio: ${RATIO}%  (healthy ~93%, the incident was 0%)"
        else
            RATIO=-1
            line "               no queries in the window — nothing asked, so nothing proved"
        fi
        line "symptomsd:     ${STALLS:-0} 'all out' / data-stall events (the incident ran ~45/min)"
    else
        TELE="timeout"
        line "(timed out — the unified-log query did not finish in 40s)"
    fi

    if [ "$TELE" = ok ] && [ "${MD_SENT:-0}" -ge 20 ] && [ "${RATIO:-100}" -lt 20 ]; then
        concl "DNS IS DEAD IN PRACTICE — ${MD_OK}/${MD_SENT} answered. The configuration can still be perfect; this is the symptom, not the cause."
    elif [ "$TELE" = ok ] && [ "${MD_SENT:-0}" -ge 20 ]; then
        concl "name resolution is working in practice (${MD_OK}/${MD_SENT} answered)."
    else
        concl "telemetry inconclusive (too few samples, or the query did not finish)."
    fi
fi

# ── 8. VERDICT ──────────────────────────────────────────────────────────
section "VERDICT"

# The whole script exists for these fifteen lines. The rule it follows: say
# "cannot tell" rather than guess. The user has been given confident wrong
# answers before, including by me, and a wrong verdict here costs a reboot and
# the trust needed to run this next time.
APP_FAULT=0
[ -z "${ABORT:-}" ] && {
    [ "$STALE_DEFAULTS" -gt 0 ] && APP_FAULT=1
    [ "$TUNNEL_DEFAULTS" -gt 0 ] && [ "$OC_RUNNING" -eq 0 ] && APP_FAULT=1
    [ "$UTUN_KEYS" -gt 0 ] && [ "$OC_RUNNING" -eq 0 ] && APP_FAULT=1
}
EXT_STORM=0
[ "$EXT_WORST" -gt 100 ] && EXT_STORM=1
DNS_DEAD=0
[ "$TELE" = ok ] && [ "${MD_SENT:-0}" -ge 20 ] && [ "${RATIO:-100}" -lt 20 ] && DNS_DEAD=1

RC=3
if [ -n "${ABORT:-}" ]; then
    printf '  CANNOT TELL.\n'
    printf '  The route table or the interface snapshot could not be read (%s), so\n' "$ABORT"
    printf '  no on-link judgement is possible. Everything below section 3 stands,\n'
    printf '  but the routing question is open. Capture the bundle and say so.\n'
    RC=3
elif [ "$APP_FAULT" -eq 1 ]; then
    printf '  THIS LOOKS LIKE AnywayConnect. Routing or DNS is in a state the app is\n'
    printf '  responsible for:\n'
    [ "$STALE_DEFAULTS" -gt 0 ] && printf '    - %s default route(s) point at a next hop that cannot carry traffic\n' "$STALE_DEFAULTS"
    [ "$TUNNEL_DEFAULTS" -gt 0 ] && [ "$OC_RUNNING" -eq 0 ] && printf '    - the default route goes down a tunnel with no tunnel process alive\n'
    [ "$UTUN_KEYS" -gt 0 ] && [ "$OC_RUNNING" -eq 0 ] && printf '    - %s configd utun DNS/IPv4 key(s) with no tunnel behind them\n' "$UTUN_KEYS"
    [ "${LEFTOVER:-0}" -gt 0 ] && printf '    - %s leftover route(s) via a gateway that is on no live link\n' "$LEFTOVER"
    printf '\n  WHAT TO DO. In AnywayConnect, Connect and then Disconnect once:\n'
    printf '  openconnect'"'"'s disconnect script removes the routes and DNS state its\n'
    printf '  tunnel installed. Anything it leaves is listed in section 3. Delete a\n'
    printf '  route by hand with "sudo route -n delete -net <destination>" (add\n'
    printf '  "-ifscope <interface>" for a scoped one), or reboot. Keep the bundle\n'
    printf '  either way — this is a bug in the app and the bundle is what makes it\n'
    printf '  fixable.\n'
    RC=1
elif [ "$EXT_STORM" -eq 1 ] || { [ "$DNS_DEAD" -eq 1 ] && [ "$EXT_WORST" -gt 0 ]; }; then
    printf '  THIS IS NOT AnywayConnect. %s is failing socket operations.\n' "$EXT_WORST_NAME"

    # The recovery goes FIRST, ahead of the evidence. On 2026-10-22 this verdict
    # was right and its recommendation — restart the offending client before you
    # reach for a reboot — was right, and it was still not taken, because it was
    # phrased as a procedure three paragraphs down and the reader had a dead
    # network. So: concrete, copy-pasteable, fish-safe, immediately under the
    # verdict line, naming the client that is actually failing. Nothing below is
    # run by this script. It prints; you decide.
    printf '\n  DO THIS FIRST — minutes, not a reboot.\n'
    case "$EXT_WORST_NAME" in
        *cisco*|*acsockext*)
            cat <<'CISCO'
  The failing extension is Cisco Secure Client's socket filter. It sits in the
  data path for every socket on this machine whenever the client is installed,
  connected or not. Restarting the client restarts the extension, which re-binds
  to the addresses this machine actually has now. In increasing order of what it
  costs you:

    1. Quit and relaunch Cisco Secure Client. Costs: your Cisco VPN session if
       you have one, nothing else. Always permitted — it is your own app.
       Menu bar: Cisco's icon -> Quit, then relaunch it from Applications.
       Or paste these, one line at a time (fish-safe: no &&, nothing to escape):
           osascript -e 'quit app "Cisco Secure Client"'
           sleep 5
           open -a "Cisco Secure Client"
       Expected recovery: the extension re-registers within a few seconds of the
       relaunch, and traffic returns with it — under a minute end to end. That
       is an estimate from how the extension comes up at login, NOT a measured
       recovery from this fault. If the network is not back after a minute, this
       did not work, and you have lost a minute.

    2. Look at the extension. Read-only, costs nothing, safe at any point:
           systemextensionsctl list
       Find com.cisco.anyconnect.macos.acsockext and check it still reads
       [activated enabled].

    3. Deactivating or reinstalling the extension. THIS MAY NOT BE PERMITTED ON
       THIS MACHINE, and saying otherwise would be dishonest: on a managed Mac
       the extension is MDM-approved, `systemextensionsctl uninstall` generally
       requires SIP developer mode and is often refused outright, and removing a
       managed security extension can raise a compliance alert against you.
       Treat this as a conversation with whoever owns the client, not a command
       to run. This script will not attempt it.

    4. Reboot. Costs every open session. It is also the only step here that has
       been proven to clear this fault, so it is the floor, not the first move.
CISCO
            ;;
        *crowdstrike*|*falcon*)
            cat <<'FALCON'
  The failing extension is CrowdStrike Falcon's. It is a managed security agent,
  so your options are narrower than with a user-launched client:

    1. Look at it first. Read-only, costs nothing:
           systemextensionsctl list
       Find com.crowdstrike.falcon.Agent and check it reads [activated enabled].

    2. There is no user-facing quit for Falcon, and stopping it is almost
       certainly not permitted on a managed machine: the agent is MDM-installed,
       usually tamper-protected, and interfering with it can raise a compliance
       alert. Do not fight it. Report it to whoever owns the agent, with the
       bundle below.

    3. Reboot. On a machine where the agent cannot be restarted, this is the
       recovery. Costs every open session.
FALCON
            ;;
        *)
            printf '  The failing extension is %s.\n' "$EXT_WORST_NAME"
            cat <<'OTHER'
  Restarting whatever client owns it restarts the extension, which re-binds to
  the addresses this machine actually has now. In increasing order of cost:

    1. Look at it first. Read-only, costs nothing:
           systemextensionsctl list
       Find the bundle ID above and check it still reads [activated enabled].

    2. If a user-facing app owns it (a VPN or security client with a menu-bar
       item), quit and relaunch that app. Costs: that client's session.
       Expected recovery: seconds after the extension re-registers. That is an
       estimate, not a measurement of this fault; give it a minute, no more.

    3. If it is MDM-managed with no user-facing app, stopping it is probably not
       permitted here and may raise a compliance alert. Report it to whoever
       owns it instead of fighting it. This script will not attempt it.

    4. Reboot. Costs every open session, and it is the step that is known to
       work.
OTHER
            ;;
    esac
    printf '\n  A Wi-Fi off/on will NOT help at any point above. It was tried during the\n'
    printf '  2026-10-21 incident and the error storm continued straight through a full\n'
    printf '  link bounce and an IPv4 service re-publish.\n'

    printf '\n  WHY THAT IS THE VERDICT:\n'
    printf '    - routing is clean: a usable default, every gateway on-link somewhere\n'
    printf '    - DNS configuration is clean for the current tunnel state\n'
    printf '    - %s is failing socket operations with errno 49\n' "$EXT_WORST_NAME"
    printf '      (%s in the last %s; errno 49 is EADDRNOTAVAIL, "the address I am\n' "$EXT_WORST" "$EXT_WINDOW"
    printf '      bound to no longer exists on this machine")\n'
    [ "$DNS_DEAD" -eq 1 ] && printf '    - and name resolution is dead in practice: %s/%s answered\n' "${MD_OK:-0}" "${MD_SENT:-0}"
    printf '\n  This is the 2026-10-21 signature exactly: a socket filter extension still\n'
    printf '  bound to an address from the network you left, failing every write, while\n'
    printf '  the link, the address, the gateway and the resolver are all fine.\n'
    printf '\n  The bundle below already holds the route table, ifconfig and scutil --dns,\n'
    printf '  and it survives a reboot. For the raw extension lines, which are NOT kept:\n'
    printf '    log show --last 10m --predicate %s > %s/wedge-ext.txt\n' "'process CONTAINS \"acsockext\"'" "$BUNDLE"
    printf '\n  Worth reporting to whoever owns that client: after a sleep spanning a\n'
    printf '  network change it fails every flow write and does not recover.\n'
    RC=2
elif [ "$FLOW" = ok ]; then
    printf '  NOTHING WRONG HERE. Routing is correct, DNS configuration is coherent,\n'
    printf '  and data flows at every layer probed.\n'
    [ "${LEFTOVER:-0}" -gt 0 ] && printf '  Note: %s leftover route(s) are present. They blackhole only those\n  destinations, not the machine, and deleting them by hand or a reboot clears them.\n' "$LEFTOVER"
    RC=0
elif [ "$FLOW" = dns ] || [ "$FLOW" = beyond ] || [ "$FLOW" = link ]; then
    printf '  CANNOT TELL — and that is the honest answer.\n'
    printf '  Routing and DNS configuration are clean, so this is not a state\n'
    printf '  AnywayConnect put the machine in. But data does not flow (%s), and\n' "$FLOW"
    printf '  no extension is throwing the errno-49 storm that would name a culprit.\n'
    printf '  What is NOT established: which component is dropping the traffic.\n'
    printf '  Next: rerun this without --quick if you used it, widen the window\n'
    printf '  (edit EXT_WINDOW to 30m), and keep the bundle before changing anything.\n'
    RC=3
else
    printf '  CANNOT TELL. The probes did not agree on a single picture and nothing\n'
    printf '  above reached a threshold. Read sections 3, 5 and 6 directly; the\n'
    printf '  bundle has the raw captures.\n'
    RC=3
fi

printf '%s\n' "$RC" >"$BUNDLE/verdict"

section "Evidence bundle"
line "$BUNDLE"
line ""
line "THIS SURVIVES A REBOOT. ~/Library/Logs is not cleared on restart, so you can"
line "reboot to recover the machine and still have everything below afterwards."
line ""
line "Contains: the route table, ifconfig, scutil --dns, the configd key list,"
line "the loaded system extensions, the launchd record of the daemon, the"
line "/var/run pid file, the sleep/wake lines from pmset, the DNS telemetry"
line "counts, and report.txt — a verbatim copy of everything printed above,"
line "written as it was printed, so you do not have to remember to redirect."
line ""
line "Retention: the $RETAIN most recent diag-<timestamp> bundles are kept."
if [ "${PRUNED_N:-0}" -gt 0 ]; then
    line "This run pruned $PRUNED_N older bundle(s) of its own:"
    printf '%s\n' "$PRUNED" | while read -r pb; do
        [ -n "$pb" ] && line "    $pb"
    done
else
    line "Nothing was pruned this run."
fi
if [ -e "$BUNDLE/openconnect.log" ]; then
    line ""
    line "It also holds openconnect.log (copied FIRST, before any probe, because it"
    line "is truncated on every connect) and anyway-connect-helper.log (the only"
    line "LIVE log that survives a reboot; this copy of it does too). Those are the"
    line "app's own logs: they name your VPN endpoint hostnames and the sites in"
    line "your exception-route list, so glance over them before attaching the"
    line "bundle to anything public."
fi
}
# ══════════════════════════════════════════════════════════════════════════

main 2>&1 | redact | tee "$BUNDLE/report.txt"

# The shared unified-log capture never stays: it names hosts, binaries and flow
# endpoints. Only the derived counts in dns-telemetry.txt and the report remain.
rm -f "$BUNDLE/.unified.log"

RC=$(cat "$BUNDLE/verdict" 2>/dev/null)
exit "${RC:-3}"
