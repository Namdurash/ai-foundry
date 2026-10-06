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
#
# And it is never more than the record: nothing it does may stop anything
# (docs/DEFECTS.md 13.1). Nothing reads it to decide — the gates judge the
# artifacts, the run record holds the stage — so a row that cannot be written
# is skipped with a warning, and the run, the gate and the land go on. It used
# to be the other way round. A lock left behind, a missing file or one that was
# not JSON made the append exit, and because a gate records its verdicts after
# rendering them, a gate that had PASSED exited 1 — which the worker reads as a
# rejection: the station was sent back with "ledger is locked" for its
# complaint, and the run then died writing its report. The ledger was built
# when aif watched the money; on a subscription it is the least of what a run
# is for, and it is ranked that way.
#
# Nor is it in git (docs/DEFECTS.md 13.13). It was committed with the ticket,
# so it rode every merge the ticket's branch made — and an empty one the
# analyst had committed met the branch's at land, the only file the merge of
# aif/OPES-74 stopped on (13.2). It lives in the main checkout now, under
# AIF_LEDGERS_DIR, one file per ticket: every worktree writes to the same one,
# it outlives the worktree, and no branch carries it. What a reviewer needs of
# it — each station's attempts and tokens, each gate's verdict — the report
# carries, on the branch.

AIF_LEDGER_SCHEMA=1

