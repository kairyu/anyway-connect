#!/bin/sh
#
# Render the Homebrew cask for a released version.
#
#   sh scripts/make-cask.sh <version> <sha256> [url]
#
# Prints the cask to stdout. The release workflow uses it to attach a cask to the
# release and to update the tap; run it by hand to inspect what either will produce.
#
# A cask rather than a formula: formulae build command-line software from source, casks
# install prebuilt macOS applications. This ships an .app.
#
# Two things about this cask are not boilerplate.
#
# depends_on formula: "openconnect" — the app is a UI and lifecycle manager around an
# external openconnect binary and cannot connect without one. Declaring it means
# `brew install --cask anyway-connect` leaves a working installation rather than an app
# that launches and then fails at the first connect.
#
# The uninstall and zap stanzas have real work to do. This app registers a *system*
# launchd daemon and, on the sudo path, may have installed root-owned files outside its
# bundle. Dragging the app to the Trash would leave all of that behind, including a
# sudoers rule — so uninstalling has to unregister and delete them explicitly.
#
# And because that uninstall deletes root-owned files that a LIVE tunnel depends on, it
# is guarded. See the uninstall_preflight stanza below for what goes wrong without it.
set -eu

VERSION="${1:?usage: make-cask.sh <version> <sha256> [url]}"
SHA="${2:?usage: make-cask.sh <version> <sha256> [url]}"
# The URL keeps Homebrew's #{version} interpolation so a version bump only ever touches
# the version and sha256 lines. Built with a plain if rather than "${3:-...}", because
# that form ends at the first unescaped } — which is inside #{version}, and silently
# produced a mangled URL.
if [ "$#" -ge 3 ]; then
    URL="$3"
else
    URL='https://github.com/kairyu/anyway-connect/releases/download/v#{version}/AnywayConnect-v#{version}.zip'
fi

