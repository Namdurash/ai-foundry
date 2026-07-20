#!/usr/bin/env bash
#
# `aif project init|check` — set up and validate .aif/project.json.
# Sourced by bin/aif; not meant to be executed directly.

_aif_project_usage() {
  cat <<EOF
usage: aif project init [runner] [--force]
       aif project check

  init    Scaffold .aif/project.json from a template. Detects the test runner
          when not named. Runners: $(_aif_project_runners | tr '\n' ' ')
  check   Validate .aif/project.json
EOF
}

# Templates ship with the set, in AIF_ROOT. They are copied into a project, not
# installed by `aif init` — a project carries its own config, not our template.
_aif_project_templates_dir() {
  printf '%s/sets/claude/project.templates' "$AIF_ROOT"
}

_aif_project_runners() {
  local dir f
  dir="$(_aif_project_templates_dir)"
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    basename "$f" .json
  done
}

# Guess the runner from repository signals, most specific first. A guess only —
# the user can always name it, and an unknown result asks rather than assumes.
_aif_detect_runner() {
  local root="$1"
  if [ -f "$root/go.mod" ]; then
    printf 'go'
  elif [ -f "$root/package.json" ] && grep -q '"jest"' "$root/package.json" 2>/dev/null; then
    printf 'jest'
  elif [ -f "$root/pyproject.toml" ] || [ -f "$root/pytest.ini" ] ||
    [ -f "$root/setup.cfg" ] || [ -f "$root/conftest.py" ]; then
    printf 'pytest'
  elif [ -d "$root/tests" ] &&
    find "$root/tests" -name '*.py' -print 2>/dev/null | head -1 | grep -q .; then
    printf 'pytest'
  else
    printf ''
  fi
}

_aif_project_init() {
  local root="$1" runner="$2" force="$3"
  local dest template detected

  dest="$(aif_project_config "$root")"

  if [ -z "$runner" ]; then
    detected="$(_aif_detect_runner "$root")"
    if [ -z "$detected" ]; then
      aif_die "could not detect a test runner — name one: aif project init <$(_aif_project_runners | tr '\n' '|' | sed 's/|$//')>"
    fi
    runner="$detected"
    printf 'detected runner: %s%s%s\n' "$AIF_C_BOLD" "$runner" "$AIF_C_RESET"
  fi

  template="$(_aif_project_templates_dir)/$runner.json"
  if [ ! -f "$template" ]; then
    aif_die "no template for '$runner' — available: $(_aif_project_runners | tr '\n' ' ')"
  fi

  if [ -f "$dest" ] && [ "$force" -eq 0 ]; then
    aif_die ".aif/project.json already exists — edit it, or re-init with --force"
  fi

  mkdir -p "$(dirname "$dest")"
  cp "$template" "$dest"

  local problems
  problems="$(aif_project_validate "$dest")"
  if [ -n "$problems" ]; then
    aif_warn "template copied but does not validate — this is a bug in the template:"
    printf '%s\n' "$problems" | sed 's/^/  /' >&2
  fi

  printf '%swrote%s %s (runner: %s)\n' "$AIF_C_GREEN" "$AIF_C_RESET" ".aif/project.json" "$runner"
  printf '%sReview it — the test command and paths are a starting point, not a guess that is always right.%s\n' \
    "$AIF_C_DIM" "$AIF_C_RESET"
}

_aif_project_check() {
  local root="$1"
  local dest problems
  dest="$(aif_project_config "$root")"

  [ -f "$dest" ] || aif_die "no .aif/project.json — run 'aif project init'"

  problems="$(aif_project_validate "$dest")"
  if [ -n "$problems" ]; then
    aif_err "project.json has problems:"
    printf '%s\n' "$problems" | sed 's/^/  - /' >&2
    return 1
  fi

  printf '%s✓%s .aif/project.json is valid (runner command: %s)\n' \
    "$AIF_C_GREEN" "$AIF_C_RESET" "$(jq -r '.test.command' "$dest")"
}

aif_cmd_project() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift

  local root
  root="$(aif_require_project)"

  case "$sub" in
    init)
      local runner="" force=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --force) force=1 ;;
          -*) aif_die "unknown option: $1" ;;
          *) runner="$1" ;;
        esac
        shift
      done
      _aif_project_init "$root" "$runner" "$force"
      ;;
    check)
      _aif_project_check "$root"
      ;;
    -h | --help | "")
      _aif_project_usage
      ;;
    *)
      aif_die "unknown subcommand: $sub (try: aif project --help)"
      ;;
  esac
}
