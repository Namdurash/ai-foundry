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
- `make check` ends with `scripts/release.sh --verify`: silent while a version
  is unreleased, failing as soon as a tag exists that the tap does not serve.
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
- **`docs/` is gitignored** except `docs/DEFECTS-3.md`, which is tracked
  deliberately. `docs/FINDINGS.md` is where a probed, non-obvious fact goes so
  nobody re-derives it.
- **Traps are per-process.** Arm one with `aif_trap_arm` and restore it with
  `aif_trap_restore`; a bare `trap -` in a helper takes the caller's handler
  with it (`docs/DEFECTS-3.md` #1).
