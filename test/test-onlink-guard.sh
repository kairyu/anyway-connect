#!/bin/sh
#
# Parity test for the on-link guard: the SAME case table the Swift harness runs
# as Suite 1, executed against the POSIX sh port in
# scripts/anyway-root-helper.sh, asserting the SAME rejection-reason strings.
#
# This is the mitigation for the duplicate implementation the requirements
# mandate (open issue O-6). The shell guard is a copy of, not a call into,
# NetGuard.swift's evaluateDefaultGateway — and route-wrapper.sh carries a third
# copy of the address arithmetic — so what keeps them honest is one case table
# run against each. If this file and the harness ever disagree, one of the two
# guards is wrong and a privileged route decision rests on the difference.
#
# NOTHING LIVE IS TOUCHED. The helper is SOURCED with ANYWAY_HELPER_SOURCE_ONLY=1
# (the source-only guard is what makes that safe: below it the openconnect
# discovery would `die`, i.e. exit the sourcing shell) and its three command
# paths are then pointed at fixture-printing stubs. No route, scutil, ifconfig,
# ipconfig or netstat is executed, and no subcommand runs.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
chmod +x "$DIR/stub-ifconfig.sh" "$DIR/stub-ipconfig.sh" "$DIR/stub-netstat.sh"

pass=0; fail=0
check() {
    if [ "$1" = "$2" ]; then
        echo "  PASS: $3"; pass=$((pass + 1))
    else
        echo "  FAIL: $3 (got [$1] want [$2])"; fail=$((fail + 1))
    fi
}

# The order is load-bearing: the helper assigns IFCONFIG/IPCONFIG/NETSTAT
# UNCONDITIONALLY — it runs as root under a NOPASSWD rule and must take no
# command path from its environment — so the override has to happen AFTER
# sourcing. That works because the guard functions read the variables at call
# time. Deliberately NOT exported, for the same reason the helper does not read
# the environment; the STUB_* variables below are the test's own and are.
ANYWAY_HELPER_SOURCE_ONLY=1 . "$DIR/../scripts/anyway-root-helper.sh"
IFCONFIG="$DIR/stub-ifconfig.sh"
IPCONFIG="$DIR/stub-ipconfig.sh"
NETSTAT="$DIR/stub-netstat.sh"

export STUB_SNAPSHOT=guard
export STUB_DHCP_ROUTER=""
export STUB_ROUTE_TABLE=empty

# "accept", or the GUARD_REASON string — which is exactly the GatewayRejection
# raw value the Swift suite asserts.
verdict() {
    if gw_on_link_for "$1" "$2" 2>/dev/null; then echo "accept"; else echo "$GUARD_REASON"; fi
}

echo "== Test 0: the version the app requires, and the sourcing seam itself =="
check "$HELPER_VERSION" "3" "HELPER_VERSION is 3 (restore-default takes an interface; reconcile exists)"
check "$(command -v gw_on_link_for >/dev/null 2>&1 && echo yes)" "yes" "sourcing reached the guard definitions"

echo "== Test 1: the whole-interface snapshot (pass-4 finding 5) =="
SNAP="$(iface_snapshot)"
check "$(printf '%s\n' "$SNAP" | awk '$1 == "en0"')" \
      "en0 1 0 0 10.0.1.22/0xffffff00" "en0: up, not p2p, not loopback, one address + hex mask"
check "$(printf '%s\n' "$SNAP" | awk '$1 == "en1"')" \
      "en1 1 0 0" "en1: present and up with NO address (different from absent)"
check "$(printf '%s\n' "$SNAP" | awk '$1 == "en4"')" \
      "en4 0 0 0 10.0.1.40/0xffffff00" "en4: addressed but DOWN"
check "$(printf '%s\n' "$SNAP" | awk '$1 == "utun7"')" \
      "utun7 1 1 0 192.168.204.16/0xffffffff" "utun7: the POINTOPOINT flag is read, and the peer address is not"
check "$(printf '%s\n' "$SNAP" | awk '$1 == "lo0"')" \
      "lo0 1 0 1 127.0.0.1/0xff000000" "lo0: the LOOPBACK flag is read"
check "$(printf '%s\n' "$SNAP" | awk '$1 == "en5"')" \
      "" "en5 is absent from the snapshot, which is what Suite 1 case 3 asks about"

