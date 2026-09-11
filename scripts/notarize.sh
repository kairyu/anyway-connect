#!/bin/sh
#
# Notarize and staple a built AnywayConnect.app.
#
#   sh scripts/notarize.sh [AnywayConnect.app]
#
# Kept out of build-app.sh on purpose: this needs credentials and the network, and waits
# on Apple for minutes. Paying that on every build — including the dozens of builds that
# never leave the machine — would be the wrong default.
#
# One-time setup. Store credentials in the keychain so they never appear in a command
# line or in this file. An App Store Connect API key is preferred over an Apple ID: it
# carries no 2FA, can be scoped, and can be revoked without touching your account.
#
#   xcrun notarytool store-credentials anyway-notary \
#       --key ~/private_keys/AuthKey_XXXXXXXXXX.p8 \
#       --key-id XXXXXXXXXX \
#       --issuer aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
#
# Or with an Apple ID and an app-specific password from appleid.apple.com:
#
#   xcrun notarytool store-credentials anyway-notary \
#       --apple-id you@example.com --team-id XXXXXXXXXX --password xxxx-xxxx-xxxx-xxxx
#
# Override the profile name with ANYWAY_NOTARY_PROFILE.
set -eu

APP="${1:-AnywayConnect.app}"
PROFILE="${ANYWAY_NOTARY_PROFILE:-anyway-notary}"

[ -d "$APP" ] || { echo "notarize: no bundle at $APP" >&2; exit 1; }

# Refuse an ad-hoc build early. Apple would reject it minutes later with a message that
# takes some reading; the local check is instant and unambiguous.
if ! codesign -dv --verbose=4 "$APP" 2>&1 | grep -q "^Authority=Developer ID Application"; then
    echo "notarize: $APP is not signed with a Developer ID." >&2
    echo "          Notarization requires one. Check: codesign -dv --verbose=4 $APP" >&2
    exit 1
fi
if ! codesign -dv --verbose=4 "$APP" 2>&1 | grep -q "flags=.*runtime"; then
    echo "notarize: $APP lacks the hardened runtime, which notarization requires." >&2
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "notarize: no keychain profile '$PROFILE'." >&2
    echo "          See the setup notes at the top of this script." >&2
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ZIP="$WORK/$(basename "$APP" .app).zip"

# ditto, not zip: the bundle contains symlinks and its signature covers them.
echo "==> packaging"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> submitting to Apple (this waits; typically a few minutes)"
set +e
OUT=$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1)
rc=$?
set -e
echo "$OUT" | sed 's/^/    /'

if [ $rc -ne 0 ] || ! echo "$OUT" | grep -q "status: Accepted"; then
    ID=$(echo "$OUT" | sed -n 's/^ *id: \([0-9a-f-]*\)$/\1/p' | head -1)
    if [ -n "$ID" ]; then
        echo "==> rejected; fetching the log" >&2
        xcrun notarytool log "$ID" --keychain-profile "$PROFILE" 2>&1 | sed 's/^/    /' >&2
    fi
    echo "notarize: submission did not succeed" >&2
    exit 1
fi

# Staples the ticket into the bundle so Gatekeeper can verify it without a network
# round trip — which is the whole point, since the machine that opens it may be offline.
echo "==> stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> verifying as Gatekeeper would"
spctl -a -vvv --type exec "$APP" 2>&1 | sed 's/^/    /'

# Re-packaged after stapling: the earlier zip predates the ticket, so shipping it would
# hand out an unnotarized copy despite everything above having succeeded.
DIST="$(basename "$APP" .app)-notarized.zip"
rm -f "$DIST"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST"

echo
echo "notarize: done — $APP is stapled, and $DIST is ready to distribute"
