#!/usr/bin/env bash
#
# Gate: verify-red — do the new tests fail, for the right reason, against the
# contract, before any implementation exists?
#
# "The tests fail" is far too weak to be worth checking. A SyntaxError fails. A
# misspelled import fails. A test that was never collected did not fail — it is
# absent. Any of those, accepted as "red", launders confidence: it lets a broken
# oracle through and calls it a passing gate. So this gate checks the FAILURE
# MODE, not the failure:
#
#   - the pre-existing suite was green before this ticket's tests existed (a
#     repo already broken makes "red" meaningless) → exit 3 if not, naming the
#     tests. A pre-existing test that was green WITHOUT the new test files and
#     is red with them is a different thing, told apart by running the suite
#     once more without them (see "Pre-existing tests" below)
#   - each new test is present in the report, and each failing one fails for
#     one of two reasons: an assertion did not hold, or the skeleton threw the
#     not-implemented marker. The plan station wrote the contract — every
#     module the plan creates exists as signatures whose bodies throw — so a
#     test that fails any other way is calling something the contract does not
#     export, or is broken (syntax, a fixture that is not there). Both are the
#     tests station's own, and both come back to it as a REJECTION, while it
#     is still there to fix them. "Broken" used to be a stop (docs/REBUILD-4.md)
#   - every acceptance criterion is carried by a collected test: its marker,
#     ticket id and criterion id — `OPES-69 AC-003` — in the test's own name,
#     not merely in a file's text, where a comment or another ticket's marker
#     in a shared file used to satisfy it. And the criterion's literal in that
#     test's file
#   - every relative import in a declared file resolves to a file that exists.
#     With the contract on disk that is what a misspelling looks like, and it
#     used to be frozen as red and surface at green, in a file nobody may edit
#   - the new red tests are red twice: the suite runs once more at the freeze,
#     and a test whose status moved is non-deterministic, not red
#   - no implementation was written: the skeleton is byte-identical to the
#     plan's commit, and a create path the plan marked no_skeleton does not
#     exist yet
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
# nothing — unless the station SAID so, in tests.note.json, in which case it is
# the ticket's problem and a spec stop (exit 2).
#
# The station runs this gate itself, before the freeze, as `aif _verify <ID>`:
# AIF_VERIFY_DRY=1 makes every check run and every complaint print, and freezes
# nothing. That is the execute-and-repair loop every working test generator
# has, and the blind station never had.
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

dry="${AIF_VERIFY_DRY:-0}"

plan="$work/plan.md"
spec="$work/ticket.md"
note="$work/tests.note.json"
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

ticket_id="$(printf '%s' "$spec_meta" | jq -r '.ticket // ""')"
test_files="$(printf '%s' "$plan_meta" | jq -r '.files.tests[]? // empty')"
create_files="$(printf '%s' "$plan_meta" | jq -r '.files.create[]? // empty')"
change_files="$(printf '%s' "$plan_meta" | jq -r '.files.change[]? // empty')"
no_skeleton="$(printf '%s' "$plan_meta" | jq -r '.no_skeleton[]? // empty')"

# --- the station's note: what it could not write a red test for --------------
# A structured way to say "this criterion is already built" or "this one
# cannot be falsified", read here rather than guessed from a closing message.
# Unfalsifiable is the ticket's problem whoever found it: a spec stop, now,
# before anything is frozen and before three attempts at the impossible.
note_built=""
note_unf=""
if [ -f "$note" ]; then
  printf '%s' "$(cat "$note")" | jq -e . >/dev/null 2>&1 ||
    aif_g_reject "tests.note.json is not valid JSON"
  note_built="$(jq -r '.already_built[]? // empty' "$note")"
  note_unf="$(jq -r '.unfalsifiable[]? | (.id // "") + " cannot be falsified: " + (.because // "no reason given")' "$note")"
fi
if [ -n "$note_unf" ]; then
  aif_g_spec "$(printf '%s\n%s' "$note_unf" "the tests station could not write a test that would fail for it; the criterion needs a literal observation, or it is not a criterion")"
