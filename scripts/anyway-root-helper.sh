#!/bin/sh
#
# anyway-root-helper.sh — the ONLY thing granted passwordless sudo.
#
# THREAT MODEL
# ------------
# The sudoers rule lets the desktop user run this script as root with no
# password. Anything running as that user — including malware — can therefore
# invoke it. So the grant is only as narrow as this script's argument handling:
# every path it hands to a program that runs as root, and every file it
# executes, must be fixed and root-owned, never caller-supplied.
#
# Previously this script accepted the --script path, the vpnc-script path and
# the pid-file path as arguments. Each was a straight privilege escalation:
#     sudo anyway-root-helper.sh tunnel anyconnect - - /tmp/evil.sh host ...
# would have run /tmp/evil.sh as root. They are now hardcoded below, and
# verified to be root-owned and not group/other-writable before use.
#
# Note this is also why the vpnc-script is used from LIBEXEC rather than from
# Homebrew: /opt/homebrew is owned by the desktop user, so executing anything
# from there as root would hand the same hole straight back.
#
# Subcommands:
#   tunnel <protocol> <fp|-> <resolve|-> <host> <auto_subnet 0|1> <cidr,csv|->
#          (cookie on stdin)
#   stop <pid> [pid...]
#   restore-default <interface>
#   reconcile
#
# FILE ORDER IS LOAD-BEARING. test/test-onlink-guard.sh SOURCES this file to run
# the Swift guard's case table against the shell port, so everything above the
# source-only guard below must be definitions only: the openconnect discovery
# loop ends in `die`, which is `exit 2` and would kill the sourcing shell, and
# `CMD="${1:-}"; shift` would eat the test's own arguments. Nothing is invoked
# between the top of this file and the `case`, so hoisting the definitions is
# behaviour-neutral.
#
# Install with scripts/install-privileged.sh. Keep root-owned, mode 0755.

set -u

# This script invoked route, kill, stat, printf, cut and tr unqualified and set
# no PATH at all. Fixed and minimal, for the same reason the daemon fixes the
# environment it hands openconnect.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

# Every validator below is a `case` with a bracket RANGE in it, and a range
# collates by LOCALE. Under the desktop user's en_US.UTF-8, `*[!a-z0-9]*` does
# NOT reject "EN0" — the collation folds case — so valid_iface accepted an
# interface name that PrivilegedValidation.isValidInterface rejects, and the
# parity test caught the difference. C collation is what makes a-z mean a-z.
# Strictly tightening: the other validators spell both cases out explicitly, so
# nothing that was accepted on purpose stops being accepted.
LC_ALL=C
export LC_ALL

LIBEXEC="/usr/local/libexec/anyway-connect"
ROUTE_WRAPPER="$LIBEXEC/route-wrapper.sh"
VPNC_SCRIPT="$LIBEXEC/vpnc-script"
PIDFILE="/var/run/anyway-connect.pid"
# Written by the privileged daemon before a connect, removed by its stopTunnel.
# `reconcile` READS one field of it (preexistingTunnels) and never writes or
# removes it: every later reconcile in this boot needs that tunnel scope.
NETSTATE="/var/run/anyway-connect.netstate.json"

die() { echo "anyway-root-helper: $*" >&2; exit 2; }

# --- Command paths ----------------------------------------------------------
#
# UNCONDITIONAL assignment, never the `: "${VAR:=default}"` form. This runs as
# root under a NOPASSWD sudoers rule, and its own banner states the rule: every
# path it hands to a program that runs as root must be fixed, never
# caller-supplied. An environment variable IS caller-supplied input, and
# "overridable only for the test" is not a property anything enforces — sudo's
# env_reset happens to strip these today, but that is a sudoers default and not
# a property of this script.
#
# test/test-onlink-guard.sh overrides them by ASSIGNING AFTER SOURCING, which
# works because the functions below read the variables at call time. It gets the
# same capability with no new influence on the installed root path.
IFCONFIG=/sbin/ifconfig
IPCONFIG=/usr/sbin/ipconfig
NETSTAT=/usr/sbin/netstat
SCUTIL=/usr/sbin/scutil

# Set by gw_on_link_for for in-process callers (the parity test, which sources
# this file). Declared here because the script runs under `set -u` — and because
# derive_gateway runs in a command substitution, i.e. a subshell, so a reason set
# inside it can NEVER propagate to the parent. The reason reaches the APP through
# stderr instead; see gw_on_link_for.
GUARD_REASON=""
_g_if=""
_g_gw=""

# --- Refuse to run anything a non-root user could have tampered with --------
assert_root_owned() {
    _f="$1"
    [ -e "$_f" ] || die "missing $_f — run scripts/install-privileged.sh"
    _owner="$(stat -f '%u' "$_f" 2>/dev/null)" || die "cannot stat $_f"
    [ "$_owner" = "0" ] || die "$_f must be owned by root (owner uid $_owner)"
    # Low 3 permission digits; group and other must not carry the write bit.
    _perm="$(stat -f '%Lp' "$_f" 2>/dev/null)"
    _perm="$(printf '%03d' "$_perm" 2>/dev/null || echo "$_perm")"
    _g="$(printf '%s' "$_perm" | cut -c2)"
    _o="$(printf '%s' "$_perm" | cut -c3)"
    case "$_g" in 2|3|6|7) die "$_f is group-writable (mode $_perm)" ;; esac
    case "$_o" in 2|3|6|7) die "$_f is world-writable (mode $_perm)" ;; esac
}

