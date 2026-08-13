#!/usr/bin/env bash
#
# Gate: verify-red — do the new tests fail, for the right reason, before any
# implementation exists?
#
# "The tests fail" is far too weak to be worth checking. A SyntaxError fails. A
# misspelled import fails. A test that was never collected did not fail — it is
# absent. Any of those, accepted as "red", launders confidence: it lets a broken
# oracle through and calls it a passing gate. So this gate checks the FAILURE
# MODE, not the failure:
#
#   - the pre-existing suite is green (a repo already broken makes "red"
#     meaningless) → exit 3 if not
#   - each new test is present in the report AND failing
#   - each failure is a legitimate class (assertion, missing module), not a
#     broken one (syntax, collection error) → exit 3 if broken
#   - every acceptance criterion is covered by a test, and its expected literal
#     appears in a test
#   - no implementation was written (the plan's create paths must not exist yet)
#
# On success it writes tests.lock.json, the frozen record of this boundary: the test
# hashes, the implementation hashes at red-time (for green's revert-recheck), and
# the coverage. That file, not the scattered test output, is what the implement
# station's precondition binds to.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source-path=SCRIPTDIR source=_lib.sh
. "$here/_lib.sh"

aif_g_need jq

work="${1:-}"
[ -n "$work" ] || aif_g_error "usage: verify-red.sh <work-dir>"

plan="$work/plan.md"
spec="$work/spec.md"
project="$(aif_g_project "$work")" || exit $?
root="$(dirname "$(dirname "$project")")"

[ -f "$plan" ] || aif_g_error "plan.md missing"
[ -f "$spec" ] || aif_g_error "spec.md missing"

plan_meta="$(aif_g_meta_or_die "$plan" "plan.md")" || exit $?
spec_meta="$(aif_g_meta_or_die "$spec" "spec.md")" || exit $?
plan_hash="$(aif_g_sha256 "$plan")"

# The plan must bind to the current spec, and this gate to the current plan —
# otherwise "red" is measured against a moving target.
if [ "$(printf '%s' "$plan_meta" | jq -r '.spec_sha256 // ""')" != "$(aif_g_sha256 "$spec")" ]; then
  aif_g_reject "plan.md is bound to a different spec — re-run the plan station"
fi

test_files="$(printf '%s' "$plan_meta" | jq -r '.files.tests[]? // empty')"
create_files="$(printf '%s' "$plan_meta" | jq -r '.files.create[]? // empty')"
change_files="$(printf '%s' "$plan_meta" | jq -r '.files.change[]? // empty')"

# --- the test files must exist; implementation must NOT --------------------
viol=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$root/$f" ] || viol="$viol
declared test file is missing: $f"
done <<EOF
$test_files
EOF

# A create path that already exists means the test-author wrote implementation —
# the one thing this station must not do.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -e "$root/$f" ] && viol="$viol
implementation was written by the test station: $f exists (it must not until implement)"
done <<EOF
$create_files
EOF
aif_g_report "${viol# }" "tests"

# --- run the suite ---------------------------------------------------------
test_cmd="$(jq -r '.test.command' "$project")"
report_path="$(jq -r '.test.report.path' "$project")"
mkdir -p "$root/$(dirname "$report_path")"

(cd "$root" && eval "$test_cmd") >"$work/.suite.out" 2>&1 || true

mode="per-test"
results=""
if aif_g_have python3 && [ -f "$root/$report_path" ]; then
  results="$(python3 "$here/junit.py" "$root/$report_path" 2>/dev/null || true)"
fi
if [ -z "$results" ]; then
  # No parser or no report: fall back to the suite exit code alone. A much weaker
  # gate — it cannot tell a legitimate failure from a broken one — so record the
  # degradation loudly in tests.lock.json rather than pretending to per-test rigour.
  mode="coarse"
fi

