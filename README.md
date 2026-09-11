# AnywayConnect

A generic, mostly-native macOS menu bar client for **OpenConnect**-compatible
SSL VPNs (AnyConnect/ocserv, Pulse, GlobalProtect, F5, Fortinet, etc.). Built
because the stock vendor clients don't always let you do what you want (e.g.
keep LAN access on).

The name is a wink at Cisco AnyConnect: it connects *anyway*, on your terms.

## What it is

- A native Swift `NSStatusItem` app: a globe icon that gains a padlock when the
  tunnel is up, and no Dock icon in normal use.
- One menu for everything — connect, switch endpoint, disconnect — with the
  endpoint you're on ticked and a coloured status dot.
- A Settings window for profiles, endpoints, LAN bypass, auto-reconnect, launch
  at login, and installing the privileged helper.
- Reconnects by itself if the tunnel drops.

For how any of that actually behaves, see **[docs/FEATURES.md](docs/FEATURES.md)**.

## Requirements

macOS 13 or later. The app is a UI and lifecycle manager: it **relies on an
external `openconnect` binary**, which you install yourself.

```
brew install openconnect         # provides openconnect + vpnc-script
brew install xmlstarlet          # only if your gateway needs the CSD/posture step
```

Installing the cask brings both along, so this is only for building from source.
Paths are auto-detected, and configurable in Settings if yours differ.

A **Developer ID** signing identity is needed for the preferred privileged
backend. Without one the build still works and the app still connects — it falls
back to `sudo`.

## Build and run

```
./build-app.sh
open AnywayConnect.app
```

The build stages into `AnywayConnect.app.staging` and swaps it over the real
bundle only once signing and verification pass, so a build that dies partway
leaves the working app alone.

To check a build over than just "it compiled":

```
sh scripts/verify-bundle.sh AnywayConnect.app
sh test/test-connect-flow.sh
```

CI runs both on every push, unsigned, needing no secrets. Tagging `v*` runs a
signed, notarized release — see
[docs/FEATURES.md](docs/FEATURES.md#ci-and-releases) for the secrets that needs.

A local build is **signed but not notarized**. That's fine on the machine that
built it, since locally built files carry no quarantine flag, but a copy that
travels — zipped, downloaded, AirDropped — will be stopped by Gatekeeper. To
notarize one by hand:

```
sh scripts/notarize.sh AnywayConnect.app
```

## First run

1. Launch it; a globe appears in the menu bar.
2. **Settings ▸ Profiles** — add a gateway by hand, or use **Auto-detect…** or
   **Import from File…** (Cisco AnyConnect profile XML).
3. **Settings ▸ General ▸ Privileged helper ▸ Install**, then approve the
   background item when macOS asks. This is what lets connects run without a
   password prompt. Skipping it is fine — connects will prompt for `sudo`.
4. Pick your endpoint from the menu. Authentication opens in your browser.

## How it gets root

Building a tunnel needs root: creating the `utun` interface and editing the
routing table. There are two mechanisms, and Settings shows which is in use.

**A privileged XPC daemon** (preferred). Registered with `SMAppService`, shipped
inside the app bundle, run by launchd as root on demand. It authenticates its
peer by code-signing requirement, so only this app — signed by this team — can
ask it for anything. The tunnel cookie goes over XPC straight into
`openconnect`'s stdin and never touches disk.

**A sudoers helper** (fallback). A single narrowly-scoped root script with a
`NOPASSWD` rule for only that script. Anything running as your user can invoke
it, so its safety rests entirely on argument validation — every path it executes
is hardcoded rather than passed in, and everything it runs must be root-owned.

Both are described properly, including the threat model each is built against, in
[docs/FEATURES.md](docs/FEATURES.md#privileged-backends).

To install the sudoers path from a terminal instead of from Settings:

```
sudo ./scripts/install-privileged.sh
```

Once the daemon works, the sudo grant can be removed:

```
sudo rm /etc/sudoers.d/anyway-connect
sudo rm /usr/local/sbin/anyway-root-helper.sh
```

Leave `/usr/local/libexec/anyway-connect/` in place — the daemon uses it too.

## Install with Homebrew

Once a release exists in a tap:

```
brew tap kairyu/tap
brew install --cask anyway-connect
```

The cask declares `openconnect` and `xmlstarlet` as dependencies, so that pulls in
the binary, `vpnc-script` and the posture-check tooling too — nothing to install by
hand. Uninstalling unregisters the privileged daemon and removes the root-owned
files it installed, which dragging the app to the Trash would not.

This needs a public repo and a notarized build — Homebrew now quarantines cask
downloads and has ended support for casks that fail Gatekeeper. See
[docs/FEATURES.md](docs/FEATURES.md#homebrew) for what that involves.

## Config

`~/.config/anyway-connect/config.json`, editable from Settings or by hand. A
fresh install ships zero profiles and writes no file until you change something.
`config/config.sample.json` documents the schema.

## Tests

```
sh test/test-connect-flow.sh
```

Drives the connect flow against a mock `openconnect`, covering argument handling
and cookie hygiene.

## Compliance note

Keeping your local LAN (or other networks) reachable while connected to a
corporate VPN may violate that organization's acceptable-use / split-tunnel
policy. This is a generic tool; **you are responsible for using it in
compliance with the policies of any network you connect to.**

## License

MIT — see [LICENSE](LICENSE).
