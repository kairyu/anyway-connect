#!/bin/sh
#
# Assert the invariants a built AnywayConnect.app has to satisfy.
#
# Run locally or from CI:  sh scripts/verify-bundle.sh AnywayConnect.app
#
# These are not style checks. Each one stands for a way the bundle has actually been
# wrong, or could silently become wrong, in a manner that only shows up at run time —
# a daemon that cannot be registered, an icon Finder won't draw, or a root-run script
# missing a patch. A build that passes signing can still fail every one of them.
set -u

APP="${1:-AnywayConnect.app}"
fails=0
ok()   { echo "  ok    $1"; }
bad()  { echo "  FAIL  $1" >&2; fails=$((fails + 1)); }
info() { echo "  --    $1"; }

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

if [ ! -d "$APP" ]; then
    echo "verify-bundle: no bundle at $APP" >&2
    exit 1
fi
echo "Verifying $APP"

INFO="$APP/Contents/Info.plist"
APP_ID=$(plist "$INFO" CFBundleIdentifier)
[ -n "$APP_ID" ] && ok "bundle identifier: $APP_ID" || bad "Info.plist has no CFBundleIdentifier"

# --- Version ----------------------------------------------------------------
# Derived from the git tag at build time, so this is where a broken derivation shows
# up rather than in a shipped bundle that quietly claims 0.0.0.
SHORT=$(plist "$INFO" CFBundleShortVersionString)
BUILDV=$(plist "$INFO" CFBundleVersion)
case "$SHORT" in
    "") bad "Info.plist has no CFBundleShortVersionString" ;;
    # Not a failure on its own: building from a tarball, or from a shallow clone with no
    # tags fetched, legitimately has no version to derive. The release path asserts the
    # real thing through EXPECT_VERSION below.
    0.0.0) info "version is 0.0.0 — built with no tag to derive from (build $BUILDV)" ;;
    *[!0-9.]*) bad "CFBundleShortVersionString '$SHORT' is not dotted integers" ;;
    *) ok "version: $SHORT (build $BUILDV)" ;;
esac
if [ -n "${EXPECT_VERSION:-}" ]; then
    [ "$SHORT" = "${EXPECT_VERSION#v}" ] && ok "version matches the expected ${EXPECT_VERSION#v}" \
        || bad "version is $SHORT but ${EXPECT_VERSION#v} was expected"
fi

# --- Icon -------------------------------------------------------------------
# An Info.plist naming an icon that isn't there gets the same blank page as no icon
# at all, so the promise and the file are checked together.
ICON_NAME=$(plist "$INFO" CFBundleIconFile)
if [ -z "$ICON_NAME" ]; then
    bad "Info.plist has no CFBundleIconFile — Finder will show a blank icon"
else
    ICNS="$APP/Contents/Resources/${ICON_NAME%.icns}.icns"
    if [ -s "$ICNS" ]; then
        ok "icon present: ${ICNS#$APP/}"
        # Round-trips the .icns back to an iconset to count what is really inside it.
        # A file that exists but holds one size would pass a mere existence check and
        # still look wrong everywhere but the Dock.
        ICON_TMP=$(mktemp -d)
        if iconutil -c iconset "$ICNS" -o "$ICON_TMP/out.iconset" >/dev/null 2>&1; then
            n=$(find "$ICON_TMP/out.iconset" -name '*.png' | wc -l | tr -d ' ')
            [ "$n" -eq 10 ] && ok "icon has all 10 sizes" \
                            || bad "icon has $n sizes, expected 10"
        else
            bad "iconutil could not read $ICNS"
        fi
        rm -rf "$ICON_TMP"
    else
        bad "Info.plist promises $ICON_NAME but Resources/${ICON_NAME}.icns is missing or empty"
    fi
fi

# --- Privileged daemon identity ---------------------------------------------
# The launchd label, the plist filename, the MachServices key, BundleProgram and the
# helper binary's name all have to be the same string, or registration fails or the
# XPC name cannot be reached. They are derived from one variable in build-app.sh, but
# the suffix is spelled out independently in PrivilegedProtocol.swift — so this is
# where the two are actually compared.
DAEMON_DIR="$APP/Contents/Library/LaunchDaemons"
count=$(find "$DAEMON_DIR" -name '*.plist' 2>/dev/null | wc -l | tr -d ' ')
if [ "$count" -ne 1 ]; then
    bad "expected exactly 1 LaunchDaemons plist, found $count"