# --- Argument validation ----------------------------------------------------
valid_proto() {
    case "$1" in anyconnect|nc|gp|pulse|f5|fortinet|array) return 0 ;; *) return 1 ;; esac
}
# Reject anything that could be read as an option, plus shell/path metacharacters.
valid_host() {
    [ -n "$1" ] || return 1
    case "$1" in -*) return 1 ;; esac
    case "$1" in *[!A-Za-z0-9.:_-]*) return 1 ;; esac
    return 0
}
valid_fp() {
    [ "$1" = "-" ] && return 0
    case "$1" in -*) return 1 ;; esac
    case "$1" in
        pin-sha256:*) case "${1#pin-sha256:}" in *[!A-Za-z0-9+/=]*) return 1 ;; esac ;;
        *)            case "$1" in *[!A-Fa-f0-9:]*) return 1 ;; esac ;;
    esac
    return 0
}
valid_resolve() {
    [ "$1" = "-" ] && return 0
    case "$1" in -*) return 1 ;; esac
    case "$1" in *:*) ;; *) return 1 ;; esac
    case "$1" in *[!A-Za-z0-9.:_-]*) return 1 ;; esac
    return 0
}
valid_cidr() {
    case "$1" in *[!0-9./]*|'') return 1 ;; esac
    case "$1" in */*) ;; *) return 1 ;; esac
    return 0
}
# RETAINED, UNUSED, superseded by valid_ipv4_strict: its only caller was
# restore-default's gateway argument, which no longer exists. Kept because
# deleting a function is a gratuitous edit in a security-sensitive file.
valid_ipv4() {
    case "$1" in *[!0-9.]*|'') return 1 ;; esac
    return 0
}
valid_iface() {
    case "$1" in *[!a-z0-9]*|'') return 1 ;; esac
    return 0
}

# Strict dotted quad, and deliberately NOT a change to valid_ipv4: that one
# accepts "10.0.1" and "999.999.999.999", which would make this guard disagree
# with the Swift guard on the very case table that proves they agree.
#
# Leading zeros are rejected, which is STRICTER than the design's sketch of this
# function and matches NetGuard.swift's IPv4(_:) exactly ("010.0.1.1" is nil
# there). Two reasons, both load-beared: a string two parsers read differently is
# how you install the wrong route, and $(( 010 )) is OCTAL 8 in this shell, so
# accepting it here would feed ip_to_int a silently different address.
#
# Every temporary below is prefixed `_vs_`, and so is every temporary in the new
# functions that follow: sh has no local variables, this one is called from
# inside other functions' `while read` loops, and an earlier revision of it
# counted octets in a bare `_n` — which silently overwrote the caller's loop
# variable and made a reconcile install a default route for interface "4".
valid_ipv4_strict() {
    case "$1" in *[!0-9.]*|''|*..*|.*|*.) return 1 ;; esac
    _vs_n=0; _vs_ifs="$IFS"; IFS='.'
    for _vs_o in $1; do
        case "$_vs_o" in ''|*[!0-9]*) IFS="$_vs_ifs"; return 1 ;; esac
        case "$_vs_o" in 0?*) IFS="$_vs_ifs"; return 1 ;; esac    # no leading zeros
        { [ "${#_vs_o}" -le 3 ] && [ "$_vs_o" -le 255 ]; } || { IFS="$_vs_ifs"; return 1; }
        _vs_n=$((_vs_n + 1))
    done
    IFS="$_vs_ifs"
    [ "$_vs_n" = 4 ]
}

# The name half of NetInterface.isTunnelLike. The flag half (POINTOPOINT) comes
# from the snapshot; both are needed, because a utun with an unexpected name is
# still a tunnel and a point-to-point link with an ordinary name is too.
iface_name_is_tunnel() {
    case "$1" in utun*|ppp*|ipsec*|gif*|stf*) return 0 ;; *) return 1 ;; esac
}

# PrivilegedValidation.isRestoreTargetInterface: valid_iface, plus a length the
# kernel can hold (IFNAMSIZ - 1) and not being a tunnel — restoring the physical
# default onto a utun is the failure this whole change exists to stop (FR-1.8).
restore_target_iface() {
    valid_iface "$1" || return 1
    [ "${#1}" -le 15 ] || return 1
    iface_name_is_tunnel "$1" && return 1
    return 0
}

# --- Address arithmetic, written out ----------------------------------------
#
# This is a COPY OF, NOT A CALL INTO, scripts/route-wrapper.sh's mask_to and
# inside_subnet. That file is the vendored route wrapper (F8) and stays
# untouched, it is executed by openconnect in a completely different context, and
# it reasons in CIDR prefixes while the guard below reasons in the hex netmasks
# ifconfig actually prints. Sharing it would mean sourcing one privileged script
# from another for three lines of arithmetic.
#
# The duplication is accepted and tracked as open issue O-6; what keeps the two
# copies honest is test/test-onlink-guard.sh, which runs the SAME case table as
# the Swift harness's Suite 1 against this implementation.
#
# The arithmetic, stated once:
#   * a netmask must match 0x followed by exactly 8 hex digits, or the guard
#     REFUSES — it never guesses. ifconfig prints the netmask by keyword, and a
#     line read positionally is what produced "0x2.: invalid arithmetic
#     operator" in route-wrapper.sh's own history;
#   * a hex mask becomes an integer with $(( 0x... ));
#   * a dotted quad becomes an integer by IFS-splitting on '.' and
#     (a << 24) | (b << 16) | (c << 8) | d;
#   * on-link is (gw & m) == (addr & m) for ANY (addr, mask) pair the target
#     carries — a secondary address makes a next hop just as reachable as the
#     primary one does (pass-5 HIGH 2);
#   * the network and broadcast addresses are rejected only when the prefix is
#     <= 30, i.e. when the mask leaves at least 2 host bits. At /31 and /32
#     neither address exists (RFC 3021).

# Dotted quad -> 32-bit integer. The caller MUST have run valid_ipv4_strict
# first: that is what guarantees four octets with no leading zero, so $(( ))
# cannot read an octet as octal.
#
# On a shell with 32-bit arithmetic the top octet's shift would wrap; every use
# below is an equality between two values computed the same way, so a consistent
# wrap cannot change an answer. (macOS /bin/sh is 64-bit regardless.)
ip_to_int() {
    _it_q="$1"
    _it_ifs="$IFS"; IFS='.'
    set -- $_it_q
    IFS="$_it_ifs"
    echo "$(( ($1 << 24) | ($2 << 16) | ($3 << 8) | $4 ))"
}

# "0xffffff00" -> integer. Anything else is a refusal, never a guess.
mask_hex_to_int() {
    case "$1" in
        0x[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
        *) return 1 ;;
    esac
    echo "$(( $1 ))"
}

# --- The interface snapshot -------------------------------------------------
#
# ONE `ifconfig -a` parse covering EVERY interface, rather than one `ifconfig
# <iface>` per question. Without it the guard cannot implement §3.2 step 4 (the
# target is absent from the snapshot — which is a different answer from "present
# but unaddressed") or step 8 (the candidate is the address of ANY tunnel
# interface, which is the observed failure), and the "same case table as the
# Swift guard" claim would simply be false.
#
# One line per interface:
#
#     NAME UP POINTOPOINT LOOPBACK [ADDR/MASK ...]
#
# with the three flags as 0/1 read from the <...> TOKEN LIST by exact match
# (never from the hex value, and never positionally), and EVERY inet address of
# the link kept with the hex netmask that appeared on its own line. A missing or
# unreadable netmask is recorded as "-", which can only make the guard refuse.
#
# Not cached: derive_gateway asks twice at most, and reconcile's install has to
# see the table and the links as its own deletions left them (FR-2.8).
iface_snapshot() {
    "$IFCONFIG" -a 2>/dev/null | awk '
        # An interface header line; everything indented below it belongs to it.
        /^[A-Za-z][A-Za-z0-9_.-]*:[ \t]*flags=/ {
            if (name != "") print line
            name = $1; sub(/:$/, "", name)
            flags = $0; sub(/^[^<]*</, "", flags); sub(/>.*$/, "", flags)
            up = 0; p2p = 0; lo = 0
            n = split(flags, tok, ",")
            for (i = 1; i <= n; i++) {
                if      (tok[i] == "UP")          up = 1
                else if (tok[i] == "POINTOPOINT") p2p = 1
                else if (tok[i] == "LOOPBACK")    lo = 1
            }
            line = name " " up " " p2p " " lo
            next
        }
        # Read BY KEYWORD. A point-to-point inet line is
        #   inet 192.168.204.16 --> 192.168.204.16 netmask 0xffffffff
        # so the netmask is not at a fixed field index.
        name != "" && $1 == "inet" {
            mask = "-"
            for (i = 1; i <= NF; i++) if ($i == "netmask") { mask = $(i + 1); break }
            if (mask == "") mask = "-"
            line = line " " $2 "/" mask
            next
        }
        END { if (name != "") print line }
    '
}

# True when NAME ($2) is tunnel-like according to the snapshot ($1): the name
# rule, or the POINTOPOINT flag.
snapshot_is_tunnel() {
    iface_name_is_tunnel "$2" && return 0
    printf '%s\n' "$1" | awk -v n="$2" '
        $1 == n { found = 1; tun = ($3 == 1); exit }
        END { if (found && tun) exit 0; exit 1 }
    '
}

# Every address of every tunnel-like link in the snapshot ($1), one per line.
tunnel_addresses() {
    printf '%s\n' "$1" | awk '
        {
            tun = ($3 == 1) || ($1 ~ /^(utun|ppp|ipsec|gif|stf)/)
            if (!tun) next
            for (i = 5; i <= NF; i++) { split($i, a, "/"); print a[1] }
        }
    '
}

# Links that could carry a default route: up, addressed, not a tunnel, not
# loopback. (Loopback is excluded for the same reason the Swift planner excludes
# it: lo0 is always present, up and addressed, so counting it would make every
# "is there exactly one physical link" question answer no.)
physical_links() {
    printf '%s\n' "$1" | awk '
        NF >= 5 && $2 == 1 && $3 == 0 && $4 == 0 && $1 !~ /^(utun|ppp|ipsec|gif|stf)/ { print $1 }
    ' | sort
}

# --- The on-link guard ------------------------------------------------------
#
# A faithful port of NetGuard.swift's evaluateDefaultGateway: the same step
# ORDER and the same GatewayRejection raw-value strings, because the reason is
# part of the contract — "off-link" and "the gateway is a tunnel's own address"
# are different diagnoses of different faults and must not be interchangeable.

# Records a rejection twice over, on purpose:
#   * GUARD_REASON, for in-process callers — the parity test sources this file;
#   * stderr, for the app, because derive_gateway runs in a command substitution
#     and a variable set in that subshell can never reach the parent. The app
#     logs both streams and reads its verdict from the final line of stdout, so
#     a guard line here can never be mistaken for a verdict.
# Always returns 1.
_guard_reject() {
    GUARD_REASON="$1"
    echo "guard: $_g_if $_g_gw -> reject($1)" >&2
    return 1
}

# gw_on_link_for IFACE GW — 0 if GW may be installed as IFACE's default next
# hop, 1 with GUARD_REASON set otherwise. Prints nothing on stdout: derive_gateway
# calls it inside a command substitution whose stdout IS the derived gateway.
gw_on_link_for() {
    _g_if="$1"; _g_gw="$2"
    GUARD_REASON=""

    # 1. The name is about to become an argv element for a root `route`
    #    invocation, so it is validated before anything else looks at it.
    #    15 == IFNAMSIZ - 1, the kernel's own limit.
    if [ -z "$_g_if" ] || [ "${#_g_if}" -gt 15 ] || ! valid_iface "$_g_if"; then
        _guard_reject malformedInterfaceName; return 1
    fi
    # 2. Strict dotted quad, so "010.0.1.1" is refused here rather than meaning
    #    something different to `route` than it did to us.
    valid_ipv4_strict "$_g_gw" || { _guard_reject malformedGateway; return 1; }
    # 3. Neither of these is a next hop, and both pass sloppier validators.
    case "$_g_gw" in
        0.0.0.0|255.255.255.255) _guard_reject unspecifiedGateway; return 1 ;;
    esac

    _g_snap="$(iface_snapshot)"
    _g_line="$(printf '%s\n' "$_g_snap" | awk -v n="$_g_if" '$1 == n { print; exit }')"
    # 4/5. Absent from the snapshot and present-but-unaddressed are DIFFERENT
    #    answers: the first means the snapshot cannot tell us anything, the
    #    second that the link is not configured. Neither means "the route is
    #    dead". Step 5 precedes step 7, so a link that is both unaddressed and
    #    down reports `unconfigured`.
    [ -n "$_g_line" ] || { _guard_reject targetInterfaceMissing; return 1; }

    _g_ifs="$IFS"; IFS=' '
    set -- $_g_line
    IFS="$_g_ifs"
    _g_up="$2"; _g_p2p="$3"
    shift 4                                  # "$@" is now ADDR/MASK ...
    [ "$#" -ge 1 ] || { _guard_reject targetInterfaceUnconfigured; return 1; }
    _g_addrs="$*"

    # 6. FR-1.8. Before step 7, so a dead utun reports the tunnel reason rather
    #    than "down".
    if [ "$_g_p2p" = "1" ] || iface_name_is_tunnel "$_g_if"; then
        _guard_reject targetInterfaceIsTunnel; return 1
    fi
    # 7. A down link cannot carry the traffic we would point at it.
    [ "$_g_up" = "1" ] || { _guard_reject targetInterfaceDown; return 1; }

    # 8. The real observed failure, reported by its own name: the vendored
    #    vpnc-script's get_default_gw() answered utun7's OWN 192.168.204.16 as
    #    "the physical gateway". Calling that merely off-link would hide the
    #    mechanism. Address-only comparison, across EVERY address of EVERY
    #    tunnel-like link, so a utun with no netmask in the snapshot still counts.
    for _g_t in $(tunnel_addresses "$_g_snap"); do
        if [ "$_g_t" = "$_g_gw" ]; then
            _guard_reject gatewayIsTunnelAddress; return 1
        fi
    done

    # 9. The target's own address is not a next hop — any of its addresses: a
    #    secondary address is just as much "ourselves" as the primary.
    for _g_p in $_g_addrs; do
        if [ "${_g_p%%/*}" = "$_g_gw" ]; then
            _guard_reject gatewayIsOwnAddress; return 1
        fi
    done

    # 10/11. On-link for ANY (address, mask) pair, and then network/broadcast
    #    reasoning about THAT pair's subnet — a candidate can only be the network
    #    or broadcast address of the subnet it actually sits in.
    _g_gwi="$(ip_to_int "$_g_gw")"
    _g_matched=0
    for _g_p in $_g_addrs; do
        _g_a="${_g_p%%/*}"; _g_m="${_g_p##*/}"
        valid_ipv4_strict "$_g_a" || continue
        _g_mi="$(mask_hex_to_int "$_g_m")" || continue    # refuses, never guesses
        _g_ai="$(ip_to_int "$_g_a")"
        [ "$(( _g_gwi & _g_mi ))" = "$(( _g_ai & _g_mi ))" ] || continue
        _g_matched=1
        # Host bits of a contiguous mask: 255 at /24, 3 at /30, 1 at /31, 0 at
        # /32. ">= 3" IS "prefix <= 30", written in the terms this code has.
        _g_hosts=$(( (~_g_mi) & 0xffffffff ))
        if [ "$_g_hosts" -ge 3 ]; then
            if [ "$_g_gwi" = "$(( _g_ai & _g_mi ))" ]; then
                _guard_reject gatewayIsNetworkAddress; return 1
            fi
            if [ "$_g_gwi" = "$(( (_g_ai & _g_mi) | _g_hosts ))" ]; then
                _guard_reject gatewayIsBroadcastAddress; return 1
            fi
        fi
        break
    done
    [ "$_g_matched" = "1" ] || { _guard_reject gatewayOffLink; return 1; }

    # Accepted. No re-canonicalisation step is needed here, unlike Swift's
    # IPv4.text: valid_ipv4_strict rejects every non-canonical spelling, so the
    # string checked and the string handed to `route` are the same bytes.
    GUARD_REASON=""
    return 0
}

