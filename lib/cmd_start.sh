#!/usr/bin/env bash
#
# `aif start` — run this project's foundry against its profile.
# Sourced by bin/aif; not meant to be executed directly.
#
# This is the supported entry point for anything other than the default
# provider. Routing is applied by exporting into the child process, which is the
# one mechanism that works on every version and every runner; a settings file
# cannot be relied on for it. See docs/FINDINGS.md #1.
#
# The corollary is worth stating plainly: a bare `claude` in the project is NOT
# on the profile's model. It uses whatever the project already had. That is the
# honest trade for never silently putting you on a model you did not choose.

_aif_start_usage() {
  cat <<EOF
usage: aif start [task] [--profile <name>] [--headless]

  Starts the runner with this project's profile applied.

    aif start                    interactive
    aif start "<task>"           interactive, opening with that task
    aif start --headless "<t>"   one-shot, for scripts and CI

  --profile <name>   override the profile recorded by 'aif init'
  --headless         print the result and exit
EOF
}

aif_cmd_start() {
  local profile="" headless=0 task=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --profile)
        shift
        profile="${1:-}"
        ;;
      --headless)
        headless=1
        ;;
      -h | --help)
        _aif_start_usage
        return 0
        ;;
      --)
        shift
        task="$*"
        break
        ;;
      -*)
        aif_die "unknown option: $1"
        ;;
      *)
        task="$1"
        ;;
    esac
    shift || true
  done

  local root
  root="$(aif_require_project)"

  if [ -z "$profile" ]; then
    if [ -f "$root/$AIF_PROFILE_STATE" ]; then
      profile="$(cat "$root/$AIF_PROFILE_STATE")"
    else
      aif_die "this project has no profile — run 'aif init' first, or pass --profile"
    fi
  fi

  aif_profile_load "$profile"

  # shellcheck source=lib/runner_claude.sh
  . "$AIF_ROOT/lib/runner_claude.sh"

  "aif_runner_${AIF_PROFILE_RUNNER}_available" ||
    aif_die "runner '$AIF_PROFILE_RUNNER' is not installed"

  if [ -n "$AIF_PROFILE_SECRET_VAR" ] && [ -z "$(aif_profile_secret)" ]; then
    aif_die "$AIF_PROFILE_SECRET_VAR is not set — export it to use profile '$profile'"
  fi

  if ! aif_manifest_exists "$root" 2>/dev/null; then
    aif_warn "no foundry set installed here — run 'aif init' to get one"
  fi

  aif_profile_export_env

  if [ "${AIF_PROFILE_ISOLATE_CONFIG:-0}" = "1" ]; then
    CLAUDE_CONFIG_DIR="$(aif_runner_config_dir "$profile")"
    export CLAUDE_CONFIG_DIR
    mkdir -p "$CLAUDE_CONFIG_DIR"
  fi

  # Always say which model this is. The failure this guards against is silent:
  # believing you are on one model while talking to another. One banner line is
  # a cheap price for never wondering.
  printf '%saif%s %s · %s\n' \
    "$AIF_C_DIM" "$AIF_C_RESET" "$profile" "$AIF_PROFILE_DESC" >&2
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    printf '%s    isolated config: %s%s\n' \
      "$AIF_C_DIM" "$CLAUDE_CONFIG_DIR" "$AIF_C_RESET" >&2
  fi

  "aif_runner_${AIF_PROFILE_RUNNER}_start" "$headless" "$task"
}