echo "== Test 2: Suite 1's case table, same inputs, same reasons =="
# 1-5: the four literal acceptance cases plus the own-address rule.
check "$(verdict en0 10.0.1.1)"          "accept"                     "case 1  10.0.1.1 on en0 -> accept (AC-3)"
check "$(verdict en0 192.168.1.1)"       "gatewayOffLink"             "case 2  192.168.1.1 on en0 -> gatewayOffLink (AC-4)"
check "$(verdict en5 10.0.1.1)"          "targetInterfaceMissing"     "case 3  en5 is not in the snapshot (AC-5)"
check "$(verdict en0 192.168.204.16)"    "gatewayIsTunnelAddress"     "case 4  the OBSERVED failure, by name (AC-6)"
check "$(verdict en0 10.0.1.22)"         "gatewayIsOwnAddress"        "case 5  the target's own address is not a next hop"
# 6: the malformed/unspecified family.
check "$(verdict en0 0.0.0.0)"           "unspecifiedGateway"         "case 6a 0.0.0.0"
check "$(verdict en0 255.255.255.255)"   "unspecifiedGateway"         "case 6b 255.255.255.255"
check "$(verdict en0 '')"                "malformedGateway"           "case 6c the empty string"
check "$(verdict en0 10.0.1)"            "malformedGateway"           "case 6d three octets"
check "$(verdict en0 nope)"              "malformedGateway"           "case 6e not an address at all"
check "$(verdict en0 999.999.999.999)"   "malformedGateway"           "case 6f octets over 255"
check "$(verdict en0 010.0.1.1)"         "malformedGateway"           "case 6g a leading zero (and \$((010)) is octal here)"
# 7-9: target-side rejections, in the order the Swift guard reports them.
check "$(verdict utun7 10.0.1.1)"        "targetInterfaceIsTunnel"    "case 7  a tunnel is never a restore target (FR-1.8)"
check "$(verdict en0 10.0.1.0)"          "gatewayIsNetworkAddress"    "case 8a the subnet's network address"
check "$(verdict en0 10.0.1.255)"        "gatewayIsBroadcastAddress"  "case 8b the subnet's broadcast address"
check "$(verdict en1 10.0.1.1)"          "targetInterfaceUnconfigured" "case 9  present but unaddressed"
# 10-14: the rest of the table.
check "$(verdict en0 10.0.1.5)"          "accept"                     "case 10 a different in-subnet address"
check "$(verdict en2 192.168.1.3)"       "accept"                     "case 11 the /31 peer: no network or broadcast exists"
check "$(verdict en2 192.168.1.0)"       "gatewayOffLink"             "case 11b masks to a different /31"
check "$(verdict en3 203.0.113.10)"      "gatewayOffLink"             "case 11c at /32 only the own address is in-subnet"
check "$(verdict en0 10.9.9.9)"          "gatewayIsTunnelAddress"     "case 12 tunnel-like BY NAME (utun9 is not point-to-point)"
check "$(verdict en4 10.0.1.1)"          "targetInterfaceDown"        "case 13 present, addressed, down"
check "$(verdict en6 10.0.1.1)"          "targetInterfaceUnconfigured" "case 14 unaddressed AND down reports unconfigured"
# The interface name itself, which becomes an argv element for a root `route`.
check "$(verdict '' 10.0.1.1)"           "malformedInterfaceName"     "name: empty"
check "$(verdict EN0 10.0.1.1)"          "malformedInterfaceName"     "name: not lowercase alphanumeric"
check "$(verdict enaaaaaaaaaaaaaaa 10.0.1.1)" "malformedInterfaceName" "name: longer than IFNAMSIZ-1"

echo "== Test 3: the reason also reaches the APP, which only has stderr =="
# derive_gateway runs in a command substitution, so GUARD_REASON cannot cross
# back; the app reads these lines from the helper's stderr.
ERR="$(gw_on_link_for en0 192.168.1.1 2>&1 >/dev/null || true)"
check "$ERR" "guard: en0 192.168.1.1 -> reject(gatewayOffLink)" "the rejection is echoed to stderr verbatim"

echo "== Test 4: restore_target_iface (PrivilegedValidation.isRestoreTargetInterface) =="
rti() { if restore_target_iface "$1"; then echo ok; else echo no; fi; }
check "$(rti en0)"               "ok" "en0 is a restore target"
check "$(rti utun7)"             "no" "a utun is not (FR-1.8)"
check "$(rti ppp0)"              "no" "nor a ppp link"
check "$(rti enaaaaaaaaaaaaaaa)" "no" "nor a name the kernel cannot hold"
check "$(rti '')"                "no" "nor an empty name"

echo "== Test 5: Suite 8's derivation ladder, cases 1, 2 and 5 =="
STUB_SNAPSHOT=home           # en0 = 192.168.1.42/24, the laptop AT HOME
derived() { if derive_gateway "$1" 2>/dev/null; then :; else echo "-"; fi; }

STUB_DHCP_ROUTER="192.168.1.1"; STUB_ROUTE_TABLE=home-default
check "$(derived en0)" "192.168.1.1" "case 1  a live DHCP lease wins"

STUB_DHCP_ROUTER=""; STUB_ROUTE_TABLE=home-default
check "$(derived en0)" "192.168.1.1" "case 2  no lease: the table's own default for en0"

STUB_DHCP_ROUTER="10.0.1.1"; STUB_ROUTE_TABLE=home-default
check "$(derived en0)" "192.168.1.1" "case 3  a stale off-link lease is rejected, the table answers"
check "$(derive_gateway en0 2>&1 >/dev/null | grep -c 'reject(gatewayOffLink)')" "1" \
      "case 3  and the dhcp rejection is in the transcript"

# Case 5 is the reported incident: at home, with no lease yet and nothing in the
# table, the office gateway 10.0.1.1 must NOT be installed. The Swift ladder
# refuses it at candidate 3's subnet precondition; this transport never reads the
# netstate at all (O-6), so it refuses one step earlier — the same verdict by a
# narrower route, and it is the SAFE direction of divergence.
STUB_DHCP_ROUTER=""; STUB_ROUTE_TABLE=empty
check "$(derived en0)" "-" "case 5  carried home with nothing to derive from: REFUSE"
STUB_DHCP_ROUTER=""; STUB_ROUTE_TABLE=no-default
check "$(derived en0)" "-" "case 5b a readable table with no default: still refuse"
if derive_gateway en0 >/dev/null 2>&1; then
    check "refused" "exit-non-zero" "case 5  derive_gateway's exit status"
else
    check "exit-non-zero" "exit-non-zero" "case 5  derive_gateway's exit status"
fi

echo ""
echo "== RESULT: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
