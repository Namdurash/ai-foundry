#!/usr/bin/env bash
#
# Gate: green — is the project's Definition of Done met, because the
# implementation is real?
#
# The mirror of verify-red, and it is not just "the tests pass". Four things
# have to hold, and the third is the one that catches a defeated oracle:
#
#   - the test tree is byte-identical to what verify-red froze, so the tests that
#     pass are the tests that were red — not tests quietly weakened, and not
#     logic smuggled into a conftest the declared-file list would miss;
#   - every test passes, and a skipped test fails this gate (a skip is the
#     cheapest way to make red go away without implementing anything);
#   - reverting the implementation makes the covering tests go red again. A test
#     that stays green with the code reverted never depended on it — it asserts
#     nothing, and it is exactly what a small model reaches for under pressure;
#   - every check the project bound to this phase passes. This gate used to read
#     exactly one thing — `.test.command` — so a project whose Definition of Done
#     included a compiler, a linter or a dependency-integrity pass could not say
#     so, and the pipeline therefore never enforced it. A module that did not
#     compile on its target runtime shipped through a green suite that way.
#
# Under all four sits one rule about the evidence itself: the report is read
# beside the runner that wrote it, never alone. A junit reporter emits one
# <testcase> per test and therefore NONE for a suite that failed to run, so a
# report can be entirely silent about a broken file and read as a clean pass.
# When the runner and its own report disagree, this gate answers 3 — it cannot
# render a verdict — rather than picking the more convenient of the two.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source-path=SCRIPTDIR source=_lib.sh
. "$here/_lib.sh"

aif_g_need jq

work="${1:-}"
[ -n "$work" ] || aif_g_error "usage: green.sh <work-dir>"

plan="$work/plan.md"
lock="$work/tests.lock.json"
# A ticket frozen before the rename still has the old name and is mid-flight;
# reading it is three lines, and the alternative is telling someone whose tests
# are already red to author them again.
[ -f "$lock" ] || [ ! -f "$work/tests.lock" ] || lock="$work/tests.lock"
project="$(aif_g_project "$work")" || exit $?
root="$(dirname "$(dirname "$project")")"

[ -f "$plan" ] || aif_g_error "plan.md missing"
[ -f "$lock" ] || aif_g_reject "no tests.lock.json — run the tests station (verify-red) first"

# The lock must be for the current plan; otherwise "green" is measured against a
# stale oracle.
if [ "$(jq -r '.plan_sha256 // ""' "$lock")" != "$(aif_g_sha256 "$plan")" ]; then
  aif_g_reject "tests.lock.json is for a different plan — re-run the tests station"
fi

# The lock must hold THIS ticket's oracle, not merely some tests. verify-red
# freezes the union of test.roots and the plan's declared test files and refuses
# to write a lock that misses either — but the lock is a file on disk that a
# hand, an older aif, or a misconfigured test.roots can produce, and a freeze
# over the wrong tree looks exactly like a freeze until someone reads it. The
# plan says which files this ticket's oracle lives in; they must be in there.
missing_frozen=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ "$(jq -r --arg p "$f" '.tests[$p] // ""' "$lock")" != "" ] || missing_frozen="$missing_frozen
$f is a declared test file that the freeze does not hold — the implementation could edit the oracle it is judged against"
done <<EOF
$(aif_g_meta "$plan" | jq -r '.files.tests[]? // empty' 2>/dev/null)
EOF

