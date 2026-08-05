#!/usr/bin/env bash
#
# `aif run [<ticket> | <link> | <description>]` — the one pipeline command.
# Sourced by bin/aif; not meant to be executed directly.
#
# It preflights, exports the profile's routing, and hands the terminal to an
# ordinary interactive claude opened on the orchestrator skill. That is all it
# does, and the thinness is the design.
#
# What it replaces: a bash orchestrator that shelled out to `claude -p` once per
# station. That worked and its accounting was honest, but the user could not see
# any of it — a $1.27 planning step reported one line and deleted its own
# reasoning into /dev/null. Now the session IS the pipeline: stations are
# subagents, so their work is visible while it happens, and the state machine
# stays in bash where a model cannot have opinions about it (lib/cmd_state.sh).
#
# The argument is deliberately not parsed here. A ticket id, a board link and a
# sentence are all just the skill's starting point, and only the skill can
# resolve a link — that needs an MCP connector, which is the user's to set up.
# Guessing an id out of a URL in bash would be a second, worse resolver.

_aif_run_usage() {
  cat <<EOF
usage: aif run [<ticket> | <link> | <description>] [--profile P]

  Open the foundry on a ticket. The whole cycle runs in one session:

    ticket (interview) -> spec -> approve -> plan -> tests -> code

  With a ticket id, work resumes wherever that ticket actually stands — the
  state is derived by running the gates, so it cannot be stale.
  With a board link, the id is read off the linked card and matched against
  ${AIF_TASKS_DIR}/; a match resumes, no match starts a new ticket.
  With nothing, the orchestrator asks what you want to work on.
EOF
}

_aif_run() {
  local root="$1" arg="$2" profile="$3"

  local project problems
  project="$(aif_project_config "$root")"
  [ -f "$project" ] || aif_die "no .aif/project.json — run 'aif project init'"

  # Validated here rather than at the first gate that dereferences it. Every gate
  # downstream reads this file to learn how to run the tests; invalid, and they
  # all degrade to theatre — several stations deep, after the money is spent.
  problems="$(aif_project_validate "$project")"
  if [ -n "$problems" ]; then
    aif_err "project.json has problems — the gates read it, so fix these first:"
    printf '%s\n' "$problems" | sed 's/^/  - /' >&2
    return 1
  fi

  if [ -z "$profile" ]; then
    if [ -f "$root/$AIF_PROFILE_STATE" ]; then
      profile="$(cat "$root/$AIF_PROFILE_STATE")"
    else
      aif_die "no profile — run 'aif init' or pass --profile"
    fi
  fi

  # Preflight loudly, before the terminal is handed over. Once claude holds the
  # tty a failure surfaces as a confusing session rather than as a message.
  aif_profile_load "$profile"
  # shellcheck source=lib/runner_claude.sh
  . "$AIF_ROOT/lib/runner_claude.sh"
  "aif_runner_${AIF_PROFILE_RUNNER}_available" ||
    aif_die "runner '$AIF_PROFILE_RUNNER' is not installed"
  if [ -n "$AIF_PROFILE_SECRET_VAR" ] && [ -z "$(aif_profile_secret)" ]; then
    aif_die "$AIF_PROFILE_SECRET_VAR is not set — export it to use profile '$profile'"
  fi

  [ -f "$root/.claude/skills/aif/SKILL.md" ] ||
    aif_die "the orchestrator skill is not installed — run 'aif init'"

  printf '%srun%s · profile %s\n\n' "$AIF_C_BOLD" "$AIF_C_RESET" "$profile" >&2

  # The profile's routing is exported into the child, which is also how each
  # station gets its engine: a subagent declaring `model: opus` resolves to
  # whatever this profile maps opus to. The set stays model-agnostic; the
  # profile decides the provider.
  aif_profile_export_env
  if [ "${AIF_PROFILE_ISOLATE_CONFIG:-0}" = "1" ]; then
    CLAUDE_CONFIG_DIR="$(aif_runner_config_dir "$profile")"
    export CLAUDE_CONFIG_DIR
    mkdir -p "$CLAUDE_CONFIG_DIR"
  fi

  # Marks this session as a foundry run, for the guard hook. Inside a run the
  # orchestrator may not write product code — that is a station's job, and code
  # written outside a station is code no gate ever saw. Outside a run the guard
  # must stay out of the way: a project with aif installed is still an ordinary
  # project, and a plain `claude` in it must not find its Write tool restricted.
  #
  # An exported variable rather than a file, because it has to describe THIS
  # session. A marker on disk would outlive the run and start policing sessions
  # that have nothing to do with the pipeline. Hooks inherit the parent's
  # environment — measured, not assumed.
  AIF_RUN=1
  export AIF_RUN

  cd "$root" || aif_die "cannot enter $root"
  "aif_runner_${AIF_PROFILE_RUNNER}_start" 0 "/aif $arg"
}

aif_cmd_run() {
  local arg="" profile=""
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
        # Everything else is the skill's starting point, rejoined as given so an
        # unquoted sentence still arrives whole.
        if [ -z "$arg" ]; then arg="$1"; else arg="$arg $1"; fi
        ;;
    esac
    shift
  done

  local root
  root="$(aif_require_project)"
  _aif_run "$root" "$arg" "$profile"
}
