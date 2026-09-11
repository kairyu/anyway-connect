#!/bin/sh
#
# mock-openconnect.sh — a fake `openconnect` for testing AnywayConnect end-to-end
# with no real gateway. Understands the two modes the app uses:
#
#   --authenticate ... <host>   -> print realistic COOKIE/HOST/FINGERPRINT/RESOLVE and exit 0
#   --cookie-on-stdin ...       -> simulate a running tunnel: print success lines,
#                                  run the --script (route wrapper) with reason=connect,
#                                  write the pid-file, then sleep until killed.
#
# It also honors --csd-wrapper (runs it, ignores result) so the CSD path is exercised.
#
# Env:
#   MOCK_FAIL_AUTH=1   -> phase 1 prints an error and exits non-zero
#   MOCK_DEMAND_CSD=1  -> phase 1 without --csd-wrapper prints the CSD hostscan error
#                         (to exercise the app's auto-CSD-on-demand retry)

MODE=""
HOST=""
HAS_CSD=0
SCRIPT=""
PIDFILE=""
for a in "$@"; do
    case "$a" in
        --authenticate) MODE="auth" ;;
        --cookie-on-stdin) MODE="tunnel" ;;
        --csd-wrapper=*) HAS_CSD=1 ;;
        --script=*) SCRIPT="${a#--script=}" ;;
        --pid-file=*) PIDFILE="${a#--pid-file=}" ;;
        --*) : ;;
        *) HOST="$a" ;;   # last bare arg is the host
    esac
done

if [ "$MODE" = "auth" ]; then
    if [ "${MOCK_FAIL_AUTH:-0}" = "1" ]; then
        echo "Failed to complete authentication" >&2
        exit 1
    fi
    if [ "${MOCK_DEMAND_CSD:-0}" = "1" ] && [ "$HAS_CSD" = "0" ]; then
        echo "Error: Server asked us to run CSD hostscan." >&2
        echo "You need to provide a suitable --csd-wrapper argument." >&2
        exit 1
    fi
    # Emit the same variable format real openconnect --authenticate prints.
    # NOTE: real cookies contain ';' (e.g. "strapkey=..; webvpn=..") — include
    # one so tests catch any parser that wrongly splits on ';'.
    cat <<EOF
COOKIE='strapkey=MOCK$(date +%s); webvpn=ABC@123@DEF'
HOST='10.9.9.9'
CONNECT_URL='https://${HOST:-mock.test}/'
FINGERPRINT='pin-sha256:MOCKFINGERPRINTAAAAAAAAAAAAAAAAAAAAAAAAAAA='
RESOLVE='${HOST:-mock.test}:10.9.9.9'
EOF
    exit 0
fi

if [ "$MODE" = "tunnel" ]; then
    # Consume the cookie from stdin.
    read -r _cookie 2>/dev/null || true
    echo "Mock: connecting to ${HOST:-mock.test}"
    echo "Established DTLS connection (mock)"
    echo "Configured as 10.9.9.9, with SSL connected and DTLS connected"
    # Write pid file so disconnect can find us.
    [ -n "$PIDFILE" ] && echo "$$" > "$PIDFILE"
    # Run the route script with a connect reason (like real openconnect does).
    if [ -n "$SCRIPT" ] && [ -x "$SCRIPT" ]; then
        reason=connect TUNDEV=utunMOCK "$SCRIPT" 2>&1 || true
    fi
    echo "Mock tunnel up; sleeping until terminated."
    # Stay alive so the app sees a running tunnel; exit cleanly on TERM/INT.
    trap 'echo "Mock: got signal, exiting"; exit 0' INT TERM
    while :; do sleep 1; done
fi

echo "mock-openconnect: unrecognized invocation: $*" >&2
exit 2
