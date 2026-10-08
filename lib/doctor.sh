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
  if ! root="$(aif_project_root 2>/dev/null)"; then
    # The precondition everything else rests on, and the one a fresh machine
    # hits first: `aif init` refuses outside a repository, but doctor used to
    # print a clean bill of health here and say what it could drive. A report
    # that is green where the next command is guaranteed to fail is worse than
    # no report.
    printf '\n%sProject%s\n' "$AIF_C_BOLD" "$AIF_C_RESET"
    printf '  %s %-14s %snot a git repository — aif needs one. Run: git init%s\n' \
      "$(aif_no)" "git" "$AIF_C_YELLOW" "$AIF_C_RESET"
    return 1
  fi
  if [ ! -d "$root/.aif" ]; then
    printf '\n%sProject%s  %s%s%s\n' "$AIF_C_BOLD" "$AIF_C_RESET" "$AIF_C_DIM" "$root" "$AIF_C_RESET"
    printf '  %s %-14s %saif is not installed here. Run: aif init%s\n' \
      "$(aif_no)" "set" "$AIF_C_YELLOW" "$AIF_C_RESET"
    return 1
  fi

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
      # Valid and current are different answers. A project.json from an older
      # template validates and still tells verify-red that a TypeError is a
      # legitimate red; the gates read it as it is (docs/DEFECTS.md 8.1).
      local drift_n
      drift_n="$(aif_project_drift "$config" | grep -c . || true)"
      if [ "${drift_n:-0}" -gt 0 ]; then
        printf '  %s %-14s valid, but %sbehind its template — %s thing(s) the gates now read differently (aif project check lists them; aif project upgrade brings them forward)%s\n' \
          "$(aif_no)" "project.json" "$AIF_C_YELLOW" "$drift_n" "$AIF_C_RESET"
      else
        printf '  %s %-14s valid\n' "$(aif_ok)" "project.json"
      fi
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

    # The knowledge layer (docs/REBUILD-4.md §6). The runner fragment is a
    # line, not a capability: a runner the set has no fragment for is the one
    # honest limit of the stations' self-sufficiency, and they work from their
    # general rules there — the worker does not refuse. The guide is the
    # worker's `test-guide` capability, probed below with the others.
    local kind recorded
    kind="$(aif_project_kind "$config")"
    recorded="$(aif_project_kind_recorded "$config")"
    if [ -z "$kind" ]; then
      printf '  %s %-14s %sno test.kind in project.json, and the test command names neither jest nor pytest — the stations get no runner fragment and work from their general rules%s\n' \
        "$(aif_no)" "stack" "$AIF_C_DIM" "$AIF_C_RESET"
    elif [ -n "$(aif_stack_fragment "$root" "$kind")" ]; then
      printf '  %s %-14s %s — %s/%s.md goes to the plan and tests stations%s\n' \
        "$(aif_ok)" "stack" "$kind" "$AIF_STACKS_DIR" "$kind" \
        "$([ -n "$recorded" ] || printf ' %s(inferred from test.command; record it as test.kind)%s' "$AIF_C_YELLOW" "$AIF_C_RESET")"
    else
      printf '  %s %-14s %sno fragment for %s at %s/%s.md — the stations work from their general rules (aif init installs the ones the set ships)%s\n' \
        "$(aif_no)" "stack" "$AIF_C_DIM" "$kind" "$AIF_STACKS_DIR" "$kind" "$AIF_C_RESET"
    fi
  fi

  # The managed block in .gitignore, against the one `aif init` writes now.
  # Nothing else rewrites it — not an upgrade, not `aif project upgrade` — so
  # a project set up before a line joined it goes without: .aif/start.local,
  # one developer's shift defaults, untracked and not ignored, one `git add -A`
  # from the team's repository (docs/DEFECTS.md 15.2). Named here with the
  # command that adds it, never written: the developer's .gitignore is theirs
  # to have rewritten, when they say so.
  local gi_missing
  gi_missing="$(_aif_doctor_gitignore_missing "$root")"
  if [ -z "$gi_missing" ]; then
    printf '  %s %-14s the managed block names every path aif keeps out of git\n' "$(aif_ok)" ".gitignore"
  else
    printf '  %s %-14s %sthe managed block lacks %s — aif init adds %s (it rewrites that block and nothing else)%s\n' \
      "$(aif_no)" ".gitignore" "$AIF_C_YELLOW" "$(printf '%s\n' "$gi_missing" | paste -sd, - | sed 's/,/, /g')" \
      "$([ "$(printf '%s\n' "$gi_missing" | grep -c .)" -eq 1 ] && printf it || printf them)" "$AIF_C_RESET"
  fi

  # Worktrees cut under an older set. Nothing to fix by hand — the worker
  # brings a branch up to the checkout's set before a run (docs/DEFECTS.md
  # 9.1) — but a reader of this table should see which branches still carry
  # the old one, because that is what a reviewer looking at those branches
  # sees too.
  local wt_dir wtm root_set behind=""
  root_set="$(jq -r '.set_version // ""' "$root/.aif/manifest.json" 2>/dev/null)"
  if [ -n "$root_set" ] && [ -d "$root/$AIF_WORK_WORKTREES" ]; then
    for wt_dir in "$root/$AIF_WORK_WORKTREES"/*/; do
      [ -d "$wt_dir" ] || continue
      wtm="$(jq -r '.set_version // "none"' "$wt_dir/.aif/manifest.json" 2>/dev/null || printf 'none')"
      [ "$wtm" != "$root_set" ] || continue
      behind="$behind, $(basename "$wt_dir") ($wtm)"
    done
    if [ -n "$behind" ]; then
      printf '  %s %-14s %son an older set: %s — brought up to %s at their next aif work%s\n' \
        "$(aif_no)" "worktrees" "$AIF_C_DIM" "${behind#, }" "$root_set" "$AIF_C_RESET"
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

# _aif_doctor_gitignore_missing <root> — each pattern of the managed block
# `aif init` writes (aif_gitignore_block, lib/paths.sh) that the block in
# <root>/.gitignore lacks, one a line; every one of them when the file or the
# block is not there. Found as aif_block_inject finds the block (lib/merge.sh):
# by its markers, anywhere on a line; a line inside it matched whole, a
# browser's \r and trailing blanks taken off.
_aif_doctor_gitignore_missing() {
  local f="$1/.gitignore" have=""
  # shellcheck source=lib/merge.sh
  . "$AIF_ROOT/lib/merge.sh"
  if [ -f "$f" ]; then
    have="$(awk -v b="$AIF_MARK_BEGIN_HASH" -v e="$AIF_MARK_END_HASH" '
      index($0, b) { inb = 1; next }
      inb && index($0, e) { inb = 0; next }
      inb { sub(/\r$/, ""); sub(/[[:space:]]+$/, ""); print }' "$f" 2>/dev/null)" || have=""
  fi
  # The lines through the environment, not `-v`: a multi-line assignment on
  # awk's command line dies with "newline in string" (lib/merge.sh says why).
  aif_gitignore_block | AIF_D_HAVE="$have" awk '
    BEGIN { n = split(ENVIRON["AIF_D_HAVE"], h, "\n"); for (i = 1; i <= n; i++) got[h[i]] = 1 }
    /^#/ || !NF { next }
    !($0 in got) { print }'
}

# _aif_doctor_unroot <root> — stdin with every spelling of <root> taken out, as
# literal text (a path is not a regex). What remains of a path under the root
# is relative to it.
_aif_doctor_unroot() {
  local r1="$1" r2
  r2="$(cd "$r1" 2>/dev/null && pwd -P)" || r2="$r1"
  AIF_D_R1="$r1" AIF_D_R2="$r2" awk '
    function cut(s, from,   out, i) {
      if (from == "") return s
      out = ""
      while ((i = index(s, from)) > 0) { out = out substr(s, 1, i - 1); s = substr(s, i + length(from)) }
      return out s
    }
    BEGIN { a = ENVIRON["AIF_D_R1"]; b = ENVIRON["AIF_D_R2"]; if (length(b) > length(a)) { t = a; a = b; b = t } }
    { print cut(cut($0, a), b) }'
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

  # The worker's checkouts live INSIDE the repository, at .aif/worktrees/<ID>,
  # and they are complete trees. A test runner that globs from the project root
  # does not care that git is hiding them: it collects every suite twice — once
  # real, once from the worker's copy — and reports failures that do not exist.
  # One `aif work` run is enough to make the project's own `npm test`
  # meaningless, and the noise reads as the ticket's fault.
  #
  # Established from evidence, not from the presence of the directory: the run
  # that just happened either mentioned those paths or it did not.
  # No -q on the piped grep: the suite's output can be far larger than a pipe
  # buffer, and a grep that leaves at the first match hands printf SIGPIPE —
  # which `pipefail` turns into "not found" for exactly the suites large enough
  # to matter (docs/DEFECTS.md 5.3). Without -q grep reads to the end.
  #
  # The probed root's own path is taken out first. The worker probes INSIDE a
  # worktree, whose every absolute path runs through .aif/worktrees/ — so a
  # red test whose stack trace names its own file read as "this runner
  # collects the worker's checkouts", and the run was refused for a collision
  # that was not there (docs/DEFECTS.md 6.5).
  if printf '%s' "$out" | _aif_doctor_unroot "$root" | grep "$AIF_WORK_WORKTREES/" >/dev/null ||
    { [ -f "$root/$report_path" ] &&
      _aif_doctor_unroot "$root" <"$root/$report_path" | grep "$AIF_WORK_WORKTREES/" >/dev/null; }; then
    printf '  %s %-14s it collects %s%s/%s too — the worker'"'"'s own checkouts\n' \
      "$(aif_no)" "test scope" "$AIF_C_YELLOW" "$AIF_WORK_WORKTREES" "$AIF_C_RESET"
    printf '       %severy suite is then counted twice, once from a copy on another branch,\n' "$AIF_C_DIM"
    printf '       and the extra failures belong to no ticket. Tell the runner to skip it:%s\n' "$AIF_C_RESET"
    case "$test_cmd" in
      *jest* | *vitest*)
        printf '       %stestPathIgnorePatterns: ["<rootDir>/%s/"]%s\n' \
          "$AIF_C_DIM" "$AIF_WORK_WORKTREES" "$AIF_C_RESET"
        ;;
      *pytest*)
        printf '       %snorecursedirs = %s%s\n' "$AIF_C_DIM" "$AIF_WORK_WORKTREES" "$AIF_C_RESET"
        ;;
      *)
        printf '       %s(the ignore list your runner reads, with the path %s/)%s\n' \
          "$AIF_C_DIM" "$AIF_WORK_WORKTREES" "$AIF_C_RESET"
        ;;
    esac
    # The obvious pattern is a trap, so it is named. An unanchored `.aif/`
    # matches inside the worktree as well, where the gates run the suite — and
    # a worktree that excludes its own tree collects nothing, writes an empty
    # report, and the gate falls to coarse mode on a project that is fine.
    printf '       %sAnchor it (<rootDir>, or a rootdir-relative path). A bare ".aif/" also\n' "$AIF_C_YELLOW"
    printf '       matches when the suite runs INSIDE a worktree, and then it finds no tests.%s\n' "$AIF_C_RESET"
    return 1
  fi

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

# _aif_doctor_guard_matcher <root> — the matcher our PreToolUse registration
# carries in .claude/settings.json, echoed; rc 1 when the guard hook is not
# registered there at all. Ours is the entry whose every hook runs from
# .aif/hooks/, the same reading aif init uses to refresh it.
_aif_doctor_guard_matcher() {
  local f="$1/.claude/settings.json" m
  [ -f "$f" ] || return 1
  m="$(jq -r '
    [ (.hooks.PreToolUse // [])[]
      | select(((.hooks // []) | length > 0) and ((.hooks // []) | all((.command // "") | contains("/.aif/hooks/guard.sh"))))
      | .matcher // "" ] | .[0] // "none"' "$f" 2>/dev/null)" || return 1
  [ -n "$m" ] && [ "$m" != "none" ] || return 1
  printf '%s' "$m"
}

# _aif_doctor_caps <root|""> <probe-suite 0|1> <probe-runner 0|1> — every
# capability, probed, as JSON:
#   { "<name>": { "ok": true|false|null, "detail": "…" } }
#
# ok is null where the answer needs a side effect nobody asked for: the test
# toolchain is only known once the suite has been run, which is what --probe
# is. A role that needs an unknown capability reports as unknown, never as
# ready — "not checked" and "checked and fine" are different answers.
#
# `board` is the probe that matters most and the one a file check cannot do:
# it is lib/board.sh's aif_board_check — a token that resolves, one real call
# that succeeds, six columns that exist. The human cannot know which of those
# is missing on their machine; this is the thing that tells them.
_aif_doctor_caps() {
  # TWO switches, not one, and they are separate because the text path needs
  # different answers to them: it has already run the suite itself (so it must
  # not run it again) but has NOT called the runner (so it must). Sharing one
  # flag is how `aif doctor --probe` came to print "not asked whether it
  # answers here (aif doctor --probe)" at someone who had just run exactly
  # that — advice contradicting the command that produced it.
  local root="$1" probe="$2" probe_runner="${3:-$2}"
  local c_ok c_d h_ok h_d g_ok g_d t_ok t_d b_ok b_d p_ok p_d out

  # TWO capabilities, because the roles ask two different questions of the
  # runner and collapsing them gets one of them wrong whichever way you pick:
  #
  #   claude           — is there a session to type a skill INTO? A skill is
  #                      prompt text a model already running reads; /aif-ba
  #                      spawns nothing. Presence is the whole question, and it
  #                      is answerable for free.
  #   claude-headless  — can aif SPAWN a runner and get an answer? That is the
  #                      worker's first dispatch, and only --probe can ask it.
  #
  # The case that forced the split: a machine whose interactive app works fine
  # while the CLI's own stored OAuth session has expired (FINDINGS #7, narrowed
  # twice). There, the analyst really is ready and the worker really is not —
  # one capability cannot say both.
  if aif_have claude; then
    c_ok=true
    c_d="$(aif_runner_version claude) — a session to run the skills in"
  else
    c_ok=false
    c_d="claude is not installed — brew install --cask claude-code"
  fi

  if [ -n "${AIF_WORK_STATION_CMD:-}" ]; then
    # The offline seam: a scripted command stands in for the runner, which is
    # how the check suite drives the whole worker without a model. Probing
    # claude here would ask about something no station is going to use — and
    # would put a billed call inside `make check`.
    h_ok=true
    h_d="substituted by AIF_WORK_STATION_CMD — a scripted runner is in use"
  elif [ "$c_ok" = false ]; then
    h_ok=false
    h_d="claude is not installed — brew install --cask claude-code"
  elif [ "$probe_runner" -eq 1 ]; then
    # shellcheck source=lib/runner_claude.sh
    . "$AIF_ROOT/lib/runner_claude.sh"
    local h_out
    if h_out="$(aif_runner_claude_probe)"; then
      h_ok=true
      h_d="spawned and $h_out"
    else
      h_ok=false
      h_d="installed but a spawned run did not answer: $h_out"
    fi
  else
    h_ok=null
    h_d="not asked whether a spawned run answers here (aif doctor --probe)"
  fi

  if ! aif_have git; then
    g_ok=false
    g_d="git is not installed"
  elif [ -n "$root" ]; then
    if git -C "$root" worktree list >/dev/null 2>&1; then
      g_ok=true
      g_d="$(git --version | head -1)"
    else
      g_ok=false
      g_d="git worktree does not work here — git 2.5 or newer is needed"
    fi
  else
    g_ok=true
    g_d="$(git --version | head -1) (no project to check a worktree in)"
  fi

  if [ -z "$root" ]; then
    t_ok=false
    t_d="not in a project"
  elif [ "$probe" -eq 1 ]; then
    if out="$(aif_doctor_probe "$root" 2>&1)"; then
      t_ok=true
      t_d="the test command runs and writes a parseable report"
    else
      t_ok=false
      t_d="$(printf '%s' "$out" | grep -E '✗' | head -1 | sed 's/^[^a-zA-Z]*//; s/  */ /g')"
      [ -n "$t_d" ] || t_d="the test toolchain cannot produce a verdict — aif doctor --probe"
    fi
  else
    t_ok=null
    t_d="not probed — aif doctor --probe runs the test command once"
  fi

  if [ -z "$root" ] || [ ! -f "$(aif_project_config "$root")" ]; then
    b_ok=false
    b_d="no .aif/project.json here"
  elif out="$(aif_board_check "$root" 2>&1)"; then
    b_ok=true
    b_d="$(printf '%s' "$out" | head -1 | sed 's/^board: //')"
  else
    b_ok=false
    b_d="$(printf '%s' "$out" | head -1 | sed 's/^board: //')"
  fi

  if aif_have python3; then
    p_ok=true
    p_d="$(python3 --version 2>&1 | head -1)"
  else
    p_ok=false
    p_d="python3 is not installed — verify-red and green degrade to coarse mode"
  fi

  # station-guard — has the guard hook been seen to DENY a command in a
  # spawned run here? The tests station's `aif _verify` loop rides on it, and
  # the worker withholds Bash from that station until this says yes. Not a
  # file check: a registered hook that does not fire is the failure this
  # exists to catch. Probed by --probe; remembered per runner version in
  # .aif/state/guard-probed, so a `claude` upgrade asks again.
  local s_ok s_d s_marker s_matcher
  if [ -z "$root" ]; then
    s_ok=false
    s_d="not in a project"
  elif [ -n "${AIF_WORK_STATION_CMD:-}" ]; then
    s_ok=true
    s_d="substituted by AIF_WORK_STATION_CMD — a scripted runner is in use"
  elif ! s_matcher="$(_aif_doctor_guard_matcher "$root")"; then
    # Read before anything is probed: a hook that is not registered, or is
    # registered for the write tools only, cannot deny a command whatever a
    # probe says. A project initialised before 0.5.3 kept a matcher without
    # Bash through every later init (docs/DEFECTS.md 8.2).
    s_ok=false
    s_d="the guard hook is not registered in .claude/settings.json — aif init registers it"
  elif ! printf '%s' "$s_matcher" | tr '|' '\n' | grep -qx Bash; then
    s_ok=false
    s_d="the guard is registered for \"$s_matcher\" — without Bash it never sees a command, and the tests station's aif _verify is never granted; aif init refreshes the registration"
  else
    s_marker="$root/.aif/state/guard-probed"
    if [ "$probe_runner" -eq 1 ] && [ "$c_ok" = true ]; then
      # shellcheck source=lib/runner_claude.sh
      . "$AIF_ROOT/lib/runner_claude.sh"
      local s_out
      if s_out="$(aif_runner_claude_guard_probe "$root")"; then
        s_ok=true
        s_d="$s_out"
      else
        s_ok=false
        s_d="$s_out — the tests station runs without aif _verify until it does"
      fi
    elif [ -f "$s_marker" ] && [ "$(cat "$s_marker" 2>/dev/null)" = "$(aif_runner_version claude)" ]; then
      s_ok=true
      s_d="denied a command in a spawned run (claude $(cat "$s_marker"))"
    else
      s_ok=null
      s_d="not asked whether the guard denies a command here (aif doctor --probe); the tests station runs without aif _verify until it is"
    fi
  fi

  # test-guide — the project's guide to its own tests, which the worker
  # appends to the plan and tests stations' prompts (docs/REBUILD-4.md §6).
  # Three things, and all three are read rather than assumed: it exists, it is
  # in HEAD (the worker's checkout is cut from there — a guide written and
  # never committed exists for the developer and nobody else), and every path
  # it cites still exists. A file check alone would pass a guide that sends
  # the stations to a helper renamed last week. The human's section being
  # unwritten is said, not failed: nothing mechanical can write it.
  local tg_ok tg_d tg_missing tg_n
  if [ -z "$root" ]; then
    tg_ok=false
    tg_d="not in a project"
  elif [ ! -f "$(aif_guide_path "$root")" ]; then
    tg_ok=false
    tg_d="no $AIF_GUIDE_FILE — the plan and tests stations read it; write it from the repository: aif project guide"
  else
    tg_missing="$(aif_guide_missing_paths "$root")"
    tg_n="$(aif_guide_cited_paths "$(aif_guide_path "$root")" | grep -c . || true)"
    if [ -n "$tg_missing" ]; then
      tg_ok=false
      tg_d="$AIF_GUIDE_FILE names paths that no longer exist: $(printf '%s\n' "$tg_missing" | sed -n '1,3p' | paste -sd, - | sed 's/,/, /g') — aif project guide brings its block up to date; what you wrote by hand is yours to fix"
    elif ! aif_guide_committed "$root"; then
      tg_ok=false
      tg_d="$AIF_GUIDE_FILE is not committed — the stations run in a checkout cut from HEAD, which does not have it: git add $AIF_GUIDE_FILE && git commit"
    else
      tg_ok=true
      tg_d="$AIF_GUIDE_FILE — ${tg_n:-0} path(s) cited, all exist"
      aif_guide_unwritten "$root" &&
        tg_d="$tg_d; its boundaries section is not written yet (/aif-setup writes it with you, or edit the file)"
    fi
  fi

  jq -n --argjson c "$c_ok" --arg cd "$c_d" --argjson h "$h_ok" --arg hd "$h_d" \
    --argjson g "$g_ok" --arg gd "$g_d" \
    --argjson t "$t_ok" --arg td "$t_d" --argjson b "$b_ok" --arg bd "$b_d" \
    --argjson p "$p_ok" --arg pd "$p_d" --argjson s "$s_ok" --arg sd "$s_d" \
    --argjson tg "$tg_ok" --arg tgd "$tg_d" '
    { "claude":          { ok: $c, detail: $cd },
      "claude-headless": { ok: $h, detail: $hd },
      "git-worktree":   { ok: $g, detail: $gd },
      "test-toolchain": { ok: $t, detail: $td },
      "board":          { ok: $b, detail: $bd },
      "python3":        { ok: $p, detail: $pd },
      "station-guard":  { ok: $s, detail: $sd },
      "test-guide":     { ok: $tg, detail: $tgd } }'
}

