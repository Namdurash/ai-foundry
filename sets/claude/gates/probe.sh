#!/usr/bin/env bash
#
# Gate: probe — does this project's test contract hold?
#
# Every gate after the plan reads one thing about a project's tests: the
# report test.command writes. Whatever the runner — jest, vitest, go test,
# xcodebuild, an engine's automation — they need four facts from it:
#
#   1  a report appears at test.report.path, as JUnit XML junit.py reads
#   2  a new test file is collected: it is a test by test.roots and
#      test.files, and the runner selects it
#   3  each case names its file, repo-relative — how verify-red tells this
#      ticket's tests from the rest of the suite
#   4  a case's id keeps the criterion's marker the stations put in a test's
#      name, a failing assertion reads as a legitimate red
#      (failure_classes.legitimate), and the same id comes back on every run
#
# aif knew these for two runners, in templates it shipped, and a project on
# any other could not be set up at all (docs/DEFECTS.md 20.1). Now `aif
# setup` writes them for the project — the model of its profile — and this
# gate is how they are known to hold rather than believed: it writes
# test.probe.red, a test failing by an assertion, into a copy of the tree,
# runs the suite and reads the report as verify-red reads it; then
# test.probe.green, the same test passing; then, when the project names one,
# test.probe.broken, the same file unable to load, which must not read as a
# red. The probe's test is named for PROBE-1 AC-001, the way a station names
# a test of ticket PROBE-1's first criterion.
#
# The developer's checkout is never written: the copy is the gates' own
# (aif_g_scratch_at), the tree as it stands, what is uncommitted included —
# which is what `aif setup` iterates on.
#
# --cached: proven once under a key of what the proof stands on — the
# project's test, failure_classes, deps, copies and prepare; the tracked
# manifests and lockfiles; the files test.probe.watch names (the runner's
# configuration); what is under .aif/adapter/; these gates — kept under
# .aif/tmp/probe/. The worker asks with --cached before a run, so a change
# to any of it — a runner upgraded under the project, a config moved — is
# proven again before a station is paid to meet it. Without the flag it is
# proven again regardless (`aif doctor --probe`). --proven only says whether
# it is: the configuration is read, and the suite never runs (`aif doctor`).
#
# Usage: probe.sh [--cached | --proven] [<a directory in the project>]
# Exit 0 the contract holds · 1 it does not, what and the fix said · 3 the
# gate could not run · 5 (--proven) not proven since what it stands on moved.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source-path=SCRIPTDIR source=_lib.sh
. "$here/_lib.sh"

aif_g_need jq
aif_g_need git

cached=0
proven=0
dir="."
while [ $# -gt 0 ]; do
  case "$1" in
    --cached) cached=1 ;;
    --proven) proven=1 ;;
    -*) aif_g_error "usage: probe.sh [--cached | --proven] [<a directory in the project>]" ;;
    *) dir="$1" ;;
  esac
  shift
done

project="$(aif_g_project "$dir")" || exit $?
aif_g_stack_load "$project"
root="$(dirname "$(dirname "$project")")"

# The marker as a station writes it in a test's name, and as verify-red
# finds it: normalised, whole (aif_g_marker_in).
AIF_G_PROBE_MARKER='PROBE-1 AC-001'
mark="$(aif_g_norm "$AIF_G_PROBE_MARKER")"

# probe_fail <what> <fix> — the contract does not hold: what, and the fix.
probe_fail() {
  printf 'probe: ✗ %s\n' "$1" >&2
  [ -z "${2:-}" ] || printf '  fix: %s\n' "$2" >&2
  exit 1
}

cmd="$(jq -r '.test.command // empty' "$project" 2>/dev/null)"
report="$(jq -r '.test.report.path // empty' "$project" 2>/dev/null)"
ppath="$(jq -r '.test.probe.path // empty' "$project" 2>/dev/null)"
[ -n "$cmd" ] || probe_fail "test.command is empty — the test contract is not set up" \
  "aif setup writes it: how the tests run here, the report they write, the probe that proves both"
[ -n "$report" ] || probe_fail "test.report.path is empty — every gate reads that report" \
  "name where test.command writes its JUnit XML, e.g. .aif/tmp/report.xml"
[ -n "$ppath" ] || probe_fail "test.probe is not set — nothing proves the test contract" \
  "aif setup writes it: { path, red, green } — one test in this project's language, named for $AIF_G_PROBE_MARKER, failing by an assertion, then passing; on a jest or pytest project, aif project upgrade adds the template's"
