#!/usr/bin/env bash
#
# `aif work <ticket>` — the worker: one ticket, one worktree, one budget, no
# questions. Sourced by bin/aif; not meant to be executed directly.
#
# This is the machine half of the foundry (docs/REBUILD-3.md §3). The human
# half — the product conversation, the analyst, the board — happens in ordinary
# sessions, in the human's own time. What crosses the boundary is a ticket that
# is READY, and what comes back is a branch and a report. Nothing in between
# asks anybody anything: a question the worker cannot answer from the ticket
# and the repository is, by definition, the failure mode, and it is reported as
# one rather than waited on.
#
# Shape:
#
#   preflight   profile, runner, toolchain — before the first token (cmd_run.sh
#               learned this at ~$6.61 on a live ticket)
#   worktree    git worktree add .aif/worktrees/<ID> -b aif/<ID>. A disposable
#               checkout of its own: nothing a station writes reaches the
#               developer's tree until they merge the branch, which is what
#               makes bypassPermissions safe for the stations (runner_claude.sh)
#   intake      the ticket's bytes are hashed and committed. From here the
#               inputs are FROZEN for the run's lifetime — a ticket edited on
#               the board mid-run changes nothing here, and the report says
#               which bytes were built. That one rule is what lets the
#               backward-lapsing hash cascade of earlier sets be deleted
#   loop        `aif _state` says what is next (bash decides) — the ready gate
#               first, then the stations; the worker
#               dispatches the station as `claude -p` with the station's own
#               prompt (model dispatches); `aif _gate` judges the output and
#               records the verdict; `aif _commit` seals the accepted step.
#               A rejection is a RETRY with the gate's complaint in the prompt,
#               up to limits.attempts_max — never a conversation
#   report      tasks/<ID>/report.md: what was built, what was decided, what
#               was not verified, what it cost. The human reviews this next to
#               the diff, which is the one place they have enough context to
#
# Every station is metered from its own envelope (runner_claude.sh) and staged
# for `aif _gate` to fold, exactly like the SubagentStop hook's rows: a ledger
# write between commits would appear in scope's diff as the implementation
# editing the pipeline's own record.
#
# Exit: 0 built · 1 stopped, needs a human (the report says why) · 3 the
# environment cannot run a ticket at all (nothing was spent).

AIF_WORK_WORKTREES=".aif/worktrees"

_aif_work_usage() {
  cat <<EOF
usage: aif work <ticket> [options]

  Build one ticket, headless, on its own branch. Never asks a question: a
  ticket the worker cannot build from what it was given comes back with a
  report saying what was missing.

    aif work OPES-52            build it in .aif/worktrees/OPES-52 on aif/OPES-52
    aif work OPES-52 --clean    remove that worktree (the branch stays)

  --profile P        which (set, runner, model) profile; default: the project's
  --budget USD       stop past this spend (best-effort — under subscription
                     auth the runner reports \$0; tokens are always recorded)
  --max-minutes N    stop past this wall clock (default limits.run_max_minutes, 120)
  --no-worktree      run in the current checkout instead of a worktree. Only
                     for a checkout that is already disposable (CI, a test)
  --clean            remove the ticket's worktree and stop

The worker is the whole dev pipeline. There is no command per stage, and there
is no question at any stage; see docs/REBUILD-3.md.
EOF
}

# _aif_work_say <label> <text> — one dim status line on stderr.
_aif_work_say() {
  printf '%s%-9s%s %s\n' "$AIF_C_DIM" "$1" "$AIF_C_RESET" "$2" >&2
}

