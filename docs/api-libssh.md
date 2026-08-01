# otsh:libssh — API reference

Raw bindings to libssh's server API. Everything here maps 1:1 onto the C function of the same name, so libssh's own documentation is authoritative for semantics.

Generated from `libssh/*.odin` by `docs/tools/gen_api.py`. For how these fit together, see the hand-written guide ([ssh](ssh.md)).

## Contents

**Types** — [`Auth`](#auth), [`Auth_None_Proc`](#auth-none-proc), [`Auth_Password_Proc`](#auth-password-proc), [`Auth_Pubkey_Proc`](#auth-pubkey-proc), [`Bind`](#bind), [`Bind_Option`](#bind-option), [`Channel`](#channel), [`Channel_Callbacks`](#channel-callbacks), [`Channel_Close_Proc`](#channel-close-proc), [`Channel_Data_Proc`](#channel-data-proc), [`Channel_Env_Proc`](#channel-env-proc), [`Channel_Eof_Proc`](#channel-eof-proc), [`Channel_Exec_Proc`](#channel-exec-proc), [`Channel_Open_Session_Proc`](#channel-open-session-proc), [`Channel_Pty_Proc`](#channel-pty-proc), [`Channel_Shell_Proc`](#channel-shell-proc), [`Channel_Window_Change_Proc`](#channel-window-change-proc), [`Event`](#event), [`Key`](#key), [`Keytype`](#keytype), [`Pubkey_Hash_Type`](#pubkey-hash-type), [`Pubkey_State`](#pubkey-state), [`Server_Callbacks`](#server-callbacks), [`Session`](#session), [`Session_Option`](#session-option), [`Threads_Callbacks`](#threads-callbacks)

**Constants** — [`AGAIN`](#again), [`AUTH_METHOD_HOSTBASED`](#auth-method-hostbased), [`AUTH_METHOD_INTERACTIVE`](#auth-method-interactive), [`AUTH_METHOD_NONE`](#auth-method-none), [`AUTH_METHOD_PASSWORD`](#auth-method-password), [`AUTH_METHOD_PUBLICKEY`](#auth-method-publickey), [`AUTH_METHOD_UNKNOWN`](#auth-method-unknown), [`EOF`](#eof), [`ERROR`](#error), [`INVALID_SOCKET`](#invalid-socket), [`MIN_MAJOR`](#min-major), [`MIN_MICRO`](#min-micro), [`MIN_MINOR`](#min-minor), [`MIN_ODIN_VERSION`](#min-odin-version), [`OK`](#ok), [`Socket`](#socket), [`TESTED_MAX_MAJOR`](#tested-max-major), [`TESTED_MAX_MICRO`](#tested-max-micro), [`TESTED_MAX_MINOR`](#tested-max-minor)

**Procedures** — [`bind_accept`](#bind-accept), [`bind_free`](#bind-free), [`bind_get_fd`](#bind-get-fd), [`bind_listen`](#bind-listen), [`bind_new`](#bind-new), [`bind_options_set`](#bind-options-set), [`channel_close`](#channel-close), [`channel_free`](#channel-free), [`channel_is_eof`](#channel-is-eof), [`channel_is_open`](#channel-is-open), [`channel_new`](#channel-new), [`channel_poll`](#channel-poll), [`channel_read_nonblocking`](#channel-read-nonblocking), [`channel_request_send_exit_status`](#channel-request-send-exit-status), [`channel_send_eof`](#channel-send-eof), [`channel_write`](#channel-write), [`clean_pubkey_hash`](#clean-pubkey-hash), [`disconnect`](#disconnect), [`event_add_session`](#event-add-session), [`event_dopoll`](#event-dopoll), [`event_free`](#event-free), [`event_new`](#event-new), [`event_remove_session`](#event-remove-session), [`finalize`](#finalize), [`free_session`](#free-session), [`get_clientbanner`](#get-clientbanner), [`get_error`](#get-error), [`get_fd`](#get-fd), [`get_fingerprint_hash`](#get-fingerprint-hash), [`get_publickey_hash`](#get-publickey-hash), [`handle_key_exchange`](#handle-key-exchange), [`init`](#init), [`is_connected`](#is-connected), [`key_free`](#key-free), [`key_type`](#key-type), [`key_type_to_char`](#key-type-to-char), [`new_session`](#new-session), [`options_set`](#options-set), [`pki_export_privkey_file`](#pki-export-privkey-file), [`pki_generate`](#pki-generate), [`pki_import_privkey_file`](#pki-import-privkey-file), [`set_auth_methods`](#set-auth-methods), [`set_blocking`](#set-blocking), [`set_channel_callbacks`](#set-channel-callbacks), [`set_server_callbacks`](#set-server-callbacks), [`socket_valid`](#socket-valid), [`string_free_char`](#string-free-char), [`threads_get_default`](#threads-get-default), [`threads_set_callbacks`](#threads-set-callbacks), [`version`](#version), [`version_int`](#version-int)

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

*libssh/libssh.odin:136*

### `Auth_None_Proc`

```odin
Auth_None_Proc :: #type proc "c" (session: Session, user: cstring, userdata: rawptr) -> c.int
```

*libssh/libssh.odin:216*

### `Auth_Password_Proc`

```odin
Auth_Password_Proc :: #type proc "c" (session: Session, user, password: cstring, userdata: rawptr) -> c.int
```

*libssh/libssh.odin:217*

### `Auth_Pubkey_Proc`

```odin
Auth_Pubkey_Proc :: #type proc "c" (session: Session, user: cstring, pubkey: Key, signature_state: c.char, userdata: rawptr) -> c.int
```

*libssh/libssh.odin:218*

### `Bind`

```odin
Bind :: distinct rawptr
Event :: distinct rawptr
Key :: distinct rawptr
Threads_Callbacks :: distinct rawptr

// libssh's `socket_t`: a signed file descriptor on unix-likes, a Windows
// `SOCKET` (an unsigned UINT_PTR) there. The widths differ, so binding it as
```

*libssh/libssh.odin:30*

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

*libssh/libssh.odin:164*

### `Channel`

```odin
Channel :: distinct rawptr
Bind :: distinct rawptr
Event :: distinct rawptr
Key :: distinct rawptr
Threads_Callbacks :: distinct rawptr

// libssh's `socket_t`: a signed file descriptor on unix-likes, a Windows
// `SOCKET` (an unsigned UINT_PTR) there. The widths differ, so binding it as
```

*libssh/libssh.odin:29*

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

*libssh/libssh.odin:252*

### `Channel_Close_Proc`

```odin
Channel_Close_Proc :: #type proc "c" (session: Session, channel: Channel, userdata: rawptr)
```

*libssh/libssh.odin:223*

### `Channel_Data_Proc`

```odin
Channel_Data_Proc :: #type proc "c" (session: Session, channel: Channel, data: rawptr, len: u32, is_stderr: c.int, userdata: rawptr) -> c.int
```

*libssh/libssh.odin:221*

### `Channel_Env_Proc`

```odin
Channel_Env_Proc :: #type proc "c" (session: Session, channel: Channel, name, value: cstring, userdata: rawptr) -> c.int
```

*libssh/libssh.odin:227*

### `Channel_Eof_Proc`

```odin
Channel_Eof_Proc :: #type proc "c" (session: Session, channel: Channel, userdata: rawptr)
```

*libssh/libssh.odin:222*

### `Channel_Exec_Proc`

```odin
Channel_Exec_Proc :: #type proc "c" (session: Session, channel: Channel, command: cstring, userdata: rawptr) -> c.int
```

*libssh/libssh.odin:228*

### `Channel_Open_Session_Proc`

```odin
Channel_Open_Session_Proc :: #type proc "c" (session: Session, userdata: rawptr) -> Channel
```

*libssh/libssh.odin:219*

### `Channel_Pty_Proc`

```odin
Channel_Pty_Proc :: #type proc "c" (session: Session, channel: Channel, term: cstring, width, height, pxwidth, pxheight: c.int, userdata: rawptr) -> c.int
```

*libssh/libssh.odin:224*

### `Channel_Shell_Proc`

```odin
Channel_Shell_Proc :: #type proc "c" (session: Session, channel: Channel, userdata: rawptr) -> c.int
```

*libssh/libssh.odin:225*

### `Channel_Window_Change_Proc`

```odin
Channel_Window_Change_Proc :: #type proc "c" (session: Session, channel: Channel, width, height, pxwidth, pxheight: c.int, userdata: rawptr) -> c.int
```

*libssh/libssh.odin:226*

### `Event`

```odin
Event :: distinct rawptr
Key :: distinct rawptr
Threads_Callbacks :: distinct rawptr

// libssh's `socket_t`: a signed file descriptor on unix-likes, a Windows
// `SOCKET` (an unsigned UINT_PTR) there. The widths differ, so binding it as
```

*libssh/libssh.odin:31*

### `Key`

```odin
Key :: distinct rawptr
Threads_Callbacks :: distinct rawptr

// libssh's `socket_t`: a signed file descriptor on unix-likes, a Windows
// `SOCKET` (an unsigned UINT_PTR) there. The widths differ, so binding it as
```

*libssh/libssh.odin:32*

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

*libssh/libssh.odin:205*

### `Pubkey_Hash_Type`

```odin
Pubkey_Hash_Type :: enum c.int {
	Sha1   = 0,
	Md5    = 1,
	Sha256 = 2,
}
```

*libssh/libssh.odin:192*

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

*libssh/libssh.odin:146*

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

*libssh/libssh.odin:236*

### `Session`

```odin
Session :: distinct rawptr
Channel :: distinct rawptr
Bind :: distinct rawptr
Event :: distinct rawptr
Key :: distinct rawptr
Threads_Callbacks :: distinct rawptr

// libssh's `socket_t`: a signed file descriptor on unix-likes, a Windows
// `SOCKET` (an unsigned UINT_PTR) there. The widths differ, so binding it as
```

*libssh/libssh.odin:28*

### `Session_Option`

```odin
Session_Option :: enum c.int {
	Host    = 0,
	Port    = 1,
	Timeout = 9, // seconds, as a uint64
}
```

Only the entries we use; the ordering matches libssh's enum ssh_options_e.

*libssh/libssh.odin:199*

### `Threads_Callbacks`

```odin
Threads_Callbacks :: distinct rawptr

// libssh's `socket_t`: a signed file descriptor on unix-likes, a Windows
// `SOCKET` (an unsigned UINT_PTR) there. The widths differ, so binding it as
```

*libssh/libssh.odin:33*

## Constants

### `AGAIN`

```odin
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
```

*libssh/libssh.odin:133*

### `AUTH_METHOD_HOSTBASED`

```odin
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
```

*libssh/libssh.odin:159*

### `AUTH_METHOD_INTERACTIVE`

```odin
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
```

*libssh/libssh.odin:160*

### `AUTH_METHOD_NONE`

```odin
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
```

*libssh/libssh.odin:156*

### `AUTH_METHOD_PASSWORD`

```odin
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
```

*libssh/libssh.odin:157*

### `AUTH_METHOD_PUBLICKEY`

```odin
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
```

*libssh/libssh.odin:158*

### `AUTH_METHOD_UNKNOWN`

```odin
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
```

*libssh/libssh.odin:155*

### `EOF`

```odin
EOF :: -127

Auth :: enum c.int {
	Success = 0,
	Denied  = 1,
	Partial = 2,
	Info    = 3,
	Again   = 4,
	Error   = -1,
}
```

*libssh/libssh.odin:134*

### `ERROR`

```odin
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
```

*libssh/libssh.odin:132*

### `INVALID_SOCKET`

```odin
INVALID_SOCKET :: ~Socket(0) when ODIN_OS == .Windows else Socket(-1)
```

libssh's SSH_INVALID_SOCKET, i.e. `(socket_t)-1`.

*libssh/libssh.odin:40*

### `MIN_MAJOR`

```odin
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
```

The oldest libssh otsh will run against.

0.10.6 is where the fix for CVE-2023-48795 ("Terrapin", a prefix-truncation
attack on the SSH transport) landed, along with the strict-kex extension that
makes the fix effective. Running a server on anything older is not something
this package will do quietly.

This is a floor, not an endorsement: libssh is a separate project with its own
advisories, and being above this line does not mean you are patched. Track
https://www.libssh.org/security/ and keep the system library current.

*libssh/libssh.odin:64*

### `MIN_MICRO`

```odin
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
```

*libssh/libssh.odin:66*

### `MIN_MINOR`

```odin
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
```

*libssh/libssh.odin:65*

### `MIN_ODIN_VERSION`

```odin
MIN_ODIN_VERSION :: "dev-2026-03"

// The check, and the reason it is written defensively.
//
// Not every official Odin build reports a usable ODIN_VERSION: the prebuilt
// `dev-2026-05` release for linux-arm64 reports `ODIN_VERSION == "dev-"` and
// `odin version` prints `dev--nightly:`, because the release was cut without
// the version baked in. Measured on that tarball; dev-2026-01, dev-2025-12a and
// dev-2026-07a all report properly. A bare `#assert(ODIN_VERSION >= ...)` would
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

*libssh/libssh.odin:100*

### `OK`

```odin
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
```

*libssh/libssh.odin:131*

### `Socket`

```odin
Socket :: uintptr when ODIN_OS == .Windows else c.int
// libssh's SSH_INVALID_SOCKET, i.e. `(socket_t)-1`.
```

libssh's `socket_t`: a signed file descriptor on unix-likes, a Windows
`SOCKET` (an unsigned UINT_PTR) there. The widths differ, so binding it as
c.int everywhere would truncate the return of `get_fd` on 64-bit Windows.

*libssh/libssh.odin:38*

### `TESTED_MAX_MAJOR`

```odin
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

*libssh/libssh.odin:83*

### `TESTED_MAX_MICRO`

```odin
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
```

*libssh/libssh.odin:85*

### `TESTED_MAX_MINOR`

```odin
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
```

*libssh/libssh.odin:84*

## Procedures

### `bind_accept`

```odin
proc(b: Bind, s: Session) -> c.int
```

*libssh/libssh.odin:302* · C: `ssh_bind_accept`

### `bind_free`

```odin
proc(b: Bind)
```

*libssh/libssh.odin:296* · C: `ssh_bind_free`

### `bind_get_fd`

```odin
proc(b: Bind) -> Socket
```

*libssh/libssh.odin:304* · C: `ssh_bind_get_fd`

### `bind_listen`

```odin
proc(b: Bind) -> c.int
```

*libssh/libssh.odin:300* · C: `ssh_bind_listen`

### `bind_new`

```odin
proc() -> Bind
```

bind (listening socket)

*libssh/libssh.odin:294* · C: `ssh_bind_new`

### `bind_options_set`

```odin
proc(b: Bind, opt: Bind_Option, value: rawptr) -> c.int
```

*libssh/libssh.odin:298* · C: `ssh_bind_options_set`

### `channel_close`

```odin
proc(ch: Channel) -> c.int
```

*libssh/libssh.odin:354* · C: `ssh_channel_close`

### `channel_free`

```odin
proc(ch: Channel)
```

*libssh/libssh.odin:352* · C: `ssh_channel_free`

### `channel_is_eof`

```odin
proc(ch: Channel) -> c.int
```

*libssh/libssh.odin:360* · C: `ssh_channel_is_eof`

### `channel_is_open`

```odin
proc(ch: Channel) -> c.int
```

*libssh/libssh.odin:358* · C: `ssh_channel_is_open`

### `channel_new`

```odin
proc(s: Session) -> Channel
```

channel

*libssh/libssh.odin:350* · C: `ssh_channel_new`

### `channel_poll`

```odin
proc(ch: Channel, is_stderr: c.int) -> c.int
```

Returns how many bytes are buffered inside libssh for this channel (its stdout_buffer), 0 when empty, EOF at end of stream, ERROR on error. Also pumps the session nonblockingly, like event_dopoll(e, 0).

*libssh/libssh.odin:369* · C: `ssh_channel_poll`

### `channel_read_nonblocking`

```odin
proc(ch: Channel, dest: rawptr, count: u32, is_stderr: c.int) -> c.int
```

Drains up to `count` bytes from the channel's internal buffer without blocking. Returns bytes read, 0/AGAIN when empty, EOF at end of stream, ERROR on error. Data a channel_data_function declined stays in that internal buffer, and this is the only call that can retrieve it after the peer goes quiet — see ssh.read.

*libssh/libssh.odin:376* · C: `ssh_channel_read_nonblocking`

### `channel_request_send_exit_status`

```odin
proc(ch: Channel, status: c.int) -> c.int
```

*libssh/libssh.odin:364* · C: `ssh_channel_request_send_exit_status`

### `channel_send_eof`

```odin
proc(ch: Channel) -> c.int
```

*libssh/libssh.odin:356* · C: `ssh_channel_send_eof`

### `channel_write`

```odin
proc(ch: Channel, data: rawptr, len: u32) -> c.int
```

*libssh/libssh.odin:362* · C: `ssh_channel_write`

### `clean_pubkey_hash`

```odin
proc(hash: ^[^]u8)
```

*libssh/libssh.odin:400* · C: `ssh_clean_pubkey_hash`

### `disconnect`

```odin
proc(s: Session)
```

*libssh/libssh.odin:312* · C: `ssh_disconnect`

### `event_add_session`

```odin
proc(e: Event, s: Session) -> c.int
```

*libssh/libssh.odin:342* · C: `ssh_event_add_session`

### `event_dopoll`

```odin
proc(e: Event, timeout_ms: c.int) -> c.int
```

*libssh/libssh.odin:346* · C: `ssh_event_dopoll`

### `event_free`

```odin
proc(e: Event)
```

*libssh/libssh.odin:340* · C: `ssh_event_free`

### `event_new`

```odin
proc() -> Event
```

event loop

*libssh/libssh.odin:338* · C: `ssh_event_new`

### `event_remove_session`

```odin
proc(e: Event, s: Session) -> c.int
```

*libssh/libssh.odin:344* · C: `ssh_event_remove_session`

### `finalize`

```odin
proc() -> c.int
```

*libssh/libssh.odin:279* · C: `ssh_finalize`

### `free_session`

```odin
proc(s: Session)
```

*libssh/libssh.odin:310* · C: `ssh_free`

### `get_clientbanner`

```odin
proc(s: Session) -> cstring
```

*libssh/libssh.odin:328* · C: `ssh_get_clientbanner`

### `get_error`

```odin
proc(s: rawptr) -> cstring
```

*libssh/libssh.odin:326* · C: `ssh_get_error`

### `get_fd`

```odin
proc(s: Session) -> Socket
```

*libssh/libssh.odin:334* · C: `ssh_get_fd`

### `get_fingerprint_hash`

```odin
proc(type: Pubkey_Hash_Type, hash: [^]u8, len: c.size_t) -> cstring
```

*libssh/libssh.odin:398* · C: `ssh_get_fingerprint_hash`

### `get_publickey_hash`

```odin
proc(k: Key, type: Pubkey_Hash_Type, hash: ^[^]u8, hlen: ^c.size_t) -> c.int
```

fingerprints (public-key identity)

*libssh/libssh.odin:396* · C: `ssh_get_publickey_hash`

### `handle_key_exchange`

```odin
proc(s: Session) -> c.int
```

*libssh/libssh.odin:314* · C: `ssh_handle_key_exchange`

### `init`

```odin
proc() -> c.int
```

*libssh/libssh.odin:277* · C: `ssh_init`

### `is_connected`

```odin
proc(s: Session) -> c.int
```

*libssh/libssh.odin:324* · C: `ssh_is_connected`

### `key_free`

```odin
proc(k: Key)
```

*libssh/libssh.odin:388* · C: `ssh_key_free`

### `key_type`

```odin
proc(k: Key) -> Keytype
```

*libssh/libssh.odin:390* · C: `ssh_key_type`

### `key_type_to_char`

```odin
proc(t: Keytype) -> cstring
```

*libssh/libssh.odin:392* · C: `ssh_key_type_to_char`

### `new_session`

```odin
proc() -> Session
```

session

*libssh/libssh.odin:308* · C: `ssh_new`

### `options_set`

```odin
proc(s: Session, opt: Session_Option, value: rawptr) -> c.int
```

*libssh/libssh.odin:322* · C: `ssh_options_set`

### `pki_export_privkey_file`

```odin
proc(privkey: Key, passphrase: cstring, auth_fn: rawptr, auth_data: rawptr, filename: cstring) -> c.int
```

*libssh/libssh.odin:384* · C: `ssh_pki_export_privkey_file`

### `pki_generate`

```odin
proc(type: Keytype, parameter: c.int, pkey: ^Key) -> c.int
```

pki (host key generation)

*libssh/libssh.odin:382* · C: `ssh_pki_generate`

### `pki_import_privkey_file`

```odin
proc(filename: cstring, passphrase: cstring, auth_fn: rawptr, auth_data: rawptr, pkey: ^Key) -> c.int
```

*libssh/libssh.odin:386* · C: `ssh_pki_import_privkey_file`

### `set_auth_methods`

```odin
proc(s: Session, methods: c.int)
```

*libssh/libssh.odin:316* · C: `ssh_set_auth_methods`

### `set_blocking`

```odin
proc(s: Session, blocking: c.int)
```

*libssh/libssh.odin:320* · C: `ssh_set_blocking`

### `set_channel_callbacks`

```odin
proc(ch: Channel, cb: ^Channel_Callbacks) -> c.int
```

*libssh/libssh.odin:378* · C: `ssh_set_channel_callbacks`

### `set_server_callbacks`

```odin
proc(s: Session, cb: ^Server_Callbacks) -> c.int
```

*libssh/libssh.odin:318* · C: `ssh_set_server_callbacks`

### `socket_valid`

```odin
socket_valid :: proc "contextless" (s: Socket) -> bool
```

True when `get_fd` handed back a real socket. Spelled as a helper because the
obvious `fd < 0` is silently always false on Windows, where socket_t is
unsigned.

*libssh/libssh.odin:45*

### `string_free_char`

```odin
proc(s: cstring)
```

*libssh/libssh.odin:402* · C: `ssh_string_free_char`

### `threads_get_default`

```odin
proc() -> Threads_Callbacks
```

The platform's own threading backend: pthreads on unix, and on Windows the winlocks one. Deliberately NOT ssh_threads_get_pthread — callbacks.h declares that on every platform, but a Windows libssh only *defines* ssh_threads_get_default and ssh_threads_get_noop, so binding the pthread spelling links everywhere except the one place it is checked: error LNK2019: unresolved external symbol ssh_threads_get_pthread On unix the two are the same function's result, so nothing changes there.

*libssh/libssh.odin:290* · C: `ssh_threads_get_default`

### `threads_set_callbacks`

```odin
proc(cb: Threads_Callbacks) -> c.int
```

*libssh/libssh.odin:281* · C: `ssh_threads_set_callbacks`

### `version`

```odin
proc(req_version: c.int) -> cstring
```

Returns the runtime library version as text, or nil if the library is older than the (major<<16 | minor<<8 | micro) value passed in.

*libssh/libssh.odin:332* · C: `ssh_version`

### `version_int`

```odin
version_int :: proc "contextless" (major, minor, micro: int) -> c.int
```

Builds a libssh version integer the way its SSH_VERSION_INT macro does.

*libssh/libssh.odin:50*