case "$ppath" in
  /* | ../* | */../* | .. | */..) probe_fail "test.probe.path $ppath is not a path inside the repository" "a relative path, no .." ;;
esac
roots="$(jq -r '.test.roots[]?' "$project" 2>/dev/null)"
aif_g_test_path "$ppath" "$roots" ||
  probe_fail "test.probe.path $ppath is not a test by this project's rules — under test.roots, or matched by test.files" \
    "the gates tell a ticket's tests from its code by that rule: put the probe where this project keeps its tests, or name the pattern in test.files"
aif_g_have python3 ||
  aif_g_error "python3 is not on PATH (PATH=${PATH:0:200}) — the report cannot be read per test, and nothing can be proven"
has_broken="$(jq -r 'if ((.test.probe.broken // "") | length) > 0 then 1 else 0 end' "$project" 2>/dev/null)"
broken_re="$(jq -r '(.failure_classes.broken // []) | join("|")' "$project" 2>/dev/null)"
legit_re="$(jq -r '(.failure_classes.legitimate // []) | join("|")' "$project" 2>/dev/null)"

# probe_key — what the proof stands on, hashed. A path is written before its
# bytes, so a file moved is a change too.
probe_key() {
  local f
  {
    jq -c '{ t: .test, f: .failure_classes, d: .deps, c: .copies, p: .prepare }' "$project"
    git -C "$root" -c core.quotePath=false ls-files 2>/dev/null | grep -E "$AIF_G_MANIFESTS|$AIF_G_LOCKFILES" | sort |
      while IFS= read -r f; do
        printf '%s\n' "$f"
        [ ! -f "$root/$f" ] || cat "$root/$f"
      done
    jq -r '(.test.probe.watch // [])[]? | strings' "$project" | while IFS= read -r f; do
      printf '%s\n' "$f"
      [ ! -f "$root/$f" ] || cat "$root/$f"
    done
    [ ! -d "$root/.aif/adapter" ] || find "$root/.aif/adapter" -type f 2>/dev/null | sort | while IFS= read -r f; do
      printf '%s\n' "${f#"$root"/}"
      cat "$f"
    done
    cat "$here/probe.sh" "$here/_lib.sh" "$here/junit.py" 2>/dev/null
  } | aif_g_sha256 /dev/stdin | cut -c1-16
}

key="$(probe_key)"
stamp="$root/.aif/tmp/probe/$key.ok"
if [ "$cached" -eq 1 ] || [ "$proven" -eq 1 ]; then
  if [ -f "$stamp" ]; then
    printf 'probe: the test contract holds — proven %s, and nothing it stands on has moved since\n' "$(cat "$stamp" 2>/dev/null)"
    exit 0
  fi
  if [ "$proven" -eq 1 ]; then
    printf 'probe: not proven since what it stands on last moved — the configuration, the lockfiles, the adapter or the gates\n'
    exit 5
  fi
fi

scratch=""
errf="$(mktemp "${TMPDIR:-/tmp}/aif-probe-XXXXXX")" || aif_g_error "could not make a temporary file"
# shellcheck disable=SC2329  # the EXIT trap's
probe_cleanup() {
  [ -z "$scratch" ] || rm -rf "${scratch:?}"
  rm -f "${errf:?}"
}
trap probe_cleanup EXIT
scratch="$(aif_g_scratch_at "$root" "" 2>"$errf")" ||
  aif_g_error "could not copy the tree to probe it — $(cat "$errf")"
mkdir -p "$scratch/.aif/tmp"

