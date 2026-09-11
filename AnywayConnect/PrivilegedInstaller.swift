import Foundation
import Security

// ── Provisioning the privileged pieces ───────────────────────────────────────
//
// Both backends need root-owned copies of route-wrapper.sh and vpnc-script under
// /usr/local/libexec, because openconnect executes --script as root and a script
// that runs as root must not live somewhere the desktop user can rewrite. The
// root-helper backend additionally needs the helper itself plus a NOPASSWD
// sudoers rule naming only that helper.
//
// This exists so none of that requires a Terminal. It matters most for the case
// that cannot use the daemon at all: an ad-hoc signed build has no team, so the
// XPC code requirement is unsatisfiable and PrivilegedClient fails closed. Such a
// build can still install the root helper, and now without instructions.
//
// Getting root without a signing identity leaves one workable mechanism —
// AppleScript's `with administrator privileges`, which raises the system
// authentication panel. SMJobBless needs the signing we are working around, and
// AuthorizationExecuteWithPrivileges has been deprecated for over a decade.
//
// Two rules keep that safe:
//   1. What runs as root is built here, in the signed binary, never read from a
//      file that something else could have swapped first.
//   2. The bundle's resource seal is verified before anything is copied out of it.
//      Ad-hoc signatures still seal resources, so tampering is detectable even
//      without a certificate.
enum PrivilegedInstaller {

    enum Backend {
        case daemon      // support files only; SMAppService installs the daemon
        case rootHelper  // support files + helper + sudoers rule
    }

    // Destinations are constants. Nothing here is ever taken from a caller — the
    // whole point is that a root-executed path cannot be influenced.
    static let libexecDir   = "/usr/local/libexec/anyway-connect"
    static let routeWrapper = libexecDir + "/route-wrapper.sh"
    static let vpncScript   = libexecDir + "/vpnc-script"
    static let rootHelper   = "/usr/local/sbin/anyway-root-helper.sh"
    static let sudoersFile  = "/etc/sudoers.d/anyway-connect"

    struct State {
        /// Both libexec files present, root-owned, not group/world writable.
        var supportFilesReady = false
        var helperPresent = false
        var sudoersPresent = false
        /// End-to-end: `sudo -n helper version` answered with a good version.
        /// The authoritative check, since it proves the file *and* the grant.
        var helperUsable = false
        /// The bundle carries what an install would need.
        var canProvision = false
        /// Installed support files are byte-identical to the bundled ones.
        ///
        /// Worth knowing because the installed copies are what actually run, and
        /// they don't update when the app does. A stale route-wrapper.sh sat in
        /// /usr/local/libexec for days after the source was fixed, silently doing
        /// the old thing. This is what lets the UI offer a refresh — and skip the
        /// authentication panel when there is genuinely nothing to change.
        var supportFilesUpToDate = false
    }