# --- The route table and the derivation ladder ------------------------------

# Default-route rows of a `netstat -rn -f inet` capture ($1), in table order, as
#
#     NETIF IFSCOPED(0|1) GATEWAY
#
# Column indices are DERIVED FROM THE HEADER, never positional — the same rule
# NetReconcile.parseRouteTable follows, for the same reason. `I` is RTF_IFSCOPE
# and is case-sensitive: the lowercase `i` is RTF_IFREF and means something else.
default_rows() {
    printf '%s\n' "$1" | awk '
        !seen {
            if ($1 != "Destination") next
            for (i = 1; i <= NF; i++) {
                if      ($i == "Destination") d = i
                else if ($i == "Gateway")     g = i
                else if ($i == "Flags")       f = i
                else if ($i == "Netif")       n = i
            }
            if (d && g && f && n) seen = 1
            next
        }
        $1 == "Destination" { next }                      # a second family header
        NF < d || NF < g || NF < f || NF < n { next }
        $d == "default" { printf "%s %d %s\n", $n, (index($f, "I") ? 1 : 0), $g }
    '
}

# The interface the kernel currently answers the UNSCOPED default with.
current_default_iface() {
    route -n get default 2>/dev/null | awk '/interface:/ { print $2; exit }'
}

# derive_gateway IFACE — prints an accepted gateway and returns 0, or returns 1
# having printed its reasons to stderr. The ladder is deriveDefaultGateway's,
# minus candidate 3:
#
#   1. the live DHCP lease (`ipconfig getoption <iface> router`) — a live lease
#      beats a possibly stale table row;
#   2. the route table's existing IPv4 default FOR THIS INTERFACE — covers
#      statically configured links, where ipconfig says nothing.
#
# Two documented, safe-direction divergences from the Swift ladder, both in
# O-6's register:
#   * no candidate 3. The netstate's advisory gateway is not read here; parsing
#     JSON in POSIX sh to recover an advisory value is not worth the surface, and
#     its absence can only make this refuse where Swift would have installed.
#   * no `ipconfig getsummary` fallback behind candidate 1. A static link is
#     covered by candidate 2; a DHCP link whose getoption is empty but whose
#     getsummary has a Router line is the gap.
# Every candidate still goes through the same guard, so neither divergence can
# install anything Swift would have refused.
derive_gateway() {
    _d_if="$1"
    _d_c="$("$IPCONFIG" getoption "$_d_if" router 2>/dev/null | tr -d '[:space:]')"
    if [ -n "$_d_c" ]; then
        echo "derive: dhcp candidate $_d_c" >&2
        gw_on_link_for "$_d_if" "$_d_c" && { echo "$_d_c"; return 0; }
    else
        echo "derive: dhcp (none)" >&2
    fi

    # The first default row for this interface, scoped or not: both are eligible
    # as a gateway SOURCE, and the guard re-validates whichever it is, so this
    # cannot install something the table did not already claim.
    _d_c="$(default_rows "$("$NETSTAT" -rn -f inet 2>/dev/null)" \
            | awk -v want="$_d_if" '$1 == want && $3 ~ /^[0-9]+(\.[0-9]+){3}$/ { print $3; exit }')"
    if [ -n "$_d_c" ]; then
        echo "derive: routeTable candidate $_d_c" >&2
        gw_on_link_for "$_d_if" "$_d_c" && { echo "$_d_c"; return 0; }
    else
        echo "derive: routeTable (none)" >&2
    fi

    echo "derive: no acceptable gateway for $_d_if" >&2
    return 1
}

