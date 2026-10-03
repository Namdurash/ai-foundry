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
#
# And one answer this gate gives that is neither a rejection nor a stop: 4,
# REPAIR. A failure that is the ORACLE's — a test that arrived with the
# ticket's own files and fails whatever the code does, a check failing in a
# frozen test file the same way without the implementation, a pre-existing
# test the new test files break, a frozen test the implementer declares wrong
# in its note — is nothing the implement station can clear, and it used to be
# a stop for a human. It goes to the tests station now, which repairs it in a
# copy of the tree with the implementation reverted to the skeleton, under the
# same gate that admitted the original (docs/REBUILD-4.md §2.3). The one
# attribution that stays a stop is a dependency that moved outside the tracked
# tree: no station's edit reaches that.

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
# "No skips" is the right rule for THIS TICKET'S tests and the wrong rule for
# everything else, and for one release it was applied to everything. A skip in
# a frozen covering test is the cheapest way to make red go away without
# implementing anything, so it is a rejection. A skip somewhere else in the
# project is ordinary: a platform guard, an importorskip, a slow marker. The
# gate used to reject on any of those, which meant that any repository with a
# single skipped test anywhere passed verify-red (which explicitly allows them)
# and could then never pass green. The two gates disagreed about what a skip
# means, and the one that was wrong was this one.
#
# What is still caught: a pre-existing test that RAN when the tests were
# frozen and is skipped now. The implementation cannot edit a test — the tree
# is hash-locked — but it can change source so one stops collecting, and that
# is a regression however it happened. verify-red records the rest of the
# suite's status at freeze so this can be told apart from a skip that was
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
# worker commits. Every early exit below used to leak it there (docs/DEFECTS.md (log 3)
# #14): the removals were written on the pass paths only, and a rejection is the
# common case. A gate is its own process, so a plain EXIT trap is the whole fix.
# The reverted copy of the tree and this gate's own scratch go the same way.
scratch=""
gtmp="$(mktemp -d "${TMPDIR:-/tmp}/aif-green-XXXXXX")"
trap 'rm -f "$work/.suite.out"; [ -z "$scratch" ] || rm -rf "${scratch:?}"; [ -z "$gtmp" ] || rm -rf "${gtmp:?}"' EXIT
tab="$(printf '\t')"

suite_rc=0
(cd "$root" && eval "$test_cmd") >"$work/.suite.out" 2>&1 || suite_rc=$?

# What the LOCK is, as distinct from what this run is. A lock written in coarse
# mode holds no per-test record at all: covering is empty, suite_at_freeze is
# empty, and the three checks below that read them therefore check nothing. That
# was invisible — this gate printed the same confident sentence either way.
lock_mode="$(jq -r '.mode // "per-test"' "$lock")"

# --- the tree without this ticket's implementation ---------------------------
#
# One copy of the working tree with everything the implement station changed
# put back as it stood when the station was dispatched — which is the tree the
# tests were frozen on, plus whatever git ignores (installed dependencies,
# caches) as it is NOW. Made on first use and shared by the three questions
# that need it:
#
#   - the revert-recheck: do the covering tests fail without the code?
#   - a pre-existing test that fails: does it fail without the code too?
#   - a check that fails in a frozen test file: the same way without the code?
#
# The last two are the attribution this gate was missing. It used to reject the
# implement station for every failure it could not explain, and the station
# was then retried against things no edit to its files could reach: twelve
# pre-existing tests broken by a dependency re-resolved in node_modules, a type
# error inside a frozen test file. Three attempts each, 49 minutes for one of
# them (docs/DEFECTS.md 6.2, #3). A failure the implementation can clear is
# one that CHANGES when the implementation is taken away; one that does not
# change is out of its reach, and the run stops instead of retrying.
#
# The whole diff since dispatch is reverted, not only the manifest's files: an
# amended path, or a stray file scope has yet to reject, is the implementation
# too, and leaving it in would blame the environment for what it did.
base=""
reverted=""
reverted_ran=0
reverted_why=""

