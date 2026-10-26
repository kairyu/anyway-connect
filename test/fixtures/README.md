# Network fixtures

Inputs for the pure decision layer of the network-resilience fix: the route-table
parser (`NetReconcile.parseRouteTable`), the on-link guard
(`evaluateDefaultGateway`) and the reconcile planner (`NetReconcile.plan`).

There is no unit-test target in this project, so these are driven by the Swift
harness in `test/harness/`, compiled and run by `sh test/run-swift-harness.sh`
at the fixed scratch path `/tmp/anyway-scratch` with the binary always named
`a`. See `test/harness/README.md`. They are checked in because the states they describe cannot be
reproduced on demand: one of them is a laptop that had been carried from one
network to another with a dead tunnel still in its route table, and the reboot
that fixed the machine destroyed the evidence.

## `interfaces.*.json` is the test input; `ifconfig.*.txt` is provenance only

`NetInterface` is `Codable` precisely so that there is exactly one definition of
"what a live interface looked like" and **no second `ifconfig` parser** anywhere
in the tree. Every suite reads `interfaces.*.json`. `ifconfig.vpn-up.txt` is kept
only to show where the hand-authored JSON came from; nothing parses it, and
nothing should be changed to parse it.

Every `interfaces.*.json` carries the `ipv4s` array — all IPv4 addresses of the
link, in `getifaddrs` order — because a guard rejection can authorise a
privileged route deletion, so a next hop that is on-link for a *secondary*
address of a link must not be classified `gatewayOffLink`.

## How the captures were taken

Read-only, once, on a machine that was live on the VPN at the time (`utun7`, ~122
static routes via `10.0.1.1`). No command below mutates anything:

```sh
netstat -rn -f inet                                          > test/fixtures/netstat-rn-inet.vpn-up.txt
ifconfig | grep -v -e ' ether ' -e ' inet6 '                 > test/fixtures/ifconfig.vpn-up.txt
echo 'list State:/Network/Service/[^/]+/(DNS|IPv4)' | scutil > test/fixtures/scutil-keys.vpn-up.txt
```

Two notes on the second line. The `' ether '` filter does **not** match real
`ifconfig` output, whose flag lines are tab-indented — the MAC addresses came
through and were removed afterwards, as part of the renumbering below. And the
filter exists only because the raw output carries MAC and IPv6 addresses that no
test reads.

## Renumbering, and why "reproducible" means the command *plus* this mapping

`origin` is a public GitHub repository and the `vpn-up` capture *is* an
employer's split-tunnel configuration: ~120 destination prefixes, an internal
`192.168.192/18` range and the configd service UUID. The suites depend on the
table's *structure* — row counts, prefix lengths, scoped/unscoped duplicate
pairs, flag strings — and never on a particular address, so every public or
employer-internal prefix was renumbered **once, one-to-one and reversibly**
before the fixture was committed.

So: a later reader must **not** "restore" these addresses to make the fixture
look authentic. Re-capturing on another machine and re-deriving the counts below
is the supported way to refresh them.

What the rewrite preserves, by construction:

- the printed form of every destination, so netstat's two abbreviation rules (the
  slash form and the class-masked form) are still exercised — including
  `100.68.0/16`, a three-octet print of a /16, the shape that made a naive
  octet-count cross-check wrong;
- the prefix length of every row (`/4` … `/32` all still present);
- the row count (139 as captured; **140** since the review-fix pass added one
  row, see below), the distinct-destination count (130 as captured, now **131**)
  and all 9 destinations that appear in both scoped and unscoped form;
- every flag string, gateway, netif and trailing `!`.

The target space is **RFC 6598 `100.64.0.0/10`** (shared address space, assigned
to no party, not publicly routable), and not the TEST-NET ranges the design
proposed: three /24s cannot hold this capture's `/16`…`/23` prefixes at their
original length, and the prefix length is exactly what §4.2's rules 3–5 turn on.
Addresses that identify nothing and that every worked example in the design
cites are kept verbatim: `10.0.1.x`, `192.168.1.x`, `192.168.204.16`, `127/8`,
`169.254/16`, `224.0.0/4`, `255.255.255.255`.

