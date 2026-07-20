#!/usr/bin/env bash
#
# `aif work new|status` and `aif approve` — the ticket lifecycle.
# Sourced by bin/aif; not meant to be executed directly.
#
# State is derived, never stored. `aif work status` computes it by running the
# installed gates against the CURRENT bytes of each artifact — "passes now", not
# "passed once". That is what makes a backward transition free: edit spec.md and
# its gates stop passing, with nothing to undo.

_aif_gate() {
  # <root> <gate-name> <work-dir> — run an installed gate, echo output, return
  # its exit code (0 pass / 1 reject / 3 error / 127 not installed).
  local gp="$1/.aif/gates/$2.sh"
  [ -f "$gp" ] || return 127
  /bin/bash "$gp" "$3" 2>&1
}

_aif_work_new() {
  local root="$1" ticket="$2"
  local pattern work

  pattern="$(jq -r '.ticket_pattern // "^[A-Z]{2,10}-[0-9]+$"' "$(aif_project_config "$root")" 2>/dev/null)"
  case "$ticket" in
    "") aif_die "usage: aif work new <ticket>" ;;
  esac
  if ! printf '%s' "$ticket" | grep -qE "$pattern"; then
    aif_die "ticket '$ticket' does not match $pattern (from project.json)"
  fi

  work="$root/.aif/work/$ticket"
  [ -d "$work" ] && aif_die "$ticket already exists at $work"

  mkdir -p "$work"

  # The ticket is the human's words, verbatim — the one source of truth the
  # spec is judged against, so it is written by a person and never by a model.
  # risk defaults to medium (→ sonnet), never the cheapest tier by omission.
  cat >"$work/ticket.md" <<EOF
<!-- aif:meta
{ "schema": 1, "ticket": "$ticket", "lang": "en", "risk": "medium" }
-->

<!-- Describe the need in your own words. Set lang and risk in the block above.
     risk drives the implementation tier: low→cheap, high→careful + human review.
     This text is the source of truth the specification is judged against. -->
EOF

  aif_ledger_init "$work" "$ticket"

  printf '%screated%s %s\n\n' "$AIF_C_GREEN" "$AIF_C_RESET" ".aif/work/$ticket/"
  printf '  1. edit %s.aif/work/%s/ticket.md%s — the need, in your words\n' \
    "$AIF_C_BOLD" "$ticket" "$AIF_C_RESET"
  printf '  2. aif work status %s — see what is next\n' "$ticket"
}

# One pipeline stage line for `status`: name, glyph, detail.
_aif_stage() {
  local label="$1" glyph="$2" detail="$3"
  printf '  %s  %-8s %s\n' "$glyph" "$label" "$detail"
}

_aif_work_status() {
  local root="$1" ticket="$2"
  local work out rc next=""

  work="$root/.aif/work/$ticket"
  [ -d "$work" ] || aif_die "no such ticket: $ticket (start it with: aif work new $ticket)"

  printf '%s%s%s\n\n' "$AIF_C_BOLD" "$ticket" "$AIF_C_RESET"

  # ticket.md
  if [ -f "$work/ticket.md" ]; then
    _aif_stage "ticket" "$(aif_ok)" "present"
  else
    _aif_stage "ticket" "$(aif_no)" "missing"
    next="write ticket.md"
  fi

  # spec.md → spec-form (live), then spec-approve (live)
  if [ ! -f "$work/spec.md" ]; then
    _aif_stage "spec" "$(aif_no)" "not written"
    [ -z "$next" ] && next="run the spec station"
  else
    # rc captured via `|| rc=$?`, never `out=$(...); rc=$?`: under `set -e` a
    # command substitution that exits non-zero in a plain assignment kills the
    # script, and a rejecting gate exiting non-zero is the whole point here.
    rc=0
    out="$(_aif_gate "$root" "spec-form" "$work")" || rc=$?
    if [ "$rc" -ne 0 ]; then
      _aif_stage "spec" "$(aif_no)" "spec-form: $(printf '%s' "$out" | head -1)"
      [ -z "$next" ] && next="fix spec.md"
    else
      # spec-form → spec-judge → human approve. The judge runs before the human
      # to keep a malformed or blocked spec off the human's desk.
      rc=0
      out="$(_aif_gate "$root" "spec-judge" "$work")" || rc=$?
      if [ "$rc" -eq 127 ]; then
        rc=0 # judge gate not installed (pre-M2b); skip it
      fi
      if [ "$rc" -ne 0 ]; then
        _aif_stage "spec" "$(aif_no)" "judge: $(printf '%s' "$out" | head -1)"
        case "$(printf '%s' "$out" | head -1)" in
          *"not judged"*) [ -z "$next" ] && next="aif station run spec-judge $ticket" ;;
          *"different spec"*) [ -z "$next" ] && next="aif station run spec-judge $ticket" ;;
          *) [ -z "$next" ] && next="fix spec.md (judge found blockers)" ;;
        esac
      else
        rc=0
        out="$(_aif_gate "$root" "spec-approve" "$work")" || rc=$?
        if [ "$rc" -ne 0 ]; then
          _aif_stage "spec" "$(aif_no)" "awaiting approval"
          [ -z "$next" ] && next="aif approve $ticket"
        else
          _aif_stage "spec" "$(aif_ok)" "$(printf '%s' "$out" | head -1)"
        fi
      fi
    fi
  fi

  # plan.md → plan-form (live)
  if [ ! -f "$work/plan.md" ]; then
    _aif_stage "plan" "$(aif_no)" "not written"
    [ -z "$next" ] && next="run the plan station"
  else
    rc=0
    out="$(_aif_gate "$root" "plan-form" "$work")" || rc=$?
    if [ "$rc" -ne 0 ]; then
      _aif_stage "plan" "$(aif_no)" "plan-form: $(printf '%s' "$out" | head -1)"
      [ -z "$next" ] && next="fix plan.md"
    else
      _aif_stage "plan" "$(aif_ok)" "$(printf '%s' "$out" | head -1)"
    fi
  fi

  printf '\n'
  if [ -n "$next" ]; then
    printf 'next: %s%s%s\n' "$AIF_C_BOLD" "$next" "$AIF_C_RESET"
  else
    printf 'next: %stests station (not built yet)%s\n' "$AIF_C_DIM" "$AIF_C_RESET"
  fi
}

