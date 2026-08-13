#!/usr/bin/env bash
#
# The ticket lifecycle: scaffold, fold a rejection back in, record an approval.
# Sourced by bin/aif; not meant to be executed directly.
#
# None of these are user-facing commands any more. The user's entry point is
# `aif run`, which opens a session; the orchestrator skill inside it calls these.
# They stay in bash rather than moving into the skill because each one either
# writes a binding the gates read, or decides something a model must not.

# `aif _ticket-init <ticket>` — create tasks/<ticket>/ and its ledger.
#
# Not a bare mkdir: it validates the id against the project's pattern and
# initialises ledger.json. A ticket dir without a ledger looks fine until the
# first station tries to record an attempt into a file that is not there.
aif_cmd_ticket_init() {
  local ticket="${1:-}"
  [ -n "$ticket" ] || aif_die "usage: aif _ticket-init <ticket>"

  local root work pattern
  root="$(aif_require_project)"

  pattern="$(jq -r '.ticket_pattern // "^[A-Z]{2,10}-[0-9]+$"' \
    "$(aif_project_config "$root")" 2>/dev/null)"
  if ! printf '%s' "$ticket" | grep -qE "$pattern"; then
    aif_die "ticket '$ticket' does not match $pattern (from project.json)"
  fi

  work="$(aif_task_dir "$root" "$ticket")"
  [ -d "$work" ] && aif_die "$ticket already exists at $AIF_TASKS_DIR/$ticket"

  mkdir -p "$work"

  # The ticket is the human's words, verbatim — the one source of truth the spec
  # is judged against, so it is written by a person and never by a model.
  # risk defaults to medium, never the cheapest tier by omission.
  cat >"$work/ticket.md" <<EOF
<!-- aif:meta
{ "schema": 1, "ticket": "$ticket", "lang": "en", "risk": "medium" }
-->

<!-- Describe the need in your own words. Set lang and risk in the block above.
     risk drives the implementation tier: low and medium run on the routine
     engine, high on the careful one.
     This text is the source of truth the specification is judged against. -->
EOF

  aif_ledger_init "$work" "$ticket"
  printf '%screated%s %s/%s/\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$AIF_TASKS_DIR" "$ticket"
}

# `aif _rework <ticket> <reason>` — fold a rejection back into the ticket.
#
# The spec station reads the whole ticket narrative and nothing else, by
# contract. So a rejection only reaches the next spec if it lands there, as
# prose — not in a side channel the spec never opens. The first rejection opens
# the heading; later ones stack under it, so the spec sees the full history of
# asks rather than only the latest.
aif_cmd_rework() {
  local ticket="${1:-}" reason="${2:-}"
  [ -n "$ticket" ] && [ -n "$reason" ] || aif_die "usage: aif _rework <ticket> <reason>"

  local root tm heading="## Rework requested at approve"
  root="$(aif_require_project)"
  tm="$(aif_task_dir "$root" "$ticket")/ticket.md"
  [ -f "$tm" ] || aif_die "no ticket.md for $ticket to record the rework reason in"

  if ! grep -qF "$heading" "$tm" 2>/dev/null; then
    printf '\n%s\n\n' "$heading" >>"$tm"
  fi
  printf -- '- %s\n' "$reason" >>"$tm"
  printf '%srework noted%s in %s/%s/ticket.md — the spec is redone against it.\n' \
    "$AIF_C_YELLOW" "$AIF_C_RESET" "$AIF_TASKS_DIR" "$ticket"
}

