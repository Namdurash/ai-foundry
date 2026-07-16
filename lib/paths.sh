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
    if [ -d "$dir/.git" ]; then
      printf '%s' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

aif_require_project() {
  local root
  root="$(aif_project_root)" || aif_die "not a git repository — run 'git init' first"
  printf '%s' "$root"
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
