// The version of the otsh packages.
//
// One number covers the whole set. `libssh`, `ssh`, `tui` and `sshtui` are four
// packages in one checkout, released together: an app points `-collection:otsh=`
// at a working tree, so what it pins is a git tag, not four independently
// versioned artefacts. Separate numbers would suggest the packages can be mixed
// across versions, and they cannot.
//
// Why here and not in a package of its own: a fifth package existing only to
// hold four constants would need its own entry in docs/tools/gen_api.py, its own
// reference page, and an import in every other package to carry an integer.
// `ssh` is the package the server lives in and the one anything network-facing
// already depends on. `sshtui` re-exports these in sshtui/version.odin — Odin
// has no re-export, so the aliases are written out — which is what makes them
// reachable from an app that imports only `otsh:sshtui`.
//
// `tui` does not carry them. That is a real gap: an app that imports `otsh:tui`
// alone, for a purely local TUI, has no version to assert against. It was judged
// not worth adding a package to a four-package set, and `tui` is the package
// least likely to break — no C boundary, no network, no threads.
//
// The scheme is 0.MINOR.PATCH, read the usual pre-1.0 way:
//
//	MINOR  may break your build or change behaviour you relied on. Read
//	       CHANGELOG.md before moving from one minor to the next.
//	PATCH  fixes and backwards-compatible additions only. Moving 0.1.0 to
//	       0.1.1 must never require you to change your code.
//
// So there is no compatibility promise across minors before 1.0. What there is
// instead: every removal gets an entry under Removed in CHANGELOG.md saying what
// went, why, and what to use now. docs/migrating.md carries the long versions.
//
// Assert against it at compile time if you need a particular API:
//
//	#assert(sshtui.VERSION_MAJOR == 0 && sshtui.VERSION_MINOR >= 1)
package ssh

// The first of the three numbers described above. Assert against it at
// compile time if your app needs a particular API:
//
// Example:
//
//	#assert(ssh.VERSION_MAJOR == 0 && ssh.VERSION_MINOR >= 1)
VERSION_MAJOR :: 0
VERSION_MINOR :: 4
VERSION_PATCH :: 0

// The same version as a string, for banners and log lines: "0.2.0".
//
// Written out rather than composed from the three constants above, because Odin
// has no compile-time integer-to-string. tests/version_test.odin asserts the two
// spellings agree, since a bumped triple beside a stale string is exactly the
// mistake a release makes.
VERSION :: "0.4.0"
