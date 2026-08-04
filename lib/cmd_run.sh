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
#   - the human steps are an interactive `claude` (the /aif-ticket interview, the
#     /aif-fix repair bench, and the aif approve prompt);
#   - the machine steps reuse `aif station run` verbatim.
# It MUST run outside a claude session: a station spawns `claude -p`, and a
# `claude -p` nested in a claude session cannot authenticate (docs/FINDINGS.md
# #7). `aif approve` already needs a TTY, so "real terminal only" is a rule the
# pipeline already carried — this command just states it up front.
#
# There are no silent branches. Every path through this file either opens claude
# where a human is wanted or says out loud what it is doing, because a command
# that sometimes talks to you and sometimes does not is unreadable from outside.
#
# It calls _aif_station_run (cmd_station.sh) and aif_cmd_approve /
# _aif_ticket_create / _aif_ticket_status / _aif_gate (cmd_ticket.sh) in-process,
# so bin/aif sources both alongside this file.

# How many times a rejected artifact goes back to the repair bench before we
# stop and hand the problem over. Past this, re-opening the same session is not
# converging — it is grinding, and the user should hear that plainly.
AIF_RUN_REPAIR_MAX=3

_aif_run_usage() {
  cat <<EOF
usage: aif run <ticket> [seed] [--profile P]

  Drive one ticket through the whole pipeline, with the human where a human
  belongs:

    ticket (interview) -> spec -> approve -> plan -> tests -> code

  seed  optional: a Jira/Trello/issue link or a sentence, handed to the
        /aif-ticket interview as its starting point. A link is pulled by a
        configured MCP connector — that is the user's to set up.

  The interview always opens; confirm the ticket there and exit to continue.
  If a gate rejects an artifact, /aif-fix opens on it rather than stopping.

  Run it from a REAL TERMINAL, never inside a claude session: the stations
  spawn 'claude -p', which cannot authenticate when nested (FINDINGS #7).
EOF
}

# _aif_run_ticket_ready <work> — true once ticket.md holds a real ticket rather
# than the stub `aif create-ticket` writes. The stub carries a fixed instruction
# line; the moment the interview (or a human) replaces it with narrative, it is
# gone.
# A cheap proxy, not a validator — the spec station and its gate judge the rest.
_aif_run_ticket_ready() {
  local tm="$1/ticket.md"
  [ -f "$tm" ] || return 1
  ! grep -q "Describe the need in your own words" "$tm" 2>/dev/null
}

# _aif_run_claude <root> <prompt> <profile> — hand the terminal to an interactive
# claude, then return so the pipeline can go on.
#
# Interactive, not `claude -p`, so it authenticates the ordinary way. Wrapped in
# a subshell: the profile's exported routing stays inside, so one step cannot
# contaminate the next.
#
# The human's exit status is not ours to interpret — quitting claude is not an
# error. Whether the step achieved anything is decided by looking at the
# artifact afterwards, never by this return code.
_aif_run_claude() {
  local root="$1" prompt="$2" profile="$3"
  (
    aif_profile_load "$profile"
    # shellcheck source=lib/runner_claude.sh
    . "$AIF_ROOT/lib/runner_claude.sh"
    aif_profile_export_env
    "aif_runner_${AIF_PROFILE_RUNNER}_converse" "$root" "$prompt" || true
  )
}

_aif_run_station_meta() {
  # <root> <station> — the station's aif:meta JSON.
  aif_meta_json "$1/.aif/stations/$2.md"
}

_aif_run_gates_of() {
  # <root> <station> — the gates this station's output is checked by, one per
  # line. Same resolution order as cmd_station.sh: .gates wins over .form_gate.
  _aif_run_station_meta "$1" "$2" |
    jq -r 'if .gates then .gates[] elif .form_gate then .form_gate else empty end'
}

# _aif_run_gates_verdict <root> <station> <ticket>
#
# Re-run every gate of a station against current bytes. Echoes the first
# rejecting gate's output; rc 0 iff all of them pass. This is how the
# orchestrator learns whether a failure is a REJECTED ARTIFACT (which a human at
# the repair bench can fix) rather than a broken run — exit codes alone cannot
# tell those apart, since both leave the station returning non-zero.
_aif_run_gates_verdict() {
  local root="$1" station="$2" ticket="$3"
  local work gate gp rc out
  work="$(aif_task_dir "$root" "$ticket")"

  while IFS= read -r gate; do
    [ -n "$gate" ] || continue
    gp="$root/.aif/gates/$gate.sh"
    [ -f "$gp" ] || continue
    rc=0
    out="$(/bin/bash "$gp" "$work" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      printf '%s\n' "$out"
      return "$rc"
    fi
  done <<EOF
$(_aif_run_gates_of "$root" "$station")
EOF
  return 0
}

# _aif_run_record_gates <root> <station> <ticket>
#
# Record a post-repair gate pass in the ledger, bound to the repaired bytes.
# Without this the ledger's last word on the gate is the rejection, and the
# ledger is meant to be the complete record of what happened — including that a
# human fixed the artifact by hand and the gate then passed against it.
_aif_run_record_gates() {
  local root="$1" station="$2" ticket="$3"
  local work meta produces freezes subject hash gate gp
  work="$(aif_task_dir "$root" "$ticket")"

  meta="$(_aif_run_station_meta "$root" "$station")"
  produces="$(printf '%s' "$meta" | jq -r '.produces // empty')"
  freezes="$(printf '%s' "$meta" | jq -r '.freezes // empty')"

  # Bind to what the station froze when it names one, exactly as cmd_station.sh
  # does, so a downstream precondition can still find its subject.
  subject="$produces"
  if [ -n "$freezes" ] && [ -f "$work/$freezes" ]; then
    subject="$freezes"
  fi
  hash=""
  if [ -n "$subject" ] && [ -f "$work/$subject" ]; then
    hash="$(aif_sha256 "$work/$subject")"
  fi

  while IFS= read -r gate; do
    [ -n "$gate" ] || continue
    gp="$root/.aif/gates/$gate.sh"
    [ -f "$gp" ] || continue
    aif_ledger_gate "$work" "$gate" "pass" "$subject" "$hash" \
      "$(aif_sha256 "$gp")" "repaired at the bench, gate re-run"
  done <<EOF
$(_aif_run_gates_of "$root" "$station")
EOF
}

# _aif_run_step <root> <station> <ticket> <profile>
#
# Run one station, and when its gate rejects the artifact, open the repair bench
# on it instead of stopping. rc 0 once the station's gates pass.
#
# The station runs in a subshell because _aif_station_run reports hard failures
# with aif_die, which exits — un-subshelled, an authentication error three
# stations in would kill the orchestrator mid-pipeline with no chance to react.
_aif_run_step() {
  local root="$1" station="$2" ticket="$3" profile="$4"
  local rc gout round

  rc=0
  (_aif_station_run "$root" "$station" "$ticket" "$profile") || rc=$?
  [ "$rc" -eq 0 ] && return 0

  # Non-zero. Ask the gates what they think of the artifact as it now stands: a
  # rejection is repairable with a human, anything else is not this bench's job.
  rc=0
  gout="$(_aif_run_gates_verdict "$root" "$station" "$ticket")" || rc=$?
  if [ "$rc" -eq 0 ]; then
    # The gates are happy, so the station failed for some other reason — its own
    # message is already on screen and is the honest one to act on.
    return 1
  fi
  if [ "$rc" -eq 3 ]; then
    aif_err "$station: a gate could not render a verdict — that is the environment, not the artifact:"
    printf '%s\n' "$gout" | sed 's/^/  /' >&2
    return 1
  fi

  round=0
  while [ "$round" -lt "$AIF_RUN_REPAIR_MAX" ]; do
    round=$((round + 1))
    printf '\n%s%s rejected%s — opening /aif-fix (round %s of %s)\n' \
      "$AIF_C_YELLOW" "$station" "$AIF_C_RESET" "$round" "$AIF_RUN_REPAIR_MAX" >&2
    printf '%s\n' "$gout" | sed 's/^/  /' >&2
    printf '%sfix it with the agent, then exit claude to continue%s\n\n' \
      "$AIF_C_DIM" "$AIF_C_RESET" >&2

    _aif_run_claude "$root" "/aif-fix $ticket $station" "$profile"

    rc=0
    gout="$(_aif_run_gates_verdict "$root" "$station" "$ticket")" || rc=$?
    if [ "$rc" -eq 0 ]; then
      _aif_run_record_gates "$root" "$station" "$ticket"
      printf '%s✓%s %s: gates pass after repair\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$station"
      return 0
    fi
  done

  aif_err "$station is still rejected after $AIF_RUN_REPAIR_MAX repair rounds:"
  printf '%s\n' "$gout" | sed 's/^/  /' >&2
  aif_err "this is usually the ticket, not the artifact — amend tasks/$ticket/ticket.md and re-run 'aif run $ticket'."
  return 1
}

_aif_run() {
  local root="$1" ticket="$2" seed="$3" profile="$4"

  [ -n "$ticket" ] || {
    _aif_run_usage >&2
    aif_die "usage: aif run <ticket> [seed]"
  }

  # A real terminal, stated up front. The interview, the repair bench and the
  # approval all need one, and aif approve would refuse anyway — fail now, with
  # the reason, rather than three stations deep.
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

  # Preflight the runner once, loudly, here — the interactive steps run inside
  # subshells where an aif_die would be swallowed into a silent no-op.
  aif_profile_load "$profile"
  # shellcheck source=lib/runner_claude.sh
  . "$AIF_ROOT/lib/runner_claude.sh"
  "aif_runner_${AIF_PROFILE_RUNNER}_available" ||
    aif_die "runner '$AIF_PROFILE_RUNNER' is not installed"
  if [ -n "$AIF_PROFILE_SECRET_VAR" ] && [ -z "$(aif_profile_secret)" ]; then
    aif_die "$AIF_PROFILE_SECRET_VAR is not set — export it to use profile '$profile'"
  fi

  local work
  work="$(aif_task_dir "$root" "$ticket")"

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
      _aif_ticket_create "$root" "$ticket" >/dev/null
    fi

    # The interview ALWAYS opens. Whether the existing ticket needs work is a
    # judgement, and the agent makes it with the user in front of the ticket —
    # deciding it out here, from a grep, is how a command becomes unreadable:
    # one invocation talks to you, the next silently does not.
    _aif_run_claude "$root" "/aif-ticket $ticket $seed" "$profile"
    _aif_run_ticket_ready "$work" ||
      aif_die "no ticket written for $ticket — the interview produced none, so there is nothing to spec."

    # ---- the spec <-> approve loop ---------------------------------------
    # Reject is not "go back": aif approve appends the reason to the ticket and
    # the spec runs again against it. The human ends the loop by approving, so it
    # has no fixed cap — that call is theirs, not a counter's.
    while :; do
      _aif_run_step "$root" "spec" "$ticket" "$profile" ||
        aif_die "cannot get an admissible spec for $ticket — see above."
      _aif_run_step "$root" "spec-judge" "$ticket" "$profile" ||
        aif_die "spec-judge blocked $ticket — see above."

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
  # The human approved the WHAT; the rest is the machine's to build, stopping at
  # the repair bench whenever a gate rejects what it produced.
  local st
  for st in plan plan-judge tests implement; do
    _aif_run_step "$root" "$st" "$ticket" "$profile" ||
      aif_die "$st did not get past its gate for $ticket — see above. The approved spec stands; fix and re-run 'aif run $ticket'."
  done

  printf '\n%sdone%s — %s ran to code. Review the branch.\n\n' \
    "$AIF_C_GREEN" "$AIF_C_RESET" "$ticket"
  _aif_ticket_status "$root" "$ticket"
}

aif_cmd_run() {
  case "${1:-}" in
    -h | --help | "")
      _aif_run_usage
      return 0
      ;;
  esac

  local ticket="" seed="" profile=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile)
        shift
        profile="${1:-}"
        ;;
      -h | --help)
        _aif_run_usage
        return 0
        ;;
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
