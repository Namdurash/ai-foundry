#!/usr/bin/env bash
#
# `aif _meter` — record what a station's subagent cost. Reads a SubagentStop hook
# payload on stdin. Sourced by bin/aif; not meant to be executed directly.
#
# This is the accounting, and it replaces reading `total_cost_usd` off a
# `claude -p` envelope. The replacement is better in three ways that matter:
#
#   - it works under subscription auth, where total_cost_usd is structurally 0
#     (docs/FINDINGS.md #2);
#   - it survives a station that failed, because the transcript is written to
#     disk as the run happens rather than assembled at the end. The old error
#     path built its ledger row by hand and one branch forgot the cost field, so
#     failed attempts were recorded poorer than successful ones — a bias that
#     always pointed the same way, and pointed hardest at the worst tickets;
#   - it is per-turn, so a run that ground through its turn budget is visible as
#     grinding rather than as one large total.
#
# Two properties of the transcript were established by measurement, not assumed,
# and both will silently inflate or corrupt the numbers if forgotten:
#
#   - `message.usage` REPEATS per content block. One measured file had 36 rows
#     for 14 real requests. Dedupe by message.id.
#   - some entries carry `model: "<synthetic>"`. They are not billed.

# _aif_meter_rollup <transcript> — token totals for one subagent, as JSON.
_aif_meter_rollup() {
  jq -s '
    [ .[] | select(.message.usage) | select(.message.model != "<synthetic>") ]
    | group_by(.message.id) | map(.[0])
    | { turns: length,
        model: ( [ .[].message.model ] | unique | join(",") ),
        usage: {
          input_tokens:               ( [ .[].message.usage.input_tokens // 0 ]               | add // 0 ),
          output_tokens:              ( [ .[].message.usage.output_tokens // 0 ]              | add // 0 ),
          cache_read_input_tokens:    ( [ .[].message.usage.cache_read_input_tokens // 0 ]    | add // 0 ),
          cache_creation_input_tokens:( [ .[].message.usage.cache_creation_input_tokens // 0 ]| add // 0 ) } }
  ' "$1" 2>/dev/null
}

# _aif_meter_cost <prices.json> <model> <usage-json> — dollars, or "null".
#
# null when the model is not in the table, and that is the designed behaviour:
# a wrong price is a confident number nobody re-checks, a missing one is an
# obvious gap next to a complete token count. See sets/claude/prices.json.
_aif_meter_cost() {
  local prices="$1" model="$2" usage="$3"
  [ -f "$prices" ] || { printf 'null'; return 0; }
  jq -n --slurpfile p "$prices" --arg m "$model" --argjson u "$usage" '
    ($p[0].models[$m] // null) as $r
    | if $r == null then null
      else ( ( $u.input_tokens                * ($r.input       // 0)
             + $u.output_tokens               * ($r.output      // 0)
             + $u.cache_read_input_tokens     * ($r.cache_read  // 0)
             + $u.cache_creation_input_tokens * ($r.cache_write // 0) ) / 1000000 )
      end' 2>/dev/null || printf 'null'
}

aif_cmd_meter() {
  local payload
  payload="$(cat)"

  command -v jq >/dev/null 2>&1 || return 0

  local agent_type station transcript agent_id summary
  agent_type="$(printf '%s' "$payload" | jq -r '.agent_type // empty')"

  # Only aif's own stations are metered. A general-purpose subagent the user
  # spawned for something else is not a pipeline cost, and the ticket-critic is
  # advisory rather than a station.
  case "$agent_type" in
    aif-ticket-critic | "") return 0 ;;
    aif-*) ;;
    *) return 0 ;;
  esac

  # aif-implement and aif-implement-careful are one station on two engines. The
  # ledger records the station, and the agent name alongside it, so which engine
  # ran is answerable without inventing a second station.
  station="${agent_type#aif-}"
  station="${station%-careful}"
  station="${station%-routine}"

  transcript="$(printf '%s' "$payload" | jq -r '.agent_transcript_path // empty')"
  agent_id="$(printf '%s' "$payload" | jq -r '.agent_id // empty')"
  summary="$(printf '%s' "$payload" | jq -r '.last_assistant_message // ""' | head -1)"

  local root ticket work
  root="$(aif_project_root)" || return 0
  ticket="$(cat "$(aif_current_ticket_file "$root")" 2>/dev/null)" || true
  [ -n "$ticket" ] || {
    aif_err "meter: no current ticket — $station ran unmetered"
    return 0
  }
  work="$(aif_task_dir "$root" "$ticket")"
  [ -f "$(aif_ledger_path "$work")" ] || {
    aif_err "meter: no ledger for $ticket — $station ran unmetered"
    return 0
  }

  # No transcript is a fact worth recording, not a reason to record nothing. A
  # station that ran and left no measurable trace is exactly the hole this whole
  # phase exists to close, so it goes in the ledger as "unmetered" rather than
  # quietly vanishing and making the totals look better than they are.
  local rollup model usage turns cost attempt
  if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    rollup="$(_aif_meter_rollup "$transcript")"
  else
    rollup=""
  fi

  attempt=$(($(jq --arg s "$station" \
    '[.entries[] | select(.station == $s)] | length' \
    "$(aif_ledger_path "$work")" 2>/dev/null || printf 0) + 1))

  if [ -z "$rollup" ] || [ "$rollup" = "null" ]; then
    aif_ledger_append "$work" "$(jq -n \
      --arg s "$station" --argjson a "$attempt" --arg ag "$agent_type" \
      --arg id "$agent_id" --arg sum "$summary" --arg t "${transcript:-none}" \
      '{ station: $s, attempt: $a, agent: $ag, agent_id: $id,
         result: "unmetered", reason: ("no readable transcript at " + $t),
         summary: $sum }')"
    aif_err "meter: could not read a transcript for $station — recorded as unmetered"
    return 0
  fi

  model="$(printf '%s' "$rollup" | jq -r '.model')"
  usage="$(printf '%s' "$rollup" | jq -c '.usage')"
  turns="$(printf '%s' "$rollup" | jq -r '.turns')"
  cost="$(_aif_meter_cost "$root/.aif/prices.json" "$model" "$usage")"

  aif_ledger_append "$work" "$(jq -n \
    --arg s "$station" --argjson a "$attempt" --arg ag "$agent_type" \
    --arg id "$agent_id" --arg m "$model" --argjson u "$usage" \
    --argjson t "$turns" --argjson c "$cost" --arg sum "$summary" \
    '{ station: $s, attempt: $a, agent: $ag, agent_id: $id, model: $m,
       usage: $u, num_turns: $t,
       cost_usd: $c,
       cost_source: (if $c == null then "tokens-only" else "priced" end),
       result: "ran", summary: $sum }')"

  printf '%smetered%s %s · %s turns · %s output tokens%s\n' \
    "$AIF_C_DIM" "$AIF_C_RESET" "$station" "$turns" \
    "$(printf '%s' "$usage" | jq -r '.output_tokens')" \
    "$([ "$cost" = "null" ] && printf ' (unpriced — see .aif/prices.json)' || printf ' · $%s' "$cost")" >&2
}