The configd service UUID became one fixed literal
(`11111111-2222-3333-4444-555555555555`), and MAC addresses became literals in
the RFC 7042 documentation range (`0:0:5e:0:53:…`). The mDNS group address
`1:0:5e:0:0:fb` is standard and was kept.

### Mapping (one-to-one, reversible)

| captured | committed |
|---|---|
| `3.7.35/25` | `100.72.51/25` |
| `3.21.137.128/25` | `100.72.0.128/25` |
| `3.25.41.128/25` | `100.72.51.128/25` |
| `3.33.178.229/32` | `100.72.0.1/32` |
| `3.80.20.128/25` | `100.72.52.128/25` |
| `3.104.34.128/25` | `100.72.53.128/25` |
| `3.120.121/25` | `100.72.52/25` |
| `3.127.194.128/25` | `100.72.54.128/25` |
| `3.208.72/25` | `100.72.53/25` |
| `3.235.71.128/25` | `100.72.55.128/25` |
| `3.235.72.128/25` | `100.72.56.128/25` |
| `3.235.73/25` | `100.72.54/25` |
| `3.235.82/23` | `100.72.2/23` |
| `3.235.96/23` | `100.72.20/23` |
| `4.34.125.128/25` | `100.72.57.128/25` |
| `4.35.64.128/25` | `100.72.58.128/25` |
| `8.5.128/23` | `100.72.22/23` |
| `10.32.144.4/32` | `100.72.0.2/32` |
| `10.32.144.5/32` | `100.72.0.3/32` |
| `13.52.6.128/25` | `100.72.59.128/25` |
| `13.112.53.107` | `100.72.0.4` |
| `13.159.222.15/32` | `100.72.0.5/32` |
| `13.210.2.192/26` | `100.72.0.64/26` |
| `13.236.8/25` | `100.72.55/25` |
| `13.248.196.238/32` | `100.72.0.6/32` |
| `13.248.198.144/32` | `100.72.0.7/32` |
| `13.248.206.243/32` | `100.72.0.8/32` |
| `15.193/19` | `100.71/19` |
| `15.197.233.235/32` | `100.72.0.9/32` |
| `15.220.80/24` | `100.72.1/24` |
| `15.220.81/25` | `100.72.56/25` |
| `18.182.96.64/26` | `100.72.62.64/26` |
| `18.184.2.128/25` | `100.72.60.128/25` |
| `18.236.61/25` | `100.72.57/25` |
| `18.254.23.128/25` | `100.72.61.128/25` |
| `18.254.61/25` | `100.72.58/25` |
| `20.203.158.80/28` | `100.72.0.16/28` |
| `20.203.190.192/26` | `100.72.63.64/26` |
| `23.35.100.73/32` | `100.72.0.10/32` |
| `23.192.46.11/32` | `100.72.0.11/32` |
| `23.192.46.64/32` | `100.72.0.12/32` |
| `35.158.127.64/26` | `100.72.64.64/26` |
| `43.206.185.214/32` | `100.72.0.13/32` |
| `50.239.202/23` | `100.72.24/23` |
| `50.239.204/24` | `100.72.32/24` |
| `52.55.191.224/27` | `100.72.0.32/27` |
| `52.61.100.128/25` | `100.72.62.128/25` |
| `52.84.151/24` | `100.72.33/24` |
| `52.202.62.192/26` | `100.72.65.64/26` |
| `52.210.237.186/32` | `100.72.0.14/32` |
| `54.76.163.254/32` | `100.72.0.15/32` |
| `54.190.198.32/28` | `100.72.65.16/28` |
| `62.12.232/22` | `100.71.248/22` |
| `63.32.174.155/32` | `100.72.65.1/32` |
| `64.125.62/24` | `100.72.34/24` |
| `64.211.144/24` | `100.72.35/24` |
| `64.224.32/19` | `100.71.32/19` |
| `65.39.152/24` | `100.72.36/24` |
| `69.174.57/24` | `100.72.37/24` |
| `69.174.108/22` | `100.71.252/22` |
| `74.125.250/24` | `100.72.38/24` |
| `75.2.119.112/32` | `100.72.65.2/32` |
| `76.223.70.74/32` | `100.72.65.3/32` |
| `76.223.85.145/32` | `100.72.65.4/32` |
| `76.223.90.169/32` | `100.72.65.5/32` |
| `99.77.128/18` | `100.70.128/18` |
| `99.79.20/25` | `100.72.59/25` |
| `99.83.140.42/32` | `100.72.65.6/32` |
| `101.36.167/24` | `100.72.39/24` |
| `101.36.170/23` | `100.72.26/23` |
| `103.122.166/23` | `100.72.28/23` |
| `111.33.115/25` | `100.72.60/25` |
| `111.33.181/25` | `100.72.61/25` |
| `115.110.154.192/26` | `100.72.66.64/26` |
| `115.114.56.192/26` | `100.72.66.128/26` |
| `115.114.115/26` | `100.72.62/26` |
| `115.114.131/26` | `100.72.63/26` |
| `120.29.148/24` | `100.72.40/24` |
| `121.244.146/27` | `100.72.64/27` |
| `134.224` | `100.64` |
| `144.195` | `100.65` |
| `147.124.96/19` | `100.71.192/19` |
| `149.137/17` | `100.69/17` |
| `156.45/17` | `100.70/17` |
| `159.124` | `100.66` |
| `160.1.56.128/25` | `100.72.63.128/25` |
| `161.199.136/22` | `100.72.4/22` |
| `162.255.36/22` | `100.72.8/22` |
| `165.254.88/23` | `100.72.30/23` |
| `166.108.64/18` | `100.70.192/18` |
| `168.86.128/18` | `100.71.64/18` |
| `170.114` | `100.67` |
| `170.114.45/24` | `100.72.41/24` |
| `170.114.46/24` | `100.72.42/24` |
| `173.231.80/20` | `100.71.224/20` |
| `192.168.192/18` | `100.71.128/18` |
| `192.204.12/22` | `100.72.12/22` |
| `198.251.128/17` | `100.69.128/17` |
| `202.177.207.128/27` | `100.72.64.32/27` |
| `203.200.219.128/27` | `100.72.65.32/27` |
| `204.80.104/21` | `100.71.240/21` |
| `204.141.28/22` | `100.72.16/22` |
| `206.247.0/16` | `100.68.0/16` |
| `207.226.132` | `100.72.43` |
| `209.9.211` | `100.72.44` |
| `209.9.215` | `100.72.45` |
| `213.19.144` | `100.72.46` |
| `213.19.153` | `100.72.47` |
| `213.244.140` | `100.72.48` |
| `221.122.63` | `100.72.49` |
| `221.122.64` | `100.72.50` |
| `221.122.88.64/27` | `100.72.66.32/27` |
| `221.122.88.128/25` | `100.72.64.128/25` |
| `221.122.89.128/25` | `100.72.65.128/25` |
| `221.123.139.192/27` | `100.72.66.192/27` |
| `d6:9e:ac:a0:e3:f2` | `0:0:5e:0:53:1` |

