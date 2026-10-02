# ai-foundry — working rules

`aif` scaffolds an AI SDLC setup into an existing project. This file is the
short list of things that are easy to get wrong here and expensive to get wrong
once shipped.

## Releasing — a tag is not a release

`aif` is installed with `brew install Namdurash/tap/aif`. A tag that the tap's
formula does not point at is a version **nobody can install**: `brew upgrade`
keeps serving the previous one and reports nothing. 0.5.0 went out that way —
the tag was pushed, the formula stayed on 0.4.2, and the only machine running
the new code was the one with `make link`'s symlink on `PATH`.

So: **cutting a version means updating `Namdurash/homebrew-tap` in the same
breath.** One command does both halves:

```sh
make release V=0.5.1
```

- Never `git tag` a release by hand, and never stop at the tag.
- GitHub builds the tarball only after the tag is pushed, so the halves cannot
  be simultaneous. Every step checks whether it already happened — if the
  command stops between them, run it again with the same version.
  `scripts/check-release.sh` stops it at each step and runs it again, offline.
- `make check` ends with `scripts/release.sh --verify`: silent while a version
  is unreleased, failing as soon as a tag exists that the tap does not serve —
  except the version `make release` is cutting, named in `AIF_RELEASING`, or
  the re-run could never get past its own check (`docs/DEFECTS-6.md` #7).
- Both version markers move together: `AIF_VERSION` in `bin/aif` and
  `SET_VERSION` in `sets/claude/set.meta`. The formula's own test asserts they
  agree, because a release that bumps only the CLI ships last release's stations
  against this release's gates.
- The formula's `test do` block identifies the set by a file the release added
  **and** files it retired. Update it when a release changes the set's shape.

## The rest, in one line each

- **bash 3.2 is the floor** (stock macOS): no associative arrays, no `mapfile`,
  no `${var,,}`, no `sed -i`. `make check` runs the entry point under
  `/bin/bash` so a newer bash cannot hide an incompatibility.
- **`make lint` and `make check` before anything ships.** Both are fast and
  offline; `check` drives the whole worker with a fake station.
- **Gates run without `aif`.** Anything under `sets/*/gates/` must work in CI
  from a fresh checkout — it may not source `lib/`.
- **`.aif/project.json` is the project's; the templates still move.** `aif init`
  never rewrites it, so a change of aif's mind recorded in a template — a
  failure class retired, a check's phase, a cap — reaches an existing project
  only through `aif project upgrade`. A retired pattern goes in the template's
  `failure_classes.retired`, so `aif project check` can name it
  (`docs/DEFECTS-8.md` #1).
- **A runner is two files.** `sets/claude/project.templates/<r>.json` and
  `sets/claude/stacks/<r>.md` ship together — the fragment is what the worker
  appends to the plan and tests stations for a project of that `test.kind` —
  and `scripts/check-set.sh` fails on one without the other.
- **`docs/` is gitignored** except the defect logs, tracked deliberately, and
  `docs/CYCLE.md` + `docs/CYCLE.html`, which `make cycle` generates from the code
  — never edit them by hand; `make check` fails while they are stale.
  `docs/FINDINGS.md` is where a probed, non-obvious fact goes so nobody
  re-derives it.
- **Traps are per-process.** Arm one with `aif_trap_arm` and restore it with
  `aif_trap_restore`; a bare `trap -` in a helper takes the caller's handler
  with it (`docs/DEFECTS-3.md` #1).
