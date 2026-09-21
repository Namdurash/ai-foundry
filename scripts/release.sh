#!/usr/bin/env bash
#
# scripts/release.sh — cut a release, tap included.
#
# A RELEASE IS NOT A TAG. `aif` is installed with `brew install
# Namdurash/tap/aif`, so a tag the tap does not point at is a version nobody
# can install: `brew upgrade` keeps handing out the previous one and says
# nothing about it. That is exactly how 0.5.0 shipped — the tag went out, the
# formula stayed on 0.4.2, and the only machine running the new code was the
# one carrying `make link`'s symlink. The user found out from their own
# project, which is the worst place to find out.
#
# So the tap bump is not a step after the release. It is part of it, and this
# is the only supported way to cut one.
#
# The order is forced by GitHub: the tarball the formula has to hash does not
# exist until the tag is pushed. There is therefore a window where the tag is
# out and the tap is not, and the script is built for that window — every step
# checks whether it has already happened, so running it again with the same
# version resumes at the first thing that has not.
#
# usage: scripts/release.sh <version>   cut it, end to end
#        scripts/release.sh --verify    is the tap serving what is tagged?
#
# --verify is what `make check` runs. It is silent between releases (a version
# nobody has tagged owes the tap nothing) and starts failing the moment a tag
# exists that the formula does not serve.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REPO="Namdurash/ai-foundry"
TAP_NAME="namdurash/tap"
FORMULA="Formula/aif.rb"

say() { printf '  %s\n' "$*"; }
die() {
  printf 'release: %s\n' "$*" >&2
  exit 1
}

# The tap's working copy. AIF_TAP overrides it — for a test, or for a machine
# where brew keeps its taps somewhere unusual.
tap_dir() {
  if [ -n "${AIF_TAP:-}" ]; then
    printf '%s' "$AIF_TAP"
    return 0
  fi
  local base
  base="$(brew --repository 2>/dev/null)" || return 1
  [ -n "$base" ] || return 1
  printf '%s/Library/Taps/namdurash/homebrew-tap' "$base"
}

aif_version() { sed -n 's/^AIF_VERSION="\(.*\)"$/\1/p' "$ROOT/bin/aif" | head -1; }
set_version() { sed -n 's/^SET_VERSION=\(.*\)$/\1/p' "$ROOT/sets/claude/set.meta" | head -1; }
formula_version() { sed -n 's|.*/archive/refs/tags/v\(.*\)\.tar\.gz.*|\1|p' "$1" | head -1; }

# write_version <file> <sed-expression> — `sed -i` is not portable (FINDINGS #6).
write_version() {
  local f="$1" expr="$2" tmp
  tmp="$(mktemp "$(dirname "$f")/.aif-rel-XXXXXX")" || die "cannot write beside $f"
  sed "$expr" "$f" >"$tmp" && cat "$tmp" >"$f"
  rm -f "$tmp"
}

# --------------------------------------------------------------------------
# verify — the invariant, checkable on any machine
# --------------------------------------------------------------------------
verify() {
  local v tap f fv
  v="$(aif_version)"
  [ -n "$v" ] || die "cannot read AIF_VERSION from bin/aif"

  if ! git -C "$ROOT" rev-parse -q --verify "refs/tags/v$v" >/dev/null 2>&1; then
    printf 'release: %s is unreleased (no tag) — the tap owes it nothing yet\n' "$v"
    return 0
  fi

  tap="$(tap_dir)" || {
    printf 'release: no brew on this machine — the tap was not checked here\n'
    return 0
  }
  f="$tap/$FORMULA"
  if [ ! -f "$f" ]; then
    printf 'release: %s is not tapped here — not checked (brew tap %s)\n' "$TAP_NAME" "$TAP_NAME"
    return 0
  fi

  fv="$(formula_version "$f")"
  if [ "$fv" = "$v" ]; then
    printf 'release: v%s is tagged and the tap serves it\n' "$v"
    return 0
  fi
  printf 'release: v%s is tagged, the tap still serves %s — `brew install` hands out the old one\n' "$v" "${fv:-?}" >&2
  printf '         make release V=%s\n' "$v" >&2
  return 1
}

