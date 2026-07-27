// Adversarial tests for the code that touches attacker-controlled bytes.
//
// Everything a client sends reaches `tui.parse_input` before anything else
// looks at it, so it is the part of otsh most worth trying to break. These
// tests assert the invariants the caller (`tui.run`'s dispatch loop) depends
// on — chiefly that the parser always either consumes bytes or asks for more,
// and never claims to have consumed more than it was given.
package otsh_tests

import "core:math/rand"
import "core:testing"
import "otsh:ssh"
import "otsh:tui"

// The contract `dispatch_input` relies on. A violation here is a potential
// out-of-bounds slice or an infinite loop in the frame loop.
@(private = "file")
check_invariants :: proc(t: ^testing.T, buf: []u8, where_: string) {
	ev, n, ok := tui.parse_input(buf)

	testing.expectf(t, n >= 0, "%s: negative consume count %d", where_, n)
	testing.expectf(t, n <= len(buf),
		"%s: claimed %d bytes from a %d-byte buffer", where_, n, len(buf))
	if ok {
		testing.expectf(t, n > 0,
			"%s: reported success without consuming anything (would spin)", where_)
	} else {
		testing.expectf(t, ev == nil,
			"%s: returned an event while reporting incomplete", where_)
	}
}

@(test)
fuzz_random_bytes :: proc(t: ^testing.T) {
	rand.reset(0x0757) // fixed seed: a failure here must be reproducible
	buf: [64]u8
	for round in 0 ..< 20000 {
		n := int(rand.uint32() % 32) + 1
		for i in 0 ..< n {
			buf[i] = u8(rand.uint32())
		}
		check_invariants(t, buf[:n], "random")
	}
}

@(test)
fuzz_escape_sequences :: proc(t: ^testing.T) {
	// Random bytes rarely produce a valid CSI, so bias the generator towards
	// escape-sequence shapes: that is where the parser's real complexity is.
	rand.reset(0xC51)
	alphabet := []u8{0x1b, '[', 'O', '<', ';', '0', '1', '5', '9', '~', 'A', 'M', 'm', 'Z', 0xff}
	buf: [48]u8
	for round in 0 ..< 20000 {
		n := int(rand.uint32() % 16) + 1
		buf[0] = 0x1b
		for i in 1 ..< n {
			buf[i] = alphabet[rand.uint32() % u32(len(alphabet))]
		}
		check_invariants(t, buf[:n], "escape")
	}
}

@(test)
fuzz_truncated_prefixes :: proc(t: ^testing.T) {
	// Every prefix of a valid sequence must be handled: this is exactly what a
	// slow or fragmented connection delivers.
	valid := []string {
		"\x1b[1;5A", "\x1b[15~", "\x1bOP", "\x1b[<0;10;5M", "\x1b[<64;1;1m",
		"\x1b[200~", "é", "世", "🙂", "\x1b\x1b[A", "\x1b[Z",
	}
	for s in valid {
		bytes := transmute([]u8)s
		for cut in 1 ..= len(bytes) {
			check_invariants(t, bytes[:cut], s)
		}
	}
}

@(test)
fuzz_never_stalls_on_a_full_buffer :: proc(t: ^testing.T) {
	// dispatch_input drops one byte and retries when the parser reports
	// incomplete twice. What must never happen is a buffer that the parser
	// refuses forever while claiming success with n == 0 — that spins the loop.
	// Feed pathological inputs and require forward progress.
	cases := []string {
		"\x1b", "\x1b[", "\x1b[<", "\x1b[<0", "\x1b[<0;", "\x1b[<0;1",
		"\x1bO", "\x1b[1;", "\xc3", "\xe4\xb8", "\xf0\x9f\x99",
		"\x00", "\x1b[\x00", "\x1b[999999999999;1A",
	}
	for c in cases {
		bytes := transmute([]u8)c
		ev, n, ok := tui.parse_input(bytes)
		testing.expectf(t, n <= len(bytes), "%q: over-consumed", c)
		if ok {
			testing.expectf(t, n > 0, "%q: success with no progress", c)
		}
		_ = ev
	}
}

@(test)
fuzz_key_name_respects_small_buffers :: proc(t: ^testing.T) {
	// key_name writes into a caller-supplied buffer. Undersized buffers must
	// truncate, never overflow.
	rand.reset(0x4E)
	guard: [64]u8
	for round in 0 ..< 5000 {
		size := int(rand.uint32() % 12) // deliberately too small, sometimes 0
		for i in 0 ..< len(guard) {
			guard[i] = 0xAA
		}
		k := tui.Key {
			kind  = tui.Key_Kind(rand.uint32() % u32(len(tui.Key_Kind))),
			r     = rune(rand.uint32() % 0x10FFFF),
			ctrl  = rand.uint32() & 1 == 1,
			alt   = rand.uint32() & 1 == 1,
			shift = rand.uint32() & 1 == 1,
		}
		out := tui.key_name(k, guard[:size])
		testing.expectf(t, len(out) <= size, "wrote %d bytes into %d", len(out), size)
		// The bytes past the slice must be untouched.
		for i in size ..< len(guard) {
			testing.expectf(t, guard[i] == 0xAA, "key_name wrote past its buffer at %d", i)
		}
	}
}

// --- the ring buffer under adversarial sizes --------------------------------

@(test)
fuzz_ring_never_loses_or_invents_bytes :: proc(t: ^testing.T) {
	// The ring is fed straight from the network. Push/pop random amounts and
	// verify the byte stream comes back exactly, in order, forever.
	rand.reset(0x21A6)

	ring: ssh.Ring
	src := make([]u8, 4096)
	defer delete(src)
	dst := make([]u8, 4096)
	defer delete(dst)

	next_write, next_read: u8
	pending := 0

	for round in 0 ..< 4000 {
		if rand.uint32() & 1 == 0 {
			n := int(rand.uint32() % 4096) + 1
			for i in 0 ..< n {
				src[i] = next_write
				next_write += 1
			}
			took := ssh.ring_push(&ring, src[:n])
			testing.expectf(t, took <= n, "ring took more than offered")
			// Bytes it declined were not consumed, so rewind the generator.
			next_write -= u8(n - took)
			pending += took
		} else {
			n := int(rand.uint32() % 4096) + 1
			got := ssh.ring_pop(&ring, dst[:n])
			testing.expectf(t, got <= n, "ring returned more than asked")
			testing.expectf(t, got <= pending, "ring invented bytes")
			for i in 0 ..< got {
				testing.expectf(t, dst[i] == next_read,
					"ring reordered bytes at round %d", round)
				next_read += 1
			}
			pending -= got
		}
	}
}
