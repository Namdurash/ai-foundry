#!/usr/bin/env bash
#
# The work ledger: an append-only, hash-chained record of every station attempt
# and every gate result for one ticket.
# Sourced by bin/aif; not meant to be executed directly.
#
# Two invariants carry principle 7 (the unit of measure is the accepted
# function):
#
#   - One row per attempt, never updated in place. Overwrite a row and rework
#     vanishes — and rework is exactly what the metric counts. A flattering
#     number is the failure mode here.
#   - Cost is recorded as TOKENS, not total_cost_usd, which docs/FINDINGS.md #2
#     shows is structurally zero under subscription auth. Dollars are derived
#     later from a price table; tokens are the raw datum.
#
# The ledger is the RECORD of what happened, not the state machine. Where the
# stage of a run has got to is lib/run.sh's business; this file answers "what
# did each attempt cost, and what did each gate say about which bytes", which
# is a question a fold over an append-only log answers honestly and a stored
# summary does not.

AIF_LEDGER_SCHEMA=1

aif_ledger_path() {
  printf '%s/ledger.json' "$1"
}

aif_ledger_init() {
  local work="$1" ticket="$2"
  local ledger
  ledger="$(aif_ledger_path "$work")"
  [ -f "$ledger" ] && return 0
  jq -n --argjson schema "$AIF_LEDGER_SCHEMA" --arg ticket "$ticket" \
    '{ schema: $schema, ticket: $ticket, entries: [], accepted_at: null }' \
    >"$ledger.tmp" && mv "$ledger.tmp" "$ledger"
}

# aif_ledger_append <work> <entry-json>
#
# Stamps the entry with seq, at, and prev (the sha256 of the previous stored
# entry) and appends it. The chain is cheap self-consistency; git is the real
# tamper-evidence, since tasks/ is committed.
aif_ledger_append() {
  local work="$1" entry="$2"
  local ledger tmp seq prev last stamp
  ledger="$(aif_ledger_path "$work")"
  [ -f "$ledger" ] || aif_die "no ledger at $ledger — run 'aif _ticket-init' first"

  # Read-modify-write, so two writers racing would silently drop one entry —
  # and a ledger that quietly loses rows is worse than one that fails loudly,
  # because the number it then reports is too low and looks fine. The metering
  # hook made this reachable: it fires when a subagent finishes, and finishes
  # are not serialised by anything aif controls.
  #
  # mkdir is the lock: atomic on every POSIX filesystem, needs no flock (absent
  # from stock macOS), and leaves a directory a human can see and delete.
  local lock="$ledger.lock" waited=0
  while ! mkdir "$lock" 2>/dev/null; do
    waited=$((waited + 1))
    if [ "$waited" -gt 100 ]; then
      aif_die "ledger is locked by another writer ($lock) — remove it if no run is in progress"
    fi
    sleep 0.1 2>/dev/null || sleep 1
  done
  # The path is expanded into the trap NOW, not read from a local at fire time —
  # by then the local is out of scope. The caller's handler is appended rather
  # than displaced: a signal arriving mid-write must still do whatever the
  # command had arranged for it, and `trap -` on the way out used to take that
  # handler with it (docs/DEFECTS-3.md #1).
  # shellcheck disable=SC2064 # expanding now is the point, see above
  trap "rmdir '$lock' 2>/dev/null || true; ${AIF_TRAP_ARMED:-}" EXIT INT TERM

  seq=$(($(jq '.entries | length' "$ledger") + 1))
  if [ "$seq" -eq 1 ]; then
    prev="null"
  else
    last="$(jq -S -c '.entries[-1]' "$ledger")"
    prev="\"$(printf '%s' "$last" | aif_sha256_stdin)\""
  fi
  stamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  tmp="$(aif_tmpfile "$ledger")"
  jq --argjson entry "$entry" --argjson seq "$seq" \
    --argjson prev "$prev" --arg at "$stamp" \
    '.entries += [ $entry + { seq: $seq, at: $at, prev: $prev } ]' \
    "$ledger" >"$tmp" && mv "$tmp" "$ledger"

  rmdir "$lock" 2>/dev/null || true
  aif_trap_restore
}

# aif_ledger_gate <work> <gate> <result> <subject> <subject_sha> <gate_sha> <reason>
#
# One row per verdict, bound to the bytes it judged and to the gate script that
# judged them. The gate's own hash is there so a verdict recorded by an older
# set is legible as such rather than silently compared against today's rules.
aif_ledger_gate() {
  aif_ledger_append "$1" "$(jq -n \
    --arg gate "$2" --arg result "$3" --arg subject "$4" \
    --arg ssha "$5" --arg gsha "$6" --arg reason "$7" \
    '{ gate: $gate, result: $result, subject: $subject,
       subject_sha256: $ssha, gate_sha256: $gsha, reason: $reason }')"
}

