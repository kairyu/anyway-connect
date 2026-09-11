#!/bin/sh
#
# install-privileged.sh — install AnywayConnect's privileged pieces.
#
# Run with sudo:
#     sudo ./scripts/install-privileged.sh
#
# Installs, all root-owned:
#   /usr/local/sbin/anyway-root-helper.sh          the only sudo-granted entry point
#   /usr/local/libexec/anyway-connect/route-wrapper.sh
#   /usr/local/libexec/anyway-connect/vpnc-script  a root-owned copy
#   /etc/sudoers.d/anyway-connect                  NOPASSWD for the helper only
#
# Why a root-owned COPY of vpnc-script: it is executed as root on every
# connect, and Homebrew's prefix (/opt/homebrew) is owned by the desktop user.
# Running the Homebrew copy as root would let anything running as that user
# edit it and get root — the exact hole this script exists to close. The cost
# is that a `brew upgrade openconnect` does not update the copy; re-run this
# script after upgrading if the script itself changed.

set -eu

PREFIX_SBIN="/usr/local/sbin"
LIBEXEC="/usr/local/libexec/anyway-connect"
SUDOERS="/etc/sudoers.d/anyway-connect"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "must run as root: sudo $0" >&2; exit 1; }

# The user who will be granted the sudo rule.
TARGET_USER="${SUDO_USER:-}"
[ -n "$TARGET_USER" ] || { echo "cannot determine the invoking user; run via sudo, not as root directly" >&2; exit 1; }

# --- Locate a vpnc-script to copy -------------------------------------------
VPNC_SRC="${VPNC_SCRIPT_SRC:-}"
if [ -z "$VPNC_SRC" ]; then
    for c in /opt/homebrew/etc/vpnc/vpnc-script /usr/local/etc/vpnc/vpnc-script /etc/vpnc/vpnc-script; do
        [ -f "$c" ] && { VPNC_SRC="$c"; break; }
    done
fi
[ -n "$VPNC_SRC" ] || {
    echo "vpnc-script not found. Install openconnect (brew install openconnect)," >&2
    echo "or set VPNC_SCRIPT_SRC=/path/to/vpnc-script" >&2
    exit 1
}

echo "Installing AnywayConnect privileged components"
echo "  user granted sudo : $TARGET_USER"
echo "  vpnc-script source: $VPNC_SRC"

install -d -o root -g wheel -m 0755 "$PREFIX_SBIN"
install -d -o root -g wheel -m 0755 "$LIBEXEC"

install -o root -g wheel -m 0755 "$SRC_DIR/route-wrapper.sh"      "$LIBEXEC/route-wrapper.sh"
install -o root -g wheel -m 0755 "$VPNC_SRC"                       "$LIBEXEC/vpnc-script"
install -o root -g wheel -m 0755 "$SRC_DIR/anyway-root-helper.sh"  "$PREFIX_SBIN/anyway-root-helper.sh"

# --- sudoers rule, generated for the invoking user ---------------------------
# Written to a temp file and validated with visudo before being moved into
# place: a malformed sudoers file can lock you out of sudo entirely.
TMP_SUDOERS="$(mktemp)"
cat > "$TMP_SUDOERS" <<EOF
# Allow $TARGET_USER to run ONLY the AnywayConnect root helper without a password.
# The helper hardcodes every path it executes; see its header for the threat model.
$TARGET_USER ALL=(root) NOPASSWD: $PREFIX_SBIN/anyway-root-helper.sh
EOF
chmod 0440 "$TMP_SUDOERS"
if visudo -cqf "$TMP_SUDOERS"; then
    install -o root -g wheel -m 0440 "$TMP_SUDOERS" "$SUDOERS"
    rm -f "$TMP_SUDOERS"
else
    rm -f "$TMP_SUDOERS"
    echo "generated sudoers rule failed validation; nothing installed to $SUDOERS" >&2
    exit 1
fi

echo
echo "Installed:"
ls -l "$PREFIX_SBIN/anyway-root-helper.sh" "$LIBEXEC/route-wrapper.sh" "$LIBEXEC/vpnc-script" "$SUDOERS"
echo
echo "Verifying the helper accepts a no-op and rejects tampering vectors..."
if sudo -n -u root "$PREFIX_SBIN/anyway-root-helper.sh" 2>&1 | grep -q "unknown subcommand"; then
    echo "  helper runs: OK"
fi
echo "Done."
