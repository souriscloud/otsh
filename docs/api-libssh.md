# otsh:libssh — API reference

Raw bindings to libssh's server API. Everything here maps 1:1 onto the C function of the same name, so libssh's own documentation is authoritative for semantics.

Generated from `libssh/*.odin` by `docs/tools/gen_api.py`. For how these fit together, see the hand-written guide ([ssh](ssh.md)).

## Contents

**Types** — [`Auth`](#auth), [`Auth_None_Proc`](#auth-none-proc), [`Auth_Password_Proc`](#auth-password-proc), [`Auth_Pubkey_Proc`](#auth-pubkey-proc), [`Bind`](#bind), [`Bind_Option`](#bind-option), [`Channel`](#channel), [`Channel_Callbacks`](#channel-callbacks), [`Channel_Close_Proc`](#channel-close-proc), [`Channel_Data_Proc`](#channel-data-proc), [`Channel_Env_Proc`](#channel-env-proc), [`Channel_Eof_Proc`](#channel-eof-proc), [`Channel_Exec_Proc`](#channel-exec-proc), [`Channel_Open_Session_Proc`](#channel-open-session-proc), [`Channel_Pty_Proc`](#channel-pty-proc), [`Channel_Shell_Proc`](#channel-shell-proc), [`Channel_Window_Change_Proc`](#channel-window-change-proc), [`Event`](#event), [`Key`](#key), [`Keytype`](#keytype), [`Pubkey_Hash_Type`](#pubkey-hash-type), [`Pubkey_State`](#pubkey-state), [`Server_Callbacks`](#server-callbacks), [`Session`](#session), [`Session_Option`](#session-option), [`Threads_Callbacks`](#threads-callbacks)

**Constants** — [`AGAIN`](#again), [`AUTH_METHOD_HOSTBASED`](#auth-method-hostbased), [`AUTH_METHOD_INTERACTIVE`](#auth-method-interactive), [`AUTH_METHOD_NONE`](#auth-method-none), [`AUTH_METHOD_PASSWORD`](#auth-method-password), [`AUTH_METHOD_PUBLICKEY`](#auth-method-publickey), [`AUTH_METHOD_UNKNOWN`](#auth-method-unknown), [`EOF`](#eof), [`ERROR`](#error), [`MIN_MAJOR`](#min-major), [`MIN_MICRO`](#min-micro), [`MIN_MINOR`](#min-minor), [`OK`](#ok)

**Procedures** — [`bind_accept`](#bind-accept), [`bind_free`](#bind-free), [`bind_listen`](#bind-listen), [`bind_new`](#bind-new), [`bind_options_set`](#bind-options-set), [`channel_close`](#channel-close), [`channel_free`](#channel-free), [`channel_is_eof`](#channel-is-eof), [`channel_is_open`](#channel-is-open), [`channel_new`](#channel-new), [`channel_request_send_exit_status`](#channel-request-send-exit-status), [`channel_send_eof`](#channel-send-eof), [`channel_write`](#channel-write), [`clean_pubkey_hash`](#clean-pubkey-hash), [`disconnect`](#disconnect), [`event_add_session`](#event-add-session), [`event_dopoll`](#event-dopoll), [`event_free`](#event-free), [`event_new`](#event-new), [`event_remove_session`](#event-remove-session), [`finalize`](#finalize), [`free_session`](#free-session), [`get_clientbanner`](#get-clientbanner), [`get_error`](#get-error), [`get_fd`](#get-fd), [`get_fingerprint_hash`](#get-fingerprint-hash), [`get_publickey_hash`](#get-publickey-hash), [`handle_key_exchange`](#handle-key-exchange), [`init`](#init), [`is_connected`](#is-connected), [`key_free`](#key-free), [`key_type`](#key-type), [`key_type_to_char`](#key-type-to-char), [`new_session`](#new-session), [`options_set`](#options-set), [`pki_export_privkey_file`](#pki-export-privkey-file), [`pki_generate`](#pki-generate), [`pki_import_privkey_file`](#pki-import-privkey-file), [`set_auth_methods`](#set-auth-methods), [`set_blocking`](#set-blocking), [`set_channel_callbacks`](#set-channel-callbacks), [`set_server_callbacks`](#set-server-callbacks), [`string_free_char`](#string-free-char), [`threads_get_pthread`](#threads-get-pthread), [`threads_set_callbacks`](#threads-set-callbacks), [`version`](#version), [`version_int`](#version-int)

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

*libssh/libssh.odin:51*

### `Auth_None_Proc`

```odin
Auth_None_Proc :: #type proc "c" (session: Session, user: cstring, userdata: rawptr) -> c.int
```

*libssh/libssh.odin:131*

### `Auth_Password_Proc`

```odin
Auth_Password_Proc :: #type proc "c" (session: Session, user, password: cstring, userdata: rawptr) -> c.int
```

*libssh/libssh.odin:132*

### `Auth_Pubkey_Proc`

```odin
Auth_Pubkey_Proc :: #type proc "c" (session: Session, user: cstring, pubkey: Key, signature_state: c.char, userdata: rawptr) -> c.int
```

*libssh/libssh.odin:133*

### `Bind`

```odin
Bind :: distinct rawptr
Event :: distinct rawptr
Key :: distinct rawptr
Threads_Callbacks :: distinct rawptr

// Builds a libssh version integer the way its SSH_VERSION_INT macro does.
version_int :: proc "contextless" (major, minor, micro: int) -> c.int {
	return c.int(major << 16 | minor << 8 | micro)
}
```

*libssh/libssh.odin:20*

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

*libssh/libssh.odin:79*

### `Channel`

```odin
Channel :: distinct rawptr
Bind :: distinct rawptr
Event :: distinct rawptr
Key :: distinct rawptr
Threads_Callbacks :: distinct rawptr

// Builds a libssh version integer the way its SSH_VERSION_INT macro does.
version_int :: proc "contextless" (major, minor, micro: int) -> c.int {
	return c.int(major << 16 | minor << 8 | micro)
}
```

*libssh/libssh.odin:19*

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

*libssh/libssh.odin:167*

### `Channel_Close_Proc`

```odin
Channel_Close_Proc :: #type proc "c" (session: Session, channel: Channel, userdata: rawptr)
```

*libssh/libssh.odin:138*

### `Channel_Data_Proc`

```odin
Channel_Data_Proc :: #type proc "c" (session: Session, channel: Channel, data: rawptr, len: u32, is_stderr: c.int, userdata: rawptr) -> c.int
```

*libssh/libssh.odin:136*

### `Channel_Env_Proc`

```odin
Channel_Env_Proc :: #type proc "c" (session: Session, channel: Channel, name, value: cstring, userdata: rawptr) -> c.int
```

*libssh/libssh.odin:142*

### `Channel_Eof_Proc`

```odin
Channel_Eof_Proc :: #type proc "c" (session: Session, channel: Channel, userdata: rawptr)
```

*libssh/libssh.odin:137*

### `Channel_Exec_Proc`

```odin
Channel_Exec_Proc :: #type proc "c" (session: Session, channel: Channel, command: cstring, userdata: rawptr) -> c.int
```

*libssh/libssh.odin:143*

### `Channel_Open_Session_Proc`

```odin
Channel_Open_Session_Proc :: #type proc "c" (session: Session, userdata: rawptr) -> Channel
```

*libssh/libssh.odin:134*

### `Channel_Pty_Proc`

```odin
Channel_Pty_Proc :: #type proc "c" (session: Session, channel: Channel, term: cstring, width, height, pxwidth, pxheight: c.int, userdata: rawptr) -> c.int
```

*libssh/libssh.odin:139*

### `Channel_Shell_Proc`

```odin
Channel_Shell_Proc :: #type proc "c" (session: Session, channel: Channel, userdata: rawptr) -> c.int
```

*libssh/libssh.odin:140*

### `Channel_Window_Change_Proc`

```odin
Channel_Window_Change_Proc :: #type proc "c" (session: Session, channel: Channel, width, height, pxwidth, pxheight: c.int, userdata: rawptr) -> c.int
```

*libssh/libssh.odin:141*

### `Event`

```odin
Event :: distinct rawptr
Key :: distinct rawptr
Threads_Callbacks :: distinct rawptr

// Builds a libssh version integer the way its SSH_VERSION_INT macro does.
version_int :: proc "contextless" (major, minor, micro: int) -> c.int {
	return c.int(major << 16 | minor << 8 | micro)
}
```

*libssh/libssh.odin:21*

### `Key`

```odin
Key :: distinct rawptr
Threads_Callbacks :: distinct rawptr

// Builds a libssh version integer the way its SSH_VERSION_INT macro does.
version_int :: proc "contextless" (major, minor, micro: int) -> c.int {
	return c.int(major << 16 | minor << 8 | micro)
}
```

*libssh/libssh.odin:22*

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

*libssh/libssh.odin:120*

### `Pubkey_Hash_Type`

```odin
Pubkey_Hash_Type :: enum c.int {
	Sha1   = 0,
	Md5    = 1,
	Sha256 = 2,
}
```

*libssh/libssh.odin:107*

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

*libssh/libssh.odin:61*

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

*libssh/libssh.odin:151*

### `Session`

```odin
Session :: distinct rawptr
Channel :: distinct rawptr
Bind :: distinct rawptr
Event :: distinct rawptr
Key :: distinct rawptr
Threads_Callbacks :: distinct rawptr

// Builds a libssh version integer the way its SSH_VERSION_INT macro does.
version_int :: proc "contextless" (major, minor, micro: int) -> c.int {
	return c.int(major << 16 | minor << 8 | micro)
}
```

*libssh/libssh.odin:18*

### `Session_Option`

```odin
Session_Option :: enum c.int {
	Host    = 0,
	Port    = 1,
	Timeout = 9, // seconds, as a uint64
}
```

Only the entries we use; the ordering matches libssh's enum ssh_options_e.

*libssh/libssh.odin:114*

### `Threads_Callbacks`

```odin
Threads_Callbacks :: distinct rawptr

// Builds a libssh version integer the way its SSH_VERSION_INT macro does.
version_int :: proc "contextless" (major, minor, micro: int) -> c.int {
	return c.int(major << 16 | minor << 8 | micro)
}
```

*libssh/libssh.odin:23*

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

*libssh/libssh.odin:48*

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

*libssh/libssh.odin:74*

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

*libssh/libssh.odin:75*

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

*libssh/libssh.odin:71*

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

*libssh/libssh.odin:72*

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

*libssh/libssh.odin:73*

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

*libssh/libssh.odin:70*

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

*libssh/libssh.odin:49*

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

*libssh/libssh.odin:47*

### `MIN_MAJOR`

```odin
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
```

The oldest libssh otsh will run against.

0.10.6 is where the fix for CVE-2023-48795 ("Terrapin", a prefix-truncation
attack on the SSH transport) landed, along with the strict-kex extension that
makes the fix effective. Running a server on anything older is not something
this package will do quietly.

This is a floor, not an endorsement: libssh is a separate project with its own
advisories, and being above this line does not mean you are patched. Track
https://www.libssh.org/security/ and keep the system library current.

*libssh/libssh.odin:40*

### `MIN_MICRO`

```odin
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
```

*libssh/libssh.odin:42*

### `MIN_MINOR`

```odin
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
```

*libssh/libssh.odin:41*

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

*libssh/libssh.odin:46*

## Procedures

### `bind_accept`

```odin
proc(b: Bind, s: Session) -> c.int
```

*libssh/libssh.odin:210* · C: `ssh_bind_accept`

### `bind_free`

```odin
proc(b: Bind)
```

*libssh/libssh.odin:204* · C: `ssh_bind_free`

### `bind_listen`

```odin
proc(b: Bind) -> c.int
```

*libssh/libssh.odin:208* · C: `ssh_bind_listen`

### `bind_new`

```odin
proc() -> Bind
```

bind (listening socket)

*libssh/libssh.odin:202* · C: `ssh_bind_new`

### `bind_options_set`

```odin
proc(b: Bind, opt: Bind_Option, value: rawptr) -> c.int
```

*libssh/libssh.odin:206* · C: `ssh_bind_options_set`

### `channel_close`

```odin
proc(ch: Channel) -> c.int
```

*libssh/libssh.odin:260* · C: `ssh_channel_close`

### `channel_free`

```odin
proc(ch: Channel)
```

*libssh/libssh.odin:258* · C: `ssh_channel_free`

### `channel_is_eof`

```odin
proc(ch: Channel) -> c.int
```

*libssh/libssh.odin:266* · C: `ssh_channel_is_eof`

### `channel_is_open`

```odin
proc(ch: Channel) -> c.int
```

*libssh/libssh.odin:264* · C: `ssh_channel_is_open`

### `channel_new`

```odin
proc(s: Session) -> Channel
```

channel

*libssh/libssh.odin:256* · C: `ssh_channel_new`

### `channel_request_send_exit_status`

```odin
proc(ch: Channel, status: c.int) -> c.int
```

*libssh/libssh.odin:270* · C: `ssh_channel_request_send_exit_status`

### `channel_send_eof`

```odin
proc(ch: Channel) -> c.int
```

*libssh/libssh.odin:262* · C: `ssh_channel_send_eof`

### `channel_write`

```odin
proc(ch: Channel, data: rawptr, len: u32) -> c.int
```

*libssh/libssh.odin:268* · C: `ssh_channel_write`

### `clean_pubkey_hash`

```odin
proc(hash: ^[^]u8)
```

*libssh/libssh.odin:294* · C: `ssh_clean_pubkey_hash`

### `disconnect`

```odin
proc(s: Session)
```

*libssh/libssh.odin:218* · C: `ssh_disconnect`

### `event_add_session`

```odin
proc(e: Event, s: Session) -> c.int
```

*libssh/libssh.odin:248* · C: `ssh_event_add_session`

### `event_dopoll`

```odin
proc(e: Event, timeout_ms: c.int) -> c.int
```

*libssh/libssh.odin:252* · C: `ssh_event_dopoll`

### `event_free`

```odin
proc(e: Event)
```

*libssh/libssh.odin:246* · C: `ssh_event_free`

### `event_new`

```odin
proc() -> Event
```

event loop

*libssh/libssh.odin:244* · C: `ssh_event_new`

### `event_remove_session`

```odin
proc(e: Event, s: Session) -> c.int
```

*libssh/libssh.odin:250* · C: `ssh_event_remove_session`

### `finalize`

```odin
proc() -> c.int
```

*libssh/libssh.odin:194* · C: `ssh_finalize`

### `free_session`

```odin
proc(s: Session)
```

*libssh/libssh.odin:216* · C: `ssh_free`

### `get_clientbanner`

```odin
proc(s: Session) -> cstring
```

*libssh/libssh.odin:234* · C: `ssh_get_clientbanner`

### `get_error`

```odin
proc(s: rawptr) -> cstring
```

*libssh/libssh.odin:232* · C: `ssh_get_error`

### `get_fd`

```odin
proc(s: Session) -> c.int
```

*libssh/libssh.odin:240* · C: `ssh_get_fd`

### `get_fingerprint_hash`

```odin
proc(type: Pubkey_Hash_Type, hash: [^]u8, len: c.size_t) -> cstring
```

*libssh/libssh.odin:292* · C: `ssh_get_fingerprint_hash`

### `get_publickey_hash`

```odin
proc(k: Key, type: Pubkey_Hash_Type, hash: ^[^]u8, hlen: ^c.size_t) -> c.int
```

fingerprints (public-key identity)

*libssh/libssh.odin:290* · C: `ssh_get_publickey_hash`

### `handle_key_exchange`

```odin
proc(s: Session) -> c.int
```

*libssh/libssh.odin:220* · C: `ssh_handle_key_exchange`

### `init`

```odin
proc() -> c.int
```

*libssh/libssh.odin:192* · C: `ssh_init`

### `is_connected`

```odin
proc(s: Session) -> c.int
```

*libssh/libssh.odin:230* · C: `ssh_is_connected`

### `key_free`

```odin
proc(k: Key)
```

*libssh/libssh.odin:282* · C: `ssh_key_free`

### `key_type`

```odin
proc(k: Key) -> Keytype
```

*libssh/libssh.odin:284* · C: `ssh_key_type`

### `key_type_to_char`

```odin
proc(t: Keytype) -> cstring
```

*libssh/libssh.odin:286* · C: `ssh_key_type_to_char`

### `new_session`

```odin
proc() -> Session
```

session

*libssh/libssh.odin:214* · C: `ssh_new`

### `options_set`

```odin
proc(s: Session, opt: Session_Option, value: rawptr) -> c.int
```

*libssh/libssh.odin:228* · C: `ssh_options_set`

### `pki_export_privkey_file`

```odin
proc(privkey: Key, passphrase: cstring, auth_fn: rawptr, auth_data: rawptr, filename: cstring) -> c.int
```

*libssh/libssh.odin:278* · C: `ssh_pki_export_privkey_file`

### `pki_generate`

```odin
proc(type: Keytype, parameter: c.int, pkey: ^Key) -> c.int
```

pki (host key generation)

*libssh/libssh.odin:276* · C: `ssh_pki_generate`

### `pki_import_privkey_file`

```odin
proc(filename: cstring, passphrase: cstring, auth_fn: rawptr, auth_data: rawptr, pkey: ^Key) -> c.int
```

*libssh/libssh.odin:280* · C: `ssh_pki_import_privkey_file`

### `set_auth_methods`

```odin
proc(s: Session, methods: c.int)
```

*libssh/libssh.odin:222* · C: `ssh_set_auth_methods`

### `set_blocking`

```odin
proc(s: Session, blocking: c.int)
```

*libssh/libssh.odin:226* · C: `ssh_set_blocking`

### `set_channel_callbacks`

```odin
proc(ch: Channel, cb: ^Channel_Callbacks) -> c.int
```

*libssh/libssh.odin:272* · C: `ssh_set_channel_callbacks`

### `set_server_callbacks`

```odin
proc(s: Session, cb: ^Server_Callbacks) -> c.int
```

*libssh/libssh.odin:224* · C: `ssh_set_server_callbacks`

### `string_free_char`

```odin
proc(s: cstring)
```

*libssh/libssh.odin:296* · C: `ssh_string_free_char`

### `threads_get_pthread`

```odin
proc() -> Threads_Callbacks
```

*libssh/libssh.odin:198* · C: `ssh_threads_get_pthread`

### `threads_set_callbacks`

```odin
proc(cb: Threads_Callbacks) -> c.int
```

*libssh/libssh.odin:196* · C: `ssh_threads_set_callbacks`

### `version`

```odin
proc(req_version: c.int) -> cstring
```

Returns the runtime library version as text, or nil if the library is older than the (major<<16 | minor<<8 | micro) value passed in.

*libssh/libssh.odin:238* · C: `ssh_version`

### `version_int`

```odin
version_int :: proc "contextless" (major, minor, micro: int) -> c.int
```

Builds a libssh version integer the way its SSH_VERSION_INT macro does.

*libssh/libssh.odin:26*
