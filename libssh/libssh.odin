// Minimal Odin bindings for the libssh *server* API.
//
// Only the surface needed to run an SSH server that hands each connection a
// pseudo-terminal-shaped byte stream is bound here. See ../ssh for the
// higher-level wrapper.
package libssh

import "core:c"

when ODIN_OS != .Darwin &&
	ODIN_OS != .Linux &&
	ODIN_OS != .FreeBSD &&
	ODIN_OS != .Windows {
	#panic("libssh bindings support unix-likes and Windows")
}

// What the linker is told to link against, and the one knob static linking
// turns.
//
// The default names the *system* library: `system:ssh` becomes `-lssh`, which
// the linker resolves to libssh.so/.dylib wherever it finds it, and
// `system:ssh.lib` is the vcpkg import library on Windows — vcpkg is the
// expected provider there (`vcpkg install libssh:x64-windows`), and the linker
// still needs its directory, e.g.
// -extra-linker-flags:"/LIBPATH:C:\\vcpkg\\installed\\x64-windows\\lib".
// There is no rpath equivalent on Windows; ssh.dll has to be on %PATH% at run
// time. Exercised for real once: on 2026-07-31 these bindings linked against
// vcpkg libssh 0.12.0 on Windows 11 and served live openssh sessions. The
// hosted CI windows job has since run green. See docs/getting-started.md.
//
// Pointing this at a static archive instead is what makes a binary that runs
// on a machine with no libssh installed:
//
//	-define:OTSH_LIBSSH=system:/usr/lib/x86_64-linux-gnu/libssh.a
//
// `system:` followed by an absolute path is passed to the linker verbatim as an
// input file rather than turned into a `-l`, which is the whole trick: `-lssh`
// finds the shared library first on every platform tested, so an archive added
// alongside it is ignored and the binary keeps its libssh dependency. Naming
// the archive here removes the `-l` entirely. The archive's own dependencies —
// libcrypto, libz — still have to be supplied, as archives, through
// -extra-linker-flags. `otsh build --static` works all of that out; see
// docs/static-linking.md for what it costs and why you might not want it.
//
// This is deliberately a path and not a boolean: there is no portable place a
// libssh.a lives, so a boolean would only push the guessing into these
// bindings, where it cannot see pkg-config. `foreign import` needs a string
// *literal* — `foreign import lib LIB` is a syntax error — so the braced form
// is what lets a compile-time constant, and therefore a -define, reach it.
LIB :: #config(OTSH_LIBSSH, "system:ssh.lib" when ODIN_OS == .Windows else "system:ssh")

foreign import lib {LIB}

// --- opaque handles ---------------------------------------------------------

Session :: distinct rawptr
Channel :: distinct rawptr
Bind :: distinct rawptr
Event :: distinct rawptr
Key :: distinct rawptr
Threads_Callbacks :: distinct rawptr

// libssh's `socket_t`: a signed file descriptor on unix-likes, a Windows
// `SOCKET` (an unsigned UINT_PTR) there. The widths differ, so binding it as
// c.int everywhere would truncate the return of `get_fd` on 64-bit Windows.
Socket :: uintptr when ODIN_OS == .Windows else c.int
// libssh's SSH_INVALID_SOCKET, i.e. `(socket_t)-1`.
INVALID_SOCKET :: ~Socket(0) when ODIN_OS == .Windows else Socket(-1)

// True when `get_fd` handed back a real socket. Spelled as a helper because the
// obvious `fd < 0` is silently always false on Windows, where socket_t is
// unsigned.
socket_valid :: proc "contextless" (s: Socket) -> bool {
	return s != INVALID_SOCKET
}

// Builds a libssh version integer the way its SSH_VERSION_INT macro does.
version_int :: proc "contextless" (major, minor, micro: int) -> c.int {
	return c.int(major << 16 | minor << 8 | micro)
}

// The oldest libssh otsh will run against.
//
// 0.10.6 is where the fix for CVE-2023-48795 ("Terrapin", a prefix-truncation
// attack on the SSH transport) landed, along with the strict-kex extension that
// makes the fix effective. Running a server on anything older is not something
// this package will do quietly.
//
// This is a floor, not an endorsement: libssh is a separate project with its own
// advisories, and being above this line does not mean you are patched. Track
// https://www.libssh.org/security/ and keep the system library current.
MIN_MAJOR :: 0
MIN_MINOR :: 10
MIN_MICRO :: 6

