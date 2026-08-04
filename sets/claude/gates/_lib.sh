#!/usr/bin/env bash
#
# Shared helpers for gate scripts.
#
# Gates run in CI from a fresh checkout, where `aif` is not installed, so this
# file deliberately duplicates a little of lib/common.sh rather than sourcing
# it. A gate that needs the tool that installed it is not a gate on the
# artifact, it is a gate on the toolchain.
#
# Targets bash 3.2: no associative arrays, no ${var,,}, no mapfile.

# Exit codes are the contract, and the 1/3 split drives the state machine:
#   0  the artifact passes
#   1  the artifact is rejected — fix it and retry
#   3  the gate could not run — stop looping, something upstream is broken
#
# AIF_G_PASS is documentation for whoever writes the next gate; nothing exits
# with a variable when the answer is a plain 0.
# shellcheck disable=SC2034
AIF_G_PASS=0
AIF_G_REJECT=1
AIF_G_ERROR=3

aif_g_reject() {
  printf 'REJECT %s\n' "$*" >&2
  exit "$AIF_G_REJECT"
}

aif_g_error() {
  printf 'ERROR  %s\n' "$*" >&2
  exit "$AIF_G_ERROR"
}

aif_g_need() {
  command -v "$1" >/dev/null 2>&1 || aif_g_error "required tool not found: $1"
}

# aif_g_have <command> — true if present. Gates cannot use lib/common.sh's
# aif_have (they run in CI without aif), and a call to a missing function fails
# silently under set +e — which is how an optional tool check turns into a quiet
# downgrade. Use this for optional tools like python3.
aif_g_have() {
  command -v "$1" >/dev/null 2>&1
}

aif_g_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | cut -d' ' -f1
  else
    aif_g_error "no sha256 tool (shasum or sha256sum)"
  fi
}

# aif_g_meta <file> — the JSON out of the FIRST aif:meta HTML comment.
#
# The metadata lives inside the markdown rather than beside it so that one
# artifact has exactly one hash. An HTML comment keeps it invisible wherever
# markdown is rendered.
#
# Only the first block: an artifact body may quote the format, and matching
# every block would concatenate them into invalid JSON. Kept identical to
# aif_meta_json in lib/common.sh.
aif_g_meta() {
  awk '
    /^<!-- aif:meta$/ && !seen { inblock = 1; seen = 1; next }
    inblock && /^-->$/         { inblock = 0; next }
    inblock                    { print }
  ' "$1"
}

# aif_g_meta_or_die <file> <label> — extract and validate in one step, since
# every caller wants both and a bad parse must be an ERROR (the gate cannot
# run), never a REJECT.
aif_g_meta_or_die() {
  local file="$1" label="$2"
  local meta

  [ -f "$file" ] || aif_g_reject "$label: file not found: $file"
  [ -s "$file" ] || aif_g_reject "$label: file is empty: $file"

  meta="$(aif_g_meta "$file")"
  if [ -z "$meta" ]; then
    aif_g_reject "$label: no <!-- aif:meta ... --> block"
  fi

  # Report the parse error verbatim. A retry is only productive if the model is
  # told which line broke.
  if ! printf '%s' "$meta" | jq -e . >/dev/null 2>&1; then
    printf 'REJECT %s: meta block is not valid JSON\n' "$label" >&2
    printf '%s' "$meta" | jq . 2>&1 | head -3 >&2
    exit "$AIF_G_REJECT"
  fi

  printf '%s' "$meta"
}

# aif_g_project <work-dir> — path to project.json, walking up from the work dir.
#
# Gates are handed a work dir but their configuration lives at the project root,
# and neither the depth of tasks/<ticket>/ nor the caller's cwd is guaranteed.
# Walking up rather than hopping a fixed number of levels is what let the work
# dir move out of .aif/ without touching this function.
aif_g_project() {
  local dir
  dir="$(cd "$1" 2>/dev/null && pwd -P)" || aif_g_error "no such work dir: $1"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/.aif/project.json" ]; then
      printf '%s' "$dir/.aif/project.json"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  aif_g_error ".aif/project.json not found — run 'aif project init'"
}

# aif_g_report <violations> <label> — reject with a numbered list, or pass.
#
# Every violation is printed, never just the first. A gate that reports one
# problem per run turns a fix into a guessing game and burns a station attempt
# per line.
aif_g_report() {
  local violations="$1" label="$2"
  local count

  if [ -z "$violations" ]; then
    return 0
  fi

  count="$(printf '%s\n' "$violations" | grep -c .)"
  printf 'REJECT %s: %s problem(s)\n' "$label" "$count" >&2
  # Drop blank lines: an accumulator that prepends "\nMSG" leaves a leading
  # empty that would otherwise print as a bare bullet.
  printf '%s\n' "$violations" | sed '/^[[:space:]]*$/d; s/^/  - /' >&2
  exit "$AIF_G_REJECT"
}
