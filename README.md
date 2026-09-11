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

Requires macOS 13 or later.

## Install

```
brew tap kairyu/tap
brew trust --tap kairyu/tap
brew install --cask anyway-connect
```

`brew trust` is needed because Homebrew 6.0 does not evaluate code from a
third-party tap until you say so. Without it the tap is present but its cask is
never loaded. Inspect what you are trusting first if you like — it is one file,
[`Casks/anyway-connect.rb`](https://github.com/kairyu/homebrew-tap/blob/main/Casks/anyway-connect.rb).

The cask declares `openconnect` and `xmlstarlet` as dependencies, so installing
it also brings the VPN binary, `vpnc-script` and the posture-check tooling —
nothing to install by hand. Uninstalling unregisters the privileged daemon and
removes the root-owned files it installed, which dragging the app to the Trash
would not.

Alternatively, download the notarized zip from
[Releases](https://github.com/kairyu/anyway-connect/releases) and move
`AnywayConnect.app` to `/Applications` — you will need `openconnect` yourself in
that case (`brew install openconnect xmlstarlet`).

More on the tap, including why it isn't in `homebrew/cask` and what the cask's
uninstall stanza cleans up, is in
[docs/FEATURES.md](docs/FEATURES.md#homebrew).

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

## Config

`~/.config/anyway-connect/config.json`, editable from Settings or by hand. A
fresh install ships zero profiles and writes no file until you change something.
`config/config.sample.json` documents the schema.

## Building from source

The app is a UI and lifecycle manager: it **relies on an external `openconnect`
binary**, which the cask would normally install for you.

```
brew install openconnect         # provides openconnect + vpnc-script
brew install xmlstarlet          # for gateways needing the CSD/posture step
./build-app.sh
open AnywayConnect.app
```

Paths are auto-detected, and configurable in Settings if yours differ. The
version comes from the git tag, so a build off a tag reports that version and a
build in between says so.

The build stages into `AnywayConnect.app.staging` and swaps it over the real
bundle only once signing and verification pass, so a build that dies partway
leaves the working app alone.

To check a build for more than "it compiled":

```
sh scripts/verify-bundle.sh AnywayConnect.app
sh test/test-connect-flow.sh
```

The first asserts what signing cannot — that the icon is present at all ten
sizes, that the daemon's launchd identity is internally consistent, that the
bundled `vpnc-script` carries its patch, and that the hardened runtime is on both
executables. The second drives the connect flow against a mock `openconnect`,
covering argument handling and cookie hygiene.

A **Developer ID** signing identity is needed for the preferred privileged
backend. Without one the build still works and the app still connects — it falls
back to `sudo`.

A local build is **signed but not notarized**. That's fine on the machine that
built it, since locally built files carry no quarantine flag, but a copy that
travels — zipped, downloaded, AirDropped — will be stopped by Gatekeeper. To
notarize one by hand:

```
sh scripts/notarize.sh AnywayConnect.app
```

CI builds and tests on every push, unsigned, needing no secrets. Tagging `v*`
produces a signed, notarized release and updates the tap — see
[docs/FEATURES.md](docs/FEATURES.md#ci-and-releases) for the secrets that needs.

## Compliance note

Keeping your local LAN (or other networks) reachable while connected to a
corporate VPN may violate that organization's acceptable-use / split-tunnel
policy. This is a generic tool; **you are responsible for using it in
compliance with the policies of any network you connect to.**

## License

MIT — see [LICENSE](LICENSE).
