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
# to, echoed as "<relative-path>\t<sha256>\t<key>", or empty when there is none.
#
# Three fallbacks, in this order, and each answers a different question:
#
#   freezes  — what the station's gate WROTE to record a boundary (tests.lock.json).
#              The next station's precondition binds to that boundary, not to
#              the scattered files that produced it.
#   produces — the station's own artifact (plan.md, a verdict).
#   binds    — for a station that writes no artifact into the work dir at all.
#              implement writes CODE, so there is nothing here to hash; but its
#              scope verdict is relative to the plan's file manifest, so the
#              plan is what the verdict must lapse with. Without this the
#              verdict binds to nothing, and a pass recorded against nothing
#              can never be invalidated — which is the same as not recording it.
#
# The key travels with the answer because the caller's no-progress guard must
# know it: only a `produces` subject is the station's own output, so only there
# does "unchanged bytes" mean "the station rewrote nothing". A freezes subject
# is written by the GATE, a binds subject by an EARLIER station — comparing
# either across attempts measures a file the station never touches, and that
# deadlocked two stations permanently (defects 2 and 4 of the gate-defect set).
aif_station_subject() {
  local root="$1" station="$2" work="$3"
  local meta subject key
  meta="$(aif_station_meta "$root" "$station")" || return 0
  for key in freezes produces binds; do
    subject="$(printf '%s' "$meta" | jq -r --arg k "$key" '.[$k] // empty')"
    if [ -n "$subject" ] && [ -f "$work/$subject" ]; then
      printf '%s\t%s\t%s' "$subject" "$(aif_sha256 "$work/$subject")" "$key"
      return 0
    fi
  done
}

# aif_station_rewrites <root> <station> <work> — what the station actually
# rewrites between attempts, echoed as "<kind>\t<sha256>", or empty when the
# station declares no `rewrites` (or its inputs are not there to hash).
#
# This is the no-progress guard's subject for the stations whose gate subject
# is NOT their own output. The tests station rewrites the files the plan names
# in files.tests; the implement station rewrites the working tree, so its
# subject is the diff since the last commit — tasks/ excluded, because the
# ledger legitimately moves between commits and bookkeeping noise must not
# read as progress. Two kinds, declared per station:
#
#   plan.files.tests — hash over each declared test file's current bytes
#                      (an absent file hashes as absent, so creating it counts
#                      as a rewrite too);
#   diff             — hash over the tracked diff against HEAD plus the
#                      content of untracked files, tasks/ excluded from both.
aif_station_rewrites() {
  local root="$1" station="$2" work="$3"
  local kind hash f
  kind="$(aif_station_meta "$root" "$station" 2>/dev/null | jq -r '.rewrites // empty')"
  [ -n "$kind" ] || return 0

  case "$kind" in
    plan.files.tests)
      [ -f "$work/plan.md" ] || return 0
      hash="$(
        while IFS= read -r f; do
          [ -n "$f" ] || continue
          if [ -f "$root/$f" ]; then
            printf '%s\t%s\n' "$f" "$(aif_sha256 "$root/$f")"
          else
            printf '%s\tabsent\n' "$f"
          fi
        done <<EOF
$(aif_meta_json "$work/plan.md" | jq -r '.files.tests[]? // empty')
EOF
      )"
      hash="$(printf '%s' "$hash" | aif_sha256_stdin)"
      ;;
    diff)
      [ -e "$root/.git" ] || return 0
      hash="$(
        {
          git -C "$root" diff HEAD -- . ":(exclude)$AIF_TASKS_DIR" 2>/dev/null
          git -C "$root" ls-files --others --exclude-standard -- . ":(exclude)$AIF_TASKS_DIR" 2>/dev/null |
            while IFS= read -r f; do
              [ -n "$f" ] || continue
              printf '%s\t%s\n' "$f" "$(aif_sha256 "$root/$f")"
            done
        } | aif_sha256_stdin
      )"
      ;;
    *)
      return 0
      ;;
  esac

  [ -n "$hash" ] || return 0
  printf '%s\t%s' "$kind" "$hash"
}

# aif_station_agent <root> <station> <work> — the subagent that runs this
# station, resolving the per-ticket tier when the station declares one.
#
# A station whose tier is "risk" cannot name one agent: a subagent's model comes
# from static frontmatter, so the two engines are two agent files and the choice
# is made here, from the ticket's risk — the human's call, made with the analyst.
aif_station_agent() {
  local root="$1" station="$2" work="$3"
  local meta tier risk
  meta="$(aif_station_meta "$root" "$station")" || return 1
  tier="$(printf '%s' "$meta" | jq -r '.tier // empty')"

  if [ "$tier" != "risk" ]; then
    printf 'aif-%s' "$station"
    return 0
  fi

  risk="$(aif_meta_json "$work/ticket.md" 2>/dev/null | jq -r '.risk // "medium"' 2>/dev/null)"
  [ -n "$risk" ] || risk="medium"
  case "$risk" in
    high) tier="careful" ;;
    *) tier="routine" ;;
  esac
  printf '%s' "$meta" | jq -r --arg t "$tier" \
    '.agents[$t] // ("aif-" + .station)'
}
