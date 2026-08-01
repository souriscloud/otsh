// The otsh version, re-exported.
//
// Odin has no re-export: an app that imports only `otsh:sshtui` cannot reach
// `ssh.VERSION` without importing `otsh:ssh` as well. Most apps import only this
// package, so the aliases are written out here. These are the same constants,
// not copies — ssh/version.odin defines them and explains what the number means.
package sshtui

import "../ssh"

VERSION_MAJOR :: ssh.VERSION_MAJOR
VERSION_MINOR :: ssh.VERSION_MINOR
VERSION_PATCH :: ssh.VERSION_PATCH
// The version as a string, for banners and log lines.
VERSION :: ssh.VERSION
