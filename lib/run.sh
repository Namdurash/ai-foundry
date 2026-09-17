#!/usr/bin/env bash
#
# The run record — where one ticket's build has got to.
# Sourced by bin/aif; not meant to be executed directly.
#
# This replaces the derived state machine (lib/cmd_state.sh, 308 lines), and
# the reason it can is one rule the worker now enforces: THE INPUTS ARE FROZEN
# FOR THE RUN'S LIFETIME. `aif work` copies the ticket in at intake, hashes it,
# commits it, and from then on nothing upstream can move under the run.
#
# The old design derived the stage by running every gate against current bytes,
# because a human could edit any artifact at any moment and the answer had to
# account for it. That was correct and it cost: a hash chain that lapsed
# backwards through five artifacts, recorded passes that followed the bindings
# inside their subjects, and a run of ten commits fixing deadlocks in it. With
# the inputs frozen there is nothing to lapse, so the stage is simply recorded
# — and the ONE thing that can still invalidate it is checked explicitly:
#
#   the ticket's bytes changed since intake  →  the record is stale, start over
#
# That is the whole cascade, replaced by one comparison.
#
# The record is committed with the rest of tasks/<ID>/, so it travels with the
# branch and a reviewer can read what the run did without the run being there.

AIF_RUN_SCHEMA=2

# The stations, in order. Each is dispatched, then judged by the gate(s) it
# declares in its own agent file — the station says what checks it, not this
# list. `done` is not a stage; it is what `aif_run_next` returns past the end.
AIF_RUN_STAGES="plan tests implement"

aif_run_path() {
  printf '%s/run.json' "$1"
}

# aif_run_next <stage> — the stage after this one, or "done".
aif_run_next() {
  local s found=""
  for s in $AIF_RUN_STAGES; do
    if [ -n "$found" ]; then
      printf '%s' "$s"
      return 0
    fi
    [ "$s" = "$1" ] && found=1
  done
  printf 'done'
}

# aif_run_init <work> <ticket> <branch> <base> <worktree-rel>
#
# A fresh record at the first stage, bound to the ticket AS IT IS NOW. Called
# once per `aif work`, after the ticket has been carried into the worktree.
aif_run_init() {
  local work="$1" ticket="$2" branch="$3" base="$4" wt="$5" f
  f="$(aif_run_path "$work")"
  jq -n --argjson schema "$AIF_RUN_SCHEMA" --arg t "$ticket" \
    --arg sha "$(aif_sha256 "$work/ticket.md")" \
    --arg br "$branch" --arg base "$base" --arg wt "$wt" \
    --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg stage "${AIF_RUN_STAGES%% *}" \
    '{ schema: $schema, ticket: $t, ticket_sha256: $sha, branch: $br, base: $base,
       worktree: $wt, stage: $stage, attempts: {}, dispatches: 0, spent_usd: 0,
       started_at: $at, finished_at: null, status: "running", why: null }' \
    >"$f.tmp" && mv "$f.tmp" "$f"
}

# aif_run_get <work> <jq-path> — one field, or empty.
aif_run_get() {
  local f
  f="$(aif_run_path "$1")"
  [ -f "$f" ] || return 1
  jq -r "$2 // empty" "$f" 2>/dev/null
}

# aif_run_update <work> <jq-filter> [jq args…] — rewrite the record atomically.
#
# The FILTER COMES FIRST and the jq flags after it, which is the opposite of
# how jq itself reads. It has to be one or the other in bash 3.2 (no way to
# pop the last argument cleanly), and putting the filter where the reader
# expects the subject keeps the call sites legible.
aif_run_update() {
  local work="$1" filter="$2" f tmp
  shift 2
  f="$(aif_run_path "$work")"
  [ -f "$f" ] || return 1
  tmp="$(aif_tmpfile "$f")"
  jq "$@" "$filter" "$f" >"$tmp" && mv "$tmp" "$f"
}

# aif_run_resumable <work> — rc 0 iff a record is there AND it was made against
# the ticket as it now stands.
#
# The one check that replaces the hash cascade. A ticket reworked between runs
# makes the plan, the frozen tests and the code below it answers to a question
# nobody is asking any more; the honest response is to start the run over, not
# to reconcile it artifact by artifact.
aif_run_resumable() {
  local work="$1" recorded
  recorded="$(aif_run_get "$work" '.ticket_sha256')" || return 1
  [ -n "$recorded" ] || return 1
  [ "$recorded" = "$(aif_sha256 "$work/ticket.md")" ]
}

# aif_run_attempts <work> <stage> — how many times this stage has been
# dispatched in this run.
aif_run_attempts() {
  local n
  n="$(aif_run_get "$1" ".attempts[\"$2\"]")"
  printf '%s' "${n:-0}"
}

# aif_run_checklist <work> — what this run did NOT establish, as a JSON array
# of { source, id, text }.
#
# Emitted into the report when the ticket is done, and that is the whole point
# of it. A blind spot acknowledged once and never surfaced again is the same as
# no blind spot: on the ticket that produced this, the record said in writing
# that the target environment was never exercised, the human accepted it in a
# list of eight, and nothing referred to it afterwards.
#
# Three sources, because gaps arrive at three different moments:
#   ticket.md       — verification_gaps, recorded by the analyst with the human;
#   plan.md         — external dependencies the plan could point at no check
#                     and no criterion for. Nothing in the run validated those.
#   tests.lock.json — tests green at freeze: on a reworked ticket an earlier
#                     round already implemented their criteria, so this run
#                     accepted them without ever seeing a red-to-green
#                     transition.
aif_run_checklist() {
  local work="$1" t_gaps="[]" p_gaps="[]" x_gaps="[]"

  if [ -f "$work/ticket.md" ]; then
    t_gaps="$(aif_meta_json "$work/ticket.md" 2>/dev/null |
      jq -c '[ .verification_gaps[]? | { source: "ticket", id: .id, text: .text } ]' 2>/dev/null)"
  fi
  if [ -f "$work/plan.md" ]; then
    p_gaps="$(aif_meta_json "$work/plan.md" 2>/dev/null |
      jq -c '[ .external[]?
               | select((.check // null) == null and (.ac // null) == null)
               | { source: "plan", id: .name,
                   text: "external dependency with no check and no criterion — nothing in this run exercised it" } ]' 2>/dev/null)"
  fi
  if [ -f "$work/tests.lock.json" ]; then
    x_gaps="$(jq -c '[ .green_at_freeze[]?
               | { source: "tests", id: .,
                   text: "green at freeze — never proven red; this run accepted its criterion without a red-to-green transition" } ]' \
      "$work/tests.lock.json" 2>/dev/null)"
  fi

  [ -n "$t_gaps" ] || t_gaps="[]"
  [ -n "$p_gaps" ] || p_gaps="[]"
  [ -n "$x_gaps" ] || x_gaps="[]"
  jq -nc --argjson a "$t_gaps" --argjson b "$p_gaps" --argjson c "$x_gaps" '$a + $b + $c'
}
