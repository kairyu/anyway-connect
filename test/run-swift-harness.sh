#!/bin/sh
#
# Compile and run the Swift harness in test/harness/ against the REAL app
# sources, after four static gates and an independent re-derivation of every
# expected list.
#
# WHY A RUNNER AND NOT A TEST TARGET. There is no Xcode project and no SwiftPM
# manifest in this repo, so the only way to execute the pure decision layer is
# to compile it together with a throwaway entry point. That used to be an
# uncommitted scratch file, and it was lost to a /tmp prune — which is what made
# "the 282 cases stay green" unverifiable and why the suites are committed now.
#
# THE SCRATCH PATH IS FIXED AT /tmp/anyway-scratch AND THE BINARY IS ALWAYS `a`.
# Each distinct executable path costs the developer a separate approval prompt,
# so the path is reused rather than made unique per run. Overwrite in place; do
# not add a timestamp, a pid or an experiment name.
#
# Three defects in the previous runner, all found by EXECUTING the commands
# rather than reading them, are fixed here and the reasons are recorded so they
# are not reintroduced:
#
#   1. The pattern-literal grep used a BRE (`'route-wrapper\\.sh\|...'`), in
#      which `\\` is one literal backslash while the Swift source carries two.
#      It matched nothing, so the gate fired on every tree, passing or not.
#      Now `grep -cF`, which matches the Swift text verbatim.
#   2. The SIGKILL gate was `grep -n SIGKILL … | grep -v timeout`, which matches
#      BOTH the intended overrun kill and its comment, because the word
#      `timeout` is on the function's SIGNATURE line and not on either of them.
#      Now a count, anchored on the enclosing function AND taken file-wide, with
#      the `kill(` form chosen so neither line is matched by accident.
#   3. The compile step was `swiftc … | grep error: ; ./a`, whose status is
#      grep's and which ran `./a` regardless. Since the scratch binary is
#      reused, a failed compile left the PREVIOUS binary in place and the runner
#      reported "N passed / 0 failed" for sources that do not build. Now the
#      binary is deleted first and required back.
set -u

cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
D=/tmp/anyway-scratch                      # the FIXED path; the binary is always `a`

# ── Gate 1: re-derive every expected list and diff it ───────────────────────
#
# BEFORE compiling, so a list that moved is reported as a derivation mismatch
# rather than as a Swift assertion failure. test/harness/derive-expected.sh
# re-implements the sweep classification, the destination canonicalisation and
# the first-seen ordering from the fixture text plus the paired interface
# snapshot, reading no Swift source and calling no planner. The harness then
# asserts the committed files element for element — so the planner and an
# independent derivation are pinned to each other, and a hand-edited expected
# file fails here.
mkdir -p "$D" || exit 1
fixtures="clean vpn-up carried-home lingering-utun link-down no-default
          two-physical two-tunnels cap-exceeded dual-default unspecified-default
          late-tunnel live-shape live-shape.stale-en8"
for f in $fixtures; do
    for kind in sweep kept; do
        want="test/harness/expected/$f.$kind.txt"
        [ -f "$want" ] || { echo "missing expected file: $want" >&2; exit 1; }
        if [ "$kind" = kept ]; then
            sh test/harness/derive-expected.sh --kept "$f" > "$D/derived.txt" 2>/dev/null
        else
            sh test/harness/derive-expected.sh "$f" > "$D/derived.txt" 2>/dev/null
        fi
        if ! diff -u "$want" "$D/derived.txt"; then
            echo "derivation mismatch for $f ($kind)" >&2
            rm -f "$D/derived.txt"
            exit 1
        fi
    done
done
rm -f "$D/derived.txt"
echo "derivation: every expected list re-derived from the fixtures and identical"
# `dual-default` is the one route table shared by FOUR snapshots, which is the
# whole point of it: the install target must come from the snapshot and not from
# netstat print order. Suite 13 asserts all four against ONE pair of expected
# files, so the claim that its sweep and its clause-(c) kept records are
# IDENTICAL under every snapshot is derived here rather than assumed. The two
# stale host routes are off-link for every link in every one of them.
for snap in dual-default.reversed dual-default.en0-absent dual-default.en0-down; do
    for kind in sweep kept; do
        if [ "$kind" = kept ]; then
            sh test/harness/derive-expected.sh --kept dual-default "$snap" > "$D/derived.txt" 2>/dev/null
        else
            sh test/harness/derive-expected.sh dual-default "$snap" > "$D/derived.txt" 2>/dev/null
        fi
        if ! diff -u "test/harness/expected/dual-default.$kind.txt" "$D/derived.txt"; then
            echo "dual-default's $kind list is not snapshot-independent ($snap)" >&2
            rm -f "$D/derived.txt"
            exit 1
        fi
    done
done
rm -f "$D/derived.txt"
echo "derivation: dual-default's sweep is identical under all four of its snapshots"