## The files

| File | Origin |
|---|---|
| `netstat-rn-inet.vpn-up.txt`, `ifconfig.vpn-up.txt`, `scutil-keys.vpn-up.txt` | captured live and renumbered: 140 rows (139 captured + one added, below), the unscoped `default → 192.168.204.16 utun7` beside the **scoped** `default → 10.0.1.1 en0`, the duplicate scoped/unscoped rows, the two `utun7` configd keys **and** the UUID service's two |
| `interfaces.vpn-up.json` | `[NetInterface]`, authored by hand from `ifconfig.vpn-up.txt` |
| `netstat-rn-inet.carried-home.txt`, `interfaces.carried-home.json` | **the reported incident.** The captured table plus the home link's own rows (`192.168.1/24 link#15`, `192.168.1.42/32 link#15`, and one host route via the live router `192.168.1.1`), against a snapshot where `en0` is `192.168.1.42/24` and `utun7` is gone. The surviving `default 10.0.1.1 UGScIg en0` row is the blackhole |

### Rows added by hand for FR-2.6c (the review-fix pass)

Four synthetic host routes, added because nothing in the capture exercised a next
hop that is *inside* a live link's subnet but is still not installable — the case
the sweep used to delete in breach of FR-2.6c:

| Row | In | Classified as |
|---|---|---|
| `10.0.1.77 → 10.0.1.22` | **both** tables | in `vpn-up` (`en0 = 10.0.1.22/24`) the gateway is en0's **own address** ⇒ kept; in `carried-home` (`en0 = 192.168.1.42/24`) it is simply off-link ⇒ swept, and it is the one destination N grew by |
| `192.168.1.77 → 192.168.1.42` | `carried-home` | en0's own address at home ⇒ kept |
| `192.168.1.88 → 192.168.1.0` | `carried-home` | the subnet's network address ⇒ kept |
| `192.168.1.99 → 192.168.1.255` | `carried-home` | the subnet's broadcast address ⇒ kept |

