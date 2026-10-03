#!/usr/bin/env bash
#
# scripts/check-release.sh — `make release`, stopped at each step it can stop
# at once the tag exists, then run again. OFFLINE.
#
# A release is two halves that cannot happen at once — the tag, then the tap
# pointed at the tarball GitHub builds from it — and scripts/release.sh
# promises that a run which stops in between is finished by running it again
# with the same version. Cutting 0.10.0 it was not (docs/DEFECTS.md 6.7), and
# nothing short of GitHub failing a push had ever exercised the promise. Here
# it is exercised against stand-ins:
#
#   - origin and the tap's origin are bare repos in a sandbox; a push to one is
#     refused while its `refuse` file names the ref, as GitHub's 500 refused
#     main on 2026-09-29;
#   - the tap is a clone of its origin, handed to the script through AIF_TAP;
#   - curl is a script ahead of the real one on PATH that serves `git archive`
#     of the tag from the stand-in origin — so only once the tag is pushed
#     there, as GitHub builds the tarball only then — or fails, or sends a
#     piece and fails, when told to;
#   - the repository is this checkout's release.sh and version markers, with a
#     Makefile whose lint is nothing and whose check is the part of ours that
#     stopped the re-run, `release.sh --verify`. Ours would run this script
#     again from inside itself.
#
# What it proves:
#   0  nothing in the way: one run releases; a second changes nothing
#   1  origin refuses main once the tag is made (0.10.0's case): the re-run
#      finishes it, and --verify still fails that state for anyone but the run
#      cutting that version
#   2  origin takes main and refuses the tag: the re-run finishes it
#   3  the tag is out and GitHub has no tarball yet: the re-run finishes it
#   4  a tarball cut short on every try is not hashed into the formula
#   5  the formula is committed and the tap refuses the push: the re-run pushes
#      it, rather than calling a tap served that is served only here
#   6  main is rebased under a tag that never left this machine: the tag is
#      refused, not published; dropped, the re-run tags main and finishes
#   7  a tag made by hand before the bump is refused, not published
#
# Run by `make check`. Requires git, make and shasum. No network, no brew, no
# real tap.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REPO="Namdurash/ai-foundry"

for tool in git make shasum; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'check-release: %s not found — cannot run\n' "$tool"
    exit 1
  }
done

fails=0
ok() { printf '  ✓ %s\n' "$1"; }
bad() {
  printf '  ✗ %s\n' "$1"
  fails=$((fails + 1))
}
eq() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2', wanted '$3'"; fi
}

S="$(mktemp -d "${TMPDIR:-/tmp}/aif-check-release-XXXXXX")"
OUT="$S/out"
mkdir -p "$OUT"
printf '\nrelease, stopped and run again (sandbox: %s)\n' "$S"

# `make release` runs this inside its own `make check`, naming the real version
# in AIF_RELEASING, and a developer's AIF_TAP points at a real tap. Neither may
# reach the runs below.
unset AIF_RELEASING AIF_TAP

# ============================================================== stand-ins ====
# origin and the tap's origin. A hook runs inside its bare repo, so `refuse`
# sits there: a case pattern of the refs to turn away.
for o in origin tap-origin; do
  git init -q --bare "$S/$o.git"
  git -C "$S/$o.git" symbolic-ref HEAD refs/heads/main
  cat >"$S/$o.git/hooks/pre-receive" <<'HOOK'
#!/bin/sh
[ -f refuse ] || exit 0
pat="$(cat refuse)"
while read -r _ _ ref; do
  case "$ref" in $pat) echo "Internal Server Error" >&2 && exit 1 ;; esac
done
exit 0
HOOK
  chmod +x "$S/$o.git/hooks/pre-receive"
done
refuse() { printf '%s\n' "$2" >"$S/$1.git/refuse"; } # refuse <origin|tap-origin> <ref pattern>
admit() { rm -f "${S:?}/$1.git/refuse"; }

# GitHub's tarball endpoint. sleep beside it is a no-op: the script waits
# between tries at the tarball, and nothing here is helped by waiting.
mkdir -p "$S/bin"
cat >"$S/bin/curl" <<'CURL'
#!/bin/sh
S="$(cd "$(dirname "$0")/.." && pwd -P)"
out='' url=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2" && shift 2 ;;
    -*) shift ;;
    *) url="$1" && shift ;;
  esac
