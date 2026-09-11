#!/bin/sh
# external-browser wrapper for OpenConnect on macOS. Opens the SSO URL ($1)
# via /usr/bin/open, which works reliably where openconnect's direct spawn does not.
URL="$1"
[ -z "$URL" ] && { echo "browser-wrapper: no URL" >&2; exit 1; }
echo "browser-wrapper: opening $URL" >&2
exec /usr/bin/open "$URL"
