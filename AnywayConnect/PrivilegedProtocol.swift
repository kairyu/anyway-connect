import Foundation
import Security

// ── Contract between the app and the privileged daemon ───────────────────────
//
// Compiled into BOTH targets, so it must stay Foundation-only.
//
// This replaces the `sudo /usr/local/sbin/anyway-root-helper.sh` path. The
// difference that matters is authentication: a NOPASSWD sudoers rule can be
// invoked by *anything* running as the desktop user, so its safety rested
// entirely on the shell script's argument validation. An XPC listener can
// instead demand that the peer be a specific, correctly-signed binary — so an
// arbitrary process can't reach these operations at all, however carefully it
// crafts its arguments.
//
// Argument validation is still performed daemon-side. Authentication says *who*
// may ask; validation still decides *what* may be asked.

/// launchd label, the plist filename in Contents/Library/LaunchDaemons, the Mach
/// service name and the daemon binary's own name all have to agree. Derived from
/// the app's bundle identifier so nothing is hardcoded here either.
public func privilegedDaemonLabel() -> String {
    let appID = Bundle.main.bundleIdentifier
        ?? currentCodeIdentity()?.identifier
        ?? "unknown.app"
    return appID.hasSuffix(kHelperIdentifierSuffix) ? appID : appID + kHelperIdentifierSuffix
}

/// Bumped when this protocol changes, so an app paired with an older installed
/// daemon can detect the mismatch rather than call it with arguments that mean
/// something else. Same reasoning as the shell helper's `version` subcommand.
///
/// Version 1 is the first release of this protocol, in step with the app's own 1.0.
///
/// Bump it whenever an argument's meaning changes — and only ever bump it. Lowering it
/// would tell the app to accept a daemon that predates whatever the raise was protecting
/// against, and the check exists precisely so a mismatched pair falls back to sudo rather
/// than calling each other with arguments that mean something else.
public let kPrivilegedProtocolVersion = 1

/// Suffix distinguishing the daemon's signing identifier from the app's.
public let kHelperIdentifierSuffix = ".privhelper"

// ── Identity, read from our own signature rather than hardcoded ───────────────
//
// An earlier version had the team ID and bundle identifier as literals. That was
// two problems in one: it put the author's team ID in the source, and — worse —
// it silently broke the build for anyone else, since a requirement naming
// someone else's team can never be satisfied by your own signature.
//
// The app and the daemon are signed by the same team by construction, so each
// can read its own identity and require the peer to match. Nothing to configure,
// and it stays correct whoever builds it.

/// Signing identity of the running code: (identifier, teamID).
/// Returns nil when unsigned or ad-hoc signed — there is no team then, and the
/// XPC path must fail closed and let the caller fall back to sudo.
public func currentCodeIdentity() -> (identifier: String, team: String)? {
    var code: SecCode?
    guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code = code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
          let staticCode = staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode,
                                        SecCSFlags(rawValue: kSecCSSigningInformation),
                                        &info) == errSecSuccess,
          let dict = info as? [String: Any],
          let identifier = dict[kSecCodeInfoIdentifier as String] as? String,
          let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
    else { return nil }
    return (identifier, team)
}

/// Requirement the daemon applies to callers: our app, same team.
/// `anchor apple generic` pins the chain to Apple's roots, so a self-signed
/// binary claiming the identifier is rejected.
///
/// Called from the daemon, whose own identifier is the app's plus the helper
/// suffix — so the expected client identifier is derived, not configured.
/// The *app's* identifier, whichever side of the connection we happen to be on.
/// The daemon's identifier is the app's plus the suffix, so strip it if present.
/// Both requirement builders normalise through this, which makes them idempotent:
/// calling either from either side yields the same pair of strings. Without that,
/// a mistaken call site would silently produce `…privhelper.privhelper` — a
/// requirement nothing can satisfy, failing later as a puzzling refused
/// connection rather than an obvious error.
private func baseAppIdentifier(_ identifier: String) -> String {
    identifier.hasSuffix(kHelperIdentifierSuffix)
        ? String(identifier.dropLast(kHelperIdentifierSuffix.count))
        : identifier
}

public func clientCodeRequirement() -> String? {
    guard let me = currentCodeIdentity() else { return nil }
    return "anchor apple generic and identifier \"\(baseAppIdentifier(me.identifier))\""
        + " and certificate leaf[subject.OU] = \"\(me.team)\""
}

/// Requirement the app applies to the daemon, so a hijacked Mach name can't
/// impersonate it. Called from the app, so the daemon's identifier is our own
/// plus the suffix.
public func daemonCodeRequirement() -> String? {
    guard let me = currentCodeIdentity() else { return nil }
    let identifier = baseAppIdentifier(me.identifier) + kHelperIdentifierSuffix
    return "anchor apple generic and identifier \"\(identifier)\""
        + " and certificate leaf[subject.OU] = \"\(me.team)\""
}

/// Operations that need root. Deliberately a small, fixed surface — the same
/// three the shell helper exposed, plus status.
///
/// Note what is *absent*: no path arguments. The daemon owns the route-wrapper
/// and vpnc-script paths, exactly as the hardened shell helper does, because a
/// caller-supplied script path is arbitrary root code execution.
@objc public protocol PrivilegedHelperProtocol {

    /// Protocol version the installed daemon speaks.
    func version(reply: @escaping (Int) -> Void)