# aif_ledger_path <work> — the ledger of the ticket whose directory is <work>:
# AIF_LEDGERS_DIR/<ID>.json in the main checkout of the repository <work> is
# in, whichever worktree that is. A directory that is not a ticket's keeps its
# ledger beside it, as every ledger once did.
aif_ledger_path() {
  local work="$1" root
  case "$work" in
    */"$AIF_TASKS_DIR"/*)
      root="${work%/"$AIF_TASKS_DIR"/*}"
      printf '%s/%s/%s.json' "$(aif_main_root "$root")" "$AIF_LEDGERS_DIR" "$(basename "$work")"
      ;;
    *) printf '%s/ledger.json' "$work" ;;
  esac
}

# aif_ledger_init <work> <ticket> — a ledger, when there is none. rc 0 always:
# a ledger nobody could create is a warning, never a stop.
#
# Empty — unless the ticket carries one from when ledgers were committed
# (<work>/ledger.json, readable): then that is where its rows go on from. The
# old file is read, never written again; its rows stay in git's history and on
# the branches that have it.
aif_ledger_init() {
  local work="$1" ticket="$2" ledger legacy="$1/ledger.json"
  ledger="$(aif_ledger_path "$work")"
  [ ! -f "$ledger" ] || return 0
  mkdir -p "$(dirname "$ledger")" 2>/dev/null || true
  if [ "$legacy" != "$ledger" ] && jq -e '.entries | type == "array"' "$legacy" >/dev/null 2>&1 &&
    cp "$legacy" "$ledger.tmp" 2>/dev/null && mv "$ledger.tmp" "$ledger" 2>/dev/null; then
    return 0
  fi
  if ! { jq -n --argjson schema "$AIF_LEDGER_SCHEMA" --arg ticket "$ticket" \
    '{ schema: $schema, ticket: $ticket, entries: [], accepted_at: null }' \
    >"$ledger.tmp" && mv "$ledger.tmp" "$ledger"; } 2>/dev/null; then
    rm -f "$ledger.tmp" 2>/dev/null
    aif_warn "ledger: could not create $ledger — what runs here goes unrecorded; nothing else is affected"
  fi
  return 0
}

# aif_ledger_append <work> <entry-json> — the entry, stamped with seq, at and
# prev (the sha256 of the previous stored entry), appended. rc 0 always.
#
# The chain is self-consistency and no more: the ledger is not in git, and
# nothing decides anything by it.
#
# In a subshell of its own, so that whatever happens inside ends there: a lock
# nobody gave back, a file that is not JSON, a signal mid-write. The subshell
# arms its own traps, which take the lock and the half-written file with them,
# and the caller's traps are never touched — docs/DEFECTS.md 3.1 was a library
# that cleared the caller's handler, and splicing that handler into this one's
# trap was the fix until there was no shared trap to splice into.
aif_ledger_append() {
  (
    _AIF_LEDGER_LOCK=""
    _AIF_LEDGER_TMP=""
    trap '[ -z "$_AIF_LEDGER_TMP" ] || rm -f "$_AIF_LEDGER_TMP"; [ -z "$_AIF_LEDGER_LOCK" ] || rm -rf "$_AIF_LEDGER_LOCK"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    # And the hang-up a closed terminal sends to the worker's whole group: left
    # to its default it kills the subshell without the EXIT trap, lock and
    # half-written file in place (docs/DEFECTS.md 14.8).
    trap 'exit 129' HUP
    _aif_ledger_append "$1" "$2"
  ) || true
  return 0
}

# _aif_ledger_append <work> <entry-json> — the append itself, inside the
# subshell above: every step checked, nothing left to errexit, which the
# subshell's `|| true` turns off anyway. rc 1 with a warning said.
_aif_ledger_append() {
  local work="$1" entry="$2" ledger lock holder tries=0 n prev last stamp tmp aside
  ledger="$(aif_ledger_path "$work")"
  [ -f "$ledger" ] || aif_ledger_init "$work" "$(basename "$work")"
  [ -f "$ledger" ] || return 1

  # mkdir is the lock: atomic on every POSIX filesystem, needs no flock (absent
  # from stock macOS), and leaves a directory a human can see. A writer's
  # appends are serial — the worker's, then `aif _gate`'s, never at once — so
  # the lock is insurance against a second process, not a queue, and a lock
  # nobody holds is taken over instead of obeyed: one left by this very
  # process (an append of it that was killed mid-write), one whose process is
  # gone, one older than a minute, and one never signed after half a second.
  # A live writer is waited for five seconds; after that this row is skipped.
  lock="$ledger.lock"
  while ! mkdir "$lock" 2>/dev/null; do
    tries=$((tries + 1))
    holder="$(cat "$lock/pid" 2>/dev/null || true)"
    if [ "$tries" -gt 50 ]; then
      aif_warn "ledger: $lock is held${holder:+ by pid $holder} — one row of $(basename "$work") is not recorded; nothing else is affected"
      return 1
    fi
    if [ "$holder" = "$$" ] || { [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; } ||
      { [ -z "$holder" ] && [ "$tries" -gt 5 ]; } ||
      [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rm -rf "${lock:?}" 2>/dev/null || true
      continue
    fi
    sleep 0.1 2>/dev/null || sleep 1
  done
  _AIF_LEDGER_LOCK="$lock"
  printf '%s\n' "$$" >"$lock/pid" 2>/dev/null || true

  # A ledger that is not JSON — a file edited by hand, a disk that filled — is
  # set aside beside itself, and a new one is started: the rows from here on
  # are worth more than a run stopped over the rows before.
  n="$(jq '.entries | length' "$ledger" 2>/dev/null)" || n=""
  case "$n" in
    '' | *[!0-9]*)
      aside="${ledger%.json}.unreadable-$(date -u '+%Y%m%dT%H%M%SZ').json"
      if ! { cp "$ledger" "$aside" && rm -f "$ledger"; } 2>/dev/null; then
        aif_warn "ledger: $ledger is not JSON and could not be set aside — one row of $(basename "$work") is not recorded"
        return 1
      fi
      aif_ledger_init "$work" "$(basename "$work")"
      [ -f "$ledger" ] || return 1
      aif_warn "ledger: $ledger was not JSON — kept at $aside, and a new one started"
      n=0
      ;;
  esac

  if [ "$n" -eq 0 ]; then
    prev="null"
  else
    last="$(jq -S -c '.entries[-1]' "$ledger" 2>/dev/null)" || last=""
    prev="\"$(printf '%s' "$last" | aif_sha256_stdin)\""
  fi
  stamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  tmp="$(aif_tmpfile "$ledger" 2>/dev/null)" || tmp=""
  [ -n "$tmp" ] || {
    aif_warn "ledger: no temp file beside $ledger — one row of $(basename "$work") is not recorded"
    return 1
  }
  _AIF_LEDGER_TMP="$tmp"
  if ! jq --argjson entry "$entry" --argjson seq "$((n + 1))" \
    --argjson prev "$prev" --arg at "$stamp" \
    '.entries += [ $entry + { seq: $seq, at: $at, prev: $prev } ]' \
    "$ledger" >"$tmp" 2>/dev/null || ! mv "$tmp" "$ledger" 2>/dev/null; then
    aif_warn "ledger: a row of $(basename "$work") was not recorded — it was not a JSON object: $(printf '%s' "$entry" | tr '\n' ' ' | cut -c1-120)"
    return 1
  fi
  _AIF_LEDGER_TMP=""
  return 0
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
