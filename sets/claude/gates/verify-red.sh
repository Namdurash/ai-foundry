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
#   - each new test is present in the report, and each failing one fails for a
#     legitimate class (assertion, missing module), not a broken one (syntax,
#     collection error) → exit 3 if broken
#   - every acceptance criterion is covered by a test, and its expected literal
#     appears in a test
#   - no implementation was written (the plan's create paths must not exist yet)
#
# Without a readable per-test report none of that is possible and the gate falls
# to COARSE mode — the suite's exit code alone. Only a report that exists and
# cannot be read per test gets there; a suite that wrote NO report did not run,
# and that is an ERROR, not a weaker red. Two things hold in coarse mode. The
# project's broken-failure classes are matched against the run's own output, so
# a suite that did not compile is still refused rather than frozen as an oracle;
# and the reason for the degradation is named, on the closing line and in
# tests.lock.json, because three different causes used to collapse into one
# empty variable and "install python3" was the only thing this gate ever said
# about any of them.
#
# A new test that PASSES at freeze is not rejected. On a second round — a
# reworked ticket whose earlier round already implemented some criteria — the
# honest test for a built criterion is green before this round's implementation
# exists, and demanding red there is jointly unsatisfiable with demanding
# coverage: include the file and N tests "pass already", exclude it and M
# criteria are "not referenced". The one workaround is an artificial
# precondition that breaks the built behaviour so the test can fail first —
# manufactured evidence, which is worse than a recorded gap. So a green test is
# recorded in tests.lock.json as green_at_freeze — "green at freeze, never
# proven red" — excluded from `covering` (green's revert-recheck must not
# target a test that never depended on this round's code), and re-surfaced on
# the closing checklist. If EVERY new test is green, that is still a rejection:
# nothing red remains, so either the ticket is already done or the tests assert
# nothing.
#
# On success it writes tests.lock.json, the frozen record of this boundary: the test
# hashes, the implementation hashes at red-time (for green's revert-recheck), the
# coverage, and the green-at-freeze list. That file, not the scattered test
# output, is what the implement station's precondition binds to.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source-path=SCRIPTDIR source=_lib.sh
. "$here/_lib.sh"

aif_g_need jq

work="${1:-}"
[ -n "$work" ] || aif_g_error "usage: verify-red.sh <work-dir>"

plan="$work/plan.md"
spec="$work/ticket.md"
project="$(aif_g_project "$work")" || exit $?
root="$(dirname "$(dirname "$project")")"

[ -f "$plan" ] || aif_g_error "plan.md missing"
[ -f "$spec" ] || aif_g_error "ticket.md missing"

plan_meta="$(aif_g_meta_or_die "$plan" "plan.md")" || exit $?
spec_meta="$(aif_g_meta_or_die "$spec" "ticket.md")" || exit $?
plan_hash="$(aif_g_sha256 "$plan")"

# The plan must bind to the current ticket, and this gate to the current plan —
# otherwise "red" is measured against a moving target.
if [ "$(printf '%s' "$plan_meta" | jq -r '.ticket_sha256 // ""')" != "$(aif_g_sha256 "$spec")" ]; then
  aif_g_reject "plan.md is bound to a different ticket — re-run the plan station"
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
# The previous report is DELETED first, and that is not tidiness. A run that
# never gets as far as writing one — a reporter that is not installed, a runner
# that dies on startup, a checkout the runner refuses — leaves the last run's
# file exactly where this gate looks for it, and every conclusion below is then
# drawn about a suite that did not run. `aif doctor` has cleared it before
# probing since the probe existed; the gates, which decide things, had not.
test_cmd="$(jq -r '.test.command' "$project")"
report_path="$(jq -r '.test.report.path' "$project")"
[ -n "$report_path" ] && [ "$report_path" != "null" ] ||
  aif_g_error "project.json names no test.report.path — this gate has nothing to read"
mkdir -p "$root/$(dirname "$report_path")"
rm -f "$root/$report_path"

# The suite's raw output is scratch, and it lives inside tasks/<ID>/ — which the
# worker commits. Every early exit below used to leak it there (docs/DEFECTS-3.md
# #14): the removals were written on the pass paths only, and a rejection is the
# common case. A gate is its own process, so a plain EXIT trap is the whole fix.
trap 'rm -f "$work/.suite.out"' EXIT

suite_rc=0
(cd "$root" && eval "$test_cmd") >"$work/.suite.out" 2>&1 || suite_rc=$?

