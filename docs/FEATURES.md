# AnywayConnect — features in detail

Companion to the [README](../README.md), which covers what the app is, how to
install it and how to build it. This document describes how it actually behaves,
and why, in the places where the reasoning is not obvious from the outside.

- [Menu bar](#menu-bar)
- [The menu](#the-menu)
- [When macOS hides the icon](#when-macos-hides-the-icon)
- [Settings](#settings)
- [Profiles and endpoints](#profiles-and-endpoints)
- [Connecting](#connecting)
- [Auto-reconnect](#auto-reconnect)
- [LAN bypass](#lan-bypass)
- [Privileged backends](#privileged-backends)
- [The session cookie](#the-session-cookie)
- [Only one copy runs at a time](#only-one-copy-runs-at-a-time)
- [Icons](#icons)
- [Config](#config)
- [Build pipeline](#build-pipeline)
- [CI and releases](#ci-and-releases)
- [Homebrew](#homebrew)
- [Tests](#tests)

## Menu bar

The app is an `NSStatusItem` and, in normal use, nothing else — no Dock icon, no
window until you open Settings.

The icon is a globe with a state badge:

| State | Badge |
| --- | --- |
| Disconnected | none |
| Connecting | `ellipsis.circle.fill` |
| Connected | a padlock in a filled disc |

The geometry is deliberate rather than incidental, because a menu bar icon is
small enough that a fraction of a point is visible:

- The canvas is 21 × 19pt, and the globe's **ink** is exactly 15 × 15pt. Sizing
  by the symbol's reported box instead left it visibly smaller, because SF
  Symbols carry asymmetric padding around the glyph.
- The globe is centred vertically by ink, not by box.
- The badge is a 12pt disc centred on an integer point, (15, 6). An even
  diameter needs an integer centre or its edges land mid-pixel and blur.
- The padlock is knocked out of the disc at 0.72 of its height. The stock
  `lock.circle.fill` gives its padlock only about half the disc — narrower than
  the ellipsis it has to be told apart from, which made the most important state
  the least legible one. Above 0.72 the lock's top corners start merging with
  the ring.
- Ink is measured at 16× resolution. The measuring grid becomes the placement
  error, and at 4× the resulting 0.25pt grid was itself the misalignment.

Optionally the connected endpoint's name appears beside the icon, truncated to
18 characters.

## The menu

Every row carries a symbol in one column, which is what keeps the titles on a
single left edge. This matters more than it sounds: macOS 26 supplies a gear for
"Settings…" whether asked to or not, and a menu reserves its image column *per
section between separators* — so one silently decorated row indented four of its
neighbours and nothing else, which looked arbitrary.

Layout, top to bottom:

1. **Status** — a coloured dot with the state: green connected, amber working,
   grey disconnected, followed by the endpoint name when connected. The dot is
   drawn rather than taken from SF Symbols, centred in the same 16pt box the
   symbols occupy, so the column keeps one geometry.
2. **Profile** and, when connected, the **gateway host** it actually reached.
3. **Stop Connecting** — only while busy, and the only enabled row then. Without
   it a connect that never finished left no way out but quitting.
4. **Disconnect** when connected, otherwise a "Connect to" header.
5. **Endpoints** — favourites if any are marked, otherwise all of them. An "All
   endpoints" submenu appears only when it would reveal something not already
   listed. Only the endpoint in use is marked, with a tick; one being connected
   shows an ellipsis; the rest are unmarked. Giving every row a globe filled the
   column with a glyph that said nothing, since each row *is* an endpoint.
6. **Profile** submenu, when more than one profile exists, ticking the active one.
7. **Show / Hide endpoint name**, **Refresh status**, **Settings…**,
   **About AnywayConnect**.
8. **Quit AnywayConnect**.

The name toggle is worded as the action it performs rather than checkmarked —
the same pattern as "Show/Hide Sidebar" — because with a symbol in every row
there is no checkmark column left to report state in.

Endpoint rows are disabled while a connect is in flight. The parent of the "All
endpoints" submenu is disabled too: left enabled it still opened, revealing a
submenu where nothing could be clicked, which reads as the app ignoring you.

## When macOS hides the icon

macOS decides where a status item goes, and it can place one off-screen. Observed
parked at `{0, -22}` — the window's top edge exactly at the bottom of the primary
display — while the item reported itself visible with its image set, so nothing
in the app's own state hinted at it.

Ruled out individually by test: the icon itself, `isVisible`, item creation, the
delegate lifecycle, disk space, the saved "NSStatusItem Preferred Position"
(absent, valid and deleted all behaved alike), menu bar capacity, Control
Centre's state, and the launch method. A standalone probe placed its icon
correctly on the same machine in every one of those configurations. The state
appears to be keyed to the **bundle identifier**: identical probe code placed its
icon under one identifier and parked it under another.

Because the icon is the entire interface, the app does not merely log this:

1. At startup, a remembered position that lands on no current display is
   discarded. Unplugging a monitor can leave one pointing at empty air — observed
   with a saved x of 5596 on a desktop reaching about 3331.
2. Six seconds in — late enough that layout has settled — it checks whether the
   item made it onto a screen. If not, it tears the item down and builds a new
   one, which asks macOS for a slot afresh.
3. If that fails too, it switches to a **Dock icon** carrying the same menu, on
   right-click and in a menu bar of its own, and says once why it changed shape.
   Connect, Disconnect, Settings and ⌘Q all stay reachable.

The Dock fallback shares `buildMenu()` with the status item, so the two cannot
drift apart.

## Settings

Three panes: **General**, **Profiles**, **Logs**.

### General

| Row | Notes |
| --- | --- |
| Start up | "Launch AnywayConnect at login". Reads and writes `SMAppService.mainApp` directly rather than storing a bool, so it cannot disagree with the system. Awaiting approval counts as on, and says so in the tooltip. |
| Active profile | |
| Menu bar | "Show endpoint name in the menu bar" — the same value the menu's toggle writes. |
| Auto-reconnect | Enable, plus max retries and delay in seconds. |
| openconnect binary | Blank means automatic; the detected path is shown beneath. |
| Authorization / Method | Which privileged backend to use. The daemon option is disabled, with an explanation, in a build that has no Developer ID. |
| Privileged helper | A two-step status: is it installed, and has macOS been told to allow it. Install / Remove, plus **Open Login Items…** |

The helper status is deliberately two lights rather than one, because
registration and approval fail independently and the remedies differ. "Open
Login Items…" stays visible in every state: macOS can switch a background item
off without telling the app, so the route to the toggle must not depend on the
app having noticed.

The status line also says which path connects will actually take — daemon,
sudoers helper, or an interactive `sudo` prompt — so the effect of installing (or
not) is visible rather than implied.

### Profiles

Per profile: name, and a table of endpoints. Per endpoint: label, host, protocol
(`anyconnect`, `nc`, `gp`, `pulse`, `f5`, `fortinet`, `array`), auth group,
posture/CSD handling, favourite, and LAN bypass settings.

Endpoints can be added by hand, discovered with **Auto-detect…**, or brought in
with **Import from File…** (Cisco AnyConnect / Secure Client profile XML; other
formats are not parsed, and the app says so rather than failing quietly).

A fresh install ships **zero** profiles and writes no config file until you
change something. An earlier version seeded an "Example" profile pointing at
`vpn.example.com`, which was worse than nothing — useless, and undeletable while
the pane insisted on keeping at least one profile.

### Logs

The tunnel log, refreshed on a timer, with **Open in Console**.

## Profiles and endpoints

A profile is a named set of endpoints plus shared defaults; an endpoint is a
gateway you can connect to. Favourites are how endpoints get pinned to the top
level of the menu — with none marked, the menu lists them all rather than an
arbitrary slice.

An auth group rejected by the gateway is handled specially, because it has a
known remedy: the app offers the groups the gateway actually advertises and
saves your choice **onto that endpoint**, not the profile, since the list came
from that one host.

## Connecting

Two phases, because the credential and the tunnel need different privileges:

1. **Auth**, as your user. `openconnect --authenticate` runs browser SSO and any
   posture/CSD check, and prints a session cookie, the gateway node it
   authenticated against (`HOST`) and `RESOLVE=<hostname>:<ip>`.
2. **Tunnel**, as root. `openconnect --cookie-on-stdin` builds the `utun`.

The cookie is bound to the **exact gateway node** that issued it. Many gateways
sit behind a rotating DNS pool, so re-resolving the hostname in phase 2 can land
on a different node, which rejects the cookie:

```
Got inappropriate HTTP CONNECT response: HTTP/1.1 401 Unauthorized
Cookie was rejected by server; exiting.
```

So phase 2 pins the authenticated node. It tries, in order: the node's IP
addressed directly (trust comes from `--servercert=<fingerprint>`, so hostname
validation isn't needed), then the hostname with `--resolve=<hostname>:<ip>`
pointing at that same node, then a plain lookup as a last resort. Every attempt
is recorded in `~/.config/anyway-connect/state/openconnect.log`. If none confirm,
the tunnel is torn down and the previous default route restored.

A watchdog clears the busy state if a connect never completes, so the menu cannot
be left permanently stuck. **Stop Connecting** kills the authentication child,
which is what unblocks the reader waiting on its pipes.

## Auto-reconnect

Off by default. When on, a dropped tunnel is redialled up to the configured
number of times with the configured delay. A disconnect you asked for is never
redialled — the two are distinguished explicitly rather than inferred.

## LAN bypass

"My local network" keeps your own subnet reachable while connected, and
additional routes can be listed under "Also bypass". Exception routes are
validated in Settings rather than at connect time: the root helper refuses the
whole tunnel over one bad entry, and that failure would only be visible in the
log.

One caveat found the hard way: the bundled `vpnc-script` sets `OverridePrimary`
unconditionally — its own `#if`/`#fi` guard is commented out — and removing that
silently converts a full tunnel into a split tunnel. Worth knowing before
treating it as a knob.

## Privileged backends

Building a tunnel needs root: creating the `utun` and editing the routing table.
Two mechanisms exist; Settings shows which is in use.

### 1. Privileged daemon over XPC (preferred)

An `SMAppService`-registered launchd daemon,
`me.kairyu.anywayconnect.privhelper`, shipped inside the app bundle and run as
root on demand.

The reason to prefer it is *authentication*, not convenience. A `sudoers`
NOPASSWD rule can be invoked by anything running as your user, so its safety
rests entirely on argument checking. The XPC listener instead refuses any peer
that isn't this app, signed by this team:

```
anchor apple generic
  and identifier "<the app's bundle id>"
  and certificate leaf[subject.OU] = "<the team id>"
```

The app applies the mirror-image requirement to the daemon, so a hijacked Mach
name cannot impersonate it. Both are enforced with
`NSXPCConnection.setCodeSigningRequirement`.

Neither the team ID nor the bundle identifier is hardcoded. Each side reads its
own signature at runtime (`SecCodeCopySigningInformation`) and requires the peer
to match: the app expects the daemon's identifier to be its own plus
`.privhelper`, and the daemon expects the reverse. `anchor apple generic` pins
the chain to Apple's roots, so a self-signed binary claiming the identifier is
rejected. If the identity cannot be read — an ad-hoc build has no team — both
sides **fail closed**: the daemon refuses the connection and the app falls back
to sudo rather than talking to an unauthenticated peer with root powers.

The daemon takes **no path arguments it will trust**. It owns the route-wrapper
and `vpnc-script` paths and verifies both are root-owned before use, because
`openconnect` runs `--script` as root.

The one path it is handed, the tunnel log, is not taken on trust either. A
same-user attacker could otherwise replace that file with a symlink and redirect
a root write anywhere on the filesystem. So the daemon:

- derives the caller's home from their uid with `getpwuid` rather than believing
  the path it was given;
- resolves symlinks in that home prefix **only** — components below it must not
  be followed;
- opens with `O_NOFOLLOW_ANY`, trying `O_CREAT|O_EXCL` first;
- checks after opening that the result is a regular file with exactly one link,
  owned by the caller, and `fchown`s by file descriptor rather than by path;
- passes `O_NONBLOCK` for the open and clears it afterwards, because a FIFO left
  at that path would otherwise hang the daemon as root, indefinitely.

Both sides report a protocol version and the app refuses a daemon older than it
expects, falling back to sudo rather than calling it with arguments that mean
something else. The version is currently **1**, in step with the app's own 1.0.

Registration is judged by the state macOS ends in, not by what `register()`
returned: the call can throw and still have created the registration, which
produced a "Couldn't install" alert over a daemon that was installed and merely
waiting for approval. Re-registration is also never attempted for a daemon that
is already current — `unregister()` succeeds, `register()` is then refused
because the background item's disposition is `disabled`, and a working daemon
becomes no daemon at all.

### 2. sudoers helper (fallback)

The original path, kept so the app is never simply unable to connect. A single
narrowly-scoped root helper is installed with a `sudoers.d` rule granting
passwordless sudo to *only that helper*.

The rule means anything running as your user — including malware — can invoke it
as root without a password. The grant is therefore only as narrow as the helper's
argument handling, and two rules follow:

1. **Every path it executes is hardcoded, never an argument.** An earlier version
   accepted the `--script`, `vpnc-script` and pid-file paths as arguments, which
   was a plain root-code-execution hole:
   `sudo anyway-root-helper.sh tunnel anyconnect - - /tmp/evil.sh …` would have
   run `/tmp/evil.sh` as root.
2. **Everything it executes must be root-owned and not group/other-writable**,
   checked at runtime. This is why `vpnc-script` is *copied* to `libexec` rather
   than used from Homebrew: `/opt/homebrew` is owned by the desktop user, so
   running its copy as root would hand the same hole back. The cost is that
   `brew upgrade openconnect` will not update the copy.

Remaining arguments — protocol, host, fingerprint, resolve, exception routes,
pids, gateway — are validated against strict patterns, and the host is passed
after `--` so it can never be read as an option.

## The session cookie

The cookie is a reusable credential for the life of the session, so it stays off
the filesystem wherever possible.

On the daemon path it goes over XPC straight into `openconnect`'s stdin and never
touches disk. The sudo paths cannot do that — the shell helper is a separate
process — so there it is staged in a file created `0600` with
`O_CREAT|O_EXCL|O_NOFOLLOW`, and the shell unlinks it immediately after reading
and before `exec`ing `openconnect`:

```sh
C=path; trap 'rm -f "$C"' EXIT; exec < "$C"; rm -f "$C"; exec sudo …
```

Strays left behind by an earlier crash are swept at startup. This was a real
leak, not a theoretical one: six live cookies were found on disk when it was
found.

## Only one copy runs at a time

Two instances would mean two menu bar icons, two auto-reconnect timers racing to
redial the same tunnel, and two writers clobbering `config.json`. The app takes an
advisory `flock` on `~/.config/anyway-connect/state/instance.lock`.

A lock is used rather than a PID file — the kernel releases it even on `kill -9`,
so it cannot go stale — or a bundle-identifier check, which would not catch the
binary being run directly, outside the `.app`.

A redundant launch does not fail silently, and what happens depends on how it was
started, because the two cases are genuinely different:

- **Double-clicking the app** never starts a second process. macOS sends a reopen
  Apple Event to the copy already running, which offers **Open Settings**,
  **Quit**, or Cancel. Quit is there because the app *is* its menu bar icon: with
  the icon hidden there is otherwise no way to quit it short of Activity Monitor.
  Note that `applicationShouldHandleReopen` is **not** called for an accessory
  app — only the raw `kAEReopenApplication` event arrives, so that is what the app
  handles.
- **Running the binary directly** does start a second process, which finds the
  lock held and offers **Open Settings**, **Restart**, or Cancel. "Restart"
  counts as successful only when it manages to take the lock, since the kernel
  drops it when the holder dies — so a stale pid cannot produce a false success.

The decision is made in `applicationDidFinishLaunching`, not in `main.swift`: an
`NSAlert` cannot present before AppKit has finished launching, and running it
earlier reproduced the very "launching does nothing" symptom the dialog exists to
cure.

To run a second copy deliberately, for a harness alongside the installed app:

```
ANYWAY_SINGLE_INSTANCE=0 ./AnywayConnect.app/Contents/MacOS/AnywayConnect
```

## Icons

Both the app icon and the menu bar icon are **drawn in code**. The app icon lives
in `AnywayConnect/AppIcon.swift`, which `build-app.sh` also compiles into a
throwaway generator to bake `Contents/Resources/AnywayConnect.icns` — one drawing,
so the icon Finder shows and the one the app uses for its About panel and alerts
cannot drift apart.

Details worth keeping:

- Each iconset size is rendered natively rather than downscaled from one large
  raster, into a bitmap of exactly N pixels declared as N points.
  `NSImage.lockFocus` adopts the deepest screen's scale, so on a Retina display it
  would quietly produce double-size reps and every entry would be wrong.
- The plate covers 80.47% of the canvas with a corner radius of 22.37% of its own
  side — Apple's proportions. The remainder is the transparent margin the Dock
  expects.
- Drawing is clipped to the plate. The badge is also inset to clear the corner
  *arc* rather than just the straight edges, but the clip means a later tweak to
  either cannot leak white into the margin, which is what the first draft did.
- The badge is dropped below 64px. At 32 it renders as roughly nine pixels holding
  a five-pixel padlock, which reads as dirt; the globe grows slightly instead.
- `NSApp.applicationIconImage` is set at launch as well. That covers the About
  panel, the app's alerts and the Dock fallback — but **not** Finder or the Dock's
  own slot, which read the bundle. Only the `.icns` fixes those.

## Config

`~/.config/anyway-connect/config.json`. `config/config.sample.json` documents the
current schema (version 2) if you would rather hand-write a profile; it is a
reference only and the app never installs it.

State lives alongside it in `~/.config/anyway-connect/state/`: the tunnel log, the
instance lock, and any transient cookie file.

## Build pipeline

`./build-app.sh` produces `AnywayConnect.app`. Beyond compiling:

- **One identity.** Everything derives from a single `APP_ID` line — the bundle
  identifier, the daemon's launchd label, its plist filename, its `MachServices`
  key, `BundleProgram`, and both `codesign --identifier` values. Set
  `ANYWAY_BUNDLE_ID` to fork it.
- **Staged output.** The build assembles `AnywayConnect.app.staging` and swaps it
  over the real bundle only after signing and verification pass. It used to delete
  its output first, which — when a full disk stopped it from finishing — left no
  app at all, and for a menu bar app that means no way to reach the VPN.
- **A patched `vpnc-script`.** Upstream calls
  `networksetup -setdnsservers "$ACTIVE_NETWORK_SERVICE" …` with an empty service
  name, because by that point `ACTIVE_INTERFACE` is the `utun` and the lookup
  yields nothing. The build guards both call sites, and **fails** unless it finds
  exactly the two unguarded ones it expects, so a future upstream change cannot
  silently skip the fix. Patching at build time was chosen over vendoring the
  script, which would mean losing upstream security fixes to something that runs
  as root.
- **A baked icon**, as above. The build fails if `iconutil` produces nothing,
  since an `Info.plist` promising an icon that isn't there gets the same blank page
  as no icon at all.
- Signing is inner-to-outer, daemon first, with the hardened runtime.

Without a Developer ID the build warns and signs ad-hoc. The app still runs, but
the daemon cannot register and the app uses its sudo path.

## CI and releases

Two workflows, split by whether they need Apple.

### CI — `.github/workflows/ci.yml`

Runs on every push and pull request, on `macos-15` and `macos-26`. Both are worth
covering: the deployment target is macOS 13, so the older image is what catches use
of an API newer than that target, while the newer one is what development actually
happens on.

It needs **no secrets**, which is what lets it run on forks and pull requests. With
no Developer ID in the keychain `build-app.sh` warns and signs ad-hoc — a valid
bundle that simply cannot register the privileged daemon. Ad-hoc signing tolerates
`--timestamp` and `--options runtime`, so the build script needs no special case.

It installs `openconnect` purely for its `vpnc-script`. A missing one is only a
warning to `build-app.sh`, so without that step the DNS patch — and the check that
the patch still applies to current upstream — would be skipped silently, which is
the single most valuable thing the job verifies.

Then it runs `scripts/verify-bundle.sh`, the tests, and uploads the bundle as an
artifact (packaged with `ditto`, not `zip`, so symlinks and the signature survive).

### `scripts/verify-bundle.sh`

Worth running locally too. Each check stands for a way the bundle has actually been
wrong, or could silently become wrong, in a way that only appears at run time — a
build can pass signing and still fail all of them:

- `CFBundleIconFile` is set **and** the `.icns` exists and holds all ten sizes. It
  round-trips the file back through `iconutil` to count them, because an
  `Info.plist` promising an icon that isn't there produces the same blank page as no
  icon at all.
- The daemon's launchd label, plist filename, `MachServices` key, `BundleProgram` and
  binary name are all the same string, and `AssociatedBundleIdentifiers` matches the
  app.
- **The helper suffix agrees between `build-app.sh` and `PrivilegedProtocol.swift`.**
  Everything else derives from one variable, but that suffix is spelled out
  independently in both, and a disagreement means the app derives a Mach name the
  daemon never listens on — so every connect would quietly fall back to sudo. This is
  the only place the two are compared.
- The bundled `vpnc-script` really does have both `networksetup` calls guarded.
- The signature verifies `--deep --strict`, and both executables carry the hardened
  runtime. That last one is a notarization prerequisite and is easier to lose than to
  notice: nothing complains at run time and the submission fails much later.

Signing authority and notarization status are reported but never failed on, since an
unsigned CI build is expected to be both ad-hoc and unnotarized.

### Release — `.github/workflows/release.yml`

Triggered by a `v*` tag. Imports the certificate into a throwaway keychain, builds,
refuses to continue unless the signature really is a Developer ID one, verifies,
tests, notarizes, staples, confirms Gatekeeper reports
`source=Notarized Developer ID`, and attaches the zip plus its SHA-256 to a GitHub
release. The keychain is deleted in an `if: always()` step, so a failed release does
not leave a private key on the runner.

Secrets required:

| Secret | What it is |
| --- | --- |
| `APPLE_CERT_P12` | Developer ID Application certificate **and private key**, exported as `.p12`, base64 encoded |
| `APPLE_CERT_PASSWORD` | the password set during that export |
| `APPLE_API_KEY` | App Store Connect API key (`.p8`), base64 encoded |
| `APPLE_API_KEY_ID` | its Key ID |
| `APPLE_API_ISSUER_ID` | the issuer UUID |
| `HOMEBREW_TAP_DEPLOY_KEY` | private half of an SSH deploy key with write access to the tap (optional) |

`APPLE_CERT_PASSWORD` is only needed if the `.p12` was exported with one — an empty
export password is a valid answer and the workflow treats a missing secret as such.

The signing identity is not among them — `build-app.sh` finds it in the keychain.
The keychain password is generated per run rather than stored, since it protects
nothing beyond the life of the job.

### Notarization

The app is signed with a Developer ID, the hardened runtime and a secure timestamp,
which is everything notarization *requires*. A local build lacks only the
submission, so there is no stapled ticket:

```
AnywayConnect.app does not have a ticket stapled to it.
AnywayConnect.app: rejected
source=Unnotarized Developer ID
```

That `rejected` does not affect the machine that built it. Gatekeeper only consults
an assessment for a bundle carrying `com.apple.quarantine`, and locally built files
never get one — which is also why the privileged daemon registers happily:
`SMAppService` wants a valid Developer ID signature, not a ticket.

It matters the moment the app travels. Any copy that arrives quarantined gets
"cannot be opened because Apple cannot check it for malicious software", with only
the right-click-Open bypass.

`scripts/notarize.sh` does it by hand. It is kept out of `build-app.sh` because it
needs credentials and the network and waits on Apple for minutes — paying that on
every build, including the many that never leave the machine, would be the wrong
default. It refuses an ad-hoc or non-hardened bundle up front rather than letting
Apple reject it minutes later, fetches the notarization log automatically on
failure, and **re-packages after stapling**: the zip made for submission predates
the ticket, so shipping that one would hand out an unnotarized copy despite
everything having succeeded.

Credentials live in the keychain, set up once:

```
xcrun notarytool store-credentials anyway-notary \
    --key ~/private_keys/AuthKey_XXXXXXXXXX.p8 \
    --key-id XXXXXXXXXX \
    --issuer aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
```

An API key is preferred over an Apple ID with an app-specific password: it carries
no 2FA, can be scoped, and can be revoked without touching the account.

## Homebrew

Distribution is a **cask**, not a formula: formulae build command-line software from
source, casks install prebuilt macOS applications.

`scripts/make-cask.sh <version> <sha256>` renders it, and the release workflow uses
that same script — so the cask attached to a release and the one pushed to the tap
are produced identically. It passes `brew style` and `brew audit` clean.

Two stanzas are doing real work rather than filling in a template.

`depends_on formula: "openconnect"` — the app is a UI and lifecycle manager around an
external binary and cannot connect without one. Declaring it means
`brew install --cask anyway-connect` leaves a working installation rather than an app
that launches and then fails at the first connect, and it brings `vpnc-script` along
with it. It also brings thirteen transitive formulae of its own — `gnutls`, `p11-kit`,
`ca-certificates` and so on — which is why those show up in the dependency tree without
being named in the cask.

`depends_on formula: "xmlstarlet"` covers a gap in the `openconnect` formula rather
than a need of this app's own. openconnect's `libexec/openconnect/csd-post.sh`, which
this app runs for gateways demanding a posture check, calls `xmlstarlet` — and the
formula does not declare it. Without it the script writes "xmlstarlet not found in
path; CSD token extraction may not work" to stderr and the connect fails for a reason
the user never sees. It is a leaf formula with no dependencies of its own, so declaring
it is cheap insurance on the one code path that needs it.

The `uninstall` stanza unregisters the launchd daemon and deletes the root-owned
files the sudo backend may have installed — `/etc/sudoers.d/anyway-connect`,
`/usr/local/sbin/anyway-root-helper.sh`, `/usr/local/libexec/anyway-connect`. Moving
the app to the Trash would leave a registered root daemon and a passwordless sudo
rule behind, which is the sort of residue an uninstaller exists to prevent. `zap`
additionally takes `~/.config/anyway-connect` and the preferences domain.

### What it requires

- **A public repository.** Release assets on a private repo need authentication, and
  `brew` fetches anonymously.
- **A notarized build.** Homebrew quarantines cask downloads, has deprecated
  `--no-quarantine`, and ended support for casks that fail Gatekeeper checks as of
  1 September 2026. An unnotarized app would be blocked on first launch. This is the
  concrete reason to finish the notarization setup rather than leave it optional.
- **A versioned, immutable URL and a SHA-256**, which the release workflow produces.

### Own tap, not homebrew/cask

The official `homebrew/cask` has a notability threshold — for a self-submission by the
repository owner, at least 90 forks, 90 watchers or 225 stars. A personal tap has no
such requirement and works immediately:

```
brew tap kairyu/tap
brew trust --tap kairyu/tap
brew install --cask anyway-connect
```

The `brew trust` step is not optional and not a formality. Homebrew 6.0 stopped
evaluating code from third-party taps until they are explicitly trusted, since a tap
is arbitrary unsandboxed Ruby that runs on the user's machine. Skip it and the tap is
present but its cask is never loaded, which reads as the tap being broken. Trust is
recorded in `~/.homebrew/trust.json`, or under `$XDG_CONFIG_HOME/homebrew/` when that
is set, and `brew untrust` reverses it.

This is worth mentioning in install instructions rather than leaving users to hit it,
and it is also an argument for keeping the cask small and readable: anyone can check
what they are trusting in one file.

The tap is a separate repository named `homebrew-tap`, holding
`Casks/anyway-connect.rb`. Without a credential for it the cask is still rendered and
attached to the release, and only the push is skipped, so a release never fails over a
tap that does not exist yet.

That credential is an **SSH deploy key** on the tap, not a personal access token,
chosen for how little it can do: a deploy key grants git access to exactly one
repository and cannot reach the API, read other repositories, or create releases, even
if it leaks. A classic PAT with `repo` scope would hand over write access to
everything the account owns in order to publish one text file. A fine-grained PAT
scoped to the tap would be closer, but still expires and still carries API rights.

A GitHub App was considered and rejected for this job. Its installation tokens are
ephemeral, which is a genuine advantage, but its private key mints real API tokens for
every repository the App is installed on — more capability than "push one file to one
repo" needs, for more setup. The App becomes the right answer if the tap should be
updated by pull request rather than direct push, or once several repositories are
involved.

The workflow pins GitHub's SSH host keys from `api.github.com/meta` rather than
accepting them on first use, so the push cannot be aimed at an impostor host.

## Tests

```
sh test/test-connect-flow.sh
```

16 checks driving the connect flow against `test/mock-openconnect.sh` rather than
a real gateway, covering argument handling and cookie hygiene. They earn their
keep: they are what caught a FIFO at the log path blocking the root daemon
indefinitely.

The tests are hermetic — `mktemp`, the mock, no `HOME`, no sudo, no real
`openconnect` — which is what lets CI run them unchanged.

There is no unit-test target for the AppKit code. Behaviour there is verified by
compiling throwaway harnesses against the real sources: copy every file in
`AnywayConnect/` except `main.swift` into a scratch directory, add your own
`main.swift` as the entry point (Swift only allows top-level statements in a file
with that name), and build with `swiftc -O`.

Two rules learned the hard way:

- **Never let a harness reach `ConfigStore.shared`.** It resolves
  `~/.config/anyway-connect/config.json` in a private initialiser with no override,
  so a harness that touches it reads — and can write — the real config. Decode and
  encode `AppConfig` from literal JSON instead. Likewise `VPNRunner.shared`, whose
  initialiser sweeps the real state directory.
- Run with `ANYWAY_SINGLE_INSTANCE=0`, or the harness hands off to the installed
  app and exits. Show windows with `orderFrontRegardless()` rather than activating,
  so a test run doesn't steal focus.

A harness is ad-hoc signed, so anything gated on the Developer ID signature —
`currentCodeIdentity()`, the XPC code requirement, `SMAppService` — will correctly
refuse. That's the fail-closed behaviour working, not a defect.