done
case "$url" in
  https://github.com/Namdurash/ai-foundry/archive/refs/tags/v*.tar.gz) ;;
  *) echo "curl: (6) the stand-in serves release tarballs, not $url" >&2 && exit 6 ;;
esac
tag="${url##*/}"
tag="${tag%.tar.gz}"
archive() { git -C "$S/origin.git" archive --format=tar.gz --prefix="ai-foundry-${tag#v}/" "$tag" 2>/dev/null; }
if [ -f "$S/github-down" ]; then
  echo "curl: (22) The requested URL returned error: 502" >&2
  exit 22
fi
if [ -f "$S/github-flaky" ]; then
  archive | head -c 64 >"$out"
  echo "curl: (18) transfer closed with outstanding read data remaining" >&2
  exit 18
fi
archive >"$out" || {
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
}
CURL
printf '#!/bin/sh\nexit 0\n' >"$S/bin/sleep"
chmod +x "$S/bin/curl" "$S/bin/sleep"
export PATH="$S/bin:$PATH"

# The repository, with the release before as its history: tagged and pushed.
R="$S/repo"
mkdir -p "$R/scripts" "$R/bin" "$R/sets/claude"
cp "$ROOT/scripts/release.sh" "$R/scripts/"
cp "$ROOT/bin/aif" "$R/bin/"
cp "$ROOT/sets/claude/set.meta" "$R/sets/claude/"
printf 'lint:\n\t@true\ncheck:\n\t@/bin/bash scripts/release.sh --verify\n' >"$R/Makefile"
git -C "$R" init -q
git -C "$R" symbolic-ref HEAD refs/heads/main
git -C "$R" config user.email release@aif
git -C "$R" config user.name "Release"
git -C "$R" add -A
git -C "$R" commit -qm "the release before"
v="$(sed -n 's/^AIF_VERSION="\(.*\)"$/\1/p' "$R/bin/aif" | head -1)"
git -C "$R" tag -a "v$v" -m "aif $v"
git -C "$R" remote add origin "$S/origin.git"
git -C "$R" push -q origin main "v$v"

# served_sha <version> — the hash of what GitHub serves for it, asked of the
# stand-in the way the script asks.
served_sha() {
  "$S/bin/curl" -fsSL -o "$S/served.tar.gz" "https://github.com/$REPO/archive/refs/tags/v$1.tar.gz" &&
    shasum -a 256 "$S/served.tar.gz" | cut -d' ' -f1
}

# The tap, serving the release before.
T="$S/tap"
mkdir -p "$T/Formula"
cat >"$T/Formula/aif.rb" <<RUBY
class Aif < Formula
  desc "Put an existing project on AI SDLC rails"
  homepage "https://github.com/$REPO"
  url "https://github.com/$REPO/archive/refs/tags/v$v.tar.gz"
  sha256 "$(served_sha "$v")"
  license "MIT"
end
RUBY
git -C "$T" init -q
git -C "$T" symbolic-ref HEAD refs/heads/main
git -C "$T" config user.email tap@aif
git -C "$T" config user.name "Tap"
git -C "$T" add -A
git -C "$T" commit -qm "point aif at v$v"
git -C "$T" remote add origin "$S/tap-origin.git"
git -C "$T" push -q -u origin main >/dev/null
export AIF_TAP="$T"

# ================================================================ helpers ====
# release <version> <label> — `make release V=<version>`, as the Makefile runs
# it. Leaves the exit status in rc and the output in $OUT/<label>.
release() {
  rc=0
  /bin/bash "$R/scripts/release.sh" "$1" >"$OUT/$2" 2>&1 || rc=$?
}
said() { grep -cF -- "$2" "$OUT/$1"; } # said <label> <text> — lines of that run carrying it

# verify [releasing] — the last line of `make check`, run as a developer runs
# it (or as a release cutting <releasing> does): "<exit>|<first line>".
verify() {
  local rc=0 says
  says="$(cd "$R" && AIF_RELEASING="${1:-}" /bin/bash scripts/release.sh --verify 2>&1)" || rc=$?
  printf '%s|%s' "$rc" "$(printf '%s\n' "$says" | head -1)"
}

