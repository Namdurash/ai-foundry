#!/usr/bin/env bash
#
# `aif project init|check` — set up and validate .aif/project.json.
# Sourced by bin/aif; not meant to be executed directly.

_aif_project_usage() {
  cat <<EOF
usage: aif project init [runner] [--force] [--no-checks]
       aif project checks
       aif project check

  init    Scaffold .aif/project.json from a template. Detects the test runner
          when not named. Runners: $(_aif_project_runners | tr '\n' ' ')
  checks  Ask again what the project's Definition of Done is, and record it
  check   Validate .aif/project.json

  --no-checks skips the Definition-of-Done interview and writes checks: []
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
    [ -n "$(find "$root/tests" -name '*.py' -print 2>/dev/null | head -1)" ]; then
    # Inside a substitution, on purpose: `head -1` leaves after one line, a
    # find still walking a large tree takes SIGPIPE, and as the condition's
    # own pipeline that 141 read as "no .py files" — at 5000 of them
    # (docs/DEFECTS-5.md #2). `[ -n … ]` reads the text, not the status.
    printf 'pytest'
  else
    printf ''
  fi
}

# _aif_pytest_launcher <root> — how pytest is actually invoked HERE.
#
# The template shipped a bare `pytest`, and on any project with a virtualenv —
# which on macOS with a Homebrew python is close to every project — that is
# exit 127 at the first gate. Worse, it is not curable in the file: the next
# `aif project init pytest` writes the same broken line again.
#
# aif still learns nothing about python. It reads what the PROJECT already
# declares about itself — a venv directory, a lockfile — exactly as the checks
# interview reads package.json scripts and Makefile targets, and it prints what
# it chose so a wrong guess is visible once rather than at the first gate.
_aif_pytest_launcher() {
  local root="$1"
  if [ -x "$root/.venv/bin/pytest" ]; then
    printf '.venv/bin/pytest\tthis project has a .venv with pytest in it'
  elif [ -x "$root/venv/bin/pytest" ]; then
    printf 'venv/bin/pytest\tthis project has a venv with pytest in it'
  elif [ -f "$root/uv.lock" ] && aif_have uv; then
    printf 'uv run pytest\tuv.lock is present and uv is installed'
  elif [ -f "$root/poetry.lock" ] && aif_have poetry; then
    printf 'poetry run pytest\tpoetry.lock is present and poetry is installed'
  elif aif_have pytest; then
    printf 'pytest\tpytest is on PATH'
  else
    printf 'python3 -m pytest\tnothing else was detected; this at least fails with a readable error rather than exit 127'
  fi
}

# Candidate checks, as "name<TAB>command", from what the project ALREADY
# declares about itself.
#
# Deliberately shallow. aif does not know what a compiler is, what a type
# declaration is, or where a package manager keeps its modules — that knowledge
# stays on the project side, and a toolkit that grew it would be a toolkit for
# one language. What it can read is a list of names the project wrote down: the
# scripts in a package.json, the targets in a Makefile. A name that looks like a
# check is offered as a candidate and a human decides.
_aif_check_candidates() {
  # One candidate per NAME. A repo with both a `lint` script and a `lint` make
  # target would otherwise offer two, and accepting both writes a project.json
  # that fails its own validation — after the interview is over, which is the
  # worst possible moment to find out.
  _aif_check_candidates_raw "$@" | awk -F'\t' '!seen[$1]++'
}

_aif_check_candidates_raw() {
  local root="$1"
  local pattern='^(typecheck|type-check|types|tsc|lint|lint:fix|build|check|verify|audit|deps|compile)$'
  local runner="npm run"

  if [ -f "$root/package.json" ]; then
    # Which package manager, from the lockfile the project committed. Wrong
    # guesses are cheap here: the command is shown for confirmation and can be
    # edited before anything is written.
    if [ -f "$root/pnpm-lock.yaml" ]; then
      runner="pnpm run"
    elif [ -f "$root/yarn.lock" ]; then
      runner="yarn"
    elif [ -f "$root/bun.lockb" ]; then
      runner="bun run"
    fi
    jq -r --arg re "$pattern" --arg r "$runner" \
      '(.scripts // {}) | keys[] | select(test($re)) | . + "\t" + $r + " " + .' \
      "$root/package.json" 2>/dev/null || true
  fi

  if [ -f "$root/Makefile" ]; then
    grep -oE '^[a-z][a-z0-9_-]*:' "$root/Makefile" 2>/dev/null |
      tr -d ':' |
      grep -E "$pattern" |
      while IFS= read -r t; do
        [ -n "$t" ] || continue
        printf '%s\tmake %s\n' "$t" "$t"
      done
  fi
}

