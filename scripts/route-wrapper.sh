#!/bin/sh
#
# AnywayConnect route wrapper (--script for openconnect).
# openconnect execs this as root on connect/disconnect. It runs the real
# vpnc-script, then re-adds the local subnet and/or manual exception routes so
# they stay reachable while the VPN routes are in effect.
#
# Configuration is passed via environment variables (set by the caller), so
# this script has NO dependencies beyond POSIX sh + route/ifconfig:
#   ANYWAY_VPNC_SCRIPT       path to the real vpnc-script
#   ANYWAY_AUTO_SUBNET       "1" to auto-add the physical local subnet
#   ANYWAY_EXCEPTION_ROUTES  space-separated CIDRs to keep via physical gw
#
# NOTE: keeping local/other networks reachable while on a corporate VPN may
# violate that network's acceptable-use policy. Generic tool; user is
# responsible for compliant use.

REAL_VPNC_SCRIPT="${ANYWAY_VPNC_SCRIPT:-/opt/homebrew/etc/vpnc/vpnc-script}"

log() { printf '[%s] [anyway-route] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# Snapshot the default route BEFORE handing over to the real vpnc-script: once
# that has installed the tunnel routes, "route get default" answers with the
# utun, and every downstream lookup based on it is wrong.
PRE_IF=""; PRE_GW=""
case "$reason" in
    connect|reconnect)
        PRE_IF="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
        PRE_GW="$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')"
        ;;
esac

"$REAL_VPNC_SCRIPT"
RET=$?

# Resolve the physical path out to the internet. The route to the VPN gateway is
# authoritative: vpnc-script pins it to the physical link, so it stays correct
# even after the tunnel has taken over the default route.
PHYS_IF=""; PHYS_GW=""
if [ -n "${VPNGATEWAY:-}" ]; then
    PHYS_IF="$(route -n get "$VPNGATEWAY" 2>/dev/null | awk '/interface:/{print $2}')"
    PHYS_GW="$(route -n get "$VPNGATEWAY" 2>/dev/null | awk '/gateway:/{print $2}')"
fi
# Fall back to what the default route looked like before the tunnel came up.
[ -z "$PHYS_IF" ] && PHYS_IF="$PRE_IF"
# A gateway on the same link has no "gateway:" line; borrow the pre-tunnel one.
[ -z "$PHYS_GW" ] && PHYS_GW="$PRE_GW"
# Never mistake a tunnel for the physical path.
case "$PHYS_IF" in
    utun*|ppp*|ipsec*) PHYS_IF=""; PHYS_GW="" ;;
esac

# A destination reached through a router. Correct for anything OUTSIDE the local
# subnet — and wrong for anything inside it, which is what add_onlink_route is for.
add_route() {
    _net="$1"; _gw="$2"; _if="$3"
    # Both forms, for the same reason as add_onlink_route: a surviving
    # interface-scoped duplicate would keep winning over whatever we install.
    _n=0
    while [ "$_n" -lt 8 ] && /sbin/route -n delete -net "$_net" >/dev/null 2>&1; do
        _n=$((_n + 1))
    done
    if [ -n "$_if" ]; then
        _n=0
        while [ "$_n" -lt 8 ] && /sbin/route -n delete -net "$_net" -ifscope "$_if" >/dev/null 2>&1; do
            _n=$((_n + 1))
        done
    fi
    [ -n "$_if" ] && /sbin/route -n add -net "$_net" "$_gw" -ifscope "$_if" >/dev/null 2>&1
    if /sbin/route -n add -net "$_net" "$_gw" >/dev/null 2>&1; then
        log "kept $_net via $_gw ${_if:+($_if)}"
    else
        log "FAILED to keep $_net via $_gw ${_if:+($_if)}"
    fi
}