# What the tap serves: its origin's formula, which is what `brew update`
# fetches — and this machine's copy, which is what --verify reads.
formula_version() { sed -n 's|.*/archive/refs/tags/v\(.*\)\.tar\.gz.*|\1|p'; }
tap_serves() { git -C "$S/tap-origin.git" show main:Formula/aif.rb | formula_version; }
tap_sha() { git -C "$S/tap-origin.git" show main:Formula/aif.rb | sed -n 's|.*sha256 "\(.*\)".*|\1|p'; }
tap_here() { formula_version <"$T/Formula/aif.rb"; }
tap_untouched() { # "<served>|<local HEAD is origin's>|<local changes>"
  printf '%s|%s|%s' "$(tap_serves)" \
    "$([ "$(git -C "$T" rev-parse HEAD)" = "$(git -C "$S/tap-origin.git" rev-parse main)" ] && echo same)" \
    "$(git -C "$T" status --porcelain)"
}

# released <version> — the end state, seen from outside this machine: origin
# has main and the tag on it, and the tap's origin points at the tag's tarball
# by the hash of what GitHub serves for it.
released() {
  eq "origin has main" "$(git -C "$S/origin.git" rev-parse main)" "$(git -C "$R" rev-parse main)"
  eq "origin has v$1, on main" \
    "$(git -C "$S/origin.git" rev-parse -q --verify "refs/tags/v$1^{commit}")" "$(git -C "$R" rev-parse main)"
  eq "the tap's origin serves v$1" "$(tap_serves)" "$1"
  eq "by the hash of the tarball GitHub serves for it" "$(tap_sha)" "$(served_sha "$1")"
  eq "--verify: green" "$(verify)" "0|release: v$1 is tagged and the tap serves it"
}

next() { printf '%s.%s' "${1%.*}" "$((${1##*.} + 1))"; }

# ============================================================== scenarios ====
prev="$v" v="$(next "$v")"
printf '\n0. nothing in the way — %s\n' "$v"
eq "the release before is out and served" "$(verify)|$(tap_serves)" "0|release: v$prev is tagged and the tap serves it|$prev"
release "$v" 0a
eq "one run releases it" "$rc|$(said 0a "tap → v$v, pushed")" "0|1"
released "$v"
release "$v" 0b
eq "a second run changes nothing, and says so" "$rc|$(said 0b "tap already served v$v")" "0|1"

prev="$v" v="$(next "$v")"
printf '\n1. origin refuses main once the tag is made, as for 0.10.0 — %s\n' "$v"
refuse origin refs/heads/main
release "$v" 1a
eq "the run stops at main, and says to run it again" \
  "$rc|$(said 1a "could not push main — re-run: make release V=$v")" "1|1"
eq "the tag is on this machine only" "$(git -C "$R" tag -l "v$v")|$(git -C "$S/origin.git" tag -l "v$v")" "v$v|"
eq "--verify fails it, as it always did" \
  "$(verify)" "1|release: v$v is tagged, the tap still serves $prev — \`brew install\` hands out the old one"
eq "for a release cutting another version too" \
  "$(verify 99.0.0)" "1|release: v$v is tagged, the tap still serves $prev — \`brew install\` hands out the old one"
eq "not for the release cutting this one" \
  "$(verify "$v")" "0|release: v$v is tagged and being released — the tap is the last step of this run"
admit origin
release "$v" 1b
eq "the same command again finishes it" "$rc" "0"
released "$v"

prev="$v" v="$(next "$v")"
printf '\n2. origin takes main and refuses the tag — %s\n' "$v"
refuse origin 'refs/tags/*'
release "$v" 2a
eq "the run stops at the tag, and says to run it again" \
  "$rc|$(said 2a "could not push the tag — re-run: make release V=$v")" "1|1"
eq "main is out, the tag is not" \
  "$(git -C "$S/origin.git" rev-parse main)|$(git -C "$S/origin.git" tag -l "v$v")" "$(git -C "$R" rev-parse main)|"
admit origin
release "$v" 2b
eq "the same command again finishes it" "$rc" "0"
released "$v"

