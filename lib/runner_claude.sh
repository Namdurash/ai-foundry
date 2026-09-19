#!/usr/bin/env bash
#
# The claude runner. This is the ONLY module that knows claude's argv, its
# environment variable names and the shape of its JSON envelope. Commands call
# aif_runner_<runner>_* and never mention --output-format or ANTHROPIC_*.
#
# That boundary is what makes a second runner cheap: sets/codex lands as
# lib/runner_codex.sh implementing the same handful of functions, and no command
# module changes.
#
# It shrank when the stations became subagents. `_station` and `_converse` are
# gone with the bash orchestrator that called them: a station is now dispatched
# inside the session by the runner's own agent mechanism, so aif no longer needs
# a way to spawn one. What is left is what aif still does itself — open a
# session (`_start`) and run an eval (`_eval`) — plus reading the envelope those
# produce.
#
# Sourced by bin/aif; not meant to be executed directly.

aif_runner_claude_available() {
  aif_have claude
}

aif_runner_claude_version() {
  claude --version 2>/dev/null | head -1 | tr -d '\r\n'
}

# aif_runner_claude_start <headless> <task>
#
# Hands the terminal over to claude. The caller has already exported the
# profile's environment, so the child inherits the right routing.
#
# exec, not a plain call: the wrapper has nothing left to do, and replacing it
# means signals, job control and the TTY all reach claude directly rather than
# through a bash process that would swallow them.
aif_runner_claude_start() {
  local headless="$1" task="$2"

  if [ "$headless" -eq 1 ]; then
    [ -n "$task" ] || aif_die "--headless needs a task"
    exec claude -p "$task"
  fi

  if [ -n "$task" ]; then
    exec claude "$task"
  fi

  exec claude
}

# aif_runner_claude_eval <workdir> <prompt> <max_turns> <budget_usd> <out> <err>
#
# One headless run inside a disposable working directory. The caller has already
# exported the profile's environment.
aif_runner_claude_eval() {
  local workdir="$1" prompt="$2" max_turns="$3" budget="$4" out="$5" err="$6"

  # Deliberately NOT --bare. It skips CLAUDE.md auto-discovery, which is the
  # payload under test, and restricts auth to ANTHROPIC_API_KEY — so it cannot
  # authenticate a provider that uses ANTHROPIC_AUTH_TOKEN, which is how GLM
  # authenticates. Hermeticity comes from --setting-sources and a disposable
  # workdir instead. See docs/FINDINGS.md #4.
  #
  # bypassPermissions is safe here only because workdir is a throwaway copy —
  # never reuse this invocation against a real repository.
  (
    cd "$workdir" || exit 70
    claude -p "$prompt" \
      --output-format json \
      --max-turns "$max_turns" \
      --max-budget-usd "$budget" \
      --no-session-persistence \
      --permission-mode bypassPermissions \
      --setting-sources project,local \
      >"$out" 2>"$err" </dev/null
  )
}

# aif_runner_claude_result_ok <result.json>
#
# Gate on is_error and nothing else. The envelope reports subtype:"success"
# alongside is_error:true on a hard failure, so subtype cannot be trusted.
# See docs/FINDINGS.md #2.
aif_runner_claude_result_ok() {
  jq -e '.is_error == false' "$1" >/dev/null 2>&1
}

# aif_runner_claude_result_error <result.json> — the human-readable reason.
#
# "no result field" is not a fallback for a missing key so much as a diagnosis:
# the envelope carries .result only when the run produced a final answer. Its
# absence, with usage present, is what an exhausted turn budget looks like — so
# read this alongside subtype and num_turns, never alone.
aif_runner_claude_result_error() {
  jq -r '.result // "no result field"' "$1" 2>/dev/null | head -1
}

