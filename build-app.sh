#!/bin/sh
# Build AnywayConnect.app, including the privileged XPC daemon.
#
# Signing: SMAppService will only register a daemon whose signature the system
# trusts, and the XPC listener authenticates its client by code-signing
# requirement, so both sides must be signed by the same Developer ID team.
# Override the identity with CODESIGN_IDENTITY=... if needed.
#
# The build falls back to ad-hoc signing when no Developer ID is present, so it
# still produces a runnable app on another machine — but the daemon cannot
# register in that state, and the app then uses its sudo fallback instead.
set -e
cd "$(dirname "$0")"

# Built to one side and swapped in only once it is signed and verified, because the
# first thing this script does is delete its output. A build that dies in the middle —
# a full disk did exactly this — used to leave no app at all, which for a menu bar app
# means no way to reach the VPN. Staging keeps the working copy until there is a
# complete replacement for it.
FINAL="AnywayConnect.app"
APP="AnywayConnect.app.staging"
BIN="AnywayConnect"

# The one place your identity appears. Everything else is derived from it, so
# forking this only means changing this line (or exporting ANYWAY_BUNDLE_ID).
APP_ID="${ANYWAY_BUNDLE_ID:-me.kairyu.anywayconnect}"

# The helper binary is named identically to its launchd label on purpose: the
# label, the plist filename, the MachServices key, BundleProgram, the codesign
# --identifier and this binary all have to agree, and making them literally the
# same string removes a whole class of typo. It is also what Apple's
# privileged-helper samples do. The ".privhelper" suffix is the same one
# PrivilegedProtocol.swift uses to derive one side's identifier from the other.
HELPER_LABEL="${APP_ID}.privhelper"
HELPER_BIN="$HELPER_LABEL"
SRC_DIR="AnywayConnect"
HELPER_SRC_DIR="AnywayConnectHelper"
# --- Pick a signing identity -------------------------------------------------
# Auto-detected rather than hardcoded: naming one developer's certificate here
# would leak their identity into the repo and break the build for everyone else.
# Set CODESIGN_IDENTITY to choose a specific one.
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    SIGN_ID="$CODESIGN_IDENTITY"
else
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null |
              grep "Developer ID Application" | head -1 |
              sed 's/.*"\(.*\)".*/\1/')
fi

if [ -n "$SIGN_ID" ] && security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
    SIGN_MODE="developer-id"
else
    if [ -n "$SIGN_ID" ]; then
        echo "warning: '$SIGN_ID' is not in the keychain." >&2
    else
        echo "warning: no 'Developer ID Application' identity found in the keychain." >&2
    fi
    echo "         Falling back to ad-hoc signing. The privileged daemon cannot" >&2
    echo "         register in that state, so the app will use its sudo path." >&2
    SIGN_ID="-"
    SIGN_MODE="adhoc"
fi

# --- Version -----------------------------------------------------------------
# Taken from the git tag rather than written here, so a release, its cask and the
# app's own About panel cannot disagree about which version they are. Hardcoding it
# meant the bundle claimed 1.0 while a v1.0.0 tag shipped it.
#
# Precedence: an explicit ANYWAY_VERSION (what the release workflow passes, since a
# tag-triggered checkout is not guaranteed to have fetched tag objects), then the tag
# at HEAD, then a describe for development builds, then a bare fallback.
if [ -n "${ANYWAY_VERSION:-}" ]; then
    VERSION="${ANYWAY_VERSION#v}"
elif VERSION=$(git describe --exact-match --tags HEAD 2>/dev/null); then
    VERSION="${VERSION#v}"
elif VERSION=$(git describe --tags --always --dirty 2>/dev/null); then
    VERSION="${VERSION#v}"
else
    VERSION="0.0.0"
fi

# CFBundleShortVersionString is the version people see, and Apple expects dotted
# integers there — so a describe like "1.0.0-3-gabc1234-dirty" contributes only its
# "1.0.0". The full string goes in CFBundleVersion, which is where a development build
# can say precisely what it is; the About panel shows it in parentheses when the two
# differ, and shows nothing extra when they agree.
SHORT_VERSION=$(printf '%s' "$VERSION" | sed -n 's/^\([0-9][0-9.]*\).*/\1/p')
[ -n "$SHORT_VERSION" ] || SHORT_VERSION="0.0.0"

