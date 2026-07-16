#!/usr/bin/env bash
#
# The claude runner. This is the ONLY module that knows claude's argv, its
# environment variable names and the shape of its JSON envelope. Commands call
# aif_runner_<runner>_* and never mention --output-format or ANTHROPIC_*.
#
# That boundary is what makes a second runner cheap: sets/codex lands as
# lib/runner_codex.sh implementing the same five functions, and no command
# module changes.
#
# Sourced by bin/aif; not meant to be executed directly.

aif_runner_claude_available() {
  aif_have claude
}

aif_runner_claude_version() {
  claude --version 2>/dev/null | head -1 | tr -d '\r\n'
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
