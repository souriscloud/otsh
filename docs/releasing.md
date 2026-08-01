# Releasing otsh

How a version of otsh gets cut. Written so somebody who has never done it can
follow it start to finish.

**This process has been executed zero times.** `v0.1.0` is the first tag, and it
was created by following the steps below in order — but no tag had ever been
pushed when this page was written, so the parts that only happen on GitHub (the
tag-gated CI matrix actually running, the release page rendering) are described
from the workflow file and GitHub's documented behaviour, not from having
watched them. Correct this paragraph the first time it is done for real.

## What a version means here

otsh is `0.MINOR.PATCH`, and the ordinary pre-1.0 reading applies:

| Bump | When | Promise |
| --- | --- | --- |
| **MINOR** — `0.1.0` to `0.2.0` | A public symbol was removed or renamed, a signature or a struct field changed meaning, or behaviour an app could reasonably have depended on is different | None. Apps may need edits. The changelog says which |
| **PATCH** — `0.1.0` to `0.1.1` | Bug fixes, new symbols, new `Config` fields with a working zero value, docs, examples, tooling | Recompiling against it must not require touching app code |

There is no MAJOR bump before 1.0; `VERSION_MAJOR` stays 0 until otsh is ready
to promise stability, which is a decision, not a milestone that arrives on its
own.

Two judgement calls worth naming, because they come up:

- **Adding a field to a public struct is a patch** as long as its zero value
  keeps the old behaviour. `Config.audit` and `Config.shutdown_seconds` are both
  shaped that way on purpose. If a new field's zero value changes what the
  program does, it is a minor.
- **Fixing a bug is a patch even when someone might have relied on the bug** —
  with one exception: if the old behaviour was documented, say so in the
  changelog under **Changed** and take the minor. `ids_equal("", "")` returning
  false is the kind of fix that would have earned a minor if otsh had had a
  released version at the time.

What an app pins is a git tag. `-collection:otsh=` points the Odin compiler at a
source tree, so there is no built artefact and no package registry — a consumer
does `git checkout v0.1.0` in their otsh checkout, or vendors it as a submodule
at that tag.

## Cutting a release

### 1. Decide the number

Read the commits since the last tag and apply the table above:

```sh
git log --oneline v0.1.0..HEAD
git log v0.1.0..HEAD          # the full messages; they are the material
```

Then check the public surface against what you concluded. The API reference is
generated, so a diff of it is a diff of the public API:

```sh
git diff v0.1.0..HEAD -- docs/api-ssh.md docs/api-tui.md docs/api-sshtui.md docs/api-libssh.md
```

A removed `###` entry is a removed public symbol and therefore a minor, whatever
the commit messages implied.

### 2. Update the version constants

They live in `ssh/version.odin`, which is the only file to edit:

<!-- check:decls illustrative snapshot of the constants' shape at the v0.1.0 cut; current values are in ssh/version.odin -->
```odin
VERSION_MAJOR :: 0
VERSION_MINOR :: 1
VERSION_PATCH :: 0

VERSION :: "0.1.0"
```

`sshtui` aliases all four in `sshtui/version.odin`, so nothing there needs
touching. The string is written out by hand because Odin has no compile-time
integer-to-string; `tests/version_test.odin` fails if the two spellings
disagree, which is the whole reason it exists.

`tui` and `libssh` carry no version constant. That is deliberate and is
explained in the comment at the top of `ssh/version.odin`.

### 3. Update the changelog

In [CHANGELOG.md](../CHANGELOG.md): rename `## Unreleased` to
`## MINOR.PATCH — YYYY-MM-DD` and open a fresh empty `## Unreleased` above it.

The rules that matter more than the format:

- **Every entry traces to a commit.** If you cannot point at one, it does not go
  in. The commit messages in this repository are long on purpose and are the
  source material; the changelog is an index into them, not a retelling.
- **Lead with what changes for someone using the package.** A removed symbol,
  a behaviour change, a fixed bug they could have hit. Internal refactors,
  test-suite work and doc corrections go last or not at all.
- **Numbers come from measurements that were actually taken.** They are in the
  commit messages. Do not round them into something rhetorical.
- **Every removal gets a migration note** under **Removed**: what went, why, and
  what to do instead — even if the answer is "nothing". If it needs more than a
  paragraph, write the long version in [docs/migrating.md](migrating.md) and
  link to it.

### 4. Make everything green

All of this runs locally. None of it needs a push.

```sh
./check.sh
```

6 builds, the full test suite and 2 doc checks. Non-zero exit means stop.

```sh
for pkg in libssh ssh tui sshtui; do
  odin check "$pkg" -collection:otsh=. -target:windows_amd64 -no-entry-point
done
for ex in examples/*/; do
  odin check "$ex" -collection:otsh=. -target:windows_amd64
done
```

The same two loops again with `-target:freebsd_amd64`. These are the steps the
Linux CI job runs, and they are the only automated statement about FreeBSD that
exists — that is how `tui/local.odin` came to hold the Linux `TIOCGWINSZ` value
there. Run them before a tag even when nothing platform-specific changed.