# A destination on the same link, delivered by ARP rather than handed to a router.
#
# This distinction is the whole ballgame for the local subnet. Adding it as a
# gateway route ("route add -net 10.0.1.0/24 10.0.1.1") replaces the on-link
# entry macOS maintains, and every peer on the subnet then has its packets sent
# to the router instead of being ARP'd directly. The router has no reason to
# hairpin them back, so the LAN goes dark — while the gateway itself still
# answers, because it is the next hop. The symptom is a reachable router, silent
# peers, and no ARP entries for them at all.
add_onlink_route() {
    _net="$1"; _if="$2"
    [ -n "$_if" ] || { log "no interface for on-link $_net"; return 1; }
    # Clear EVERY existing form of this route, unscoped and interface-scoped.
    #
    # `route delete -net X` removes only the unscoped entry. An interface-scoped
    # duplicate — which this script's gateway-form path also installs — survives it
    # and still wins for traffic on that interface. That is exactly how a stale
    # "10.0.1/24 via 10.0.1.1 UGScI" kept beating the correct on-link route: the
    # on-link route was added successfully and simply never took effect.
    #
    # Bounded rather than `while ... do :; done` so a route that cannot be deleted
    # can't spin here forever.
    _n=0
    while [ "$_n" -lt 8 ] && /sbin/route -n delete -net "$_net" >/dev/null 2>&1; do
        _n=$((_n + 1))
    done
    _n=0
    while [ "$_n" -lt 8 ] && /sbin/route -n delete -net "$_net" -ifscope "$_if" >/dev/null 2>&1; do
        _n=$((_n + 1))
    done
    /sbin/route -n add -net "$_net" -interface "$_if" -ifscope "$_if" >/dev/null 2>&1
    if /sbin/route -n add -net "$_net" -interface "$_if" >/dev/null 2>&1; then
        log "kept $_net on-link via $_if"
    else
        log "FAILED to keep $_net on-link via $_if"
    fi
}

del_route() { /sbin/route -n delete -net "$1" "$2" >/dev/null 2>&1; }

# Mask a dotted IPv4 address to a prefix length. POSIX arithmetic only: no ** and
# no python, so the partial octet comes from a lookup.
mask_to() {
    _i="$1"; _b="$2"
    _a1=$(echo "$_i" | cut -d. -f1); _a2=$(echo "$_i" | cut -d. -f2)
    _a3=$(echo "$_i" | cut -d. -f3); _a4=$(echo "$_i" | cut -d. -f4)
    _r="$_b"; _m1=0; _m2=0; _m3=0; _m4=0
    for _oct in 1 2 3 4; do
        if [ "$_r" -ge 8 ]; then _v=255; _r=$((_r - 8))
        else
            case "$_r" in
                0) _v=0;;   1) _v=128;; 2) _v=192;; 3) _v=224;;
                4) _v=240;; 5) _v=248;; 6) _v=252;; 7) _v=254;;
            esac
            _r=0
        fi
        case "$_oct" in 1) _m1=$_v;; 2) _m2=$_v;; 3) _m3=$_v;; 4) _m4=$_v;; esac
    done
    echo "$((_a1 & _m1)).$((_a2 & _m2)).$((_a3 & _m3)).$((_a4 & _m4))"
}

# True when CIDR/address $1 falls inside subnet CIDR $2.
inside_subnet() {
    _cand="${1%%/*}"; _sub="$2"
    _subnet="${_sub%%/*}"; _subbits="${_sub##*/}"
    [ -n "$_subnet" ] && [ -n "$_subbits" ] || return 1
    [ "$(mask_to "$_cand" "$_subbits")" = "$(mask_to "$_subnet" "$_subbits")" ]
}

