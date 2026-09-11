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
#   restore-default <gateway> [interface]
#
# Install with scripts/install-privileged.sh. Keep root-owned, mode 0755.

set -u

LIBEXEC="/usr/local/libexec/anyway-connect"
ROUTE_WRAPPER="$LIBEXEC/route-wrapper.sh"
VPNC_SCRIPT="$LIBEXEC/vpnc-script"
PIDFILE="/var/run/anyway-connect.pid"

die() { echo "anyway-root-helper: $*" >&2; exit 2; }

# --- openconnect, from a fixed allowlist and never from an argument ----------
OPENCONNECT=""
for _c in /opt/homebrew/bin/openconnect /usr/local/bin/openconnect /usr/bin/openconnect; do
    [ -x "$_c" ] && { OPENCONNECT="$_c"; break; }
done
[ -n "$OPENCONNECT" ] || die "openconnect not found in /opt/homebrew/bin, /usr/local/bin, /usr/bin"

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
valid_ipv4() {
    case "$1" in *[!0-9.]*|'') return 1 ;; esac
    return 0
}
valid_iface() {
    case "$1" in *[!a-z0-9]*|'') return 1 ;; esac
    return 0
}

# Argument-protocol version. Bump whenever a subcommand's arguments change, so
# an app paired with an older installed helper can detect the mismatch instead
# of invoking it with arguments that mean something else.
HELPER_VERSION=2

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
        GW="${1:-}"; IFACE="${2:-}"
        valid_ipv4 "$GW" || die "bad gateway '$GW'"
        [ -z "$IFACE" ] || valid_iface "$IFACE" || die "bad interface '$IFACE'"
        route -n delete default >/dev/null 2>&1 || true
        if [ -n "$IFACE" ]; then
            route -n add default "$GW" -ifscope "$IFACE" >/dev/null 2>&1 || true
        fi
        route -n add default "$GW" >/dev/null 2>&1 || true
        echo "restored default via $GW ${IFACE:+($IFACE)}"
        exit 0
        ;;

    *) die "unknown subcommand '$CMD'" ;;
esac