# revert_tree — make the copy (once), and prove the revert happened.
#
# From the commit the worker recorded at dispatch, not from the index. The
# implement station has Bash, and after one `git commit` from it the index
# already held the implementation: the revert was a no-op, every covering test
# stayed green, and this gate told the station its tests were worthless when
# what had happened was that it committed (docs/DEFECTS.md 3.8).
revert_tree() {
  local rel want not_restored=""
  [ -z "$scratch" ] || return 0
  base="$(aif_g_dispatch_base "$work" "$root")"
  scratch="$(aif_g_scratch_at "$root" "$base")"
  [ -n "$scratch" ] && [ -d "$scratch" ] ||
    aif_g_error "could not copy the tree to revert the implementation in"
  jq -r '.impl_created[]?' "$lock" | while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    rm -f "${scratch:?}/${rel:?}"
  done

  # The revert is proven, file by file, against the hashes verify-red froze. A
  # revert that did not happen used to be indistinguishable from tests that
  # assert nothing; now it is named for what it is, and it is a 3, because no
  # retry of the implementation changes what the baseline holds.
  while IFS="$tab" read -r rel want; do
    [ -n "$rel" ] || continue
    [ "$(aif_g_sha256 "$scratch/$rel")" = "$want" ] || not_restored="$not_restored
$rel"
  done <<EOF
$(jq -r '.impl_frozen | to_entries[] | [.key, .value] | @tsv' "$lock")
EOF
  not_restored="$(printf '%s' "${not_restored# }" | grep -v '^$' || true)"
  if [ -n "$not_restored" ]; then
    printf 'ERROR  the implementation could not be reverted to what the tests were frozen against, from %s:\n' \
      "$(printf '%s' "$base" | cut -c1-10)" >&2
    printf '%s\n' "$not_restored" | sed 's/^/  - /' >&2
    printf '  At that commit the file does not match its hash in tests.lock.json. When a gate\n' >&2
    printf '  is run by hand there is no dispatch baseline, only HEAD — and if the station\n' >&2
    printf '  committed its work, HEAD already holds the change being reverted.\n' >&2
    exit "$AIF_G_ERROR"
  fi
}

# reverted_suite — the suite in that copy, parsed, once. Sets $reverted, or
# $reverted_why when there is nothing to read.
#
# The copy is of the tree AFTER this gate's own run, so it carries that run's
# report. It is deleted first: a reverted run that fails to produce one would
# otherwise be read from the stale file — every covering test "pass", and a
# correct implementation rejected for tests that "do not depend on" it.
reverted_suite() {
  [ "$reverted_ran" -eq 0 ] || return 0
  reverted_ran=1
  revert_tree
  mkdir -p "$scratch/$(dirname "$report_path")"
  rm -f "${scratch:?}/${report_path:?}"
  (cd "$scratch" && eval "$test_cmd") >"$gtmp/reverted.out" 2>&1 || true
  if [ ! -f "$scratch/$report_path" ]; then
    reverted_why="the suite wrote no report at $report_path"
  else
    reverted="$(python3 "$here/junit.py" "$scratch/$report_path" 2>/dev/null || true)"
    [ -n "$reverted" ] || reverted_why="the report it wrote at $report_path could not be read"
  fi
}

# render — a list of problems as the gates print them: a bullet per problem, and
# the indented lines under one (a failure's own words) as its continuation.
render() {
  sed '/^[[:space:]]*$/d; /^[[:space:]]/s/^/    /; /^[^[:space:]]/s/^/  - /'
}

allowed_skips=0
freeze_known=yes
[ "$lock_mode" = "per-test" ] || freeze_known=no
# No report is not a coarse verdict; it is no run. The same rule verify-red
# applies, for the same reason (docs/DEFECTS.md 4.11): a suite that never
# reached its reporter has an exit code that says nothing about the tests.
if [ ! -f "$root/$report_path" ]; then
  printf 'ERROR  the suite did not run — it exited %s and wrote no report at %s:\n' \
    "$suite_rc" "$report_path" >&2
  tail -8 "$work/.suite.out" | sed 's/^/      /' >&2
  exit "$AIF_G_ERROR"
fi
if aif_g_have python3; then
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
      exit "$AIF_G_ERROR"
    fi
    # Bound once, read below. $mine is small; the freeze record is the whole
    # suite and goes through a file — as an argument it would meet ARG_MAX on
    # exactly the projects large enough to need this gate.
    mine_json="$(jq -c '((.covering // []) + (.green_at_freeze // []))' "$lock")"
    jq -c '.suite_at_freeze // null' "$lock" >"$gtmp/freeze.json"

    # Every result that is not what it should be, classified once:
    #   mine    — a test this ticket froze, not passing
    #   pre     — a failing test the freeze recorded: it existed when the tests
    #             were frozen, so it is not this ticket's own
    #   post    — a failing test absent from that record
    #   unknown — a failing test, and a lock with no record to tell by
    #   quiet   — a test that ran at the freeze and is skipped now
    #
    # A failing test that is not one of this ticket's own used to be reported,
    # unconditionally, as "the pre-existing suite broke". That sentence is a
    # claim about WHERE a test came from, and the gate was not checking: on a
    # live ticket it was printed about six tests in a file the run had just
    # created, and the human read it as a regression in their own repository.
    # The freeze knows: an id absent from it did not exist when the tests were
    # frozen and cannot be pre-existing — whatever else it is.
    rows="$(printf '%s' "$results" | jq -r \
      --argjson mine "$mine_json" --slurpfile fz "$gtmp/freeze.json" '
      $fz[0] as $freeze
      | .[] | . as $t
      | (($freeze // {})[$t.id] // "") as $fs
      | (if ($mine | index($t.id)) != null then (if $t.status != "pass" then "mine" else empty end)
         elif ($t.status == "failure" or $t.status == "error") then
           (if $freeze == null then "unknown" elif $fs == "" then "post" else "pre" end)
         elif $t.status == "skipped" and $fs != "" and $fs != "skipped" then "quiet"
         else empty end) as $k
      | $k + "\t" + $t.id + "\t" + $t.status + "\t" + $fs')"
    kind_n() { printf '%s\n' "$rows" | awk -F'\t' -v k="$1" '$1 == k { n++ } END { print n + 0 }'; }
    mine_fail="$(kind_n mine)"
    pre_fail="$(kind_n pre)"
    post_fail="$(kind_n post)"

    # The pre-existing failures, attributed. Each is run against the tree
    # without the implementation, and the answer decides who it belongs to:
    #   passes there              — this change broke it: the implement station's
    #   fails there, passed at the freeze
    #                             — the tree without this change is the tree
    #                               that passed, so what moved is outside it:
    #                               installed dependencies, a cache, a service.
    #                               Unless the change moved a dependency
    #                               manifest or lockfile — then the dependencies
    #                               it installs are its own, and so is this
    #   fails there, red at the freeze (red_with_tests: it went red when the
    #   test files landed)
    #                             — compared line by line. If nothing in its
    #                               failure is new with the implementation, the
    #                               implementation does not reach it
    # Without the copy there is nothing to measure, and the old sentence stands.
    pre_text="$(printf '%s\n' "$rows" | awk -F'\t' '$1 == "pre" { print $2 " (" $3 ") — the pre-existing suite broke" }')"
    unreached_n=0 moved_n=0 interaction_n=0
    if [ "${pre_fail:-0}" -gt 0 ] && [ -e "$root/.git" ]; then
      reverted_suite
      if [ -n "$reverted" ]; then
        printf '%s' "$reverted" >"$gtmp/reverted.json"
        printf '%s\n' "$rows" | awk -F'\t' '$1 == "pre" { print $2 }' | jq -R . | jq -s . >"$gtmp/pre.json"
        deps="$(aif_g_dep_changes "$root" "$base" | paste -sd ' ' -)"
        attrib="$(printf '%s' "$results" | jq -c \
          --slurpfile rev "$gtmp/reverted.json" --slurpfile fz "$gtmp/freeze.json" \
          --slurpfile ids "$gtmp/pre.json" --arg deps "$deps" --arg here_root "$root" \
          --arg there "$scratch" --arg there_p "$(cd "$scratch" && pwd -P)" '
          # Each root spelling becomes "<root>", the longer first, so the same
          # failure read in two copies of the tree compares equal.
          def lines($m; $roots):
            reduce ($roots | sort_by(-length))[] as $r (($m // "") | gsub("\r"; "");
              if $r == "" then . else split($r) | join("<root>") end)
            | split("\n") | map(gsub("\u001b\\[[0-9;]*m"; "")) | map(select(test("[^ \t]")));
          ($rev[0] | map({ (.id): . }) | add // {}) as $R
          | ($fz[0] // {}) as $F
          | [ .[] | . as $t | select($ids[0] | index($t.id))
              | $R[$t.id] as $r | ($F[$t.id] // "") as $fs
              | ($t.id + " (" + $t.status + ") — ") as $head
              | if $r == null then
                  { out: false, text: ($head + "the pre-existing suite broke; the suite without the implementation does not collect it, so where it broke could not be measured") }
                elif ($r.status == "pass" or $r.status == "skipped") then
                  { out: false, text: ($head + "the pre-existing suite broke: it passes with the implementation reverted, so this change broke it") }
                elif ($fs == "pass" or $fs == "skipped") then
                  ((if $fs == "pass" then "passed" else "was skipped" end) as $then
                  | if $deps != "" then
                    { out: false, text: ($head + "it " + $then + " when the tests were frozen and fails with the implementation reverted too; this change moved " + $deps + ", and the breakage follows the dependencies that installs — keep what the lockfile already pinned") }
                  else
                    { out: true, kind: "moved", text: ($head + "it " + $then + " when the tests were frozen and fails with the implementation reverted too: the tree without this change is the tree the tests were frozen on, so what moved is outside it") }
                  end)
                else
                  ((lines($t.message; [$here_root]) - lines($r.message; [$there, $there_p])) as $d
                  | if ($d | length) == 0 then
                      { out: true, kind: "interaction", text: ($head + "red since this ticket'"'"'s test files landed, and it fails the same way with the implementation reverted: the implementation does not reach it") }
                    else
                      { out: false, text: ($head + "red since this ticket'"'"'s test files landed; the implementation changes how it fails and has not cleared it — new with it:"),
                        detail: ($d[0:8] | map(.[0:240])) }
                    end)
                end ]')"
        pre_text="$(printf '%s' "$attrib" | jq -r '.[] | .text, (.detail[]? | "    " + .)')"
        unreached_n="$(printf '%s' "$attrib" | jq '[ .[] | select(.out) ] | length')"
        moved_n="$(printf '%s' "$attrib" | jq '[ .[] | select(.kind == "moved") ] | length')"
        interaction_n="$(printf '%s' "$attrib" | jq '[ .[] | select(.kind == "interaction") ] | length')"
      else
        pre_text="$pre_text
    (not attributed: the suite without the implementation could not be read — $reverted_why)"
      fi
    fi

    notpass="$(
      printf '%s\n' "$rows" | awk -F'\t' '
        $1 == "mine"    { print $2 " (" $3 ") — a test this ticket froze, so it must pass; a skip here is red made to go away without implementing anything" }
        $1 == "unknown" { print $2 " (" $3 ") — origin unknown: this lock predates suite_at_freeze, so a pre-existing test cannot be told from one this ticket authored" }
        $1 == "post"    { print $2 " (" $3 ") — NOT pre-existing: absent from the suite when the tests were frozen, so it arrived with this ticket'"'"'s own test files" }
        $1 == "quiet"   { print $2 " (skipped) — it ran when the tests were frozen (" $4 "), so something in this change silenced it" }'
      [ -z "$pre_text" ] || printf '%s\n' "$pre_text"
    )"

    if [ -n "$(printf '%s' "$notpass" | grep -v '^[[:space:]]*$' || true)" ]; then
      # Whose defect is it? The implement station may write only files.change,
      # and every test file is hash-locked by tests.lock.json — so when nothing
      # failing is either one of this ticket's frozen tests or a pre-existing
      # one, what failed can only be a test that arrived with the oracle, and
      # implement cannot reach it. Rejecting implement there is not merely
      # unfair, it is unsatisfiable: measured at three dispatches, 93 turns and
      # 51 580 output tokens before limits.attempts_max stopped the run.
      #
      # So it is a 4, not a 1: the oracle's, and the tests station repairs it
      # in the copy of the tree without the implementation.
      if [ "$lock_mode" = "per-test" ] && [ "${mine_fail:-0}" -eq 0 ] &&
        [ "${pre_fail:-0}" -eq 0 ] && [ "${post_fail:-0}" -gt 0 ]; then
        printf 'REPAIR the failing tests are the oracle, not the implementation:\n' >&2
        printf '%s\n' "$notpass" | render >&2
        printf '  Every one of them arrived with this ticket'"'"'s own test files, which are frozen by\n' >&2
        printf '  tests.lock.json and outside files.change. The implement station cannot fix what it\n' >&2
        printf '  is being rejected for; the tests station can, without the implementation in view.\n' >&2
        exit "$AIF_G_REPAIR"
      fi
      # The same rule, reached by measurement rather than by origin: a failure
      # that is the same with the implementation taken away cannot be cleared
      # by any change to it, and while one of those stands no retry can pass.
      # What moved OUTSIDE the tracked tree — installed dependencies — no
      # station's edit reaches, and that is a stop; a pre-existing test the
      # new test files broke is the tests', and goes back to them.
      if [ "${unreached_n:-0}" -gt 0 ]; then
        if [ "${moved_n:-0}" -gt 0 ]; then
          printf 'ERROR  %s failing test(s) are out of the implementation'"'"'s reach — the run stops instead of retrying:\n' \
            "$unreached_n" >&2
          printf '%s\n' "$notpass" | render >&2
          printf '  Each of those fails the same way with this ticket'"'"'s implementation reverted, so\n' >&2
          printf '  no change the implement station may make can clear it.\n' >&2
          printf '  Passed at the freeze, fails now without the code: something outside the tracked\n' >&2
          printf '  tree moved — installed dependencies are the usual suspect (a package installed\n' >&2
          printf '  around the lockfile). Run "prepare" in the worktree, then resume.\n' >&2
          exit "$AIF_G_ERROR"
        fi
        printf 'REPAIR %s failing test(s) are out of the implementation'"'"'s reach, and are the new tests'"'"' doing:\n' \
          "$unreached_n" >&2
        printf '%s\n' "$notpass" | render >&2
        printf '  Each of those fails the same way with this ticket'"'"'s implementation reverted, so\n' >&2
        printf '  no change the implement station may make can clear it. %s went red when the test\n' \
          "$interaction_n" >&2
        printf '  files landed, and the code does not reach them: the new tests break them, and they have to change.\n' >&2
        exit "$AIF_G_REPAIR"
      fi
      # The implementer's own claim. A frozen test of this ticket that fails
      # with the code in place is, by default, the code's: a red-first test is
      # red without the code by design, so "the same without it" says nothing
      # here. What the implement station may do is SAY the test is wrong, in
      # its note, naming it and why — and when every failing frozen test is
      # named, the claim goes to the tests station as a repair, which keeps the
      # test or changes it under the gate that admitted it. A claim that covers
      # only some of the failures is not a claim about the rest.
      claims=""
      [ ! -f "$work/implement.note.json" ] ||
        claims="$(jq -r '.tests_wrong[]? | (.test // "") + "\t" + (.because // "")' "$work/implement.note.json" 2>/dev/null)"
      if [ "${mine_fail:-0}" -gt 0 ] && [ "${pre_fail:-0}" -eq 0 ] && [ "${post_fail:-0}" -eq 0 ] && [ -n "$claims" ]; then
        unclaimed=""
        while IFS="$tab" read -r kind tid rest; do
          [ "$kind" = "mine" ] || continue
          : "$rest"
          printf '%s\n' "$claims" | awk -F'\t' -v id="$tid" '$1 != "" && index(id, $1) > 0 { f = 1 } END { exit !f }' ||
            unclaimed="$unclaimed
$tid"
        done <<EOF
$rows
EOF
        if [ -z "$(printf '%s' "$unclaimed" | grep -v '^$' || true)" ]; then
          printf 'REPAIR the implementer declares the failing frozen test(s) wrong, naming each:\n' >&2
          printf '%s\n' "$claims" | awk -F'\t' '$1 != "" { print "  - " $1 ": " $2 }' >&2
          printf '%s\n' "$notpass" | render >&2
          printf '  The tests station reads the claim, without the implementation in view, and either\n' >&2
          printf '  amends the test or keeps it; the implementation is judged again after that.\n' >&2
          exit "$AIF_G_REPAIR"
        fi
        printf 'REJECT suite is not green, and the note'"'"'s claim does not cover every failing frozen test:\n' >&2
        printf '%s\n' "$notpass" | render >&2
        printf '  not claimed:\n' >&2
        printf '%s\n' "$unclaimed" | grep -v '^$' | sed 's/^/    - /' >&2
        exit "$AIF_G_REJECT"
      fi
      printf 'REJECT suite is not green:\n' >&2
      printf '%s\n' "$notpass" | render >&2
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
  # Coarse: exit code only. Weaker, and a skip is invisible here. One reason
  # is left that lands a gate here — the report exists and there is no python3
  # to read it — and it is named rather than left to be guessed.
  coarse_why="python3 is not on PATH (PATH=${PATH:0:200})"
  # The exit code alone. The grep this used to OR in — `fail|error` anywhere in
  # the output — rejected a green suite for a test NAMED test_error_handling,
  # for a captured log line, for tsc's "0 errors", with a complaint no station
  # could act on (docs/DEFECTS.md 3.5).
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
covering_n="$(jq -r '(.covering // []) | length' "$lock")"
if [ "${covering_n:-0}" -eq 0 ]; then
  recheck_ok=0
  recheck_why="the lock names no covering test, so there was nothing to revert-recheck"
  [ "$lock_mode" = "per-test" ] ||
    recheck_why="$recheck_why (the lock is COARSE: $(jq -r '.mode_reason // "reason not recorded"' "$lock"))"
elif [ ! -e "$root/.git" ] || ! aif_g_have python3; then
  recheck_ok=0
else
  reverted_suite
  if [ -z "$reverted" ]; then
    # The green run above wrote a report and this one did not, on the same
    # tree minus the implementation. Whatever stopped it, the one proof this
    # gate exists to produce — that the covering tests fail without the code —
    # was not produced, and a pass with a caveat is the wrong answer to that.
    printf 'ERROR  the revert-recheck did not run — %s:\n' "$reverted_why" >&2
    tail -8 "$gtmp/reverted.out" 2>/dev/null | sed 's/^/      /' >&2
    printf '  Nothing established that the covering tests depend on the implementation.\n' >&2
    exit "$AIF_G_ERROR"
  fi
  # Every covering test must now be failing. One that stays green did not
  # depend on the implementation.
  still_green=""
  while IFS= read -r tid; do
    [ -n "$tid" ] || continue
    st="$(printf '%s' "$reverted" | jq -r --arg i "$tid" '[ .[] | select(.id==$i) | .status ] | .[0] // ""' 2>/dev/null)"
    [ "$st" = "pass" ] && still_green="$still_green
$tid stays green with the implementation reverted — it does not test the behaviour"
  done <<EOF
$(jq -r '.covering[]?' "$lock")
EOF
  if [ -n "$still_green" ]; then
    printf 'REJECT the tests do not depend on the implementation:\n' >&2
    printf '%s\n' "${still_green# }" | render >&2
    exit "$AIF_G_REJECT"
  fi
fi

rm -f "$work/.suite.out"

# --- the rest of the Definition of Done ------------------------------------
# Run last, because the suite is the cheapest signal and there is no point
# type-checking code whose tests do not pass. The record goes under .aif/tmp/,
# which is gitignored: an artifact written into tasks/ at this moment would show
# up in scope's diff as an implementation editing the pipeline's own machinery,
# and scope would reject a correct implementation for the bookkeeping of the gate
# that admitted it. `aif _gate` folds the record into the ledger afterwards.
#
# A failing check is attributed the way a failing pre-existing test is. If its
# failure names a frozen test file, the same check runs once more in the tree
# without the implementation, and when every line of it recurs there the
# implementation added none of it — the error is in the oracle, which the
# implement station may not edit. That is a stop, not a retry: on a live ticket
# a mock typed `Mock<Category, []>` against a field declared
# `Mock<Category | null, [string]>` failed the project's typecheck inside a
# frozen test, and three attempts at the implementation could not touch it
# (docs/DEFECTS.md 6.2). A line that appears only with the implementation is
# the implementation's to fix — a signature a test calls in a way the new code
# does not accept — and that stays a rejection, with the check's own words.
mkdir -p "$root/.aif/tmp" "$gtmp/checks"
check_viol="$(aif_g_checks_run "$project" "$root" "green" "$root/.aif/tmp/checks-green.json" "" "$gtmp/checks")"
if [ -n "$check_viol" ]; then
  unreached=""
  if [ -f "$gtmp/checks/failed.tsv" ] && [ -e "$root/.git" ]; then
    jq -r '.tests | keys[]' "$lock" >"$gtmp/checks/frozen.txt"
    while IFS="$tab" read -r idx name; do
      [ -n "$idx" ] || continue
      # Compared normalised — root spellings, colour, CRs — and shown as the
      # tool printed them.
      named="$(aif_g_located "$gtmp/checks/$idx.out" "$gtmp/checks/frozen.txt")"
      [ -n "$named" ] || continue
      aif_g_lines "$gtmp/checks/$idx.out" "$root" >"$gtmp/checks/$idx.here"
      cmd="$(jq -r --arg n "$name" '[ .checks[]? | select(.name == $n) | .command ] | .[0] // empty' "$project")"
      [ -n "$cmd" ] || continue
      revert_tree
      (cd "$scratch" && eval "$cmd") </dev/null >"$gtmp/checks/$idx.rev" 2>&1 || true
      aif_g_lines "$gtmp/checks/$idx.rev" "$scratch" >"$gtmp/checks/$idx.there"
      added="$(awk 'NR == FNR { seen[$0] = 1; next } !seen[$0]' \
        "$gtmp/checks/$idx.there" "$gtmp/checks/$idx.here")"
      [ -z "$added" ] || continue
      unreached="$unreached
check \"$name\" fails in frozen test files, and every line of the failure recurs with the implementation reverted:
$(printf '%s\n' "$named" | sed -n '1,12p' | cut -c1-240 | sed 's/^/    /')"
    done <"$gtmp/checks/failed.tsv"
  fi
  if [ -n "$unreached" ]; then
    printf 'REPAIR a check fails in the frozen tests, not in the implementation:\n' >&2
    printf '%s\n' "$unreached" | render >&2
    printf '  None of it comes from the implementation: the same lines are printed without it,\n' >&2
    printf '  and they name files the freeze holds, which the implement station may not edit.\n' >&2
    printf '  The tests have to change, and the tests station changes them. A check bound to\n' >&2
    printf '  "red" would have caught this before the freeze.\n' >&2
    other="$(printf '%s\n' "$check_viol" | grep -c '^[^[:space:]]' || true)"
    [ "${other:-0}" -le 1 ] ||
      printf '  (%s check(s) failed in all; each is in the ledger by name.)\n' "$other" >&2
    exit "$AIF_G_REPAIR"
  fi
  aif_g_report "$check_viol" "checks"
fi

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