# Compute the local subnet CIDR of an interface, POSIX-only (no python).
local_subnet() {
    _if="$1"
    [ -n "$_if" ] || return 1
    # Point-to-point links have no local subnet, and their "inet" line carries
    # the peer address where a broadcast link puts the netmask — reading it
    # positionally is what produced "0x2.: invalid arithmetic operator".
    if ifconfig "$_if" 2>/dev/null | grep -q 'POINTOPOINT'; then
        log "$_if is point-to-point; no local subnet to keep"
        return 1
    fi
    _ip="$(ifconfig "$_if" 2>/dev/null | awk '/inet /{print $2; exit}')"
    # Find the netmask by keyword rather than field position.
    _mask="$(ifconfig "$_if" 2>/dev/null | awk '/inet /{for(i=1;i<=NF;i++) if($i=="netmask"){print $(i+1); exit}}')"
    [ -n "$_ip" ] || return 1
    [ -n "$_mask" ] || { log "no netmask found on $_if"; return 1; }
    # Only a hex mask (0xffffff00) is understood. Anything else means the line
    # was mis-read, and guessing would install a bogus route.
    case "$_mask" in
        0x[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
        *) log "unexpected netmask '$_mask' on $_if; skipping LAN route"; return 1 ;;
    esac
    _hex="${_mask#0x}"
    # Hex mask -> prefix length.
    _bits=0
    for _b in $(echo "$_hex" | sed 's/../& /g'); do
        case "$_b" in
            ff) _bits=$((_bits+8));; fe) _bits=$((_bits+7));; fc) _bits=$((_bits+6));;
            f8) _bits=$((_bits+5));; f0) _bits=$((_bits+4));; e0) _bits=$((_bits+3));;
            c0) _bits=$((_bits+2));; 80) _bits=$((_bits+1));; 00) ;;
        esac
    done
    # Network address = ip AND mask, per octet.
    _o1=$(echo "$_ip" | cut -d. -f1); _o2=$(echo "$_ip" | cut -d. -f2)
    _o3=$(echo "$_ip" | cut -d. -f3); _o4=$(echo "$_ip" | cut -d. -f4)
    _m1=$((0x$(echo "$_hex" | cut -c1-2))); _m2=$((0x$(echo "$_hex" | cut -c3-4)))
    _m3=$((0x$(echo "$_hex" | cut -c5-6))); _m4=$((0x$(echo "$_hex" | cut -c7-8)))
    echo "$((_o1&_m1)).$((_o2&_m2)).$((_o3&_m3)).$((_o4&_m4))/$_bits"
}

case "$reason" in
    connect|reconnect)
        if [ -z "$PHYS_IF" ] || [ -z "$PHYS_GW" ]; then
            log "could not determine the physical gateway (if='$PHYS_IF' gw='$PHYS_GW'); no exception routes added"
        else
            log "physical path: $PHYS_GW via $PHYS_IF"
            # Computed even when auto-subnet is off, because exceptions still need
            # to know which of them are on the same link.
            LOCAL_SUBNET="$(local_subnet "$PHYS_IF" 2>/dev/null)" || LOCAL_SUBNET=""
            if [ "${ANYWAY_AUTO_SUBNET:-0}" = "1" ] && [ -n "$LOCAL_SUBNET" ]; then
                add_onlink_route "$LOCAL_SUBNET" "$PHYS_IF"
            fi
            for CIDR in $ANYWAY_EXCEPTION_ROUTES; do
                [ -n "$CIDR" ] || continue
                # An exception inside the local subnet is a neighbour, not something
                # to route through the router. Sending it via the gateway is what
                # made LAN peers unreachable.
                if [ -n "$LOCAL_SUBNET" ] && inside_subnet "$CIDR" "$LOCAL_SUBNET"; then
                    add_onlink_route "$CIDR" "$PHYS_IF"
                else
                    add_route "$CIDR" "$PHYS_GW" "$PHYS_IF"
                fi
            done
        fi
        ;;
    disconnect)
        # Only gateway-form routes are withdrawn. An on-link route for the local
        # subnet, or for a neighbour inside it, is what the system maintains anyway
        # — removing it would take the LAN down rather than restore it.
        if [ -n "$PHYS_GW" ]; then
            LOCAL_SUBNET="$(local_subnet "$PHYS_IF" 2>/dev/null)" || LOCAL_SUBNET=""
            for CIDR in $ANYWAY_EXCEPTION_ROUTES; do
                [ -n "$CIDR" ] || continue
                if [ -n "$LOCAL_SUBNET" ] && inside_subnet "$CIDR" "$LOCAL_SUBNET"; then
                    continue
                fi
                del_route "$CIDR" "$PHYS_GW"
            done
        fi
        ;;
esac
exit $RET
