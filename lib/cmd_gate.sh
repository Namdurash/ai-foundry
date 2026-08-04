#!/usr/bin/env bash
#
# `aif _gate <station> <ticket>` — check a station's output and record the verdict.
# Sourced by bin/aif; not meant to be executed directly.
#
# The orchestrator dispatches a station as a subagent and then calls this. It
# takes a STATION, not a gate, because a station may have several (implement has
# green and scope), they are ordered, and each verdict has to bind to the right
# artifact — which the station's declaration knows and the caller should not have
# to.
#
# Recording is the point as much as checking. A gate result in the ledger, bound
# to the bytes it judged, is what makes the next station's precondition
# checkable without re-running a gate that can no longer be re-run.
#
# Exit: 0 all gates pass · 1 an artifact was rejected · 3 a gate could not render
# a verdict (the environment, not the artifact) · 4 the station rewrote nothing.

_aif_gate_usage() {
  cat <<EOF
usage: aif _gate <station> <ticket>

  Runs every gate the station declares, in order, and records each verdict in
  the ledger bound to the artifact it judged.
EOF
}

aif_cmd_gate() {
  case "${1:-}" in
    -h | --help | "")
      _aif_gate_usage
      return 0
      ;;
  esac

  local station="$1" ticket="${2:-}"
  [ -n "$ticket" ] || aif_die "usage: aif _gate <station> <ticket>"

  local root work
  root="$(aif_require_project)"
  work="$(aif_task_dir "$root" "$ticket")"
  [ -d "$work" ] || aif_die "no such ticket: $ticket"

  aif_station_meta "$root" "$station" >/dev/null 2>&1 ||
    aif_die "no such station: $station"

  local tab subject_line subject hash
  tab="$(printf '\t')"

  # The subject is resolved twice, and it has to be. BEFORE a gate runs it is the
  # station's output as it stands, which is what the unchanged-bytes check
  # compares against. AFTER the gate runs it may be something else entirely: a
  # freezing gate CREATES the artifact it freezes — verify-red writes tests.lock
  # — so a subject resolved up front would be empty exactly for the station whose
  # recorded pass the next station depends on.
  _resolve_subject() {
    subject_line="$(aif_station_subject "$root" "$station" "$work")"
    if [ -n "$subject_line" ]; then
      subject="${subject_line%%"$tab"*}"
      hash="${subject_line#*"$tab"}"
    else
      subject=""
      hash=""
    fi
  }
  _resolve_subject

  local gates gate rc out last last_result last_sha overall=0
  gates="$(aif_station_gates "$root" "$station")"
  [ -n "$gates" ] || aif_die "station '$station' declares no gates — nothing to check"

  # Verdicts are collected here and written to the ledger only after every gate
  # has run. Recording as we go looks harmless and is not: the ledger lives under
  # tasks/, tasks/ is on scope's denylist, and scope diffs the working tree — so
  # green's freshly recorded pass appeared to scope as an implementation editing
  # the pipeline's own machinery, and scope rejected a correct implementation.
  #
  # The rule this restores: instrumentation must not perturb what it measures.
  local records=""

  for gate in $gates; do
    # Byte-identical output that this same gate already rejected is a failed
    # attempt wearing a success's clothes. The gate would return the same verdict
    # it returned last time, so re-recording it would show a second attempt that
    # cost tokens and moved nothing. Observed live before this check existed: a
    # spec attempt that burned 2599 output tokens over 5 turns and rewrote
    # nothing, then produced complaints identical to the previous round.
    if [ -n "$hash" ]; then
      last="$(aif_ledger_gate_last "$work" "$gate")"
      last_result="${last%%|*}"
      last_sha="${last#*|}"
      if [ "$last_result" = "fail" ] && [ "$last_sha" = "$hash" ]; then
        aif_err "$station left $subject byte-for-byte unchanged since $gate last rejected it."
        aif_err "Nothing was rewritten, so the gate can only return the same verdict. Check the station's instructions or the ticket before re-running."
        return 4
      fi
    fi

    rc=0
    out="$(aif_gate_run "$root" "$gate" "$work")" || rc=$?

    if [ "$rc" -eq 127 ]; then
      aif_err "gate '$gate' is not installed in this project — cannot verify $station"
      return 3
    fi

    # A gate that cannot render a verdict is recorded as such rather than as a
    # rejection: "the environment is wrong" and "the artifact is wrong" send a
    # human to different places, and flattening them sends them to the wrong one.
    # Re-resolve now that the gate has run: it may have written the artifact the
    # verdict must bind to.
    _resolve_subject

    if [ "$rc" -eq 3 ]; then
      records="$records$gate$tab""error$tab$subject$tab$hash$tab$(printf '%s' "$out" | head -1)
