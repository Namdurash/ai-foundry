#!/usr/bin/env bash
#
# `aif _state <ticket>` — the ticket's derived state, as JSON.
# Sourced by bin/aif; not meant to be executed directly.
#
# This is the state machine, and it is deliberately NOT in the orchestrator's
# head. The orchestrator is a model; if "what runs next" were its judgement, the
# pipeline would have opinions instead of preconditions. Bash decides, the model
# dispatches.
#
# State is derived, never stored: computed by running the installed gates against
# the CURRENT bytes of each artifact — "passes now", not "passed once". That is
# what makes a backward transition free. Edit spec.md and its gates stop passing,
# the approval below it lapses on its own, and there is nothing to undo.
#
# Cost: the walk stops at the first step that is not done, so the expensive gates
# (green re-runs the suite twice) only execute once everything before them
# passes — which is exactly when their answer is the one being asked for.

# The pipeline, in order. Columns: step, kind, then its gates as gate:source.
#
# source is "live" or "recorded", and the distinction is not an optimisation. It
# separates gates that assert something about an artifact as it now stands from
# gates whose truth is relative to a BASELINE THAT MOVES. The three of the second
# kind are all at the code end of the pipeline, and each fails differently if
# re-run:
#
#   - verify-red asserts the tests are RED. That stops being true the moment
#     implementation begins, so a re-run reports failure on a step that succeeded.
#   - scope asserts the diff since the last commit stayed inside the plan. Once
#     the station is committed there is no diff, so a re-run passes VACUOUSLY —
#     worse than useless, because emptiness looks like evidence.
#   - green reverts the implementation and checks the covering tests go red
#     again. After the commit, "revert to the last commit" no longer removes the
#     implementation, so the tests stay green and it concludes they never
#     depended on the code. A false accusation, from a correct gate.
#
# For these, the RECORDED pass — bound to the bytes that were judged — is the
# verdict, and it lapses the same way every other binding does: implement's
# verdicts bind to plan.md, so a changed plan invalidates them.
#
# What this costs, stated plainly: at the code boundary "passes now" becomes
# "passed, against a plan that has not changed since". Editing the source after
# acceptance does not re-open the gate. Nothing cheap fixes that — the evidence
# a revert-recheck needs is destroyed by the commit that preserves the work.
_aif_state_steps() {
  cat <<'EOF'
spec	station	spec-form:live
spec-judge	station	spec-judge:live
approve	human	spec-approve:live
plan	station	plan-form:live
plan-judge	station	plan-judge:live
tests	station	verify-red:recorded
implement	station	green:recorded scope:recorded
EOF
}

# _aif_state_ticket_ready <work> — true once ticket.md holds a real ticket rather
# than the stub the scaffold writes. A cheap proxy, not a validator: the spec
# station and its gate judge the rest.
_aif_state_ticket_ready() {
  local tm="$1/ticket.md"
  [ -f "$tm" ] || return 1
  ! grep -q "Describe the need in your own words" "$tm" 2>/dev/null
}

# _aif_state_verdict <root> <step> <gatespec> <work>
#
# gatespec is a space-separated list of gate:source. Echo "<state>\t<detail>",
# where state is done | blocked | error.
_aif_state_verdict() {
  local root="$1" step="$2" gatespec="$3" work="$4"
  local spec gate source rc out detail=""

  for spec in $gatespec; do
    gate="${spec%%:*}"
    source="${spec#*:}"

    if [ "$source" = "recorded" ]; then
      if ! aif_ledger_recorded_pass "$work" "$gate"; then
        printf 'blocked\t%s has no recorded pass bound to the current artifact' "$gate"
        return 0
      fi
      detail="$gate recorded"
      continue
    fi

    rc=0
    out="$(aif_gate_run "$root" "$gate" "$work")" || rc=$?
    case "$rc" in
      0) detail="$(printf '%s' "$out" | head -1)" ;;
      127)
        # Not installed. An older set, or a gate from a milestone this project
        # has not taken — skipping is right, silently claiming a pass is not.
        printf 'blocked\t%s is not installed in this project' "$gate"
        return 0
        ;;
      3)
        printf 'error\t%s could not render a verdict: %s' "$gate" "$(printf '%s' "$out" | head -1)"
        return 0
        ;;
      *)
        printf 'blocked\t%s' "$(printf '%s' "$out" | head -1)"
        return 0
        ;;
    esac
  done
  printf 'done\t%s' "$detail"
}