// The newest libssh otsh has been built and run against, as a record rather
// than a limit: nothing checks it and no version is refused for being above it.
// It is here so that "tested up to" has a number attached instead of being a
// vague claim in prose. See docs/compatibility.md for the measurements.
//
// 0.10.6, 0.11.2, 0.12.1 and 0.12.2 were each built, tested and made to serve a
// real ssh session. The struct layouts below were re-derived from each of those
// headers with offsetof: every field otsh names sits at an identical offset in
// all four. The structs mirror the 0.12 shape, so on older libssh they are a
// superset: 0.10 defines two fewer trailing fields in each struct and 0.11 two
// fewer in the server struct. That is safe because libssh bound-checks every
// callback against the `size` we declare and only ever reads fields it knows
// about, so the extra trailing slots are never touched. Every change across
// 0.10 -> 0.11 -> 0.12 was a pure append; nothing was reordered or inserted.
// docs/compatibility.md has the full offset tables.
TESTED_MAX_MAJOR :: 0
TESTED_MAX_MINOR :: 12
TESTED_MAX_MICRO :: 2

// The oldest Odin that compiles this package.
//
// Measured, not guessed: dev-2026-02 fails and dev-2026-03 builds and passes
// the suite, both against libssh 0.10.6 in a container. dev-2026-02 fails
// because `os.read_entire_file_from_path`, `crypto.zero_explicit` and
// `crypto.is_zero_constant_time` do not exist yet and because a compound
// literal this package uses was not legal then — four separate breakages, so
// this is a floor with real content rather than an off-by-one.
//
// Odin has no numeric version constant. `ODIN_VERSION` is a string, and the
// releases are dated, so lexicographic comparison happens to order them
// correctly ("dev-2026-03" < "dev-2026-07" < "dev-2027-01"). That trick is only
// as good as the format, hence the guard below.
MIN_ODIN_VERSION :: "dev-2026-03"

// The check, and the reason it is written defensively.
//
// Not every official Odin build reports a usable ODIN_VERSION: the prebuilt
// `dev-2026-05` release for linux-arm64 reports `ODIN_VERSION == "dev-"` and
// `odin version` prints `dev--nightly:`, because the release was cut without
// the version baked in. Measured on that tarball; dev-2026-01, dev-2025-12a and
// dev-2026-07a all report properly. A bare `#assert(ODIN_VERSION >= ...)` would
// therefore reject a working compiler outright, with no way for the user to
// override it.
//
// So the assert only fires when ODIN_VERSION actually looks like a dated
// release — `dev-` followed by a date, 11 characters at minimum. Anything else
// is treated as "cannot tell" and allowed through, which fails open: a truly
// ancient compiler with a mangled version string gets the raw core-library
// errors instead of this message. That is the same experience as having no
// check at all, so nothing is lost, and the common case gets one clear line
// instead of a dozen confusing ones.
@(private)
ODIN_VERSION_IS_DATED :: len(ODIN_VERSION) >= 11 && ODIN_VERSION[:4] == "dev-"
// The message is a plain literal because Odin requires one there: a
// concatenation of constants, even all-constant, is rejected with "is not a
// constant string". So MIN_ODIN_VERSION appears twice; keep them in step.
#assert(
	!ODIN_VERSION_IS_DATED || ODIN_VERSION >= MIN_ODIN_VERSION,
	"otsh needs Odin dev-2026-03 or newer; see docs/compatibility.md",
)

// --- return codes -----------------------------------------------------------

OK :: 0
ERROR :: -1
AGAIN :: -2
EOF :: -127

Auth :: enum c.int {
	Success = 0,
	Denied  = 1,
	Partial = 2,
	Info    = 3,
	Again   = 4,
	Error   = -1,
}

// c.char is unsigned on this platform, so the signed enum is spelled out.
Pubkey_State :: enum i8 {
	Error = -1,
	None  = 0,
	Valid = 1,
	Wrong = 2,
}

// --- auth method bitmask ----------------------------------------------------

AUTH_METHOD_UNKNOWN :: 0x0000
AUTH_METHOD_NONE :: 0x0001
AUTH_METHOD_PASSWORD :: 0x0002
AUTH_METHOD_PUBLICKEY :: 0x0004
AUTH_METHOD_HOSTBASED :: 0x0008
AUTH_METHOD_INTERACTIVE :: 0x0010

// --- options ----------------------------------------------------------------

