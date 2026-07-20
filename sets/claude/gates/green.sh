#!/usr/bin/env bash
#
# Gate: green — do the frozen tests now pass, because the implementation is real?
#
# The mirror of verify-red, and it is not just "the tests pass". Three things
# have to hold, and the third is the one that catches a defeated oracle:
#
#   - the test tree is byte-identical to what verify-red froze, so the tests that
#     pass are the tests that were red — not tests quietly weakened, and not
#     logic smuggled into a conftest the declared-file list would miss;
#   - every test passes, and a skipped test fails this gate (a skip is the
#     cheapest way to make red go away without implementing anything);
#   - reverting the implementation makes the covering tests go red again. A test
#     that stays green with the code reverted never depended on it — it asserts
#     nothing, and it is exactly what a small model reaches for under pressure.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source-path=SCRIPTDIR source=_lib.sh
. "$here/_lib.sh"

aif_g_need jq

work="${1:-}"
[ -n "$work" ] || aif_g_error "usage: green.sh <work-dir>"

plan="$work/plan.md"
lock="$work/tests.lock"
project="$(aif_g_project "$work")" || exit $?
root="$(dirname "$(dirname "$project")")"

[ -f "$plan" ] || aif_g_error "plan.md missing"
[ -f "$lock" ] || aif_g_reject "no tests.lock — run the tests station (verify-red) first"

# The lock must be for the current plan; otherwise "green" is measured against a
# stale oracle.
if [ "$(jq -r '.plan_sha256 // ""' "$lock")" != "$(aif_g_sha256 "$plan")" ]; then
  aif_g_reject "tests.lock is for a different plan — re-run the tests station"
fi

# --- the test tree is frozen -----------------------------------------------
# Compare the live tree under test.roots to the lock: no test file changed,
# none added, none removed. The whole tree, so a fixture cannot be the hiding
# place.
drift=""
while IFS= read -r rootdir; do
  [ -n "$rootdir" ] || continue
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$root"/}"
    locked="$(jq -r --arg p "$rel" '.tests[$p] // ""' "$lock")"
    if [ -z "$locked" ]; then
      drift="$drift
$rel was added under the test tree after the tests were frozen"
    elif [ "$locked" != "$(aif_g_sha256 "$f")" ]; then
      drift="$drift
$rel was modified after the tests were frozen"
    fi
  done <<EOF
$(find "$root/$rootdir" -type f 2>/dev/null)
EOF
done <<EOF
$(jq -r '.test.roots[]?' "$project")
EOF

# Deletions: anything in the lock that is gone now.
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  [ -f "$root/$rel" ] || drift="$drift
$rel was deleted after the tests were frozen"
done <<EOF
$(jq -r '.tests | keys[]' "$lock")
EOF

aif_g_report "${drift# }" "test tree"

# --- the suite is green, with no skips -------------------------------------
test_cmd="$(jq -r '.test.command' "$project")"
report_path="$(jq -r '.test.report.path' "$project")"
mkdir -p "$root/$(dirname "$report_path")"
(cd "$root" && eval "$test_cmd") >"$work/.suite.out" 2>&1 || true

if aif_g_have python3 && [ -f "$root/$report_path" ]; then
  results="$(python3 "$here/junit.py" "$root/$report_path" 2>/dev/null || true)"
  if [ -n "$results" ]; then
    notpass="$(printf '%s' "$results" | jq -r '.[] | select(.status != "pass") | .id + " (" + .status + ")"')"
    if [ -n "$notpass" ]; then
      printf 'REJECT suite is not green:\n' >&2
      printf '%s\n' "$notpass" | sed 's/^/  - /' >&2
      exit "$AIF_G_REJECT"
    fi
  else
    aif_g_error "test report was not parseable — cannot confirm green"
  fi
else
  # Coarse: exit code only. Weaker, and a skip is invisible here.
  if grep -qiE 'fail|error' "$work/.suite.out"; then
    aif_g_reject "the suite is not green (coarse mode)"
  fi
fi

# --- revert-recheck: the tests must actually depend on the code -------------
# Restore the implementation to its red-time state in a throwaway copy of the
# repo, re-run, and require the covering tests to fail again. A copy, not the
# live tree — the same disposable-copy reasoning as the eval harness — so this
# check cannot damage the work.
scratch="$(mktemp -d "${TMPDIR:-/tmp}/aif-green-XXXXXX")"
cp -R "$root/." "$scratch/" 2>/dev/null || true

# change files: back to frozen content. create files: remove them.
jq -r '.impl_frozen | to_entries[] | .key' "$lock" | while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  # The frozen content is not stored, only its hash — so revert by checking out
  # the committed version if git is present, else skip with a recorded caveat.
  if [ -d "$root/.git" ]; then
    git -C "$scratch" checkout -q -- "$rel" 2>/dev/null || true
  fi
done
jq -r '.impl_created[]?' "$lock" | while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  rm -f "$scratch/$rel"
done

recheck_ok=1
if [ -d "$root/.git" ] && aif_g_have python3; then
  (cd "$scratch" && eval "$test_cmd") >"$scratch/.out" 2>&1 || true
  if [ -f "$scratch/$report_path" ]; then
    reverted="$(python3 "$here/junit.py" "$scratch/$report_path" 2>/dev/null || true)"
    # Every covering test must now be failing. One that stays green did not
    # depend on the implementation.
    still_green=""
    while IFS= read -r tid; do
      [ -n "$tid" ] || continue
      st="$(printf '%s' "$reverted" | jq -r --arg i "$tid" '.[] | select(.id==$i) | .status' 2>/dev/null | head -1)"
      [ "$st" = "pass" ] && still_green="$still_green
$tid stays green with the implementation reverted — it does not test the behaviour"
    done <<EOF
$(jq -r '.covering[]?' "$lock")
EOF
    if [ -n "$still_green" ]; then
      rm -rf "$scratch" "$work/.suite.out"
      printf 'REJECT the tests do not depend on the implementation:\n' >&2
      printf '%s\n' "${still_green# }" | sed 's/^/  - /' >&2
      exit "$AIF_G_REJECT"
    fi
  else
    recheck_ok=0
  fi
else
  recheck_ok=0
fi

rm -rf "$scratch" "$work/.suite.out"

if [ "$recheck_ok" -eq 0 ]; then
  printf 'green: suite passes (revert-recheck skipped — needs git and python3)\n'
else
  printf 'green: suite passes, and the covering tests depend on the implementation\n'
fi