# Coarse mode is a large downgrade in rigour and it used to engage in silence:
# three different causes collapsed into one empty variable, and from the outside
# there was no way to tell which had happened — not from the gate's output, not
# from the lock, not afterwards. Each cause is now named where it is found, and
# the name travels to the closing line and into tests.lock.json.
#
# One of the three is not a cause of coarse mode at all, and for one release
# it was treated as one. A suite that wrote no report never reached its
# reporter: a runner that died validating its config, a missing dependency in
# a fresh worktree, an uninstalled reporter. Its exit code says nothing about
# the tests, because no test ran — and coarse red admitted it, froze an empty
# `covering`, and green then passed on a run that had established nothing
# (docs/DEFECTS-4.md #11). That case is a 3. Coarse mode is for a report that
# exists and cannot be read per test.
mode="per-test"
mode_why=""
results=""
if [ ! -f "$root/$report_path" ]; then
  printf 'ERROR  the suite did not run — it exited %s and wrote no report at %s:\n' \
    "$suite_rc" "$report_path" >&2
  tail -8 "$work/.suite.out" | sed 's/^/      /' >&2
  printf '  A run that never reaches its reporter is neither red nor green; it is not a\n' >&2
  printf '  run. If this is a fresh worktree, the runner may need dependencies that only\n' >&2
  printf '  tracked files cannot bring: set "prepare" in .aif/project.json (e.g. "npm ci").\n' >&2
  exit "$AIF_G_ERROR"
elif ! aif_g_have python3; then
  # PATH, because the interesting case is a python3 the developer's shell
  # resolves and the gate's environment does not.
  mode_why="python3 is not on PATH (PATH=${PATH:0:200})"
else
  parse_rc=0
  results="$(python3 "$here/junit.py" "$root/$report_path" 2>/dev/null)" || parse_rc=$?
  [ -n "$results" ] ||
    mode_why="junit.py could not read $report_path (exit $parse_rc) — not the declared format, or it holds no test cases"
fi
if [ -z "$results" ]; then
  # No parser or no report: fall back to the suite exit code alone. A much weaker
  # gate — it cannot tell a legitimate failure from a broken one — so record the
  # degradation loudly in tests.lock.json rather than pretending to per-test rigour.
  mode="coarse"
fi

new_count=0
new_rows=""
suite_rows=""
green_ids=""
green_count=0
red_count=0
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

  # And the rest of the suite, as it stands right now. green needs it to tell
  # a test that was ALREADY skipped before this ticket — a platform guard, an
  # importorskip, a slow marker — from one the implementation just silenced.
  # Without it green can only choose between rejecting every project that has
  # a skipped test anywhere (which it did) and ignoring a real regression.
  suite_rows="$(printf '%s' "$results" | jq -r --argjson tf "$local_tf" \
    '.[] | select(((.file // "") as $f | $tf | index($f)) | not) | .id + "\t" + .status')"

  # Three kinds of outcome, and they part ways here:
  #   reject (exit 1) — a real test asserting the wrong thing (skipped, since a
  #     skip is the cheapest way to make red disappear). The test-author
  #     rewrites it.
  #   broke  (exit 3) — not a usable oracle at all (syntax/collection error, or
  #     an error we cannot classify). verify-red cannot certify it as red, the
  #     same way a judge cannot certify a hallucinated verdict.
  #   green  (recorded) — passes at freeze. On a second round that is the
  #     honest test for an already-implemented criterion; see the header. It is
  #     kept, named in the lock, and kept OUT of covering.
  reject=""
  broke=""
  green_ids=""
  while IFS="$(printf '\t')" read -r file id status msg; do
    [ -n "$id" ] || continue
    : "$file"
    new_count=$((new_count + 1))
    if [ -n "$broken_re" ] && printf '%s' "$msg" | grep -qE "$broken_re"; then
      broke="$broke
$id failed for a broken reason, not a missing feature — it is not a usable test"
    elif [ "$status" = "pass" ]; then
      green_ids="$green_ids
