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
# State is never stored — it is a fold over these entries (see cmd_ticket.sh). A
# derived state cannot drift from the events it is derived from, and cannot lie.

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
  # by then the local is out of scope. No other trap exists in this codebase, so
  # clearing it below cannot clobber someone else's.
  # shellcheck disable=SC2064 # expanding now is the point, see above
  trap "rmdir '$lock' 2>/dev/null || true" EXIT INT TERM

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
  trap - EXIT INT TERM
}

# aif_ledger_gate <work> <gate> <result> <subject> <subject_sha> <gate_sha> <reason>
aif_ledger_gate() {
  aif_ledger_append "$1" "$(jq -n \
    --arg gate "$2" --arg result "$3" --arg subject "$4" \
    --arg ssha "$5" --arg gsha "$6" --arg reason "$7" \
    '{ gate: $gate, result: $result, subject: $subject,
       subject_sha256: $ssha, gate_sha256: $gsha, reason: $reason }')"
}

# aif_ledger_gate_last <work> <gate> — "<result>|<subject_sha256>" for the latest
# entry this gate wrote, or "none|" if it has never run here.
aif_ledger_gate_last() {
  local ledger
  ledger="$(aif_ledger_path "$1")"
  [ -f "$ledger" ] || { printf 'none|'; return 0; }
  jq -r --arg g "$2" \
    '[.entries[] | select(.gate == $g)] | last
     | if . == null then "none|" else (.result + "|" + (.subject_sha256 // "")) end' \
    "$ledger"
}

# aif_ledger_gate_valid <work> <gate> <current-sha> — rc 0 iff the latest entry
# for this gate is a pass recorded against exactly the current artifact bytes.
#
# This is what makes "passes now, not passed once" hold: change the artifact and
# the recorded pass no longer matches, so the gate is no longer valid — without
# anyone re-running it.
aif_ledger_gate_valid() {
  local work="$1" gate="$2" cur="$3" ledger latest
  ledger="$(aif_ledger_path "$work")"
  [ -f "$ledger" ] || return 1
  latest="$(jq -r --arg g "$gate" \
    '[.entries[] | select(.gate == $g)] | last
     | if . == null then "none|" else (.result + "|" + (.subject_sha256 // "")) end' \
    "$ledger")"
  [ "$latest" = "pass|$cur" ]
}

# aif_ledger_recorded_pass <work> <gate> — rc 0 iff the latest entry for this
# gate is a pass whose subject artifact still hashes to the recorded value.
#
# For gates that cannot be re-run as a live precondition. verify-red asserts the
# tests are red; once implementation starts that stops holding, so the recorded
# pass — bound to tests.lock's bytes — IS the precondition, not a re-run.
aif_ledger_recorded_pass() {
  local work="$1" gate="$2" ledger result subject recorded actual
  ledger="$(aif_ledger_path "$work")"
  [ -f "$ledger" ] || return 1

  result="$(jq -r --arg g "$gate" '[.entries[]|select(.gate==$g)]|last|.result//"none"' "$ledger")"
  [ "$result" = "pass" ] || return 1

  subject="$(jq -r --arg g "$gate" '[.entries[]|select(.gate==$g)]|last|.subject//""' "$ledger")"
  recorded="$(jq -r --arg g "$gate" '[.entries[]|select(.gate==$g)]|last|.subject_sha256//""' "$ledger")"

  [ -n "$subject" ] && [ -f "$work/$subject" ] || return 1
  actual="$(aif_sha256 "$work/$subject")"
  [ "$actual" = "$recorded" ]
}
