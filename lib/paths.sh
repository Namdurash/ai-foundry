#!/usr/bin/env bash
#
# Locating the project we are operating on, and the paths aif owns.
# Sourced by bin/aif; not meant to be executed directly.

# Where the active profile is recorded, relative to the project root. Ours, not
# Claude Code's, and gitignored: the set is a shared team asset, the model choice
# is per-developer.
#
# Read by cmd_init and cmd_start, which a linter reading this file alone cannot
# see.
# shellcheck disable=SC2034
AIF_PROFILE_STATE=".aif/profile.local"

# Where a ticket's artifacts live, relative to the project root.
#
# At the root, not under .aif/, and that is a deliberate split: .aif/ holds what
# `aif init` installed and `aif uninstall` may remove (project.json, gates,
# agents, hooks), while tasks/ holds the project's own work — tickets, specs,
# plans, ledgers. Uninstalling the foundry must never take the record of what it
# built with it.
#
# Committed, not ignored: git is the real tamper-evidence behind the ledger's
# hash chain (see lib/ledger.sh).
# shellcheck disable=SC2034
AIF_TASKS_DIR="tasks"

# Where the product partner's requests live, relative to the project root.
#
# Parallel to tasks/, and deliberately not inside it: a request is what a
# human decided is worth wanting, before any ticket exists. It has no id, no
# ledger, no gate and nothing derives from it — the analyst reads one and cuts
# tickets from it. Committed, like tasks/: it is the record of why the work
# exists.
# shellcheck disable=SC2034
AIF_REQUESTS_DIR="requests"

# aif_task_dir <root> <ticket> — where this ticket's artifacts live.
#
# One place, because the path is dereferenced by the CLI, the gates, the
# stations' prompts and the skills; when it was spelled out at each site, moving
# it meant finding seventeen of them.
aif_task_dir() {
  printf '%s/%s/%s' "$1" "$AIF_TASKS_DIR" "$2"
}

# aif_current_ticket_file <root> — which ticket this session is working on.
#
# The metering hook needs a ticket and the SubagentStop payload does not carry
# one: it knows the agent, the transcript and the cwd, but nothing about the
# foundry. This pointer supplies it.
#
# Written by `aif work` at intake, which is the moment the ticket id is first
# certain — a run may have been handed nothing at all and taken the top of the
# board's Ready column. The worker itself meters from each station's own
# envelope and does not read this; it is for a session that spawns an aif-*
# subagent of its own, where the SubagentStop payload carries an agent and a
# transcript but nothing about which ticket they belong to.
#
# Session-local and gitignored: it says where one developer is, not anything
# about the project.
aif_current_ticket_file() {
  printf '%s/.aif/state/current' "$1"
}

# aif_station_file <root> <station> — the file declaring a pipeline station.
#
# A station is a SUBAGENT, so its file lives where the runner looks for agents
# (.claude/agents/aif-<station>.md), not in a private .aif/stations/ the runner
# cannot see. One file now carries both readers: YAML frontmatter for the runner
# (name, tools, model) and the aif:meta block for aif (tier, produces, gates,
# preconditions). aif_meta_body strips everything up to the meta block's close,
# so the frontmatter never leaks into the system prompt.
#
# The station's own name, not the agent's: callers say "spec", the aif- prefix
# is this function's business.
aif_station_file() {
  printf '%s/.claude/agents/aif-%s.md' "$1" "$2"
}

# aif_runner_config_dir <profile> — an isolated runner config root for a profile.
#
# Deliberately outside the project. This becomes CLAUDE_CONFIG_DIR, which holds
# sessions and credentials; that is per-user state, and putting credentials
# inside a repository is how they get committed.
aif_runner_config_dir() {
  printf '%s/aif/runners/%s' "${XDG_DATA_HOME:-$HOME/.local/share}" "$1"
}

# aif_project_root — nearest ancestor containing .git, rc 1 if none.
#
# git is required rather than falling back to cwd: this is a tool for putting a
# project on AI SDLC rails, the foundry set is meant to be committed, and half
# the safety here (knowing what we own, keeping secrets out of the index) is
# meaningless without it. Failing loudly beats scaffolding into a directory the
# user did not mean.
aif_project_root() {
  local dir
  dir="$(pwd -P)"
  while [ "$dir" != "/" ]; do
    # -e, not -d: in a git WORKTREE .git is a file pointing at the main
    # repository, and a directory test would walk straight past the checkout
    # `aif work` is running in and resolve every path to the developer's tree.
    if [ -e "$dir/.git" ]; then
      printf '%s' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

# aif_main_root <root> — the main checkout's root when <root> is a git
# worktree; <root> itself otherwise.
#
# The local board lives here and nowhere else: a move made from inside the
# worktree `aif work` runs in has to land on the board the developer is
# looking at, not on a copy that lives and dies with the branch. The git
# common dir is the one thing every worktree of a repository shares.
aif_main_root() {
  local common
  common="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || {
    printf '%s' "$1"
    return 0
  }
  case "$common" in
    /*) ;;
    *) common="$1/$common" ;;
  esac
  common="$(cd "$common" 2>/dev/null && pwd -P)" || {
    printf '%s' "$1"
    return 0
  }
  dirname "$common" | tr -d '\n'
}

aif_require_project() {
  local root
  root="$(aif_project_root)" || aif_die "not a git repository — run 'git init' first"
  printf '%s' "$root"
}

# aif_prune_empty_dirs <root> <relpath> — remove directories left empty by our
# own removal, walking up to the project root.
#
# rmdir refuses a non-empty directory, which is exactly the guard wanted: the
# moment we reach a directory holding anything else, we stop. Shared by init
# (retiring a file the set no longer ships) and uninstall (removing them all),
# because two copies of this would eventually disagree about where to stop.
aif_prune_empty_dirs() {
  local root="$1" rel="$2" dir
  dir="$(dirname "$root/$rel")"
  while [ "$dir" != "$root" ] && [ "$dir" != "/" ]; do
    rmdir "$dir" 2>/dev/null || break
    dir="$(dirname "$dir")"
  done
}

# aif_sha256 <file> — hex digest, empty if no digest tool is available.
# macOS ships shasum; most Linux images ship sha256sum; some have both.
aif_sha256() {
  if aif_have shasum; then
    shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
  elif aif_have sha256sum; then
    sha256sum "$1" 2>/dev/null | cut -d' ' -f1
  else
    printf ''
  fi
}

# aif_sha256_stdin — digest of stdin. Used to hash a canonical JSON string
# without a temp file, e.g. the ledger's per-entry chain.
aif_sha256_stdin() {
  if aif_have shasum; then
    shasum -a 256 | cut -d' ' -f1
  elif aif_have sha256sum; then
    sha256sum | cut -d' ' -f1
  else
    printf ''
  fi
}

# aif_tmpfile <target> — a temp file beside the target.
#
# Beside, not in $TMPDIR, so that the mv is a rename within one filesystem and
# therefore atomic. A settings.json half-written by a crash is unrecoverable for
# the user; a leftover temp file is not.
aif_tmpfile() {
  local dir
  dir="$(dirname "$1")"
  mktemp "$dir/.aif-tmp-XXXXXX"
}