# probe_run <red|green|broken> — the suite in the copy, the probe's file as
# test.probe.<variant> writes it; the report's rows (junit.py's) left in
# $scratch/.aif/tmp/probe.<variant>.json. rc 1 no report, rc 2 a report
# junit.py cannot read — PROBE_WHY says which, with the suite's last lines.
PROBE_WHY=""
probe_run() {
  local v="$1" out="$scratch/.aif/tmp/probe.$1.out" rc=0 rows
  mkdir -p "$scratch/$(dirname "$ppath")" "$scratch/$(dirname "$report")"
  # As written, ending in one newline: a reader by lines misses a last line
  # without one, and -r would add a second.
  jq -j --arg v "$v" '.test.probe[$v]' "$project" >"$scratch/$ppath"
  [ -z "$(tail -c 1 "$scratch/$ppath")" ] || printf '\n' >>"$scratch/$ppath"
  rm -f "${scratch:?}/${report:?}"
  (cd "$scratch" && eval "$cmd") </dev/null >"$out" 2>&1 || rc=$?
  if [ ! -f "$scratch/$report" ]; then
    PROBE_WHY="the suite exited $rc and wrote no report at $report — $(grep -v '^[[:space:]]*$' "$out" | tail -3 | paste -sd ' ' - | cut -c1-300)"
    [ -n "$(grep -v '^[[:space:]]*$' "$out" | head -1)" ] || PROBE_WHY="${PROBE_WHY}(it printed nothing)"
    return 1
  fi
  if ! rows="$(python3 "$here/junit.py" "$scratch/$report" 2>/dev/null)" || [ -z "$rows" ]; then
    PROBE_WHY="the report at $report is not JUnit XML junit.py can read — the gates read nothing else"
    return 2
  fi
  printf '%s' "$rows" >"$scratch/.aif/tmp/probe.$v.json"
}

