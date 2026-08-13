#!/usr/bin/env bash
#
# `aif doctor` — report what is installed and what aif can therefore drive.
# Read-only. Sourced by bin/aif; not meant to be executed directly.

_aif_doctor_runners() {
  printf '%sRunners%s\n' "$AIF_C_BOLD" "$AIF_C_RESET"

  local r path ver mark
  for r in $AIF_RUNNERS; do
    path="$(aif_runner_path "$r")"
    if [ -n "$path" ]; then
      ver="$(aif_runner_version "$r")"
      mark="$(aif_ok)"
      printf '  %s %-10s %-26s %s%s%s\n' \
        "$mark" "$r" "${ver:-?}" "$AIF_C_DIM" "$path" "$AIF_C_RESET"
    else
      mark="$(aif_no)"
      printf '  %s %-10s %snot installed%s\n' \
        "$mark" "$r" "$AIF_C_DIM" "$AIF_C_RESET"
    fi
  done
}

_aif_doctor_tooling() {
  printf '\n%sTooling%s\n' "$AIF_C_BOLD" "$AIF_C_RESET"

  # bash is special: what matters is the interpreter running us, not whatever
  # `bash` on PATH happens to be. aif targets 3.2, so this is informational.
  printf '  %s %-10s %s\n' "$(aif_ok)" "bash" "${BASH_VERSION:-?}"

  local t ver
  for t in jq git; do
    if aif_have "$t"; then
      ver="$("$t" --version 2>/dev/null | head -1 | tr -d '\r\n')"
      printf '  %s %-10s %s\n' "$(aif_ok)" "$t" "${ver:-?}"
    else
      printf '  %s %-10s %snot installed%s\n' \
        "$(aif_no)" "$t" "$AIF_C_DIM" "$AIF_C_RESET"
    fi
  done
}

# Project health, but only when run inside an initialised project. Two
# silent-failure classes are worth catching here before they cost a station run:
# an invalid project.json (every gate downstream degrades to theatre), and a
# skill pointing `agent:` at an agent that does not exist (which claude silently
# resolves to general-purpose — a quiet tier downgrade on the quality mechanism).
_aif_doctor_project() {
  local root config
  root="$(aif_project_root 2>/dev/null)" || return 0
  [ -d "$root/.aif" ] || return 0

  printf '\n%sProject%s  %s%s%s\n' "$AIF_C_BOLD" "$AIF_C_RESET" "$AIF_C_DIM" "$root" "$AIF_C_RESET"

  config="$(aif_project_config "$root")"
  if [ ! -f "$config" ]; then
    printf '  %s %-14s %snot set up — run: aif project init%s\n' \
      "$(aif_no)" "project.json" "$AIF_C_YELLOW" "$AIF_C_RESET"
  else
    local problems
    problems="$(aif_project_validate "$config")"
    if [ -n "$problems" ]; then
      printf '  %s %-14s invalid:\n' "$(aif_no)" "project.json"
      printf '%s\n' "$problems" | sed 's/^/       /'
    else
      printf '  %s %-14s valid\n' "$(aif_ok)" "project.json"
    fi

    # The Definition of Done, reported whichever way it went. An empty checks
    # list means green will enforce the test command and nothing else — a real
    # answer, and one worth seeing before a ticket is judged against it rather
    # than after.
    local nchecks
    nchecks="$(jq '(.checks // []) | length' "$config" 2>/dev/null)"
    if [ "${nchecks:-0}" -eq 0 ]; then
      printf '  %s %-14s %snone — the test command is the whole Definition of Done (aif project checks)%s\n' \
        "$(aif_no)" "checks" "$AIF_C_DIM" "$AIF_C_RESET"
    else
      printf '  %s %-14s %s\n' "$(aif_ok)" "checks" \
        "$(jq -r '[.checks[] | .name + " [" + (.phase | join(",")) + "]"] | join(", ")' "$config")"
    fi
  fi

  # Every agent a skill dispatches to must exist, or the fork silently falls
  # back to general-purpose.
  local skills_dir agents_dir missing=0 skill agent_name
  skills_dir="$root/.claude/skills"
  agents_dir="$root/.claude/agents"
  if [ -d "$skills_dir" ]; then
    for skill in "$skills_dir"/*/SKILL.md; do
      [ -f "$skill" ] || continue
      # A skill's frontmatter is YAML, not our meta block, so read the field
      # directly rather than through aif_meta_json.
      #
      # `|| true` is load-bearing under `set -euo pipefail`: a skill with no
      # `agent:` line makes grep exit 1, pipefail propagates it, and the failed
      # assignment kills the whole of `aif doctor` on the spot. It did, silently,
      # for every project whose skills declare no agent — which is all of them.
      # The output simply stopped after "project.json valid" and the command
      # exited 1, so the one check this function exists for had never run.
      agent_name="$(grep -E '^agent:' "$skill" 2>/dev/null | head -1 | sed 's/^agent:[[:space:]]*//' | tr -d '\r')" || true
      [ -n "$agent_name" ] || continue
      if [ ! -f "$agents_dir/$agent_name.md" ]; then
        printf '  %s %-14s %s → agent "%s" not found\n' \
          "$(aif_no)" "skill target" "$(basename "$(dirname "$skill")")" "$agent_name"
        missing=1
      fi
    done
  fi
  [ "$missing" -eq 0 ] && printf '  %s %-14s all skill agent targets exist\n' "$(aif_ok)" "skill targets"
}

