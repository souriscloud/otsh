// Minimal Odin bindings for the libssh *server* API.
//
// Only the surface needed to run an SSH server that hands each connection a
// pseudo-terminal-shaped byte stream is bound here. See ../ssh for the
// higher-level wrapper.
package libssh

import "core:c"

when ODIN_OS == .Darwin || ODIN_OS == .Linux || ODIN_OS == .FreeBSD {
	foreign import lib "system:ssh"
} else when ODIN_OS == .Windows {
	// vcpkg is the expected provider: `vcpkg install libssh:x64-windows` builds
	// the import library as ssh.lib. The linker still needs its directory, e.g.
	// -extra-linker-flags:"/LIBPATH:C:\\vcpkg\\installed\\x64-windows\\lib".
	//
	// Experimental: cross-type-checked and built in CI, never run by a human on
	// real Windows. See docs/getting-started.md.
	foreign import lib "system:ssh.lib"
} else {
	#panic("libssh bindings support unix-likes and Windows")
}

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
// `size` replaces the ssh_callbacks_init() macro: libssh uses it for forward
// compatibility and rejects the struct if it is zero.

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
