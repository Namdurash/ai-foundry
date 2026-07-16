#!/usr/bin/env bash
#
# `aif doctor` — report what is installed and what aif can therefore drive.
# Read-only. Sourced by bin/aif; not meant to be executed directly.

_aif_doctor_runners() {
  printf '%sRunners%s\n' "$AIF_C_BOLD" "$AIF_C_RESET"

  local r path ver mark
  for r in $AIF_RUNNERS; do
    path="$(aif_runner_path "$r")"
    if [ -n "$path" ]; then
      ver="$(aif_runner_version "$r")"
      mark="$(aif_ok)"
      printf '  %s %-10s %-26s %s%s%s\n' \
        "$mark" "$r" "${ver:-?}" "$AIF_C_DIM" "$path" "$AIF_C_RESET"
    else
      mark="$(aif_no)"
      printf '  %s %-10s %snot installed%s\n' \
        "$mark" "$r" "$AIF_C_DIM" "$AIF_C_RESET"
    fi
  done
}

_aif_doctor_tooling() {
  printf '\n%sTooling%s\n' "$AIF_C_BOLD" "$AIF_C_RESET"

  # bash is special: what matters is the interpreter running us, not whatever
  # `bash` on PATH happens to be. aif targets 3.2, so this is informational.
  printf '  %s %-10s %s\n' "$(aif_ok)" "bash" "${BASH_VERSION:-?}"

  local t ver
  for t in jq git; do
    if aif_have "$t"; then
      ver="$("$t" --version 2>/dev/null | head -1 | tr -d '\r\n')"
      printf '  %s %-10s %s\n' "$(aif_ok)" "$t" "${ver:-?}"
    else
      printf '  %s %-10s %snot installed%s\n' \
        "$(aif_no)" "$t" "$AIF_C_DIM" "$AIF_C_RESET"
    fi
  done
}

aif_doctor() {
  printf '%saif %s%s\n\n' "$AIF_C_BOLD" "$AIF_VERSION" "$AIF_C_RESET"

  _aif_doctor_runners
  _aif_doctor_tooling

  printf '\n'

  local available
  available="$(aif_runners_available)"
  if [ -z "$available" ]; then
    aif_warn "no agentic CLI found — aif has nothing to drive"
    printf '      %sInstall one, e.g.: brew install --cask claude-code%s\n' \
      "$AIF_C_DIM" "$AIF_C_RESET"
    return 1
  fi

  printf 'aif can drive:%s\n' "$(printf ' %s' "$available")"

  if ! aif_have jq; then
    aif_warn "jq is missing — init and test will need it"
    return 1
  fi

  return 0
}