# --- reconcile's inputs -----------------------------------------------------

# FR-2.2's gate, as the SAME union the daemon's livePIDs() takes: the pid file
# (digits only, kill -0) UNION a pgrep for our own openconnect command line.
#
# The pid file alone is not trustworthy and FR-2.2 is unconditional: stopTunnel
# removes that file even when it had to escalate to SIGTERM and the process
# survived, so a reparented, still-live openconnect would be invisible and a
# reconcile would mutate routing under a live tunnel. The pattern is byte-for-byte
# the daemon's, so the two judgements cannot drift.
live_tunnel_pid() {
    if [ -r "$PIDFILE" ]; then
        _lp="$(tr -d '[:space:]' < "$PIDFILE" 2>/dev/null || true)"
        case "${_lp:-}" in
            ''|*[!0-9]*) ;;
            *) kill -0 "$_lp" 2>/dev/null && { echo "$_lp"; return 0; } ;;
        esac
    fi
    _lp="$(pgrep -f 'openconnect .*(route-wrapper\.sh|--cookie-on-stdin)' 2>/dev/null | head -1)"
    case "${_lp:-}" in
        ''|*[!0-9]*) return 1 ;;
        *) echo "$_lp"; return 0 ;;
    esac
}

# The netstate's preexistingTunnels — the tunnels that were already up when we
# connected, i.e. somebody else's. One awk extraction of that one array of simple
# strings; ANY parse difficulty is treated as "netstate absent" (return 1) and
# said so on stderr, which is the widened, requirement-literal behaviour of
# acting on every utun (open issue O-9).
netstate_preexisting_tunnels() {
    [ -r "$NETSTATE" ] || return 1
    # NetState.maxBytes. A file larger than this is not our netstate.
    _ns_sz="$(wc -c < "$NETSTATE" 2>/dev/null | tr -d ' ')"
    case "${_ns_sz:-}" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_ns_sz" -le 65536 ] || return 1
    awk '
        { all = all $0 }
        END {
            i = index(all, "\"preexistingTunnels\"")
            if (i == 0) exit 1
            rest = substr(all, i)
            o = index(rest, "["); c = index(rest, "]")
            if (o == 0 || c == 0 || c < o) exit 1
            body = substr(rest, o + 1, c - o - 1)
            gsub(/[ \t"]/, "", body)
            n = split(body, t, ",")
            for (j = 1; j <= n; j++) {
                if (t[j] == "") continue
                # Only plain utun names. Anything else means this is not the
                # array we think it is, and guessing would scope a privileged
                # deletion by a value we misread.
                if (t[j] !~ /^utun[0-9][0-9]?[0-9]?$/) exit 1
                print t[j]
            }
        }
    ' "$NETSTATE" 2>/dev/null
}

# The configd keys that hold a tunnel's IPv4 and DNS overrides, as bare keys.
#
# Anchored at both ends with the service component constrained to utun + digits,
# so a UUID-named physical service — which is the machine's REAL resolver
# configuration — can never match.
configd_tunnel_keys() {
    echo 'list State:/Network/Service/[^/]+/(DNS|IPv4)' | "$SCUTIL" 2>/dev/null | awk '
        {
            i = index($0, " = ")
            if (i == 0) next
            k = substr($0, i + 3)
            gsub(/^[ \t]+|[ \t]+$/, "", k)
            if (k ~ /^State:\/Network\/Service\/utun[0-9][0-9]?[0-9]?\/(IPv4|DNS)$/) print k
        }
    '
}

# Install target selection, in the order this transport can honour: the netif of
# a non-tunnel default row (unscoped preferred — the link whose default is
# already there is the obvious target), else the single usable physical link.
#
# Swift's step (1), netstate.physicalInterface, is not available here: this arm
# reads only preexistingTunnels from the netstate (O-6). With two or more live
# physical links and no default row to inherit a netif from, NOTHING is chosen
# and that is said out loud — picking one at random is how you install a default
# onto the wrong network.
pick_install_target() {
    _pt_snap="$1"
    _pt_cand=""; _pt_scoped=""
    while read -r _pt_n _pt_s _pt_gw; do
        [ -n "${_pt_n:-}" ] || continue
        snapshot_is_tunnel "$_pt_snap" "$_pt_n" && continue
        if [ "$_pt_s" = "0" ]; then _pt_cand="$_pt_n"; break; fi
        [ -n "$_pt_scoped" ] || _pt_scoped="$_pt_n"
    done <<EOF
$(default_rows "$2")
EOF
    [ -n "$_pt_cand" ] || _pt_cand="$_pt_scoped"
    if [ -n "$_pt_cand" ]; then printf '%s\n' "$_pt_cand"; return 0; fi

    _pt_links="$(physical_links "$_pt_snap")"
    _pt_count=0
    for _pt_l in $_pt_links; do _pt_count=$((_pt_count + 1)); done
    if [ "$_pt_count" = "1" ]; then printf '%s\n' "$_pt_links"; return 0; fi
    if [ "$_pt_count" = "0" ]; then
        echo "no usable physical link in the interface snapshot" >&2
    else
        echo "ambiguous install target: $(printf '%s' "$_pt_links" | tr '\n' ' ')" >&2
    fi
    return 1
}

# The install gate, §4.3(f)'s condition: an UNSCOPED default on a non-tunnel link
# whose next hop the guard still accepts. Prints "NETIF GATEWAY" when one exists.
# A scoped-only physical default does NOT count: ordinary traffic does not use it.
physical_default_usable() {
    _pu_snap="$1"; _pu_found=""
    while read -r _pu_n _pu_s _pu_gw; do
        [ -n "${_pu_n:-}" ] || continue
        [ "$_pu_s" = "0" ] || continue
        snapshot_is_tunnel "$_pu_snap" "$_pu_n" && continue
        if gw_on_link_for "$_pu_n" "$_pu_gw"; then
            _pu_found="$_pu_n $_pu_gw"
            break
        fi
    done <<EOF
$(default_rows "$2")
EOF
    [ -n "$_pu_found" ] || return 1
    printf '%s\n' "$_pu_found"
}

# §4.3(b)'s narrow rule, ported for this transport (O-11): the first UNSCOPED
# default on a non-tunnel link whose next hop the guard refuses FOR A REASON THAT
# PROVES THE HOP CANNOT CARRY TRAFFIC. Prints "NETIF GATEWAY REASON" and returns
# 0; returns 1 when there is no such row.
#
# The reason, not the refusal, is what authorises the deletion. The six below all
# say the link is present, up and addressed and the hop still cannot work. Every
# other refusal — targetInterfaceDown, targetInterfaceMissing,
# targetInterfaceUnconfigured, malformedInterfaceName, malformedGateway (an
# `-interface` default, gateway `link#N`) — describes the SNAPSHOT or the shape of
# the row, not the next hop, and a link mid-DHCP or briefly down is the normal
# state in the window a reconcile runs in. Those are left alone.
#
# WHY THIS LIST IS *NOT* THE SWEEP'S RULE, and must not be "harmonised" with it.
# NetReconcile's sweep KEEPS a route whose gateway is a live link's own, network
# or broadcast address (FR-2.6c), while this function names those same three
# reasons as authorising deletion. Both are correct, because the routes differ:
#   * a DEFAULT route is the one route whose destination means that keeping a dead
#     one blackholes the entire machine, and it is deleted here only as the first
#     half of "delete, then install a guarded replacement" — one operation, never
#     a deletion on its own;
#   * a swept exception route has a specific destination, gets no replacement, and
#     FR-2.6c deliberately draws its line at on-link-ness rather than usability.
# A future reader who makes the two lists agree breaks one requirement or the
# other.
stale_unscoped_default() {
    _sd_snap="$1"; _sd_found=""
    while read -r _sd_n _sd_s _sd_gw; do
        [ -n "${_sd_n:-}" ] || continue
        [ "$_sd_s" = "0" ] || continue            # a scoped row is not THE default
        snapshot_is_tunnel "$_sd_snap" "$_sd_n" && continue   # step 2 owns those
        # A hop the guard accepts is a working default and is never deleted —
        # which is also what makes this safe to call after physical_default_usable
        # has already said no such row exists.
        gw_on_link_for "$_sd_n" "$_sd_gw" && continue
        case "$GUARD_REASON" in
            gatewayOffLink|gatewayIsTunnelAddress|gatewayIsOwnAddress|\
unspecifiedGateway|gatewayIsNetworkAddress|gatewayIsBroadcastAddress)
                _sd_found="$_sd_n $_sd_gw $GUARD_REASON"
                break
                ;;
            *)
                echo "kept the unscoped default via $_sd_gw on $_sd_n:" \
                     "reject($GUARD_REASON) describes the link, not the next hop" >&2
                ;;
        esac
    done <<EOF
$(default_rows "$2")
EOF
    [ -n "$_sd_found" ] || return 1
    printf '%s\n' "$_sd_found"
}

