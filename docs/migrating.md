# Migrating between versions

One page per breaking change, oldest at the bottom. [CHANGELOG.md](../CHANGELOG.md)
carries the short version of each; this page is for the ones where the reason
matters, because knowing *why* something went is usually what tells you whether
your code was relying on it.

otsh is `0.MINOR.PATCH` before 1.0, so a **minor** bump may break your build and
a **patch** bump may not. If you are moving across more than one minor, read
every section between where you are and where you are going.

Nothing here is urgent for anyone yet. otsh has one tag and no known dependents,
so the removal below is written down to set the pattern rather than to rescue
anybody.

## 0.1.0 — the session input ring

**Removed:** `ssh.MAX_INPUT`, `ssh.Ring`, `ssh.ring_push`, `ssh.ring_pop`.

**What to do:** delete any use of them. Nothing replaces them. `ssh.read` was
always the supported way to get bytes out of a session and it is unchanged:

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
