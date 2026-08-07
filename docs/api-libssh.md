# otsh:libssh — API reference

Raw bindings to libssh's server API. Everything here maps 1:1 onto the C function of the same name, so libssh's own documentation is authoritative for semantics.

Generated from `libssh/*.odin` by `docs/tools/gen_api.py`. For how these fit together, see the hand-written guide ([ssh](ssh.md)).

## Contents

**Types** — [`Auth`](#auth), [`Auth_None_Proc`](#auth-none-proc), [`Auth_Password_Proc`](#auth-password-proc), [`Auth_Pubkey_Proc`](#auth-pubkey-proc), [`Bind`](#bind), [`Bind_Option`](#bind-option), [`Channel`](#channel), [`Channel_Callbacks`](#channel-callbacks), [`Channel_Close_Proc`](#channel-close-proc), [`Channel_Data_Proc`](#channel-data-proc), [`Channel_Env_Proc`](#channel-env-proc), [`Channel_Eof_Proc`](#channel-eof-proc), [`Channel_Exec_Proc`](#channel-exec-proc), [`Channel_Open_Session_Proc`](#channel-open-session-proc), [`Channel_Pty_Proc`](#channel-pty-proc), [`Channel_Shell_Proc`](#channel-shell-proc), [`Channel_Window_Change_Proc`](#channel-window-change-proc), [`Event`](#event), [`Key`](#key), [`Keytype`](#keytype), [`Pubkey_Hash_Type`](#pubkey-hash-type), [`Pubkey_State`](#pubkey-state), [`Server_Callbacks`](#server-callbacks), [`Session`](#session), [`Session_Option`](#session-option), [`Socket`](#socket), [`Threads_Callbacks`](#threads-callbacks)

**Constants** — [`AGAIN`](#again), [`AUTH_METHOD_HOSTBASED`](#auth-method-hostbased), [`AUTH_METHOD_INTERACTIVE`](#auth-method-interactive), [`AUTH_METHOD_NONE`](#auth-method-none), [`AUTH_METHOD_PASSWORD`](#auth-method-password), [`AUTH_METHOD_PUBLICKEY`](#auth-method-publickey), [`AUTH_METHOD_UNKNOWN`](#auth-method-unknown), [`EOF`](#eof), [`ERROR`](#error), [`INVALID_SOCKET`](#invalid-socket), [`LIB`](#lib), [`MIN_MAJOR`](#min-major), [`MIN_MICRO`](#min-micro), [`MIN_MINOR`](#min-minor), [`MIN_ODIN_VERSION`](#min-odin-version), [`OK`](#ok), [`TESTED_MAX_MAJOR`](#tested-max-major), [`TESTED_MAX_MICRO`](#tested-max-micro), [`TESTED_MAX_MINOR`](#tested-max-minor)

**Procedures** — [`bind_accept`](#bind-accept), [`bind_free`](#bind-free), [`bind_get_fd`](#bind-get-fd), [`bind_listen`](#bind-listen), [`bind_new`](#bind-new), [`bind_options_set`](#bind-options-set), [`channel_close`](#channel-close), [`channel_free`](#channel-free), [`channel_is_eof`](#channel-is-eof), [`channel_is_open`](#channel-is-open), [`channel_new`](#channel-new), [`channel_poll`](#channel-poll), [`channel_read_nonblocking`](#channel-read-nonblocking), [`channel_request_send_exit_status`](#channel-request-send-exit-status), [`channel_send_eof`](#channel-send-eof), [`channel_window_size`](#channel-window-size), [`channel_write`](#channel-write), [`clean_pubkey_hash`](#clean-pubkey-hash), [`disconnect`](#disconnect), [`event_add_session`](#event-add-session), [`event_dopoll`](#event-dopoll), [`event_free`](#event-free), [`event_new`](#event-new), [`event_remove_session`](#event-remove-session), [`finalize`](#finalize), [`free_session`](#free-session), [`get_clientbanner`](#get-clientbanner), [`get_error`](#get-error), [`get_fd`](#get-fd), [`get_fingerprint_hash`](#get-fingerprint-hash), [`get_publickey_hash`](#get-publickey-hash), [`handle_key_exchange`](#handle-key-exchange), [`init`](#init), [`is_connected`](#is-connected), [`key_free`](#key-free), [`key_type`](#key-type), [`key_type_to_char`](#key-type-to-char), [`new_session`](#new-session), [`options_set`](#options-set), [`pki_export_privkey_file`](#pki-export-privkey-file), [`pki_generate`](#pki-generate), [`pki_import_privkey_file`](#pki-import-privkey-file), [`set_auth_methods`](#set-auth-methods), [`set_blocking`](#set-blocking), [`set_channel_callbacks`](#set-channel-callbacks), [`set_server_callbacks`](#set-server-callbacks), [`socket_valid`](#socket-valid), [`string_free_char`](#string-free-char), [`threads_get_default`](#threads-get-default), [`threads_set_callbacks`](#threads-set-callbacks), [`version`](#version), [`version_int`](#version-int)

## Types

### `Auth`

```odin
Auth :: enum c.int {
	Success = 0,
	Denied  = 1,
	Partial = 2,
	Info    = 3,
	Again   = 4,
	Error   = -1,
}
```

*[libssh/libssh.odin:164](../libssh/libssh.odin#L164)*

### `Auth_None_Proc`

```odin
Auth_None_Proc :: #type proc "c" (session: Session, user: cstring, userdata: rawptr) -> c.int
```

*[libssh/libssh.odin:244](../libssh/libssh.odin#L244)*

### `Auth_Password_Proc`

```odin
Auth_Password_Proc :: #type proc "c" (session: Session, user, password: cstring, userdata: rawptr) -> c.int
```

*[libssh/libssh.odin:245](../libssh/libssh.odin#L245)*

### `Auth_Pubkey_Proc`

```odin
Auth_Pubkey_Proc :: #type proc "c" (session: Session, user: cstring, pubkey: Key, signature_state: c.char, userdata: rawptr) -> c.int
```

*[libssh/libssh.odin:246](../libssh/libssh.odin#L246)*

### `Bind`

```odin
Bind :: distinct rawptr
```

*[libssh/libssh.odin:58](../libssh/libssh.odin#L58)*

### `Bind_Option`

```odin
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
```

*[libssh/libssh.odin:192](../libssh/libssh.odin#L192)*

### `Channel`

```odin
Channel :: distinct rawptr
```

*[libssh/libssh.odin:57](../libssh/libssh.odin#L57)*

### `Channel_Callbacks`

```odin
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
```

*[libssh/libssh.odin:288](../libssh/libssh.odin#L288)*

### `Channel_Close_Proc`

```odin
Channel_Close_Proc :: #type proc "c" (session: Session, channel: Channel, userdata: rawptr)
```

*[libssh/libssh.odin:251](../libssh/libssh.odin#L251)*

### `Channel_Data_Proc`

```odin
Channel_Data_Proc :: #type proc "c" (session: Session, channel: Channel, data: rawptr, len: u32, is_stderr: c.int, userdata: rawptr) -> c.int
```

*[libssh/libssh.odin:249](../libssh/libssh.odin#L249)*

### `Channel_Env_Proc`

```odin
Channel_Env_Proc :: #type proc "c" (session: Session, channel: Channel, name, value: cstring, userdata: rawptr) -> c.int
```

*[libssh/libssh.odin:255](../libssh/libssh.odin#L255)*

### `Channel_Eof_Proc`

```odin
Channel_Eof_Proc :: #type proc "c" (session: Session, channel: Channel, userdata: rawptr)
```

*[libssh/libssh.odin:250](../libssh/libssh.odin#L250)*

### `Channel_Exec_Proc`

```odin
Channel_Exec_Proc :: #type proc "c" (session: Session, channel: Channel, command: cstring, userdata: rawptr) -> c.int
```

*[libssh/libssh.odin:256](../libssh/libssh.odin#L256)*

### `Channel_Open_Session_Proc`

```odin
Channel_Open_Session_Proc :: #type proc "c" (session: Session, userdata: rawptr) -> Channel
```

*[libssh/libssh.odin:247](../libssh/libssh.odin#L247)*

### `Channel_Pty_Proc`

```odin
Channel_Pty_Proc :: #type proc "c" (session: Session, channel: Channel, term: cstring, width, height, pxwidth, pxheight: c.int, userdata: rawptr) -> c.int
```

*[libssh/libssh.odin:252](../libssh/libssh.odin#L252)*

### `Channel_Shell_Proc`

```odin
Channel_Shell_Proc :: #type proc "c" (session: Session, channel: Channel, userdata: rawptr) -> c.int
```

*[libssh/libssh.odin:253](../libssh/libssh.odin#L253)*

### `Channel_Window_Change_Proc`

```odin
Channel_Window_Change_Proc :: #type proc "c" (session: Session, channel: Channel, width, height, pxwidth, pxheight: c.int, userdata: rawptr) -> c.int
```

*[libssh/libssh.odin:254](../libssh/libssh.odin#L254)*

### `Event`

```odin
Event :: distinct rawptr
```

*[libssh/libssh.odin:59](../libssh/libssh.odin#L59)*

### `Key`

```odin
Key :: distinct rawptr
```

*[libssh/libssh.odin:60](../libssh/libssh.odin#L60)*

### `Keytype`

```odin
Keytype :: enum c.int {
	Unknown = 0,
	Dss     = 1,
	Rsa     = 2,
	Rsa1    = 3,
	Ecdsa   = 4,
	Ed25519 = 5,
}
```

*[libssh/libssh.odin:233](../libssh/libssh.odin#L233)*

### `Pubkey_Hash_Type`

```odin
Pubkey_Hash_Type :: enum c.int {
	Sha1   = 0,
	Md5    = 1,
	Sha256 = 2,
}
```

*[libssh/libssh.odin:220](../libssh/libssh.odin#L220)*

### `Pubkey_State`

```odin
Pubkey_State :: enum i8 {
	Error = -1,
	None  = 0,
	Valid = 1,
	Wrong = 2,
}
```

c.char is unsigned on this platform, so the signed enum is spelled out.

*[libssh/libssh.odin:174](../libssh/libssh.odin#L174)*

### `Server_Callbacks`

```odin
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
```

*[libssh/libssh.odin:272](../libssh/libssh.odin#L272)*

### `Session`

```odin
Session :: distinct rawptr
```

*[libssh/libssh.odin:56](../libssh/libssh.odin#L56)*

### `Session_Option`

```odin
Session_Option :: enum c.int {
	Host    = 0,
	Port    = 1,
	Timeout = 9, // seconds, as a uint64
}
```

Only the entries we use; the ordering matches libssh's enum ssh_options_e.

*[libssh/libssh.odin:227](../libssh/libssh.odin#L227)*

### `Socket`

```odin
Socket :: uintptr when ODIN_OS == .Windows else c.int
```

libssh's `socket_t`: a signed file descriptor on unix-likes, a Windows
`SOCKET` (an unsigned UINT_PTR) there. The widths differ, so binding it as
c.int everywhere would truncate the return of `get_fd` on 64-bit Windows.

*[libssh/libssh.odin:66](../libssh/libssh.odin#L66)*

### `Threads_Callbacks`

```odin
Threads_Callbacks :: distinct rawptr
```

*[libssh/libssh.odin:61](../libssh/libssh.odin#L61)*

## Constants

### `AGAIN`

```odin
AGAIN :: -2
```

*[libssh/libssh.odin:161](../libssh/libssh.odin#L161)*

### `AUTH_METHOD_HOSTBASED`

```odin
AUTH_METHOD_HOSTBASED :: 0x0008
```

*[libssh/libssh.odin:187](../libssh/libssh.odin#L187)*

### `AUTH_METHOD_INTERACTIVE`

```odin
AUTH_METHOD_INTERACTIVE :: 0x0010
```

*[libssh/libssh.odin:188](../libssh/libssh.odin#L188)*

### `AUTH_METHOD_NONE`

```odin
AUTH_METHOD_NONE :: 0x0001
```

*[libssh/libssh.odin:184](../libssh/libssh.odin#L184)*

### `AUTH_METHOD_PASSWORD`

```odin
AUTH_METHOD_PASSWORD :: 0x0002
```

*[libssh/libssh.odin:185](../libssh/libssh.odin#L185)*

### `AUTH_METHOD_PUBLICKEY`

```odin
AUTH_METHOD_PUBLICKEY :: 0x0004
```

*[libssh/libssh.odin:186](../libssh/libssh.odin#L186)*

### `AUTH_METHOD_UNKNOWN`

```odin
AUTH_METHOD_UNKNOWN :: 0x0000
```

*[libssh/libssh.odin:183](../libssh/libssh.odin#L183)*

### `EOF`

```odin
EOF :: -127
```

*[libssh/libssh.odin:162](../libssh/libssh.odin#L162)*

### `ERROR`

```odin
ERROR :: -1
```

*[libssh/libssh.odin:160](../libssh/libssh.odin#L160)*

### `INVALID_SOCKET`

```odin
INVALID_SOCKET :: ~Socket(0) when ODIN_OS == .Windows else Socket(-1)
```

libssh's SSH_INVALID_SOCKET, i.e. `(socket_t)-1`.

*[libssh/libssh.odin:68](../libssh/libssh.odin#L68)*

### `LIB`

```odin
LIB :: #config(OTSH_LIBSSH, "system:ssh.lib" when ODIN_OS == .Windows else "system:ssh")
```

What the linker is told to link against, and the one knob static linking
turns.

The default names the *system* library: `system:ssh` becomes `-lssh`, which
the linker resolves to libssh.so/.dylib wherever it finds it, and
`system:ssh.lib` is the vcpkg import library on Windows — vcpkg is the
expected provider there (`vcpkg install libssh:x64-windows`), and the linker
still needs its directory, e.g.
-extra-linker-flags:"/LIBPATH:C:\\vcpkg\\installed\\x64-windows\\lib".
There is no rpath equivalent on Windows; ssh.dll has to be on %PATH% at run
time. Exercised for real once: on 2026-07-31 these bindings linked against
vcpkg libssh 0.12.0 on Windows 11 and served live openssh sessions. The
hosted CI windows job has since run green. See docs/getting-started.md.

Pointing this at a static archive instead is what makes a binary that runs
on a machine with no libssh installed:

```
-define:OTSH_LIBSSH=system:/usr/lib/x86_64-linux-gnu/libssh.a
```

`system:` followed by an absolute path is passed to the linker verbatim as an
input file rather than turned into a `-l`, which is the whole trick: `-lssh`
finds the shared library first on every platform tested, so an archive added
alongside it is ignored and the binary keeps its libssh dependency. Naming
the archive here removes the `-l` entirely. The archive's own dependencies —
libcrypto, libz — still have to be supplied, as archives, through
-extra-linker-flags. `otsh build --static` works all of that out; see
docs/static-linking.md for what it costs and why you might not want it.

This is deliberately a path and not a boolean: there is no portable place a
libssh.a lives, so a boolean would only push the guessing into these
bindings, where it cannot see pkg-config. `foreign import` needs a string
*literal* — `foreign import lib LIB` is a syntax error — so the braced form
is what lets a compile-time constant, and therefore a -define, reach it.

*[libssh/libssh.odin:50](../libssh/libssh.odin#L50)*

### `MIN_MAJOR`

```odin
MIN_MAJOR :: 0
```

The oldest libssh otsh will run against.

0.10.6 is where the fix for CVE-2023-48795 ("Terrapin", a prefix-truncation
attack on the SSH transport) landed, along with the strict-kex extension that
makes the fix effective. Running a server on anything older is not something
this package will do quietly.

This is a floor, not an endorsement: libssh is a separate project with its own
advisories, and being above this line does not mean you are patched. Track
https://www.libssh.org/security/ and keep the system library current.

*[libssh/libssh.odin:92](../libssh/libssh.odin#L92)*

### `MIN_MICRO`

```odin
MIN_MICRO :: 6
```

*[libssh/libssh.odin:94](../libssh/libssh.odin#L94)*

### `MIN_MINOR`

```odin
MIN_MINOR :: 10
```

*[libssh/libssh.odin:93](../libssh/libssh.odin#L93)*

### `MIN_ODIN_VERSION`

```odin
MIN_ODIN_VERSION :: "dev-2026-03"
```

The oldest Odin that compiles this package.

Measured, not guessed: dev-2026-02 fails and dev-2026-03 builds and passes
the suite, both against libssh 0.10.6 in a container. dev-2026-02 fails
because `os.read_entire_file_from_path`, `crypto.zero_explicit` and
`crypto.is_zero_constant_time` do not exist yet and because a compound
literal this package uses was not legal then — four separate breakages, so
this is a floor with real content rather than an off-by-one.

Odin has no numeric version constant. `ODIN_VERSION` is a string, and the
releases are dated, so lexicographic comparison happens to order them
correctly ("dev-2026-03" < "dev-2026-07" < "dev-2027-01"). That trick is only
as good as the format, hence the guard below.

*[libssh/libssh.odin:128](../libssh/libssh.odin#L128)*

### `OK`

```odin
OK :: 0
```

*[libssh/libssh.odin:159](../libssh/libssh.odin#L159)*

### `TESTED_MAX_MAJOR`

```odin
TESTED_MAX_MAJOR :: 0
```

The newest libssh otsh has been built and run against, as a record rather
than a limit: nothing checks it and no version is refused for being above it.
It is here so that "tested up to" has a number attached instead of being a
vague claim in prose. See docs/compatibility.md for the measurements.

0.10.6, 0.11.2, 0.12.1 and 0.12.2 were each built, tested and made to serve a
real ssh session. The struct layouts below were re-derived from each of those
headers with offsetof: every field otsh names sits at an identical offset in
all four. The structs mirror the 0.12 shape, so on older libssh they are a
superset: 0.10 defines two fewer trailing fields in each struct and 0.11 two
fewer in the server struct. That is safe because libssh bound-checks every
callback against the `size` we declare and only ever reads fields it knows
about, so the extra trailing slots are never touched. Every change across
0.10 -> 0.11 -> 0.12 was a pure append; nothing was reordered or inserted.
docs/compatibility.md has the full offset tables.

*[libssh/libssh.odin:111](../libssh/libssh.odin#L111)*

### `TESTED_MAX_MICRO`

```odin
TESTED_MAX_MICRO :: 2
```

*[libssh/libssh.odin:113](../libssh/libssh.odin#L113)*

### `TESTED_MAX_MINOR`

```odin
TESTED_MAX_MINOR :: 12
```

*[libssh/libssh.odin:112](../libssh/libssh.odin#L112)*

## Procedures

### `bind_accept`

```odin
bind_accept :: proc(b: Bind, s: Session) -> c.int
```

*[libssh/libssh.odin:338](../libssh/libssh.odin#L338)* · C: `ssh_bind_accept`

### `bind_free`

```odin
bind_free :: proc(b: Bind)
```

*[libssh/libssh.odin:332](../libssh/libssh.odin#L332)* · C: `ssh_bind_free`

### `bind_get_fd`

```odin
bind_get_fd :: proc(b: Bind) -> Socket
```

*[libssh/libssh.odin:340](../libssh/libssh.odin#L340)* · C: `ssh_bind_get_fd`

### `bind_listen`

```odin
bind_listen :: proc(b: Bind) -> c.int
```

*[libssh/libssh.odin:336](../libssh/libssh.odin#L336)* · C: `ssh_bind_listen`

### `bind_new`

```odin
bind_new :: proc() -> Bind
```

bind (listening socket)

*[libssh/libssh.odin:330](../libssh/libssh.odin#L330)* · C: `ssh_bind_new`

### `bind_options_set`

```odin
bind_options_set :: proc(b: Bind, opt: Bind_Option, value: rawptr) -> c.int
```

*[libssh/libssh.odin:334](../libssh/libssh.odin#L334)* · C: `ssh_bind_options_set`

### `channel_close`

```odin
channel_close :: proc(ch: Channel) -> c.int
```

*[libssh/libssh.odin:390](../libssh/libssh.odin#L390)* · C: `ssh_channel_close`

### `channel_free`

```odin
channel_free :: proc(ch: Channel)
```

*[libssh/libssh.odin:388](../libssh/libssh.odin#L388)* · C: `ssh_channel_free`

### `channel_is_eof`

```odin
channel_is_eof :: proc(ch: Channel) -> c.int
```

*[libssh/libssh.odin:396](../libssh/libssh.odin#L396)* · C: `ssh_channel_is_eof`

### `channel_is_open`

```odin
channel_is_open :: proc(ch: Channel) -> c.int
```

*[libssh/libssh.odin:394](../libssh/libssh.odin#L394)* · C: `ssh_channel_is_open`

### `channel_new`

```odin
channel_new :: proc(s: Session) -> Channel
```

channel

*[libssh/libssh.odin:386](../libssh/libssh.odin#L386)* · C: `ssh_channel_new`

### `channel_poll`

```odin
channel_poll :: proc(ch: Channel, is_stderr: c.int) -> c.int
```

Returns how many bytes are buffered inside libssh for this channel (its stdout_buffer), 0 when empty, EOF at end of stream, ERROR on error. Also pumps the session nonblockingly, like event_dopoll(e, 0).

*[libssh/libssh.odin:417](../libssh/libssh.odin#L417)* · C: `ssh_channel_poll`

### `channel_read_nonblocking`

```odin
channel_read_nonblocking :: proc(ch: Channel, dest: rawptr, count: u32, is_stderr: c.int) -> c.int
```

Drains up to `count` bytes from the channel's internal buffer without blocking. Returns bytes read, 0/AGAIN when empty, EOF at end of stream, ERROR on error. Data a channel_data_function declined stays in that internal buffer, and this is the only call that can retrieve it after the peer goes quiet — see ssh.read.

*[libssh/libssh.odin:424](../libssh/libssh.odin#L424)* · C: `ssh_channel_read_nonblocking`

### `channel_request_send_exit_status`

```odin
channel_request_send_exit_status :: proc(ch: Channel, status: c.int) -> c.int
```

*[libssh/libssh.odin:412](../libssh/libssh.odin#L412)* · C: `ssh_channel_request_send_exit_status`

### `channel_send_eof`

```odin
channel_send_eof :: proc(ch: Channel) -> c.int
```

*[libssh/libssh.odin:392](../libssh/libssh.odin#L392)* · C: `ssh_channel_send_eof`

### `channel_window_size`

```odin
channel_window_size :: proc(ch: Channel) -> u32
```

The peer's remaining flow-control credit, i.e. how many bytes may be sent right now without waiting. Zero means the peer has not read what it was already sent.  This is what keeps `ssh.write` off libssh's blocking path. Once the credit is exhausted, ssh_channel_write waits inside ssh_handle_packets for a WINDOW_ADJUST, and that wait does not honour SSH_OPTIONS_TIMEOUT — measured still blocked 34 s in with the timeout set to 20 s. A client that simply stops reading would otherwise pin a session thread for as long as it likes.

*[libssh/libssh.odin:410](../libssh/libssh.odin#L410)* · C: `ssh_channel_window_size`

### `channel_write`

```odin
channel_write :: proc(ch: Channel, data: rawptr, len: u32) -> c.int
```

*[libssh/libssh.odin:398](../libssh/libssh.odin#L398)* · C: `ssh_channel_write`

### `clean_pubkey_hash`

```odin
clean_pubkey_hash :: proc(hash: ^[^]u8)
```

*[libssh/libssh.odin:448](../libssh/libssh.odin#L448)* · C: `ssh_clean_pubkey_hash`

### `disconnect`

```odin
disconnect :: proc(s: Session)
```

*[libssh/libssh.odin:348](../libssh/libssh.odin#L348)* · C: `ssh_disconnect`

### `event_add_session`

```odin
event_add_session :: proc(e: Event, s: Session) -> c.int
```

*[libssh/libssh.odin:378](../libssh/libssh.odin#L378)* · C: `ssh_event_add_session`

### `event_dopoll`

```odin
event_dopoll :: proc(e: Event, timeout_ms: c.int) -> c.int
```

*[libssh/libssh.odin:382](../libssh/libssh.odin#L382)* · C: `ssh_event_dopoll`

### `event_free`

```odin
event_free :: proc(e: Event)
```

*[libssh/libssh.odin:376](../libssh/libssh.odin#L376)* · C: `ssh_event_free`

### `event_new`

```odin
event_new :: proc() -> Event
```

event loop

*[libssh/libssh.odin:374](../libssh/libssh.odin#L374)* · C: `ssh_event_new`

### `event_remove_session`

```odin
event_remove_session :: proc(e: Event, s: Session) -> c.int
```

*[libssh/libssh.odin:380](../libssh/libssh.odin#L380)* · C: `ssh_event_remove_session`

### `finalize`

```odin
finalize :: proc() -> c.int
```

*[libssh/libssh.odin:315](../libssh/libssh.odin#L315)* · C: `ssh_finalize`

### `free_session`

```odin
free_session :: proc(s: Session)
```

*[libssh/libssh.odin:346](../libssh/libssh.odin#L346)* · C: `ssh_free`

### `get_clientbanner`

```odin
get_clientbanner :: proc(s: Session) -> cstring
```

*[libssh/libssh.odin:364](../libssh/libssh.odin#L364)* · C: `ssh_get_clientbanner`

### `get_error`

```odin
get_error :: proc(s: rawptr) -> cstring
```

*[libssh/libssh.odin:362](../libssh/libssh.odin#L362)* · C: `ssh_get_error`

### `get_fd`

```odin
get_fd :: proc(s: Session) -> Socket
```

*[libssh/libssh.odin:370](../libssh/libssh.odin#L370)* · C: `ssh_get_fd`

### `get_fingerprint_hash`

```odin
get_fingerprint_hash :: proc(type: Pubkey_Hash_Type, hash: [^]u8, len: c.size_t) -> cstring
```

*[libssh/libssh.odin:446](../libssh/libssh.odin#L446)* · C: `ssh_get_fingerprint_hash`

### `get_publickey_hash`

```odin
get_publickey_hash :: proc(k: Key, type: Pubkey_Hash_Type, hash: ^[^]u8, hlen: ^c.size_t) -> c.int
```

fingerprints (public-key identity)

*[libssh/libssh.odin:444](../libssh/libssh.odin#L444)* · C: `ssh_get_publickey_hash`

### `handle_key_exchange`

```odin
handle_key_exchange :: proc(s: Session) -> c.int
```

*[libssh/libssh.odin:350](../libssh/libssh.odin#L350)* · C: `ssh_handle_key_exchange`

### `init`

```odin
init :: proc() -> c.int
```

*[libssh/libssh.odin:313](../libssh/libssh.odin#L313)* · C: `ssh_init`

### `is_connected`

```odin
is_connected :: proc(s: Session) -> c.int
```

*[libssh/libssh.odin:360](../libssh/libssh.odin#L360)* · C: `ssh_is_connected`

### `key_free`

```odin
key_free :: proc(k: Key)
```

*[libssh/libssh.odin:436](../libssh/libssh.odin#L436)* · C: `ssh_key_free`

### `key_type`

```odin
key_type :: proc(k: Key) -> Keytype
```

*[libssh/libssh.odin:438](../libssh/libssh.odin#L438)* · C: `ssh_key_type`

### `key_type_to_char`

```odin
key_type_to_char :: proc(t: Keytype) -> cstring
```

*[libssh/libssh.odin:440](../libssh/libssh.odin#L440)* · C: `ssh_key_type_to_char`

### `new_session`

```odin
new_session :: proc() -> Session
```

session

*[libssh/libssh.odin:344](../libssh/libssh.odin#L344)* · C: `ssh_new`

### `options_set`

```odin
options_set :: proc(s: Session, opt: Session_Option, value: rawptr) -> c.int
```

*[libssh/libssh.odin:358](../libssh/libssh.odin#L358)* · C: `ssh_options_set`

### `pki_export_privkey_file`

```odin
pki_export_privkey_file :: proc(privkey: Key, passphrase: cstring, auth_fn: rawptr, auth_data: rawptr, filename: cstring) -> c.int
```

*[libssh/libssh.odin:432](../libssh/libssh.odin#L432)* · C: `ssh_pki_export_privkey_file`

### `pki_generate`

```odin
pki_generate :: proc(type: Keytype, parameter: c.int, pkey: ^Key) -> c.int
```

pki (host key generation)

*[libssh/libssh.odin:430](../libssh/libssh.odin#L430)* · C: `ssh_pki_generate`

### `pki_import_privkey_file`

```odin
pki_import_privkey_file :: proc(filename: cstring, passphrase: cstring, auth_fn: rawptr, auth_data: rawptr, pkey: ^Key) -> c.int
```

*[libssh/libssh.odin:434](../libssh/libssh.odin#L434)* · C: `ssh_pki_import_privkey_file`

### `set_auth_methods`

```odin
set_auth_methods :: proc(s: Session, methods: c.int)
```

*[libssh/libssh.odin:352](../libssh/libssh.odin#L352)* · C: `ssh_set_auth_methods`

### `set_blocking`

```odin
set_blocking :: proc(s: Session, blocking: c.int)
```

*[libssh/libssh.odin:356](../libssh/libssh.odin#L356)* · C: `ssh_set_blocking`

### `set_channel_callbacks`

```odin
set_channel_callbacks :: proc(ch: Channel, cb: ^Channel_Callbacks) -> c.int
```

*[libssh/libssh.odin:426](../libssh/libssh.odin#L426)* · C: `ssh_set_channel_callbacks`

### `set_server_callbacks`

```odin
set_server_callbacks :: proc(s: Session, cb: ^Server_Callbacks) -> c.int
```

*[libssh/libssh.odin:354](../libssh/libssh.odin#L354)* · C: `ssh_set_server_callbacks`

### `socket_valid`

```odin
socket_valid :: proc "contextless" (s: Socket) -> bool
```

True when `get_fd` handed back a real socket. Spelled as a helper because the
obvious `fd < 0` is silently always false on Windows, where socket_t is
unsigned.

*[libssh/libssh.odin:73](../libssh/libssh.odin#L73)*

### `string_free_char`

```odin
string_free_char :: proc(s: cstring)
```

*[libssh/libssh.odin:450](../libssh/libssh.odin#L450)* · C: `ssh_string_free_char`

### `threads_get_default`

```odin
threads_get_default :: proc() -> Threads_Callbacks
```

The platform's own threading backend: pthreads on unix, and on Windows the winlocks one. Deliberately NOT ssh_threads_get_pthread — callbacks.h declares that on every platform, but a Windows libssh only *defines* ssh_threads_get_default and ssh_threads_get_noop, so binding the pthread spelling links everywhere except the one place it is checked:   error LNK2019: unresolved external symbol ssh_threads_get_pthread On unix the two are the same function's result, so nothing changes there.

*[libssh/libssh.odin:326](../libssh/libssh.odin#L326)* · C: `ssh_threads_get_default`

### `threads_set_callbacks`

```odin
threads_set_callbacks :: proc(cb: Threads_Callbacks) -> c.int
```

*[libssh/libssh.odin:317](../libssh/libssh.odin#L317)* · C: `ssh_threads_set_callbacks`

### `version`

```odin
version :: proc(req_version: c.int) -> cstring
```

Returns the runtime library version as text, or nil if the library is older than the (major<<16 | minor<<8 | micro) value passed in.

*[libssh/libssh.odin:368](../libssh/libssh.odin#L368)* · C: `ssh_version`

### `version_int`

```odin
version_int :: proc "contextless" (major, minor, micro: int) -> c.int
```

Builds a libssh version integer the way its SSH_VERSION_INT macro does.

*[libssh/libssh.odin:78](../libssh/libssh.odin#L78)*