# Argument-protocol version. Bump whenever a subcommand's arguments change, so
# an app paired with an older installed helper can detect the mismatch instead
# of invoking it with arguments that mean something else.
#
# 3: restore-default takes an INTERFACE and derives the gateway itself, and
# reconcile is new. A version-2 helper handed a bare interface name would read it
# as the gateway address. Above the source-only guard so the parity test can
# assert it by sourcing this file.
HELPER_VERSION=3

# LOAD-BEARING for test/test-onlink-guard.sh, which sources this file to run the
# Swift guard's case table against the shell port. Everything above is
# definitions; everything below either exits (the openconnect discovery's die) or
# eats positional parameters, so the test could not reach the guard functions at
# all without this. Placed here, not lower, for exactly that reason. Do not move
# it down and do not delete it.
[ "${ANYWAY_HELPER_SOURCE_ONLY:-0}" = "1" ] && return 0

# --- openconnect, from a fixed allowlist and never from an argument ----------
OPENCONNECT=""
for _c in /opt/homebrew/bin/openconnect /usr/local/bin/openconnect /usr/bin/openconnect; do
    [ -x "$_c" ] && { OPENCONNECT="$_c"; break; }
done
[ -n "$OPENCONNECT" ] || die "openconnect not found in /opt/homebrew/bin, /usr/local/bin, /usr/bin"

