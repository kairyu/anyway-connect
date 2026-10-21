import Foundation

// ── The harness's own assertion machinery and fixture loader ─────────────────
//
// Compiled together with every AnywayConnect source EXCEPT main.swift (see
// test/run-swift-harness.sh), so the suites below drive the REAL pure functions
// rather than a copy of them.
//
// FOUR STANDING CONSTRAINTS, all of them load-bearing and all of them checked
// by the runner's static gates rather than trusted:
//
//  1. No suite touches the config store's shared instance. It resolves
//     ~/.config/anyway-connect/config.json in a private initialiser with no
//     override, so a harness that touches it can WRITE the developer's live
//     config — which has caused data loss twice. `AppConfig` is exercised by
//     decoding literal JSON if it is exercised at all.
//  2. No suite opens a real /var/run path. `NetState.load` takes `path:` with a
//     default, and reaching for the default would read a root-owned live file;
//     the suites use `decode(_:)` over literal `Data` instead. That is why both
//     state-file path constants are in the runner's forbidden list.
//  3. No suite instantiates a window or calls NSApp. Suites 1-9 are
//     pure-function tests, so the rule is vacuous today; if one ever needs a
//     window it uses `orderFrontRegardless()` and never the activation call
//     that steals focus from the developer's session.
//  4. Nothing here shells out. The impure collectors are off limits by name.

enum H {
    private(set) static var passed = 0
    private(set) static var failed = 0

    static func suite(_ name: String) {
        print("== \(name) ==")
    }

    static func ok(_ condition: Bool, _ what: String) {
        if condition {
            passed += 1
            print("  PASS: \(what)")
        } else {
            failed += 1
            print("  FAIL: \(what)")
        }
    }

    static func eq<T: Equatable>(_ got: T, _ want: T, _ what: String) {
        if got == want {
            passed += 1
            print("  PASS: \(what)")
        } else {
            failed += 1
            print("  FAIL: \(what)")
            print("        got  \(got)")
            print("        want \(want)")
        }
    }

    /// Element for element, reporting the FIRST divergence and its index rather
    /// than two walls of text. This is what makes "the 236-entry list matches"
    /// a usable failure message instead of a diff the reader has to do by eye.
    static func eqList<T: Equatable>(_ got: [T], _ want: [T], _ what: String) {
        if got == want {
            passed += 1
            print("  PASS: \(what) (\(got.count) entries)")
            return
        }
        failed += 1
        print("  FAIL: \(what)")
        if got.count != want.count {
            print("        count got \(got.count), want \(want.count)")
        }
        for i in 0..<min(got.count, want.count) where got[i] != want[i] {
            print("        first divergence at [\(i)]")
            print("        got  \(got[i])")
            print("        want \(want[i])")
            break
        }
        if got.count > want.count {
            print("        extra got[\(want.count)] \(got[want.count])")
        } else if want.count > got.count {
            print("        missing want[\(got.count)] \(want[got.count])")
        }
    }

    static func report() -> Never {
        print("")
        print("== RESULT: \(passed) passed, \(failed) failed ==")
        exit(failed == 0 ? 0 : 1)
    }
}

/// Paths come from the runner, never from a path literal: the harness is
/// compiled in /tmp/anyway-scratch, so it has no idea where the worktree is.
enum Fixtures {
    static let dir = required("ANYWAY_FIXTURES")
    static let expectedDir = required("ANYWAY_EXPECTED")

    private static func required(_ name: String) -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            FileHandle.standardError.write(Data("harness: \(name) is not set\n".utf8))
            exit(70)
        }
        return value
    }

    private static func read(_ path: String) -> Data {
        guard let data = FileManager.default.contents(atPath: path) else {
            FileHandle.standardError.write(Data("harness: cannot read \(path)\n".utf8))
            exit(70)
        }
        return data
    }

    static func routeTable(_ name: String) -> String {
        String(decoding: read("\(dir)/netstat-rn-inet.\(name).txt"), as: UTF8.self)
    }

    static func scutilKeys(_ name: String) -> [String] {
        NetReconcile.configdKeys(fromScutilOutput:
            String(decoding: read("\(dir)/scutil-keys.\(name).txt"), as: UTF8.self))
    }

    /// `interfaces.*.json` IS the snapshot format — `NetInterface` is `Codable`
    /// precisely so there is no second `ifconfig` parser anywhere in the tree.
    static func interfaces(_ name: String) -> [NetInterface] {
        do {
            return try JSONDecoder().decode([NetInterface].self,
                                            from: read("\(dir)/interfaces.\(name).json"))
        } catch {
            FileHandle.standardError.write(
                Data("harness: interfaces.\(name).json: \(error)\n".utf8))
            exit(70)
        }
    }

    /// One line per entry, blank lines dropped. The committed expected files are
    /// re-derived by test/harness/derive-expected.sh and diffed against it by
    /// the runner BEFORE this binary is compiled, so reading them here is
    /// reading an independently derived list and not the planner's own output.
    static func expected(_ relative: String) -> [String] {
        String(decoding: read("\(expectedDir)/\(relative)"), as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

// MARK: - Shared shorthands

/// `evaluateDefaultGateway`'s answer as the SAME string the shell parity suite
/// asserts (`test/test-onlink-guard.sh`'s `verdict`): `"accept"` or the
/// `GatewayRejection` raw value. One vocabulary across both guards is what
/// keeps the duplicate implementation honest.
func guardVerdict(_ gateway: String, _ target: String, _ ifaces: [NetInterface]) -> String {
    switch evaluateDefaultGateway(candidate: gateway, targetInterface: target,
                                  interfaces: ifaces) {
    case .accept: return "accept"
    case .reject(let reason): return reason.rawValue
    }
}

/// A `ReconcileCommand.route` reduced to one line of argv, in exactly the form
/// `derive-expected.sh` prints. Comparing the argv rather than the
/// `RouteDeletion` means the diff pins the argument SHAPE too — §4.2's
/// `inet_aton` reasoning lives entirely in the argument shape.
func argvLine(_ command: ReconcileCommand) -> String {
    if case .route(let argv) = command { return argv.joined(separator: " ") }
    return "not-a-route-command: \(command)"
}

func oneAddress(_ name: String, _ address: String, _ prefix: Int,
                up: Bool = true, loopback: Bool = false, p2p: Bool = false) -> NetInterface {
    NetInterface(name: name, ipv4: IPv4(address), prefixLength: prefix,
                 isUp: up, isLoopback: loopback, isPointToPoint: p2p)
}

func noAddress(_ name: String, up: Bool = true,
               loopback: Bool = false, p2p: Bool = false) -> NetInterface {
    NetInterface(name: name, ipv4: nil, prefixLength: nil,
                 isUp: up, isLoopback: loopback, isPointToPoint: p2p)
}