cat <<CASK
cask "anyway-connect" do
  version "${VERSION}"
  sha256 "${SHA}"

  # No \`verified:\` parameter. Homebrew deprecated it — it warns on every \`brew info\`
  # — because the default check already covers this case: the URL's host and path are
  # a prefix match for \`homepage\`, which is what \`verified:\` used to assert by hand.
  url "${URL}"
  name "AnywayConnect"
  desc "Menu bar client for OpenConnect-compatible SSL VPNs"
  homepage "https://github.com/kairyu/anyway-connect"

  livecheck do
    url :url
    strategy :github_latest
  end

  # The app drives an external openconnect binary; without one it launches but cannot
  # connect. vpnc-script comes from the same formula, along with thirteen transitive
  # dependencies of its own — gnutls, p11-kit, ca-certificates and so on — which is why
  # those appear in the dependency tree without being named here.
  #
  # xmlstarlet is needed by openconnect's *own* libexec/openconnect/csd-post.sh, which
  # this app runs for gateways that demand a posture check. The openconnect formula does
  # not declare it, so without this the script prints "xmlstarlet not found in path; CSD
  # token extraction may not work" to stderr and the connect fails for reasons the user
  # never sees. It is a leaf formula with no dependencies, so declaring it is cheap
  # insurance against an obscure failure on the one code path that needs it.
  depends_on formula: "openconnect"
  depends_on formula: "xmlstarlet"
  depends_on macos: :ventura

  app "AnywayConnect.app"

  # Refuse to touch an installation whose tunnel is up.
  #
  # The uninstall stanza below unregisters the privileged daemon and then deletes
  # /usr/local/libexec/anyway-connect — which is where route-wrapper.sh and vpnc-script
  # live, the --script openconnect was handed when the tunnel was built. openconnect
  # runs that script at disconnect to put the routing table and the resolvers back.
  # Delete it from under a live tunnel and nothing is left to undo what the tunnel did:
  # the routes and the scoped resolvers outlive the interface they point at, and the
  # machine loses the network in a way that waiting does not fix. That is the same wedge
  # the reconnect work chased for two weeks, reached deliberately by a package manager.
  #
  # \`brew upgrade\` runs that uninstall, so a routine version bump was enough to cause
  # it, and nothing warned. So: fail closed, name the pids, say what to do.
  #
  # Only the uninstall side is guarded. A plain install deletes nothing — it replaces
  # the bundle, which an orphaned tunnel survives, and route-wrapper.sh stays where
  # openconnect expects it. The deletes are the whole hazard.
  #
  # \`brew style\` reports this as a convention offence: Homebrew is steering casks from
  # the flight blocks towards \`uninstall_preflight_steps\`, a declarative DSL of mkdir_p,
  # touch, move, symlink and set_ownership. That DSL has no way to inspect anything and
  # no way to abort, so it cannot express a refusal — and a refusal is the entire point.
  # The legacy block still runs, and the offence is a convention, not an error. If a
  # future Homebrew removes the block outright, the place this moves to is
  # \`uninstall early_script:\`, which runs ahead of every other uninstall directive.
  #
  # The escape hatch is advertised rather than hidden, because a pid file that outlives
  # its process must not be able to wedge an uninstall permanently.
  #
  # A kill(0) that fails with EPERM means the process EXISTS and this user merely may
  # not signal it — openconnect runs as root. Reading that as "gone" is the single
  # mistake this guard is here to avoid.
  uninstall_preflight do
    pid_file = "/var/run/anyway-connect.pid"
    alive = lambda do |pid|
      next false unless pid.is_a?(Integer)
      next false if pid <= 1

      begin
        Process.kill(0, pid)
        true
      rescue Errno::EPERM
        true
      rescue Errno::ESRCH
        false
      end
    end
    pids = []
    pids << File.read(pid_file).strip.to_i if File.readable?(pid_file)
    # The pid file alone is not evidence enough: a tunnel whose file was removed while
    # the process lived is a tunnel the pid file alone would miss. pgrep
    # needs the -- , because the pattern it is given starts with a dash.
    scan = system_command "/usr/bin/pgrep",
                          args:         ["-f", "--", "--pid-file=" + pid_file],
                          must_succeed: false,
                          print_stdout: false
    pids.concat(scan.stdout.split.map(&:to_i))
    live = pids.uniq.select { |pid| alive.call(pid) }

    if live.any? && ENV["ANYWAY_CONNECT_ALLOW_LIVE_TEARDOWN"].nil?
      raise Cask::CaskError, <<~EOM
        AnywayConnect's tunnel is still up (openconnect pid #{live.join(", ")}).

        Uninstalling or upgrading now would unregister the privileged daemon and then
        delete /usr/local/libexec/anyway-connect, where openconnect's disconnect script
        lives. The tunnel's routes and DNS would have nothing left to restore them, and
        this machine would lose the network until they were cleaned up by hand.

        Disconnect from the AnywayConnect menu, quit the app, then run this again.
        To proceed regardless — sensible only if those pids are not really a tunnel —
        set ANYWAY_CONNECT_ALLOW_LIVE_TEARDOWN=1.
      EOM
    end
  end

  # Order and alphabetisation are what \`brew style\` enforces: launchctl before quit,
  # deletions last and sorted. The daemon is unregistered before the app is asked to
  # quit, and the root-owned paths are removed with it — dragging the app to the Trash
  # would leave a registered root daemon and a sudoers rule behind.
  uninstall launchctl: "me.kairyu.anywayconnect.privhelper",
            quit:      "me.kairyu.anywayconnect",
            delete:    [
              "/etc/sudoers.d/anyway-connect",
              "/usr/local/libexec/anyway-connect",
              "/usr/local/sbin/anyway-root-helper.sh",
            ]

  zap trash: [
    "~/.config/anyway-connect",
    "~/Library/Preferences/me.kairyu.anywayconnect.plist",
  ]

  caveats <<~EOS
    AnywayConnect needs root to create the tunnel interface and edit the routing
    table. Open Settings > General > Privileged helper > Install and approve the
    background item when macOS asks. Until then, each connect prompts for sudo.

    To remove the privileged helper before uninstalling, use Remove in that same
    pane — it unregisters the daemon the way macOS expects.
  EOS
end
CASK