else
    DPLIST=$(find "$DAEMON_DIR" -name '*.plist')
    FILE_LABEL=$(basename "$DPLIST" .plist)
    LABEL=$(plist "$DPLIST" Label)
    PROGRAM=$(plist "$DPLIST" BundleProgram)
    ASSOC=$(plist "$DPLIST" "AssociatedBundleIdentifiers:0")
    MACH=$(/usr/libexec/PlistBuddy -c "Print :MachServices" "$DPLIST" 2>/dev/null \
           | sed -n 's/^ *\([^ =]*\) = .*/\1/p' | head -1)

    [ "$LABEL" = "$FILE_LABEL" ] && ok "daemon label matches its plist filename: $LABEL" \
        || bad "daemon Label ($LABEL) != plist filename ($FILE_LABEL)"
    [ "$MACH" = "$LABEL" ] && ok "MachServices key matches the label" \
        || bad "MachServices key ($MACH) != Label ($LABEL)"
    [ "$PROGRAM" = "Contents/MacOS/$LABEL" ] && ok "BundleProgram points at Contents/MacOS/$LABEL" \
        || bad "BundleProgram ($PROGRAM) != Contents/MacOS/$LABEL"
    [ -x "$APP/Contents/MacOS/$LABEL" ] && ok "daemon binary present and executable" \
        || bad "no executable at Contents/MacOS/$LABEL"
    [ "$ASSOC" = "$APP_ID" ] && ok "AssociatedBundleIdentifiers matches the app" \
        || bad "AssociatedBundleIdentifiers ($ASSOC) != CFBundleIdentifier ($APP_ID)"

    # The duplicated literal: the suffix the build script appended, versus the one the
    # Swift constant will append at run time. Disagreement means the app derives a Mach
    # name the daemon never listens on, and every connect silently falls back to sudo.
    BUILT_SUFFIX=${LABEL#"$APP_ID"}
    SWIFT_SUFFIX=$(sed -n 's/^public let kHelperIdentifierSuffix = "\(.*\)"/\1/p' \
                   AnywayConnect/PrivilegedProtocol.swift 2>/dev/null)
    if [ -z "$SWIFT_SUFFIX" ]; then
        info "could not read kHelperIdentifierSuffix (running outside the source tree)"
    elif [ "$BUILT_SUFFIX" = "$SWIFT_SUFFIX" ]; then
        ok "helper suffix agrees between build-app.sh and PrivilegedProtocol.swift ($SWIFT_SUFFIX)"
    else
        bad "helper suffix disagrees: bundle has '$BUILT_SUFFIX', Swift expects '$SWIFT_SUFFIX'"
    fi
fi

# --- vpnc-script patch ------------------------------------------------------
# openconnect runs this as root. Shipping it unpatched is the one outcome the build
# exists to prevent, so the shipped copy is checked rather than trusted.
VPNC="$APP/Contents/Resources/vpnc-script"
if [ -f "$VPNC" ]; then
    guarded=$(grep -c 'then networksetup -setdnsservers' "$VPNC" 2>/dev/null || true)
    left=$(grep -c '^[[:space:]]*networksetup -setdnsservers' "$VPNC" 2>/dev/null || true)
    if [ "$guarded" -eq 2 ] && [ "$left" -eq 0 ]; then
        ok "bundled vpnc-script has both networksetup DNS calls guarded"
    else
        bad "bundled vpnc-script patch wrong (guarded=$guarded, unguarded=$left)"
    fi
else
    info "no bundled vpnc-script (openconnect not installed at build time)"
fi

# --- Support scripts --------------------------------------------------------
for s in route-wrapper.sh open-browser.sh anyway-root-helper.sh; do
    [ -x "$APP/Contents/Resources/$s" ] && ok "$s bundled and executable" \
        || bad "missing or non-executable: Resources/$s"
done

# --- Signature --------------------------------------------------------------
if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
    ok "signature verifies (--deep --strict)"
else
    bad "codesign --verify --deep --strict failed"
fi

# Hardened runtime is a notarization prerequisite, and it is easier to lose than to
# notice: nothing at run time complains, and the submission fails much later.
for target in "$APP" "$APP/Contents/MacOS/$(basename "${LABEL:-x}")"; do
    [ -e "$target" ] || continue
    if codesign -dv --verbose=4 "$target" 2>&1 | grep -q "flags=.*runtime"; then
        ok "hardened runtime on ${target#$APP/}"
    else
        bad "no hardened runtime on ${target#$APP/}"
    fi
done

# Informational: whether this build could ever register the daemon, and whether it
# would survive Gatekeeper somewhere else. Neither is a failure — an unsigned CI build
# is expected to be both ad-hoc and unnotarized.
AUTH=$(codesign -dv --verbose=4 "$APP" 2>&1 | sed -n 's/^Authority=\(.*\)/\1/p' | head -1)
if [ -n "$AUTH" ]; then
    info "signed by: $AUTH"
else
    info "ad-hoc signed — the privileged daemon cannot register; the app uses its sudo path"
fi
if xcrun stapler validate "$APP" >/dev/null 2>&1; then
    info "notarization ticket stapled"
else
    info "not notarized (fine locally; a copy that travels with a quarantine flag will be gatekept)"
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "verify-bundle: all checks passed"
    exit 0
fi
echo "verify-bundle: $fails check(s) failed" >&2
exit 1
