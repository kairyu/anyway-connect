#!/bin/sh
#
# Fixture-printing stand-in for /usr/sbin/netstat, used ONLY by
# test/test-onlink-guard.sh. See stub-ifconfig.sh for why these are real
# executables rather than shell functions.
#
# Only `-rn -f inet` is implemented — the one invocation the shell helper makes.
# STUB_ROUTE_TABLE selects the table:
#   home-default    — a default via the home router on en0, the Suite 8 case 2 table
#   empty           — netstat produced nothing at all (a failed probe)
#   no-default      — a readable table with no default route in it
# …and the five tables stale_unscoped_default is asserted against (Test 6):
#   carried-home    — THE reported incident: the office default, unscoped, on en0
#   carried-scoped  — the same row but `-ifscope`d, which is not THE default
#   own-address     — a default via en0's OWN address
#   tunnel-gw       — a default via a live utun's address, on a physical link
#   down-link       — a default on a link that is addressed but DOWN
#   interface-only  — an `-interface` default, gateway `link#15`, no IPv4 next hop
# …and the two tables pick_install_target is asserted against (Test 7):
#   dual-default        — en0 AND en8 each with an `-ifscope`-only default via its
#                         own on-link router, EN0'S ROW PRINTED FIRST. The same
#                         shape as test/fixtures/netstat-rn-inet.dual-default.txt,
#                         so both arms answer the same question on one input.
#   unspecified-default — three default rows: `0.0.0.0` on en9 and `link#7` on
#                         en7, neither of them a link in any snapshot, beside
#                         en8's healthy `-ifscope` default
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
    carried-home)
        # The office gateway, carried to the home link: UNSCOPED, so it is the row
        # ordinary traffic uses, and 10.0.1.1 is off-link for 192.168.1.42/24.
        printf '%s\n' \
            'Routing tables' \
            '' \
            'Internet:' \
            'Destination        Gateway            Flags               Netif Expire' \
            'default            10.0.1.1           UGScg                 en0       ' \
            '192.168.1/24       link#15            UCSc                  en0      !'
        ;;
    carried-scoped)
        # The same hop, `-ifscope`d (the capital I). Ordinary traffic does not use
        # it, so it is neither "a usable default" nor a row this deletes.
        printf '%s\n' \
            'Routing tables' \
            '' \
            'Internet:' \
            'Destination        Gateway            Flags               Netif Expire' \
            'default            10.0.1.1           UGScIg                en0       ' \
            '192.168.1/24       link#15            UCSc                  en0      !'
        ;;
    own-address)
        printf '%s\n' \
            'Routing tables' \
            '' \
            'Internet:' \
            'Destination        Gateway            Flags               Netif Expire' \
            'default            10.0.1.22          UGScg                 en0       '
        ;;
    tunnel-gw)
        # The OBSERVED failure in the default slot: utun7's own address installed as
        # a physical link's next hop.
        printf '%s\n' \
            'Routing tables' \
            '' \
            'Internet:' \
            'Destination        Gateway            Flags               Netif Expire' \
            'default            192.168.204.16     UGScg                 en0       '
        ;;
    down-link)
        printf '%s\n' \
            'Routing tables' \
            '' \
            'Internet:' \
            'Destination        Gateway            Flags               Netif Expire' \
            'default            10.0.1.1           UGScg                 en4       '
        ;;
    interface-only)
        printf '%s\n' \
            'Routing tables' \
            '' \
            'Internet:' \
            'Destination        Gateway            Flags               Netif Expire' \
            'default            link#15            UCSg                  en0       '
        ;;
    dual-default)
        # Two usable links, each with a default that ordinary traffic does not
        # use. en0's row is printed FIRST, so a tie resolved by print order
        # cannot be told apart from one resolved by snapshot order — which is
        # exactly why the snapshot is what decides.
        printf '%s\n' \
            'Routing tables' \
            '' \
            'Internet:' \
            'Destination        Gateway            Flags               Netif Expire' \
            'default            10.0.1.1           UGScIg                en0       ' \
            'default            192.168.1.1        UGScIg                en8       ' \
            '10.0.1/24          link#15            UCSc                  en0      !' \
            '192.168.1/24       link#16            UCSc                  en8      !'
        ;;
    unspecified-default)
        # The two pre-lookup rejection reasons in the default slot: `0.0.0.0`
        # (unspecifiedGateway, step 3) and `link#7` (malformedGateway, step 2).
        # Both are returned BEFORE the interface lookup, so neither row's link
        # has to exist — and neither does, in any snapshot.
        printf '%s\n' \
            'Routing tables' \
            '' \
            'Internet:' \
            'Destination        Gateway            Flags               Netif Expire' \
            'default            0.0.0.0            UGSc                  en9       ' \
            'default            link#7             UGSc                  en7       ' \
            'default            192.168.1.1        UGScIg                en8       ' \
            '192.168.1/24       link#16            UCSc                  en8      !'
        ;;
    empty)
        ;;
    *)
        echo "stub-netstat: unknown STUB_ROUTE_TABLE '${STUB_ROUTE_TABLE:-}'" >&2
        exit 64
        ;;
esac
