# Migrating between versions

One page per breaking change, oldest at the bottom. [CHANGELOG.md](../CHANGELOG.md)
carries the short version of each; this page is for the ones where the reason
matters, because knowing *why* something went is usually what tells you whether
your code was relying on it.

otsh is `0.MINOR.PATCH` before 1.0, so a **minor** bump may break your build and
a **patch** bump may not. If you are moving across more than one minor, read
every section between where you are and where you are going.

How to actually perform an upgrade — pinning to a tag, asserting a minimum
version, and what a rebuild does and does not catch — is in
[getting-started.md](./getting-started.md#pinning-and-upgrading-otsh). This page
is only the per-change detail.

## 0.3.0 — the default bind address

**Changed:** `ssh.DEFAULT_HOST` from `"0.0.0.0"` to `"::"`. **Added:**
`ssh.DEFAULT_HOST_IPV4`.

**Does your code break?** No. Nothing fails to compile, and nothing about your
app changes. This one is here precisely because a compiler cannot warn you
about it.

**What actually changed:** a server that never sets `Config.host` used to bind
the IPv4 wildcard and answer IPv4 clients only. It now binds the IPv6 wildcard,
which on a dual-stack kernel serves both families from one socket. Where a
dual-stack socket is not available — no `AF_INET6` at all, or a kernel that
made the socket IPv6-only, as `net.ipv6.bindv6only=1` does — `serve` rebinds on
`DEFAULT_HOST_IPV4` and says so on stderr.

**What to check before you upgrade a deployed server:** anything in front of
the process that is written for IPv4. A firewall rule, an nftables set, a
fail2ban action, a rate limiter, an allow-list. Such a control does not
partially cover the IPv6 half — it does not cover it at all, and it does so
silently, because the traffic simply never reaches the rule. The artifacts in
`deploy/` are paired for both families already; anything you wrote yourself
probably is not.

**What to do:** either extend those controls to IPv6, or keep the old
behaviour deliberately:

<!-- check:decls -->
```odin
import "otsh:ssh"
import "otsh:sshtui"

old_ipv4_only :: proc() -> sshtui.Config {
	return sshtui.Config{host = ssh.DEFAULT_HOST_IPV4}
}
```

**What did not change:** the peer address an IPv4 client is reported as. A
dual-stack `getpeername` hands back the IPv4-mapped `::ffff:127.0.0.1`; otsh
converts it to the dotted quad before anything sees it, so `ssh.remote_addr`,
the audit log and the per-address limiter read `127.0.0.1` exactly as before,
and existing `addr=` log filters keep matching.

## 0.1.0 — the session input ring

**Removed:** `ssh.MAX_INPUT`, `ssh.Ring`, `ssh.ring_push`, `ssh.ring_pop`.

**What to do:** delete any use of them. Nothing replaces them. `ssh.read` was
always the supported way to get bytes out of a session and it is unchanged:

<!-- check:skip fragment referencing a Session `s` from surrounding prose, not a standalone declaration -->
```odin
buf: [256]u8
n, ok := ssh.read(s, buf[:], 33)   // ok == false means the connection is finished
```

If you sized a buffer with `MAX_INPUT`, pick your own number — `read` fills
whatever slice you hand it and returns how much it wrote. If you were driving a
`Ring` yourself, that ring no longer exists to drive.

### Why

Input used to take two paths. libssh called a registered
`channel_data_function` with each arriving packet; that callback copied bytes
into a fixed-size ring living inline in every `Session`, returning how many it
had taken, and `ssh.read` popped from the ring. The design rested on a belief
written into a comment next to `MAX_INPUT`: that libssh re-offers whatever the
callback declines.

It does not. The callback runs only from libssh's `channel_rcv_data` — that is,
when the *next* CHANNEL_DATA packet arrives. A paste is a burst followed by
silence, so whatever the ring declined sat in libssh's channel buffer with
nothing to release it, and the session was deaf for the rest of the connection
while it went on repainting perfectly. Measured: 1,048,577 bytes pasted, 549,951
stranded, the quit key still unseen after 60 seconds. One paste of a log file
did it.

Shrinking the ring had made this more likely, not less, and growing it would
only have raised the paste size that triggers it — the callback runs without an
Odin context and must never touch an allocator, so a growable buffer was never
on the table either.

The fix was to stop having a second buffer. No `channel_data_function` is
registered now; `ssh.read` is the only consumer, pulling from libssh's own
per-channel buffer with `ssh_channel_read_nonblocking` before it ever waits on
the socket. Backpressure comes from SSH itself: libssh widens the client's
transport window only as `read` consumes, which caps buffered input at about
2 MiB per session with no accounting of ours involved. Keeping both the callback
and such a drain is unsound — the drain's internal `ssh_handle_packets` can fire
the callback mid-drain and invalidate its space accounting, measured at 42,110
bytes silently lost — so it really is one path or the other.

The ring's removal took `Session` from 17,184 bytes to 792. At the default
`max_sessions` of 256 that is about 200 KB of sessions instead of 4.4 MB.

The full reasoning, with the reproduction recipe and the two dead ends that were
tried and reverted first, is in the input-path comment at the top of
`ssh/server.odin` and in [Architecture](architecture.md).