The row is in **both** large tables on purpose: `carried-home` is `vpn-up` plus
the home link's rows, and that relationship is what makes "the same table, a
different network" the whole point of the pair.
| `netstat-rn-inet.clean.txt`, `interfaces.clean.json` | an **unscoped** physical default via the live router, no `utun`, no dead gateway — a machine with nothing to repair |
| `netstat-rn-inet.cap-exceeded.txt` | synthetic: 300 distinct destinations via a dead gateway. **It has no `interfaces.*.json` of its own and is paired with `interfaces.clean.json`** — recorded here and in `test/harness/derive-expected.sh`, which carries the same pairing so a script and this table cannot drift. `clean`'s `en0` is `192.168.1.42/24`, the same subnet as the fixture's on-link row and off-link from its `10.0.1.1` gateway, which is what makes all 300 destinations swept and the cap fire. (`interfaces.carried-home.json` gives the identical answer — its `en0` carries the same address — but it also carries three `utun`s that have nothing to do with this fixture, so the smaller snapshot is the one the harness uses.) |
| `netstat-rn-inet.lingering-utun.txt`, `interfaces.lingering-utun.json` | `utun7` still addressed with no tunnel process, plus routes via a *second*, vanished utun address — the kept case and the swept case of the same shape |
| `netstat-rn-inet.two-physical.txt`, `interfaces.two-physical.json` | synthetic: `en0` and `en1` both up and addressed, no default route — the ambiguous install target |
| `netstat-rn-inet.two-tunnels.txt`, `interfaces.two-tunnels.json`, `scutil-keys.two-tunnels.txt` | synthetic: `utun0` and `utun7` each with a default route and a pair of configd keys — the third-party-VPN case. `utun0` carries **no IPv4**, which is the live shape of this machine's system tunnels, so it also pins that an IPv4-less link is present in the snapshot rather than omitted |
| `netstat-rn-inet.link-down.txt`, `interfaces.link-down.json` | synthetic: `en0` addressed but **not up** with its default via an off-link gateway, beside a second live link so the snapshot stays usable |
| `netstat-rn-inet.no-default.txt`, `interfaces.no-default.json` | synthetic: `en0` up with its on-link row and **no default row at all** — the state the vendored script's own teardown leaves behind |
| `netstat-rn-inet.dual-default.txt` | synthetic: `en0` and `en8` each with an **`-ifscope`-only** default (`UGScIg`) via its own on-link router — `en0 = 10.0.1.42/24` via `10.0.1.1`, `en8 = 192.168.1.42/24` via `192.168.1.1`, **`en0`'s row printed first** — plus each link's `link#N` on-link row, its `/32` self and router rows and its broadcast row, and two stale `/32` host routes via the dead gateway `100.64.9.9` so the sweep is non-empty and countable. Neither default serves unbound traffic, so clause (f) must install one, which is what makes the fixture a question about *which link* |
| `interfaces.dual-default.json`, `.reversed.json`, `.en0-absent.json`, `.en0-down.json` | **four snapshots against that one route table.** `dual-default` lists `en0` then `en8`, both up and addressed; `reversed` lists the *same two links* with `en8` first; `en0-absent` has `en8` only (the measured dual-homed transcript, where `en0`'s route rows persist after the link has left the snapshot); `en0-down` has both present and addressed with `en0` `"isUp": false` |
| `netstat-rn-inet.unspecified-default.txt`, `interfaces.unspecified-default.json` | synthetic: three default rows — `default 0.0.0.0 … UGSc en9`, `default link#7 … UGSc en7`, and `en8`'s healthy `-ifscope` default — against a snapshot holding `en8` **only**. `en9` and `en7` are absent on purpose: `unspecifiedGateway` (step 3) and `malformedGateway` (step 2) are both returned *before* `evaluateDefaultGateway`'s interface lookup, so a default row can name a link that does not exist |
| `netstat-rn-inet.late-tunnel.txt`, `interfaces.late-tunnel.json`, `scutil-keys.late-tunnel.txt` | synthetic: **three live tunnels** — `utun0`, `utun7`, `utun9` — each with a default row and an IPv4+DNS configd key pair, beside a live `en0 = 10.0.1.22/24` and one UUID-named physical service key. `utun7`'s default is the **unscoped** one and it carries `192.168.204.16`, so it is the one an attribution record can witness; the other two are scoped. The discrimination fixture for the tunnel scope: with `utun7` witnessed, nothing in the plan may name `utun9` |
| `netstat-rn-inet.live-shape.txt`, `interfaces.live-shape.json` | the **verified live shape** of the developer's machine while connected: an unscoped tunnel default on `utun7` beside a scoped `en0` default, plus `en0`'s on-link rows. The shape in which clause (f) would otherwise emit an install that can only return `EEXIST` |
| `netstat-rn-inet.live-shape.stale-en8.txt`, `interfaces.live-shape.stale-en8.json` | the same plus a **stale physical default on `en8`** via the dead gateway `100.64.9.9`, with `en8 = 192.168.50.10/24` present, up and addressed in its own snapshot. `en8` has to be usable or its row would be *kept* for a missing target rather than classified stale, and then clause (g) would have nothing to withhold — which is the composition this fixture exists to assert. Paired with its own snapshot rather than with `live-shape`'s for exactly that reason |
| `interfaces.lo0-only.json` | `lo0` and nothing else: the **unusable snapshot**, which (d″) aborts on and the tunnel scope answers `none` for. Used with `carried-home`'s route table; mirrored on the shell arm by `STUB_SNAPSHOT=lo0-only` |
| `attribution.{witnessed,mismatch,pending,bad-schema}.json` | the four states of `/var/run/anyway-connect.tunnels.json`, for the shell arm's reader (`test/test-onlink-guard.sh` points `ATTRIBUTION` at them). `witnessed` names `utun7` with `ourTunnelIPv4: 192.168.204.16`, which is the address the `guard` ifconfig stub already prints for `utun7` — that is why no stub changed; `mismatch` is the same name with `10.8.0.3`; `pending` has `ourTunnel: null`, the observer's starting state; `bad-schema` is `schema: 2`. A fifth case, a path that does not exist, is asserted without a file |

#### Why four snapshots share one route table

The install target has to come from the interface snapshot, not from `netstat`
print order, and the only way to make that a falsifiable claim is to hold the
route table fixed. `dual-default` and `dual-default.reversed` describe the
**same two links** in the opposite order against a **byte-identical** table, and
the harness expects `en0` for the first and `en8` for the second. A planner
reading print order answers `en0` for both and fails the second — an assertion
that cannot be written against print order at all, because print order is a
statement about a text format rather than about the links.

`en0-absent` and `en0-down` are the two shapes of the same trap: a default row
whose netif the reconcile has itself just recorded as unusable
(`why: "target not addressed"` and `why: "link down"` respectively).

#### The `0.0.0.0` gateway row is synthetic

Real `netstat -rn` prints `link#N` for a route with no next hop, never a literal
`0.0.0.0`. The row is committed deliberately anyway, because the two readings
reach `evaluateDefaultGateway` by different steps and both have to be exercised:
`IPv4("0.0.0.0")` parses and is `isUnspecified`, so it is **step 3**
(`unspecifiedGateway`), while `IPv4("link#7")` is `nil`, so that row is **step 2**
(`malformedGateway`). Both readings were confirmed against `parseRouteTable`,
which stores the gateway column verbatim as `gatewayText` beside
`IPv4(gatewayText)`. The `link#7` row is the realistic form; the `0.0.0.0` row is
the only way to drive step 3 from a fixture.

## The sweep count N, derived independently of the planner

Asserting a count the planner produced against the planner is a tautology, so N
is derived from the committed fixture by a separate reduction. On
`netstat-rn-inet.carried-home.txt` with `interfaces.carried-home.json`
(`en0 = 192.168.1.42/24`, no live tunnel):

```sh
awk '
  /^Destination/ { for (i = 1; i <= NF; i++) col[$i] = i; seen = 1; next }
  !seen { next }
  $(col["Gateway"]) !~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/ { next }   # link#N / MAC ⇒ on-link
  $(col["Destination"]) == "default" { next }                     # clause (b), not the sweep
  $(col["Netif"]) == "lo0" { next }                               # FR-2.6b
  $(col["Destination"]) ~ /^(127|169\.254|22[4-9]|23[0-9]|255\.255\.255\.255)[\.\/]/ { next }
  $(col["Destination"]) ~ /^(127|169\.254)$/ { next }
  $(col["Gateway"]) ~ /^192\.168\.1\.[0-9]+$/ { next }            # in en0's subnet
  { dst[$(col["Destination"])] = 1 }
  END { n = 0; for (d in dst) n++; print "N =", n }
' test/fixtures/netstat-rn-inet.carried-home.txt
```

Note that the gateway rule above is "in en0's subnet", not "a usable next hop":
that IS the planner's rule (FR-2.6c keeps a route whose gateway is on-link for a
live interface, whether or not the guard would install it), which is why the
three `192.168.1.{42,0,255}`-gateway rows below are skipped here too.

