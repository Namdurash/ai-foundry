#!/usr/bin/env bash
#
# Shared output helpers and small predicates.
# Sourced by bin/aif; not meant to be executed directly.

# Colour only when stdout is a terminal and NO_COLOR is unset.
# https://no-color.org/
#
# Some of these are consumed only by the modules that source this file, which
# is invisible to a linter reading each file on its own.
# shellcheck disable=SC2034
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  AIF_C_RESET=$'\033[0m'
  AIF_C_BOLD=$'\033[1m'
  AIF_C_DIM=$'\033[2m'
  AIF_C_RED=$'\033[31m'
  AIF_C_GREEN=$'\033[32m'
  AIF_C_YELLOW=$'\033[33m'
else
  AIF_C_RESET=''
  AIF_C_BOLD=''
  AIF_C_DIM=''
  AIF_C_RED=''
  AIF_C_GREEN=''
  AIF_C_YELLOW=''
fi

# Traps are per-process, not per-function: a bare `trap -` anywhere in a
# library takes the CALLER's handler with it. That is not hypothetical — the
# worker's interrupt handler was dead from the first ledger write onwards, and
# had been since the day it was written (docs/DEFECTS-3.md #1).
#
# So a command that needs a handler to outlive the libraries it calls arms it
# here, and a library that needs a trap of its own restores it here afterwards
# rather than clearing the slate.
# shellcheck disable=SC2034  # read by the modules that source this file
AIF_TRAP_ARMED=""

# aif_trap_arm <handler> — run <handler> on EXIT, INT and TERM.
aif_trap_arm() {
  AIF_TRAP_ARMED="$1"
  # shellcheck disable=SC2064  # the handler IS the argument; expanding it now
  trap "$1" EXIT INT TERM
}

# aif_trap_restore — put back whatever was armed, or clear if nothing was.
aif_trap_restore() {
  if [ -n "${AIF_TRAP_ARMED:-}" ]; then
    # shellcheck disable=SC2064  # same: put back the handler, not a reference
    trap "$AIF_TRAP_ARMED" EXIT INT TERM
  else
    trap - EXIT INT TERM
  fi
}

aif_err() {
  printf '%serror:%s %s\n' "$AIF_C_RED" "$AIF_C_RESET" "$*" >&2
}

aif_warn() {
  printf '%swarn:%s %s\n' "$AIF_C_YELLOW" "$AIF_C_RESET" "$*" >&2
}

aif_die() {
  aif_err "$*"
  exit 1
}

# aif_have <command> — true if the command is on PATH.
aif_have() {
  command -v "$1" >/dev/null 2>&1
}

# aif_meta_json <file> — the JSON out of the FIRST aif:meta HTML comment.
#
# Only the first: a station prompt legitimately contains an example aif:meta
# block in its body, and a model's output may echo the format. Matching every
# block would concatenate them into invalid JSON.
#
# The same block the gates read (their copy lives in .aif/gates/_lib.sh, which
# cannot source this file — it runs in CI without aif). Keep the two awk
# programs identical.
aif_meta_json() {
  awk '
    /^<!-- aif:meta$/ && !seen { inblock = 1; seen = 1; next }
    inblock && /^-->$/         { inblock = 0; next }
    inblock                    { print }
  ' "$1"
}

# aif_meta_body <file> — everything after the aif:meta comment closes.
#
# For station files, the meta block carries the config and the body is the
# system prompt.
aif_meta_body() {
  awk 'body { print } /^-->$/ { body = 1 }' "$1"
}

# aif_meta_replace <file> <json> — rewrite the aif:meta block in place.
#
# How `aif _record` stamps a binding into an artifact a model wrote: the model
# owns the content, the tool owns the provenance, and neither has to trust the
# other to copy 64 hex characters correctly (see lib/cmd_record.sh).
#
# The JSON is re-serialised by jq rather than patched textually — a regex over
# someone else's JSON is how a working artifact becomes an unparseable one.
aif_meta_replace() {
  local file="$1" json="$2" tmp
  tmp="$(aif_tmpfile "$file")"
  {
    printf '<!-- aif:meta\n'
    printf '%s' "$json" | jq .
    printf -- '-->\n'
    aif_meta_body "$file"
  } >"$tmp" && mv "$tmp" "$file"
}

# aif_meta_get <file> <key> [default] — read one KEY=VALUE line.
#
# Parsed, never sourced. Sets and evals are the things you eventually accept
# from other people, and sourcing one executes it.
aif_meta_get() {
  local file="$1" key="$2" default="${3:-}"
  local line
  line="$(grep -E "^${key}=" "$file" 2>/dev/null | head -1)" || true
  if [ -z "$line" ]; then
    printf '%s' "$default"
    return 0
  fi
  printf '%s' "${line#*=}"
}

# aif_ok <label> / aif_no <label> — status markers for report output.
# The marker carries the colour so that %-Ns padding elsewhere stays aligned;
# escape sequences inside a padded field would break the column width.
aif_ok() {
  printf '%s✓%s' "$AIF_C_GREEN" "$AIF_C_RESET"
}

aif_no() {
  printf '%s✗%s' "$AIF_C_DIM" "$AIF_C_RESET"
}
