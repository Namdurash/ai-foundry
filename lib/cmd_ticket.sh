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

# `aif _ticket-init <ticket>` — create tasks/<ticket>/ with the ticket's stub.
#
# Not a bare mkdir: it validates the id against the project's pattern. It
# writes no ledger. It used to, and the empty file, committed with the ticket
# in the developer's checkout, met the one the worker had filled on the
# ticket's branch as an add/add conflict at land — on aif/OPES-74 the only file
# the merge stopped on, the code merging clean (docs/DEFECTS.md 13.2). The
# worker makes the ledger at intake, and not in git at all: in the main
# checkout's .aif/state/ledgers/ (13.13).
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
  "rules": [],
  "acceptance": [],
  "open": [],
  "decided": [],
  "verification_gaps": [],
  "non_goals": [] }
-->

<!-- Describe the need in your own words. Set lang and risk in the block above.
     risk drives the implementation tier: low and medium run on the routine
     engine, high on the careful one.
     rules[] holds the business rules, one sentence each — the size cap counts
     these; acceptance[] holds the GIVEN / WHEN / THEN examples of each rule,
     every one naming its rule, which the code is built to;
     open[] holds the questions still unanswered, each with a proposed default;
     /aif-ba fills all of this in with you, and aif _ready says when it is
     buildable. -->
EOF

  printf '%screated%s %s/%s/\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$AIF_TASKS_DIR" "$ticket"
}

# `aif _ready <ticket>` — the Definition of Ready, as the analyst sees it.
#
# A thin wrapper over the installed `ready` gate — the SAME script the worker
# runs at intake (`lib/cmd_work.sh`), so the two cannot disagree. Prints the
# gate's own words: a pass with what was decided by default, or one reason per
# line, each of which is the next question to put to the human.
#
# rc 0 ready · 1 not ready · 3 the environment: the gate could not run, or is
# not installed here.
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
      # The environment, as a gate that cannot run is (3 below), not a
      # ticket that is not ready: a caller that reads the code — the shift's
      # facts read 0 ready, 1 not, 3 the environment — took the 1 aif_die
      # exits with for "not ready", offered no pull, and said nothing of why
      # (docs/DEFECTS.md 15.9).
      aif_err "the ready gate is not installed in this project — run 'aif init'"
      return 3
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