# _aif_doctor_roles <root|""> <caps-json> — per role: ready, and what is
# missing, as a JSON array. The roles come from lib/roles.sh (the worker) and
# from every installed skill's frontmatter.
_aif_doctor_roles() {
  local root="$1" caps="$2" role req rows="" tab
  tab="$(printf '\t')"
  while IFS="$tab" read -r role req; do
    [ -n "$role" ] || continue
    rows="$rows$(jq -n --arg r "$role" --arg req "$req" --argjson caps "$caps" '
      ($req | split(" ") | map(select(length > 0))) as $needs
      | [ $needs[] | . as $n
          | ($caps[$n] // { ok: false, detail: "unknown capability — no probe by that name" }) as $c
          | { cap: $n, ok: $c.ok, detail: $c.detail } ] as $checked
      | { role: $r,
          requires: $needs,
          ready: (if any($checked[]; .ok == false) then false
                  elif any($checked[]; .ok == null) then null
                  else true end),
          missing: [ $checked[] | select(.ok == false) | .cap + ": " + .detail ],
          unknown: [ $checked[] | select(.ok == null) | .cap + ": " + .detail ] }')
"
  done <<EOF
$(if [ -n "$root" ]; then aif_roles_all "$root"; else aif_roles_builtin; fi)
EOF
  printf '%s' "$rows" | jq -s '.'
}

_aif_doctor_render_roles() {
  printf '\n%sRoles%s  %swhich of the foundry'"'"'s roles can work on this machine%s\n' \
    "$AIF_C_BOLD" "$AIF_C_RESET" "$AIF_C_DIM" "$AIF_C_RESET"
  printf '%s' "$1" | jq -r '
    .[] | (if .ready == true then "  ✓ " elif .ready == false then "  ✗ " else "  ? " end)
        + (.role + "          ")[0:10]
        + (if .ready == true then "ready"
           elif .ready == false then (.missing | join("; "))
           else (.unknown | join("; ")) end)'
}

aif_doctor() {
  local probe=0 json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --probe) probe=1 ;;
      --json) json=1 ;;
      -h | --help)
        printf 'usage: aif doctor [--probe] [--json]\n\n'
        printf '  --probe  also RUN the project test command and check it emits a\n'
        printf '           parseable report. Has a side effect, hence opt-in here —\n'
        printf '           the work command does it for you before spending anything.\n'
        printf '  --json   the same facts as data: capabilities, and per role whether it\n'
        printf '           is ready here and what is missing. What /aif-setup reads.\n'
        return 0
        ;;
      *) aif_die "unknown option: $1" ;;
    esac
    shift
  done

  local root caps roles="[]"
  root="$(aif_project_root 2>/dev/null)" || root=""
  [ -n "$root" ] && [ -d "$root/.aif" ] || root=""

  if [ "$json" -eq 1 ]; then
    caps="$(_aif_doctor_caps "$root" "$probe" "$probe")"
    roles="$(_aif_doctor_roles "$root" "$caps")"
    jq -n --arg v "$AIF_VERSION" --arg root "$root" --argjson caps "$caps" --argjson roles "$roles" \
      '{ aif: $v, project: (if $root == "" then null else $root end), capabilities: $caps, roles: $roles }'
    return 0
  fi

  printf '%saif %s%s\n\n' "$AIF_C_BOLD" "$AIF_VERSION" "$AIF_C_RESET"

  _aif_doctor_runners
  _aif_doctor_tooling
  local project_rc=0
  _aif_doctor_project || project_rc=$?

  local probe_rc=0
  if [ "$probe" -eq 1 ]; then
    if [ -n "$root" ]; then
      aif_doctor_probe "$root" || probe_rc=$?
    fi
  fi

  # Roles last, because they are the summary of everything above put the way
  # a person asks the question: can I run the analyst here, the worker, the
  # project manager — and if not, what exactly is missing.
  if [ -n "$root" ]; then
    # The suite already ran above when asked, so do not run it twice — but the
    # RUNNER has not been called yet, and --probe is what asks it to be.
    caps="$(_aif_doctor_caps "$root" 0 "$probe")"
    if [ "$probe" -eq 1 ]; then
      caps="$(printf '%s' "$caps" | jq --argjson ok "$([ "$probe_rc" -eq 0 ] && printf true || printf false)" \
        '."test-toolchain" = { ok: $ok, detail: (if $ok then "the test command runs and writes a parseable report" else "the test toolchain cannot produce a verdict — see above" end) }')"
    fi
    roles="$(_aif_doctor_roles "$root" "$caps")"
    _aif_doctor_render_roles "$roles"

    # Not a role's requirement — the worker runs without it, slower — and so
    # not in the table above; and until now rendered only in --json, so a
    # guard that never saw a command was invisible to anyone reading this
    # (docs/DEFECTS.md 8.2).
    printf '\n%sStations%s  %swhat the worker hands its stations%s\n' \
      "$AIF_C_BOLD" "$AIF_C_RESET" "$AIF_C_DIM" "$AIF_C_RESET"
    printf '%s' "$caps" | jq -r '
      ."station-guard"
      | (if .ok == true then "  ✓ " elif .ok == false then "  ✗ " else "  ? " end)
        + ("station-guard" + "              ")[0:15] + .detail'
  fi

  printf '\n'

  if ! aif_have jq; then
    aif_warn "jq is missing — nothing here works without it"
    return 1
  fi

  local available
  available="$(aif_runners_available)"
  if [ -z "$available" ]; then
    aif_warn "no agentic CLI found — aif has nothing to drive"
    printf '      %sInstall one, e.g.: brew install --cask claude-code%s\n' \
      "$AIF_C_DIM" "$AIF_C_RESET"
    return 1
  fi

  # The single most useful line: what to do next, here, now. A report that ends
  # with a capability list leaves the reader to work out the blocker themselves,
  # and the blocker is usually one command.
  if [ "$project_rc" -ne 0 ]; then
    return 1
  fi
  if [ ! -f "$(aif_project_config "$root")" ]; then
    printf 'next: %saif project init%s\n' "$AIF_C_BOLD" "$AIF_C_RESET"
    return 1
  fi
  if [ "$(aif_project_drift "$(aif_project_config "$root")" | grep -c . || true)" -gt 0 ]; then
    printf 'next: %saif project upgrade%s — project.json is behind the template it was made from; aif project check says what moved\n' \
      "$AIF_C_BOLD" "$AIF_C_RESET"
    return 1
  fi
  # The guide comes right after project.json in the order of setting up, and
  # before the probe: the worker refuses to run without it, and the probe's
  # cost is better spent once the refusal is out of the way.
  if [ ! -f "$(aif_guide_path "$root")" ]; then
    printf 'next: %saif project guide%s — writes %s from what the repository declares; the plan and tests stations read it\n' \
      "$AIF_C_BOLD" "$AIF_C_RESET" "$AIF_GUIDE_FILE"
    return 1
  fi
  if [ "$probe_rc" -ne 0 ]; then
    return 1
  fi
  if [ "$probe" -eq 0 ]; then
    printf 'next: %saif doctor --probe%s — runs your test command and the runner once, which is the only way to know they work here\n' \
      "$AIF_C_BOLD" "$AIF_C_RESET"
    return 0
  fi

  # The closing line has to agree with the table above it, and it has to say
  # WHERE each command is typed. `aif` is a shell command; `/aif-setup` is a
  # Claude Code session command. Printed side by side with nothing to tell
  # them apart, the second one gets typed into zsh — which is exactly what
  # happened the first time this line existed.
  local blocked
  blocked="$(printf '%s' "$roles" | jq -r '[ .[] | select(.ready == false) | .role ] | join(", ")')"
  if [ -n "$blocked" ]; then
    # The ✗ rows above already carry the reason and the remedy; repeating them
    # here would double the longest lines on the screen.
    printf 'next: %s cannot run yet — see the %s✗%s above.\n' \
      "$blocked" "$AIF_C_RED" "$AIF_C_RESET"
    printf '      Fix it here in the shell, or open Claude Code in this project and type\n'
    printf '      %s/aif-setup%s %s— a session command, not a shell one.%s\n' \
      "$AIF_C_BOLD" "$AIF_C_RESET" "$AIF_C_DIM" "$AIF_C_RESET"
    return 1
  fi

  printf 'next: in a Claude Code session:  %s/aif-ba <ID> "<what to build>"%s\n' \
    "$AIF_C_BOLD" "$AIF_C_RESET"
  printf '      then back in this shell:   %saif work%s\n' \
    "$AIF_C_BOLD" "$AIF_C_RESET"
  return 0
}