    /// Bring up the tunnel. The cookie is passed in-band rather than via a
    /// temp file — over XPC it never touches disk at all, which is strictly
    /// better than the mode-0600 file the shell path needed.
    ///
    /// - Parameters:
    ///   - logPath: where to append openconnect's output. NOT trusted: the daemon
    ///     derives the only acceptable path from the connected client's uid and
    ///     requires this to equal it, then opens it refusing symlinks in any
    ///     component and verifies ownership through the descriptor. Created owned by
    ///     the calling user if absent, so the unprivileged app can still write to it.
    func startTunnel(protocolName: String,
                     host: String,
                     fingerprint: String,
                     resolve: String,
                     autoAddLocalSubnet: Bool,
                     exceptionRoutes: [String],
                     logPath: String,
                     cookie: String,
                     reply: @escaping (Bool, String) -> Void)

    /// Signal the tunnel down gracefully, waiting for openconnect to run its
    /// own disconnect teardown before escalating.
    func stopTunnel(reply: @escaping (Bool, String) -> Void)

    /// Whether a tunnel process is alive, and its pid.
    func tunnelStatus(reply: @escaping (Bool, Int) -> Void)

    /// Put the physical default route back after a failed tunnel left it
    /// pointing at a dead utun.
    func restoreDefaultRoute(gateway: String, interface: String,
                             reply: @escaping (Bool, String) -> Void)
}

// ── Opening a file in a directory someone else can write ─────────────────────

public enum PrivilegedFile {

    /// Refuses symlinks in *any* path component, not just the final one the way
    /// O_NOFOLLOW does. macOS 11+, absent from Darwin's Swift overlay.
    public static let oNoFollowAny: Int32 = 0x2000_0000

    public enum OpenResult {
        case opened(fd: Int32)
        case refused(String)
    }

    /// Open `path` for appending, safely enough for root to do it inside a directory
    /// the desktop user can write.
    ///
    /// The path cannot be trusted no matter how well the *caller* is authenticated,
    /// because any process running as that user can swap what sits there between a
    /// check and an open. So there is no check-then-open: the open is the check, and
    /// everything after it is verified through the descriptor rather than by looking
    /// up the path a second time.
    ///
    ///  - O_NOFOLLOW_ANY: a symlink anywhere in the path fails the open instead of
    ///    redirecting the write.
    ///  - O_CREAT|O_EXCL first: separates "we created it" from "it already existed"
    ///    without a racy existence probe, and refuses to create through a link.
    ///  - fstat on the fd: must be a plain file with exactly one link. The link count
    ///    is what defeats a hard link to someone else's file, which symlink
    ///    protection does nothing about.
    ///  - fchown on the fd, never chown on the path.
    ///  - O_NONBLOCK, or a planted FIFO would hang this call forever: opening a pipe
    ///    for writing blocks until someone opens the read end, so without it a local
    ///    attacker could wedge the root daemon — and every connect waiting on its
    ///    reply — with a single mkfifo. Cleared once the file is known to be regular,
    ///    for which the flag is a no-op anyway.
    public static func openAppendOnly(path: String, owner uid: uid_t) -> OpenResult {
        let base = O_WRONLY | O_APPEND | O_NONBLOCK | oNoFollowAny
        var created = false
        var fd = open(path, base | O_CREAT | O_EXCL, 0o644)
        if fd >= 0 {
            created = true
        } else if errno == EEXIST {
            fd = open(path, base)
        }
        guard fd >= 0 else {
            return .refused("open failed: \(String(cString: strerror(errno)))")
        }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd); return .refused("fstat failed")
        }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            close(fd); return .refused("not a regular file")
        }
        guard st.st_nlink == 1 else {
            close(fd); return .refused("\(st.st_nlink) hard links")
        }
        if created {
            fchown(fd, uid, gid_t(bitPattern: -1))
        } else if st.st_uid != uid {
            close(fd); return .refused("owned by uid \(st.st_uid), not \(uid)")
        }
        // Safe now that the target is known to be a regular file.
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        return .opened(fd: fd)
    }
}

// ── Validation shared by both sides ──────────────────────────────────────────
// Kept here so the daemon and the app cannot drift apart on what is acceptable.
// The daemon applies these regardless of what the app claims to have checked.

public enum PrivilegedValidation {

    public static let allowedProtocols: Set<String> = [
        "anyconnect", "nc", "gp", "pulse", "f5", "fortinet", "array",
    ]

    public static func isValidProtocol(_ s: String) -> Bool { allowedProtocols.contains(s) }

    /// Host names and addresses only. Rejects anything that could be read as an
    /// option, and anything carrying path or shell metacharacters.
    public static func isValidHost(_ s: String) -> Bool {
        guard !s.isEmpty, !s.hasPrefix("-") else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._:".contains($0)) }
    }

    public static func isValidFingerprint(_ s: String) -> Bool {
        if s == "-" { return true }
        guard !s.hasPrefix("-") else { return false }
        if s.hasPrefix("pin-sha256:") {
            let body = String(s.dropFirst("pin-sha256:".count))
            return !body.isEmpty && body.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || "+/=".contains($0))
            }
        }
        return !s.isEmpty && s.allSatisfy {
            $0.isASCII && ($0.isHexDigit || $0 == ":")
        }
    }

    /// "hostname:address", as emitted by `openconnect --authenticate`.
    public static func isValidResolve(_ s: String) -> Bool {
        if s == "-" { return true }
        guard s.contains(":"), !s.hasPrefix("-") else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._:".contains($0)) }
    }

    /// Numeric IPv4 CIDR only. Host names are resolved app-side before they get
    /// here, so the privileged surface never has to touch DNS.
    public static func isValidCIDR(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let len = Int(parts[1]), (0...32).contains(len) else { return false }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { o in
            guard !o.isEmpty, o.count <= 3, let v = Int(o), (0...255).contains(v) else { return false }
            return true
        }
    }

    public static func isValidIPv4(_ s: String) -> Bool {
        isValidCIDR(s + "/32")
    }

    public static func isValidInterface(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
    }
}