# _aif_collect_checks <root> <ask> — ask the human what "done" means here beyond the
# tests, and echo the result as a JSON array.
#
# Interactive on purpose, and it is the one interaction `aif project init` has.
# Detected commands are PRESENTED, never auto-written: a wrong guess — the wrong
# script, the wrong package manager, a command that wants a running server —
# costs more than a question asked once per project, and a check that silently
# never runs is indistinguishable from one that passes.
#
# On a non-terminal stdin this writes [] and says so. Prompting into a pipe hangs
# CI forever, and guessing would install the exact failure this asks about.
_aif_collect_checks() {
  local root="$1" ask="$2"
  local checks="[]" name cmd answer phase

  if [ "$ask" -eq 0 ]; then
    printf '%s' "$checks"
    return 0
  fi

  if [ ! -t 0 ]; then
    aif_warn "stdin is not a terminal — leaving checks empty; run 'aif project checks' to fill it in"
    printf '%s' "$checks"
    return 0
  fi

  printf '\n%sWhat must pass, besides the tests?%s\n' "$AIF_C_BOLD" "$AIF_C_RESET" >&2
  printf '%sA compiler, a linter, a build, a dependency-integrity check — whatever your\n' "$AIF_C_DIM" >&2
  printf 'Definition of Done includes. Anything not listed here is never enforced.%s\n\n' "$AIF_C_RESET" >&2

  # The candidate list arrives on fd 3, not on stdin: a heredoc on stdin would
  # replace the terminal for the whole loop, and every `read` meant for the human
  # would silently eat the next candidate instead.
  while IFS="$(printf '\t')" read -r name cmd <&3; do
    [ -n "$name" ] || continue
    printf '  found: %s%-12s%s %s\n' "$AIF_C_BOLD" "$name" "$AIF_C_RESET" "$cmd" >&2
    printf '  add it? [Y/n/e=edit the command]: ' >&2
    read -r answer || answer=n
    case "$answer" in
      n | N | no) continue ;;
      e | E)
        printf '  command: ' >&2
        read -r answer || answer=""
        [ -n "$answer" ] || continue
        cmd="$answer"
        ;;
    esac
    checks="$(printf '%s' "$checks" | jq -c --arg n "$name" --arg c "$cmd" \
      '. + [{ name: $n, command: $c, phase: ["green"], required: true }]')"
  done 3<<EOF
$(_aif_check_candidates "$root")
EOF

  local first=1
  [ "$(printf '%s' "$checks" | jq 'length')" -eq 0 ] || first=0
  while :; do
    # "another" when nothing was offered and nothing accepted reads as a
    # question about a first check that never happened.
    if [ "$first" -eq 1 ]; then
      printf '\n  a check? name (blank for none): ' >&2
    else
      printf '\n  another check? name (blank to finish): ' >&2
    fi
    first=0
    read -r name || name=""
    [ -n "$name" ] || break
    if printf '%s' "$checks" | jq -e --arg n "$name" 'any(.name == $n)' >/dev/null 2>&1; then
      printf '  there is already a check called "%s" — pick another name\n' "$name" >&2
      continue
    fi
    printf '  command: ' >&2
    read -r cmd || cmd=""
    [ -n "$cmd" ] || continue
    # phase is not a detail: the tests station writes FAILING tests before any
    # implementation exists, so a compiler run at that moment fails correctly and
    # a phase-blind check would reject the red phase for being red by design.
    printf '  phase — green (after the code exists) or red (test files only) [green]: ' >&2
    read -r phase || phase=""
    case "$phase" in
      red | r) phase="red" ;;
      *) phase="green" ;;
    esac
    checks="$(printf '%s' "$checks" | jq -c --arg n "$name" --arg c "$cmd" --arg p "$phase" \
      '. + [{ name: $n, command: $c, phase: [$p], required: true }]')"
  done

  printf '%s' "$checks"
}

