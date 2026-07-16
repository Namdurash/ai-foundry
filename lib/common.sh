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