# aif_doctor_probe <root> — does this project's test toolchain actually work?
#
# The other checks read; this one RUNS the project's test command. That is the
# only way to answer the question, and the question is worth the side effect:
# on a live ticket the gates discovered a missing jest-junit at the LAST gate,
# after roughly $6.61 of stations had already run. Everything the gates decide
# rests on this command producing a parseable report, so it is established
# before a token is spent rather than after.
#
# A red suite is a PASS here. The probe asks "does the runner run and emit a
# report", not "do the tests pass" — at ticket start they had better not.
#
# rc 0 usable · 1 the pipeline cannot be trusted to run.
aif_doctor_probe() {
  local root="$1"
  local config report_path report_fmt test_cmd rc=0 out

  printf '\n%sTest toolchain%s\n' "$AIF_C_BOLD" "$AIF_C_RESET"

  config="$(aif_project_config "$root")"
  if [ ! -f "$config" ]; then
    printf '  %s %-14s %sno project.json — run: aif project init%s\n' \
      "$(aif_no)" "config" "$AIF_C_YELLOW" "$AIF_C_RESET"
    return 1
  fi

  # python3 parses the JUnit report per test case. Without it verify-red and
  # green fall back to the suite's exit code alone, which cannot tell a
  # legitimate failure from a broken one — the gates still work, but the oracle
  # is blunt. Loud, not fatal: a blunt gate is worse than a sharp one and better
  # than none.
  if aif_have python3; then
    printf '  %s %-14s %s\n' "$(aif_ok)" "python3" \
      "$(python3 --version 2>&1 | head -1) — per-test checking available"
  else
    printf '  %s %-14s %snot installed — verify-red and green degrade to COARSE mode%s\n' \
      "$(aif_no)" "python3" "$AIF_C_YELLOW" "$AIF_C_RESET"
    printf '       %sthey read only the suite exit code, so a broken suite and a\n' "$AIF_C_DIM"
    printf '       legitimately failing one look the same%s\n' "$AIF_C_RESET"
  fi

  test_cmd="$(jq -r '.test.command // empty' "$config")"
  report_path="$(jq -r '.test.report.path // empty' "$config")"
  report_fmt="$(jq -r '.test.report.format // empty' "$config")"
  if [ -z "$test_cmd" ] || [ -z "$report_path" ]; then
    printf '  %s %-14s project.json names no test command or report path\n' "$(aif_no)" "test command"
    return 1
  fi

  # The report is the discriminator. A suite that fails still writes one; a
  # runner that is not installed does not. So the check is "did a report appear",
  # not "what did the command exit with" — which would fail every red suite.
  rm -f "$root/$report_path" 2>/dev/null || true
  mkdir -p "$root/$(dirname "$report_path")" 2>/dev/null || true

  out="$(cd "$root" && eval "$test_cmd" 2>&1)" || rc=$?
  if [ ! -f "$root/$report_path" ]; then
    printf '  %s %-14s ran, but wrote no report at %s\n' "$(aif_no)" "test command" "$report_path"
    printf '       %s%s%s\n' "$AIF_C_DIM" "$(printf '%s' "$out" | tail -3 | tr '\n' ' ')" "$AIF_C_RESET"
    printf '       %severy gate reads that report; without it they cannot render a verdict.%s\n' \
      "$AIF_C_YELLOW" "$AIF_C_RESET"
    printf '       %sfix test.command in .aif/project.json, or install what it needs\n' "$AIF_C_DIM"
    printf '       (a junit reporter, e.g. jest-junit or pytest --junitxml)%s\n' "$AIF_C_RESET"
    return 1
  fi
  printf '  %s %-14s ran (exit %s — a red suite is fine here)\n' "$(aif_ok)" "test command" "$rc"

  # And the report must be readable by what reads it, in the format declared.
  local cases=""
  if [ "$report_fmt" = "junit" ] && aif_have python3; then
    # junit.py emits ONE line: a JSON array of test cases. Counting lines here
    # would report 0 for a perfectly good report — measured, after it did.
    cases="$(python3 "$root/.aif/gates/junit.py" "$root/$report_path" 2>/dev/null | jq 'length' 2>/dev/null)"
    if [ -z "$cases" ] || [ "$cases" = "0" ]; then
      printf '  %s %-14s %s exists but no test cases parsed out of it\n' \
        "$(aif_no)" "test report" "$report_path"
      printf '       %sthe format may not be %s, or the suite collected nothing%s\n' \
        "$AIF_C_YELLOW" "$report_fmt" "$AIF_C_RESET"
      return 1
    fi
    printf '  %s %-14s %s · %s · %s test case(s)\n' \
      "$(aif_ok)" "test report" "$report_path" "$report_fmt" "$cases"
  else
    printf '  %s %-14s %s · %s (not parsed — no python3)\n' \
      "$(aif_ok)" "test report" "$report_path" "$report_fmt"
  fi

  return 0
}

