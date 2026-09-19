#!/usr/bin/env bash
#
# The ticket lifecycle: scaffold, and the Definition of Ready.
# Sourced by bin/aif; not meant to be executed directly.
#
# Neither is a user-facing command. The analyst skill (/aif-ba) calls both while
# it writes the ticket with the human; the worker calls `_ready` again at
# intake. They stay in bash because each is something a model must not decide:
# where a ticket lives and what it is initialised with, and whether it is
# buildable as it stands.

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

  # Schema 2: the criteria live in the ticket. The analyst writes them WITH the
  # human, in the conversation — the one place the meaning of the ticket is
  # actually known — and the machine builds to them. There is no station
  # between the two that re-derives them blindfolded.
  cat >"$work/ticket.md" <<EOF
<!-- aif:meta
{ "schema": 2, "ticket": "$ticket", "lang": "en", "risk": "medium",
  "surfaces": [],
  "acceptance": [],
  "open": [],
  "decided": [],
  "verification_gaps": [],
  "non_goals": [] }
-->

<!-- Describe the need in your own words. Set lang and risk in the block above.
     risk drives the implementation tier: low and medium run on the routine
     engine, high on the careful one.
     acceptance[] holds the GIVEN / WHEN / THEN criteria the code is built to;
     open[] holds the questions still unanswered, each with a proposed default;
     /aif-ba fills all of this in with you, and aif _ready says when it is
     buildable. -->
EOF

  aif_ledger_init "$work" "$ticket"
  printf '%screated%s %s/%s/\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$AIF_TASKS_DIR" "$ticket"
}

# `aif _ready <ticket>` — the Definition of Ready, as the analyst sees it.
#
# A thin wrapper over the installed `ready` gate — the SAME script the worker
# runs at intake (`lib/cmd_work.sh`), so the two cannot disagree. Prints the
# gate's own words: a pass with what was decided by default, or one reason per
# line, each of which is the next question to put to the human.
aif_cmd_ready() {
  local ticket="${1:-}"
  [ -n "$ticket" ] || aif_die "usage: aif _ready <ticket>"

  local root work out rc=0
  root="$(aif_require_project)"
  work="$(aif_task_dir "$root" "$ticket")"
  [ -d "$work" ] || aif_die "no such ticket: $ticket — scaffold it with: aif _ticket-init $ticket"

  out="$(aif_gate_run "$root" "ready" "$work")" || rc=$?
  case "$rc" in
    0)
      printf '%s✓%s %s\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$out"
      # The path, every time. This is the last command the analyst runs, and a
      # conversation that ends "I created the ticket" without saying where
      # leaves the one concrete thing it produced for the user to go hunting.
      printf '  %s%s/%s/ticket.md%s\n' "$AIF_C_DIM" "$AIF_TASKS_DIR" "$ticket" "$AIF_C_RESET"
      ;;
    127)
      aif_die "the ready gate is not installed in this project — run 'aif init'"
      ;;
    3)
      aif_err "the ready gate could not run — that is the environment, not the ticket:"
      printf '%s\n' "$out" | sed 's/^/  /' >&2
      return 3
      ;;
    *)
      printf '%snot ready%s — %s\n' "$AIF_C_YELLOW" "$AIF_C_RESET" \
        "$(printf '%s' "$out" | head -1 | sed 's/^REJECT ticket.md: //')"
      printf '%s\n' "$out" | tail -n +2 | sed 's/^/  /'
      return 1
      ;;
  esac
}