CMD="${1:-}"; shift 2>/dev/null || true
case "$CMD" in
    version)
        echo "$HELPER_VERSION"
        exit 0
        ;;

    tunnel)
        PROTO="${1:-}"; FP="${2:-}"; RES="${3:-}"; HOST="${4:-}"
        AUTO="${5:-0}"; EXC="${6:--}"

        valid_proto "$PROTO"  || die "bad protocol '$PROTO'"
        valid_fp "$FP"        || die "bad fingerprint"
        valid_resolve "$RES"  || die "bad resolve '$RES'"
        valid_host "$HOST"    || die "bad host '$HOST'"
        case "$AUTO" in 0|1) ;; *) die "bad auto_subnet '$AUTO'" ;; esac

        # Validate every argument before touching the filesystem, so a bad
        # argument is reported as such rather than as a missing install.
        _routes=""
        if [ "$EXC" != "-" ] && [ -n "$EXC" ]; then
            _oldifs="$IFS"
            IFS=','
            for _c in $EXC; do
                IFS="$_oldifs"
                _c="$(printf '%s' "$_c" | tr -d '[:space:]')"
                if [ -n "$_c" ]; then
                    valid_cidr "$_c" || die "bad exception route '$_c'"
                    _routes="$_routes $_c"
                fi
                IFS=','
            done
            IFS="$_oldifs"
        fi

        assert_root_owned "$ROUTE_WRAPPER"
        assert_root_owned "$VPNC_SCRIPT"

        # LAN config for the route wrapper. Paths are ours, not the caller's.
        export ANYWAY_AUTO_SUBNET="$AUTO"
        export ANYWAY_VPNC_SCRIPT="$VPNC_SCRIPT"
        [ -n "$_routes" ] && export ANYWAY_EXCEPTION_ROUTES="${_routes# }"

        set -- --protocol="$PROTO" --cookie-on-stdin --timestamp --pid-file="$PIDFILE"
        [ "$FP" != "-" ] && set -- "$@" --servercert="$FP"
        [ "$RES" != "-" ] && set -- "$@" --resolve="$RES"
        # "--" ends option parsing, so a host can never be read as a flag.
        set -- "$@" --script="$ROUTE_WRAPPER" -- "$HOST"
        exec "$OPENCONNECT" "$@"
        ;;

    stop)
        [ "$#" -ge 1 ] || die "usage: stop PID..."
        for p in "$@"; do case "$p" in *[!0-9]*|'') die "bad pid '$p'" ;; esac; done
        # SIGINT asks openconnect to tear the tunnel down gracefully, which
        # includes running the --script for "disconnect" to remove its routes.
        # Escalating on a fixed 2s timer interrupted that mid-spawn ("Failed to
        # spawn script ... Interrupted system call"), so wait and only escalate
        # if it is genuinely stuck.
        kill -INT "$@" 2>/dev/null || true
        _n=0
        while [ "$_n" -lt 40 ]; do
            _alive=0
            for p in "$@"; do kill -0 "$p" 2>/dev/null && _alive=1; done
            [ "$_alive" = "0" ] && exit 0
            sleep 0.25
            _n=$((_n + 1))
        done
        echo "openconnect still alive after 10s; escalating to SIGTERM" >&2
        kill -TERM "$@" 2>/dev/null || true
        exit 0
        ;;

    restore-default)
        # Restore the physical default route after a failed tunnel left it
        # pointing at a dead utun (which blackholes the network).
        #
        # ONE argument, and no gateway among them: the caller's idea of "the
        # gateway" is exactly what blackholed the carried-home laptop — a value
        # captured on the office LAN and replayed verbatim at home. The gateway
        # is derived HERE, privileged-side, and guarded against the link it is
        # about to be installed on.
        IFACE="${1:-}"
        valid_iface "$IFACE" || die "bad interface '$IFACE'"
        restore_target_iface "$IFACE" || die "'$IFACE' is not a valid restore target"
        # Guard reasons are printed to stderr by gw_on_link_for, which the app
        # captures and logs; GUARD_REASON cannot cross the command substitution.
        GW="$(derive_gateway "$IFACE")" \
            || die "no acceptable gateway for $IFACE (see reasons above)"
        # Same privileged-side precondition as the daemon: only touch the
        # UNSCOPED default when it is absent, already ours, or on a tunnel.
        # Deleting somebody else's working default would be the very outcome
        # this subcommand exists to repair.
        CUR="$(current_default_iface)"
        case "${CUR:-}" in
            ''|"$IFACE"|utun*|ppp*|ipsec*)
                route -n delete default >/dev/null 2>&1 || true
                echo "replaced the unscoped default (was ${CUR:-none})" >&2 ;;
            *)  echo "left the unscoped default via $CUR alone" >&2 ;;
        esac
        route -n add default "$GW" -ifscope "$IFACE" >/dev/null 2>&1 || true
        # Unconditional, and its EEXIST is EXPECTED: when a correct unscoped
        # default survived the precondition above there is nothing to add, and
        # this is still the add that restores service for ordinary traffic.
        route -n add default "$GW" >/dev/null 2>&1 || true
        echo "restored default via $GW ($IFACE)"
        # The sentinel the app reads from the FINAL LINE OF STDOUT, because sudo's
        # exit status is not available to it.
        echo "restore-default: ok"
        exit 0
        ;;

    reconcile)
        # Unwedge the network after a tunnel died without tearing itself down:
        # clear the tunnel's configd IPv4/DNS overrides, remove its default
        # route, and install a guarded physical default.
        #
        # This arm deliberately does LESS than the daemon's reconcile (open issue
        # O-7): there is no dead-gateway sweep. Porting the route-table parser and
        # a mass deletion into POSIX sh would duplicate the riskiest code where
        # the Swift harness cannot reach it.
        #
        # It DOES delete a stale unscoped physical default, narrowly
        # (`stale_unscoped_default` above, O-11), because the alternative is worse
        # than the asymmetry: with a carried-home `default 10.0.1.1 UGScg en0` in
        # the slot, both `route add` calls fail with EEXIST and the machine stays
        # blackholed. §4.3(g)'s "never delete a default that could carry traffic
        # without installing one" holds here the same way it holds in the daemon:
        # the deletion is guard-gated, and it happens immediately before the add
        # that replaces it, in the same operation — never on its own.
        #
        # Diagnostics go to stderr; the final line of stdout is the sentinel.
        [ "$#" -eq 0 ] || die "usage: reconcile (takes no arguments)"
        _rc_why=""

        # FR-2.2. Mutating routing under a live tunnel would tear down a working
        # connection, so this is the one gate that is checked before anything.
        if _rc_pid="$(live_tunnel_pid)"; then
            echo "tunnel alive (pid $_rc_pid) — nothing to do"
            echo "reconcile: ok"
            exit 0
        fi

        SNAP="$(iface_snapshot)"
        TABLE="$("$NETSTAT" -rn -f inet 2>/dev/null)"
        KEYS="$(configd_tunnel_keys)"

        # The tunnel scope, shared by the configd removals and the default-route
        # deletion: every tunnel we can see, minus the ones that were already up
        # when we connected. Without the subtraction a launch- or wake-time
        # reconcile on a machine also running Tailscale, Zscaler or a
        # profile-installed IKEv2 tunnel would dismantle that product's routing
        # and resolver configuration every time this app starts.
        if PRE="$(netstate_preexisting_tunnels)"; then
            :
        else
            PRE=""
            echo "netstate absent or unparsable — acting on every tunnel seen" >&2
        fi
        SEEN="$( { printf '%s\n' "$SNAP" | awk '
                      ($3 == 1) || ($1 ~ /^(utun|ppp|ipsec|gif|stf)/) { print $1 }'
                   default_rows "$TABLE" | awk '$1 ~ /^utun[0-9][0-9]?[0-9]?$/ { print $1 }'
                   printf '%s\n' "$KEYS" | awk -F/ 'NF >= 5 { print $4 }'
                 } | sort -u | grep -v '^$' || true)"
        INSCOPE=""
        for _rc_t in $SEEN; do
            _rc_foreign=0
            for _rc_f in $PRE; do [ "$_rc_t" = "$_rc_f" ] && _rc_foreign=1; done
            if [ "$_rc_foreign" = "1" ]; then
                echo "left foreign tunnel $_rc_t alone (it predates our connect)" >&2
            else
                INSCOPE="$INSCOPE $_rc_t"
            fi
        done

        # 1. configd first, so DNS comes back. IPv4 before DNS per tunnel,
        #    ascending by name — the same order the vendored vpnc-script uses in
        #    its own removal heredoc.
        _rc_remove=""; _rc_nkeys=0
        for _rc_t in $INSCOPE; do
            for _rc_k in IPv4 DNS; do
                _rc_key="State:/Network/Service/$_rc_t/$_rc_k"
                if printf '%s\n' "$KEYS" | grep -qx "$_rc_key"; then
                    _rc_remove="$_rc_remove $_rc_key"
                    _rc_nkeys=$((_rc_nkeys + 1))
                fi
            done
        done
        if [ "$_rc_nkeys" -gt 0 ]; then
            if { echo open
                 for _rc_key in $_rc_remove; do echo "remove $_rc_key"; done
                 echo close
               } | "$SCUTIL" >/dev/null 2>&1; then
                echo "cleared $_rc_nkeys tunnel configd key(s):$_rc_remove"
            else
                echo "scutil refused to remove:$_rc_remove" >&2
                _rc_why="scutil remove failed"
            fi
        else
            echo "no tunnel configd keys to clear"
        fi

        # 2. The tunnel's default route, deleted by SCOPING. A -ifscope'd row is
        #    deleted by name, which is ASSUMED to hit exactly that scoped row and
        #    never the unscoped default (assumption 1 in NetReconcile.swift's
        #    ReconcileCommand comment — unverified, because confirming it means
        #    running it); an unscoped row is deleted only while the kernel still
        #    answers the unscoped default with that interface, because
        #    `route -n delete default` names no interface and would otherwise
        #    remove whatever happens to be there.
        _rc_ndel=0
        while read -r _rc_n _rc_s _rc_gw; do
            [ -n "${_rc_n:-}" ] || continue
            _rc_in=0
            for _rc_t in $INSCOPE; do [ "$_rc_n" = "$_rc_t" ] && _rc_in=1; done
            [ "$_rc_in" = "1" ] || continue
            if [ "$_rc_s" = "1" ]; then
                route -n delete default -ifscope "$_rc_n" >/dev/null 2>&1 || true
                echo "deleted the $_rc_n-scoped default route"
                _rc_ndel=$((_rc_ndel + 1))
            else
                _rc_i=0
                while [ "$_rc_i" -lt 8 ] && [ "$(current_default_iface)" = "$_rc_n" ]; do
                    route -n delete default >/dev/null 2>&1 || break
                    _rc_i=$((_rc_i + 1))
                done
                echo "deleted $_rc_i unscoped default route(s) on $_rc_n; current default now $(current_default_iface || true)"
                _rc_ndel=$((_rc_ndel + _rc_i))
            fi
        done <<EOF