# `aif _approve <ticket> --confirmation <text>` — record the human's acceptance.
#
# The human gate, placed at the INPUT: the question is "is anything missing from
# what this says done means", not "is the code right".
#
# It used to refuse unless stdin was a terminal, on the grounds that an agent's
# Bash tool is not one. That was a genuine capability boundary and it is gone on
# purpose — the human now sits in the session where the approval is asked for,
# and the terminal check blocked the only path they have.
#
# What replaces it is weaker, and is written down as weaker: the confirmation
# text is EVIDENCE, not proof. A model could fabricate it. Requiring it at all is
# the design — an approval that could be recorded with no argument would
# eventually be recorded by accident. See the README's trust assumptions.
aif_cmd_approve() {
  local ticket="" confirmation="" approver="" gaps_confirmation=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --confirmation)
        shift
        confirmation="${1:-}"
        ;;
      --gaps-confirmation)
        shift
        gaps_confirmation="${1:-}"
        ;;
      --by)
        shift
        approver="${1:-}"
        ;;
      -*) aif_die "unknown option: $1" ;;
      *) [ -n "$ticket" ] || ticket="$1" ;;
    esac
    shift
  done

  [ -n "$ticket" ] || aif_die "usage: aif _approve <ticket> --confirmation <the user's words>"
  [ -n "$confirmation" ] ||
    aif_die "refusing to approve without --confirmation: record what the user actually said when they accepted this spec"

  local root work spec meta hash out rc
  root="$(aif_require_project)"
  work="$(aif_task_dir "$root" "$ticket")"
  spec="$work/spec.md"
  [ -f "$spec" ] || aif_die "no spec.md for $ticket — nothing to approve"

  # Never approve a malformed spec. The human decides on completeness and on the
  # assumptions, not on whether the criteria are shaped right — that is the
  # machine's job, and it runs first.
  rc=0
  out="$(aif_gate_run "$root" "spec-form" "$work")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    aif_err "spec.md does not pass spec-form — fix it before approving:"
    printf '%s\n' "$out" | sed 's/^/  /' >&2
    return 1
  fi

  [ -n "$approver" ] || approver="$(git -C "$root" config user.name 2>/dev/null || true)"
  [ -n "$approver" ] || approver="${USER:-unknown}"

  meta="$(aif_meta_json "$spec")"
  hash="$(aif_sha256 "$spec")"

  # A verification gap is not an assumption and must not be accepted as one.
  # "The API is named get/set/delete" and "the target environment is never
  # verified" went into one list on a live ticket, and the human approved both
  # with one keystroke; the second was never referred to again. So the second
  # kind needs its own answer, in the human's own words, or there is nothing to
  # record.
  local gaps
  gaps="$(printf '%s' "$meta" | jq -c '[.verification_gaps[]?.id]')"
  if [ "$(printf '%s' "$gaps" | jq 'length')" -gt 0 ] && [ -z "$gaps_confirmation" ]; then
    aif_err "this spec records verification gaps — things this run will NOT establish:"
    printf '%s' "$meta" | jq -r '.verification_gaps[] | "  ! " + .id + ": " + .text' >&2
    aif_die "ask the user about these separately and pass --gaps-confirmation <their words>; accepting a blind spot is not the same decision as accepting an assumption"
  fi

  jq -n \
    --arg s "$hash" --arg a "$approver" --arg c "$confirmation" \
    --arg gc "$gaps_confirmation" \
    --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson assumptions "$(printf '%s' "$meta" | jq -c '[.assumptions[]?.id]')" \
    --argjson gaps "$gaps" \
    '{ schema: 1, subject: "spec.md", subject_sha256: $s,
       approver: $a, at: $at, channel: "chat", confirmation: $c,
       approved_assumptions: $assumptions,
       acknowledged_gaps: $gaps, gaps_confirmation: $gc }' \
    >"$work/approval.json.tmp" && mv "$work/approval.json.tmp" "$work/approval.json"

  aif_ledger_append "$work" "$(jq -n --arg s "$hash" --arg a "$approver" --arg c "$confirmation" \
    --arg gc "$gaps_confirmation" --argjson gaps "$gaps" \
    '{ event: "approve", subject: "spec.md", subject_sha256: $s,
       approver: $a, channel: "chat", confirmation: $c,
       acknowledged_gaps: $gaps, gaps_confirmation: $gc }')"

  printf '%sapproved%s by %s — bound to this spec; edit spec.md and it lapses.\n' \
    "$AIF_C_GREEN" "$AIF_C_RESET" "$approver"
  if [ "$(printf '%s' "$gaps" | jq 'length')" -gt 0 ]; then
    printf '%sacknowledged%s %s blind spot(s) — re-emitted as a manual checklist at close.\n' \
      "$AIF_C_YELLOW" "$AIF_C_RESET" "$(printf '%s' "$gaps" | jq 'length')"
  fi
}