Bind_Option :: enum c.int {
	Bindaddr                  = 0,
	Bindport,
	Bindport_Str,
	Hostkey,
	Dsakey, // deprecated
	Rsakey, // deprecated
	Banner,
	Log_Verbosity,
	Log_Verbosity_Str,
	Ecdsakey, // deprecated
	Import_Key,
	Key_Exchange,
	Ciphers_C_S,
	Ciphers_S_C,
	Hmac_C_S,
	Hmac_S_C,
	Config_Dir,
	Pubkey_Accepted_Key_Types,
	Hostkey_Algorithms,
	Process_Config,
	Moduli,
	Rsa_Min_Size,
	Import_Key_Str,
	Gssapi_Key_Exchange,
	Gssapi_Key_Exchange_Algs,
}

Pubkey_Hash_Type :: enum c.int {
	Sha1   = 0,
	Md5    = 1,
	Sha256 = 2,
}

// Only the entries we use; the ordering matches libssh's enum ssh_options_e.
Session_Option :: enum c.int {
	Host    = 0,
	Port    = 1,
	Timeout = 9, // seconds, as a uint64
}

Keytype :: enum c.int {
	Unknown = 0,
	Dss     = 1,
	Rsa     = 2,
	Rsa1    = 3,
	Ecdsa   = 4,
	Ed25519 = 5,
}

// --- callback signatures ----------------------------------------------------

Auth_None_Proc :: #type proc "c" (session: Session, user: cstring, userdata: rawptr) -> c.int
Auth_Password_Proc :: #type proc "c" (session: Session, user, password: cstring, userdata: rawptr) -> c.int
Auth_Pubkey_Proc :: #type proc "c" (session: Session, user: cstring, pubkey: Key, signature_state: c.char, userdata: rawptr) -> c.int
Channel_Open_Session_Proc :: #type proc "c" (session: Session, userdata: rawptr) -> Channel

Channel_Data_Proc :: #type proc "c" (session: Session, channel: Channel, data: rawptr, len: u32, is_stderr: c.int, userdata: rawptr) -> c.int
Channel_Eof_Proc :: #type proc "c" (session: Session, channel: Channel, userdata: rawptr)
Channel_Close_Proc :: #type proc "c" (session: Session, channel: Channel, userdata: rawptr)
Channel_Pty_Proc :: #type proc "c" (session: Session, channel: Channel, term: cstring, width, height, pxwidth, pxheight: c.int, userdata: rawptr) -> c.int
Channel_Shell_Proc :: #type proc "c" (session: Session, channel: Channel, userdata: rawptr) -> c.int
Channel_Window_Change_Proc :: #type proc "c" (session: Session, channel: Channel, width, height, pxwidth, pxheight: c.int, userdata: rawptr) -> c.int
Channel_Env_Proc :: #type proc "c" (session: Session, channel: Channel, name, value: cstring, userdata: rawptr) -> c.int
Channel_Exec_Proc :: #type proc "c" (session: Session, channel: Channel, command: cstring, userdata: rawptr) -> c.int

// C struct layouts. Field order must match libssh/callbacks.h exactly; slots we
// do not use are typed as rawptr so they stay nil.
//
// `size` replaces the ssh_callbacks_init() macro. It is how libssh decides
// which fields the caller's struct actually has, and getting it wrong fails
// quietly rather than loudly: `ssh_callbacks_exists(p, c)` in callbacks.h is
//
//   (p != NULL) && ((char *)&((p)->c) < (char *)(p) + (p)->size) && ((p)->c != NULL)
//
// so with `size` left at zero that bound check is false for every field, and
// libssh accepts the struct and then invokes nothing. The symptom is a
// connection that hangs at the first callback it needed, not an error at
// registration — which is why every callback struct here sets it explicitly.

Server_Callbacks :: struct {
	size:                                       c.size_t,
	userdata:                                   rawptr,
	auth_password_function:                     Auth_Password_Proc,
	auth_none_function:                         Auth_None_Proc,
	auth_gssapi_mic_function:                   rawptr,
	auth_pubkey_function:                       Auth_Pubkey_Proc,
	service_request_function:                   rawptr,
	channel_open_request_session_function:      Channel_Open_Session_Proc,
	gssapi_select_oid_function:                 rawptr,
	gssapi_accept_sec_ctx_function:             rawptr,
	gssapi_verify_mic_function:                 rawptr,
	channel_open_request_direct_tcpip_function: rawptr,
	auth_kbdint_function:                       rawptr,
}

