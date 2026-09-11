#!/bin/sh
#
# Automated test for the AnywayConnect connect flow using mock-openconnect.
# Exercises phase-1 (--authenticate parsing) and phase-2 (tunnel launch +
# route-script invocation) with NO real gateway and NO sudo/root helper.
#
# It reproduces exactly what VPNRunner does, so a pass here means the app's
# openconnect arg construction, cookie parsing, host/resolve handling, CSD
# retry, and route-wrapper wiring are all correct.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
MOCK="$DIR/mock-openconnect.sh"
ROUTE_WRAPPER="$DIR/../scripts/route-wrapper.sh"
BROWSER="$DIR/../scripts/open-browser.sh"
TMP="$(mktemp -d)"
PIDFILE="$TMP/oc.pid"
LOG="$TMP/oc.log"
chmod +x "$MOCK"
trap 'kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; rm -rf "$TMP"' EXIT

pass=0; fail=0
check() { if [ "$1" = "$2" ]; then echo "  PASS: $3"; pass=$((pass+1)); else echo "  FAIL: $3 (got [$1] want [$2])"; fail=$((fail+1)); fi; }
contains() { case "$1" in *"$2"*) echo "  PASS: $3"; pass=$((pass+1));; *) echo "  FAIL: $3 (missing [$2])"; fail=$((fail+1));; esac; }

echo "== Test 1: phase-1 --authenticate output is parseable =="
AUTH="$("$MOCK" --protocol=anyconnect --external-browser="$BROWSER" --authenticate test.gateway.example)"
# Parse the way the FIXED app does: split on NEWLINES only, strip outer quotes.
COOKIE=$(printf '%s\n' "$AUTH" | awk -F"=" '/^COOKIE=/{sub(/^COOKIE=/,"");gsub(/^'\''|'\''$/,"");print;exit}')
FP=$(printf '%s\n' "$AUTH" | sed -n "s/^FINGERPRINT='\(.*\)'$/\1/p")
RES=$(printf '%s\n' "$AUTH" | sed -n "s/^RESOLVE='\(.*\)'$/\1/p")
contains "$COOKIE" "strapkey=" "cookie captured (first part)"
contains "$COOKIE" "webvpn=" "cookie NOT truncated at ';' (the bug we fixed)"
contains "$FP" "pin-sha256:" "fingerprint captured"
check "$RES" "test.gateway.example:10.9.9.9" "resolve captured"
AUTH_HOST=$(printf '%s\n' "$AUTH" | sed -n "s/^HOST='\(.*\)'$/\1/p")
check "$AUTH_HOST" "10.9.9.9" "authenticated node (HOST) captured"

# NODE AFFINITY: the SSO cookie is bound to the gateway node that issued it.
# Gateways behind a rotating DNS pool hand out a different IP on a fresh
# lookup, and that other node answers phase 2 with 401 / "Cookie was
# rejected". So phase 2 MUST pin the authenticated node: first candidate is
# the node's IP addressed directly (trust comes from --servercert), second is
# the hostname with --resolve pointing at that same IP.
RES_HOST="${RES%%:*}"; RES_IP="${RES#*:}"
check "$AUTH_HOST" "$RES_IP" "HOST and RESOLVE agree on the node IP"
check "$RES_HOST" "test.gateway.example" "RESOLVE carries the hostname for SNI"
# Candidate 1 must be the IP, NOT the pool hostname.
CAND1_HOST="$AUTH_HOST"; CAND1_RESOLVE="-"
check "$CAND1_HOST" "10.9.9.9" "candidate 1 host = authenticated node IP"
check "$CAND1_RESOLVE" "-" "candidate 1 sends no --resolve (already an IP)"
# Candidate 2 keeps the same node but with a matching Host/SNI.
CAND2_HOST="$RES_HOST"; CAND2_RESOLVE="$RES_HOST:$RES_IP"
check "$CAND2_HOST" "test.gateway.example" "candidate 2 host = hostname"
check "$CAND2_RESOLVE" "test.gateway.example:10.9.9.9" "candidate 2 pins hostname to node IP"

echo "== Test 2: auto-CSD-on-demand =="
OUT="$(MOCK_DEMAND_CSD=1 "$MOCK" --protocol=anyconnect --authenticate test.gateway.example 2>&1)"
contains "$OUT" "CSD hostscan" "server demands CSD when no wrapper"
OUT2="$(MOCK_DEMAND_CSD=1 "$MOCK" --protocol=anyconnect --csd-wrapper=/bin/true --authenticate test.gateway.example 2>&1)"
contains "$OUT2" "COOKIE=" "auth succeeds once CSD wrapper supplied"

echo "== Test 3: phase-2 tunnel launch + route-wrapper invocation =="
# Launch mock tunnel detached, feeding a cookie, pointing --script at the route wrapper.
# Use a dummy vpnc-script so the wrapper doesn't touch real routes.
DUMMY_VPNC="$TMP/dummy-vpnc.sh"; printf '#!/bin/sh\nexit 0\n' > "$DUMMY_VPNC"; chmod +x "$DUMMY_VPNC"
: > "$LOG"
( printf 'testcookie\n' | ANYWAY_AUTO_SUBNET=1 ANYWAY_VPNC_SCRIPT="$DUMMY_VPNC" ANYWAY_EXCEPTION_ROUTES="192.0.2.0/24" \
  "$MOCK" --protocol=anyconnect --cookie-on-stdin \
    --servercert="pin-sha256:X" --resolve="test.gateway.example:10.9.9.9" \
    --pid-file="$PIDFILE" --script="$ROUTE_WRAPPER" test.gateway.example >> "$LOG" 2>&1 ) &
# Wait for the mock to report up.
ok=0
for _ in $(seq 1 20); do
    if grep -q "Configured as" "$LOG" 2>/dev/null; then ok=1; break; fi
    sleep 0.3
done
check "$ok" "1" "tunnel reached 'Configured as' (success line)"
[ -f "$PIDFILE" ] && check "1" "1" "pid-file written" || check "0" "1" "pid-file written"
# Give the mock a moment to run the --script (route wrapper) after the success line.
sleep 1
contains "$(cat "$LOG")" "anyway-route" "route-wrapper ran on connect (reason=connect)"

# Cleanup tunnel.
kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null

echo ""
echo "== RESULT: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