new_count=0
new_rows=""
if [ "$mode" = "per-test" ]; then
  # jq emits plain rows; classification happens in bash against the project's
  # failure-class patterns. Keeping the jq single-line and pattern-free is what
  # lets a linter parse this file and a reader follow it.
  local_tf="$(printf '%s' "$test_files" | jq -R . | jq -s .)"
  broken_re="$(jq -r '.failure_classes.broken | join("|")' "$project")"
  legit_re="$(jq -r '.failure_classes.legitimate | join("|")' "$project")"

  # Pre-existing tests (not in a declared test file) must all pass: a repo
  # already red makes this gate blind, so that is a stop, not a reject.
  pre_red="$(printf '%s' "$results" | jq -r --argjson tf "$local_tf" \
    '[ .[] | select(((.file // "") as $f | $tf | index($f)) | not) | select(.status != "pass" and .status != "skipped") ] | length')"
  if [ "${pre_red:-0}" -gt 0 ]; then
    aif_g_error "the pre-existing suite is not green ($pre_red failing) — fix the repo before authoring tests; red is meaningless otherwise"
  fi

  # Each new test as "file<TAB>id<TAB>status<TAB>message". The file travels with
  # the id because the freeze below has to prove that every test it records as
  # covered actually resolves to a file it holds — a `covering` list of bare
  # names that resolve to nothing is what a lock looks like when it is describing
  # tests it does not have.
  new_rows="$(printf '%s' "$results" | jq -r --argjson tf "$local_tf" \
    '.[] | select((.file // "") as $f | $tf | index($f)) | (.file // "") + "\t" + .id + "\t" + .status + "\t" + ((.message // "") | gsub("[\n\t]"; " "))')"

  # Two kinds of wrong, and they get different exit codes:
  #   reject (exit 1) — a real test asserting the wrong thing (passes already,
  #     or is skipped). The test-author rewrites it.
  #   broke  (exit 3) — not a usable oracle at all (syntax/collection error, or
  #     an error we cannot classify). verify-red cannot certify it as red, the
  #     same way a judge cannot certify a hallucinated verdict.
  reject=""
  broke=""
  while IFS="$(printf '\t')" read -r file id status msg; do
    [ -n "$id" ] || continue
    : "$file"
    new_count=$((new_count + 1))
    if [ -n "$broken_re" ] && printf '%s' "$msg" | grep -qE "$broken_re"; then
      broke="$broke
$id failed for a broken reason, not a missing feature — it is not a usable test"
    elif [ "$status" = "pass" ]; then
      reject="$reject
$id passes already — nothing to implement, or it asserts nothing"
    elif [ "$status" = "skipped" ]; then
      reject="$reject
$id is skipped — a skipped test is not a red test"
    elif [ "$status" = "error" ] && [ -n "$legit_re" ] && ! printf '%s' "$msg" | grep -qE "$legit_re"; then
      broke="$broke
$id errored for an unrecognised reason — treat as broken, not as red"
    fi
  done <<EOF
$new_rows
EOF

  [ "$new_count" -gt 0 ] || aif_g_reject "no new tests were collected from the declared test files"

  broke="$(printf '%s' "${broke# }" | grep -v '^$' || true)"
  if [ -n "$broke" ]; then
    printf 'ERROR  the new tests are not a usable oracle — fix them, do not proceed:\n' >&2
    printf '%s\n' "$broke" | sed 's/^/  - /' >&2
    exit "$AIF_G_ERROR"
  fi
  aif_g_report "${reject# }" "tests"
else
  # coarse: the suite as a whole must be observably non-green.
  if grep -qiE 'passed|ok|0 failed' "$work/.suite.out" && ! grep -qiE 'fail|error' "$work/.suite.out"; then
    aif_g_reject "the suite appears green — no observable red (coarse mode: install python3 for per-test checking)"
  fi
fi

# --- coverage: every criterion has a test, with its literal present ---------
cov=""
while IFS= read -r ac; do
  [ -n "$ac" ] || continue
  local_hit=0
  expect="$(printf '%s' "$spec_meta" | jq -r --arg id "$ac" '.acceptance[] | select(.id==$id) | .expect | tostring')"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qF "$ac" "$root/$f" 2>/dev/null && local_hit=1
  done <<EOF
$test_files
EOF
  [ "$local_hit" -eq 1 ] || cov="$cov
$ac is not referenced by any test file"

  # The expected literal must appear in some test — the cheap guard against a
  # test that is red now but green against any stub.
  lit_hit=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qF "$expect" "$root/$f" 2>/dev/null && lit_hit=1
  done <<EOF
$test_files
EOF
  [ "$lit_hit" -eq 1 ] || cov="$cov
$ac expected value ($expect) does not appear in any test"
done <<EOF
$(printf '%s' "$spec_meta" | jq -r '.acceptance[].id')
EOF
aif_g_report "${cov# }" "coverage"

# --- the project's own checks, for this phase -------------------------------
# Bound to "red" deliberately: at this moment no implementation exists, so a
# compiler or a build would fail CORRECTLY and a phase-blind checks list would
# reject the red phase for being red by design. Only a check that is true of the
# test files alone belongs here; compilers, linters and builds bind to "green".
mkdir -p "$root/.aif/tmp"
check_viol="$(aif_g_checks_run "$project" "$root" "red" "$root/.aif/tmp/checks-red.json")"
aif_g_report "$check_viol" "checks"

# --- freeze: write tests.lock.json ------------------------------------------
# The frozen set is the UNION of two things, and it was one for too long:
#
#   test.roots      — the whole shared test tree, not just the declared files,
#                     because green must catch logic smuggled into a conftest.py
#                     or a fixture that no plan lists. This net is correct and
#                     stays.
#   plan.files.tests — THIS ticket's own oracle. A project whose roots point at
#                     one tree while its tests live beside their sources cast the
#                     net over the wrong tree entirely: the ticket's tests were
#                     absent from the lock, so the freeze guarantee — the one
#                     that stops the implement station editing the oracle it is
#                     judged against — did not apply to them at all, and nothing
#                     noticed. The plan already declares these files and
#                     $test_files has been in scope since line 55.
#
# impl_frozen records the implementation as it is NOW (before code) so green can
# restore it and confirm the tests go red again; create paths do not exist yet,
# so they are recorded as to-be-created. covering is the new red test ids, for
# green's revert-recheck to target.
tests_json="$(
  {
    while IFS= read -r rootdir; do
      [ -n "$rootdir" ] || continue
      [ -d "$root/$rootdir" ] || continue
      find "$root/$rootdir" -type f 2>/dev/null | while IFS= read -r f; do
        printf '%s\t%s\n' "${f#"$root"/}" "$(aif_g_sha256 "$f")"
      done
    done <<EOF
$(jq -r '.test.roots[]?' "$project")
EOF
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -f "$root/$f" ] || continue
      printf '%s\t%s\n' "$f" "$(aif_g_sha256 "$root/$f")"
    done <<EOF
$test_files
EOF
  } | sort -u
)"
covering_json="$(printf '%s' "$new_rows" | cut -f2)"