# _aif_work_preflight <root> <profile> — load and export the profile, and refuse
# to start on a project whose gates could not render a verdict. Everything here
# runs before the worktree exists, because none of it depends on the ticket and
# all of it is cheaper than the first station.
_aif_work_preflight() {
  local root="$1" profile="$2"
  local project problems

  project="$(aif_project_config "$root")"
  [ -f "$project" ] || aif_die "no .aif/project.json — run 'aif project init'"
  problems="$(aif_project_validate "$project")"
  if [ -n "$problems" ]; then
    aif_err "project.json has problems — the gates read it, so fix these first:"
    printf '%s\n' "$problems" | sed 's/^/  - /' >&2
    exit 3
  fi

  [ -f "$root/.claude/agents/aif-implement.md" ] ||
    aif_die "the stations are not installed — run 'aif init'"

  aif_profile_load "$profile"
  # shellcheck source=lib/runner_claude.sh
  . "$AIF_ROOT/lib/runner_claude.sh"
  if [ -z "${AIF_WORK_STATION_CMD:-}" ]; then
    "aif_runner_${AIF_PROFILE_RUNNER}_available" ||
      aif_die "runner '$AIF_PROFILE_RUNNER' is not installed"
    if [ -n "$AIF_PROFILE_SECRET_VAR" ] && [ -z "$(aif_profile_secret)" ]; then
      aif_die "$AIF_PROFILE_SECRET_VAR is not set — export it to use profile '$profile'"
    fi
  fi

  # shellcheck source=lib/doctor.sh
  . "$AIF_ROOT/lib/doctor.sh"
  if ! aif_doctor_probe "$root" >/dev/null 2>&1; then
    aif_doctor_probe "$root" >&2 || true
    aif_err "the test toolchain cannot produce a verdict — every gate reads that report."
    exit 3
  fi

  aif_profile_export_env
  if [ "${AIF_PROFILE_ISOLATE_CONFIG:-0}" = "1" ]; then
    CLAUDE_CONFIG_DIR="$(aif_runner_config_dir "$profile")"
    export CLAUDE_CONFIG_DIR
    mkdir -p "$CLAUDE_CONFIG_DIR"
  fi
}

# _aif_work_worktree <root> <ticket> — the checkout this run happens in, echoed.
#
# Created on first use, reused on a resume. The branch is aif/<ticket>; a branch
# that already exists (an earlier run, a review in progress) is checked out
# rather than recreated, so a second `aif work` on the same ticket continues
# where the first stopped — `aif _state` derives where that is.
_aif_work_worktree() {
  local root="$1" ticket="$2"
  local wt branch
  wt="$root/$AIF_WORK_WORKTREES/$ticket"
  branch="aif/$ticket"

  if [ -d "$wt/.git" ] || [ -f "$wt/.git" ]; then
    printf '%s' "$wt"
    return 0
  fi

  # shellcheck source=lib/merge.sh
  . "$AIF_ROOT/lib/merge.sh"
  aif_gitignore_ensure "$root" "$AIF_WORK_WORKTREES/" "worker checkouts — one per ticket, disposable"

  mkdir -p "$(dirname "$wt")"
  if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$root" worktree add -q "$wt" "$branch" >/dev/null 2>&1 ||
      aif_die "could not check out $branch into $wt"
  else
    git -C "$root" worktree add -q -b "$branch" "$wt" >/dev/null 2>&1 ||
      aif_die "could not create worktree $wt on $branch"
  fi
  printf '%s' "$wt"
}

# _aif_work_intake <root> <wt> <ticket> — freeze the ticket into the run.
#
# The ticket may sit uncommitted in the developer's tree (the analyst wrote it
# a minute ago); a worktree checks out commits, so it would not be there. Copy
# it over, hash it, commit it. From this point the run reads only the worktree.
_aif_work_intake() {
  local root="$1" wt="$2" ticket="$3"
  local work src base

  work="$(aif_task_dir "$wt" "$ticket")"
  src="$(aif_task_dir "$root" "$ticket")"

  if [ ! -f "$work/ticket.md" ] && [ -f "$src/ticket.md" ] && [ "$src" != "$work" ]; then
    mkdir -p "$work"
    cp -R "$src/." "$work/"
  fi
  [ -f "$work/ticket.md" ] || {
    aif_err "no ticket: $AIF_TASKS_DIR/$ticket/ticket.md does not exist."
    aif_err "The worker builds tickets; it does not write them. Write one with /aif-ba, then run this again."
    return 1
  }
  if grep -q "Describe the need in your own words" "$work/ticket.md" 2>/dev/null; then
    aif_err "the ticket is still the scaffold stub — nothing to build."
    return 1
  fi
  [ -f "$(aif_ledger_path "$work")" ] || aif_ledger_init "$work" "$ticket"

  # The Definition of Ready, recorded. The same gate the analyst ran; its
  # verdict is bound to the ticket's bytes at intake, so the ledger says what
  # was judged buildable rather than only that a build was attempted. A
  # refusal is not handled here: the loop asks `_state`, which runs the same
  # gate and hands back every line of its complaint for the report.
  local rc=0 out
  out="$(aif_gate_run "$wt" ready "$work")" || rc=$?
  [ "$rc" -ne 127 ] || aif_die "the ready gate is not installed in this project — run 'aif init'"
  aif_ledger_gate "$work" ready "$([ "$rc" -eq 0 ] && printf pass || printf fail)" \
    ticket.md "$(aif_sha256 "$work/ticket.md")" "$(aif_sha256 "$(aif_gate_path "$wt" ready)")" \
    "$(printf '%s' "$out" | head -1)"

  base="$(git -C "$wt" rev-parse HEAD 2>/dev/null || printf 'none')"
  jq -n --arg t "$ticket" --arg sha "$(aif_sha256 "$work/ticket.md")" \
    --arg br "$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '?')" \
    --arg base "$base" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg wt "${wt#"$root"/}" \
    '{ schema: 1, ticket: $t, ticket_sha256: $sha, branch: $br, base: $base,
       worktree: $wt, started_at: $at, status: "running", dispatches: 0,
       finished_at: null, why: null }' >"$work/run.json.tmp" &&
    mv "$work/run.json.tmp" "$work/run.json"

  git -C "$wt" add -A "$AIF_TASKS_DIR/$ticket" >/dev/null 2>&1 || true
  if ! git -C "$wt" diff --cached --quiet 2>/dev/null; then
    git -C "$wt" -c user.email="aif@local" -c user.name="aif" \
      commit -q -m "aif: intake $ticket" >/dev/null 2>&1 || true
  fi
  return 0
}