aif_doctor() {
  local probe=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --probe) probe=1 ;;
      -h | --help)
        printf 'usage: aif doctor [--probe]\n\n'
        printf '  --probe  also RUN the project test command and check it emits a\n'
        printf '           parseable report. Has a side effect, hence opt-in here —\n'
        printf '           the run command does it for you before spending anything.\n'
        return 0
        ;;
      *) aif_die "unknown option: $1" ;;
    esac
    shift
  done

  printf '%saif %s%s\n\n' "$AIF_C_BOLD" "$AIF_VERSION" "$AIF_C_RESET"

  _aif_doctor_runners
  _aif_doctor_tooling
  _aif_doctor_project

  local probe_rc=0
  if [ "$probe" -eq 1 ]; then
    local root
    root="$(aif_project_root 2>/dev/null)" || root=""
    if [ -n "$root" ]; then
      aif_doctor_probe "$root" || probe_rc=$?
    fi
  fi

  printf '\n'
  [ "$probe_rc" -eq 0 ] || return 1

  local available
  available="$(aif_runners_available)"
  if [ -z "$available" ]; then
    aif_warn "no agentic CLI found — aif has nothing to drive"
    printf '      %sInstall one, e.g.: brew install --cask claude-code%s\n' \
      "$AIF_C_DIM" "$AIF_C_RESET"
    return 1
  fi

  printf 'aif can drive:%s\n' "$(printf ' %s' "$available")"

  if ! aif_have jq; then
    aif_warn "jq is missing — init and test will need it"
    return 1
  fi

  return 0
}
