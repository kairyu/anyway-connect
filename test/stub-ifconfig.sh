#!/bin/sh
#
# Fixture-printing stand-in for /sbin/ifconfig, used ONLY by
# test/test-onlink-guard.sh. A real executable at an absolute path, not a shell
# function: scripts/anyway-root-helper.sh assigns its command paths
# unconditionally and the test overrides those variables AFTER sourcing, so what
# it points them at has to be something the kernel can exec. Absolute-path
# hardening is preserved and nothing live is read.
#
# The snapshot is chosen by STUB_SNAPSHOT, so one stub serves every case:
#   guard  — design §9.1 Suite 1's snapshot, verbatim
#   home   — design §9.1 Suite 8's snapshot (the laptop at home)
#
# …and the four dual-homed snapshots pick_install_target is asserted against,
# all of them paired with STUB_ROUTE_TABLE=dual-default or unspecified-default
# and mirroring test/fixtures/interfaces.dual-default*.json so the two arms
# answer the same question on the same input:
#   dual-default             — en0 then en8, both up and addressed
#   dual-default-reversed    — the SAME two links, en8 printed first
#   dual-default-en0-absent  — en8 only
#   dual-default-en0-down    — both addressed, en0 printing NO `UP` token
#
# Indentation matters: real ifconfig indents an interface's detail lines with a
# TAB, so the tabs here are produced with printf rather than typed, and the inet
# lines carry the netmask as the hex literal ifconfig actually prints.

set -u
T="$(printf '\t')"

case "${STUB_SNAPSHOT:-guard}" in
    guard)
        # en0  10.0.1.22/24      up, broadcast
        # en1  no IPv4           up
        # en2  192.168.1.2/31    up    (no network/broadcast address exists)
        # en3  203.0.113.9/32    up
        # en4  10.0.1.40/24      DOWN
        # en6  no IPv4           DOWN  (unconfigured must beat down)
        # en5  ABSENT            — Suite 1 case 3 asks about an interface that
        #                          is not in the snapshot at all
        # utun7 192.168.204.16   point-to-point: the observed bad gateway
        # utun9 10.9.9.9         up, broadcast — tunnel-like BY NAME only
        printf '%s\n' \
            'lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384' \
            "${T}inet 127.0.0.1 netmask 0xff000000" \
            'en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500' \
            "${T}options=6460<TSO4,TSO6,CHANNEL_IO,PARTIAL_CSUM,ZEROINVERT_CSUM>" \
            "${T}inet 10.0.1.22 netmask 0xffffff00 broadcast 10.0.1.255" \
            "${T}status: active" \
            'en1: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500' \
            "${T}nd6 options=201<PERFORMNUD,DAD>" \
            "${T}status: inactive" \
            'en2: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500' \
            "${T}inet 192.168.1.2 netmask 0xfffffffe broadcast 192.168.1.3" \
            'en3: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500' \
            "${T}inet 203.0.113.9 netmask 0xffffffff" \
            'en4: flags=8862<BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500' \
            "${T}inet 10.0.1.40 netmask 0xffffff00 broadcast 10.0.1.255" \
            'en6: flags=8862<BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500' \
            "${T}nd6 options=201<PERFORMNUD,DAD>" \
            'utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1294' \
            "${T}inet 192.168.204.16 --> 192.168.204.16 netmask 0xffffffff" \
            'utun9: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500' \
            "${T}inet 10.9.9.9 netmask 0xffffff00 broadcast 10.9.9.255"
        ;;
    home)
        printf '%s\n' \
            'lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384' \
            "${T}inet 127.0.0.1 netmask 0xff000000" \
            'en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500' \
            "${T}inet 192.168.1.42 netmask 0xffffff00 broadcast 192.168.1.255" \
            "${T}status: active"
        ;;
    dual-default)
        printf '%s\n' \
            'lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384' \
            "${T}inet 127.0.0.1 netmask 0xff000000" \
            'en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500' \
            "${T}inet 10.0.1.42 netmask 0xffffff00 broadcast 10.0.1.255" \
            "${T}status: active" \
            'en8: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500' \
            "${T}inet 192.168.1.42 netmask 0xffffff00 broadcast 192.168.1.255" \
            "${T}status: active"
        ;;
    dual-default-reversed)
        # Byte-identical links to `dual-default`, printed the other way round.
        printf '%s\n' \
            'lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384' \
            "${T}inet 127.0.0.1 netmask 0xff000000" \
            'en8: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500' \
            "${T}inet 192.168.1.42 netmask 0xffffff00 broadcast 192.168.1.255" \
            "${T}status: active" \
            'en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500' \
            "${T}inet 10.0.1.42 netmask 0xffffff00 broadcast 10.0.1.255" \
            "${T}status: active"
        ;;
    dual-default-en0-absent)
        printf '%s\n' \
            'lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384' \
            "${T}inet 127.0.0.1 netmask 0xff000000" \
            'en8: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500' \
            "${T}inet 192.168.1.42 netmask 0xffffff00 broadcast 192.168.1.255" \
            "${T}status: active"
        ;;
    dual-default-en0-down)
        # en0 prints WITHOUT the `UP` token — the DOWN variant, which is
        # expressible on this arm because iface_snapshot reads that single token.
        printf '%s\n' \
            'lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384' \
            "${T}inet 127.0.0.1 netmask 0xff000000" \
            'en0: flags=8862<BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500' \
            "${T}inet 10.0.1.42 netmask 0xffffff00 broadcast 10.0.1.255" \
            'en8: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500' \
            "${T}inet 192.168.1.42 netmask 0xffffff00 broadcast 192.168.1.255" \
            "${T}status: active"
        ;;
    *)
        echo "stub-ifconfig: unknown STUB_SNAPSHOT '${STUB_SNAPSHOT:-}'" >&2
        exit 64
        ;;
esac
