#!/usr/bin/env bash
#
# Profile discovery, loading and environment export.
# Sourced by bin/aif; not meant to be executed directly.
#
# A profile is a (set, runner, model-env) triple living in its own file. Files
# rather than a table in the source because bash 3.2 has no associative arrays —
# and because it means a user can add a profile by dropping in a file, without
# touching our code.

# Where profiles are looked for, in precedence order: a user profile shadows a
# builtin one of the same name.
#
# A project directory is deliberately NOT on this list. Profiles are sourced
# shell, so reading one out of a repository would mean that cloning a hostile
# repo and running `aif init` executes its code. If project-scoped profiles are
# ever wanted, they have to be parsed as data, not sourced.
aif_profile_dirs() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/aif/profiles"
  printf '%s\n' "$AIF_ROOT/profiles"
}

# Clear every profile variable and, critically, the env function.
#
# Without the `unset -f`, a profile that omits aif_profile_env would silently
# inherit the previously loaded profile's environment — which is how you end up
# running GLM's base URL against Anthropic's credentials.
#
# Several of these are read by other modules, which is invisible to a linter
# reading each file on its own.
# shellcheck disable=SC2034
aif_profile_reset() {
  unset -f aif_profile_env 2>/dev/null || true
  AIF_PROFILE_NAME=""
  AIF_PROFILE_DESC=""
  AIF_PROFILE_RUNNER=""
  AIF_PROFILE_SET=""
  AIF_PROFILE_SECRET_VAR=""
  AIF_PROFILE_SECRET_TARGET=""
  AIF_PROFILE_ISOLATE_CONFIG="0"
}

# aif_profile_find <name> — path of the first matching profile, rc 1 if none.
aif_profile_find() {
  local name="$1"
  local dir
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    if [ -f "$dir/$name.profile" ]; then
      printf '%s' "$dir/$name.profile"
      return 0
    fi
  done <<EOF
$(aif_profile_dirs)
EOF
  return 1
}

# Read one field out of a profile without contaminating the caller's shell:
# source it in a subshell and echo the value back.
_aif_profile_field() {
  local file="$1" var="$2"
  (
    aif_profile_reset
    # shellcheck disable=SC1090
    . "$file" >/dev/null 2>&1 || exit 0
    eval "printf '%s' \"\${$var:-}\""
  )
}

