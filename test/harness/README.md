# The Swift harness

There is no Xcode project and no SwiftPM manifest in this repo, and no unit-test
target for the AppKit code. The pure decision layer — the on-link guard
(`AnywayConnect/NetGuard.swift`) and the reconcile planner
(`AnywayConnect/NetReconcile.swift`) — is therefore tested by compiling the real
app sources together with a throwaway entry point and running the result.

That entry point used to be an uncommitted scratch file. It was lost to a `/tmp`
prune, which made the recorded baseline ("282 passed / 0 failed across suites
1-9") unverifiable and left "gain cases for the next change" with nothing to add
them to. So the suites are committed here, and the loss cannot recur.

```sh
sh test/run-swift-harness.sh          # expect "N passed, 0 failed"
```

## What the runner does, and why in that order

1. **Re-derives every expected list and diffs it, before compiling anything.**
   `derive-expected.sh` is run for each fixture and its output compared against
   the committed `expected/*.txt`. A list that moved is then reported as a
   derivation mismatch rather than as a Swift assertion failure fifty lines
   further down.
2. **Runs the multi-netif check** from `test/fixtures/README.md` with the sweep's
   own destination filters applied, so "every swept destination appears on
   exactly one netif" — the step that turns `N` into `2N` — is checked rather
   than assumed.
3. **Three static gates** over the tree: no forbidden reference in
   `test/harness/*.swift`, exactly one `SIGKILL` in the daemon (the bounded
   runner's overrun kill, counted both inside its function and file-wide), and
   one `pgrep` pattern literal per binary. The last is a **warning** for now:
   `AnywayConnect/VPNRunner.swift` legitimately carries two copies until the
   defect-1 work hoists the second into a single constant, and that step flips
   this gate to a hard failure.
4. **Compiles** every `AnywayConnect/*.swift` *except* `main.swift` — the one
   file a harness must not copy, because Swift allows top-level statements only
   in `main.swift` and the harness supplies its own — together with
   `test/harness/*.swift`.
5. **Runs** the binary under a time bound, with `ANYWAY_SINGLE_INSTANCE=0` so it
   does not hand off to the already-running app and exit. The bound is
   hand-rolled (background, poll, kill on overrun) rather than `timeout 120`,
   because macOS ships no `timeout(1)` — only a machine with Homebrew coreutils
   has one, which is why that version passed locally and exited 127 on CI.

The scratch path is **fixed** at `/tmp/anyway-scratch` and the binary is
**always** named `a`. Each distinct executable path costs the developer a
separate approval prompt, so the path is reused rather than made unique per run.
The copied `*.swift` files are cleared before and after each run; the directory
and the binary are left in place.

## How the expected lists are derived

Asserting a count the planner produced against the planner is a tautology. So
`derive-expected.sh` re-implements, in awk, **from the fixture text and the
paired `interfaces.*.json` alone**:

- the sweep's keep/skip classification — the closed list of keep reasons, not
  "dead by exclusion";
- the destination canonicalisation — an explicit dotted quad plus an explicit
  netmask, never netstat's `10.1/16` shorthand, because `route`'s own parser runs
  the pre-slash text through `inet_aton` and would read `3.7.35` as `3.7.0.35`;
- the ordering — distinct `(destination, netmask)` pairs in **first-seen row
  order**, each emitting one unscoped deletion followed by one `-ifscope`
  deletion per distinct netif in first-seen order.

It reads no Swift source and calls no planner. Two output modes:

```sh
sh test/harness/derive-expected.sh carried-home          # the deletion list
sh test/harness/derive-expected.sh --kept carried-home   # the rows it declines to delete
```

giving `expected/<fixture>.sweep.txt` and `expected/<fixture>.kept.txt`. The
chain the verification record rests on is

```
derive-expected.sh  ≡  expected/*.txt      (diffed by the runner, before compiling)
expected/*.txt      ≡  the planner's own output   (asserted by suites 5 and 6)
```

so the planner and an independent re-derivation are pinned to each other
**element for element**. On `netstat-rn-inet.carried-home.txt` with
`interfaces.carried-home.json` that is **118** distinct swept destinations and
**236** deletions, which is the same answer the `awk` reduction in
`test/fixtures/README.md` gives and the same answer two prior independent
derivations gave.

**What is NOT derived by the script.** Clauses (b), (f) and (g) of the planner —
the default-route classification, the install-target ladder and the withholding
pass — are few enough per fixture to enumerate by hand, which is what the design
asks for. Suite 5 writes them out with the fixture row that produces each, and
takes only the clause-(c) slice of `kept` from the derived file.

The printed form is the complete `/sbin/route` argv rather than a `RouteDeletion`
value, so the diff pins the **argument shape** too: a sweep that emitted
`-net 3.7.35` instead of `-net 3.7.35.0 -netmask 255.255.255.0` would delete a
route that was never in the table and leave the real one in place.

## The four standing constraints

All four are enforced by the runner's gates rather than trusted.

1. **No suite touches the config store's shared instance.** It resolves
   `~/.config/anyway-connect/config.json` in a private initialiser with no
   override, so a harness that touches it can **write** the developer's live
   config — which has caused data loss twice. `AppConfig` is exercised by
   decoding literal JSON if it is exercised at all, and nothing here reads or
   echoes that file: it holds credentials.
2. **No suite opens a real `/var/run` path.** `NetState.load` and
   `TunnelAttribution.load` both take `path:` with a default, and reaching for
   either default would read a root-owned live file on the developer's machine.
   Suites 9 and 11 drive `decode(_:)` from literal `Data`, which is why both
   state-file path constants are in the forbidden list.
3. **No suite instantiates a window or calls `NSApp`.** Every suite is a
   pure-function test, so the rule is vacuous today. If one ever needs a window
   it uses `orderFrontRegardless()` and never the activation call, which steals
   focus from the developer's session and has previously corrupted the config.
4. **The forbidden-reference grep is scoped to `test/harness/*.swift`**, never to
   the copied tree. The app sources reference the config store and `NetProbe`
   legitimately, so a grep over the copies could never be zero and the gate
   would fail on every run, passing or not.

Nothing in the harness shells out, opens a socket, or signals a process. The
impure collectors are off limits by name.

## The suites

| Suite | Covers |
|---|---|
| 1 | `evaluateDefaultGateway`: one row per numbered step in its fixed order, plus the four literal rows that `test/test-onlink-guard.sh` runs against the POSIX sh port — `en0 10.0.1.1 -> accept`, `en0 192.168.1.1 -> gatewayOffLink`, `en5 10.0.1.1 -> targetInterfaceMissing`, `en0 192.168.204.16 -> gatewayIsTunnelAddress` |
| 2 | `parseRouteTable`: row counts, `isIfScoped` from the `I` flag, `gatewayText` verbatim, every destination kind, both netstat abbreviation rules, and the fail-closed `[]` |
| 3 | `configdKeys(fromScutilOutput:)` and `matchConfigdKey`. The latter is `private`, so it is driven through clause (a) of `plan`, the one observable it feeds |
| 4 | `physicalDefault` and `deriveDefaultGateway`, including the exact transcript |
| 5 | `plan` on every committed fixture: the ordered action list, the abort, the exact ordered `kept` multiset and the install-candidate note |
| 6 | the full ordered sweep list, against the independently derived literal |
| 7 | `commands(for:)`: the scoped/unscoped split, the single batched `scutil`, explicit netmasks, the `-ifscope` suffix and the prologue → install → sweep partition |
| 8 | `gate` |
| 9 | `NetState.decode`'s rejection list, from literal `Data` |
| 11 | `tunnelScope`, `TunnelAttribution.decode` and `attributionOutcome`, all from literals: the address witness in all three directions, `.none` for an unusable snapshot, the decoder's rejections and its field drops, the **round trip** through the pinned encoder, and the tick table including the two-tick address rule |
| 12 | the planner under each tunnel scope, against fixtures: the `late-tunnel` discrimination case and its fail-closed twin, clause (f)'s withholding on `live-shape` and its composition with clause (g) on `live-shape.stale-en8`, `lingering-utun` under both witness outcomes, `carried-home`'s unchanged 118/236, `.none` via `interfaces.lo0-only.json`, `vpn-up` under both answers, and `dropRevivedTunnelActions` |
| 13 | clause (f)'s install-target ladder and `preferredInstallTarget`: the four `dual-default` snapshots against one byte-identical route table, the two pre-lookup rejection reasons of `unspecified-default`, the unchanged rungs 4-5 on `two-physical`, the unchanged `carried-home`/`vpn-up` answers, and the preference function in isolation from literals |

Suites 1-9 are a **reconstruction** and cannot be faithful to the lost original.
What they can be is derived from the code they test, which is what the table
above describes. The reconstruction was accepted on two properties, not on a
count: the independently derived 118/236 lists match the planner element for
element, and the four literal guard rows report their exact reasons.