# _aif_work_frontmatter <wt> <agent> <key> — a scalar from the agent's YAML
# frontmatter. Flat key: value only, which is all the set writes.
_aif_work_frontmatter() {
  awk -v key="$3" '
    NR == 1 && $0 == "---" { inblock = 1; next }
    inblock && $0 == "---" { exit }
    inblock && index($0, key ":") == 1 { sub(/^[^:]*:[ \t]*/, ""); print; exit }
  ' "$1/.claude/agents/$2.md"
}

# _aif_work_dispatch <wt> <ticket> <station> <agent> <bindings-json> <complaint>
#                    <budget-left> <envelope-out>
#
# One station run. Writes the envelope to <envelope-out>, stages the cost row
# for `aif _gate` to fold, and returns 0 when the runner produced an envelope
# at all — the outcome of the station is read from the envelope by the caller,
# because a failed station is a recorded attempt, not an aborted one.
#
# AIF_WORK_STATION_CMD is the offline seam: when set, that command runs in
# place of the runner with the same arguments the runner would get, plus the
# station and ticket first. scripts/check-work.sh drives the whole worker
# through it with hand-written artifacts, the way demo.sh drives the gates.
_aif_work_dispatch() {
  local wt="$1" ticket="$2" station="$3" agent="$4" bindings="$5" complaint="$6"
  local budget_left="$7" out="$8"
  local project sys prompt model tools max_turns err rc=0
  project="$(aif_project_config "$wt")"

  model="$(_aif_work_frontmatter "$wt" "$agent" model)"
  tools="$(_aif_work_frontmatter "$wt" "$agent" tools | tr -d ' ')"
  max_turns="$(jq -r '.limits.station_max_turns // 30' "$project" 2>/dev/null)"
  [ -n "$model" ] || model="sonnet"
  [ -n "$tools" ] || tools="Read,Grep,Glob,Write,Edit"

  prompt="Ticket $ticket. Your working directory is the project root. Follow your instructions exactly: read the inputs they name under $AIF_TASKS_DIR/$ticket/ and produce what they specify, nothing else. Nobody will answer a question — decide from the ticket and the repository, and record what you decided in the fields your instructions provide for it."
  if [ -n "$bindings" ] && [ "$bindings" != "{}" ]; then
    prompt="$prompt

Record these values exactly as given, in the fields named (do not compute or alter them):
$(printf '%s' "$bindings" | jq -r 'to_entries[] | "  " + .key + ": " + .value')"
  fi
  if [ -n "$complaint" ]; then
    prompt="$prompt

The previous attempt was REJECTED. The gate's complaints, verbatim — fix exactly these, and change nothing that was not complained about:
$complaint"
  fi

  sys="$(mktemp "${TMPDIR:-/tmp}/aif-sys-XXXXXX")"
  err="$(mktemp "${TMPDIR:-/tmp}/aif-err-XXXXXX")"
  aif_meta_body "$wt/.claude/agents/$agent.md" >"$sys"

  # The guard hook reads these: inside a run the station may write only what
  # its station owns (guard.sh, the AIF_STATION route), and the session may not
  # write product code at all (AIF_RUN).
  export AIF_STATION="$station" AIF_RUN=1

  _aif_work_say "station" "$station · $agent · $model · ≤$max_turns turns"
  if [ -n "${AIF_WORK_STATION_CMD:-}" ]; then
    "$AIF_WORK_STATION_CMD" "$station" "$ticket" "$wt" "$sys" "$prompt" "$model" \
      "$max_turns" "$budget_left" "$tools" "$out" "$err" || rc=$?
  else
    "aif_runner_${AIF_PROFILE_RUNNER}_station" "$wt" "$sys" "$prompt" "$model" \
      "$max_turns" "$budget_left" "$tools" "$out" "$err" || rc=$?
  fi
  unset AIF_STATION
  rm -f "$sys"

  if [ ! -s "$out" ]; then
    aif_err "the runner produced no envelope for $station — $(head -1 "$err" 2>/dev/null)"
    rm -f "$err"
    return 3
  fi
  rm -f "$err"

  # Stage the cost row. Same shape as the SubagentStop hook's, plus
  # mode: "headless" so a reader can tell which route metered it, and subtype,
  # recorded and never branched on (docs/FINDINGS.md #2).
  local usage turns cost summary subtype model_ran result
  usage="$("aif_runner_${AIF_PROFILE_RUNNER}_result_usage" "$out")"
  turns="$(jq -r '.num_turns // 0' "$out")"
  subtype="$("aif_runner_${AIF_PROFILE_RUNNER}_result_subtype" "$out")"
  summary="$(jq -r '.result // ""' "$out" | head -1 | cut -c1-200)"
  model_ran="$(jq -r '.modelUsage // {} | keys | join(",")' "$out" 2>/dev/null)"
  [ -n "$model_ran" ] || model_ran="$model"
  cost="$(_aif_meter_cost "$wt/.aif/prices.json" "$model_ran" "$usage")"
  result=error
  "aif_runner_${AIF_PROFILE_RUNNER}_result_ok" "$out" && result=ran
  _aif_meter_stage "$wt" "$ticket" "$(jq -n \
    --arg s "$station" --arg ag "$agent" --arg m "$model_ran" \
    --argjson u "$usage" --argjson t "$turns" --argjson c "$cost" \
    --arg sub "$subtype" --arg sum "$summary" --arg ok "$result" \
    '{ station: $s, agent: $ag, model: $m, mode: "headless",
       usage: $u, num_turns: $t, cost_usd: $c,
       cost_source: (if $c == null then "tokens-only" else "priced" end),
       subtype: $sub, result: $ok, summary: $sum }')"
  return 0
}

