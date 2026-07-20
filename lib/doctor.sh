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

# Project health, but only when run inside an initialised project. Two
# silent-failure classes are worth catching here before they cost a station run:
# an invalid project.json (every gate downstream degrades to theatre), and a
# skill pointing `agent:` at an agent that does not exist (which claude silently
# resolves to general-purpose — a quiet tier downgrade on the quality mechanism).
_aif_doctor_project() {
  local root config
  root="$(aif_project_root 2>/dev/null)" || return 0
  [ -d "$root/.aif" ] || return 0

  printf '\n%sProject%s  %s%s%s\n' "$AIF_C_BOLD" "$AIF_C_RESET" "$AIF_C_DIM" "$root" "$AIF_C_RESET"

  config="$(aif_project_config "$root")"
  if [ ! -f "$config" ]; then
    printf '  %s %-14s %snot set up — run: aif project init%s\n' \
      "$(aif_no)" "project.json" "$AIF_C_YELLOW" "$AIF_C_RESET"
  else
    local problems
    problems="$(aif_project_validate "$config")"
    if [ -n "$problems" ]; then
      printf '  %s %-14s invalid:\n' "$(aif_no)" "project.json"
      printf '%s\n' "$problems" | sed 's/^/       /'
    else
      printf '  %s %-14s valid\n' "$(aif_ok)" "project.json"
    fi
  fi

  # Every agent a skill dispatches to must exist, or the fork silently falls
  # back to general-purpose.
  local skills_dir agents_dir missing=0 skill agent_name
  skills_dir="$root/.claude/skills"
  agents_dir="$root/.claude/agents"
  if [ -d "$skills_dir" ]; then
    for skill in "$skills_dir"/*/SKILL.md; do
      [ -f "$skill" ] || continue
      # A skill's frontmatter is YAML, not our meta block, so read the field
      # directly rather than through aif_meta_json.
      agent_name="$(grep -E '^agent:' "$skill" 2>/dev/null | head -1 | sed 's/^agent:[[:space:]]*//' | tr -d '\r')"
      [ -n "$agent_name" ] || continue
      if [ ! -f "$agents_dir/$agent_name.md" ]; then
        printf '  %s %-14s %s → agent "%s" not found\n' \
          "$(aif_no)" "skill target" "$(basename "$(dirname "$skill")")" "$agent_name"
        missing=1
      fi
    done
  fi
  [ "$missing" -eq 0 ] && printf '  %s %-14s all skill agent targets exist\n' "$(aif_ok)" "skill targets"
}

aif_doctor() {
  printf '%saif %s%s\n\n' "$AIF_C_BOLD" "$AIF_VERSION" "$AIF_C_RESET"

  _aif_doctor_runners
  _aif_doctor_tooling
  _aif_doctor_project

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