$id"
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

  green_ids="$(printf '%s' "${green_ids# }" | grep -v '^$' || true)"
  green_count="$(printf '%s' "$green_ids" | grep -c . || true)"
  red_count=$((new_count - green_count))
  if [ "$red_count" -eq 0 ]; then
    aif_g_reject "all $new_count new test(s) are already green — nothing red remains to implement; either the ticket is already done, or the tests assert nothing"
  fi
else
  # coarse: the suite as a whole must be observably non-green.
  #
  # Before that, the one distinction coarse mode CAN still draw is drawn. A
  # test file that does not compile is red, and "red" was the whole of the
  # question here — which is how a jest.mock() factory closing over an
  # out-of-scope variable became a frozen oracle asserting nothing, admitted by
  # this branch on a live ticket. The project already names these strings for
  # exactly this case; they were consulted in per-test mode only, where the
  # message of an individual test is available. The suite's own output carries
  # them too, and it is what this branch has.
  broken_re="$(jq -r '.failure_classes.broken | join("|")' "$project")"
  if [ -n "$broken_re" ] && grep -qE "$broken_re" "$work/.suite.out"; then
    printf 'ERROR  the new tests are not a usable oracle — the run matches a broken-failure class:\n' >&2
    grep -ohE "$broken_re" "$work/.suite.out" | sort -u | sed 's/^/  - /' >&2
    printf '  This is coarse mode (%s), so the gate cannot say WHICH test broke —\n' "$mode_why" >&2
    printf '  only that the suite did not merely fail, it failed to run.\n' >&2
    rm -f "$work/.suite.out"
    exit "$AIF_G_ERROR"
  fi
  # The runner's exit code, and nothing else. This used to grep the output for
  # "passed" and the absence of "fail|error": a red pytest run prints "failed"
  # so it mostly held, but a suite whose output said "ok" and nothing else read
  # as green, and one whose log mentioned "error" anywhere read as red
  # (docs/DEFECTS-3.md #5). The exit code is the one signal every runner agrees
  # on, and suite_rc has held it since the report cross-check arrived.
  if [ "$suite_rc" -eq 0 ]; then
    aif_g_reject "the suite exited 0 — no observable red (coarse mode: $mode_why)"
  fi
fi

# --- coverage: every criterion has a test, with its literal present ---------
# A fully-backticked expect is the ready gate's convention for a domain literal
# that collides with the vague-word list (`error` the union value). The
# backticks are the declaration, not part of the value — strip them, so the
# tests assert the bare literal.
cov=""
while IFS= read -r ac; do
  [ -n "$ac" ] || continue
  local_hit=0
  expect="$(printf '%s' "$spec_meta" | jq -r --arg id "$ac" \
    '.acceptance[] | select(.id==$id) | .expect | tostring
     | if test("^`[^`]+`$") then .[1:-1] else . end')"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qF -- "$ac" "$root/$f" 2>/dev/null && local_hit=1
  done <<EOF
$test_files
EOF
  [ "$local_hit" -eq 1 ] || cov="$cov
$ac is not referenced by any test file"

  # The expected literal must appear in some test — the cheap guard against a
  # test that is red now but green against any stub.
  #
  # `--` because the pattern is the ticket's own value: an expect of "-1" — what
  # indexOf returns, what a criterion about a missing item asserts — is an
  # OPTION to grep, and the search silently answers "not found" about a test
  # where the literal plainly is. The station cannot fix that; it burns
  # attempts_max runs and stops the ticket.
  lit_hit=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qF -- "$expect" "$root/$f" 2>/dev/null && lit_hit=1
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
# so they are recorded as to-be-created. covering is the new RED test ids, for
# green's revert-recheck to target; a test green at freeze goes to
# green_at_freeze instead — reverting this round's code was never going to turn
# it red, and demanding that would accuse an honest test on a second round.
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
covering_json="$(printf '%s' "$new_rows" | awk -F'\t' '$3 != "pass" { print $2 }')"

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
  --arg mode_reason "$mode_why" \
  --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)" \
  --rawfile tests_raw <(printf '%s' "$tests_json") \
  --rawfile impl_raw <(printf '%s' "$impl_frozen") \
  --rawfile suite_raw <(printf '%s' "${suite_rows:-}") \
  --argjson create "$(printf '%s' "$create_files" | jq -R . | jq -s 'map(select(length>0))')" \
  --argjson covering "$(printf '%s' "$covering_json" | jq -R . | jq -s 'map(select(length>0))')" \
  --argjson green "$(printf '%s' "$green_ids" | jq -R . | jq -s 'map(select(length>0))')" '
  def rows($raw): $raw | split("\n") | map(select(length>0) | split("\t"))
    | map({ (.[0]): .[1] }) | add // {};
  { schema: 1, plan_sha256: $plan_hash, mode: $mode, mode_reason: $mode_reason, at: $at,
    tests: rows($tests_raw),
    covering: $covering,
    green_at_freeze: $green,
    impl_frozen: rows($impl_raw),
    impl_created: $create,
    suite_at_freeze: rows($suite_raw) }' >"$work/tests.lock.json"

# The file was called tests.lock until the content stopped being a secret: it is
# JSON, editors did not highlight it, jq did not pick it up by glob, and diffs
# read worse for it. The ".lock" signal — generated by the tool, pins resolved
# state, do not hand-edit — is kept by the name, without lying about the format.
# A stale one from before the rename is removed rather than left beside its
# replacement, where a reader would have to guess which is live.
rm -f "$work/tests.lock" "$work/.suite.out"

if [ "$mode" = "coarse" ]; then
  # The reason, not the remedy. "install python3" was the only thing this line
  # ever said, and on a machine where python3 was installed and resolving it
  # sent the reader looking in the one place the answer was not.
  printf 'verify-red: red (COARSE mode — no per-test detail)\n'
  printf '  ! why: %s\n' "$mode_why"
  printf '  ! the lock records covering: [] — green has no test to revert-recheck against.\n'
else
  printf 'verify-red: %s new test(s) red for the right reason, all criteria covered\n' \
    "$red_count"
  if [ "$green_count" -gt 0 ]; then
    # On the PASS path, always — the same rule the other gates follow for what
    # they allowed. A degradation only readable out of a lock file is silent.
    printf '  ! GREEN AT FREEZE — never proven red, an earlier round already implemented these:\n'
    printf '%s\n' "$green_ids" | sed 's/^/    - /'
    printf '  Excluded from the revert-recheck; re-emitted on the closing checklist.\n'
  fi
fi