"
      _aif_gate_record "$work" "$root" "$records"
      aif_err "$gate could not render a verdict — that is the environment, not the artifact:"
      printf '%s\n' "$out" | sed 's/^/  /' >&2
      return 3
    fi

    records="$records$gate$tab$([ "$rc" -eq 0 ] && printf pass || printf fail)$tab$subject$tab$hash$tab$(printf '%s' "$out" | head -1)
"

    if [ "$rc" -ne 0 ]; then
      aif_err "$gate rejected the output:"
      printf '%s\n' "$out" | sed 's/^/  /' >&2
      overall=1
      # Stop at the first rejection: later gates read the same artifact and would
      # pile complaints onto a thing that is already going back for repair.
      break
    fi

    printf '%s✓%s %s\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$(printf '%s' "$out" | head -1)"
  done

  _aif_gate_record "$work" "$root" "$records"
  return "$overall"
}

# _aif_gate_record <work> <root> <records>
#
# Append the collected verdicts, one ledger row each. Called once, after every
# gate has run — see the comment on `records` above for why that ordering is not
# a detail. Each record carries its own subject and hash, because a freezing gate
# changes what the subject is by running.
_aif_gate_record() {
  local work="$1" root="$2" records="$3"
  local gate result subject hash reason tab
  tab="$(printf '\t')"
  while IFS="$tab" read -r gate result subject hash reason; do
    [ -n "$gate" ] || continue
    aif_ledger_gate "$work" "$gate" "$result" "$subject" "$hash" \
      "$(aif_sha256 "$(aif_gate_path "$root" "$gate")")" "$reason"
  done <<EOF
$records
EOF
}

# `aif _commit <station> <ticket>` — one commit per accepted station.
#
# aif owns the commits between ticket start and merge, so the next station's
# gates have a baseline to diff against (scope) and to revert to (green's
# recheck). The human reviews the branch at the end, not each machine step.
aif_cmd_commit() {
  local station="${1:-}" ticket="${2:-}"
  [ -n "$station" ] && [ -n "$ticket" ] || aif_die "usage: aif _commit <station> <ticket>"

  local root
  root="$(aif_require_project)"
  [ -d "$root/.git" ] || return 0

  git -C "$root" add -A >/dev/null 2>&1 || true
  if git -C "$root" diff --cached --quiet 2>/dev/null; then
    printf '%snothing to commit%s for %s\n' "$AIF_C_DIM" "$AIF_C_RESET" "$station"
    return 0
  fi

  local attempt
  attempt="$(jq --arg s "$station" \
    '[.entries[] | select(.station == $s)] | length' \
    "$(aif_ledger_path "$(aif_task_dir "$root" "$ticket")")" 2>/dev/null)"
  [ -n "$attempt" ] || attempt=1

  git -C "$root" \
    -c user.email="aif@local" -c user.name="aif" \
    commit -q -m "aif: $station $ticket (attempt $attempt)" >/dev/null 2>&1 || true
  printf '%scommitted%s %s %s\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$station" "$ticket"
}