**N = 118** (117 before the four rows described above were added), and every swept
destination appears on exactly one `netif`, so the expected action list is exactly
**2N = 236** entries: one unscoped deletion plus
one `-ifscope` deletion per distinct `netif` per destination. (`route delete -net
X` removes only the unscoped entry; the interface-scoped duplicate survives it
and still wins, which is why both are emitted.)

That every swept destination has a single `netif` is itself checked rather than
assumed — the three destinations that appear on two interfaces (`default`,
`224.0.0/4`, `255.255.255.255/32`) are all outside the sweep:

```sh
awk 'NR>4 { nif[$1] = nif[$1] " " $4 }
     END { for (k in nif) { n = split(nif[k], a, " "); u = "";
             for (i = 1; i <= n; i++) if (index(u, a[i]) == 0) u = u " " a[i];
             if (split(u, b, " ") > 1) print "multi-netif:", k, u } }' \
    test/fixtures/netstat-rn-inet.carried-home.txt
```

The harness asserts the full ordered action list, not just its length, so a
regression in either direction fails.

**The generator is no longer a throwaway script.** It is committed at
`test/harness/derive-expected.sh`, which re-implements the classification, the
canonicalisation and the first-seen ordering from the fixture text and the
paired `interfaces.*.json` — reading no Swift source and calling no planner —
and its output is committed under `test/harness/expected/`.
`test/run-swift-harness.sh` re-derives and diffs every one of those files
**before** compiling, and the harness then asserts them against the planner
element for element. So a planner change that moves a list fails the harness, a
hand-edited expected file fails the diff, and a derivation that drifts fails
both. The script's `--kept` mode prints the other side of the same
classification — one line per row the sweep declines to delete, with the reason
— so the `kept` multiset is asserted rather than counted.