# --------------------------------------------------------------------------
# cut — the release itself
# --------------------------------------------------------------------------
cut_release() {
  local version="$1" tap formula branch sha tarball tmp try
  case "$version" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) die "version must look like 1.2.3, got '$version'" ;;
  esac

  # The tap first, before anything is committed or pushed: a release that
  # cannot finish is better refused than left half-out.
  tap="$(tap_dir)" || die "brew is not installed — the tap cannot be updated from here"
  formula="$tap/$FORMULA"
  [ -f "$formula" ] || die "$TAP_NAME is not tapped — run: brew tap $TAP_NAME"
  [ -z "$(git -C "$tap" status --porcelain)" ] || die "the tap has uncommitted changes — deal with those first"

  branch="$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null)"
  [ "$branch" = "main" ] || die "releases are cut from main, not '$branch'"

  printf '\nreleasing %s\n\n' "$version"

  # 1. both version markers. The bottle is a (CLI, set) pair and they are
  #    versioned separately; the formula's own test asserts they agree.
  if [ "$(aif_version)" != "$version" ]; then
    write_version "$ROOT/bin/aif" "s/^AIF_VERSION=\".*\"$/AIF_VERSION=\"$version\"/"
    say "bin/aif → $version"
  fi
  if [ "$(set_version)" != "$version" ]; then
    write_version "$ROOT/sets/claude/set.meta" "s/^SET_VERSION=.*$/SET_VERSION=$version/"
    say "sets/claude/set.meta → $version"
  fi
  [ "$(aif_version)" = "$version" ] || die "bin/aif still says $(aif_version)"
  [ "$(set_version)" = "$version" ] || die "set.meta still says $(set_version)"

  # 2. nothing ships that does not pass its own checks.
  say "make lint"
  (cd "$ROOT" && make lint >/dev/null) || die "lint is not clean"
  say "make check"
  (cd "$ROOT" && make check >/dev/null) || die "check is not green"

  # 3. the version bump, if it was one.
  if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    git -C "$ROOT" add -A bin/aif sets/claude/set.meta
    if [ -n "$(git -C "$ROOT" diff --cached --name-only)" ]; then
      git -C "$ROOT" commit -q -m "chore: release $version" || die "could not commit the bump"
      say "committed chore: release $version"
    fi
  fi
  [ -z "$(git -C "$ROOT" status --porcelain)" ] ||
    die "the working tree is dirty with something that is not the bump — commit or stash it"

  # 4. the tag, then main, then the tag's push. Each skipped if already done.
  if ! git -C "$ROOT" rev-parse -q --verify "refs/tags/v$version" >/dev/null 2>&1; then
    git -C "$ROOT" tag -a "v$version" -m "aif $version" || die "could not tag"
    say "tagged v$version"
  fi
  git -C "$ROOT" push -q origin main || die "could not push main"
  git -C "$ROOT" push -q origin "v$version" || die "could not push the tag"
  say "pushed main and v$version"

  # 5. the tarball GitHub builds from the tag we just pushed. It can take a
  #    moment to appear, which is a bad reason to fail a release.
  tarball="https://github.com/$REPO/archive/refs/tags/v$version.tar.gz"
  tmp="$(mktemp "${TMPDIR:-/tmp}/aif-release-XXXXXX")"
  try=1
  while [ "$try" -le 3 ]; do
    curl -fsSL -o "$tmp" "$tarball" && break
    try=$((try + 1))
    sleep 2
  done
  [ -s "$tmp" ] || {
    rm -f "$tmp"
    die "could not fetch $tarball — the tag is pushed, so re-run: make release V=$version"
  }
  sha="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"
  rm -f "$tmp"
  say "tarball sha256 $sha"

  # 6. the tap. Everything above is worthless to a user without this.
  write_version "$formula" "s|url \".*\"|url \"$tarball\"|"
  write_version "$formula" "s|sha256 \".*\"|sha256 \"$sha\"|"
  [ "$(formula_version "$formula")" = "$version" ] || die "the formula did not take the new url"

  if [ -n "$(git -C "$tap" status --porcelain)" ]; then
    git -C "$tap" add "$FORMULA"
    git -C "$tap" commit -q -m "feat: point aif at the v$version tarball" ||
      die "could not commit the formula"
    git -C "$tap" push -q origin HEAD || die "the formula is committed but NOT pushed — push it by hand"
    say "tap → v$version, pushed"
  else
    say "tap already served v$version"
  fi

  printf '\nreleased %s\n' "$version"
  printf '  install:  brew update && brew upgrade %s/aif\n' "$TAP_NAME"
  printf '  a clone on PATH shadows the tap — `make unlink` first if `which aif` is a symlink here\n'
}

case "${1:-}" in
  --verify) verify ;;
  "" | -h | --help)
    sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) cut_release "$1" ;;
esac