# _aif_work_report <root> <wt> <ticket> <status> <why> <started> <dispatches>
#
# The artifact the human reviews. Everything in it is read from files the run
# wrote — the ledger, the plan, the state walk — never narrated. Written to
# tasks/<ID>/report.md and committed, so it travels with the branch; also
# printed, because the terminal that launched the worker is where the
# developer looks first.
_aif_work_report() {
  local root="$1" wt="$2" ticket="$3" status="$4" why="$5" started="$6" dispatches="$7"
  local work ledger run state report base diffstat="" mins
  work="$(aif_task_dir "$wt" "$ticket")"
  ledger="$(aif_ledger_path "$work")"
  run="$work/run.json"
  report="$work/report.md"

  # Fold anything still staged (a station that ran but whose gate never got to
  # run, e.g. on a runner error) so the report and the ledger agree.
  _aif_gate_record_meter "$wt" "$work" 2>/dev/null || true

  state="$("$AIF_ROOT/bin/aif" _state "$ticket" 2>/dev/null || printf '{}')"
  base="$(jq -r '.base // "none"' "$run" 2>/dev/null)"
  if [ "$base" != "none" ]; then
    diffstat="$(git -C "$wt" diff --shortstat "$base" HEAD -- . ":(exclude)$AIF_TASKS_DIR" 2>/dev/null | sed 's/^ *//')"
  fi
  [ -n "$diffstat" ] || diffstat="no code changed"
  mins=$((($(date +%s) - started) / 60))

  jq --arg st "$status" --arg why "$why" --argjson d "$dispatches" \
    --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '.status = $st | .why = (if $why == "" then null else $why end)
     | .dispatches = $d | .finished_at = $at' "$run" >"$run.tmp" && mv "$run.tmp" "$run"

  # Everything written here is markdown: the backticks are code spans, not
  # command substitution, and the single quotes are what keeps them that way.
  # shellcheck disable=SC2016
  {
    printf '# %s — %s\n\n' "$ticket" "$status"
    printf -- '- branch `%s` · %s · %s min · %s dispatch(es)\n' \
      "$(jq -r '.branch' "$run")" "$diffstat" "$mins" "$dispatches"
    printf -- '- built against `ticket.md` sha256 `%s`\n' "$(jq -r '.ticket_sha256' "$run")"
    if [ -f "$work/ticket.md" ] && [ "$(aif_sha256 "$work/ticket.md")" != "$(jq -r '.ticket_sha256' "$run")" ]; then
      printf -- '- **the ticket changed after intake** — this run built the bytes above, not the current file\n'
    fi
    if [ -n "$why" ]; then
      printf '\n## Why it stopped\n\n%s\n' "$why"
    fi

    printf '\n## Stations\n\n'
    printf '| station | attempts | turns | output tokens | cost |\n|---|---|---|---|---|\n'
    jq -r '
      [ .entries[] | select(.station != null) ] as $rows
      | ( $rows | map(.station) | reduce .[] as $x ([]; if index($x) == null then . + [$x] else . end) ) as $names
      | $names[] as $n
      | ( $rows | map(select(.station == $n)) ) as $g
      | "| " + $n + " | " + ($g | length | tostring) + " | "
        + ($g | map(.num_turns // 0) | add | tostring) + " | "
        + ($g | map(.usage.output_tokens // 0) | add | tostring) + " | "
        + ( ($g | map(.cost_usd // empty) | add) as $c
            | if $c == null then "tokens only" else "$" + ($c | tostring) end ) + " |"
    ' "$ledger" 2>/dev/null
    printf '\n_Costs are derived from `.aif/prices.json`; a model missing there prints "tokens only". Tokens are always recorded._\n'

    if [ -f "$work/plan.md" ]; then
      printf '\n## Decisions the plan made\n\n'
      aif_meta_json "$work/plan.md" | jq -r '
        .decisions[]? | "- **" + .id + "** " + .statement
          + "\n  - because: " + (.because // "—")
          + (if ((.rejected // "") | length) > 0 then "\n  - rather than: " + .rejected else "" end)' 2>/dev/null
    fi
    printf '\n## Decided with the analyst\n\n'
    aif_meta_json "$work/ticket.md" | jq -r '
      (.decided // []) | if length == 0 then "- nothing was left open" else
      .[] | "- " + (if .by == "default" then "**by default, not by the human:** " else "" end)
        + .question + " → " + .answer
        + (if (.kind // "") == "architecture" then " _(architecture)_" else "" end) end' 2>/dev/null

    printf '\n## Not verified by this run\n\n'
    printf '%s' "$state" | jq -r '
      (.next.checklist // []) | if length == 0
        then "- nothing recorded — every criterion was exercised, and the plan named no unvalidated dependency"
        else .[] | "- [ ] **" + .source + " " + .id + "** " + .text end' 2>/dev/null
    printf '\n## Steps\n\n'
    printf '%s' "$state" | jq -r '.steps[]? | "- " + .step + ": " + .state + (if .detail != "" then " — " + .detail else "" end)' 2>/dev/null
    printf '\n---\n_Written by `aif work`. Review the diff on the branch; merge when it is what you meant, or send the ticket back through the analyst with what was wrong._\n'
  } >"$report.tmp" && mv "$report.tmp" "$report"

  git -C "$wt" add -A "$AIF_TASKS_DIR/$ticket" >/dev/null 2>&1 || true
  if ! git -C "$wt" diff --cached --quiet 2>/dev/null; then
    git -C "$wt" -c user.email="aif@local" -c user.name="aif" \
      commit -q -m "aif: report $ticket ($status)" >/dev/null 2>&1 || true
  fi

  printf '\n'
  cat "$report"
  printf '\n%s%s%s\n' "$AIF_C_DIM" "${report#"$root"/}" "$AIF_C_RESET"
}

aif_cmd_work() {
  local ticket="" profile="" budget="" max_minutes="" use_worktree=1 clean=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --profile)
        shift
        profile="${1:-}"
        ;;
      --budget)
        shift
        budget="${1:-}"
        ;;
      --max-minutes)
        shift
        max_minutes="${1:-}"
        ;;
      --no-worktree) use_worktree=0 ;;
      --clean) clean=1 ;;
      -h | --help)
        _aif_work_usage
        return 0
        ;;
      -*) aif_die "unknown option: $1" ;;
      *) ticket="$1" ;;
    esac
    shift
  done

  local root
  root="$(aif_require_project)"
  [ -n "$ticket" ] || {
    _aif_work_usage >&2
    aif_die "usage: aif work <ticket>"
  }

  if [ "$clean" -eq 1 ]; then
    local wt="$root/$AIF_WORK_WORKTREES/$ticket"
    [ -e "$wt" ] || aif_die "no worktree for $ticket at ${wt#"$root"/}"
    git -C "$root" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
    git -C "$root" worktree prune >/dev/null 2>&1 || true
    printf '%sremoved%s %s — branch aif/%s is untouched\n' "$AIF_C_GREEN" "$AIF_C_RESET" "${wt#"$root"/}" "$ticket"
    return 0
  fi

  if [ -z "$profile" ]; then
    if [ -f "$root/$AIF_PROFILE_STATE" ]; then
      profile="$(cat "$root/$AIF_PROFILE_STATE")"
    else
      aif_die "no profile — run 'aif init' or pass --profile"
    fi
  fi

  _aif_work_preflight "$root" "$profile"

  local wt
  if [ "$use_worktree" -eq 1 ]; then
    wt="$(_aif_work_worktree "$root" "$ticket")"
  else
    wt="$root"
  fi
  _aif_work_say "worktree" "${wt#"$root"/}"

  _aif_work_intake "$root" "$wt" "$ticket" || exit 1

  local project attempts_max run_max dispatches_max started
  project="$(aif_project_config "$wt")"
  attempts_max="$(jq -r '.limits.attempts_max // 3' "$project")"
  dispatches_max="$(jq -r '.limits.run_dispatches_max // 21' "$project")"
  [ -n "$max_minutes" ] || max_minutes="$(jq -r '.limits.run_max_minutes // 120' "$project")"
  [ -n "$budget" ] || budget="$(jq -r '.limits.run_budget_usd // 20' "$project")"
  run_max=$((max_minutes * 60))
  started="$(date +%s)"

  printf '\n%swork%s %s · profile %s · budget $%s · ≤%s min\n\n' \
    "$AIF_C_BOLD" "$AIF_C_RESET" "$ticket" "$profile" "$budget" "$max_minutes" >&2

  # The loop. `_state` is asked before every step and obeyed; the worker keeps
  # only two things of its own — how many times it has dispatched the station
  # it is on, and how much it has spent.
  local state kind step agent bindings expects detail
  local cur_station="" cur_attempts=0 complaint="" dispatches=0 spent=0
  local out rc status="" why="" gate_out
  cd "$wt" || aif_die "cannot enter $wt"
  mkdir -p "$wt/.aif/tmp"
  gate_out="$wt/.aif/tmp/gate-$ticket.out"

  while :; do
    if [ $(($(date +%s) - started)) -gt "$run_max" ]; then
      status="stopped"
      why="wall clock: past $max_minutes minutes. What was accepted is committed on the branch; nothing after it is."
      break
    fi
    if [ "$dispatches" -ge "$dispatches_max" ]; then
      status="stopped"
      why="dispatch cap: $dispatches_max station runs (limits.run_dispatches_max). The run is grinding, not converging — the ticket probably does not say enough."
      break
    fi

    state="$("$AIF_ROOT/bin/aif" _state "$ticket" 2>/dev/null)" || {
      status="stopped"
      why="aif _state could not derive the ticket's state."
      break
    }
    kind="$(printf '%s' "$state" | jq -r '.next.kind')"
    step="$(printf '%s' "$state" | jq -r '.next.step // ""')"
    detail="$(printf '%s' "$state" | jq -r '.next.detail // ""')"

    case "$kind" in
      done)
        status="built"
        break
        ;;
      station)
        agent="$(printf '%s' "$state" | jq -r '.next.agent')"
        bindings="$(printf '%s' "$state" | jq -c '.next.bindings // {}')"
        expects="$(printf '%s' "$state" | jq -r '.next.expects // ""')"

        if [ "$step" != "$cur_station" ]; then
          cur_station="$step"
          cur_attempts=0
          complaint=""
        fi
        if [ "$cur_attempts" -ge "$attempts_max" ]; then
          status="stopped"
          why="$step was rejected $cur_attempts time(s) in a row (limits.attempts_max). Last complaint:
$complaint"
          break
        fi
        cur_attempts=$((cur_attempts + 1))
        dispatches=$((dispatches + 1))
        [ -z "$expects" ] || _aif_work_say "expects" "$expects"

        out="$(mktemp "${TMPDIR:-/tmp}/aif-env-XXXXXX")"
        rc=0
        _aif_work_dispatch "$wt" "$ticket" "$step" "$agent" "$bindings" "$complaint" \
          "$(awk -v b="$budget" -v s="$spent" 'BEGIN { r = b - s; if (r < 0.01) r = 0.01; printf "%.2f", r }')" \
          "$out" || rc=$?
        if [ "$rc" -eq 3 ]; then
          rm -f "$out"
          status="stopped"
          why="the runner could not run the $step station (no envelope) — the environment, not the ticket."
          break
        fi
        spent="$(awk -v s="$spent" -v c="$(jq -r '.total_cost_usd // 0' "$out")" 'BEGIN { printf "%.4f", s + c }')"
        if ! "aif_runner_${AIF_PROFILE_RUNNER}_result_ok" "$out"; then
          _aif_work_say "station" "$step ended with an error: $("aif_runner_${AIF_PROFILE_RUNNER}_result_error" "$out")"
        fi
        rm -f "$out"

        if awk -v s="$spent" -v b="$budget" 'BEGIN { exit !(s > b) }'; then
          status="stopped"
          why="budget: spent \$$spent of \$$budget (as reported by the runner)."
          break
        fi

        rc=0
        "$AIF_ROOT/bin/aif" _gate "$step" "$ticket" >"$gate_out" 2>&1 || rc=$?
        case "$rc" in
          0)
            _aif_work_say "gate" "$step admitted — $(grep -m1 '✓' "$gate_out" | sed 's/.*✓ //')"
            "$AIF_ROOT/bin/aif" _commit "$step" "$ticket" >/dev/null 2>&1 || true
            complaint=""
            ;;
          1)
            complaint="$(grep -v '^$' "$gate_out" | sed 's/\x1b\[[0-9;]*m//g' | head -40)"
            _aif_work_say "gate" "$step rejected (attempt $cur_attempts/$attempts_max) — retrying with the complaint"
            ;;
          3)
            status="stopped"
            why="a gate could not render a verdict on $step — the environment, not the ticket:
$(sed 's/\x1b\[[0-9;]*m//g' "$gate_out" | head -20)"
            break
            ;;
          4)
            status="stopped"
            why="$step rewrote nothing since its last rejection — the same verdict would repeat. The station is not getting what it needs from the ticket."
            break
            ;;
          *)
            status="stopped"
            why="aif _gate $step exited $rc:
$(head -20 "$gate_out")"
            break
            ;;
        esac
        ;;
      not-ready)
        # The Definition of Ready refused the ticket. Every line of the gate's
        # output is a question for the analyst's conversation — the worker
        # reports them verbatim and does not guess at one.
        status="stopped"
        why="the ticket is not ready — it goes back to the analyst (/aif-ba):
$detail"
        break
        ;;
      human)
        status="stopped"
        why="the ticket needs a person before it can be built: $detail"
        break
        ;;
      migrate | ticket-init)
        status="stopped"
        why="$detail"
        break
        ;;
      blocked)
        status="stopped"
        why="a gate is broken, not the ticket: $detail"
        break
        ;;
      *)
        status="stopped"
        why="aif _state returned an unknown next.kind: $kind"
        break
        ;;
    esac
  done
  rm -f "$gate_out"

  _aif_work_report "$root" "$wt" "$ticket" "$status" "$why" "$started" "$dispatches"
  [ "$status" = "built" ]
}