echo "Building $FINAL (signing: $SIGN_MODE, version: $SHORT_VERSION, build: $VERSION)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AnywayConnect</string>
    <key>CFBundleDisplayName</key><string>AnywayConnect</string>
    <key>CFBundleIconFile</key><string>${BIN}</string>
    <key>CFBundleIdentifier</key><string>${APP_ID}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${SHORT_VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>$BIN</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# --- launchd job for the privileged daemon -----------------------------------
# BundleProgram is relative to the app bundle. AssociatedBundleIdentifiers makes
# Login Items name the app rather than showing the bare label.
cat > "$APP/Contents/Library/LaunchDaemons/$HELPER_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$HELPER_LABEL</string>
    <key>BundleProgram</key><string>Contents/MacOS/$HELPER_BIN</string>
    <key>MachServices</key>
    <dict>
        <key>$HELPER_LABEL</key><true/>
    </dict>
    <key>AssociatedBundleIdentifiers</key>
    <array><string>${APP_ID}</string></array>
    <key>StandardErrorPath</key><string>/var/log/anyway-connect-helper.log</string>
</dict>
</plist>
PLIST

# --- Compile the privileged daemon -------------------------------------------
echo "  compiling $HELPER_BIN"
/usr/bin/swiftc -O \
    -framework Foundation \
    -o "$APP/Contents/MacOS/$HELPER_BIN" \
    "$SRC_DIR/PrivilegedProtocol.swift" \
    "$HELPER_SRC_DIR/main.swift"

# --- Compile the app ---------------------------------------------------------
echo "  compiling $BIN"
/usr/bin/swiftc -O \
    -framework AppKit -framework Foundation -framework ServiceManagement \
    -o "$APP/Contents/MacOS/$BIN" \
    "$SRC_DIR/Config.swift" \
    "$SRC_DIR/PrivilegedProtocol.swift" \
    "$SRC_DIR/PrivilegedClient.swift" \
    "$SRC_DIR/SingleInstance.swift" \
    "$SRC_DIR/ProfileImporter.swift" \
    "$SRC_DIR/AuthGroupSheet.swift" \
    "$SRC_DIR/PrivilegedInstaller.swift" \
    "$SRC_DIR/VPNRunner.swift" \
    "$SRC_DIR/AppIcon.swift" \
    "$SRC_DIR/AppDelegate.swift" \
    "$SRC_DIR/SettingsWindow.swift" \
    "$SRC_DIR/main.swift"

# --- Bake the app icon -------------------------------------------------------
# Drawn by the app's own AppIcon.swift, compiled here into a throwaway generator, so
# the icon in the bundle and the one the running app uses for its About panel, its
# alerts and the Dock cannot drift apart.
#
# An .icns is the only thing Finder and the Dock's own slot will read — setting
# NSApp.applicationIconImage at runtime does nothing for either, which is why the app
# still appeared blank in Finder while looking correct in its own windows.
echo "  drawing $BIN.icns"
ICON_TMP=$(mktemp -d)
trap 'rm -rf "$ICON_TMP"' EXIT
/usr/bin/swiftc -O \
    -framework AppKit -framework Foundation \
    -o "$ICON_TMP/make-iconset" \
    "$SRC_DIR/AppIcon.swift" \
    tools/make-iconset.swift
"$ICON_TMP/make-iconset" "$ICON_TMP/$BIN.iconset"
iconutil -c icns "$ICON_TMP/$BIN.iconset" -o "$APP/Contents/Resources/$BIN.icns"
# Fail loudly rather than shipping a bundle whose Info.plist promises an icon that
# isn't there — Finder's fallback for that is the same blank page as no icon at all.
if [ ! -s "$APP/Contents/Resources/$BIN.icns" ]; then
    echo "error: iconutil produced no $BIN.icns" >&2
    exit 1
fi

# --- Bundle the privileged support files -------------------------------------
# The app carries everything either backend needs to install, so provisioning is
# a Settings action rather than a Terminal step.
#
# Note these copies are NOT what runs as root. A script executed as root must not
# live where the desktop user can edit it, so both backends run root-owned copies
# under /usr/local. These are the *install sources*, and the bundle's resource
# seal is what makes them trustworthy: `codesign --verify` detects tampering even
# for an ad-hoc signature, so the installer checks the seal before copying.
cp scripts/route-wrapper.sh     "$APP/Contents/Resources/"
cp scripts/open-browser.sh      "$APP/Contents/Resources/"
cp scripts/anyway-root-helper.sh "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/"*.sh

# vpnc-script comes from openconnect's install. Bundling it means the installer
# copies from our sealed bundle instead of reading /opt/homebrew at install time —
# that path is writable by the desktop user without sudo, so treating it as a
# root-install source is a straightforward local privilege escalation.
VPNC_SRC="${VPNC_SCRIPT_SRC:-}"
if [ -z "$VPNC_SRC" ]; then
    for c in /opt/homebrew/etc/vpnc/vpnc-script /usr/local/etc/vpnc/vpnc-script \
             /etc/vpnc/vpnc-script; do
        [ -f "$c" ] && { VPNC_SRC="$c"; break; }
    done
fi
if [ -n "$VPNC_SRC" ]; then
    VPNC_DEST="$APP/Contents/Resources/vpnc-script"
    cp "$VPNC_SRC" "$VPNC_DEST"
    chmod +x "$VPNC_DEST"
    echo "  bundled vpnc-script from $VPNC_SRC"

    # --- Patch: never call networksetup with an empty service name ------------
    #
    # Upstream picks the service to set DNS on from whatever holds the default
    # route at that moment:
    #
    #   ACTIVE_INTERFACE=`route -n get default | grep interface | awk '{print $2}'`
    #   ACTIVE_NETWORK_SERVICE=`networksetup -listnetworkserviceorder \
    #                           | grep -B 1 "$ACTIVE_INTERFACE" ...`
    #   networksetup -setdnsservers "$ACTIVE_NETWORK_SERVICE" $INTERNAL_IP4_DNS
    #
    # By then the default route is already the tunnel, and networksetup only knows
    # *network services* (Wi-Fi, Ethernet) — never a utun. So the grep matches
    # nothing, the service name is empty, and every connect prints:
    #
    #       is not a recognized network service.
    #     ** Error: The parameters were not valid.
    #
    # Guarding rather than repairing the derivation is deliberate. Resolving it to
    # the physical service would start writing a PERSISTENT DNS setting onto Wi-Fi
    # — networksetup edits the saved configuration, not the dynamic store — whose
    # removal would then depend on the symmetric teardown call running correctly
    # on every disconnect, including crashes. DNS already works here via
    # State:/Network/Service/$TUNDEV/DNS, so the correct fix is to stop issuing a
    # malformed command, not to start issuing a consequential one.
    #
    # Patched at build time rather than vendored so we keep tracking upstream
    # (this script runs as root; we want its security fixes). The build fails
    # loudly if the shape changes, because silently shipping it unpatched is the
    # one outcome worth preventing.
    unguarded=$(grep -c '^[[:space:]]*networksetup -setdnsservers' "$VPNC_DEST" || true)
    if [ "$unguarded" -ne 2 ]; then
        echo "  ERROR: expected 2 unguarded 'networksetup -setdnsservers' calls in" >&2
        echo "         $VPNC_SRC, found $unguarded. Upstream changed shape — re-check" >&2
        echo "         this patch before shipping a script that openconnect runs as root." >&2
        exit 1
    fi
    sed -e 's|^\([[:space:]]*\)networksetup -setdnsservers "[$]ACTIVE_NETWORK_SERVICE" \(.*\)$|\1if [ -n "$ACTIVE_NETWORK_SERVICE" ]; then networksetup -setdnsservers "$ACTIVE_NETWORK_SERVICE" \2; fi|' \
        "$VPNC_DEST" > "$VPNC_DEST.patched"
    guarded=$(grep -c 'then networksetup -setdnsservers' "$VPNC_DEST.patched" || true)
    left=$(grep -c '^[[:space:]]*networksetup -setdnsservers' "$VPNC_DEST.patched" || true)
    if [ "$guarded" -ne 2 ] || [ "$left" -ne 0 ]; then
        echo "  ERROR: vpnc-script DNS patch did not apply (guarded=$guarded, unguarded=$left)." >&2
        rm -f "$VPNC_DEST.patched"
        exit 1
    fi
    mv "$VPNC_DEST.patched" "$VPNC_DEST"
    chmod +x "$VPNC_DEST"
    echo "  patched vpnc-script: guarded $guarded networksetup DNS call(s)"
else
    # Not fatal: an existing root-owned copy still works. But the in-app installer
    # will have nothing to provision, so say so rather than failing later.
    echo "  WARNING: vpnc-script not found — in-app provisioning will be unavailable." >&2
    echo "           brew install openconnect, or set VPNC_SCRIPT_SRC=/path/to/vpnc-script" >&2
fi

# --- Sign inner-to-outer -----------------------------------------------------
# The daemon is signed first so the app's signature seals an already-signed
# binary. --options runtime (hardened runtime) is required for notarization.
echo "  signing $HELPER_BIN"
codesign --force --timestamp --options runtime \
    --identifier "$HELPER_LABEL" \
    --sign "$SIGN_ID" "$APP/Contents/MacOS/$HELPER_BIN" 2>&1 |
    grep -v "replacing existing signature" || true

echo "  signing $APP"
codesign --force --timestamp --options runtime \
    --identifier "$APP_ID" \
    --sign "$SIGN_ID" "$APP" 2>&1 |
    grep -v "replacing existing signature" || true

echo "  verifying"
codesign --verify --strict --verbose=1 "$APP" 2>&1 | sed 's/^/    /'
codesign -dv "$APP/Contents/MacOS/$HELPER_BIN" 2>&1 | grep -E "Identifier|TeamIdentifier|Signature" | sed 's/^/    /'

# --- Swap in ------------------------------------------------------------------
# Only now, with a signed and verified bundle in hand. `set -e` means any failure
# above skips this and leaves the previous app untouched. The signature covers the
# bundle's contents rather than its path, so moving it does not invalidate it.
rm -rf "$FINAL"
mv "$APP" "$FINAL"

echo "Built: $(pwd)/$FINAL"
