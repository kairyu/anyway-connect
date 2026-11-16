#!/bin/sh
#
# Tests the Homebrew cask's refusal to uninstall while a tunnel is up.
#
# The cask's `uninstall` stanza unregisters the privileged daemon and then deletes
# /usr/local/libexec/anyway-connect, where route-wrapper.sh lives — the `--script`
# openconnect was given when the tunnel was built, and what it runs at disconnect to put
# the routing table and the resolvers back. Deleting it under a live tunnel leaves
# nothing to undo what the tunnel did. `brew upgrade` runs that uninstall, so a routine
# version bump would leave the routing table wedged with nothing to undo it. The
# guard in uninstall_preflight is what stands in the way, and this is what keeps it
# honest.
#
# Two layers, because the guard has two distinct ways to fail.
#
# It can stop being valid Ruby. It is forty lines of Ruby inside a shell heredoc in
# make-cask.sh, where an unescaped backtick or dollar sign is consumed by the shell and
# never reported — the rendered cask would simply be wrong, and `brew install` would
# fail for everyone with a syntax error. `ruby -c` on the rendered output catches that,
# and it is the same gate both workflows run before uploading a cask.
#
# It can stop being correct. That is the harness, which extracts the block from the
# RENDERED cask and executes it against real pids with Homebrew's DSL shimmed. See
# test/cask-guard-harness.rb for why it is built that way.
#
# NOTHING LIVE IS TOUCHED. No cask is installed, no tunnel is started, /var/run is not
# read, and brew is never invoked — this suite runs anywhere ruby does.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
WORK="${TMPDIR:-/tmp}/anyway-cask-guard-test"
CASK="$WORK/anyway-connect.rb"

rm -rf "$WORK"
mkdir -p "$WORK" || exit 1

pass=0; fail=0
note() { printf '%s\n' "$1"; }
ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }

# Arbitrary but well-formed: the guard does not depend on either value, and using a real
# past release would invite someone to "update" them.
if sh "$ROOT/scripts/make-cask.sh" 1.0.0 \
      0000000000000000000000000000000000000000000000000000000000000000 > "$CASK" 2>"$WORK/err"
then ok
else bad "make-cask.sh exited non-zero: $(cat "$WORK/err")"
fi

if [ -s "$CASK" ]; then ok; else bad "make-cask.sh rendered an empty cask"; fi

# The gate the release and CI workflows both apply before a cask is uploaded.
if ruby -c "$CASK" >/dev/null 2>"$WORK/err"
then ok
else bad "rendered cask is not valid Ruby: $(cat "$WORK/err")"
fi

# Presence is asserted separately from behaviour so that deleting the stanza reads as
# "the guard is gone" rather than as a puzzling parse failure in the harness.
if grep -q '^  uninstall_preflight do' "$CASK"
then ok
else bad "rendered cask has no uninstall_preflight stanza — the guard is missing"
fi

# A guard that cannot abort is decoration. The declarative *_steps DSL Homebrew is
# steering casks towards has no way to raise, which is why this stanza stays legacy.
if grep -q 'raise Cask::CaskError' "$CASK"
then ok
else bad "the guard no longer raises — it cannot stop an uninstall"
fi

note "--- guard behaviour ---"
if ruby "$DIR/cask-guard-harness.rb" "$CASK"; then
    # The harness prints and accounts for its own cases; roll its verdict in as one.
    ok
else
    bad "cask-guard-harness.rb reported failures (see above)"
fi

rm -rf "$WORK"
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