Channel_Callbacks :: struct {
	size:                               c.size_t,
	userdata:                           rawptr,
	channel_data_function:              Channel_Data_Proc,
	channel_eof_function:               Channel_Eof_Proc,
	channel_close_function:             Channel_Close_Proc,
	channel_signal_function:            rawptr,
	channel_exit_status_function:       rawptr,
	channel_exit_signal_function:       rawptr,
	channel_pty_request_function:       Channel_Pty_Proc,
	channel_shell_request_function:     Channel_Shell_Proc,
	channel_auth_agent_req_function:    rawptr,
	channel_x11_req_function:           rawptr,
	channel_pty_window_change_function: Channel_Window_Change_Proc,
	channel_exec_request_function:      Channel_Exec_Proc,
	channel_env_request_function:       Channel_Env_Proc,
	channel_subsystem_request_function: rawptr,
	channel_write_wontblock_function:   rawptr,
	channel_open_response_function:     rawptr,
	channel_request_response_function:  rawptr,
}

@(default_calling_convention = "c")
foreign lib {
	@(link_name = "ssh_init")
	init :: proc() -> c.int ---
	@(link_name = "ssh_finalize")
	finalize :: proc() -> c.int ---
	@(link_name = "ssh_threads_set_callbacks")
	threads_set_callbacks :: proc(cb: Threads_Callbacks) -> c.int ---
	// The platform's own threading backend: pthreads on unix, and on Windows the
	// winlocks one. Deliberately NOT ssh_threads_get_pthread — callbacks.h
	// declares that on every platform, but a Windows libssh only *defines*
	// ssh_threads_get_default and ssh_threads_get_noop, so binding the pthread
	// spelling links everywhere except the one place it is checked:
	//   error LNK2019: unresolved external symbol ssh_threads_get_pthread
	// On unix the two are the same function's result, so nothing changes there.
	@(link_name = "ssh_threads_get_default")
	threads_get_default :: proc() -> Threads_Callbacks ---

	// bind (listening socket)
	@(link_name = "ssh_bind_new")
	bind_new :: proc() -> Bind ---
	@(link_name = "ssh_bind_free")
	bind_free :: proc(b: Bind) ---
	@(link_name = "ssh_bind_options_set")
	bind_options_set :: proc(b: Bind, opt: Bind_Option, value: rawptr) -> c.int ---
	@(link_name = "ssh_bind_listen")
	bind_listen :: proc(b: Bind) -> c.int ---
	@(link_name = "ssh_bind_accept")
	bind_accept :: proc(b: Bind, s: Session) -> c.int ---
	@(link_name = "ssh_bind_get_fd")
	bind_get_fd :: proc(b: Bind) -> Socket ---

	// session
	@(link_name = "ssh_new")
	new_session :: proc() -> Session ---
	@(link_name = "ssh_free")
	free_session :: proc(s: Session) ---
	@(link_name = "ssh_disconnect")
	disconnect :: proc(s: Session) ---
	@(link_name = "ssh_handle_key_exchange")
	handle_key_exchange :: proc(s: Session) -> c.int ---
	@(link_name = "ssh_set_auth_methods")
	set_auth_methods :: proc(s: Session, methods: c.int) ---
	@(link_name = "ssh_set_server_callbacks")
	set_server_callbacks :: proc(s: Session, cb: ^Server_Callbacks) -> c.int ---
	@(link_name = "ssh_set_blocking")
	set_blocking :: proc(s: Session, blocking: c.int) ---
	@(link_name = "ssh_options_set")
	options_set :: proc(s: Session, opt: Session_Option, value: rawptr) -> c.int ---
	@(link_name = "ssh_is_connected")
	is_connected :: proc(s: Session) -> c.int ---
	@(link_name = "ssh_get_error")
	get_error :: proc(s: rawptr) -> cstring ---
	@(link_name = "ssh_get_clientbanner")
	get_clientbanner :: proc(s: Session) -> cstring ---
	// Returns the runtime library version as text, or nil if the library is
	// older than the (major<<16 | minor<<8 | micro) value passed in.
	@(link_name = "ssh_version")
	version :: proc(req_version: c.int) -> cstring ---
	@(link_name = "ssh_get_fd")
	get_fd :: proc(s: Session) -> Socket ---

	// event loop
	@(link_name = "ssh_event_new")
	event_new :: proc() -> Event ---
	@(link_name = "ssh_event_free")
	event_free :: proc(e: Event) ---
	@(link_name = "ssh_event_add_session")
	event_add_session :: proc(e: Event, s: Session) -> c.int ---
	@(link_name = "ssh_event_remove_session")
	event_remove_session :: proc(e: Event, s: Session) -> c.int ---
	@(link_name = "ssh_event_dopoll")
	event_dopoll :: proc(e: Event, timeout_ms: c.int) -> c.int ---

	// channel
	@(link_name = "ssh_channel_new")
	channel_new :: proc(s: Session) -> Channel ---
	@(link_name = "ssh_channel_free")
	channel_free :: proc(ch: Channel) ---
	@(link_name = "ssh_channel_close")
	channel_close :: proc(ch: Channel) -> c.int ---
	@(link_name = "ssh_channel_send_eof")
	channel_send_eof :: proc(ch: Channel) -> c.int ---
	@(link_name = "ssh_channel_is_open")
	channel_is_open :: proc(ch: Channel) -> c.int ---
	@(link_name = "ssh_channel_is_eof")
	channel_is_eof :: proc(ch: Channel) -> c.int ---
	@(link_name = "ssh_channel_write")
	channel_write :: proc(ch: Channel, data: rawptr, len: u32) -> c.int ---
	// The peer's remaining flow-control credit, i.e. how many bytes may be sent
	// right now without waiting. Zero means the peer has not read what it was
	// already sent.
	//
	// This is what keeps `ssh.write` off libssh's blocking path. Once the credit
	// is exhausted, ssh_channel_write waits inside ssh_handle_packets for a
	// WINDOW_ADJUST, and that wait does not honour SSH_OPTIONS_TIMEOUT —
	// measured still blocked 34 s in with the timeout set to 20 s. A client that
	// simply stops reading would otherwise pin a session thread for as long as
	// it likes.
	@(link_name = "ssh_channel_window_size")
	channel_window_size :: proc(ch: Channel) -> u32 ---
	@(link_name = "ssh_channel_request_send_exit_status")
	channel_request_send_exit_status :: proc(ch: Channel, status: c.int) -> c.int ---
	// Returns how many bytes are buffered inside libssh for this channel (its
	// stdout_buffer), 0 when empty, EOF at end of stream, ERROR on error. Also
	// pumps the session nonblockingly, like event_dopoll(e, 0).
	@(link_name = "ssh_channel_poll")
	channel_poll :: proc(ch: Channel, is_stderr: c.int) -> c.int ---
	// Drains up to `count` bytes from the channel's internal buffer without
	// blocking. Returns bytes read, 0/AGAIN when empty, EOF at end of stream,
	// ERROR on error. Data a channel_data_function declined stays in that
	// internal buffer, and this is the only call that can retrieve it after
	// the peer goes quiet — see ssh.read.
	@(link_name = "ssh_channel_read_nonblocking")
	channel_read_nonblocking :: proc(ch: Channel, dest: rawptr, count: u32, is_stderr: c.int) -> c.int ---
	@(link_name = "ssh_set_channel_callbacks")
	set_channel_callbacks :: proc(ch: Channel, cb: ^Channel_Callbacks) -> c.int ---

	// pki (host key generation)
	@(link_name = "ssh_pki_generate")
	pki_generate :: proc(type: Keytype, parameter: c.int, pkey: ^Key) -> c.int ---
	@(link_name = "ssh_pki_export_privkey_file")
	pki_export_privkey_file :: proc(privkey: Key, passphrase: cstring, auth_fn: rawptr, auth_data: rawptr, filename: cstring) -> c.int ---
	@(link_name = "ssh_pki_import_privkey_file")
	pki_import_privkey_file :: proc(filename: cstring, passphrase: cstring, auth_fn: rawptr, auth_data: rawptr, pkey: ^Key) -> c.int ---
	@(link_name = "ssh_key_free")
	key_free :: proc(k: Key) ---
	@(link_name = "ssh_key_type")
	key_type :: proc(k: Key) -> Keytype ---
	@(link_name = "ssh_key_type_to_char")
	key_type_to_char :: proc(t: Keytype) -> cstring ---

	// fingerprints (public-key identity)
	@(link_name = "ssh_get_publickey_hash")
	get_publickey_hash :: proc(k: Key, type: Pubkey_Hash_Type, hash: ^[^]u8, hlen: ^c.size_t) -> c.int ---
	@(link_name = "ssh_get_fingerprint_hash")
	get_fingerprint_hash :: proc(type: Pubkey_Hash_Type, hash: [^]u8, len: c.size_t) -> cstring ---
	@(link_name = "ssh_clean_pubkey_hash")
	clean_pubkey_hash :: proc(hash: ^[^]u8) ---
	@(link_name = "ssh_string_free_char")
	string_free_char :: proc(s: cstring) ---
}
