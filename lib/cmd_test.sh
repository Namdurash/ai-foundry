#!/usr/bin/env bash
#
# `aif test` — the eval harness.
#
# This is an eval, not a unit test. It runs a fixture through the real runner
# against a real model and checks a deterministic oracle. Models are not
# deterministic, so a single run means nothing: every eval runs N times and
# reports a pass rate with a confidence interval.
#
# Sourced by bin/aif; not meant to be executed directly.

AIF_EVAL_DIR="tests/evals"

# Read one KEY=VALUE out of eval.meta. Parsed, never sourced — evals are the
# thing you eventually accept from contributors.
_aif_eval_meta() {
  local file="$1" key="$2" default="${3:-}"
  local line
  line="$(grep -E "^${key}=" "$file" 2>/dev/null | head -1)" || true
  if [ -z "$line" ]; then
    printf '%s' "$default"
    return 0
  fi
  printf '%s' "${line#*=}"
}

_aif_eval_list() {
  local dir
  for dir in "$AIF_ROOT/$AIF_EVAL_DIR"/*/; do
    [ -f "$dir/eval.meta" ] || continue
    basename "$dir"
  done
}

# Build a disposable working directory for one run.
#
# A temp copy, deliberately not a git worktree. A worktree of our own repo would
# hand the agent a tree wired to our object store, where a misbehaving run can
# commit into our history — and the fixture would have to be committed to be
# materialised at all. A copy is throwaway, and still gives the agent the real
# git repo it will probe for.
_aif_eval_workdir() {
  local eval_dir="$1" work="$2"

  mkdir -p "$work"
  if [ -d "$eval_dir/fixture" ]; then
    cp -R "$eval_dir/fixture/." "$work/" 2>/dev/null || true
  fi

  git -C "$work" init -q
  git -C "$work" add -A 2>/dev/null || true
  # -c user.*: CI has no git identity and the commit would otherwise fail.
  git -C "$work" \
    -c user.email=eval@aif -c user.name=aif \
    commit -qm "fixture" --allow-empty 2>/dev/null || true
}

# One run. Echoes "<verdict>\t<duration_ms>\t<turns>\t<cost>\t<note>".
_aif_eval_run_once() {
  local eval_dir="$1" root="$2" idx="$3" max_turns="$4" budget="$5"
  local work="$root/run$idx" out="$root/run$idx.json" err="$root/run$idx.err"
  local rc=0 note="" cost_line dur turns cost

  _aif_eval_workdir "$eval_dir" "$work"

  if [ "${AIF_PROFILE_ISOLATE_CONFIG:-0}" = "1" ]; then
    # A fresh config root cannot be resumed into another provider's sessions,
    # which is the structural fix for claude-code#77512. It also drops the
    # user's auth, which is fine precisely for the profiles that carry a token.
    CLAUDE_CONFIG_DIR="$root/cfg$idx"
    export CLAUDE_CONFIG_DIR
    mkdir -p "$CLAUDE_CONFIG_DIR"
  fi

  "aif_runner_${AIF_PROFILE_RUNNER}_eval" \
    "$work" "$AIF_EVAL_PROMPT" "$max_turns" "$budget" "$out" "$err" || rc=$?

  dur=0
  turns=0
  cost=0
  if [ -s "$out" ]; then
    cost_line="$("aif_runner_${AIF_PROFILE_RUNNER}_result_cost" "$out")"
    cost="$(printf '%s' "$cost_line" | cut -f1)"
    turns="$(printf '%s' "$cost_line" | cut -f2)"
    dur="$(jq -r '.duration_ms // 0' "$out" 2>/dev/null || printf '0')"
  fi

  # Three gates, because the envelope cannot be trusted on its own: the process
  # exit code, is_error, and only then the oracle.
  if [ "$rc" -ne 0 ]; then
    note="runner exited $rc"
    if [ -s "$out" ]; then
      note="$("aif_runner_${AIF_PROFILE_RUNNER}_result_error" "$out")"
    elif [ -s "$err" ]; then
      note="$(head -1 "$err")"
    fi
    printf 'FAIL\t%s\t%s\t%s\t%s' "$dur" "$turns" "$cost" "$note"
    return 0
  fi

  if ! "aif_runner_${AIF_PROFILE_RUNNER}_result_ok" "$out"; then
    note="$("aif_runner_${AIF_PROFILE_RUNNER}_result_error" "$out")"
    printf 'FAIL\t%s\t%s\t%s\t%s' "$dur" "$turns" "$cost" "$note"
    return 0
  fi

  note="$(
    cd "$work" || exit 1
    AIF_RESULT_JSON="$out" /bin/bash "$eval_dir/oracle.sh" 2>&1
  )" || {
    printf 'FAIL\t%s\t%s\t%s\t%s' "$dur" "$turns" "$cost" "${note:-oracle failed}"
    return 0
  }

  printf 'pass\t%s\t%s\t%s\t' "$dur" "$turns" "$cost"
}

_aif_eval_one() {
  local name="$1" runs_override="$2"
  local eval_dir="$AIF_ROOT/$AIF_EVAL_DIR/$name"
  local meta="$eval_dir/eval.meta"

  [ -f "$meta" ] || aif_die "no such eval: $name"

  local desc runs max_turns budget
  desc="$(_aif_eval_meta "$meta" DESC "$name")"
  runs="${runs_override:-$(_aif_eval_meta "$meta" RUNS 3)}"
  max_turns="$(_aif_eval_meta "$meta" MAX_TURNS 10)"
  budget="$(_aif_eval_meta "$meta" MAX_BUDGET_USD 0.50)"

  AIF_EVAL_PROMPT="$(cat "$eval_dir/task.md")"

  printf '%s%s%s — %s\n' "$AIF_C_BOLD" "$name" "$AIF_C_RESET" "$desc"

  local root passes=0 i line verdict dur turns cost note
  root="$(mktemp -d "${TMPDIR:-/tmp}/aif-eval-XXXXXX")"
  : >"$root/tsv"

  i=1
  while [ "$i" -le "$runs" ]; do
    line="$(_aif_eval_run_once "$eval_dir" "$root" "$i" "$max_turns" "$budget")"
    verdict="$(printf '%s' "$line" | cut -f1)"
    dur="$(printf '%s' "$line" | cut -f2)"
    turns="$(printf '%s' "$line" | cut -f3)"
    cost="$(printf '%s' "$line" | cut -f4)"
    note="$(printf '%s' "$line" | cut -f5-)"

    if [ "$verdict" = "pass" ]; then
      passes=$((passes + 1))
      printf '  run %d/%d  %s%s%s  %5.1fs  %2s turns  $%s\n' \
        "$i" "$runs" "$AIF_C_GREEN" "pass" "$AIF_C_RESET" \
        "$(awk -v d="$dur" 'BEGIN{printf "%.1f", d/1000}')" "$turns" "$cost"
    else
      printf '  run %d/%d  %s%s%s  %5.1fs  %2s turns  $%s  %s%s%s\n' \
        "$i" "$runs" "$AIF_C_RED" "FAIL" "$AIF_C_RESET" \
        "$(awk -v d="$dur" 'BEGIN{printf "%.1f", d/1000}')" "$turns" "$cost" \
        "$AIF_C_DIM" "$note" "$AIF_C_RESET"
    fi

    printf '%s\t%s\t%s\n' "$cost" "$turns" "$dur" >>"$root/tsv"
    i=$((i + 1))
  done

  local rate total median
  rate="$(aif_stats_wilson "$passes" "$runs")"
  total="$(aif_stats_sum 1 <"$root/tsv")"
  median="$(aif_stats_median 2 <"$root/tsv")"

  printf '\n  %s%d/%d%s · %s · median %s turns · total $%s\n' \
    "$AIF_C_BOLD" "$passes" "$runs" "$AIF_C_RESET" "$rate" "$median" "$total"

  rm -rf "$root"

  [ "$passes" -eq "$runs" ]
}

_aif_test_usage() {
  cat <<EOF
usage: aif test [eval] --profile <name> [--runs N]

  Runs an eval N times against a profile and reports a pass rate.
  With no eval named, runs all of them.

  --profile <name>   which profile to measure (see: aif profiles)
  --runs N           override the eval's own run count
EOF
}

aif_cmd_test() {
  local profile="" runs="" want=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --profile)
        shift
        profile="${1:-}"
        ;;
      --runs)
        shift
        runs="${1:-}"
        ;;
      -h | --help)
        _aif_test_usage
        return 0
        ;;
      -*)
        aif_die "unknown option: $1"
        ;;
      *)
        want="$1"
        ;;
    esac
    shift || true
  done

  [ -n "$profile" ] || aif_die "--profile is required (see: aif profiles)"

  aif_profile_load "$profile"

  # shellcheck source=lib/runner_claude.sh
  . "$AIF_ROOT/lib/runner_claude.sh"
  # shellcheck source=lib/stats.sh
  . "$AIF_ROOT/lib/stats.sh"

  "aif_runner_${AIF_PROFILE_RUNNER}_available" ||
    aif_die "runner '$AIF_PROFILE_RUNNER' is not installed"

  # Fail before burning a run, not after.
  if [ -n "$AIF_PROFILE_SECRET_VAR" ] && [ -z "$(aif_profile_secret)" ]; then
    aif_die "$AIF_PROFILE_SECRET_VAR is not set — export it to use profile '$profile'"
  fi

  aif_profile_export_env

  printf 'profile %s%s%s · runner %s · set %s\n\n' \
    "$AIF_C_BOLD" "$profile" "$AIF_C_RESET" \
    "$AIF_PROFILE_RUNNER" "$AIF_PROFILE_SET"

  local name failed=0
  if [ -n "$want" ]; then
    _aif_eval_one "$want" "$runs" || failed=1
  else
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      _aif_eval_one "$name" "$runs" || failed=1
      printf '\n'
    done <<EOF
$(_aif_eval_list)
EOF
  fi

  return "$failed"
}
