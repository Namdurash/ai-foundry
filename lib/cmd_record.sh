#!/usr/bin/env bash
#
# `aif _record <station> <ticket>` — write the bindings a station's artifact
# carries. Sourced by bin/aif; not meant to be executed directly.
#
# THE MODEL NEVER CARRIES A HASH. That is the whole point of this file.
#
# Until now a station recorded its own binding: `aif _state` computed the
# sha256 of the artifact above it, the caller copied 64 hex characters into the
# dispatch prompt verbatim, the station copied them into its output, and the
# gate re-hashed and compared. A language model was the courier for a value
# whose entire purpose is exactness — and the skill file carried a paragraph
# pleading with it not to cache a stale one, because a stale hash wasted the
# whole station run.
#
# Now the tool writes it, after the station returns: the model writes CONTENT,
# the tool writes PROVENANCE. A station that was about to be rejected for
# mistyping a hash simply cannot be, and the dispatch prompt loses the one part
# of it that was a contract rather than an instruction.
#
# The gate still checks the value, and that is not tautological: the binding is
# stamped when the station ran, so the check catches a plan that is being
# re-judged after its ticket moved — a resumed run, a reworked ticket — which
# is the one lapse the frozen-inputs rule does not cover on its own.
#
# What is recorded is declared by the station, in its `records` block:
#
#   "records": { "ticket_sha256": "ticket.md" }
#
# read as: into the artifact this station `produces`, write the field
# `ticket_sha256`, holding the sha256 of `ticket.md` as it stands now.

aif_cmd_record() {
  local station="${1:-}" ticket="${2:-}"
  [ -n "$station" ] && [ -n "$ticket" ] || aif_die "usage: aif _record <station> <ticket>"

  local root work meta produces records artifact
  root="$(aif_require_project)"
  work="$(aif_task_dir "$root" "$ticket")"
  [ -d "$work" ] || aif_die "no such ticket: $ticket"

  meta="$(aif_station_meta "$root" "$station" 2>/dev/null)" ||
    aif_die "no such station: $station"

  records="$(printf '%s' "$meta" | jq -c '.records // {}')"
  if [ "$records" = "{}" ]; then
    # Nothing to stamp is the normal case for most stations, and it is not an
    # error: tests.lock.json's plan_sha256 is written by verify-red, a gate,
    # which is the tool already.
    return 0
  fi

  produces="$(printf '%s' "$meta" | jq -r '.produces // empty')"
  [ -n "$produces" ] || aif_die "station '$station' declares records but no produces — nothing to write into"
  artifact="$work/$produces"
  [ -f "$artifact" ] || {
    # The station did not write its artifact. Not this command's failure to
    # report — the gate will say so in its own words a moment from now.
    return 0
  }

  local doc field target tab
  doc="$(aif_meta_json "$artifact" 2>/dev/null)"
  [ -n "$doc" ] || aif_die "$produces has no aif:meta block to record into"
  printf '%s' "$doc" | jq -e . >/dev/null 2>&1 ||
    aif_die "$produces has an aif:meta block that is not valid JSON — the station must fix that itself"

  tab="$(printf '\t')"
  while IFS="$tab" read -r field target; do
    [ -n "$field" ] && [ -n "$target" ] || continue
    [ -f "$work/$target" ] || aif_die "cannot record $field: $target does not exist"
    doc="$(printf '%s' "$doc" | jq -c --arg k "$field" --arg v "$(aif_sha256 "$work/$target")" \
      '. + { ($k): $v }')"
  done <<EOF
$(printf '%s' "$records" | jq -r 'to_entries[] | [.key, .value] | @tsv')
EOF

  aif_meta_replace "$artifact" "$doc"
  printf '%srecorded%s %s in %s\n' "$AIF_C_DIM" "$AIF_C_RESET" \
    "$(printf '%s' "$records" | jq -r 'keys | join(", ")')" "$produces"
}
