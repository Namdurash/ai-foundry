#!/usr/bin/env bash
#
# `aif run <ticket> [seed]` — the whole pipeline in one command, from a real
# terminal. Sourced by bin/aif; not meant to be executed directly.
#
# This is the orchestrator, and it is deliberately thin: it SEQUENCES the human
# touchpoints and the headless stations that already exist, and reimplements
# none of them. The state machine, the gates, the ledger, the tiering and the
# guard hook all still live in `aif station run`; this file only decides the
# order and where a human is asked.
#
# The shape ("architecture C"): aif run is bash and runs from a plain terminal.
#   - the two human steps are an interactive `claude` (the /aif-ticket interview,
#     and the aif approve prompt);
#   - the machine steps reuse `aif station run` verbatim.
# It MUST run outside a claude session: a station spawns `claude -p`, and a
# `claude -p` nested in a claude session cannot authenticate (docs/FINDINGS.md
# #7). `aif approve` already needs a TTY, so "real terminal only" is a rule the
# pipeline already carried — this command just states it up front.
#
# It calls _aif_station_run (cmd_station.sh) and aif_cmd_approve / _aif_work_new
# / _aif_work_status / _aif_gate (cmd_work.sh) in-process, so bin/aif sources
# both alongside this file.

_aif_run_usage() {
  cat <<EOF
usage: aif run <ticket> [seed] [--profile P]

  Drive one ticket through the whole pipeline, with two human stops:

    ticket (interview) -> spec -> approve -> plan -> tests -> code

  seed  optional: a Jira/Trello/issue link or a sentence, handed to the
        /aif-ticket interview as its starting point. A link is pulled by a
        configured MCP connector — that is the user's to set up.

  Run it from a REAL TERMINAL, never inside a claude session: the stations
  spawn 'claude -p', which cannot authenticate when nested (FINDINGS #7).
EOF
}

# _aif_run_ticket_ready <work> — true once ticket.md holds a real ticket rather
# than the stub `aif work new` writes. The stub carries a fixed instruction line;
# the moment the interview (or a human) replaces it with narrative, it is gone.
# A cheap proxy, not a validator — the spec station and its gate judge the rest.
_aif_run_ticket_ready() {
  local tm="$1/ticket.md"
  [ -f "$tm" ] || return 1
  ! grep -q "Describe the need in your own words" "$tm" 2>/dev/null
}

# _aif_run_interview <root> <ticket> <seed> <profile> — hand the terminal to an
# interactive claude running the /aif-ticket analyst, then return so the pipeline
# can go on. Interactive (not `claude -p`), so it authenticates the ordinary way.
_aif_run_interview() {
  local root="$1" ticket="$2" seed="$3" profile="$4"

  aif_profile_load "$profile"
  # shellcheck source=lib/runner_claude.sh
  . "$AIF_ROOT/lib/runner_claude.sh"
  "aif_runner_${AIF_PROFILE_RUNNER}_available" ||
    aif_die "runner '$AIF_PROFILE_RUNNER' is not installed"
  if [ -n "$AIF_PROFILE_SECRET_VAR" ] && [ -z "$(aif_profile_secret)" ]; then
    aif_die "$AIF_PROFILE_SECRET_VAR is not set — export it to use profile '$profile'"
  fi
  aif_profile_export_env

  local prompt="/aif-ticket $ticket"
  [ -n "$seed" ] && prompt="$prompt $seed"

  printf '%sticket%s · interview via /aif-ticket — confirm the ticket, then exit claude to continue\n' \
    "$AIF_C_DIM" "$AIF_C_RESET" >&2

  # || true: the human may quit with a non-zero status, which is not our error.
  # Whether a usable ticket exists is decided by _aif_run_ticket_ready, not here.
  "aif_runner_${AIF_PROFILE_RUNNER}_converse" "$root" "$prompt" || true
}

_aif_run() {
  local root="$1" ticket="$2" seed="$3" profile="$4"

  [ -n "$ticket" ] || { _aif_run_usage >&2; aif_die "usage: aif run <ticket> [seed]"; }

  # A real terminal, stated up front. The interview and the approval both need
  # one, and aif approve would refuse anyway — fail now, with the reason, rather
  # than three stations deep.
  if [ ! -t 0 ]; then
    aif_die "aif run needs a real terminal — it interviews you and asks you to approve. Run it from a plain shell, not inside a claude session or a pipe."
  fi

  local project
  project="$(aif_project_config "$root")"
  [ -f "$project" ] || aif_die "no .aif/project.json — run 'aif project init'"

  # Profile: recorded by init unless overridden. Needed for the station remap and
  # so the interview runs on the same model as the rest of the pipeline.
  if [ -z "$profile" ]; then
    if [ -f "$root/$AIF_PROFILE_STATE" ]; then
      profile="$(cat "$root/$AIF_PROFILE_STATE")"
    else
      aif_die "no profile — run 'aif init' or pass --profile"
    fi
  fi

  local work="$root/.aif/work/$ticket"

  printf '%srun%s %s · profile %s\n' "$AIF_C_BOLD" "$AIF_C_RESET" "$ticket" "$profile" >&2

  # Resume, and protect the one irreversible human artifact: if this spec is
  # already approved (the gate passes against current bytes), do NOT re-run the
  # interview or the spec loop — that would overwrite an approved spec and lapse
  # the approval. Jump straight to the build.
  local approved=0
  if _aif_gate "$root" "spec-approve" "$work" >/dev/null 2>&1; then
    approved=1
  fi

  if [ "$approved" -eq 1 ]; then
    printf '%sspec already approved%s — resuming at the build.\n' "$AIF_C_DIM" "$AIF_C_RESET"
  else
    # ---- touchpoint #1: the ticket ---------------------------------------
    # Create the work dir if new — this also inits the ledger every station
    # records into, so a bare mkdir would not do.
    if [ ! -d "$work" ]; then
      _aif_work_new "$root" "$ticket" >/dev/null
    fi

    # Interview unless a real ticket is already sitting there. A seed always
    # means "start (or redo) the interview from this" — the human asked to feed
    # something in, so honour it even over an existing ticket.
    if [ -n "$seed" ] || ! _aif_run_ticket_ready "$work"; then
      _aif_run_interview "$root" "$ticket" "$seed" "$profile"
      _aif_run_ticket_ready "$work" ||
        aif_die "no ticket written for $ticket — the interview produced none, so there is nothing to spec."
    else
      printf '%susing existing ticket%s .aif/work/%s/ticket.md\n' \
        "$AIF_C_DIM" "$AIF_C_RESET" "$ticket"
    fi

    # ---- the spec <-> approve loop ---------------------------------------
    # Reject is not "go back": aif approve appends the reason to the ticket and
    # the spec runs again against it. The human ends the loop by approving, so it
    # has no fixed cap — that call is theirs, not a counter's.
    while : ; do
      _aif_station_run "$root" "spec" "$ticket" "$profile" ||
        aif_die "spec was rejected by spec-form — that is a malformed spec, not a call you make in prose. Fix spec.md (a later /aif-fix step will help), then re-run."
      _aif_station_run "$root" "spec-judge" "$ticket" "$profile" ||
        aif_die "spec-judge found blockers — resolve them in the ticket, then re-run 'aif run $ticket'."

      local arc=0
      aif_cmd_approve "$ticket" || arc=$?
      case "$arc" in
        0) break ;;
        2) printf '%sreworking%s the spec from your reason…\n' "$AIF_C_YELLOW" "$AIF_C_RESET" ;;
        *) aif_die "approval step failed" ;;
      esac
    done
  fi

  # ---- autonomous: plan -> tests -> code ---------------------------------
  # The human approved the WHAT; the rest is the machine's to build until a gate
  # says otherwise. Any gate reject halts the run with its own message above.
  local st
  for st in plan plan-judge tests implement; do
    _aif_station_run "$root" "$st" "$ticket" "$profile" ||
      aif_die "$st was rejected by its gate (see above). Fix the artifact and re-run 'aif run $ticket' — the approved spec stands."
  done

  printf '\n%sdone%s — %s ran to code. Review the branch.\n\n' \
    "$AIF_C_GREEN" "$AIF_C_RESET" "$ticket"
  _aif_work_status "$root" "$ticket"
}

aif_cmd_run() {
  case "${1:-}" in
    -h | --help | "") _aif_run_usage; return 0 ;;
  esac

  local ticket="" seed="" profile=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile)
        shift
        profile="${1:-}"
        ;;
      -h | --help) _aif_run_usage; return 0 ;;
      -*) aif_die "unknown option: $1" ;;
      *)
        if [ -z "$ticket" ]; then
          ticket="$1"
        elif [ -z "$seed" ]; then
          seed="$1"
        else
          # Allow an unquoted multi-word seed to still arrive whole.
          seed="$seed $1"
        fi
        ;;
    esac
    shift
  done

  local root
  root="$(aif_require_project)"
  _aif_run "$root" "$ticket" "$seed" "$profile"
}