# _aif_write_checks <dest> <checks-json>
_aif_write_checks() {
  local dest="$1" checks="$2" tmp
  tmp="$(aif_tmpfile "$dest")"
  jq --argjson c "$checks" '.checks = $c' "$dest" >"$tmp" && mv "$tmp" "$dest"

  local n
  n="$(printf '%s' "$checks" | jq 'length')"
  if [ "$n" -eq 0 ]; then
    printf '%sno checks recorded%s — green will enforce the test command and nothing else\n' \
      "$AIF_C_YELLOW" "$AIF_C_RESET"
  else
    printf '%s%s check(s)%s recorded — green fails the station if any of them does\n' \
      "$AIF_C_GREEN" "$n" "$AIF_C_RESET"
    printf '%s' "$checks" | jq -r '.[] | "  " + .name + "  [" + (.phase | join(",")) + "]  " + .command'
  fi
}

_aif_project_init() {
  local root="$1" runner="$2" force="$3" ask="$4"
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

  # Adapt the template's test command to how this project is actually run.
  if [ "$runner" = "pytest" ]; then
    local launcher why tab tmp
    tab="$(printf '\t')"
    launcher="$(_aif_pytest_launcher "$root")"
    why="${launcher#*"$tab"}"
    launcher="${launcher%%"$tab"*}"
    tmp="$(aif_tmpfile "$dest")"
    jq --arg l "$launcher" \
      '.test.command = ($l + " -q --junitxml=.aif/tmp/report.xml")
       | .test.select = ($l + " -q --junitxml=.aif/tmp/report.xml {ids}")' \
      "$dest" >"$tmp" && mv "$tmp" "$dest"
    printf '%stest command%s %s  %s(%s)%s\n' \
      "$AIF_C_BOLD" "$AIF_C_RESET" "$launcher" "$AIF_C_DIM" "$why" "$AIF_C_RESET"
  fi

  _aif_write_checks "$dest" "$(_aif_collect_checks "$root" "$ask")"

  local problems
  problems="$(aif_project_validate "$dest")"
  if [ -n "$problems" ]; then
    aif_warn "template copied but does not validate — this is a bug in the template:"
    printf '%s\n' "$problems" | sed 's/^/  /' >&2
  fi

  printf '%swrote%s %s (runner: %s)\n' "$AIF_C_GREEN" "$AIF_C_RESET" ".aif/project.json" "$runner"
  printf '%sReview it — the test command and paths are a starting point, not a guess that is always right.%s\n' \
    "$AIF_C_DIM" "$AIF_C_RESET"
  printf '%sThen confirm it actually runs here: aif doctor --probe%s\n' \
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

  # The rest of the Definition of Done, said out loud. An empty list is a valid
  # answer and a consequential one — it means the test command is the only thing
  # the pipeline will ever enforce — so it is reported, not passed over.
  local n
  n="$(jq '(.checks // []) | length' "$dest")"
  if [ "$n" -eq 0 ]; then
    printf '  %sno checks%s — the test command is the whole Definition of Done here (aif project checks)\n' \
      "$AIF_C_YELLOW" "$AIF_C_RESET"
  else
    jq -r '.checks[] | "  check " + .name + "  [" + (.phase | join(",")) + "]"
           + (if .required then "" else "  (optional)" end) + "  " + .command' "$dest"
  fi
}

aif_cmd_project() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift

  local root
  root="$(aif_require_project)"

  case "$sub" in
    init)
      local runner="" force=0 ask=1
      while [ $# -gt 0 ]; do
        case "$1" in
          --force) force=1 ;;
          --no-checks) ask=0 ;;
          -*) aif_die "unknown option: $1" ;;
          *) runner="$1" ;;
        esac
        shift
      done
      _aif_project_init "$root" "$runner" "$force" "$ask"
      ;;
    checks)
      # The same interview on its own, for a project that was set up before
      # checks existed, or whose Definition of Done has moved since.
      local dest
      dest="$(aif_project_config "$root")"
      [ -f "$dest" ] || aif_die "no .aif/project.json — run 'aif project init' first"
      _aif_write_checks "$dest" "$(_aif_collect_checks "$root" 1)"
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