Running the unfiltered multi-netif `awk` above prints the three destinations
listed there, exactly as documented, because they are outside the sweep. The
runner therefore applies the sweep's own destination filters before the check,
which is the form in which "every swept destination is on exactly one netif" is
a true statement; it also cross-checks the derived list directly, since 118
unscoped deletions beside 118 scoped ones is the same property stated as a count.

### The other fixtures' derived counts

Each is produced by `sh test/harness/derive-expected.sh <name>` and committed:

| Fixture | Snapshot | Swept destinations | Deletions | Clause-(c) kept rows |
|---|---|---|---|---|
| `carried-home` | `carried-home` | 118 | 236 | 21 |
| `vpn-up` | `vpn-up` | 0 | 0 | 138 |
| `lingering-utun` | `lingering-utun` | 2 | 4 | 10 |
| `clean` | `clean` | 0 | 0 | 8 |
| `link-down` | `link-down` | 0 | 0 | 7 |
| `no-default` | `no-default` | 0 | 0 | 7 |
| `two-physical` | `two-physical` | 0 | 0 | 9 |
| `two-tunnels` | `two-tunnels` | 0 | 0 | 8 |
| `cap-exceeded` | `clean` | 300 (over the 256 cap) | 0 | 1 |
| `dual-default` | `dual-default` | 2 | 4 | 13 |
| `unspecified-default` | `unspecified-default` | 0 | 0 | 8 |
| `late-tunnel` | `late-tunnel` | 0 | 0 | 11 |
| `live-shape` | `live-shape` | 0 | 0 | 9 |
| `live-shape.stale-en8` | `live-shape.stale-en8` | 0 | 0 | 11 |