fi

# --- the test files must exist; the contract must be what the plan left -----
viol=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$root/$f" ] || viol="$viol
declared test file is missing: $f"
done <<EOF
$test_files
EOF

# The skeleton is the plan's. A create path that changed since the plan's
# commit means the test station wrote implementation — the one thing it must
# not do — or edited the contract it was handed; a create path the plan marked
# no_skeleton must not exist until implement. Measured against the commit the
# worker dispatched this station from; by hand, with no record, against HEAD.
base="$(aif_g_dispatch_base "$work" "$root")"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if printf '%s\n' "$no_skeleton" | grep -qxF -- "$f"; then
    [ -e "$root/$f" ] && viol="$viol
implementation was written by the test station: $f exists (the plan marked it no_skeleton; it must not exist until implement)"
    continue
  fi
  if [ ! -f "$root/$f" ]; then
    viol="$viol
the skeleton $f the plan wrote is gone — the tests are red against the contract, and the contract has to be there"
    continue
  fi
  if [ -n "$base" ] && [ -e "$root/.git" ] && git -C "$root" cat-file -e "$base:$f" 2>/dev/null; then
    if [ "$(git -C "$root" show "$base:$f" 2>/dev/null | aif_g_sha256 /dev/stdin)" != "$(aif_g_sha256 "$root/$f")" ]; then
      viol="$viol
the test station changed the skeleton $f — the contract is the plan's; a test is written against it, not over it, and an implementation is the implement station's"
    fi
  fi
done <<EOF
$create_files
EOF

# --- every relative import resolves --------------------------------------------
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$root/$f" ] || continue
  while IFS= read -r spec_unres; do
    [ -n "$spec_unres" ] || continue
    viol="$viol
$f imports '$spec_unres', which resolves to no file — the contract is on disk, so a path that is not there is misspelled, or the plan created nothing at it"
  done <<EOF2
