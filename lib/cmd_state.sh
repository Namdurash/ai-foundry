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
# what makes a backward transition free. Edit ticket.md and the plan bound to it
# stops passing, and everything below the plan lapses with it — nothing to undo.
#
# Cost: the walk stops at the first step that is not done, so the expensive gates
# (green re-runs the suite twice) only execute once everything before them
# passes — which is exactly when their answer is the one being asked for.

# The pipeline, in order. Columns: step, kind, then its gates as gate:source.
#
# source is "live" or "recorded", and the distinction is not an optimisation. It
# separates gates that assert something about an artifact as it now stands from
# gates whose truth is relative to a BASELINE THAT MOVES. Each of the second
# kind fails differently if re-run:
#
#   - plan-form asserts, among else, that every files.create path does not
#     exist yet. The implement station then creates exactly those paths — that
#     is what files.create is for — so a re-run rejects a finished ticket and
#     routes it back to planning, forever. A plan is written against the
#     repository AS IT STOOD at plan time; only then is the check meaningful.
#   - plan-judge's verdict binds to the plan's bytes, which do not move — but
#     it runs on a model, so "re-run on every state query" was never on the
#     table; it is recorded for the same reason the code gates are.
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
# verdict, and it lapses the same way every other binding does: the pass is
# invalid the moment its subject's hash moves, and aif_ledger_recorded_pass
# also follows the bindings INSIDE the subject — so editing ticket.md lapses the
# recorded plan pass through the plan's own ticket_sha256, without anyone
# re-running a gate. verify-red's "create paths must not exist yet" check
# stays live at the tests boundary as the net for files created out-of-band
# between plan and implement.
#
# What this costs, stated plainly: at these boundaries "passes now" becomes
# "passed, against inputs that have not changed since". Editing the source after
# acceptance does not re-open the gate. Nothing cheap fixes that — the evidence
# a revert-recheck needs is destroyed by the commit that preserves the work.
#
# `ready` is a GATE step, not a station: nobody is dispatched to produce the
# ticket — the analyst wrote it with the human. The gate is the Definition of
# Ready, and it runs live every time so a ticket edited after the analyst
# passed it is re-judged on its current bytes, the same as everything else.
_aif_state_steps() {
  cat <<'EOF'
ready	gate	ready:live
plan	station	plan-form:recorded
plan-judge	station	plan-judge:recorded
tests	station	verify-red:recorded
implement	station	green:recorded scope:recorded
EOF
}

# _aif_state_ticket_ready <work> — true once ticket.md holds a real ticket rather
# than the stub the scaffold writes. A cheap proxy, not a validator: the ready
# gate judges the rest.
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
        printf 'blocked\t%s has no recorded pass bound to the current bytes — the artifact, or something it binds to, has changed since it passed' "$gate"
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

# _aif_state_bindings <root> <step> <work> — the hashes a station's dispatch
# prompt must carry, as a JSON object { field: sha256 }.
#
# A station that must copy a hash into its artifact cannot always compute one:
# the judges have Read and Write and no Bash, so subject_sha256 — the binding
# that makes their verdict falsifiable — is physically out of their reach, and
# every judge run was rejected until the orchestrator happened to supply it.
# This completes that dispatch contract: the station's aif:meta declares, in
# `dispatch`, which field binds to which artifact; _state computes the hash of
# the artifact AS IT STANDS AT DISPATCH and hands it to the orchestrator in
# `next`, which passes it into the prompt verbatim. Nothing about trust
# changes — the gate still verifies the recorded value against the real bytes,
# so a station that copies the wrong hash is caught exactly as before.
#
# An artifact not there yet is omitted rather than hashed as nothing: the
# station that needs it has a `requires` unmet, and _state will not route
# there anyway.
_aif_state_bindings() {
  local root="$1" step="$2" work="$3"
  local meta out="{}" field file tab
  meta="$(aif_station_meta "$root" "$step" 2>/dev/null)" || {
    printf '{}'
    return 0
  }
  tab="$(printf '\t')"
  while IFS="$tab" read -r field file; do
    [ -n "$field" ] && [ -n "$file" ] || continue
    [ -f "$work/$file" ] || continue
    out="$(printf '%s' "$out" |
      jq -c --arg k "$field" --arg v "$(aif_sha256 "$work/$file")" '. + { ($k): $v }')"
  done <<EOF
$(printf '%s' "$meta" | jq -r '.dispatch // {} | to_entries[] | [.key, .value] | @tsv' 2>/dev/null)
EOF
  printf '%s' "$out"
}