# The README's multi-netif check, with the sweep's own destination filters
# applied, so "every swept destination appears on exactly one netif" is CHECKED
# rather than assumed. The unfiltered form in test/fixtures/README.md:275-279
# reports `default`, `224.0.0/4` and `255.255.255.255/32`, which are documented
# there and are all outside the sweep — the filters below are exactly the ones
# that exclude them, so this must print nothing.
multi=$(awk '
    /^Destination/ { for (i = 1; i <= NF; i++) col[$i] = i; seen = 1; next }
    !seen { next }
    $(col["Gateway"]) !~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/ { next }
    $(col["Destination"]) == "default" { next }
    $(col["Netif"]) == "lo0" { next }
    $(col["Destination"]) ~ /^(127|169\.254|22[4-9]|23[0-9]|255\.255\.255\.255)[\.\/]/ { next }
    $(col["Destination"]) ~ /^(127|169\.254)$/ { next }
    { nif[$(col["Destination"])] = nif[$(col["Destination"])] " " $(col["Netif"]) " " }
    END { for (k in nif) { n = split(nif[k], a, " "); u = " "
            for (i = 1; i <= n; i++) if (a[i] != "" && index(u, " " a[i] " ") == 0) u = u a[i] " "
            if (split(u, b, " ") > 1) print "multi-netif:", k, u } }' \
    test/fixtures/netstat-rn-inet.carried-home.txt)
[ -z "$multi" ] || { echo "a swept destination appears on two netifs:" >&2
                     echo "$multi" >&2; exit 1; }
echo "multi-netif: every candidate-swept destination is on exactly one netif"

# ── Gate 2: the harness references nothing impure ───────────────────────────
#
# SCOPED TO test/harness/*.swift, never to the copied tree: `ConfigStore.shared`
# appears legitimately in VPNRunner.swift, AppDelegate.swift and
# SettingsWindow.swift, and `NetProbe.` in VPNRunner.swift, so a grep over the
# copies could never be zero and this gate would fail every run.
#
# `ConfigStore.shared` resolves ~/.config/anyway-connect/config.json in a private
# initialiser with no override, so a harness that touches it can WRITE the
# developer's live config — that has caused data loss twice. The two `path`
# constants are here because reaching for a default path means opening a
# root-owned live file under /var/run; the suites decode from literal Data.
if grep -nE 'ConfigStore\.shared|VPNRunner\.shared|NetProbe\.|NetState\.path|TunnelAttribution\.path' \
        test/harness/*.swift; then
    echo "forbidden reference in the harness" >&2; exit 1
fi
if grep -nE 'NSApp\.activate' test/harness/*.swift; then
    echo "the harness must never steal focus from the developer's session" >&2; exit 1
fi
echo "static: no forbidden reference in test/harness/*.swift"

# ── Gate 3: the only SIGKILL in the daemon is the bounded runner's overrun kill
#
# Keyed to the enclosing function AND taken file-wide, both with the `kill(`
# form, because `grep -v timeout` matches neither of the two lines it was meant
# to exclude.
inrun=$(awk '/func run\(/,/^    }$/' AnywayConnectHelper/main.swift | grep -c 'kill(.*SIGKILL')
allk=$(grep -c 'kill(.*SIGKILL' AnywayConnectHelper/main.swift)
if [ "$inrun" != "1" ] || [ "$allk" != "1" ]; then
    echo "unexpected SIGKILL in the daemon (in run(: $inrun, file-wide: $allk)" >&2
    exit 1
fi
echo "static: the daemon's only SIGKILL is the bounded runner's overrun kill"

# ── Gate 4: ONE pgrep pattern literal per binary ────────────────────────────
#
# -F because the Swift source carries a doubled backslash that a BRE would not
# match. A WARNING rather than a failure at this point in the change set:
# VPNRunner.swift legitimately holds TWO copies (:271 and :1067) until the
# defect-1 work hoists the second into a single constant. FLIP THIS TO A HARD
# FAILURE in that step, and delete this paragraph with it.
for f in AnywayConnectHelper/main.swift AnywayConnect/VPNRunner.swift; do
    n=$(grep -cF 'route-wrapper\\.sh|--cookie-on-stdin' "$f")
    if [ "$n" != "1" ]; then
        echo "WARNING: the openconnect pattern is not a single literal in $f (found $n)" >&2
    fi
done
echo "static: pattern-literal count checked (warning only until the hoist)"

# ── Compile ─────────────────────────────────────────────────────────────────
mkdir -p "$D"
rm -f "$D"/*.swift 2>/dev/null
for f in AnywayConnect/*.swift; do
    [ "$(basename "$f")" = "main.swift" ] || cp "$f" "$D"/
done
cp test/harness/*.swift "$D"/              # supplies its own main.swift

rm -f "$D/a"
( cd "$D" && swiftc -O *.swift -o a 2>&1 | grep error: ; true )
if [ ! -x "$D/a" ]; then
    echo "harness did not compile" >&2
    rm -f "$D"/*.swift
    exit 1
fi

# ── Run ─────────────────────────────────────────────────────────────────────
#
# ANYWAY_SINGLE_INSTANCE=0 because otherwise SingleInstance hands off to the
# already-running app and this exits immediately; under `timeout` because a
# harness that waited on a run loop would hang. The two paths are passed in
# rather than guessed: the binary runs from /tmp and has no idea where the
# worktree is.
( cd "$D" && ANYWAY_SINGLE_INSTANCE=0 \
    ANYWAY_FIXTURES="$ROOT/test/fixtures" \
    ANYWAY_EXPECTED="$ROOT/test/harness/expected" \
    timeout 120 ./a )
status=$?

rm -f "$D"/*.swift "$D"/*.png
exit "$status"