# aif_profile_list — "name<TAB>description" per line, user profiles shadowing
# builtins of the same name.
aif_profile_list() {
  local dir file name desc
  local seen=""
  while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    for file in "$dir"/*.profile; do
      [ -f "$file" ] || continue
      name="$(basename "$file" .profile)"
      # Membership test against a space-delimited string: bash 3.2 has no sets.
      case " $seen " in
        *" $name "*) continue ;;
      esac
      seen="$seen $name"
      desc="$(_aif_profile_field "$file" AIF_PROFILE_DESC)"
      printf '%s\t%s\n' "$name" "$desc"
    done
  done <<EOF
$(aif_profile_dirs)
EOF
}

aif_profile_validate() {
  [ -n "$AIF_PROFILE_RUNNER" ] || aif_die "profile '$AIF_PROFILE_NAME': AIF_PROFILE_RUNNER is unset"
  [ -n "$AIF_PROFILE_SET" ] || aif_die "profile '$AIF_PROFILE_NAME': AIF_PROFILE_SET is unset"

  case " $AIF_RUNNERS " in
    *" $AIF_PROFILE_RUNNER "*) ;;
    *) aif_die "profile '$AIF_PROFILE_NAME': unknown runner '$AIF_PROFILE_RUNNER'" ;;
  esac

  if ! type aif_profile_env >/dev/null 2>&1; then
    aif_die "profile '$AIF_PROFILE_NAME': aif_profile_env is not defined"
  fi
}

# aif_profile_load <name> — source a profile into the current shell.
aif_profile_load() {
  local name="$1"
  local file
  file="$(aif_profile_find "$name")" || aif_die "no such profile: $name (try: aif profiles)"

  aif_profile_reset
  # shellcheck disable=SC1090
  . "$file" || aif_die "failed to load profile: $file"
  AIF_PROFILE_NAME="$name"
  aif_profile_validate
}

# aif_profile_secret — the profile's token value, or empty. Never logged.
aif_profile_secret() {
  [ -n "$AIF_PROFILE_SECRET_VAR" ] || return 0
  eval "printf '%s' \"\${$AIF_PROFILE_SECRET_VAR:-}\""
}

# Variables that decide which model answers. A profile owns all of them, and
# they are cleared before one is applied.
#
# Without the clear, a profile only *adds* to whatever is already exported, so a
# leftover ANTHROPIC_BASE_URL from another profile — or just sitting in the
# user's shell — silently wins, and `aif work --profile anthropic` quietly runs
# on something else. A profile has to mean the same thing on every machine or it
# means nothing.
#
# Auth is deliberately absent from this list. The asymmetry is the reason: a
# wrong base URL fails *silently*, by answering from a different model, while a
# wrong token fails loudly with a 401. And the anthropic profile relies on
# ambient credentials by design.
#
# ANTHROPIC_DEFAULT_FABLE_MODEL is the CLI's variable for the `fable` alias
# (read from claude 2.1.226: the alias resolves to it when it is set, as
# `opus` resolves to ANTHROPIC_DEFAULT_OPUS_MODEL) — a profile routes it like
# the other three, and a leftover in the shell routes nothing (docs/DEFECTS.md
# 14.6).
AIF_ROUTING_VARS="ANTHROPIC_BASE_URL
ANTHROPIC_MODEL
ANTHROPIC_DEFAULT_OPUS_MODEL
ANTHROPIC_DEFAULT_SONNET_MODEL
ANTHROPIC_DEFAULT_HAIKU_MODEL
ANTHROPIC_DEFAULT_FABLE_MODEL
ANTHROPIC_SMALL_FAST_MODEL
CLAUDE_CODE_AUTO_COMPACT_WINDOW
API_TIMEOUT_MS"

# aif_profile_export_env — apply the loaded profile to this shell's environment.
#
# Exporting is how routing is applied: it is the one mechanism that works on
# every version and for every runner, and a settings file cannot be relied on
# for it. See docs/FINDINGS.md #1.
aif_profile_export_env() {
  local line key value secret var

  while IFS= read -r var; do
    [ -n "$var" ] || continue
    unset "$var" 2>/dev/null || true
  done <<EOF
$AIF_ROUTING_VARS
EOF

  # A here-doc, not a pipe. In bash 3.2 a piped `while read` runs in a subshell,
  # so every export below would be discarded and the profile would silently do
  # nothing at all.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    export "$key=$value"
  done <<EOF
$(aif_profile_env)
EOF

  if [ -n "$AIF_PROFILE_SECRET_TARGET" ]; then
    secret="$(aif_profile_secret)"
    if [ -n "$secret" ]; then
      export "$AIF_PROFILE_SECRET_TARGET=$secret"
    fi
  fi
}

# aif_profile_maps_model <model> — will the exported profile send this model
# where it can be answered? rc 0 yes · 1 it names an alias the profile leaves
# untranslated. Call it after aif_profile_export_env; it reads only what that
# exported.
#
# An alias (`opus`, `sonnet`, `haiku`, `fable`) is the CLI's word, turned into
# a model id by the CLI itself — or, under a profile that routes to another
# endpoint (ANTHROPIC_BASE_URL set), by the profile's
# ANTHROPIC_DEFAULT_<ALIAS>_MODEL. One the profile does not map is sent as it
# is to an endpoint that never heard of it, and fails there, after a session
# was opened for a person, instead of here (docs/DEFECTS.md 14.6: `fable` under
# glm). So: no base URL — every alias is the CLI's and passes; with one, each
# of the four passes when its variable is set, `opusplan` (opus to plan,
# sonnet to build) when both of those are. `fable` was refused always, the one
# alias no profile variable routed; claude 2.1.226 resolves it through
# ANTHROPIC_DEFAULT_FABLE_MODEL when that is set (read from the binary), so a
# profile that sets it routes fable as the other three. A `[…]` suffix
# (`opus[1m]`, the long-context variant) is the same alias, and so is any
# case of it: the CLI trims and lowercases a model before it matches an alias
# (read, 2.1.226) — `Fable` was taken for a full id and let through
# unmapped, to the endpoint that never heard of it. Anything else is a full
# model id, the caller's own choice, and passes.
#
# `default` and an empty model — no `--model` at all — are one thing, the
# CLI's own default, and one rule: they pass when ANTHROPIC_MODEL says what it
# is, or when opus AND sonnet are mapped, the aliases that default resolves to
# (read). `default` used to need ANTHROPIC_MODEL while no model at all passed
# always, so the same default was refused or let through by how it was
# spelled (docs/DEFECTS.md 14.6).
aif_profile_maps_model() {
  local m
  m="$(aif_profile_alias "$1")"
  [ -n "${ANTHROPIC_BASE_URL:-}" ] || return 0
  case "$m" in
    opus | sonnet | haiku | fable) _aif_profile_alias_mapped "$m" ;;
    opusplan) _aif_profile_alias_mapped opus && _aif_profile_alias_mapped sonnet ;;
    default | '')
      [ -n "${ANTHROPIC_MODEL:-}" ] && return 0
      _aif_profile_alias_mapped opus && _aif_profile_alias_mapped sonnet
      ;;
    *) return 0 ;;
  esac
}

# aif_profile_alias <model> — the model as the CLI matches it against its
# aliases: trimmed, lowercased, a `[…]` suffix off — `Opus[1m]` is opus
# (claude 2.1.226 lowercases before it matches, read; docs/DEFECTS.md 14.6).
# A full model id comes back lowercased too, which only the alias cases
# read. Not `${m,,}`: bash 3.2.
aif_profile_alias() {
  local m
  m="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "$m" in
    *\]) m="${m%\[*}" ;;
  esac
  printf '%s' "$m"
}

# aif_profile_mapped_aliases — the aliases the exported profile maps, as a
# person reads them: "opus, sonnet, haiku, fable", or "no alias". What a
# refusal of a model the profile does not map names beside it (the shift's,
# the worker's).
aif_profile_mapped_aliases() {
  local mapped=""
  [ -z "${ANTHROPIC_DEFAULT_OPUS_MODEL:-}" ] || mapped="opus"
  [ -z "${ANTHROPIC_DEFAULT_SONNET_MODEL:-}" ] || mapped="${mapped:+$mapped, }sonnet"
  [ -z "${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}" ] || mapped="${mapped:+$mapped, }haiku"
  [ -z "${ANTHROPIC_DEFAULT_FABLE_MODEL:-}" ] || mapped="${mapped:+$mapped, }fable"
  printf '%s' "${mapped:-no alias}"
}

# aif_profile_alias_var <alias> — the profile variable that routes <alias>,
# for a refusal to name: ANTHROPIC_DEFAULT_FABLE_MODEL for fable. Empty for
# anything else.
aif_profile_alias_var() {
  case "$(aif_profile_alias "$1")" in
    opus) printf 'ANTHROPIC_DEFAULT_OPUS_MODEL' ;;
    sonnet) printf 'ANTHROPIC_DEFAULT_SONNET_MODEL' ;;
    haiku) printf 'ANTHROPIC_DEFAULT_HAIKU_MODEL' ;;
    fable) printf 'ANTHROPIC_DEFAULT_FABLE_MODEL' ;;
  esac
}

# _aif_profile_alias_mapped <opus|sonnet|haiku|fable> — is its variable set?
# A `case`, because bash 3.2 has no `${v^^}` to build the name with.
_aif_profile_alias_mapped() {
  case "$1" in
    opus) [ -n "${ANTHROPIC_DEFAULT_OPUS_MODEL:-}" ] ;;
    sonnet) [ -n "${ANTHROPIC_DEFAULT_SONNET_MODEL:-}" ] ;;
    haiku) [ -n "${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}" ] ;;
    fable) [ -n "${ANTHROPIC_DEFAULT_FABLE_MODEL:-}" ] ;;
    *) return 1 ;;
  esac
}