prev="$v" v="$(next "$v")"
printf '\n3. the tag is out, GitHub has no tarball for it yet — %s\n' "$v"
touch "$S/github-down"
release "$v" 3a
eq "the run stops at the tarball, and says to run it again" \
  "$rc|$(said 3a "the tag is pushed, so re-run: make release V=$v")" "1|1"
eq "the tag is out" "$(git -C "$S/origin.git" tag -l "v$v")" "v$v"
eq "the tap is untouched" "$(tap_untouched)" "$prev|same|"
rm -f "${S:?}/github-down"
release "$v" 3b
eq "the same command again finishes it" "$rc" "0"
released "$v"

prev="$v" v="$(next "$v")"
printf '\n4. every try at the tarball is cut short — %s\n' "$v"
touch "$S/github-flaky"
release "$v" 4a
eq "the run stops at the tarball rather than hash a piece of it" \
  "$rc|$(said 4a "could not fetch https://github.com/$REPO/archive/refs/tags/v$v.tar.gz")" "1|1"
eq "the tap is untouched" "$(tap_untouched)" "$prev|same|"
rm -f "${S:?}/github-flaky"
release "$v" 4b
eq "the same command again finishes it" "$rc" "0"
released "$v"

prev="$v" v="$(next "$v")"
printf '\n5. the formula is committed, the tap refuses the push — %s\n' "$v"
refuse tap-origin 'refs/heads/*'
release "$v" 5a
eq "the run stops at the tap, and says to run it again" \
  "$rc|$(said 5a "the formula is committed but NOT pushed — re-run: make release V=$v")" "1|1"
eq "this machine's tap serves it, the tap's origin does not" "$(tap_here)|$(tap_serves)" "$v|$prev"
eq "which --verify, reading this machine's copy, cannot see" \
  "$(verify)" "0|release: v$v is tagged and the tap serves it"
admit tap-origin
release "$v" 5b
eq "the same command again pushes it" "$rc|$(said 5b "tap → v$v, pushed")" "0|1"
released "$v"

prev="$v" v="$(next "$v")"
printf '\n6. main is refused, then rebased under a tag that never left — %s\n' "$v"
refuse origin refs/heads/main
release "$v" 6a
admit origin
# Someone else's commit reached origin first, and the refused push is got
# through the usual way — which leaves the tag on a commit main no longer has.
git clone -q "$S/origin.git" "$S/other"
git -C "$S/other" config user.email other@aif
git -C "$S/other" config user.name "Other"
printf 'theirs\n' >"$S/other/NOTES"
git -C "$S/other" add NOTES
git -C "$S/other" commit -qm "someone else's"
git -C "$S/other" push -q origin main
git -C "$R" pull -q --rebase origin main >/dev/null 2>&1
theirs="$(git -C "$S/origin.git" rev-parse main)"
release "$v" 6b
eq "the re-run refuses the tag main does not contain" \
  "$rc|$(said 6b "v$v is on a commit main does not contain")" "1|1"
eq "and publishes nothing" "$(git -C "$S/origin.git" rev-parse main)|$(git -C "$S/origin.git" tag -l "v$v")" "$theirs|"
git -C "$R" tag -d "v$v" >/dev/null
release "$v" 6c
eq "dropped, the next run tags main and finishes it" "$rc" "0"
released "$v"

prev="$v" v="$(next "$v")"
printf '\n7. v%s is tagged by hand before the bump\n' "$v"
git -C "$R" tag -a "v$v" -m "by hand"
release "$v" 7a
eq "the run refuses a tag that does not say $v" \
  "$rc|$(said 7a "v$v is on a commit that does not say $v in both markers")" "1|1"
eq "and publishes nothing" "$(git -C "$S/origin.git" tag -l "v$v")|$(tap_serves)" "|$prev"
git -C "$R" tag -d "v$v" >/dev/null
release "$v" 7b
eq "dropped, the next run finishes it" "$rc" "0"
released "$v"

# ----------------------------------------------------------------------------
printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'release, stopped and run again: ok\n'
  rm -rf "${S:?}"
else
  printf 'release, stopped and run again: %s failure(s) — sandbox kept at %s\n' "$fails" "$S"
  exit 1
fi