    enum Failure: LocalizedError {
        case sealInvalid(String)
        case missingResource(String)
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .sealInvalid(let why):
                return "This app's signature doesn't verify (\(why)). "
                     + "Refusing to install files as root from a bundle that may have been modified."
            case .missingResource(let name):
                return "\(name) is missing from this build, so there is nothing to install. "
                     + "Rebuild with build-app.sh."
            case .cancelled:
                return "Authentication was cancelled."
            case .failed(let detail):
                return detail
            }
        }
    }

    // MARK: - State

    static func state() -> State {
        let fm = FileManager.default
        var s = State()
        s.supportFilesReady = isRootOwned(routeWrapper) && isRootOwned(vpncScript)
        s.helperPresent = fm.isExecutableFile(atPath: rootHelper)
        s.sudoersPresent = fm.fileExists(atPath: sudoersFile)
        s.helperUsable = VPNRunner.shared.helperIsUsable()
        s.canProvision = bundledResource("route-wrapper.sh") != nil
                      && bundledResource("vpnc-script") != nil
        s.supportFilesUpToDate = s.supportFilesReady && supportFilesMatchBundle()
        return s
    }

    /// Compare installed support files against the bundled originals.
    ///
    /// Content comparison rather than timestamps: `install` doesn't preserve mtime,
    /// and a rebuild bumps it whether or not anything changed.
    static func supportFilesMatchBundle() -> Bool {
        func same(_ bundled: String, _ installed: String) -> Bool {
            guard let a = bundledResource(bundled),
                  let x = FileManager.default.contents(atPath: a),
                  let y = FileManager.default.contents(atPath: installed) else { return false }
            return x == y
        }
        return same("route-wrapper.sh", routeWrapper) && same("vpnc-script", vpncScript)
    }

    /// Root-owned and not writable by group or other — the same test the daemon
    /// applies before it will execute one of these files.
    private static func isRootOwned(_ path: String) -> Bool {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        guard (a[.ownerAccountID] as? NSNumber)?.intValue == 0 else { return false }
        let perms = (a[.posixPermissions] as? NSNumber)?.int16Value ?? 0
        return perms & 0o022 == 0
    }

    private static func bundledResource(_ name: String) -> String? {
        guard let res = Bundle.main.resourceURL?.path else { return nil }
        let p = (res as NSString).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    // MARK: - Install / remove

    static func install(_ backend: Backend) throws {
        try verifyOwnSeal()
        try runAsRoot(installCommand(backend))
    }

    /// Withdraws the sudo grant and the helper, leaving the support files: the
    /// daemon backend still needs those, and removing them would break it.
    static func removeRootHelper() throws {
        let cmd = [
            "/bin/rm -f \(shq(sudoersFile))",
            "/bin/rm -f \(shq(rootHelper))",
        ].joined(separator: "; ")
        try runAsRoot(cmd)
    }

    /// Removes everything this installer can place, support files included.
    static func removeAll() throws {
        let cmd = [
            "/bin/rm -f \(shq(sudoersFile))",
            "/bin/rm -f \(shq(rootHelper))",
            "/bin/rm -f \(shq(routeWrapper))",
            "/bin/rm -f \(shq(vpncScript))",
            "/bin/rmdir \(shq(libexecDir)) 2>/dev/null || true",
        ].joined(separator: "; ")
        try runAsRoot(cmd)
    }

    // MARK: - The command

    private static func installCommand(_ backend: Backend) throws -> String {
        guard let wrapperSrc = bundledResource("route-wrapper.sh") else {
            throw Failure.missingResource("route-wrapper.sh")
        }
        guard let vpncSrc = bundledResource("vpnc-script") else {
            throw Failure.missingResource("vpnc-script")
        }

        var lines = [
            "/usr/bin/install -d -o root -g wheel -m 0755 \(shq(libexecDir))",
            "/usr/bin/install -o root -g wheel -m 0755 \(shq(wrapperSrc)) \(shq(routeWrapper))",
            "/usr/bin/install -o root -g wheel -m 0755 \(shq(vpncSrc)) \(shq(vpncScript))",
        ]

        if backend == .rootHelper {
            guard let helperSrc = bundledResource("anyway-root-helper.sh") else {
                throw Failure.missingResource("anyway-root-helper.sh")
            }
            // A user name is about to be written into a sudoers rule. Anything
            // outside this set could change the rule's meaning, so refuse rather
            // than quote-and-hope.
            let user = NSUserName()
            let allowed = CharacterSet(charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
            guard !user.isEmpty, user.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                throw Failure.failed("Refusing to build a sudoers rule for the unusual "
                                   + "user name “\(user)”.")
            }

            lines.append("/usr/bin/install -d -o root -g wheel -m 0755 /usr/local/sbin")
            lines.append("/usr/bin/install -o root -g wheel -m 0755 "
                       + "\(shq(helperSrc)) \(shq(rootHelper))")

            // Written to a temp file and validated with visudo before being moved
            // into place: a malformed sudoers file can lock the user out of sudo
            // entirely. printf rather than a heredoc, so the whole command stays a
            // single line and needs no embedded newlines.
            let comment = "# AnywayConnect: allow \(user) to run only this helper without a password."
            let rule = "\(user) ALL=(root) NOPASSWD: \(rootHelper)"
            lines.append("T=$(/usr/bin/mktemp)")
            lines.append("/usr/bin/printf '%s\\n' \(shq(comment)) \(shq(rule)) > \"$T\"")
            lines.append("/bin/chmod 0440 \"$T\"")
            lines.append("if /usr/sbin/visudo -cqf \"$T\"; then "
                       + "/usr/bin/install -o root -g wheel -m 0440 \"$T\" \(shq(sudoersFile)); "
                       + "else /bin/rm -f \"$T\"; "
                       + "echo 'generated sudoers rule failed validation' >&2; exit 1; fi")
            lines.append("/bin/rm -f \"$T\"")
        }
        return lines.joined(separator: "; ")
    }

    // MARK: - Plumbing

    /// Fails when our own signature or sealed resources don't verify.
    ///
    /// This is the check that makes copying out of the bundle defensible: the
    /// files are user-writable, so their trustworthiness rests entirely on the
    /// seal still matching.
    private static func verifyOwnSeal() throws {
        var code: SecStaticCode?
        let url = Bundle.main.bundleURL as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &code) == errSecSuccess,
              let staticCode = code else {
            throw Failure.sealInvalid("signature unreadable")
        }
        let status = SecStaticCodeCheckValidity(staticCode, SecCSFlags(), nil)
        guard status == errSecSuccess else {
            throw Failure.sealInvalid("OSStatus \(status)")
        }
    }

    private static func runAsRoot(_ command: String) throws {
        let script = "do shell script \(appleScriptString(command)) with administrator privileges"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        task.standardInput = FileHandle.nullDevice
        do { try task.run() } catch {
            throw Failure.failed("Couldn't run the installer: \(error.localizedDescription)")
        }
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
        _ = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            // -128 is AppleScript's "user cancelled", which is a normal outcome
            // rather than a failure worth an alarming message.
            if errText.contains("-128") || errText.localizedCaseInsensitiveContains("cancel") {
                throw Failure.cancelled
            }
            let detail = errText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.failed(detail.isEmpty
                ? "The installer exited with status \(task.terminationStatus)."
                : detail)
        }
    }

    /// Quote for a POSIX shell.
    private static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Quote for an AppleScript string literal.
    private static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
