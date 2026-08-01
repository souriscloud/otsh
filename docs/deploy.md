# Deployment and abuse mitigation

This page is about the things that run *in front of* an `otsh` process, and
why they have to. The working configuration lives in `deploy/` — a
[systemd unit](../deploy/otsh.service), a fail2ban
[filter](../deploy/fail2ban/filter.d/otsh.conf) and
[jail](../deploy/fail2ban/jail.d/otsh.local), and an
[nftables ruleset](../deploy/nftables-ratelimit.conf) with pf equivalents —
and each section below says what that layer stops and what it does not.

Its job is to make an operator's decisions easy, not to promise safety. The
closing section says plainly what none of this covers.

## The blind spot this page exists for

`ssh/limits.odin` gives every server five limits — the first four applied
before any crypto work happens, and a write-stall cap (added in 0.2.0) that
bounds an established session whose client has stopped reading:

<!-- check:verbatim ssh/limits.odin -->
```odin
DEFAULT_LIMITS :: Limits {
	max_sessions        = 256,
	max_per_ip          = 8,
	handshake_seconds   = 20,
	max_auth_attempts   = 6,
	// Generous: a real client on a bad link recovers in well under this, and an
	// app that draws at 30fps notices the window shut within one frame.
	write_stall_seconds = 30,
}
```

They are effective at what they cover, and [`./security.md`](./security.md)
§7 records the measurement: with `max_per_ip = 3`, twelve simultaneous
connections from one address admitted exactly three. But the same section is
equally clear about the boundary:

> `Limiter` tracks state per-process, keyed by the numeric source address it
> sees. It has no view across processes or machines, so it cannot stop a
> distributed flood — many source addresses each safely under `max_per_ip`
> can still collectively exceed what the host can serve. That has to be
> handled in front of `otsh` (a load balancer, a firewall, a rate limiter
> that sees the whole picture), not inside it.

The arithmetic is worth doing once. `max_per_ip = 8` and `max_sessions = 256`
means thirty-two source addresses, each perfectly well-behaved by the
per-address rule, fill the process. Every connection after that is refused —
including your users'. Nothing inside the process can distinguish those
thirty-two addresses from thirty-two real people, because from inside the
process, that is exactly what they look like.

No amount of code added to `ssh/limits.odin` fixes this. A per-process
limiter cannot see what it cannot see. The mitigation is layers that run
earlier, cheaper, or with a wider view, and that is what the rest of this page
is.

## The layers