```sh
docker run --rm -v "$PWD":/repo --workdir /repo rhysd/actionlint:latest -color
```

`actionlint` over `.github/workflows/ci.yml`. No output means no findings. Only
needed if the workflow changed, but it costs seconds.
[Getting started](getting-started.md#validating-ci-locally) has the `act`
invocation too, for actually executing a job locally.

If the release touches the SSH or input path, also run one real session by hand
against an example — `./build.sh examples/tracker && ./tracker`, then `ssh -p
2222 localhost` from another terminal. Frames render, keystrokes land, `q`
quits, and the terminal comes back. Nothing in `check.sh` opens a socket.

### 5. Commit, tag, push

```sh
git add -A
git commit -m "Release 0.1.0"
git tag -a v0.1.0 -m "otsh 0.1.0 — <one paragraph on what this release is>"
git push origin main
git push origin v0.1.0
```

Tags are `v` followed by the version: `v0.1.0`. Annotated (`-a`), not
lightweight, because the message is part of the record and `git describe` reads
it. The message is a paragraph, not a changelog — the changelog is in the repo.

Push the branch before the tag. A tag pointing at a commit GitHub has not seen
yet produces a CI run against a commit nobody can look at.

### 6. What the tag triggers

`.github/workflows/ci.yml` gates its expensive jobs on the ref:

```yaml
on:
  push:
    branches: [main]
    tags: ['v*']
```

```yaml
if: github.event_name != 'push' || startsWith(github.ref, 'refs/tags/')
```

- **Every push and pull request** runs `build` (Linux: all packages, all five
  examples, the full test suite, and both the Windows and FreeBSD
  cross-type-checks) and `docs`.
- **A `v*` tag, a manual dispatch, or the Monday cron** additionally runs `macos`
  and `windows` — the full matrix.

That gating is about money, not confidence. GitHub bills macOS runner minutes at
10x and Windows at 2x against a private repository's allowance, and the first
real run cost 47 billed minutes, 72% of it vcpkg rebuilding libssh and OpenSSL
from source. Routine pushes cost about 3. A release is exactly the moment worth
paying the other 44 for, which is why the tag is in the trigger list.

**The `windows` job is `continue-on-error: true`.** It will not fail the run
even when it is red, so read its result rather than trusting the checkmark.
Every step in it was reproduced by hand on physical Windows 11 hardware on
2026-07-31, which is why the job is worth having; whether the hosted runner
agrees is a separate question. Flip it to blocking once it has been green on
real CI a few times.

Wait for the matrix before publishing the release. If it is red, delete the tag
(`git push origin :refs/tags/v0.1.0`), fix, and re-tag — a tag that nobody has
consumed yet is cheap to move, and a released version that does not build is
not.

### 7. Publish the GitHub release

```sh
gh release create v0.1.0 \
  --title "otsh 0.1.0" \
  --notes-file <(sed -n '/^## 0\.1\.0 /,/^## /p' CHANGELOG.md | sed '$d')
```

Or paste that section by hand at
`https://github.com/souriscloud/otsh/releases/new`. Either way the release notes
are the changelog section for that version, not a second summary written from
memory.

There are no binaries to attach. otsh is consumed as source, so the source
tarball GitHub generates from the tag is the whole artefact.

Mark it a pre-release for as long as `VERSION_MAJOR` is 0.

## Pre-release checklist

- [ ] `git log <last tag>..HEAD` read, bump decided against the table above
- [ ] `git diff <last tag>..HEAD -- docs/api-*.md` reviewed for removed symbols
- [ ] `ssh/version.odin` bumped, string and triple agreeing
- [ ] `CHANGELOG.md`: `## Unreleased` renamed and dated, fresh empty one opened
- [ ] Every changelog entry traces to a commit
- [ ] Removals have a migration note; long ones are in `docs/migrating.md`
- [ ] `python3 docs/tools/gen_api.py` re-run if any doc comment changed
- [ ] `./check.sh` green
- [ ] Windows and FreeBSD cross-type-checks clean
- [ ] `actionlint` clean, if the workflow changed
- [ ] One real SSH session driven by hand, if the SSH or input path changed
- [ ] Version claims in `README.md` and `docs/` still true (test counts,
      platform claims, requirements — these drift, and a release is when
      somebody reads them)
- [ ] Committed, tagged with an annotated `v*` tag, branch pushed before the tag
- [ ] Full CI matrix green — including reading the `windows` job, which cannot
      fail the run
- [ ] GitHub release published from the changelog section, marked pre-release

## A note on what CI has and has not done

CI has run on GitHub: the first push on 2026-08-01 was green across all four
jobs, Windows included, and the billed-minute figures in
`.github/workflows/ci.yml`'s header come from it. Comments elsewhere claiming
the hosted Windows job had never run were written on a branch cut before that
push and have been corrected.

What nobody has watched yet is a `v*` tag driving the full matrix. Pushes to
`main` only run the Linux and docs jobs; the macOS and Windows jobs are gated
to tags, the weekly schedule and manual dispatch. So the first release tag is
also the first time the tag trigger itself is exercised — if the matrix does
not start, check the `on.push.tags` filter before assuming the jobs failed.
