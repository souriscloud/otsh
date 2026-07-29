#+build windows
// The Windows half of perm_posix.odin.
//
// Both procedures are deliberately empty. Windows has no mode bits; who may
// read a file is decided by its ACL, and there is no ACL code here. Nothing
// checks, warns about, or tightens the permissions of the host key or the
// identity secret on Windows.
//
// Say it plainly: the private-key permission guarantee this package makes on
// POSIX — created 0600 with O_EXCL, verified afterwards, warned about if it is
// group- or world-readable — is WEAKER on Windows. The files inherit whatever
// the parent directory's ACL gives them. Keep them in a directory only the
// service account can read, and treat that as the whole of the protection.
//
// Implementing it would mean CreateFile with a SECURITY_ATTRIBUTES carrying an
// explicit DACL, plus GetSecurityInfo to audit an existing file. That is real
// work and it cannot be tested from here, so it is left undone rather than done
// blind.
package ssh

// Nothing to check without ACL code; see the file comment above.
warn_if_world_readable :: proc(path: string) {}

// Nothing to tighten without ACL code; see the file comment above.
@(private)
ensure_private_mode :: proc(path: string) {}