| Layer | Where it runs | What it sees | What it stops | Cost per rejected connection |
| --- | --- | --- | --- | --- |
| [nftables / pf](#layer-1-kernel-rate-limiting) | Kernel, before `accept()` | Packet headers, connection tracking | Connection floods from few sources; caps the aggregate arrival rate | A few instructions. No thread, no socket, no `Session` |
| [fail2ban](#layer-2-fail2ban-on-the-audit-log) | Userspace, after the fact | This process's audit log | Repeat offenders, across connections and over time | Nothing at rejection time — the ban is a firewall rule |
| [`ssh.Limits`](#layer-3-the-built-in-limits) | Inside the process, before key exchange | This process's live connections | Thread exhaustion, silent clients, one host hogging slots | One thread and one `Session` (~800 B), briefly |
| [Your app](#layer-4-the-application) | Inside your handler | Everything about an authenticated user | Protocol-legal abuse: spam, scraping, a user filling shared state | A full session |

Read top to bottom: each layer catches what the one above it let through, at a
higher price. Nothing here is redundant with anything else, and skipping the
top layer does not make the lower ones work harder — it makes them fail
earlier.

## Layer 1: kernel rate limiting

[`../deploy/nftables-ratelimit.conf`](../deploy/nftables-ratelimit.conf) is a
standalone nftables table. It passes `nft -c`, and — as of 2026-08-01 — it has
also run against live traffic: on nftables 1.1.3 in a `NET_ADMIN` container, a
second container drove each rule until its counter moved (the measurements are
in [What was verified](#what-was-verified-and-where)). Load it, then watch its
counters:

```sh
nft -c -f deploy/nftables-ratelimit.conf   # syntax check, changes nothing
nft -f deploy/nftables-ratelimit.conf      # load
nft list table inet otsh                   # inspect, with counters
```

It sits at hook priority `-10`, ahead of a conventional filter table, with
`policy accept` — it only ever removes traffic, it is not your firewall. Four
rules apply to new inbound connections on the otsh port:

1. **Banned sources.** Two sets with a one-hour timeout, `banned4` and
   `banned6`, for bans you decide on: `nft add element inet otsh banned4 {
   203.0.113.9 }`. fail2ban keeps its bans in its own table, so the two do not
   interfere.
2. **Per-source connection rate** — 10 new connections a minute, burst 5.
   Absorbs an honest client's reconnect storm; stops a single host from
   cycling connections.
3. **Per-source concurrent connections** — 8, deliberately the same number as
   `max_per_ip`, so the kernel refuses roughly what `otsh` would have refused,
   without spending a thread and a `Session` to do it. This one `reject`s
   rather than `drop`s: it fires against real users who opened one window too
   many, and a refusal they see beats a hang.
4. **Aggregate ceiling** — 100 new connections a minute across all sources,
   burst 50.

Rule 4 is the only one a distributed flood trips, and it is indiscriminate by
nature: past that rate, new connections are dropped without regard for who
sent them, real users included. That is the trade. A server that refuses some
new connections beats one that has run out of threads, and refusing them for
the cost of a packet-header match beats refusing them for the cost of a
thread. Size it above your real peak — 100/minute suits a small service and is
far too tight for a busy one.

The dynamic sets that hold the per-source counters are capped at 65535
entries. That cap is deliberate: a spray of distinct source addresses is
exactly the traffic that makes the kernel allocate set entries, so the memory
it can spend is bounded rather than left to the attacker.

**BSD and macOS.** The equivalent pf rules are in a clearly labelled comment
block at the bottom of the same file — `max-src-conn`, `max-src-conn-rate`,
and `overload <otsh_banned> flush global`. One difference matters
operationally: pf table entries have no per-entry timeout, so a pf ban is
permanent until something expires it. Age the table from cron (`pfctl -t
otsh_banned -T expire 3600`) or you will eventually lock a customer out for a
month. On macOS, pf is off by default and system updates reset the ruleset;
treat it as a development target.

## Layer 2: fail2ban on the audit log

fail2ban reads the audit log, counts failures per source address, and installs
a firewall ban when a source crosses a threshold. It is the only layer with
memory: it catches the address that fails slowly, over hours, under every
rate limit.

### Prerequisite: turn the audit log on

`Config.audit` is `nil` by default and a nil sink records nothing — a
deliberate privacy decision, documented in [`./ssh.md`](./ssh.md#audit).
**With it unset there is no log, and fail2ban has nothing to read.**
`examples/tracker` ships without it, so a stock tracker is not protected by
this layer. In your own app:

<!-- check:skip config sketch; create/destroy are the app's own procs, defined elsewhere on this page's terms -->
```odin
import "otsh:ssh"
import "otsh:sshtui"

cfg := sshtui.Config {
    port            = 2222,
    host_key_path   = "tracker_hostkey",
    identity_secret = "tracker_secret",
    methods         = {.Publickey},
    audit           = ssh.audit_stderr, // one parseable line per event
    create          = create,
    destroy         = destroy,
}
```

`audit_stderr` writes to stderr; the systemd unit sends stderr to the journal;
the jail reads the journal. No log file, nothing to rotate.

### The files

| File | Install as |
| --- | --- |
| [`../deploy/fail2ban/filter.d/otsh.conf`](../deploy/fail2ban/filter.d/otsh.conf) | `/etc/fail2ban/filter.d/otsh.conf` |
| [`../deploy/fail2ban/jail.d/otsh.local`](../deploy/fail2ban/jail.d/otsh.local) | `/etc/fail2ban/jail.d/otsh.local` |

```sh
install -D -m 0644 deploy/fail2ban/filter.d/otsh.conf /etc/fail2ban/filter.d/otsh.conf
install -D -m 0644 deploy/fail2ban/jail.d/otsh.local  /etc/fail2ban/jail.d/otsh.local
fail2ban-client reload
fail2ban-client status otsh
```

A `.local` file in `jail.d/` is the supported way to add a jail without
editing `jail.conf`, which your package manager owns and will overwrite.

### The ban action must match your firewall

The jail sets `banaction = nftables-multiport` explicitly rather than inheriting
it, and that is not cosmetic. fail2ban 1.1.0's `jail.conf` defaults to
`iptables-multiport`, and on an nftables-only host with no `iptables` binary —
a minimal Debian 13 is exactly that — the inherited default **fails open**:
`fail2ban-client status otsh` reports the address as banned while every
`actionban` invocation dies with `iptables: not found` in `fail2ban.log`, and
the "banned" client connects and authenticates as though nothing happened.
Measured on 2026-08-01; it is the difference between a ban and a log line that
says the word *ban*. Since layer 1 already requires nftables, the nftables
action is the right dependency; if your firewall really is legacy iptables, set
`iptables-multiport` here instead — and whichever you choose, prove it once by
banning yourself from a non-loopback address and watching the connection
actually die.

### What the filter matches

Three events, all three of which carry `addr` by contract:

| Matched | Why it is a failure |
| --- | --- |
| `event=auth ... ok=false` | One refused authentication attempt — including a method the server does not offer, and an attempt past `max_auth_attempts` |
| `event=reject` | `Limits` refused the connection before any crypto: `max_sessions` or `max_per_ip` was full |
| `event=kex_fail` | Key exchange failed. There is no client identity yet, so the address is all there is |

Not matched: `listen`, `accept`, `session_start`, `session_end`, and `auth`
with `ok=true`. An accept is not a failure, and banning on it bans everyone.

The regexes are anchored against the exact field order of the line format
contract, so `<HOST>` lands on the `addr=` value and nowhere else. That
guarantee rests on the scrubbing rule in `ssh/audit.odin`: every byte of a
client-supplied value outside `[A-Za-z0-9.:_@/+,%-]` becomes `?`, so a
username cannot contain a space or an `=`, so it cannot introduce a second
`addr=` field and shift the extracted address. The scrub is load-bearing for
this filter, and the test below asserts it.

### The one number to get right

An OpenSSH client always tries the `none` method first. A publickey-only
server — `methods = {.Publickey}`, as in `examples/tracker` — therefore logs
**one `event=auth ... method=none ... ok=false` line per honest connection**.
It is right there in the real capture in [`./ssh.md`](./ssh.md#audit).

With the shipped jail (`maxretry = 6`, `findtime = 10m`), that means six
reconnects in ten minutes earns a one-hour ban. A user debugging their setup,
or on a flaky mobile link, will hit that. A client with four keys in its agent
also spends one line per key tried before the accepted one.

So pick one, on purpose:

- **Raise `maxretry`** to 12–20 if your users reconnect often. Simple, and
  keeps visibility of clients hammering a method you do not offer.
- **Use the `alt-failregex`** in the filter, which ignores `method=none`. Then
  a failure means a key or password that was actually refused — at the cost of
  no longer seeing the "wrong method" case that
  [`./ssh.md`](./ssh.md#audit) calls out as exactly what a log filter needs to
  see.

Enabling `bantime.increment = true` globally is usually better than raising
`bantime` here: a first mistake stays at an hour, a returning offender
escalates.

### Verifying the filter

fail2ban ships `fail2ban-regex`, and where fail2ban is installed that is the
authority:

```sh
fail2ban-regex /var/log/otsh.log /etc/fail2ban/filter.d/otsh.conf
```

Where it is not, [`../deploy/fail2ban/test_filter.py`](../deploy/fail2ban/test_filter.py)
runs the filter against the documented capture with nothing but the Python
standard library:

```sh
python3 deploy/fail2ban/test_filter.py
```

It loads the filter with the same interpolation rules fail2ban uses (so an
unescaped `%` fails there rather than at reload), translates `<HOST>`, and
asserts that every line of the real capture in
[`./ssh.md`](./ssh.md#audit) gets the verdict it should — the `ok=false` line
matches, the `listen`/`accept`/`ok=true`/`session_start`/`session_end` lines do
not — that the constructed `reject` and `kex_fail` lines match, and that a
username doing its best to look like an address (`user=addr?1.2.3.4`) cannot
shift the extracted host. It is not wired into `check.sh`; it is documentation
you can execute.

The filter has also been run through a **real `fail2ban-regex` 1.1.0**: on a
13-line corpus (the capture plus IPv6, journal- and syslog-prefixed, and
forged-field variants) it matches exactly the 7 failure lines, misses the 6
benign ones, and extracts the `addr=` value every time. That run is also how
the filter's one non-obvious construction was found: fail2ban excises the
matched timestamp text from the line before `failregex` runs, so the regexes
match a timestamp *slot* (`ts=\S*\s+`), never the timestamp itself — a filter
that spells out the `ts=` value matches nothing, silently.

The `MESSAGE` shape a live journald hands the systemd backend — the one thing
the file-corpus tests above could not reach — is now measured. On Debian 13
(systemd 257, fail2ban 1.1.0), journald stores the `MESSAGE` field as the
**bare** audit line, `otsh: audit ts=… event=… addr=…`, byte-for-byte what the
process wrote to stderr, with no syslog prefix embedded. fail2ban's systemd
backend then reconstructs the line its `failregex` sees from *separate* journal
fields, as `<_HOSTNAME> otsh[<_PID>]: <MESSAGE>` — e.g.

```
sut otsh[379]: otsh: audit ts=2026-08-01T19:05:19Z event=auth addr=10.77.0.20 method=none user=mallory ok=false
```

so the filter's leading `^(?:.*?\s)?otsh: audit` is what absorbs that
prefix, and the `ts=…` value survives intact (the journal carries its own
timestamp, so nothing is excised from the message). With
`journalmatch = _SYSTEMD_UNIT=otsh.service` this matched real failures and
issued real bans; see [What was verified](#what-was-verified-and-where).

Still unverified: IPv6 `addr=` lines against a *live* journal (the container
test network was IPv4-only — the regex handles v6, the end-to-end journal path
for v6 was not exercised), and fail2ban 0.9, whose `<HOST>` cannot match IPv6
at all — on 0.9 an IPv6 audit line matches nothing, silently. Check
`fail2ban-client version` before assuming your v6 listener is covered.

## Layer 3: the built-in `Limits`

Covered in full in [`./security.md`](./security.md) §7. For deployment, three
things matter:

- **Size them rather than inheriting them.** The structs themselves are noise:
  `max_sessions = 256` is about 200 KB of `Session` at full occupancy (~800 B
  each). What the number really buys is one OS thread per connection, and the
  memory that follows a thread around — its resident stack, libssh's
  per-connection state, and your app's `Model`. Only the libssh side has a
  worst case worth naming: a connection being flooded parks up to the ~2 MiB
  transport window in libssh's channel buffer (see
  [`./architecture.md`](./architecture.md), "Input flow and backpressure"), and
  an idle one costs nothing there. The `MemoryMax`/`TasksMax` in the unit below
  are sized against `max_sessions`. Raising one without the others gets you an
  OOM kill instead of a refused connection.
- **`0` means default, negative means unlimited.** `Limits{}` is the hardened
  default, not an accidental free-for-all — but a stray `-1` is a real
  free-for-all.
- **`max_auth_attempts` does not bound guessing across connections.** The
  counter lives on the `Session`, so a client that reconnects gets a fresh
  budget — measured at roughly 37 guesses/second from one address. Layers 1
  and 2 are what bound that, not this.

## Layer 4: the application

Some abuse is protocol-legal: a user who authenticates cleanly and then fills
your shared state with garbage has done nothing any of the layers above can
see. Only the app can. `examples/tracker` caps its board length for exactly
this reason. If your app has shared state, decide what one connection is
allowed to do to it, and use `Info.id` — never `Info.user`, which is
attacker-chosen text — as the key you rate-limit on.

## Walkthrough: the tracker under systemd

[`../deploy/otsh.service`](../deploy/otsh.service) is a hardened unit for the
tracker. Every hardening directive in it carries a one-line comment saying
what it protects against, so the file doubles as documentation; the lines
marked `APP-SPECIFIC` are the ones you change for your own binary.

**1. Build and install the binary.**

```sh
./build.sh examples/tracker                              # -> ./tracker
sudo install -D -m 0755 ./tracker /usr/local/lib/otsh/tracker
```

**2. Install the unit.**

```sh
sudo install -D -m 0644 deploy/otsh.service /etc/systemd/system/otsh.service
sudo systemctl daemon-reload
```

**3. Understand where the secrets land.** This is the part that bites.
`ssh.serve` resolves `Config.host_key_path` and `Config.identity_secret`
against the process working directory, and the tracker sets them to the
relative names `"tracker_hostkey"` and `"tracker_secret"`. The unit therefore
pairs:

```ini
DynamicUser=yes
StateDirectory=otsh
WorkingDirectory=%S/otsh
```

`StateDirectory=otsh` gives the service `/var/lib/otsh` (really
`/var/lib/private/otsh`, mode 0700, chowned to the transient UID on every
start), and `WorkingDirectory=%S/otsh` points the process at it. Both files
are created there on first start, 0600, by `otsh` itself. If you would rather
not depend on the working directory, put absolute paths in your `Config`
instead — but then `ProtectSystem=strict` means they must still be under the
state directory, which is the only writable place the service has.

**4. Start it, and check the first-run output.**

```sh
sudo systemctl enable --now otsh.service
journalctl -u otsh -n 20
```

The first start prints `otsh: generated new ed25519 host key at
tracker_hostkey` and `otsh: generated new identity secret at tracker_secret
(back this up)`. Back both up now: the host key is what clients pin in
`known_hosts` (regenerate it and every returning user sees a mismatch
warning), and the identity secret is the HMAC key behind every user's `id`
(lose it and every returning user looks new). Root can read them at
`/var/lib/private/otsh/`.

Publish the host key fingerprint out of band before advertising the address:

```sh
sudo ssh-keygen -lf /var/lib/private/otsh/tracker_hostkey
```

**5. Size the ceilings.** `TasksMax=300` covers 256 session threads plus the
accept loop plus main. `MemoryMax=512M` is a backstop that turns a leak into a
restart, not a measured working set — measure yours (`systemctl show otsh -p
MemoryPeak`, or `systemd-cgtop`) and set it near the real peak. Both move
together with `Limits.max_sessions`.

**6. Add the other layers.**

```sh
sudo nft -f deploy/nftables-ratelimit.conf
sudo install -D -m 0644 deploy/fail2ban/filter.d/otsh.conf /etc/fail2ban/filter.d/otsh.conf
sudo install -D -m 0644 deploy/fail2ban/jail.d/otsh.local  /etc/fail2ban/jail.d/otsh.local
sudo fail2ban-client reload
```

Remember that the fail2ban layer does nothing until your app sets
`Config.audit` — the stock tracker does not.

### Checking it works

The unit lints clean — `systemd-analyze verify` under systemd 257 reports
nothing once the binary exists (and that check is how a silently ignored
`StartLimitIntervalSec` in the wrong section was caught). As of 2026-08-01 it
has also *supervised* one: a container running the same unit started the
service, restarted it under a live client with the terminal restored, stopped
it cleanly at exit 0, and scored `systemd-analyze security` at 1.3 — see
[What was verified](#what-was-verified-and-where), including the one syscall the
filter had to add back before any session could start. These are the commands
that tell you how yours is doing:

```sh
systemctl status otsh                      # running, and under which limits
journalctl -u otsh -f                      # audit lines, live
systemd-analyze security otsh.service      # scores the hardening above
nft list table inet otsh                   # per-rule counters
fail2ban-client status otsh                # currently banned addresses
```

`systemd-analyze security` is worth running once after any edit to the unit: it
will tell you which directive you dropped.

## What was verified, and where

Every claim on this page above the line "has not run" once rested on a linter.
On **2026-08-01** the whole stack was stood up in Docker and driven with real
traffic. The bench: Debian 13 (trixie), systemd 257 (257.13), fail2ban 1.1.0,
nftables 1.1.3, libssh 0.11.2, Odin `dev-2026-07a`, on an `aarch64` host — a
system-manager container (`--privileged`, no host cgroup mount) as the server,
a second `NET_ADMIN` container on a user-defined bridge as the client, so every
source address was a real non-loopback peer rather than `127.0.0.1`. The
reproduction lives under `deploy/verify/`: a
[`Dockerfile`](../deploy/verify/Dockerfile) that builds the audited app and
installs the shipped configs verbatim, and a tiny tracker-shaped app at
`deploy/verify/app/main.odin` that differs from `examples/tracker` only by
setting `Config.audit` (so there is something for fail2ban to read) and
refusing user `mallory` (so auth failures can be generated on demand).

| Layer | Proved, with evidence | Command that showed it |
| --- | --- | --- |
| **systemd** | Service `active (running)`; host key + identity secret land 0600 at `/var/lib/private/otsh/` owned by the transient UID; `DynamicUser` gives UID 65057, no account left behind | `systemctl status`, `ls -l /var/lib/private/otsh` |
| **systemd restart** | Graceful: `systemctl restart` took 0.19 s with a client attached, and the client's byte stream ended in `ESC[?1049l` (leave alt-screen) + `ESC[?25h` (show cursor) — the terminal was restored, not cut off | pty recording of an `ssh` session across a restart |
| **systemd stop** | Clean: `systemctl stop` returned in 0.06 s with `Result=success`, `ExecMainStatus=0` — exited on its own, not SIGKILLed at `TimeoutStopSec` | `systemctl show -p Result,ExecMainStatus` |
| **security score** | `systemd-analyze security otsh.service` → **1.3 OK**. Worst offenders are all inherent to a public network service: `PrivateNetwork=` (0.5), `RestrictAddressFamilies=~AF_INET*` (0.3), `IPAddressDeny=`/`PrivateUsers=`/`SystemCallFilter=~@resources` (0.2 each). The `@resources` line is the one this exercise added on purpose (below) | `systemd-analyze security otsh.service` |
| **audit → journald** | Audit lines reach the journal under `SyslogIdentifier=otsh`; `MESSAGE` is stored as the **bare** `otsh: audit …` line, identical to stderr | `journalctl -u otsh -o json` |
| **fail2ban filter** | Reading the live journal via `journalmatch = _SYSTEMD_UNIT=otsh.service`, it matched all three failure events — `auth ok=false`, `reject limit=per_ip`, `kex_fail` — generated by a real `ssh`/`nc` client | `fail2ban-client status otsh` (Total failed climbed) |
| **fail2ban ban** | At `maxretry`, the offender was written into `inet f2b-table`'s `addr-set-otsh`, and the banned address was then **blocked** (connection refused with icmp port-unreachable), while a fresh source got through | `nft list table inet f2b-table`; `nc` from banned vs. fresh source |
| **nft per-source rate** | Rule 2 dropped 22 packets from one source doing 15 rapid connects; the aggregate counter stayed 0 — clean separation | `nft list chain inet otsh otsh_new` |
| **nft concurrent cap** | Rule 3 `reject`ed the 9th simultaneous connection from one source (counter +1); otsh logged exactly 8 `accept`/`session_start`, never a 9th | counters + `journalctl` accept count |
| **nft aggregate** | Rule 4 dropped 66 packets under 180 connections from 60 sources; a distributed spray no per-source rule catches | `nft list chain inet otsh otsh_new` |
| **nft banned set** | Operator `banned4` element dropped its source (counter +3); confirms the manual "banned tier" | `nft add element … banned4`, then `nc` |
| **nft policy accept** | An unrelated port (9999) and ICMP passed untouched, and an already-established otsh session survived a flood — the table only removes traffic on its one port | `nc`/`ping` to an off-rule target |
| **coexistence** | `inet otsh` (standing limits) and `inet f2b-table` (fail2ban's bans) were loaded at once, each dropping its own traffic, neither touching the other | `nft list tables` |

**The two defects this found, both in `deploy/`, both now fixed and re-tested:**

1. **The syscall filter denied the one call every session needs.**
   `SystemCallFilter=~@resources` includes `sched_setscheduler`, and Odin's
   `core:thread` creates each session thread with an explicit scheduling policy
   (`pthread_attr_setinheritsched(EXPLICIT_SCHED)`), so glibc's `pthread_create`
   calls `sched_setscheduler` in the new thread. Denied, that `EPERM` aborted
   thread creation and the server dropped **every** connection with "could not
   start a session thread" — it started cleanly and served nobody, which no
   linter can see. The unit now adds `SystemCallFilter=sched_setscheduler` back
   (the single most impactful line in this whole exercise). This is not a
   realtime hole: `RestrictRealtime=yes` still refuses `SCHED_FIFO`/`SCHED_RR`.
   It is also the sole reason the security score is 1.3 rather than lower.
2. **The ban action failed open.** Covered under
   [The ban action](#the-ban-action-must-match-your-firewall) above: the jail
   now pins `banaction = nftables-multiport` instead of inheriting the
   iptables default that no-ops on an nftables-only host.

**What a container test still cannot tell you.** A container is not a VM, and
these gaps are real:

- **`DynamicUser` and cgroup behaviour may differ.** The transient UID, the
  `StateDirectory` chown, `TasksMax`/`MemoryMax` accounting and `MemoryPeak` all
  reported sensibly here, but the container shares the host kernel and its
  cgroup hierarchy; a bare-metal or VM cgroup2 tree can enforce or account
  differently. The `systemd-modules-load` unit also fails in a container (no
  module loading) — harmless here, but it means the boot was `degraded`, not
  `running`, which you would not accept on a real host.
- **The security score is measured against a container's context.** Two of the
  offenders systemd names (`RootDirectory=`, the `char-rtc` device ACL) are
  artifacts of running under Docker, and `--privileged` weakens the very
  sandbox the unit builds. The number 1.3 is a floor, not the score a hardened
  VM would print.
- **IPv6 was not exercised end to end.** The test bridge was IPv4-only. The
  filter regex handles v6 addresses (the corpus in
  [`../deploy/fail2ban/test_filter.py`](../deploy/fail2ban/test_filter.py)
  covers them), but no v6 `addr=` line travelled a real journal into a real
  ban, and the fail2ban 0.9 `<HOST>`/IPv6 caveat above stands unmeasured.
- **Nothing here is a load or soak test.** "256 sessions flooded at once",
  the `MemoryMax` backstop, and `TimeoutStopSec` under a slow-draining app were
  reasoned about, not driven to their limits.

## What this still does not stop

Stated plainly, in the manner of [`./security.md`](./security.md) §9:

- **A true volumetric DDoS.** Every layer here runs on your host. Traffic that
  saturates the link, or that exhausts the kernel's connection tracking before
  a rule can match, is not something a host-local rule can help with — the
  packets have already used the resource that ran out. That needs filtering
  upstream of the machine: your provider's scrubbing, an anycast frontend, a
  load balancer that terminates connections elsewhere. If a distributed flood
  is genuinely in your threat model, that is the purchase; nothing in this
  repository substitutes for it.
- **A distributed flood is still a distributed flood.** Layers 1–3 are all
  per-source except the aggregate ceiling, and the aggregate ceiling protects
  the process by refusing everyone. Ten thousand addresses sending one
  connection each defeat every per-source rule on this page exactly as they
  defeat `otsh`'s own `Limits`. What you get is a server that stays up and
  serves whoever gets through first — not a server that keeps serving your
  users.
- **fail2ban is reactive by construction.** It bans after the failures have
  happened and been logged. Against a source that connects once and never
  returns, it does nothing at all, which is precisely the shape of a
  distributed attack.
- **A ban is invisible to the person banned.** They see a connection that
  hangs or resets, with no explanation, and nothing in `otsh` can tell them
  why. That is a real cost paid by real users every time a threshold is set
  too low.
- **None of this is authentication or authorization.** It bounds how much
  service an address can consume. What a *user* is allowed to do is
  [`./security.md`](./security.md)'s subject and your app's job.
- **The unit hardens the process, not the code.** `ProtectSystem=strict`,
  `MemoryDenyWriteExecute` and a syscall filter raise the cost of exploiting a
  bug in `otsh` or libssh. They do not remove one. Keeping libssh patched is
  still part of the security boundary.

## See also

- [`./security.md`](./security.md) — the threat model these layers sit inside;
  §7 for the limiter, §10 for the pre-exposure checklist.
- [`./ssh.md`](./ssh.md#audit) — the audit line format the fail2ban filter
  parses, as a contract.
- [`./architecture.md`](./architecture.md) — one thread per connection, and
  the `Session` size the memory ceilings are derived from.