# probe_rows <variant> [<path>] — the cases carrying the marker, and those
# naming <path> when one is given, a line each: id <US> file <US> status <US>
# message (one line, 400 characters).
probe_rows() {
  jq -r --arg m "$mark" --arg p "${2:-}" '
    .[] | select((("_" + (.id | ascii_downcase | gsub("[^a-z0-9]+"; "_")) + "_") | contains("_" + $m + "_"))
                 or ($p != "" and (.file // "") == $p))
    | [ .id, (.file // ""), .status, ((.message // "") | gsub("[\n\t\u001f]"; " ") | .[0:400]) ] | join("\u001f")
  ' "$scratch/.aif/tmp/probe.$1.json" 2>/dev/null
}

# probe_counts <variant> — "<cases in the probe's file> <cases in all>".
probe_counts() {
  jq -r --arg p "$ppath" '"\([ .[] | select((.file // "") == $p) ] | length) \(length)"' \
    "$scratch/.aif/tmp/probe.$1.json" 2>/dev/null
}

# probe_class <message> — red (the marker, or failure_classes.legitimate),
# broken (failure_classes.broken), or none: verify-red's order.
probe_class() {
  if printf '%s' "$1" | grep -qF -- "$AIF_G_NOT_IMPLEMENTED"; then
    printf 'red'
  elif [ -n "$broken_re" ] && printf '%s' "$1" | grep -qE -- "$broken_re"; then
    printf 'broken'
  elif [ -n "$legit_re" ] && printf '%s' "$1" | grep -qE -- "$legit_re"; then
    printf 'red'
  else
    printf 'none'
  fi
}

us="$(printf '\037')"

# --- red: the test is collected, names its file, keeps its marker, and its
# failing assertion is a legitimate red ---------------------------------------
probe_run red || probe_fail "with test.probe.red in place, $PROBE_WHY" \
  "test.command must run the suite and write its report even when a test fails — a JUnit reporter, or the adapter under .aif/adapter/ that converts what the runner writes"
red_rows="$(probe_rows red)"
if [ -z "$red_rows" ]; then
  read -r n_file n_all <<EOF
$(probe_counts red)
EOF
  if [ "${n_file:-0}" -gt 0 ]; then
    probe_fail "the probe's file ran — ${n_file} case(s) in $ppath — and no case's id keeps $AIF_G_PROBE_MARKER" \
      "the stations put a criterion's marker in a test's name, and verify-red finds it in the report's id (classname::name), runs of other characters read as one separator: name the probe's test so its id keeps PROBE-1 and AC-001 apart (probe_1_ac_001), and the runner's report must keep the name"
  fi
  probe_fail "the probe was not collected — no case in the report keeps $AIF_G_PROBE_MARKER, none names $ppath (${n_all:-0} case(s) in all)" \
    "the runner does not select that file — its test match, its roots — or the report leaves it out; a ticket's tests written there would be unseen the same way"
fi
IFS="$us" read -r red_id red_file red_status red_msg <<EOF
$(printf '%s\n' "$red_rows" | head -1)
EOF
[ "$red_file" = "$ppath" ] ||
  probe_fail "$(if [ -n "$red_file" ]; then printf 'the report names the probe'"'"'s file as "%s", not "%s"' "$red_file" "$ppath"; else printf 'the report names no file for the probe'"'"'s case (%s)' "$red_id"; fi)" \
    "each case must carry its file, repo-relative — @file on <testcase> (jest-junit: addFileAttribute \"true\"); a runner whose report cannot, through an adapter under .aif/adapter/ that test.command runs. verify-red tells a ticket's tests from the rest of the suite by it"
case "$red_status" in
  pass) probe_fail "test.probe.red passed — it has to fail, by an assertion" "make test.probe.red assert something false" ;;
  skipped) probe_fail "test.probe.red was skipped — a skipped test is not a red" "the probe must run" ;;
esac
[ -n "$red_msg" ] ||
  probe_fail "the report gives the red probe's failure no message — verify-red tells a red from a broken test by it" \
    "the reporter (or the adapter) must write the failure's message or text into <failure>"
case "$(probe_class "$red_msg")" in
  broken)
    probe_fail "test.probe.red reads as broken — failure_classes.broken matches its failure: $(printf '%s' "$red_msg" | cut -c1-240)" \
      "a failing assertion is a red, not a test that could not run: narrow the broken pattern that matches it"
    ;;
  none)
    probe_fail "test.probe.red fails in a way failure_classes.legitimate does not count as red: $(printf '%s' "$red_msg" | cut -c1-240)" \
      "verify-red would refuse every new test that fails this way — add a pattern of this runner's assertion failure to failure_classes.legitimate"
    ;;
esac

# --- green: the same test passing, under the same id ------------------------
probe_run green || probe_fail "with test.probe.green in place, $PROBE_WHY" \
  "test.command must write its report whether the suite passes or fails"
green_rows="$(probe_rows green)"
[ -n "$green_rows" ] ||
  probe_fail "test.probe.green was not collected, or its id lost $AIF_G_PROBE_MARKER" \
    "test.probe.green is test.probe.red with the assertion made true — the same file, the same test name"
IFS="$us" read -r green_id green_file green_status green_msg <<EOF
$(printf '%s\n' "$green_rows" | head -1)
EOF
: "$green_file"
[ "$green_status" = pass ] ||
  probe_fail "test.probe.green does not pass — $green_status: $(printf '%s' "$green_msg" | cut -c1-240)" \
    "test.probe.green is test.probe.red with the assertion made true"
[ "$green_id" = "$red_id" ] ||
  probe_fail "the probe's id changed between two runs: \"$red_id\", then \"$green_id\"" \
    "verify-red freezes the tests by id and green finds them by it: an id that carries a duration, a path to a copy or a random part breaks both — name the test, and have the report write the name alone"

# --- broken: the same file unable to load must not read as a red -----------
broken_said=""
if [ "$has_broken" = 1 ]; then
  rc=0
  probe_run broken || rc=$?
  if [ "$rc" -eq 1 ]; then
    broken_said="broken (the suite writes no report then — verify-red stops on it; a check bound to the red phase that builds the tests finds it first)"
  elif [ "$rc" -eq 2 ]; then
    probe_fail "with test.probe.broken in place, $PROBE_WHY" ""
  else
    broken_rows="$(probe_rows broken "$ppath")"
    if [ -z "$broken_rows" ]; then
      broken_said="broken (left out of the report — verify-red reads it as not collected)"
    else
      b_known=0
      while IFS="$us" read -r b_id b_file b_status b_msg; do
        [ -n "$b_id" ] || continue
        : "$b_file"
        case "$b_status" in
          pass) probe_fail "test.probe.broken passed — it has to be a test that cannot load" "a syntax error in the probe's file, as a mistyped test would have" ;;
          skipped) continue ;;
        esac
        case "$(probe_class "$b_msg")" in
          red)
            probe_fail "a test that cannot load reads as a legitimate red: $(printf '%s' "$b_msg" | cut -c1-240)" \
              "verify-red would freeze it and the implement station could never make it pass — add a pattern of this runner's load error to failure_classes.broken"
            ;;
          broken) b_known=1 ;;
        esac
      done <<EOF
$broken_rows
EOF
      if [ "$b_known" -eq 1 ]; then
        broken_said="broken (failure_classes.broken knows it)"
      else
        broken_said="broken (refused as neither a red nor the marker — failure_classes.broken would name it)"
      fi
    fi
  fi
fi

mkdir -p "$root/.aif/tmp/probe" 2>/dev/null &&
  date -u '+%Y-%m-%dT%H:%M:%SZ' >"$stamp" 2>/dev/null || true
printf 'probe: the test contract holds — red, green%s — %s case(s) in the suite, %ss\n' \
  "${broken_said:+, $broken_said}" "$(probe_counts green | cut -d' ' -f2)" "$SECONDS"
exit 0