if [ -n "$(printf '%s' "${missing_frozen# }" | grep -v '^$' || true)" ]; then
  printf 'ERROR  the freeze does not cover this ticket — re-run the tests station:\n' >&2
  printf '%s\n' "${missing_frozen# }" | grep -v '^$' | sed 's/^/  - /' >&2
  exit "$AIF_G_ERROR"
fi

# --- the test tree is frozen -----------------------------------------------
# Additions first: walk the live tree under test.roots and flag anything the
# lock does not hold. The whole tree, so a fixture cannot be the hiding place.
drift=""
while IFS= read -r rootdir; do
  [ -n "$rootdir" ] || continue
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$root"/}"
    if [ -z "$(jq -r --arg p "$rel" '.tests[$p] // ""' "$lock")" ]; then
      drift="$drift
$rel was added under the test tree after the tests were frozen"
    fi
  done <<EOF
$(find "$root/$rootdir" -type f 2>/dev/null)
EOF
done <<EOF
$(jq -r '.test.roots[]?' "$project")
EOF

# Then modifications and deletions, driven by the LOCK rather than by the tree.
# The lock holds the union of test.roots and the plan's declared test files, and
# a ticket whose tests live beside their sources has entries outside every root
# — walking the tree alone would freeze those files and then never look at them
# again, which is a guarantee on paper only.
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if [ ! -f "$root/$rel" ]; then
    drift="$drift
$rel was deleted after the tests were frozen"
  elif [ "$(jq -r --arg p "$rel" '.tests[$p] // ""' "$lock")" != "$(aif_g_sha256 "$root/$rel")" ]; then
    drift="$drift
$rel was modified after the tests were frozen"
  fi
done <<EOF
$(jq -r '.tests | keys[]' "$lock")
EOF

aif_g_report "${drift# }" "test tree"

# --- the suite is green ------------------------------------------------------
#
# "No skips" is the right rule for THIS TICKET'"'"'S tests and the wrong rule for
# everything else, and for one release it was applied to everything. A skip in
# a frozen covering test is the cheapest way to make red go away without
# implementing anything, so it is a rejection. A skip somewhere else in the
# project is ordinary: a platform guard, an importorskip, a slow marker. The
# gate used to reject on any of those, which meant that any repository with a
# single skipped test anywhere passed verify-red (which explicitly allows them)
# and could then never pass green. The two gates disagreed about what a skip
# means, and the one that was wrong was this one.
#
# What is still caught: a pre-existing test that was PASSING when the tests
# were frozen and is skipped now. The implementation cannot edit a test — the
# tree is hash-locked — but it can change source so one stops collecting, and
# that is a regression however it happened. verify-red records the rest of the
# suite'"'"'s status at freeze so this can be told apart from a skip that was
# always there. A lock written before that field existed carries no such
# record, and the gate says so rather than pretending to check it.
test_cmd="$(jq -r '.test.command' "$project")"
report_path="$(jq -r '.test.report.path' "$project")"
[ -n "$report_path" ] && [ "$report_path" != "null" ] ||
  aif_g_error "project.json names no test.report.path — this gate has nothing to read"
mkdir -p "$root/$(dirname "$report_path")"
# The last run's report is deleted before this one, so that a command which
# never reaches its reporter cannot be judged on a file it did not write. See
# the same note in verify-red.sh: the gates decide, and they were the two places
# that read this path without first clearing it.
rm -f "$root/$report_path"
# The suite's raw output is scratch, and it lives inside tasks/<ID>/ — which the
# worker commits. Every early exit below used to leak it there (docs/DEFECTS-3.md
# #14): the removals were written on the pass paths only, and a rejection is the
# common case. A gate is its own process, so a plain EXIT trap is the whole fix.
trap 'rm -f "$work/.suite.out"' EXIT

suite_rc=0
(cd "$root" && eval "$test_cmd") >"$work/.suite.out" 2>&1 || suite_rc=$?

# What the LOCK is, as distinct from what this run is. A lock written in coarse
# mode holds no per-test record at all: covering is empty, suite_at_freeze is
# empty, and the three checks below that read them therefore check nothing. That
# was invisible — this gate printed the same confident sentence either way.
lock_mode="$(jq -r '.mode // "per-test"' "$lock")"

allowed_skips=0
freeze_known=yes
[ "$lock_mode" = "per-test" ] || freeze_known=no
if aif_g_have python3 && [ -f "$root/$report_path" ]; then
  results="$(python3 "$here/junit.py" "$root/$report_path" 2>/dev/null || true)"
  if [ -n "$results" ]; then
    [ "$(jq -r 'has("suite_at_freeze")' "$lock")" = "true" ] || freeze_known=no

    # --- the report is evidence, not testimony ---------------------------
    # A reporter emits one <testcase> per test, and therefore emits NONE for a
    # suite that failed to RUN — no failing <testsuite> either, on jest-junit.
    # The file is simply absent from the report, and a report read on its own
    # then says "everything passed" about a run that plainly did not. Measured:
    # a suite reporting `1 failed, 26 passed` produced a report with zero
    # occurrences of the failing file, and this gate passed the ticket on it.
    #
    # So the report is cross-checked against the runner. A non-zero run whose
    # own report names nothing failing is neither a pass nor a rejection: it is
    # a gate that cannot render a verdict, which is what exit 3 means.
    failed_in_report="$(printf '%s' "$results" | jq -r \
      '[ .[] | select(.status == "failure" or .status == "error") ] | length' 2>/dev/null)"
    if [ "$suite_rc" -ne 0 ] && [ "${failed_in_report:-0}" -eq 0 ]; then
      printf 'ERROR  the report contradicts the runner, so it cannot carry a verdict:\n' >&2
      printf '  - the suite exited %s; its report names no failing test\n' "$suite_rc" >&2
      printf '  - a suite that fails to RUN emits no test case, so the report is silent about it\n' >&2
      printf '  - the last lines of the run were:\n' >&2
      tail -5 "$work/.suite.out" | sed 's/^/      /' >&2
      rm -f "$work/.suite.out"
      exit "$AIF_G_ERROR"
    fi
    # Bound once, read four times below. They were four identical sub-shells.
    mine_json="$(jq -c '((.covering // []) + (.green_at_freeze // []))' "$lock")"
    freeze_json="$(jq -c '.suite_at_freeze // null' "$lock")"

    # A failing test that is not one of this ticket's own used to be reported,
    # unconditionally, as "the pre-existing suite broke". That sentence is a
    # claim about WHERE a test came from, and the gate was not checking: on a
    # live ticket it was printed about six tests in a file the run had just
    # created, and the human read it as a regression in their own repository.
    #
    # The freeze knows. verify-red records the whole suite's status at freeze
    # time, so an id absent from that record did not exist when the tests were
    # frozen and cannot be pre-existing — whatever else it is.
    notpass="$(printf '%s' "$results" | jq -r \
      --argjson mine "$mine_json" \
      --argjson freeze "$freeze_json" '
      .[]
      | . as $t
      | if ($mine | index($t.id)) != null then
          (if $t.status != "pass"
            then $t.id + " (" + $t.status + ") — a test this ticket froze, so it must pass; a skip here is red made to go away without implementing anything"
            else empty end)
        elif ($t.status == "failure" or $t.status == "error") then
          (if $freeze == null then
             $t.id + " (" + $t.status + ") — origin unknown: this lock predates suite_at_freeze, so a pre-existing test cannot be told from one this ticket authored"
           elif (($freeze[$t.id] // "") == "") then
             $t.id + " (" + $t.status + ") — NOT pre-existing: absent from the suite when the tests were frozen, so it arrived with this ticket'"'"'s own test files"
           else
             $t.id + " (" + $t.status + ") — the pre-existing suite broke"
           end)
        elif $t.status == "skipped" then
          (if $freeze != null and (($freeze[$t.id] // "") == "pass")
            then $t.id + " (skipped) — it was passing when the tests were frozen, so something in this change silenced it"
            else empty end)
        else empty end')"

    # The same three populations, counted, because the counts decide WHO is
    # being rejected — and that is a different question from what to print.
    counts="$(printf '%s' "$results" | jq -r \
      --argjson mine "$mine_json" \
      --argjson freeze "$freeze_json" '
      # Each arm is parenthesised. In jq the comma binds TIGHTER than the pipe,
      # so [A] | length, [B] | length is not three counts but one pipeline that
      # ends up calling .[] on a number. It did, and the error went into the
      # output of this gate and became the recorded reason for a PASS.
      ([ .[] | . as $t | select(($mine | index($t.id)) != null)
             | select($t.status != "pass") ] | length),
      ([ .[] | . as $t | select(($mine | index($t.id)) == null)
             | select($t.status == "failure" or $t.status == "error")
             | select($freeze != null and (($freeze[$t.id] // "") != "")) ] | length),
      ([ .[] | . as $t | select(($mine | index($t.id)) == null)
             | select($t.status == "failure" or $t.status == "error")
             | select($freeze != null and (($freeze[$t.id] // "") == "")) ] | length)')"
    mine_fail="$(printf '%s\n' "$counts" | sed -n 1p)"
    pre_fail="$(printf '%s\n' "$counts" | sed -n 2p)"
    post_fail="$(printf '%s\n' "$counts" | sed -n 3p)"

    if [ -n "$notpass" ]; then
      # Whose defect is it? The implement station may write only files.change,
      # and every test file is hash-locked by tests.lock.json — so when nothing
      # failing is either one of this ticket's frozen tests or a pre-existing
      # one, what failed can only be a test that arrived with the oracle, and
      # implement cannot reach it. Rejecting implement there is not merely
      # unfair, it is unsatisfiable: measured at three dispatches, 93 turns and
      # 51 580 output tokens before limits.attempts_max stopped the run.
      #
      # So it is a 3, not a 1: the gate cannot render a verdict on THIS
      # station's work, and the loop must stop instead of retrying.
      if [ "$lock_mode" = "per-test" ] && [ "${mine_fail:-0}" -eq 0 ] &&
        [ "${pre_fail:-0}" -eq 0 ] && [ "${post_fail:-0}" -gt 0 ]; then
        printf 'ERROR  the failing tests are the oracle, not the implementation:\n' >&2
        printf '%s\n' "$notpass" | sed 's/^/  - /' >&2
        printf '  Every one of them arrived with this ticket'"'"'s own test files, which are frozen by\n' >&2
        printf '  tests.lock.json and outside files.change. The implement station cannot fix what it\n' >&2
        printf '  is being rejected for. Re-run the tests station against this plan.\n' >&2
        rm -f "$work/.suite.out"
        exit "$AIF_G_ERROR"
      fi
      printf 'REJECT suite is not green:\n' >&2
      printf '%s\n' "$notpass" | sed 's/^/  - /' >&2
      if [ "$lock_mode" != "per-test" ]; then
        printf '  The lock is COARSE (%s), so it names no covering test and no suite at freeze —\n' \
          "$(jq -r '.mode_reason // "reason not recorded"' "$lock")" >&2
        printf '  nothing above could be attributed to a station. Fix that first.\n' >&2
      fi
      exit "$AIF_G_REJECT"
    fi
    # `. as $t` first: inside index(f), jq evaluates f against the ARRAY being
    # searched, not against the element — so `index(.id)` asks $mine for its
    # own .id and dies with "Cannot index array with string". It did, on the
    # pass path, where the error became the recorded reason for a PASS.
    allowed_skips="$(printf '%s' "$results" | jq -r \
      --argjson mine "$mine_json" \
      '[ .[] | . as $t | select($t.status == "skipped")
         | select(($mine | index($t.id)) == null) ] | length' 2>/dev/null)"
    case "$allowed_skips" in
      '' | *[!0-9]*) allowed_skips=0 ;;
    esac
  else
    aif_g_error "test report was not parseable — cannot confirm green"
  fi
else
  # Coarse: exit code only. Weaker, and a skip is invisible here — so say which
  # of the two reasons put the gate here, rather than leaving the reader to
  # guess between a missing interpreter and a missing report.
  if ! aif_g_have python3; then
    coarse_why="python3 is not on PATH (PATH=${PATH:0:200})"
  else
    coarse_why="the suite (exit $suite_rc) wrote no report at $report_path"
  fi
  # The exit code alone. The grep this used to OR in — `fail|error` anywhere in
  # the output — rejected a green suite for a test NAMED test_error_handling,
  # for a captured log line, for tsc's "0 errors", with a complaint no station
  # could act on (docs/DEFECTS-3.md #5).
  if [ "$suite_rc" -ne 0 ]; then
    aif_g_reject "the suite is not green (exit $suite_rc; coarse mode: $coarse_why)"
  fi
fi

# --- revert-recheck: the tests must actually depend on the code -------------
# Restore the implementation to its red-time state in a throwaway copy of the
# repo, re-run, and require the covering tests to fail again. A copy, not the
# live tree — the same disposable-copy reasoning as the eval harness — so this
# check cannot damage the work.
#
# Whether it ran at all is now carried in recheck_why rather than assumed. An
# empty `covering` list makes the loop below a no-op, and a lock frozen in
# coarse mode has an empty covering list BY CONSTRUCTION — so on exactly the
# runs where the oracle is weakest, this gate used to print its strongest
# sentence about a check that had looked at nothing. The copy is skipped
# outright in that case: it is a full copy of the working tree, and there is
# nothing to learn from it.
recheck_ok=1
recheck_why="needs git and python3"
scratch=""
covering_n="$(jq -r '(.covering // []) | length' "$lock")"
if [ "${covering_n:-0}" -eq 0 ]; then
  recheck_ok=0
  recheck_why="the lock names no covering test, so there was nothing to revert-recheck"
  [ "$lock_mode" = "per-test" ] ||
    recheck_why="$recheck_why (the lock is COARSE: $(jq -r '.mode_reason // "reason not recorded"' "$lock"))"
elif [ ! -e "$root/.git" ] || ! aif_g_have python3; then
  recheck_ok=0
else
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/aif-green-XXXXXX")"
  cp -R "$root/." "$scratch/" 2>/dev/null || true

  # change files: back to frozen content. create files: remove them.
  #
  # From the commit the worker recorded at dispatch, not from the index. The
  # implement station has Bash, and after one `git commit` from it the index
  # already held the implementation: the checkout was a no-op, every covering
  # test stayed green, and this gate told the station its tests were worthless
  # when what had happened was that it committed (docs/DEFECTS-3.md #8).
  base="$(aif_g_dispatch_base "$work" "$root")"
  jq -r '.impl_frozen | to_entries[] | .key' "$lock" | while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    # The frozen content is not stored, only its hash — so revert by checking
    # out the baseline's version, and prove it below against that hash.
    git -C "$scratch" checkout -q "$base" -- "$rel" 2>/dev/null || true
  done
  jq -r '.impl_created[]?' "$lock" | while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    rm -f "$scratch/$rel"
  done

  # The revert is proven, file by file, against the hashes verify-red froze. A
  # revert that did not happen used to be indistinguishable from tests that
  # assert nothing; now it is named for what it is, and it is a 3, because no
  # retry of the implementation changes what the baseline holds.
  tab="$(printf '\t')"
  not_restored=""
  while IFS="$tab" read -r rel want; do
    [ -n "$rel" ] || continue
    [ "$(aif_g_sha256 "$scratch/$rel")" = "$want" ] || not_restored="$not_restored
$rel"
  done <<EOF
$(jq -r '.impl_frozen | to_entries[] | [.key, .value] | @tsv' "$lock")
EOF
  not_restored="$(printf '%s' "${not_restored# }" | grep -v '^$' || true)"
  if [ -n "$not_restored" ]; then
    rm -rf "$scratch"
    printf 'ERROR  the revert-recheck could not restore the frozen implementation from %s:\n' \
      "$(printf '%s' "$base" | cut -c1-10)" >&2
    printf '%s\n' "$not_restored" | sed 's/^/  - /' >&2
    printf '  At that commit the file does not match its hash in tests.lock.json. When a gate\n' >&2
    printf '  is run by hand there is no dispatch baseline, only HEAD — and if the station\n' >&2
    printf '  committed its work, HEAD already holds the change being reverted.\n' >&2
    exit "$AIF_G_ERROR"
  fi

  # The scratch is a copy of the tree AFTER the green run, so it carries that
  # run's report. If the reverted run fails to produce one, that stale file is
  # what gets parsed — every covering test reads as "pass", and the gate rejects
  # a correct implementation for tests that "do not depend on" it.
  rm -f "$scratch/$report_path"
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
    recheck_why="the reverted run wrote no report at $report_path"
  fi
fi

[ -z "$scratch" ] || rm -rf "$scratch"
rm -f "$work/.suite.out"

# --- the rest of the Definition of Done ------------------------------------
# Run last, because the suite is the cheapest signal and there is no point
# type-checking code whose tests do not pass. The record goes under .aif/tmp/,
# which is gitignored: an artifact written into tasks/ at this moment would show
# up in scope's diff as an implementation editing the pipeline's own machinery,
# and scope would reject a correct implementation for the bookkeeping of the gate
# that admitted it. `aif _gate` folds the record into the ledger afterwards.
mkdir -p "$root/.aif/tmp"
check_viol="$(aif_g_checks_run "$project" "$root" "green" "$root/.aif/tmp/checks-green.json")"
aif_g_report "$check_viol" "checks"

checks_ran="$(jq 'length' "$root/.aif/tmp/checks-green.json" 2>/dev/null || echo 0)"

if [ "$recheck_ok" -eq 0 ]; then
  printf 'green: suite passes (revert-recheck NOT done — %s)' "$recheck_why"
else
  printf 'green: suite passes, and the covering tests depend on the implementation'
fi
# On the PASS path, always. A test that did not run is a criterion nobody
# exercised, whoever skipped it and whenever.
if [ "${allowed_skips:-0}" -gt 0 ]; then
  printf ', %s skipped elsewhere in the suite' "$allowed_skips"
  [ "$freeze_known" = yes ] ||
    printf ' (this lock predates suite_at_freeze, so a NEWLY skipped test cannot be told from an old one — re-run the tests station to get that check)'
fi
if [ "${checks_ran:-0}" -gt 0 ]; then
  printf ', %s check(s) green' "$checks_ran"
fi
printf '\n'