# _aif_state_checklist <work> — what this run did NOT establish, as a JSON array
# of { source, id, text }.
#
# Emitted when the ticket is done, and that is the whole point of it. A blind
# spot acknowledged at approval and never surfaced again is the same as no blind
# spot: on the ticket that produced this, the record said in writing that the
# target environment was never exercised, the human accepted it in a list of
# eight, and no station referred to it afterwards. The pipeline had one place
# where it acknowledged what it could not see, and that acknowledgement was
# structurally designed to disappear.
#
# Three sources, because gaps arrive at three different moments:
#   ticket.md       — verification_gaps, recorded by the analyst with the human;
#   plan.md         — external dependencies the plan could point at no check
#                     and no criterion for. Nothing in the run validated those.
#   tests.lock.json — tests green at freeze: on a reworked ticket an earlier
#                     round already implemented their criteria, so this run
#                     accepted them without ever seeing a red-to-green
#                     transition. The suite says they pass; nothing here says
#                     they ever depended on the code.
_aif_state_checklist() {
  local work="$1" spec_gaps="[]" plan_gaps="[]" test_gaps="[]"

  if [ -f "$work/ticket.md" ]; then
    spec_gaps="$(aif_meta_json "$work/ticket.md" 2>/dev/null |
      jq -c '[ .verification_gaps[]? | { source: "ticket", id: .id, text: .text } ]' 2>/dev/null)"
  fi
  if [ -f "$work/plan.md" ]; then
    plan_gaps="$(aif_meta_json "$work/plan.md" 2>/dev/null |
      jq -c '[ .external[]?
               | select((.check // null) == null and (.ac // null) == null)
               | { source: "plan", id: .name,
                   text: "external dependency with no check and no criterion — nothing in this run exercised it" } ]' 2>/dev/null)"
  fi
  if [ -f "$work/tests.lock.json" ]; then
    test_gaps="$(jq -c '[ .green_at_freeze[]?
               | { source: "tests", id: .,
                   text: "green at freeze — never proven red; this run accepted its criterion without a red-to-green transition" } ]' \
      "$work/tests.lock.json" 2>/dev/null)"
  fi

  [ -n "$spec_gaps" ] || spec_gaps="[]"
  [ -n "$plan_gaps" ] || plan_gaps="[]"
  [ -n "$test_gaps" ] || test_gaps="[]"
  jq -nc --argjson a "$spec_gaps" --argjson b "$plan_gaps" --argjson c "$test_gaps" '$a + $b + $c'
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
    # A ticket from before tasks/ existed. Say so instead of reporting "no such
    # ticket" and quietly starting over on top of finished work — the artifacts
    # are right there, and the fix is one command. Not performed automatically:
    # moving a directory of someone's committed work is theirs to run and to see
    # in the diff.
    if [ -d "$root/.aif/work/$ticket" ]; then
      jq -n --arg t "$ticket" --arg d "$dir_rel" \
        --arg cmd "git mv .aif/work/$ticket $AIF_TASKS_DIR/$ticket" \
        '{ ticket: $t, dir: $d, exists: false, steps: [],
           next: { kind: "migrate", step: "ticket", command: $cmd,
                   detail: ("this ticket predates tasks/ — its artifacts are still under .aif/work/" + $t + ". Move them and it resumes where it stood: " + $cmd) } }'
      return 0
    fi
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

    if [ "$kind" = "gate" ]; then
      # The ticket is not ready. Nothing to dispatch: the whole complaint list
      # goes out, because every line of it is a question for the analyst's
      # conversation, and the worker reports it verbatim rather than guessing.
      local full
      full="$(aif_gate_run "$root" "${gatespec%%:*}" "$work" 2>&1 || true)"
      next_json="$(jq -n --arg s "$step" --arg d "$full" \
        '{ kind: "not-ready", step: $s, detail: $d }')"
      continue
    fi

    agent="$(aif_station_agent "$root" "$step" "$work")"
    expects="$(aif_station_meta "$root" "$step" | jq -r '.expects // ""')"
    next_json="$(jq -n --arg s "$step" --arg a "$agent" --arg e "$expects" --arg d "$detail" \
      --argjson b "$(_aif_state_bindings "$root" "$step" "$work")" \
      '{ kind: "station", step: $s, agent: $a, expects: $e, bindings: $b, detail: $d }')"
  done <<EOF
$(_aif_state_steps)
EOF

  if [ -z "$next_json" ]; then
    next_json="$(jq -n --argjson checklist "$(_aif_state_checklist "$work")" \
      '{ kind: "done", detail: "every gate passes against current bytes",
         checklist: $checklist }')"
  fi

  printf '%s' "$steps_json" | jq -s --arg t "$ticket" --arg d "$dir_rel" \
    --argjson next "$next_json" \
    '{ ticket: $t, dir: $d, exists: true, steps: ., next: $next }'
}