$(aif_g_imports_unresolved "$root" "$f")
EOF2
done <<EOF
$test_files
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
# The copy the baseline runs in (below) goes the same way.
scratch=""
trap 'rm -f "$work/.suite.out"; [ -z "$scratch" ] || rm -rf "${scratch:?}"' EXIT

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
red_with_tests=""
if [ "$mode" = "per-test" ]; then
  # jq emits plain rows; classification happens in bash against the project's
  # failure-class patterns. Keeping the jq single-line and pattern-free is what
  # lets a linter parse this file and a reader follow it.
  local_tf="$(printf '%s' "$test_files" | jq -R . | jq -s .)"
  broken_re="$(jq -r '.failure_classes.broken | join("|")' "$project")"
  legit_re="$(jq -r '.failure_classes.legitimate | join("|")' "$project")"

  # Pre-existing tests — everything outside a declared test file — that fail.
  #
  # A repo already red makes this gate blind, so that is a stop, not a reject.
  # But this run happens AFTER the tests station has written its files, and for
  # one release every failure outside them was reported as "the pre-existing
  # suite is not green — fix the repo". A test green before the new files and
  # red with them is not the repo: on a live project it was a jest test that
  # runs `tsc --noEmit` over the whole tree, turned red by a new test importing
  # `./utils` — which the plan's files.create had not produced yet, exactly as a
  # red-first test in TypeScript must. Two tickets in a row stopped here with
  # advice that was false for them (docs/DEFECTS-6.md #1).
  #
  # So a failure outside the declared files is measured against a BASELINE:
  # the suite once more, in a copy of the tree as it stood when the tests
  # station was dispatched — the tree those files landed in. Only on this path,
  # so a green suite pays nothing for it. Three answers:
  #   red before   the repo. A stop, naming the tests.
  #   green before the tests' interaction with the suite. Admitted, recorded in
  #                the lock as red_with_tests and printed on the pass path:
  #                green requires the whole suite, and it can tell a failure
  #                the implementation clears from one it cannot reach.
  #   absent       a test that exists only with this ticket's files but lives
  #                outside the declared ones — the tests' own, not the repo's.
  pre_red="$(printf '%s' "$results" | jq -r --argjson tf "$local_tf" \
    '.[] | select(((.file // "") as $f | $tf | index($f)) | not) | select(.status == "failure" or .status == "error") | .id')"
  if [ -n "$pre_red" ]; then
    baseline=""
    classes=""
    base_why=""
    if [ -z "$base" ] || [ ! -e "$root/.git" ]; then
      base_why="there is no commit to measure it at"
    else
      scratch="$(aif_g_scratch_at "$root" "$base")"
      mkdir -p "$scratch/$(dirname "$report_path")" "$scratch/.aif/tmp"
      rm -f "${scratch:?}/${report_path:?}"
      (cd "$scratch" && eval "$test_cmd") >"$scratch/.aif/tmp/baseline.out" 2>&1 || true
      if [ ! -f "$scratch/$report_path" ]; then
        base_why="the suite wrote no report there — $(grep -v '^[[:space:]]*$' "$scratch/.aif/tmp/baseline.out" | tail -1 | cut -c1-160)"
      else
        baseline="$(python3 "$here/junit.py" "$scratch/$report_path" 2>/dev/null || true)"
        [ -n "$baseline" ] || base_why="the report it wrote could not be read"
      fi
    fi
    if [ -n "$baseline" ]; then
      printf '%s' "$baseline" >"$scratch/.aif/tmp/baseline.json"
      classes="$(printf '%s' "$results" | jq -r --argjson tf "$local_tf" \
        --slurpfile before "$scratch/.aif/tmp/baseline.json" '
        ($before[0] | map({ (.id): .status }) | add // {}) as $b
        | .[] | select(((.file // "") as $f | $tf | index($f)) | not)
        | select(.status == "failure" or .status == "error")
        | ($b[.id] // "") as $s
        | (if $s == "failure" or $s == "error" then "before" elif $s == "" then "absent" else "with" end)
          + "\t" + .id + "\t" + (.file // "")' 2>/dev/null)" || classes=""
      [ -n "$classes" ] || base_why="the run without them could not be compared with this one"
    fi
    [ -z "$scratch" ] || rm -rf "${scratch:?}"
    scratch=""

    # No baseline, no attribution: the stop that was always here, with names.
    if [ -z "$classes" ]; then
      printf 'ERROR  the pre-existing suite is not green (%s failing: %s) — fix the repo before authoring tests; red is meaningless otherwise\n' \
        "$(printf '%s\n' "$pre_red" | grep -c .)" "$(printf '%s\n' "$pre_red" | sed -n '1,3p' | paste -sd, - | sed 's/,/, /g')" >&2
      printf '%s\n' "$pre_red" | sed -n '1,20p' | sed 's/^/  - /' >&2
      printf '  Whether they were red before this ticket'"'"'s test files existed could not be told: %s.\n' "$base_why" >&2
      exit "$AIF_G_ERROR"
    fi
    red_before="$(printf '%s\n' "$classes" | awk -F'\t' '$1 == "before" { print $2 }')"
    red_with_tests="$(printf '%s\n' "$classes" | awk -F'\t' '$1 == "with" { print $2 }')"
    absent_nofile="$(printf '%s\n' "$classes" | awk -F'\t' '$1 == "absent" && $3 == "" { print $2 }')"
    absent_elsewhere="$(printf '%s\n' "$classes" | awk -F'\t' '$1 == "absent" && $3 != "" { print $2 " (in " $3 ")" }')"

    if [ -n "$red_before" ]; then
      printf 'ERROR  the pre-existing suite is red without this ticket'"'"'s test files too (%s failing: %s) — fix the repo before authoring tests; red is meaningless otherwise\n' \
        "$(printf '%s\n' "$red_before" | grep -c .)" "$(printf '%s\n' "$red_before" | sed -n '1,3p' | paste -sd, - | sed 's/,/, /g')" >&2
      printf '%s\n' "$red_before" | sed -n '1,20p' | sed 's/^/  - /' >&2
      printf '  Measured in a copy of the tree as it stood when the tests station was dispatched,\n' >&2
      printf '  before any of this ticket'"'"'s test files existed. They are the repository'"'"'s.\n' >&2
      if [ -n "$red_with_tests" ]; then
        printf '  Separately, these were green there and are red with the new test files:\n' >&2
        printf '%s\n' "$red_with_tests" | sed -n '1,20p' | sed 's/^/  - /' >&2
      fi
      exit "$AIF_G_ERROR"
    fi
    if [ -n "$absent_nofile" ]; then
      printf 'ERROR  %s failing test(s) exist only with this ticket'"'"'s test files, and the report names no file for them:\n' \
        "$(printf '%s\n' "$absent_nofile" | grep -c .)" >&2
      printf '%s\n' "$absent_nofile" | sed -n '1,20p' | sed 's/^/  - /' >&2
      printf '  This gate tells a new test from a pre-existing one by the file on each test case\n' >&2
      printf '  in %s. Make the reporter write it (jest-junit: addFileAttribute "true").\n' "$report_path" >&2
      exit "$AIF_G_ERROR"
    fi
    aif_g_report "$(printf '%s\n' "$absent_elsewhere" |
      sed '/^$/d; s/$/ fails, and exists only with this ticket'"'"'s test files — in a file files.tests does not declare; write the tests in the declared files/')" "tests"
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
  #   reject (exit 1) — a test that is not red for the right reason: skipped
  #     (the cheapest way to make red disappear), broken (syntax, a fixture
  #     that is not there — it did not run), or failing in a way that is
  #     neither an assertion nor the skeleton's marker (it calls a name the
  #     contract does not export). All three are the author's, and the author
  #     is still here: they come back to it, verbatim, with the message.
  #   green  (recorded) — passes at freeze. On a second round that is the
  #     honest test for an already-implemented criterion; see the header. It is
  #     kept, named in the lock, and kept OUT of covering.
  reject=""
  green_ids=""
  while IFS="$(printf '\t')" read -r file id status msg; do
    [ -n "$id" ] || continue
    : "$file"
    new_count=$((new_count + 1))
    if [ "$status" = "pass" ]; then
      green_ids="$green_ids
$id"
    elif [ "$status" = "skipped" ]; then
      reject="$reject
$id is skipped — a skipped test is not a red test"
    elif printf '%s' "$msg" | grep -qF -- "$AIF_G_NOT_IMPLEMENTED"; then
      : # red because the behaviour is not built: the skeleton threw
    elif [ -n "$broken_re" ] && printf '%s' "$msg" | grep -qE "$broken_re"; then
      reject="$reject
$id did not run — it is broken, not red: $(printf '%s' "$msg" | cut -c1-240)
    fix the test: it must fail because a criterion does not hold yet, and this is a test that could not be loaded or collected"
    elif [ -n "$legit_re" ] && printf '%s' "$msg" | grep -qE "$legit_re"; then
      : # an assertion did not hold
    else
      reject="$reject
$id fails for a reason that is neither an assertion nor the missing implementation: $(printf '%s' "$msg" | cut -c1-240)
    the contract is on disk, so a name it does not export, a wrong signature, or a fixture that is not there is the test's own defect — or add the class to failure_classes.legitimate if this project counts it as red"
    fi
  done <<EOF
$new_rows
EOF

  [ "$new_count" -gt 0 ] || aif_g_reject "no new tests were collected from the declared test files"

  aif_g_report "${reject# }" "tests"

  green_ids="$(printf '%s' "${green_ids# }" | grep -v '^$' || true)"
  green_count="$(printf '%s' "$green_ids" | grep -c . || true)"
  red_count=$((new_count - green_count))
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
    printf 'REJECT the new tests are not a usable oracle — the run matches a broken-failure class:\n' >&2
    grep -ohE "$broken_re" "$work/.suite.out" | sort -u | sed 's/^/  - /' >&2
    printf '  This is coarse mode (%s), so the gate cannot say WHICH test broke —\n' "$mode_why" >&2
    printf '  only that the suite did not merely fail, it failed to run.\n' >&2
    rm -f "$work/.suite.out"
    exit "$AIF_G_REJECT"
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

# --- coverage: every criterion is carried by a collected test ---------------
# A fully-backticked expect is the ready gate's convention for a domain literal
# that collides with the vague-word list (`error` the union value). The
# backticks are the declaration, not part of the value — strip them, so the
# tests assert the bare literal.
#
# "A test" is one the runner collected, and the criterion's marker is in that
# test's own id — `<ticket> AC-nnn`, matched after normalising both (see
# aif_g_norm) so a jest title and a python function name both carry it. It
# used to be a grep over the TEXT of the declared files, and that was
# satisfied by a comment listing the criteria, and by another ticket's
# AC-001 in a shared file (OPES-69's eight calculation criteria were "covered"
# by OPES-62's markers that way). The literal is then looked for in the file
# that test lives in.
#
# Coarse mode has no per-test report and cannot tell a collected test from
# one the runner never saw; it reads every declared file's text, as it always
# did, and its closing lines say so.
#
# listed <line> <lines> — rc 0 when <line> is one of <lines>, matched whole.
listed() {
  local needle="$1" line
  while IFS= read -r line; do
    [ "$line" = "$needle" ] && return 0
  done <<EOF
$2
EOF
  return 1
}
if [ "$mode" = "per-test" ]; then
  cov_files="$(printf '%s\n' "$new_rows" | cut -f1 | grep -v '^$' | sort -u)"
else
  cov_files="$test_files"
fi
uncollected=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  listed "$f" "$cov_files" || uncollected="$uncollected, $f"
done <<EOF
$(printf '%s\n' "$test_files" | awk '!seen[$0]++')
EOF
uncollected="${uncollected#, }"

# Every new test's normalised id with its file and status, for the marker
# search: "<norm-id><TAB><file><TAB><status>".
norm_rows=""
if [ "$mode" = "per-test" ]; then
  norm_rows="$(printf '%s\n' "$new_rows" | while IFS="$(printf '\t')" read -r file id status msg; do
    [ -n "$id" ] || continue
    : "$msg"
    printf '%s\t%s\t%s\n' "$(aif_g_norm "$id")" "$file" "$status"
  done)"
fi

cov=""
built_ok=""
while IFS= read -r ac; do
  [ -n "$ac" ] || continue
  expect="$(printf '%s' "$spec_meta" | jq -r --arg id "$ac" \
    '.acceptance[] | select(.id==$id) | .expect | tostring
     | if test("^`[^`]+`$") then .[1:-1] else . end')"
  marker="$(aif_g_norm "$ticket_id $ac")"

  if [ "$mode" = "per-test" ]; then
    # The tests whose id carries the marker, and the files they live in.
    carriers="$(printf '%s\n' "$norm_rows" | awk -F'\t' -v m="$marker" 'index($1, m) > 0 { print $2 "\t" $3 }')"
    if [ -z "$carriers" ]; then
      ref_only=""
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        listed "$f" "$cov_files" && continue
        grep -qF -- "$ac" "$root/$f" 2>/dev/null && ref_only="$ref_only, $f"
      done <<EOF
$test_files
EOF
      if [ -n "$ref_only" ]; then
        cov="$cov
$ac is named only in a file the runner collected no test from: ${ref_only#, } — a test there runs nowhere"
      else
        cov="$cov
$ac is carried by no collected test — put \"$ticket_id $ac\" in the name of the test that proves it (a jest title, a pytest function name test_${marker}_…), not in a comment"
      fi
      continue
    fi
    # The criterion's literal, in a file one of its carriers lives in: the
    # cheap guard against a test that is red now but green against any stub.
    #
    # `--` because the pattern is the ticket's own value: an expect of "-1" —
    # what indexOf returns, what a criterion about a missing item asserts — is
    # an OPTION to grep, and the search silently answers "not found" about a
    # test where the literal plainly is. The station cannot fix that; it burns
    # attempts_max runs and stops the ticket.
    lit_hit=0
    while IFS="$(printf '\t')" read -r cf cs; do
      [ -n "$cf" ] || continue
      : "$cs"
      grep -qF -- "$expect" "$root/$cf" 2>/dev/null && lit_hit=1
    done <<EOF
$carriers
EOF
    [ "$lit_hit" -eq 1 ] || cov="$cov
$ac expected value ($expect) does not appear in the file of the test that carries it ($(printf '%s\n' "$carriers" | cut -f1 | sort -u | paste -sd, - | sed 's/,/, /g'))"
    # A criterion the station declared already built must be green, or the
    # declaration is wrong; one it did not declare and that is green anyway
    # is recorded as green at freeze below, as before.
    if printf '%s\n' "$note_built" | grep -qxF -- "$ac"; then
      if printf '%s\n' "$carriers" | awk -F'\t' '$2 == "pass" { f = 1 } END { exit !f }'; then
        built_ok="$built_ok
$ac"
      else
        cov="$cov
$ac is declared already built in tests.note.json, but its test is red — the declaration and the test disagree; one of them is wrong"
      fi
    fi
  else
    # Coarse: the text of every declared file, as it always was.
    ref_hit=0 lit_hit=0
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      grep -qF -- "$ac" "$root/$f" 2>/dev/null && ref_hit=1
      grep -qF -- "$expect" "$root/$f" 2>/dev/null && lit_hit=1
    done <<EOF
$test_files
EOF
    [ "$ref_hit" -eq 1 ] || cov="$cov
$ac is not referenced by any test file"
    [ "$lit_hit" -eq 1 ] || cov="$cov
$ac expected value ($expect) does not appear in any test"
  fi
done <<EOF
$(printf '%s' "$spec_meta" | jq -r '.acceptance[].id')
EOF
# On a rejection, every declared file that contributed no test is named — not
# only the ones a criterion was found in. A test written there without its id
# is just as absent, and the station is being sent back anyway.
if [ -n "$cov" ] && [ -n "$uncollected" ]; then
  cov="$cov
the runner collected no test from: $uncollected — a test there runs neither at this gate nor at green
  A file is not collected when its name or place is outside what the runner selects (testMatch, python_files, the test roots), or when it fails to load and the reporter leaves it out (jest-junit does, unless reportTestSuiteErrors is set).
  A support file — a helper, a conftest — needs no test of its own, and counts toward no criterion."
fi
aif_g_report "${cov# }" "coverage"

# Nothing red: the ticket is done already, or the tests assert nothing. The
# station can say which — every criterion in tests.note.json's already_built,
# each confirmed green above — and then it is the ticket's, not the tests'.
if [ "$mode" = "per-test" ] && [ "$red_count" -eq 0 ]; then
  acs_n="$(printf '%s' "$spec_meta" | jq '.acceptance | length')"
  built_n="$(printf '%s' "$built_ok" | grep -c . || true)"
  if [ "${built_n:-0}" -gt 0 ] && [ "$built_n" -eq "$acs_n" ]; then
    aif_g_spec "$(printf 'every criterion is already built, by the tests station'"'"'s own account, and its tests are green against the tree before any implementation: %s\nthe ticket asks for nothing the repository does not do already; either it is done, or the criteria do not describe what is missing' \
      "$(printf '%s' "$built_ok" | grep -v '^$' | paste -sd, - | sed 's/,/, /g')")"
  fi
  aif_g_reject "all $new_count new test(s) are already green — nothing red remains to implement; either the ticket is already done (say so: tests.note.json, already_built), or the tests assert nothing"
fi

# --- the project's own checks, for this phase -------------------------------
# Bound to "red" deliberately: at this moment no implementation exists, so a
# build would fail CORRECTLY and a phase-blind checks list would reject the red
# phase for being red by design. With the contract on disk a type-check is
# clean here — every symbol a test touches exists, typed — so a type error at
# red IS the test's, and it comes back to the station that wrote it. A project
# without a contract keeps `legitimate_at_red` for what the missing
# implementation causes (docs/DEFECTS-6.md #2).
mkdir -p "$root/.aif/tmp"
check_viol="$(aif_g_checks_run "$project" "$root" "red" "$root/.aif/tmp/checks-red.json" "$test_files")"
# A check that failed without naming one of the test files is not the tests
# station's to fix, and a retry would burn an opus attempt on it — a stop.
if [ "$(jq '[ .[]? | select(.required and .result == "unlocated") ] | length' \
  "$root/.aif/tmp/checks-red.json" 2>/dev/null)" != "0" ]; then
  printf 'ERROR  a check bound to red fails somewhere other than this ticket'"'"'s test files — the tests station cannot clear it:\n' >&2
  printf '%s\n' "$check_viol" |
    sed '/^[[:space:]]*$/d; /^[[:space:]]/s/^/    /; /^[^[:space:]]/s/^/  - /' >&2
  printf '  legitimate_at_red lets through what the missing implementation causes IN the test\n' >&2
  printf '  files, and nothing of this names one. Either the repository fails the check without\n' >&2
  printf '  this ticket — fix it there — or the check prints paths that are not relative to the\n' >&2
  printf '  project root, and cannot be read against the plan'"'"'s files.tests.\n' >&2
  exit "$AIF_G_ERROR"
fi
aif_g_report "$check_viol" "checks"

# --- a dry run ends here: the verdict, and nothing frozen --------------------
# The station called this itself. Everything above ran and every complaint
# would have printed; what does not happen is the second run (the station's
# loop pays for one) and the lock.
if [ "$dry" = "1" ]; then
  if [ "$mode" = "coarse" ]; then
    printf 'verify-red (dry): red, COARSE mode — %s\n' "$mode_why"
  else
    printf 'verify-red (dry): %s new test(s) red for the right reason, all criteria covered\n' "$red_count"
    [ "$green_count" -eq 0 ] || printf '  ! %s new test(s) green already: %s\n' \
      "$green_count" "$(printf '%s' "$green_ids" | paste -sd, - | sed 's/,/, /g' | cut -c1-200)"
    [ -z "$uncollected" ] || printf '  ! the runner collected no test from: %s\n' "$uncollected"
  fi
  printf '  nothing frozen — this was aif _verify; the worker runs the gate for real when you finish\n'
  # The checks record is the real run's to write and `aif _gate`'s to fold; a
  # dry run's would be folded as if the gate had run.
  rm -f "$work/.suite.out" "$root/.aif/tmp/checks-red.json"
  exit 0
fi

# --- red twice: a test whose status moves is not red, it is random -----------
# The suite once more, and every new test must come back as it was. A test
# that flipped is non-deterministic — a clock, an order, a shared state — and
# a freeze over it would be a coin the implement station is judged with.
flaky=""
if [ "$mode" = "per-test" ]; then
  rm -f "$root/$report_path"
  (cd "$root" && eval "$test_cmd") >"$work/.suite.out" 2>&1 || true
  again=""
  [ ! -f "$root/$report_path" ] || again="$(python3 "$here/junit.py" "$root/$report_path" 2>/dev/null || true)"
  if [ -n "$again" ]; then
    printf '%s' "$again" >"$work/.suite.again.json"
    flaky="$(printf '%s' "$results" | jq -r --argjson tf "$local_tf" --slurpfile a "$work/.suite.again.json" '
      ($a[0] | map({ (.id): .status }) | add // {}) as $b
      | .[] | select((.file // "") as $f | $tf | index($f))
      | select(($b[.id] // "absent") != .status)
      | .id + " was " + .status + " then " + ($b[.id] // "absent")' 2>/dev/null)"
    rm -f "$work/.suite.again.json"
  else
    printf '  ! the second run wrote no readable report; red was observed once\n'
  fi
  if [ -n "$flaky" ]; then
    aif_g_report "$(printf '%s\n' "$flaky" | sed 's/$/ — a test whose verdict moves between two runs of the same tree is non-deterministic; it proves nothing about the code/')" "tests"
  fi
fi

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
# restore it and confirm the tests go red again: the change files, and every
# create path that exists already — the skeleton. A create path absent now
# (no_skeleton) is recorded as to-be-created, and green removes it in the
# reverted copy. covering is the new RED test ids, for green's revert-recheck
# to target; a test green at freeze goes to green_at_freeze instead — reverting
# this round's code was never going to turn it red, and demanding that would
# accuse an honest test on a second round.
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
in_frozen() { listed "$1" "$frozen_paths"; }

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
    [ -f "$root/$f" ] || continue
    printf '%s\t%s\n' "$f" "$(aif_g_sha256 "$root/$f")"
  done <<EOF
$change_files
$create_files
EOF
)"
impl_created="$(
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -e "$root/$f" ] || printf '%s\n' "$f"
  done <<EOF
$create_files
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
  --argjson create "$(printf '%s' "$impl_created" | jq -R . | jq -s 'map(select(length>0))')" \
  --argjson covering "$(printf '%s' "$covering_json" | jq -R . | jq -s 'map(select(length>0))')" \
  --argjson green "$(printf '%s' "$green_ids" | jq -R . | jq -s 'map(select(length>0))')" \
  --argjson with "$(printf '%s' "$red_with_tests" | jq -R . | jq -s 'map(select(length>0))')" \
  --argjson declared "$(printf '%s' "$test_files" | jq -R . | jq -s 'map(select(length>0))')" \
  --argjson collected "$(printf '%s' "$cov_files" | jq -R . | jq -s 'map(select(length>0))')" '
  def rows($raw): $raw | split("\n") | map(select(length>0) | split("\t"))
    | map({ (.[0]): .[1] }) | add // {};
  { schema: 1, plan_sha256: $plan_hash, mode: $mode, mode_reason: $mode_reason, at: $at,
    tests: rows($tests_raw),
    covering: $covering,
    green_at_freeze: $green,
    impl_frozen: rows($impl_raw),
    impl_created: $create,
    suite_at_freeze: rows($suite_raw),
    red_with_tests: $with,
    declared_files: $declared,
    collected_files: (if $mode == "per-test" then $collected else null end) }' >"$work/tests.lock.json"

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
  printf '  ! coverage was read from every declared test file — whether the runner collects each one cannot be told here.\n'
else
  with_count="$(printf '%s' "$red_with_tests" | grep -c . || true)"
  printf 'verify-red: %s new test(s) red for the right reason, twice, all criteria covered' "$red_count"
  # On the first line, because that is the line the ledger and the report keep.
  [ "${with_count:-0}" -eq 0 ] ||
    printf ' — and %s pre-existing test(s) red only with them' "$with_count"
  printf '\n'
  if [ "${with_count:-0}" -gt 0 ]; then
    printf '  ! RED WITH THE NEW TESTS — green without this ticket'"'"'s test files, red once they landed:\n'
    printf '%s\n' "$red_with_tests" | sed 's/^/    - /'
    printf '  Not the repository'"'"'s: measured against the tree the tests station started from.\n'
    printf '  The implementation has to clear them — green requires the whole suite, and\n'
    printf '  sends the tests back for one that fails the same way without the code.\n'
  fi
  if [ "$green_count" -gt 0 ]; then
    # On the PASS path, always — the same rule the other gates follow for what
    # they allowed. A degradation only readable out of a lock file is silent.
    printf '  ! GREEN AT FREEZE — never proven red, an earlier round already implemented these:\n'
    printf '%s\n' "$green_ids" | sed 's/^/    - /'
    printf '  Excluded from the revert-recheck; re-emitted on the closing checklist.\n'
  fi
  if [ -n "$uncollected" ]; then
    printf '  ! the runner collected no test from: %s — counted toward no criterion (a support file needs none; a test there never runs)\n' "$uncollected"
  fi
fi