aif_cmd_work() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift

  local root
  root="$(aif_require_project)"

  case "$sub" in
    new) _aif_work_new "$root" "${1:-}" ;;
    status) _aif_work_status "$root" "${1:-}" ;;
    -h | --help | "")
      cat <<EOF
usage: aif work new <ticket>      start a ticket
       aif work status <ticket>   show the derived state
EOF
      ;;
    *) aif_die "unknown subcommand: $sub" ;;
  esac
}

# `aif approve <ticket>` — the human gate. Placed at the INPUT, not the output.
#
# Refuses unless stdin is a terminal. An agent's Bash tool is not a terminal, so
# this is a real capability boundary — the closest thing to a human-presence
# oracle available. The same guard runs in cmd_init.sh:131.
aif_cmd_approve() {
  local ticket="${1:-}"
  [ -n "$ticket" ] || aif_die "usage: aif approve <ticket>"

  local root work spec meta hash approver out rc
  root="$(aif_require_project)"
  work="$root/.aif/work/$ticket"
  spec="$work/spec.md"

  [ -f "$spec" ] || aif_die "no spec.md for $ticket — nothing to approve"

  if [ ! -t 0 ]; then
    aif_die "approval must be given at a terminal — this is the human gate, and stdin is not a TTY"
  fi

  # Never approve a malformed spec: the human decides on completeness and
  # assumptions, not on whether the criteria are shaped right — that is the
  # machine's job, and it runs first.
  rc=0
  out="$(_aif_gate "$root" "spec-form" "$work")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    aif_err "spec.md does not pass spec-form — fix it before approving:"
    printf '%s\n' "$out" | sed 's/^/  /' >&2
    return 1
  fi

  meta="$(aif_meta_json "$spec")"
  hash="$(aif_sha256 "$spec")"

  # Bound decision: the AC list and, explicitly, the assumptions — everything
  # the spec decided that the ticket did not say. Five items to weigh, not three
  # pages to skim. The question is "is anything missing", not "is this right".
  printf '\n%s%s%s — acceptance criteria\n\n' "$AIF_C_BOLD" "$ticket" "$AIF_C_RESET"
  printf '%s' "$meta" | jq -r '.acceptance[] | "  \(.id)  \(.then) → \(.expect|tostring)"'

  local n_assume
  n_assume="$(printf '%s' "$meta" | jq '.assumptions | length')"
  if [ "$n_assume" -gt 0 ]; then
    printf '\n%sassumptions the spec made that the ticket did not state:%s\n\n' \
      "$AIF_C_YELLOW" "$AIF_C_RESET"
    printf '%s' "$meta" | jq -r '.assumptions[] | "  \(.id)  \(.text)"'
  fi

  printf '\n%sIs anything missing, and do you accept these assumptions? [y/N] %s' \
    "$AIF_C_BOLD" "$AIF_C_RESET"
  local answer
  read -r answer || aif_die "cancelled"
  case "$answer" in
    y | Y | yes | Yes) ;;
    *) aif_die "not approved" ;;
  esac

  approver="$(git -C "$root" config user.name 2>/dev/null || true)"
  [ -n "$approver" ] || approver="${USER:-unknown}"

  jq -n \
    --arg s "$hash" --arg a "$approver" \
    --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson assumptions "$(printf '%s' "$meta" | jq -c '[.assumptions[]?.id]')" \
    '{ schema: 1, subject: "spec.md", subject_sha256: $s,
       approver: $a, at: $at, tty: true, approved_assumptions: $assumptions }' \
    >"$work/approval.json.tmp" && mv "$work/approval.json.tmp" "$work/approval.json"

  aif_ledger_append "$work" "$(jq -n --arg s "$hash" --arg a "$approver" \
    '{ event: "approve", subject: "spec.md", subject_sha256: $s, approver: $a }')"

  printf '\n%sapproved%s by %s — bound to this spec; edit spec.md and it lapses.\n' \
    "$AIF_C_GREEN" "$AIF_C_RESET" "$approver"
}