# aif_runner_claude_result_cost <result.json> — "cost_usd turns in_tok out_tok".
#
# total_cost_usd is 0 on error and legitimately 0 under subscription auth, so a
# zero here means nothing and must never gate anything.
aif_runner_claude_result_cost() {
  jq -r '[(.total_cost_usd // 0),
          (.num_turns // 0),
          (.usage.input_tokens // 0),
          (.usage.output_tokens // 0)] | @tsv' "$1" 2>/dev/null || printf '0\t0\t0\t0'
}

# aif_runner_claude_station <workdir> <sys-prompt-file> <user-prompt> <model>
#                           <max-turns> <budget-usd> <allowed-tools> <out> <err>
#
# One headless station run, for `aif work`. The instrumented path: aif invokes
# claude -p itself, so the JSON envelope carries num_turns and the four token
# classes the ledger needs — under subscription auth total_cost_usd is 0
# (docs/FINDINGS.md #2), so tokens are what gets recorded, and dollars are
# derived from the project's price table.
#
# The caller has already exported the profile's environment, so `--model opus`
# resolves to whatever the profile maps opus to (glm-5.2 on the glm profile).
# That remap is what keeps a set model-agnostic while a station still declares
# its tier.
#
# bypassPermissions is safe here for the same reason it is in _eval: the worker
# runs in a git WORKTREE — a disposable copy with its own checkout — never in
# the developer's working tree. Nothing a station writes reaches the branch the
# human is on until they merge it.
#
# --tools, not --allowedTools: the station's frontmatter names the tools it may
# have at all (a judge has no Bash), and under bypassPermissions "allowed" would
# restrict nothing. The list is comma-separated, as claude expects it.
#
# --setting-sources project,local: the project's hooks (guard, meter) load; the
# user's global settings do not, so a run is the same on every machine.
aif_runner_claude_station() {
  local workdir="$1" sys="$2" prompt="$3" model="$4"
  local max_turns="$5" budget="$6" tools="$7" out="$8" err="$9"

  (
    cd "$workdir" || exit 70
    claude -p "$prompt" \
      --append-system-prompt "$(cat "$sys")" \
      --model "$model" \
      --tools "$tools" \
      --output-format json \
      --max-turns "$max_turns" \
      --max-budget-usd "$budget" \
      --permission-mode bypassPermissions \
      --setting-sources project,local \
      >"$out" 2>"$err" </dev/null
  )
}

# aif_runner_claude_probe — does this runner actually ANSWER here?
#
# `aif_have claude` says a binary is on PATH. That is not the question the
# worker's first dispatch asks, and the difference is not hypothetical: a
# nested `claude -p` failed to authenticate in the very probe that established
# the flag set (docs/FINDINGS.md #12), on a machine where `aif doctor` was
# reporting the runner green. A presence check that reads as a readiness check
# is the same defect as a fail-open hook — it reports "fine" for "not asked".
#
# One turn, no tools, no session persistence. Echoes a one-line verdict.
# rc 0 the runner answered · 1 it did not.
aif_runner_claude_probe() {
  local out rc=0 err errfile
  errfile="$(mktemp "${TMPDIR:-/tmp}/aif-probe-XXXXXX")"

  # </dev/null and a SEPARATE stderr, both learned here the hard way:
  # without the first, `claude -p` waits three seconds for input it will never
  # get and warns about it; without the second, that warning lands in the
  # variable being parsed as JSON and every run reads as a failure. The
  # station runner has always had both — this function was written without
  # looking at it.
  out="$(claude -p 'Reply with exactly: ok' \
    --output-format json \
    --max-turns 1 \
    --tools "" \
    --no-session-persistence \
    --setting-sources project,local \
    2>"$errfile" </dev/null)" || rc=$?

  if [ -z "$out" ]; then
    err="$(head -1 "$errfile")"
    rm -f "$errfile"
    printf 'the runner produced no envelope (exit %s)%s' "$rc" \
      "$([ -n "$err" ] && printf ' — %s' "$err")"
    return 1
  fi
  rm -f "$errfile"
  if printf '%s' "$out" | jq -e '.is_error == false' >/dev/null 2>&1; then
    printf 'answered in %s turn(s)' "$(printf '%s' "$out" | jq -r '.num_turns // 0')"
    return 0
  fi
  err="$(printf '%s' "$out" | jq -r '.result // empty' 2>/dev/null | head -1)"
  [ -n "$err" ] || err="$(printf '%s' "$out" | head -1)"

  # An authentication failure inside a Claude Code session is the one result
  # this probe cannot be trusted on. docs/FINDINGS.md #7 was written as a law
  # from exactly this observation, and the law was false: the session exports
  # its own credentials into every child, so what failed may be the nesting
  # rather than the machine. Say so, instead of letting a confounded probe
  # send someone to debug an authentication that works fine one shell out.
  case "$err" in
    *authenticat* | *Authenticat* | *401*)
      if [ "${CLAUDECODE:-}" = "1" ]; then
        printf '%s — but this ran INSIDE a Claude Code session, where a nested run is confounded (FINDINGS #7). Run `aif doctor --probe` from your own terminal before believing it' "$err"
        return 1
      fi
      ;;
  esac
  printf '%s' "$err"
  return 1
}

# aif_runner_claude_result_usage <result.json> — the four token classes, as a
# JSON object. Zeros where the envelope has none, so a row is never missing a
# key — the failure path must record the same fields as the success path.
aif_runner_claude_result_usage() {
  jq -c '{
    input_tokens:                (.usage.input_tokens                // 0),
    output_tokens:               (.usage.output_tokens               // 0),
    cache_read_input_tokens:     (.usage.cache_read_input_tokens     // 0),
    cache_creation_input_tokens: (.usage.cache_creation_input_tokens // 0) }' \
    "$1" 2>/dev/null || printf '{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}'
}

# aif_runner_claude_result_subtype <result.json> — recorded, never branched on
# (docs/FINDINGS.md #2): "error_max_turns" says in one word what otherwise has
# to be inferred from a missing .result field.
aif_runner_claude_result_subtype() {
  jq -r '.subtype // ""' "$1" 2>/dev/null
}