# --- the freeze must hold what it claims to hold ----------------------------
# Two invariants over the set just built. Both are hard stops rather than
# rejections: a lock that does not hold this ticket's oracle is not a weaker
# lock, it is a lock over the wrong files, and letting it through would record a
# freeze that guarantees nothing.
frozen_paths="$(printf '%s' "$tests_json" | cut -f1)"
in_frozen() {
  local needle="$1" line
  while IFS= read -r line; do
    [ "$line" = "$needle" ] && return 0
  done <<EOF
$frozen_paths
EOF
  return 1
}

lock_viol=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  in_frozen "$f" || lock_viol="$lock_viol
declared test file $f is not in the frozen set — the freeze would not cover this ticket's own oracle"
done <<EOF
$test_files
EOF

if [ "$mode" = "per-test" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    in_frozen "$f" || lock_viol="$lock_viol
a covered test comes from $f, which is not in the frozen set — the lock would describe tests it does not hold"
  done <<EOF
$(printf '%s' "$new_rows" | cut -f1 | sort -u)
EOF
fi

lock_viol="$(printf '%s' "${lock_viol# }" | grep -v '^$' | sort -u || true)"
if [ -n "$lock_viol" ]; then
  printf 'ERROR  the test freeze would not cover this ticket — check test.roots and the plan:\n' >&2
  printf '%s\n' "$lock_viol" | sed 's/^/  - /' >&2
  exit "$AIF_G_ERROR"
fi
impl_frozen="$(
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '%s\t%s\n' "$f" "$(aif_g_sha256 "$root/$f")"
  done <<EOF
$change_files
EOF
)"

jq -n \
  --arg plan_hash "$plan_hash" \
  --arg mode "$mode" \
  --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)" \
  --rawfile tests_raw <(printf '%s' "$tests_json") \
  --rawfile impl_raw <(printf '%s' "$impl_frozen") \
  --argjson create "$(printf '%s' "$create_files" | jq -R . | jq -s 'map(select(length>0))')" \
  --argjson covering "$(printf '%s' "$covering_json" | jq -R . | jq -s 'map(select(length>0))')" '
  def rows($raw): $raw | split("\n") | map(select(length>0) | split("\t"))
    | map({ (.[0]): .[1] }) | add // {};
  { schema: 1, plan_sha256: $plan_hash, mode: $mode, at: $at,
    tests: rows($tests_raw),
    covering: $covering,
    impl_frozen: rows($impl_raw),
    impl_created: $create }' >"$work/tests.lock.json"

# The file was called tests.lock until the content stopped being a secret: it is
# JSON, editors did not highlight it, jq did not pick it up by glob, and diffs
# read worse for it. The ".lock" signal — generated by the tool, pins resolved
# state, do not hand-edit — is kept by the name, without lying about the format.
# A stale one from before the rename is removed rather than left beside its
# replacement, where a reader would have to guess which is live.
rm -f "$work/tests.lock" "$work/.suite.out"

if [ "$mode" = "coarse" ]; then
  printf 'verify-red: red (COARSE mode — no per-test detail; install python3)\n'
else
  printf 'verify-red: %s new test(s) red for the right reason, all criteria covered\n' \
    "$new_count"
fi
