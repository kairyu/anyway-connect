#!/bin/sh
#
# Fixture-printing stand-in for /usr/sbin/ipconfig, used ONLY by
# test/test-onlink-guard.sh. See stub-ifconfig.sh for why these are real
# executables rather than shell functions.
#
# Only `getoption <iface> router` is implemented, because that is the only
# ipconfig invocation the shell helper makes: derive_gateway has no getsummary
# fallback (a documented divergence from the Swift ladder, open issue O-6), so a
# stub that answered getsummary would be testing something that does not exist.
#
# STUB_DHCP_ROUTER holds the answer. Empty or unset means "no lease", which is
# what a statically configured link reports.

set -u

if [ "${1:-}" = "getoption" ] && [ "${3:-}" = "router" ]; then
    [ -n "${STUB_DHCP_ROUTER:-}" ] && printf '%s\n' "$STUB_DHCP_ROUTER"
    exit 0
fi

echo "stub-ipconfig: unexpected invocation: $*" >&2
exit 64
