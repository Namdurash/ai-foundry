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
# What is here is what aif does with claude itself: dispatch one headless
# station for `aif work` (`_station`), run an eval (`_eval`), ask whether the
# runner answers at all and whether the guard hook denies (`_probe`,
# `_guard_probe`), open one interactive session in the foreground for a shift
# (`_session`, `aif start`) — plus reading the envelope the headless ones
# produce. `_start`, which handed the terminal over by exec'ing claude and had
# no caller left, gave way to `_session`, which hands it over and takes it
# back.
#
# Sourced by bin/aif; not meant to be executed directly.

aif_runner_claude_available() {
  aif_have claude
}

aif_runner_claude_version() {
  claude --version 2>/dev/null | head -1 | tr -d '\r\n'
}

# aif_runner_claude_session <cwd> <prompt> <model> <name> <session-id>
#
# One interactive claude session in the foreground, for a person, and back:
# the shift (`aif start`) opens one per unit of work — `/aif-review <ID>`,
# `/aif-ba …` — and reads the board when it ends. Returns claude's exit code,
# which says how claude was stopped, not what the person meant: `/exit`, two
# Ctrl-C and a closed window are all 0; a HUP, a TERM and a kill -9 are 129,
# 143 and 137 (docs/FINDINGS.md #28). The caller has exported the profile's
# environment, so `--model opus` is whatever the profile maps opus to; an
# empty model leaves the flag off — the CLI's own default.
#
# `--session-id` is a fresh uuid the caller made: the transcript is then
# `claude --resume <uuid>` for the person afterwards, where claude's own exit
# hint resumes by `--name`, which fails once two sessions share one; and a
# uuid already used is refused (#28).
#
# Job control around the one child (`set -m`, `set +m` on the line after):
# under it a foreground child gets the terminal, so the person's Ctrl-C
# reaches claude and not the shift, and the terminal comes back to the shift
# when it ends (#27; and #28: `( cd … && exec claude … )` under `set -m`
# behaves as the bare call); left on, the shift's next non-interactive
# command would take the terminal (#24). A subshell, so the `cd` is the
# session's own.
#
# `/dev/tty` on all three of claude's descriptors, not the caller's: claude
# with a stdin that is not a terminal was never probed (#28), and a caller
# inside a `while … done <<EOF` loop — the way this codebase iterates — would
# hand it the here-doc. The test seam (AIF_START_SESSION_CMD, a script run
# with the same five arguments) sits inside the same `set -m` bracket, so a
# harness exercises the real job control, and keeps the caller's descriptors,
# so a harness with no terminal can run it.
aif_runner_claude_session() {
  local rc=0 m
  m=()
  [ -z "$3" ] || m=(--model "$3")
  set -m
  if [ -n "${AIF_START_SESSION_CMD:-}" ]; then
    (cd "$1" && exec "$AIF_START_SESSION_CMD" "$1" "$2" "$3" "$4" "$5") || rc=$?
  else
    (cd "$1" && exec claude "$2" ${m[@]+"${m[@]}"} --name "$4" --session-id "$5" \
      </dev/tty >/dev/tty 2>/dev/tty) || rc=$?
  fi
  set +m
  return "$rc"
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
  # In jq, not `| head -1`: .result is the station's whole final message, the
  # caller assigns this under set -e, and a head that leaves early would end
  # the worker right after "ended with an error" (docs/DEFECTS.md 5.3). An
  # empty message splits to no line at all, which jq printed as `null`
  # (docs/DEFECTS.md 13.7) — said as what it is.
  jq -r 'if .result == null then "no result field"
         elif .result == "" then "an empty final message"
         else (.result | tostring | split("\n")[0] // "") end' "$1" 2>/dev/null
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
# classes the ledger needs — under subscription auth total_cost_usd was 0 and
# is not always now (docs/FINDINGS.md #2, #30), so tokens are what gets
# recorded, and dollars are derived from the project's price table.
#
# The output is stream-json, not json: one JSON line per event, the envelope
# the last of them. The envelope says that a run failed, and in words for a
# person why; whether it met the account's usage limit, and when that resets,
# is only in the stream's rate_limit_event (docs/FINDINGS.md #27, #30), and a
# limit read as a station's failure was billed to the station — retried, the
# same refusal again, the run stopped blocked: run (docs/DEFECTS.md 13.7).
# <out> is the stream; aif_runner_claude_classify reads it into a class and
# the envelope alone, which is what every reader after it reads.
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
#
# <pid-file>, when given: claude's own pid is written there as it starts — a
# `/bin/sh` writes its `$$` and execs claude in its place, so the station is
# still this subshell's process, in the foreground and in the worker's group,
# where a Ctrl-C and a --stop reach it (docs/FINDINGS.md #23). The run lock
# keeps it, for a takeover to find a station whose worker died outright
# (lib/cmd_work.sh _aif_work_dispatch; docs/DEFECTS.md 14.1).
aif_runner_claude_station() {
  local workdir="$1" sys="$2" prompt="$3" model="$4"
  local max_turns="$5" budget="$6" tools="$7" out="$8" err="$9" pidfile="${10:-}"

  # An empty budget is no ceiling, and the flag is then left off entirely —
  # not passed as 0, which claude would read as a ceiling of nothing. The
  # array is expanded as ${a[@]+"${a[@]}"} because bash 3.2 treats an empty
  # one as unset under set -u (docs/FINDINGS.md, bash 3.2).
  local cap pre
  cap=()
  [ -z "$budget" ] || cap=(--max-budget-usd "$budget")
  pre=()
  # shellcheck disable=SC2016  # $$ and "$@" are the wrapper shell's own
  [ -z "$pidfile" ] || pre=(/bin/sh -c 'echo $$ >"$0"; exec "$@"' "$pidfile")

  (
    cd "$workdir" || exit 70
    exec ${pre[@]+"${pre[@]}"} claude -p "$prompt" \
      --append-system-prompt "$(cat "$sys")" \
      --model "$model" \
      --tools "$tools" \
      --output-format stream-json --verbose \
      --max-turns "$max_turns" \
      ${cap[@]+"${cap[@]}"} \
      --permission-mode bypassPermissions \
      --setting-sources project,local \
      >"$out" 2>"$err" </dev/null
  )
}

# aif_runner_claude_classify <stream> <envelope-out> [<facts-out>] — what one
# station run came to, read from its stream: one line on stdout,
# `<class>\t<reset>\t<type>\t<why>`, the run's result object written to
# <envelope-out> (empty when it left none) and, when asked, what the worker
# records of a run that was not ok to <facts-out> (turns, output tokens, the
# last rate_limit_info, the API error's kind). rc 0 always. Only <why> may be
# empty: a TAB in IFS collapses empty fields, and every field after one would
# shift (docs/FINDINGS.md #15).
#
#   ok         the result says is_error false
#   limit      the account's usage limit: the stream's rate_limit_event says
#              rejected and names the limit (rateLimitType) or the credits
#              (errorCode credits_required); <reset> when it resets, in epoch
#              seconds, 0 when it names none; <type> the limit's name
#   transient  the runner did not answer: no result at all (no-envelope —
#              nothing was written; not-json — something that is not the
#              CLI's JSON), the server's throttle, overload, a 5xx, a network
#              error; <type> what said so
#   error      anything else — max turns, an error during execution, a 4xx,
#              authentication, billing: the station's run, which the gate then
#              judges by what it left, as it always did
#
# Decided on fields alone, never on the result's prose: the throttle's own
# words are "Server is temporarily limiting requests (not your usage limit)",
# which a grep reads as the usage limit (docs/FINDINGS.md #27). The fields are
# the ones the CLI writes in stream-json --verbose (docs/FINDINGS.md #30): a
# rate_limit_event at every change of the limit's state, its status rejected
# for any 429 a subscriber gets and a rateLimitType only when that 429 named a
# limit — a rejected event with no type is the server's throttle; the
# API-error assistant line's `error` kind; the result's api_error_status and
# terminal_reason. <why> — the result's first line, its first error, or its
# subtype — is for a person, and decides nothing.
#
# jq reads a stream of JSON values whatever its line breaks, so a real stream
# and the harness's one pretty-printed envelope read alike. A value that is
# not JSON stops that read where it stands; a second read, a line at a time,
# then takes what parses around it, so a warning printed before the stream
# does not cost the result after it.
aif_runner_claude_classify() {
  local stream="$1" env_out="$2" facts_out="${3:-}" kept keep empty=1 first="" line
  # shellcheck disable=SC2016  # jq's own syntax
  keep='objects | select(.type == "result" or .type == "rate_limit_event"
          or (.type == "assistant" and .is_api_error_message == true))
        | if .type == "assistant" then { type, error } else . end'
  : >"$env_out" 2>/dev/null || true
  [ -z "$facts_out" ] || : >"$facts_out" 2>/dev/null || true
  if ! kept="$(mktemp "${TMPDIR:-/tmp}/aif-kept-XXXXXX")"; then
    printf 'transient\t0\tnot-json\tthe stream could not be read here\n'
    return 0
  fi
  if [ -s "$stream" ]; then
    empty=0
    jq -c "$keep" "$stream" >"$kept" 2>/dev/null || true
    if ! jq -e -s 'any(.[]; .type == "result")' "$kept" >/dev/null 2>&1; then
      jq -R -c "fromjson? | $keep" "$stream" >"$kept" 2>/dev/null || true
    fi
    first="$(grep -m 1 -v '^[[:space:]]*$' "$stream" 2>/dev/null | cut -c1-200 | tr '\t' ' ')" || first=""
  fi
  jq -c -s '[ .[] | select(.type == "result") ] | last // empty' "$kept" >"$env_out" 2>/dev/null ||
    : >"$env_out" 2>/dev/null || true
  # `oneline` is total, and the why takes the first of its sources that says
  # something: an empty string splits to no lines at all, and `""` read as a
  # first line was null, which gsub cannot take — the whole read failed, and
  # a station that worked and ended on an empty final message, `"result":
  # ""`, was read as transient not-json: dispatched again after a backoff,
  # three times, then blocked: environment (docs/DEFECTS.md 13.7; an error
  # with an empty result the same, its class never read). The class is
  # decided on the fields, as it always was; an empty why is allowed.
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  line="$(jq -r -s --argjson empty "$empty" --arg first "$first" '
    def num: if type == "number" and . > 0
             then (if . > 100000000000 then . / 1000 else . end) | floor else 0 end;
    def oneline: tostring | (split("\n")[0] // "") | gsub("\t"; " ") | .[0:300];
    def said: select(. != null and . != "");
    ([ .[] | select(.type == "result") ] | last) as $e
    | ([ .[] | select(.type == "rate_limit_event") | .rate_limit_info ] | last) as $r
    | ([ .[] | select(.type == "assistant") | .error | select(. != null) ] | last) as $a
    | ($e.api_error_status // null) as $st
    | (($r.rateLimitType // "") | if type == "string" then . else "" end) as $rt
    | (if $e == null then ""
       else ((first(($e.result | said), (($e.errors // []) | arrays | .[0] | said), ($e.subtype | said)) // "")
             | oneline) end) as $why
    | (if $e == null then
         [ "transient", 0, (if $empty == 1 then "no-envelope" else "not-json" end), (if $empty == 1 then "" else $first end) ]
       elif $e.is_error == false then [ "ok", 0, "-", $why ]
       elif ($st == 429 or ($st == null and $e.terminal_reason == "api_error"))
            and ($r.status // "") == "rejected"
            and ($rt != "" or ($r.errorCode // "") == "credits_required") then
         [ "limit",
           ((if $rt == "overage" then ($r.overageResetsAt // $r.resetsAt) else $r.resetsAt end) | num),
           (if $rt != "" then $rt else $r.errorCode end), $why ]
       elif $a == "rate_limit" or $a == "server_error" or $a == "overloaded" then
         [ "transient", 0, ($a + (if $st == null then "" else "-\($st)" end)), $why ]
       elif $a == null
            and ((($st | type) == "number" and any([408, 429, 500, 502, 503, 504, 529][]; . == $st))
                 or ($st == null and $e.terminal_reason == "api_error")) then
         [ "transient", 0, (if $st == null then "api_error" else "api-\($st)" end), $why ]
       else [ "error", 0, ($e.subtype // "error" | tostring), $why ] end)
    | map(tostring | gsub("[\t\n]"; " ")) | join("\t")' "$kept" 2>/dev/null)" || line=""
  if [ -n "$facts_out" ]; then
    jq -c -s '([ .[] | select(.type == "result") ] | last) as $e
      | { num_turns: ($e.num_turns // 0), output_tokens: ($e.usage.output_tokens // 0),
          api_error_status: ($e.api_error_status // null), terminal_reason: ($e.terminal_reason // null),
          rate_limit: ([ .[] | select(.type == "rate_limit_event") | .rate_limit_info ] | last),
          api_error: ([ .[] | select(.type == "assistant") | .error | select(. != null) ] | last) }' \
      "$kept" >"$facts_out" 2>/dev/null || printf '{}\n' >"$facts_out" 2>/dev/null || true
  fi
  rm -f "$kept"
  [ -n "$line" ] || line="$(printf 'transient\t0\tnot-json\t%s' "$first")"
  printf '%s\n' "$line"
  return 0
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
  err="$(printf '%s' "$out" | jq -r '(.result // empty) | (split("\n")[0] // "")' 2>/dev/null)"
  [ -n "$err" ] || err="$(printf '%s' "$out" | sed -n 1p)"

  # An authentication failure inside a Claude Code session is the one result
  # this probe cannot be trusted on. docs/FINDINGS.md #7 was written as a law
  # from exactly this observation, and the law was false: the session exports
  # its own credentials into every child, so what failed may be the nesting
  # rather than the machine. Say so, instead of letting a confounded probe
  # send someone to debug an authentication that works fine one shell out.
  case "$err" in
    *authenticat* | *Authenticat* | *401*)
      if [ "${CLAUDECODE:-}" = "1" ]; then
        # shellcheck disable=SC2016  # backticks are prose here, not substitution
        printf '%s — but this ran INSIDE a Claude Code session, where a nested run is confounded (FINDINGS #7). Run `aif doctor --probe` from your own terminal before believing it' "$err"
      else
        # shellcheck disable=SC2016  # backticks are prose here, not substitution
        # Not nested, so the credential really is the problem, and the fix is
        # one command in the shell the user is already in. Saying only what
        # failed leaves them to guess that the CLI has its own stored session,
        # separate from whatever app they were just talking to.
        printf '%s — sign the CLI in again: run `claude` in this shell (then /login if it does not ask)' "$err"
      fi
      return 1
      ;;
  esac
  printf '%s' "$err"
  return 1
}

# aif_runner_claude_guard_probe <root> — does the station guard DENY a command
# in a spawned run here?
#
# The tests station's Bash exists for one command, `aif _verify`, and the
# guard hook is what holds it to that. A hook is fail-open by nature: one that
# does not fire looks exactly like one that allowed everything, and the
# station would then have the shell. So the worker grants the tool only once
# this probe has watched the hook deny something — the rule every other
# readiness check here follows (docs/FINDINGS.md #14): ask the question the
# answer will be read as answering.
#
# One run, Bash only, as the tests station: AIF_STATION=tests in the
# environment, the project's settings loaded, bypassPermissions as the worker
# dispatches. The prompt asks for a command the guard refuses and asks the
# model to quote the refusal. Probed 2026-10-01: the hook fires under
# bypassPermissions and the denial reaches the model (docs/FINDINGS.md #21).
# rc 0 the hook denied, and the marker is written · 1 it did not, with why.
aif_runner_claude_guard_probe() {
  local root="$1" out rc=0 err errfile marker
  errfile="$(mktemp "${TMPDIR:-/tmp}/aif-probe-XXXXXX")"
  [ -f "$root/.claude/settings.json" ] || {
    rm -f "$errfile"
    printf 'no .claude/settings.json here — the guard hook is not registered (aif init)'
    return 1
  }
  out="$(cd "$root" && AIF_STATION=tests claude -p 'Run exactly this with the Bash tool: echo AIF_GUARD_PROBE. If the tool call is denied, reply with the word DENIED and the reason, verbatim. If it ran, reply with the word RAN and its output.' \
    --output-format json \
    --max-turns 3 \
    --tools Bash \
    --no-session-persistence \
    --permission-mode bypassPermissions \
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
  if ! printf '%s' "$out" | jq -e '.is_error == false' >/dev/null 2>&1; then
    printf '%s' "$(printf '%s' "$out" | jq -r '(.result // "the run failed") | (split("\n")[0] // "the run failed")' 2>/dev/null)"
    return 1
  fi
  if printf '%s' "$out" | jq -r '.result // ""' | grep -q 'aif _verify'; then
    marker="$root/.aif/state/guard-probed"
    mkdir -p "$(dirname "$marker")"
    aif_runner_version claude >"$marker"
    printf 'the guard denied a command in a spawned run (claude %s)' "$(cat "$marker")"
    return 0
  fi
  printf 'a spawned run with Bash was NOT denied by the guard — the hook did not fire, or did not reach the model: %s' \
    "$(printf '%s' "$out" | jq -r '(.result // "") | (split("\n")[0] // "") | .[0:160]' 2>/dev/null)"
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