$(default_rows "$TABLE")
EOF
        [ "$_rc_ndel" -gt 0 ] || echo "no tunnel default route to remove"

        # 3. The install, which is the command whose omission turns this
        #    operation into the very outcome it exists to prevent. Re-probed:
        #    the deletions above have changed both inputs (FR-2.8).
        SNAP="$(iface_snapshot)"
        TABLE="$("$NETSTAT" -rn -f inet 2>/dev/null)"
        if USABLE="$(physical_default_usable "$SNAP" "$TABLE")"; then
            echo "physical default already usable ($USABLE); no install needed"
        elif TARGET="$(pick_install_target "$SNAP" "$TABLE")"; then
            if GW="$(derive_gateway "$TARGET")"; then
                # The stale row that would otherwise make the add below a no-op
                # EEXIST. Evaluated through the guard, deleted only for a reason
                # that proves the hop cannot carry traffic, and only while the
                # kernel still answers the unscoped default with that interface —
                # `route -n delete default` names no interface, so without that
                # check it would remove whatever happens to be in the slot.
                if STALE="$(stale_unscoped_default "$SNAP" "$TABLE")"; then
                    read -r _rc_sn _rc_sg _rc_sr <<EOF
$STALE
EOF
                    _rc_cur="$(current_default_iface)"
                    if [ "${_rc_cur:-}" = "$_rc_sn" ]; then
                        route -n delete default >/dev/null 2>&1 || true
                        echo "deleted the stale unscoped default via $_rc_sg on" \
                             "$_rc_sn (reject($_rc_sr))" >&2
                    else
                        echo "left the unscoped default alone: the kernel answers" \
                             "it with ${_rc_cur:-none}, not $_rc_sn" >&2
                    fi
                fi
                # The scoped add keeps its `|| true`: its EEXIST is benign, and
                # ordinary traffic does not use a scoped default anyway.
                route -n add default "$GW" -ifscope "$TARGET" >/dev/null 2>&1 || true
                # THE install, and its status is NOT discarded. Reaching here means
                # physical_default_usable found no usable unscoped default, so a
                # failure now means the machine still has none — reporting "installed
                # default via …" and then the ok sentinel would tell the app the
                # network was repaired while it is still blackholed.
                if route -n add default "$GW" >/dev/null 2>&1; then
                    echo "installed default via $GW ($TARGET)"
                else
                    echo "route -n add default $GW FAILED and no usable unscoped" \
                         "default exists — routing is NOT repaired" >&2
                    _rc_why="could not install the unscoped default via $GW on $TARGET"
                fi
            else
                # FR-1.9: a refusal means routing is left exactly as it was.
                echo "install REFUSED for $TARGET — no acceptable gateway" >&2
                _rc_why="no acceptable gateway for $TARGET"
            fi
        else
            _rc_why="no install target"
        fi

        # O-7, and the reason this transport is the weaker one.
        echo "sweep unavailable on the sudo-helper transport" >&2

        if [ -n "$_rc_why" ]; then
            # The app judges the sentinel, not the exit status (it cannot see
            # sudo's). The status is here for a human running this by hand.
            echo "reconcile: failed $_rc_why"
            exit 1
        fi
        echo "reconcile: ok"
        exit 0
        ;;

    *) die "unknown subcommand '$CMD'" ;;
esac
