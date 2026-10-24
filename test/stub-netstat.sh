#!/bin/sh
#
# Fixture-printing stand-in for /usr/sbin/netstat, used ONLY by
# test/test-onlink-guard.sh. See stub-ifconfig.sh for why these are real
# executables rather than shell functions.
#
# Only `-rn -f inet` is implemented — the one invocation the shell helper makes.
# STUB_ROUTE_TABLE selects the table:
#   home-default — a default via the home router on en0, the Suite 8 case 2 table
#   empty        — netstat produced nothing at all (a failed probe)
#   no-default   — a readable table with no default route in it
#
# The column widths are the real ones, because the helper derives its column
# indices from the header rather than counting fields.

set -u

[ "${1:-}" = "-rn" ] || { echo "stub-netstat: unexpected invocation: $*" >&2; exit 64; }

case "${STUB_ROUTE_TABLE:-empty}" in
    home-default)
        printf '%s\n' \
            'Routing tables' \
            '' \
            'Internet:' \
            'Destination        Gateway            Flags               Netif Expire' \
            'default            192.168.1.1        UGScg                 en0       ' \
            '127                127.0.0.1          UCS                   lo0       ' \
            '192.168.1/24       link#15            UCSc                  en0      !' \
            '192.168.1.1/32     link#15            UCS                   en0      !'
        ;;
    no-default)
        printf '%s\n' \
            'Routing tables' \
            '' \
            'Internet:' \
            'Destination        Gateway            Flags               Netif Expire' \
            '127                127.0.0.1          UCS                   lo0       ' \
            '192.168.1/24       link#15            UCSc                  en0      !'
        ;;
    empty)
        ;;
    *)
        echo "stub-netstat: unknown STUB_ROUTE_TABLE '${STUB_ROUTE_TABLE:-}'" >&2
        exit 64
        ;;
esac
