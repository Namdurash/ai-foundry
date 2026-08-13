#!/usr/bin/env bash
#
# Running an installed gate, and reading a station's declaration.
# Sourced by bin/aif; not meant to be executed directly.
#
# Gates are the only thing in the foundry that decides anything. They are
# separate scripts under .aif/gates/ rather than functions here for a reason
# recorded in FINDINGS #7a: a gate must run in CI, in a fresh checkout, with no
# aif on the box. So this module runs them; it does not contain them.

# aif_gate_path <root> <gate>
aif_gate_path() {
  printf '%s/.aif/gates/%s.sh' "$1" "$2"
}

# aif_gate_run <root> <gate> <work-dir> — echo the gate's output, return its exit
# code: 0 pass · 1 the artifact is rejected · 3 the gate could not render a
# verdict (the environment is wrong, not the artifact) · 127 not installed.
#
# 3 and 1 are different answers and callers must not conflate them. A rejection
# is work for a human on the artifact; a 3 is a missing tool, and no amount of
# editing the artifact will fix it.
aif_gate_run() {
  local gp
  gp="$(aif_gate_path "$1" "$2")"
  [ -f "$gp" ] || return 127
  /bin/bash "$gp" "$3" 2>&1
}

# aif_station_meta <root> <station> — the aif:meta JSON of a station's agent file.
aif_station_meta() {
  local f
  f="$(aif_station_file "$1" "$2")"
  [ -f "$f" ] || return 1
  aif_meta_json "$f"
}

# aif_station_gates <root> <station> — the gates a station's output is checked
# by, one per line. .gates wins over .form_gate; a station may have several
# (implement has green and scope) and they are ordered.
aif_station_gates() {
  aif_station_meta "$1" "$2" |
    jq -r 'if .gates then .gates[] elif .form_gate then .form_gate else empty end'
}

# aif_station_subject <root> <station> <work> — the artifact a gate result binds
# to, echoed as "<relative-path>\t<sha256>", or empty when there is none.
#
# Three fallbacks, in this order, and each answers a different question:
#
#   freezes  — what the station's gate WROTE to record a boundary (tests.lock.json).
#              The next station's precondition binds to that boundary, not to
#              the scattered files that produced it.
#   produces — the station's own artifact (spec.md, plan.md).
#   binds    — for a station that writes no artifact into the work dir at all.
#              implement writes CODE, so there is nothing here to hash; but its
#              scope verdict is relative to the plan's file manifest, so the
#              plan is what the verdict must lapse with. Without this the
#              verdict binds to nothing, and a pass recorded against nothing
#              can never be invalidated — which is the same as not recording it.
aif_station_subject() {
  local root="$1" station="$2" work="$3"
  local meta subject key
  meta="$(aif_station_meta "$root" "$station")" || return 0
  for key in freezes produces binds; do
    subject="$(printf '%s' "$meta" | jq -r --arg k "$key" '.[$k] // empty')"
    if [ -n "$subject" ] && [ -f "$work/$subject" ]; then
      printf '%s\t%s' "$subject" "$(aif_sha256 "$work/$subject")"
      return 0
    fi
  done
}

# aif_station_agent <root> <station> <work> — the subagent that runs this
# station, resolving the per-ticket tier when the station declares one.
#
# A station whose tier is "risk" cannot name one agent: a subagent's model comes
# from static frontmatter, so the two engines are two agent files and the choice
# is made here, from the spec's risk — the human's call at spec time.
aif_station_agent() {
  local root="$1" station="$2" work="$3"
  local meta tier risk
  meta="$(aif_station_meta "$root" "$station")" || return 1
  tier="$(printf '%s' "$meta" | jq -r '.tier // empty')"

  if [ "$tier" != "risk" ]; then
    printf 'aif-%s' "$station"
    return 0
  fi

  risk="$(aif_meta_json "$work/spec.md" 2>/dev/null | jq -r '.risk // "medium"' 2>/dev/null)"
  [ -n "$risk" ] || risk="medium"
  case "$risk" in
    high) tier="careful" ;;
    *) tier="routine" ;;
  esac
  printf '%s' "$meta" | jq -r --arg t "$tier" \
    '.agents[$t] // ("aif-" + .station)'
}