The last three sweep **nothing** by construction, and that is what makes them
usable as scope fixtures: every non-default row in them has a `link#N` gateway or
is loopback, so the sweep cannot contribute an action and the full ordered action
list the harness asserts is entirely clauses (a), (b) and (f). What they are
*about* is therefore a non-sweep assertion, and the enumeration below is the hand
derivation design.md §7.2 point 4 asks for — every default row, every configd
key, and which scope admits each.

**`late-tunnel`**, three default rows and eight configd keys (six of them a
tunnel's):

| Row or key | `.deadPlus(utun7)` | `.deadOnly` |
|---|---|---|
| `default 192.168.204.16 UGScg utun7` (unscoped) | deleted, unscoped form | kept — live and witnessed by nothing |
| `default 100.90.0.1 UGScIg utun0` | kept, `utun0` is live | kept |
| `default 100.91.0.1 UGScIg utun9` | kept, `utun9` is live | kept |
| `State:/Network/Service/utun7/{IPv4,DNS}` | removed | kept |
| `State:/Network/Service/utun0/{IPv4,DNS}` | kept | kept |
| `State:/Network/Service/utun9/{IPv4,DNS}` | kept | kept |
| `State:/Network/Service/1111…5555/{IPv4,DNS}` | never matched — the anchored pattern admits `utun` + digits only | as before |
| clause (f) | installs `en0`: the unscoped slot was freed by `utun7`'s deletion, and `en0` is the only usable physical link | **withheld**, `utun7`'s unscoped default survives |

**`live-shape`**, two default rows and no keys: `utun7`'s unscoped default is
kept under `.deadOnly` (live, unwitnessed), `en0`'s scoped default is accepted
but scoped-only so it is never deleted and never counts as a usable default, and
clause (f) is therefore **withheld** rather than emitted. There is no stale
physical default in the table, so clause (g) does not fire and records nothing.

**`live-shape.stale-en8`** adds `default 100.64.9.9 UGScIg en8`, which the guard
rejects as `gatewayOffLink` — `100.64.9.9` is outside both `10.0.1.0/24` and
`192.168.50.0/24` — so clause (b) classifies it stale and emits its deletion.
Clause (f) is withheld as above, and clause (g) then withholds that deletion
too, because its replacement is not being installed. Net effect: no action at
all, and two kept records saying why.

`dual-default`'s counts are **identical under all four of its snapshots** — both
stale host routes go via `100.64.9.9`, which is off-link for every link in every
one of them — so the four harness cases share one pair of expected files. That
identity is derived rather than assumed: `test/run-swift-harness.sh` re-derives
the list against `reversed`, `en0-absent` and `en0-down` as well and diffs all
three against the committed `dual-default` files.

`vpn-up` sweeping **nothing** is the discrimination test for the whole
classifier, not a vacuous case: it is the same table as `carried-home` seen from
the office LAN, where every gateway in it is reachable — `10.0.1.1` is on-link
for `en0`, `10.0.1.22` is `en0`'s own address, and `192.168.204.16` is held by a
live `utun7`. If the sweep ever produces an entry there, it is deleting a route
that works. `cap-exceeded` lists 300 because the cap bounds **distinct swept
destinations**; exceeding it aborts the sweep, so the expected deletion list is
empty rather than truncated.