aif_cmd_state() {
  local ticket="${1:-}"
  [ -n "$ticket" ] || aif_die "usage: aif _state <ticket>"

  local root work
  root="$(aif_require_project)"
  work="$(aif_task_dir "$root" "$ticket")"

  # Tell the metering hook which ticket a subagent's cost belongs to. Here
  # because the orchestrator calls _state immediately before every dispatch, so
  # this is fresh precisely when it matters. See aif_current_ticket_file.
  local pointer
  pointer="$(aif_current_ticket_file "$root")"
  mkdir -p "$(dirname "$pointer")" 2>/dev/null || true
  printf '%s\n' "$ticket" >"$pointer" 2>/dev/null || true

  local dir_rel="$AIF_TASKS_DIR/$ticket"

  if [ ! -d "$work" ]; then
    jq -n --arg t "$ticket" --arg d "$dir_rel" \
      '{ ticket: $t, dir: $d, exists: false, steps: [],
         next: { kind: "ticket-init", step: "ticket",
                 detail: "no such ticket — scaffold it, then write the need into ticket.md" } }'
    return 0
  fi

  if ! _aif_state_ticket_ready "$work"; then
    jq -n --arg t "$ticket" --arg d "$dir_rel" \
      '{ ticket: $t, dir: $d, exists: true, steps: [],
         next: { kind: "human", step: "ticket",
                 detail: "ticket.md is still the stub — interview the user and write the need in their words" } }'
    return 0
  fi

  local steps_json="" next_json="" step kind gatespec tab
  local verdict state detail agent expects
  tab="$(printf '\t')"

  while IFS="$tab" read -r step kind gatespec; do
    [ -n "$step" ] || continue

    if [ -n "$next_json" ]; then
      # Everything after the first unfinished step is pending by construction,
      # and running its gates would only report that its inputs do not exist yet.
      steps_json="$steps_json$(jq -n --arg s "$step" --arg k "$kind" \
        '{ step: $s, kind: $k, state: "pending", detail: "" }')"
      continue
    fi

    verdict="$(_aif_state_verdict "$root" "$step" "$gatespec" "$work")"
    state="${verdict%%"$tab"*}"
    detail="${verdict#*"$tab"}"

    steps_json="$steps_json$(jq -n --arg s "$step" --arg k "$kind" \
      --arg st "$state" --arg d "$detail" \
      '{ step: $s, kind: $k, state: $st, detail: $d }')"

    [ "$state" = "done" ] && continue

    if [ "$state" = "error" ]; then
      next_json="$(jq -n --arg s "$step" --arg d "$detail" \
        '{ kind: "blocked", step: $s, detail: $d }')"
      continue
    fi

    if [ "$kind" = "human" ]; then
      next_json="$(jq -n --arg s "$step" --arg d "$detail" \
        '{ kind: "human", step: $s, detail: $d }')"
      continue
    fi

    agent="$(aif_station_agent "$root" "$step" "$work")"
    expects="$(aif_station_meta "$root" "$step" | jq -r '.expects // ""')"
    next_json="$(jq -n --arg s "$step" --arg a "$agent" --arg e "$expects" --arg d "$detail" \
      '{ kind: "station", step: $s, agent: $a, expects: $e, detail: $d }')"
  done <<EOF
$(_aif_state_steps)
EOF

  [ -n "$next_json" ] || next_json='{ "kind": "done", "detail": "every gate passes against current bytes" }'

  printf '%s' "$steps_json" | jq -s --arg t "$ticket" --arg d "$dir_rel" \
    --argjson next "$next_json" \
    '{ ticket: $t, dir: $d, exists: true, steps: ., next: $next }'
}
