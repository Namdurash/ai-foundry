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
# user's shell — silently wins, and `aif run --profile anthropic` quietly runs
# on something else. A profile has to mean the same thing on every machine or it
# means nothing.
#
# Auth is deliberately absent from this list. The asymmetry is the reason: a
# wrong base URL fails *silently*, by answering from a different model, while a
# wrong token fails loudly with a 401. And the anthropic profile relies on
# ambient credentials by design.
AIF_ROUTING_VARS="ANTHROPIC_BASE_URL
ANTHROPIC_MODEL
ANTHROPIC_DEFAULT_OPUS_MODEL
ANTHROPIC_DEFAULT_SONNET_MODEL
ANTHROPIC_DEFAULT_HAIKU_MODEL
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
