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
# On success it writes tests.lock, the frozen record of this boundary: the test
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
  # degradation loudly in tests.lock rather than pretending to per-test rigour.
  mode="coarse"
fi

new_count=0
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

  # Each new test as "id<TAB>status<TAB>message".
  new_rows="$(printf '%s' "$results" | jq -r --argjson tf "$local_tf" \
    '.[] | select((.file // "") as $f | $tf | index($f)) | .id + "\t" + .status + "\t" + ((.message // "") | gsub("[\n\t]"; " "))')"

  # Two kinds of wrong, and they get different exit codes:
  #   reject (exit 1) — a real test asserting the wrong thing (passes already,
  #     or is skipped). The test-author rewrites it.
  #   broke  (exit 3) — not a usable oracle at all (syntax/collection error, or
  #     an error we cannot classify). verify-red cannot certify it as red, the
  #     same way a judge cannot certify a hallucinated verdict.
  reject=""
  broke=""
  while IFS="$(printf '\t')" read -r id status msg; do
    [ -n "$id" ] || continue
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

# --- freeze: write tests.lock ----------------------------------------------
# The test hashes lock the oracle; impl_frozen records the implementation as it
# is NOW (before code) so green can restore it and confirm the tests go red
# again. create paths do not exist yet, so they are recorded as to-be-created.
tests_json="$(
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '%s\t%s\n' "$f" "$(aif_g_sha256 "$root/$f")"
  done <<EOF
$test_files
EOF
)"
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
  --argjson create "$(printf '%s' "$create_files" | jq -R . | jq -s 'map(select(length>0))')" '
  def rows($raw): $raw | split("\n") | map(select(length>0) | split("\t"))
    | map({ (.[0]): .[1] }) | add // {};
  { schema: 1, plan_sha256: $plan_hash, mode: $mode, at: $at,
    tests: rows($tests_raw),
    impl_frozen: rows($impl_raw),
    impl_created: $create }' >"$work/tests.lock"

rm -f "$work/.suite.out"

if [ "$mode" = "coarse" ]; then
  printf 'verify-red: red (COARSE mode — no per-test detail; install python3)\n'
else
  printf 'verify-red: %s new test(s) red for the right reason, all criteria covered\n' \
    "$new_count"
fi
