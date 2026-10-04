#!/usr/bin/env bash
#
# `aif project init|check` — set up and validate .aif/project.json.
# Sourced by bin/aif; not meant to be executed directly.

_aif_project_usage() {
  cat <<EOF
usage: aif project init [runner] [--force] [--no-checks]
       aif project checks
       aif project check
       aif project upgrade
       aif project guide

  init    Scaffold .aif/project.json from a template. Detects the test runner
          when not named. Runners: $(_aif_project_runners | tr '\n' ' ')
  checks  Ask again what the project's Definition of Done is, and record it
  check   Validate .aif/project.json, and say what has moved since the
          template it was made from
  upgrade Bring forward what aif has changed its mind about since — the
          failure classes, a type-check's phases, the caps, the runner — and
          leave your own fields (the test command, the roots, the checks'
          commands, the board) as they are
  guide   Write $AIF_GUIDE_FILE from what the repository declares — the
          runner's configuration, where the tests, fixtures, doubles and
          factories live, what the tests import most — for the plan and tests
          stations to read. Regenerates its block in place; what you write
          outside the markers is kept. Commit it.

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
    # (docs/DEFECTS.md 5.2). `[ -n … ]` reads the text, not the status.
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
    # behaviour exists, so a build run at that moment fails correctly and a
    # phase-blind check would reject the red phase for being red by design. A
    # compiler or type-checker is the one check that belongs at every phase:
    # it is what holds the plan's skeleton to the real library, and the tests
    # to the skeleton.
    printf '  phase — green (after the code exists), red (test files, against the skeleton), or all (a compiler: contract, red and green) [green]: ' >&2
    read -r phase || phase=""
    case "$phase" in
      red | r) phase='["red"]' ;;
      all | a | contract | c) phase='["contract","red","green"]' ;;
      *) phase='["green"]' ;;
    esac
    checks="$(printf '%s' "$checks" | jq -c --arg n "$name" --arg c "$cmd" --argjson p "$phase" \
      '. + [{ name: $n, command: $c, phase: $p, required: true }]')"
  done

  printf '%s' "$checks"
}

# _aif_typecheck_default <root> — the type-check this project already carries,
# as a check bound to every phase, or nothing. The one check `aif project init`
# writes without asking, because its command is the project's own and the
# place it is needed is not negotiable: a type error inside a frozen test
# file cost 49 minutes on a live ticket before the gate that reads this field
# existed (docs/DEFECTS.md 6.2), and a skeleton that does not compile is a
# contract nobody can test against (docs/REBUILD-4.md §2.1).
#
# Only what the project declares: a tsconfig.json with typescript installed,
# a `typecheck` script. Nothing is invented for a project that has none.
_aif_typecheck_default() {
  local root="$1" cmd=""
  if [ -f "$root/package.json" ]; then
    if jq -e '(.scripts // {}) | has("typecheck")' "$root/package.json" >/dev/null 2>&1; then
      cmd="npm run typecheck"
    elif [ -f "$root/tsconfig.json" ] &&
      jq -e '((.devDependencies // {}) + (.dependencies // {})) | has("typescript")' "$root/package.json" >/dev/null 2>&1; then
      cmd="npx tsc --noEmit"
    fi
  fi
  [ -n "$cmd" ] || return 0
  jq -n --arg c "$cmd" '{ name: "typecheck", command: $c, phase: ["contract", "red", "green"], required: true }'
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

  local checks tc
  checks="$(_aif_collect_checks "$root" "$ask")"
  # The project's own type-check, bound to every phase, written without a
  # question when the project declares one — unless the interview already
  # recorded a check by that name, or --no-checks asked for none at all.
  if [ "$ask" -eq 1 ]; then
    tc="$(_aif_typecheck_default "$root")"
    if [ -n "$tc" ] && ! printf '%s' "$checks" | jq -e 'any(.name == "typecheck")' >/dev/null 2>&1; then
      checks="$(printf '%s' "$checks" | jq -c --argjson t "$tc" '. + [$t]')"
      printf '%stypecheck%s bound to contract, red and green — the plan'"'"'s skeleton, the tests and the code are all held to it (%s)\n' \
        "$AIF_C_BOLD" "$AIF_C_RESET" "$(printf '%s' "$tc" | jq -r .command)"
    fi
  fi
  _aif_write_checks "$dest" "$checks"

  local problems
  problems="$(aif_project_validate "$dest")"
  if [ -n "$problems" ]; then
    aif_warn "template copied but does not validate — this is a bug in the template:"
    printf '%s\n' "$problems" | sed 's/^/  /' >&2
  fi

  printf '%swrote%s %s (runner: %s)\n' "$AIF_C_GREEN" "$AIF_C_RESET" ".aif/project.json" "$runner"
  printf '%sReview it — the test command and paths are a starting point, not a guess that is always right.%s\n' \
    "$AIF_C_DIM" "$AIF_C_RESET"
  printf '%sThen write the guide the stations read, from the repository: aif project guide%s\n' \
    "$AIF_C_DIM" "$AIF_C_RESET"
  printf '%sAnd confirm it all actually runs here: aif doctor --probe%s\n' \
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

  # What has moved since the template this file was made from. Valid and
  # current are different answers: a project.json from 0.10.x validates and
  # still tells verify-red that a TypeError is a legitimate red
  # (docs/DEFECTS.md 8.1). Reported, never changed here.
  local drift kind
  drift="$(aif_project_drift "$dest")"
  kind="$(aif_project_kind "$dest")"
  if [ -n "$drift" ]; then
    printf '\n%s%s thing(s) have moved%s since this file was made from the %s template — the gates read it as it is:\n' \
      "$AIF_C_YELLOW" "$(printf '%s\n' "$drift" | grep -c .)" "$AIF_C_RESET" "${kind:-?}"
    printf '%s\n' "$drift" | sed 's/^/  - /'
    printf '%saif project upgrade%s brings these forward and leaves your own fields alone.\n' "$AIF_C_BOLD" "$AIF_C_RESET"
  elif [ -n "$kind" ] && [ -n "$(aif_project_template "$kind")" ]; then
    printf '  %scurrent%s with the %s template\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$kind"
  fi
}

# _aif_project_upgrade <root> — bring .aif/project.json forward to what the
# gates and the worker read today, touching only what aif decided and later
# changed; everything the project decided stays.
#
#   test.kind                 recorded, where it was only inferred
#   failure_classes           the template's lists first, then the project's
#                             own additions — minus what the template retired
#   checks[].phase            a type-check is bound to contract, red and green,
#                             keeping any other phase it had
#   limits                    keys the template sets and the file lacks, at the
#                             template's value; a value the project set stays;
#                             a key the template retired (limits_retired) goes
#
# Idempotent: a current file is left alone and said to be current. What moved
# is printed as the drift it closes; the file is the project's to review.
_aif_project_upgrade() {
  local root="$1" dest kind t drift tmp before after
  dest="$(aif_project_config "$root")"
  [ -f "$dest" ] || aif_die "no .aif/project.json — run 'aif project init'"
  kind="$(aif_project_kind "$dest")"
  t="$(aif_project_template "$kind")"
  [ -n "$t" ] || aif_die "no template for runner '${kind:-?}' — nothing to bring project.json up to. Record test.kind as one of: $(_aif_project_runners | tr '\n' ' ')"
  drift="$(aif_project_drift "$dest")"
  if [ -z "$drift" ]; then
    printf '%s✓%s .aif/project.json is current with the %s template — nothing to bring forward\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$kind"
    return 0
  fi

  before="$(cat "$dest")"
  tmp="$(aif_tmpfile "$dest")"
  jq --slurpfile tpl "$t" --arg kind "$kind" '
    . as $p
    | $tpl[0] as $t
    | ($t.failure_classes.retired // []) as $ret
    | ($t.failure_classes.legitimate // []) as $tl
    | ($t.failure_classes.broken // []) as $tb
    | .test.kind = (.test.kind // $kind)
    | .failure_classes.legitimate = ($tl + [ ($p.failure_classes.legitimate // [])[] | . as $x
        | select((($tl | index($x)) == null) and (($ret | index($x)) == null)) ])
    | .failure_classes.broken = ($tb + [ ($p.failure_classes.broken // [])[] | . as $x
        | select(($tb | index($x)) == null) ])
    | .limits = (($t.limits // {}) * ($p.limits // {}))
    | .limits |= with_entries(select(.key as $k | ($t.limits_retired // []) | index($k) | not))
    | .checks = [ ($p.checks // [])[]
        | if (((.name // "") | test("type"; "i")) or ((.command // "") | test("tsc|mypy|pyright")))
          then .phase = (["contract", "red", "green"] + [ (.phase // [])[] | . as $x
                 | select((["contract", "red", "green"] | index($x)) == null) ])
          else . end ]
  ' "$dest" >"$tmp" || {
    rm -f "$tmp"
    aif_die "could not rewrite .aif/project.json — left untouched"
  }
  local problems
  problems="$(aif_project_validate "$tmp")"
  if [ -n "$problems" ]; then
    rm -f "$tmp"
    aif_err "the upgraded file would not validate — .aif/project.json left untouched:"
    printf '%s\n' "$problems" | sed 's/^/  - /' >&2
    return 1
  fi
  mv "$tmp" "$dest"
  after="$(cat "$dest")"

  printf '%supgraded%s .aif/project.json to the %s template, on these points:\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$kind"
  printf '%s\n' "$drift" | sed 's/ — .*$//; s/^/  - /'
  # The result, field by field, so the diff reads without opening the file.
  jq -rn --argjson b "$before" --argjson a "$after" '
    (if ($b.test.kind // "") != ($a.test.kind // "") then "  test.kind → " + $a.test.kind else empty end),
    (if $b.failure_classes.legitimate != $a.failure_classes.legitimate then
       "  failure_classes.legitimate → " + ($a.failure_classes.legitimate | tojson)
       + (([ $b.failure_classes.legitimate[] | select(. as $x | ($a.failure_classes.legitimate | index($x)) == null) ]) as $gone
          | if ($gone | length) > 0 then "\n    retired: " + ($gone | join(", ")) else "" end)
     else empty end),
    (if $b.failure_classes.broken != $a.failure_classes.broken then
       "  failure_classes.broken → " + ($a.failure_classes.broken | tojson) else empty end),
    (($a.limits // {}) | to_entries[] | .key as $k | .value as $v
       | select((($b.limits // {}) | has($k)) | not)
       | "  limits." + $k + " = " + ($v | tostring)),
    (($b.limits // {}) | to_entries[] | .key as $k
       | select((($a.limits // {}) | has($k)) | not)
       | "  limits." + $k + " removed — retired, nothing reads it"),
    (($a.checks // []) | to_entries[] | .value as $c | .key as $i
       | select((($b.checks // [])[$i] // {}).phase != $c.phase)
       | "  check \"" + ($c.name // "?") + "\" → [" + ($c.phase | join(",")) + "]")
  ' || printf '  (the field-by-field summary could not be drawn — the file is upgraded; git diff .aif/project.json shows it)\n'
  printf '%sYour own fields are as they were: the test command, the roots, the checks'"'"' commands, the board. Review the change: git diff .aif/project.json%s\n' \
    "$AIF_C_DIM" "$AIF_C_RESET"
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
    upgrade)
      [ $# -eq 0 ] || aif_die "aif project upgrade takes no arguments"
      _aif_project_upgrade "$root"
      ;;
    guide)
      [ $# -eq 0 ] || aif_die "aif project guide takes no arguments — it reads the repository"
      _aif_project_guide "$root"
      ;;
    -h | --help | "")
      _aif_project_usage
      ;;
    *)
      aif_die "unknown subcommand: $sub (try: aif project --help)"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# `aif project guide` — this project's guide to its own tests, for the stations
#
# The plan and tests stations are handed two documents the worker appends to
# their prompts: the runner fragment aif ships (sets/claude/stacks/<kind>.md)
# and THIS — .aif/guide/tests.md, where the tests, fixtures, doubles, factories
# and setup files of this particular repository live, what its tests import
# most, which tests to read first, and how it mocks its boundaries
# (docs/REBUILD-4.md §6). Stack knowledge is data the pipeline supplies, not
# something a 60-turn station rediscovers per ticket.
#
# aif learns nothing about any language here, in the same way `aif project
# init` learns nothing: it reads what the repository already declares — the
# runner's configuration file, the directories named like doubles, the
# conftest files, the import lines of the test files — and writes paths and
# counts. The one thing it cannot read is why: which boundary this project
# fakes, with what, and why that one. That section is left to the human, or to
# /aif-setup with the human, and the generator never touches it again: the
# block between the markers is regenerated in place, everything outside it is
# kept.
#
# Every path written here is in backticks, and `aif doctor` checks each one
# still exists (lib/project.sh, aif_guide_cited_paths): a guide naming a
# helper that was renamed sends the stations to a file that is not there, so
# a stale guide is a ✗ and the worker refuses to run on it.

# _aif_guide_find <root> <find-args…> — paths under the root, repo-relative,
# sorted, with vendored, generated and foreign trees pruned. .aif/ and
# .claude/ hold whole checkouts of this repository (the worker's worktrees),
# and a scan that walked them counted every suite five times over.
_aif_guide_find() {
  local root="$1" f
  shift
  find "$root" \( -name node_modules -o -name .git -o -name .aif -o -name .claude \
    -o -name .venv -o -name venv -o -name vendor -o -name dist -o -name build \
    -o -name coverage -o -name .next -o -name __pycache__ -o -name .tox \
    -o -name .mypy_cache -o -name .pytest_cache -o -name .ruff_cache \
    -o -name site-packages -o -name Pods -o -name .gradle -o -name target \) -prune \
    -o "$@" -print 2>/dev/null | while IFS= read -r f; do
    printf '%s\n' "${f#"$root"/}"
  done | sort
}

# _aif_guide_tests <root> <kind> — the test files, as the runner's defaults
# select them. A project that narrows testMatch or python_files still names
# its tests this way in practice; the configuration section shows the narrowing.
_aif_guide_tests() {
  case "$2" in
    jest)
      _aif_guide_find "$1" -type f \( -name '*.test.js' -o -name '*.test.jsx' -o -name '*.test.ts' \
        -o -name '*.test.tsx' -o -name '*.test.mjs' -o -name '*.test.cjs' -o -name '*.spec.js' \
        -o -name '*.spec.jsx' -o -name '*.spec.ts' -o -name '*.spec.tsx' \
        -o \( -path '*/__tests__/*' -a \( -name '*.js' -o -name '*.jsx' -o -name '*.ts' -o -name '*.tsx' \) \) \)
      ;;
    pytest)
      _aif_guide_find "$1" -type f \( -name 'test_*.py' -o -name '*_test.py' \)
      ;;
    *)
      _aif_guide_find "$1" -type f \( -name '*.test.js' -o -name '*.test.jsx' -o -name '*.test.ts' \
        -o -name '*.test.tsx' -o -name '*.spec.js' -o -name '*.spec.ts' -o -name '*.spec.tsx' \
        -o -name 'test_*.py' -o -name '*_test.py' \
        -o \( -path '*/__tests__/*' -a \( -name '*.js' -o -name '*.ts' -o -name '*.tsx' \) \) \)
      ;;
  esac
}

# _aif_guide_norm <path> — "." and ".." segments collapsed. Relative to the
# root; a ".." past the top is dropped, since nothing above the root is the
# repository's.
_aif_guide_norm() {
  printf '%s' "$1" | awk -F/ '{
    n = 0
    for (i = 1; i <= NF; i++) {
      s = $i
      if (s == "" || s == ".") continue
      if (s == "..") { if (n > 0) n--; continue }
      parts[++n] = s
    }
    out = ""
    for (i = 1; i <= n; i++) out = out (i > 1 ? "/" : "") parts[i]
    print out
  }'
}

# _aif_guide_js_specs <file> — every module specifier the file imports,
# requires or mocks, one per line. The same spellings _lib.sh resolves.
_aif_guide_js_specs() {
  grep -oE "(from|require|import|jest\.mock|vi\.mock|jest\.requireActual|jest\.requireMock|jest\.doMock)[[:space:]]*\(?[[:space:]]*['\"][^'\"]+['\"]" "$1" 2>/dev/null |
    sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/" || true
}

# _aif_guide_py_specs <file> — every module a python file imports, one per line.
_aif_guide_py_specs() {
  sed -n -E 's/^[[:space:]]*from[[:space:]]+([A-Za-z_.][A-Za-z0-9_.]*)[[:space:]]+import.*/\1/p; s/^[[:space:]]*import[[:space:]]+([A-Za-z_.][A-Za-z0-9_.]*).*/\1/p' "$1" 2>/dev/null
}

# _aif_guide_resolve_js <root> <dir> <spec> — the repository file a relative
# specifier names, with jest's extensions and index files, or nothing.
_aif_guide_resolve_js() {
  local base cand
  base="$(_aif_guide_norm "$2/$3")"
  for cand in "$base" "$base.ts" "$base.tsx" "$base.js" "$base.jsx" "$base.mjs" "$base.cjs" \
    "$base.mts" "$base.cts" "$base.json" "$base.d.ts" \
    "$base/index.ts" "$base/index.tsx" "$base/index.js" "$base/index.jsx"; do
    if [ -f "$1/$cand" ]; then
      printf '%s' "$cand"
      return 0
    fi
  done
}

# _aif_guide_resolve_py <root> <dir> <spec> [pythonpath…] — the repository
# module a python import names: a relative one against the file's package, an
# absolute one against the root and each pythonpath entry. Nothing for a
# package that is not this repository's.
_aif_guide_resolve_py() {
  local root="$1" dir="$2" spec="$3" base dots mod e p
  shift 3
  case "$spec" in
    .*)
      dots="${spec%%[!.]*}"
      mod="${spec#"$dots"}"
      base="$dir"
      e="${#dots}"
      while [ "$e" -gt 1 ]; do
        base="$(dirname "$base")"
        e=$((e - 1))
      done
      [ -z "$mod" ] || base="$base/$(printf '%s' "$mod" | tr '.' '/')"
      base="$(_aif_guide_norm "$base")"
      if [ -f "$root/$base.py" ]; then
        printf '%s' "$base.py"
      elif [ -f "$root/$base/__init__.py" ]; then
        printf '%s' "$base/__init__.py"
      fi
      ;;
    *)
      mod="$(printf '%s' "$spec" | tr '.' '/')"
      for p in "" "$@"; do
        base="${p:+$p/}$mod"
        if [ -f "$root/$base.py" ]; then
          printf '%s' "$base.py"
          return 0
        fi
        if [ -f "$root/$base/__init__.py" ]; then
          printf '%s' "$base/__init__.py"
          return 0
        fi
      done
      ;;
  esac
}

# _aif_guide_package <kind> <spec> — the package a non-relative specifier
# belongs to: a scoped npm name keeps its scope, a dotted python import its
# first segment.
_aif_guide_package() {
  case "$1" in
    pytest) printf '%s' "${2%%.*}" ;;
    *)
      case "$2" in
        @*/*) printf '%s' "$(printf '%s' "$2" | cut -d/ -f1-2)" ;;
        *) printf '%s' "${2%%/*}" ;;
      esac
      ;;
  esac
}

# _aif_guide_quoted <text> — every single- or double-quoted string in it, one
# per line, with jest's <rootDir>/ prefix dropped.
_aif_guide_quoted() {
  printf '%s\n' "$1" | grep -oE "['\"][^'\"]+['\"]" | tr -d "'\"" | sed 's|^<rootDir>/||; s|^<rootDir>||' | grep -v '^$' || true
}

# _aif_guide_fixtures <conftest> — the fixture names a conftest defines: the
# `def` under each @pytest.fixture, stacked decorators and blank lines allowed.
_aif_guide_fixtures() {
  awk '
    /@(pytest\.)?fixture/ { want = 1; next }
    want && /^[[:space:]]*(async[[:space:]]+)?def[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/ {
      line = $0
      sub(/^[[:space:]]*(async[[:space:]]+)?def[[:space:]]+/, "", line)
      sub(/[^A-Za-z0-9_].*$/, "", line)
      print line; want = 0; next }
    want && /^[[:space:]]*(@|$)/ { next }
    { want = 0 }
  ' "$1" 2>/dev/null | head -20 | paste -sd, - | sed 's/,/, /g'
}

# _aif_guide_block <root> <kind> <kind-recorded> — the generated block, markers
# included, on stdout.
# shellcheck disable=SC2016  # the backticks are markdown code spans, not substitution
_aif_guide_block() {
  local root="$1" kind="$2" recorded="$3" project tests tmp tsv
  project="$(aif_project_config "$root")"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/aif-guide-XXXXXX")" || aif_die "cannot make a scratch directory"
  tsv="$tmp/imports.tsv"
  : >"$tsv"

  tests="$(_aif_guide_tests "$root" "$kind")"
  local n_tests
  n_tests="$(printf '%s' "$tests" | grep -c . || true)"
  n_tests="${n_tests:-0}"

  printf '%s — generated by `aif project guide` (aif %s); regenerated in place, everything outside the markers is yours -->\n' \
    "$AIF_GUIDE_BEGIN" "$AIF_VERSION"

  # ---- the runner --------------------------------------------------------------
  printf '\n## Runner\n\n'
  if [ -n "$recorded" ]; then
    printf -- '- **%s** (test.kind in .aif/project.json)\n' "$kind"
  elif [ -n "$kind" ]; then
    printf -- '- **%s** — inferred from test.command; test.kind is not recorded in .aif/project.json. Record it ("kind": "%s" under "test") so the worker and doctor stop guessing.\n' "$kind" "$kind"
  else
    printf -- '- the runner is not known: .aif/project.json records no test.kind and the test command names neither jest nor pytest. The stations work from their general rules.\n'
  fi
  printf -- '- the suite: `%s`\n' "$(jq -r '.test.command // "?"' "$project")"
  printf -- '- the report: %s (%s) — the gates read it, one row per test, never the console\n' \
    "$(jq -r '.test.report.path // "?"' "$project")" "$(jq -r '.test.report.format // "?"' "$project")"
  local prepare
  prepare="$(jq -r '.prepare // empty' "$project")"
  [ -z "$prepare" ] || printf -- '- a fresh checkout is made able to run it with: `%s`\n' "$prepare"
  if [ -n "$kind" ]; then
    if [ -n "$(aif_stack_fragment "$root" "$kind")" ]; then
      printf -- '- the runner fragment the stations get before this guide: `%s/%s.md`\n' "$AIF_STACKS_DIR" "$kind"
    else
      printf -- '- no runner fragment is installed for %s (%s/%s.md) — aif init installs the ones the set ships; a runner the set has none for leaves the stations on their general rules\n' \
        "$kind" "$AIF_STACKS_DIR" "$kind"
    fi
  fi
  local n_checks
  n_checks="$(jq '(.checks // []) | length' "$project")"
  if [ "${n_checks:-0}" -gt 0 ]; then
    printf -- '- the project'"'"'s checks, by phase: %s\n' \
      "$(jq -r '[.checks[] | .name + " [" + (.phase | join(",")) + "]"] | join(", ")' "$project")"
  fi

  # ---- the configuration -------------------------------------------------------
  printf '\n## Configuration\n\n'
  local f shown=0 lines pythonpaths=""
  case "$kind" in
    jest)
      for f in jest.config.js jest.config.cjs jest.config.mjs jest.config.ts jest.config.json; do
        [ -f "$root/$f" ] || continue
        shown=1
        lines="$(grep -nE "^[[:space:]]*['\"]?(preset|testMatch|testRegex|roots|testPathIgnorePatterns|modulePathIgnorePatterns|setupFiles|setupFilesAfterEach|moduleNameMapper|transform|transformIgnorePatterns|testEnvironment|modulePaths|moduleDirectories|globalSetup|globalTeardown|projects|resolver|testTimeout|collectCoverageFrom|coverageThreshold|snapshotSerializers|clearMocks|resetMocks|restoreMocks)['\"]?[[:space:]]*:" "$root/$f" 2>/dev/null | cut -c1-200 | head -30)" || lines=""
        printf -- '- `%s` — the lines that select, prepare and transform tests:\n\n```\n%s\n```\n\n' "$f" "${lines:-(none of the usual keys found — read the file)}"
        local setups
        setups="$(_aif_guide_quoted "$(grep -E 'setupFiles|setupFilesAfterEach|globalSetup|globalTeardown' "$root/$f" 2>/dev/null)")"
        [ -z "$setups" ] || printf '%s\n' "$setups" >>"$tmp/setups"
      done
      if [ -f "$root/package.json" ] && jq -e '.jest' "$root/package.json" >/dev/null 2>&1; then
        shown=1
        printf -- '- `package.json`, key `jest`:\n\n```\n%s\n```\n\n' "$(jq '.jest' "$root/package.json" | head -40)"
        jq -r '.jest | ((.setupFiles // []) + (.setupFilesAfterEach // []))[], (.globalSetup // empty), (.globalTeardown // empty)' "$root/package.json" 2>/dev/null |
          sed 's|^<rootDir>/||' >>"$tmp/setups" || true
      fi
      [ "$shown" -eq 1 ] || printf -- '- no jest configuration file found and no `jest` key in package.json — jest'"'"'s defaults apply (testMatch `**/__tests__/**/*.[jt]s?(x)` and `**/?(*.)+(spec|test).[jt]s?(x)`)\n'
      for f in babel.config.js babel.config.cjs .babelrc .babelrc.js .swcrc; do
        [ -f "$root/$f" ] && printf -- '- `%s` — the transform tests run through\n' "$f"
      done
      if [ -f "$root/tsconfig.json" ]; then
        local ext flags="" fl
        ext="$(grep -oE '"extends"[[:space:]]*:[[:space:]]*"[^"]+"' "$root/tsconfig.json" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*"([^"]+)"/\1/' || true)"
        for fl in strict noUnusedLocals noUnusedParameters noImplicitReturns exactOptionalPropertyTypes noImplicitAny; do
          grep -qE "\"$fl\"[[:space:]]*:[[:space:]]*true" "$root/tsconfig.json" 2>/dev/null && flags="$flags, $fl"
        done
        printf -- '- `tsconfig.json`%s%s%s\n' \
          "${ext:+ extends $ext}" \
          "$([ -n "$flags" ] && printf ' — on here: %s' "${flags#, }" || printf ' — none of strict/noUnused*/noImplicitReturns set in this file')" \
          "$([ -n "$ext" ] && printf '; flags set in the extended config are not read here' || true)"
        case "$flags" in *noUnused*) printf '  (a skeleton `void`s each parameter it does not use, so the plan compiles)\n' ;; esac
      fi
      ;;
    pytest)
      if [ -f "$root/pytest.ini" ]; then
        shown=1
        printf -- '- `pytest.ini`:\n\n```\n%s\n```\n\n' "$(head -40 "$root/pytest.ini")"
        pythonpaths="$pythonpaths $(_aif_guide_quoted "$(grep -E '^pythonpath' "$root/pytest.ini")")"
      fi
      if [ -f "$root/pyproject.toml" ] && grep -q '^\[tool\.pytest\.ini_options\]' "$root/pyproject.toml"; then
        shown=1
        lines="$(awk '/^\[tool\.pytest\.ini_options\]/ { p = 1; print; next } /^\[/ { p = 0 } p' "$root/pyproject.toml" | head -40)"
        printf -- '- `pyproject.toml`, section `[tool.pytest.ini_options]`:\n\n```\n%s\n```\n\n' "$lines"
        pythonpaths="$pythonpaths $(_aif_guide_quoted "$(printf '%s\n' "$lines" | grep -E '^pythonpath')")"
      fi
      if [ -f "$root/setup.cfg" ] && grep -q '^\[tool:pytest\]' "$root/setup.cfg"; then
        shown=1
        printf -- '- `setup.cfg`, section `[tool:pytest]`:\n\n```\n%s\n```\n\n' "$(awk '/^\[tool:pytest\]/ { p = 1; print; next } /^\[/ { p = 0 } p' "$root/setup.cfg" | head -40)"
      fi
      if [ -f "$root/tox.ini" ] && grep -q '^\[pytest\]' "$root/tox.ini"; then
        shown=1
        printf -- '- `tox.ini`, section `[pytest]`:\n\n```\n%s\n```\n\n' "$(awk '/^\[pytest\]/ { p = 1; print; next } /^\[/ { p = 0 } p' "$root/tox.ini" | head -40)"
      fi
      [ "$shown" -eq 1 ] || printf -- '- no pytest configuration found (pytest.ini, pyproject.toml [tool.pytest.ini_options], setup.cfg, tox.ini) — pytest'"'"'s defaults apply: python_files `test_*.py` and `*_test.py`, python_functions `test*`, python_classes `Test*`\n'
      [ -d "$root/src" ] && pythonpaths="$pythonpaths src"
      for f in mypy.ini pyrightconfig.json; do
        [ -f "$root/$f" ] && printf -- '- `%s` — a type-checker is configured\n' "$f"
      done
      ;;
    *)
      printf -- '- the runner is not one aif knows a configuration shape for; read its configuration yourself\n'
      ;;
  esac
  [ -z "$(printf '%s' "$pythonpaths" | tr -d ' ')" ] || pythonpaths="$(printf '%s' "$pythonpaths" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"

  # ---- where the tests are -----------------------------------------------------
  printf '\n## Where the tests are\n\n'
  local r under outside=0 rootsre="" helpers
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    r="${r%/}"
    under="$(printf '%s\n' "$tests" | grep -c "^$r/" || true)"
    if [ "$n_tests" -gt 0 ]; then
      helpers="$(_aif_guide_find "$root" -type f -path "$root/$r/*" | grep -vxF -f <(printf '%s\n' "$tests") | grep -c . || true)"
    else
      helpers="$(_aif_guide_find "$root" -type f -path "$root/$r/*" | grep -c . || true)"
    fi
    if [ -d "$root/$r" ]; then
      printf -- '- `%s/` (test.roots) — %s test file(s), %s other file(s): helpers, fixtures, setup\n' "$r" "${under:-0}" "${helpers:-0}"
    else
      printf -- '- %s/ is named in test.roots and does not exist\n' "$r"
    fi
    rootsre="$rootsre|^$r/"
  done <<EOF2
$(jq -r '.test.roots[]? // empty' "$project")
EOF2
  rootsre="${rootsre#|}"
  if [ "$n_tests" -eq 0 ]; then
    printf -- '- no test files found by the runner'"'"'s naming (%s) — a project with no tests yet, or tests named in a way the configuration above selects and this scan does not\n' \
      "$([ "$kind" = pytest ] && printf 'test_*.py, *_test.py' || printf '*.test.*, *.spec.*, __tests__/')"
  else
    if [ -n "$rootsre" ]; then
      outside="$(printf '%s\n' "$tests" | grep -vE "$rootsre" | grep -c . || true)"
    else
      outside="$n_tests"
    fi
    if [ "${outside:-0}" -gt 0 ]; then
      printf -- '- %s test file(s) outside test.roots — beside their sources, most in:\n' "$outside"
      printf '%s\n' "$tests" | if [ -n "$rootsre" ]; then grep -vE "$rootsre"; else cat; fi |
        sed 's|/[^/]*$||' | sort | uniq -c | sort -rn | head -6 |
        awk '{ c = $1; $1 = ""; sub(/^ /, ""); printf "  - `%s/` — %s\n", $0, c }' || true
    fi
    case "$kind" in
      pytest)
        printf -- '- named: test_*.py %s, *_test.py %s\n' \
          "$(printf '%s\n' "$tests" | grep -cE '(^|/)test_[^/]*\.py$' || true)" \
          "$(printf '%s\n' "$tests" | grep -cE '_test\.py$' || true)"
        ;;
      *)
        printf -- '- named: *.test.* %s, *.spec.* %s, under __tests__/ %s\n' \
          "$(printf '%s\n' "$tests" | grep -c '\.test\.[a-z]*$' || true)" \
          "$(printf '%s\n' "$tests" | grep -c '\.spec\.[a-z]*$' || true)" \
          "$(printf '%s\n' "$tests" | grep -c '/__tests__/' || true)"
        ;;
    esac
  fi

  # ---- fixtures, doubles, factories, setup ------------------------------------
  printf '\n## Fixtures, doubles, factories, setup\n\n'
  local any=0 d s
  if [ -f "$tmp/setups" ]; then
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      any=1
      if [ -e "$root/$s" ]; then
        printf -- '- `%s` — a setup file the runner loads before the tests\n' "$s"
      else
        printf -- '- %s is named as a setup file and does not exist at that path\n' "$s"
      fi
    done <<EOF2
$(sort -u "$tmp/setups")
EOF2
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    any=1
    local fx
    fx="$(_aif_guide_fixtures "$root/$f")"
    printf -- '- `%s` — fixtures: %s\n' "$f" "${fx:-none defined here (hooks or imports only)}"
  done <<EOF2
$([ "$kind" = jest ] || _aif_guide_find "$root" -type f -name conftest.py)
EOF2
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    case "$(basename "$d" | tr '[:upper:]' '[:lower:]')" in
      helpers | support | testing | utils | util)
        # Too common a name to list wherever it occurs: only where the path says tests.
        printf '%s' "$d" | tr '[:upper:]' '[:lower:]' | grep -qE 'test|spec' || continue
        ;;
    esac
    any=1
    if [ "$(basename "$d")" = "__mocks__" ]; then
      local mocks
      mocks="$(find "$root/$d" -maxdepth 1 -type f 2>/dev/null | sed -E 's|.*/||; s/\.(d\.ts|tsx|ts|jsx|js|mjs|cjs)$//' | sort -u | head -10 | paste -sd, - | sed 's/,/, /g')"
      printf -- '- `%s/` — jest manual mocks for: %s\n' "$d" "${mocks:-nothing yet}"
    else
      printf -- '- `%s/` — %s file(s)\n' "$d" "$(find "$root/$d" -type f 2>/dev/null | grep -c . || true)"
    fi
  done <<EOF2
$(_aif_guide_find "$root" -type d \( -name __mocks__ -o -iname fixtures -o -iname __fixtures__ -o -iname factories -o -iname factory \
  -o -iname mocks -o -iname doubles -o -iname fakes -o -iname stubs -o -iname test-utils -o -iname test_utils -o -iname testutils \
  -o -iname testing -o -iname helpers -o -iname support -o -iname utils -o -iname util \) | head -25)
EOF2
  [ "$any" -eq 1 ] || printf -- '- none found by name — no conftest.py, __mocks__, fixtures/, factories/ or setup file; the tests build what they need inline, or name it in a way this scan does not know\n'

  # ---- what the tests import -----------------------------------------------------
  printf '\n## What the tests import most\n\n'
  if [ "$n_tests" -gt 0 ]; then
    local scanned=0 dir spec res
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      scanned=$((scanned + 1))
      [ "$scanned" -le 600 ] || break
      dir="$(dirname "$f")"
      case "$f" in
        *.py)
          while IFS= read -r spec; do
            [ -n "$spec" ] || continue
            # shellcheck disable=SC2086  # pythonpaths is a word list on purpose
            res="$(_aif_guide_resolve_py "$root" "$dir" "$spec" $pythonpaths)"
            if [ -n "$res" ]; then
              printf 'R\t%s\t%s\n' "$res" "$f" >>"$tsv"
            else
              case "$spec" in .*) ;; *) printf 'P\t%s\t%s\n' "$(_aif_guide_package pytest "$spec")" "$f" >>"$tsv" ;; esac
            fi
          done <<EOF2
$(_aif_guide_py_specs "$root/$f")
EOF2
          ;;
        *)
          while IFS= read -r spec; do
            [ -n "$spec" ] || continue
            case "$spec" in
              .*)
                res="$(_aif_guide_resolve_js "$root" "$dir" "$spec")"
                [ -z "$res" ] || printf 'R\t%s\t%s\n' "$res" "$f" >>"$tsv"
                ;;
              *) printf 'P\t%s\t%s\n' "$(_aif_guide_package jest "$spec")" "$f" >>"$tsv" ;;
            esac
          done <<EOF2
$(_aif_guide_js_specs "$root/$f")
EOF2
          ;;
      esac
    done <<EOF2
$tests
EOF2
    [ "$scanned" -le 600 ] || printf '_The first 600 test files were read._\n\n'
    printf 'Modules of this repository, by the number of test files importing each — the shared helpers float to the top, the modules under test sit below them:\n\n'
    local top_repo
    top_repo="$(awk -F'\t' '$1 == "R" { print $2 "\t" $3 }' "$tsv" | sort -u | cut -f1 | sort | uniq -c | sort -rn | head -12)"
    if [ -n "$top_repo" ]; then
      printf '%s\n' "$top_repo" | awk '{ c = $1; $1 = ""; sub(/^ /, ""); printf "- `%s` — %s\n", $0, c }'
    else
      printf -- '- none resolved — the tests import nothing of this repository by a path this scan can follow\n'
    fi
    printf '\nPackages, by the number of test files importing each (the test-side libraries this project already uses — HTTP fakes, clocks, factories, rendering):\n\n'
    local top_pkg
    top_pkg="$(awk -F'\t' '$1 == "P" { print $2 "\t" $3 }' "$tsv" | sort -u | cut -f1 | sort | uniq -c | sort -rn | head -12)"
    if [ -n "$top_pkg" ]; then
      printf '%s\n' "$top_pkg" | awk '{ c = $1; $1 = ""; sub(/^ /, ""); printf "- %s — %s\n", $0, c }'
    else
      printf -- '- none\n'
    fi

    # ---- tests to read first -------------------------------------------------------
    printf '\n## Tests to read first\n\n'
    printf 'For each of the most-imported modules above, the shortest test that uses it:\n\n'
    local mod ex
    local listed=0
    while IFS= read -r mod; do
      [ -n "$mod" ] || continue
      ex="$(awk -F'\t' -v m="$mod" '$1 == "R" && $2 == m { print $3 }' "$tsv" | sort -u | while IFS= read -r f; do
        printf '%s\t%s\n' "$(wc -l <"$root/$f" | tr -d ' ')" "$f"
      done | sort -n | head -1 | cut -f2)"
      [ -n "$ex" ] || continue
      listed=$((listed + 1))
      printf -- '- `%s` — uses `%s`\n' "$ex" "$mod"
    done <<EOF2
$(printf '%s\n' "$top_repo" | awk '{ $1 = ""; sub(/^ /, ""); print }' | head -3)
EOF2
    [ "$listed" -gt 0 ] || printf -- '- none to single out — read the shortest test file in each directory above\n'
  else
    printf -- '- no test files to read\n'
    printf '\n## Tests to read first\n\n- none yet\n'
  fi

  printf '\n%s\n' "$AIF_GUIDE_END"
  rm -rf "${tmp:?}"
}

# _aif_project_guide <root> — write or regenerate .aif/guide/tests.md.
# shellcheck disable=SC2016  # the backticks are markdown code spans, not substitution
_aif_project_guide() {
  local root="$1" project guide kind recorded block tmp existed=0
  project="$(aif_project_config "$root")"
  [ -f "$project" ] || aif_die "no .aif/project.json — run 'aif project init' first; the guide is written from it and the repository"
  guide="$(aif_guide_path "$root")"
  recorded="$(aif_project_kind_recorded "$project")"
  kind="$(aif_project_kind "$project")"

  block="$(mktemp "${TMPDIR:-/tmp}/aif-guide-block-XXXXXX")"
  _aif_guide_block "$root" "$kind" "$recorded" >"$block"

  mkdir -p "$(dirname "$guide")"
  tmp="$(aif_tmpfile "$guide")"
  if [ -f "$guide" ] && grep -qF -- "$AIF_GUIDE_BEGIN" "$guide" && grep -qF -- "$AIF_GUIDE_END" "$guide"; then
    # Regenerate the block in place; every other line is the human's.
    existed=1
    awk -v begin="$AIF_GUIDE_BEGIN" -v end="$AIF_GUIDE_END" -v blockfile="$block" '
      index($0, begin) == 1 && !done {
        while ((getline l < blockfile) > 0) print l
        skip = 1; next }
      skip && index($0, end) == 1 { skip = 0; done = 1; next }
      skip { next }
      { print }
    ' "$guide" >"$tmp"
  else
    if [ -f "$guide" ]; then
      # A guide without the markers is a hand-written one: kept whole, under
      # the generated block, rather than overwritten.
      existed=1
    fi
    {
      printf '# How this project tests — the guide the stations read\n\n'
      printf 'The plan and tests stations get this file appended to their instructions, after the runner fragment aif ships for this project'"'"'s test runner. The block between the markers is written by `aif project guide` from what the repository declares and is regenerated in place; everything outside it is yours and is kept. Every path in backticks is checked by `aif doctor` and by the worker before a run: a path that no longer exists makes the guide stale, and `aif project guide` brings the block up to date.\n\n'
      cat "$block"
      printf '\n## How this project mocks its boundaries\n\n'
      printf '%s One line per boundary the tests do not cross for real — the database, the clock, HTTP, the filesystem, a queue, a device — naming the double this project uses for it and where it lives (a path in backticks, so `aif doctor` checks it still exists). Written by you, or by `/aif-setup` with you from the tests named above; `aif project guide` leaves this section alone._\n' "$AIF_GUIDE_PLACEHOLDER"
      if [ -f "$guide" ]; then
        printf '\n## Written before the markers existed\n\n'
        cat "$guide"
      fi
    } >"$tmp"
  fi
  mv "$tmp" "$guide"
  rm -f "$block"

  local n_paths missing
  n_paths="$(aif_guide_cited_paths "$guide" | grep -c . || true)"
  missing="$(aif_guide_missing_paths "$root")"
  if [ "$existed" -eq 1 ]; then
    printf '%sregenerated%s %s — the block between the markers; what you wrote outside it is kept\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$AIF_GUIDE_FILE"
  else
    printf '%swrote%s %s\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$AIF_GUIDE_FILE"
  fi
  printf '  %s path(s) cited, %s\n' "${n_paths:-0}" \
    "$([ -z "$missing" ] && printf 'all exist' || printf '%sTHESE DO NOT EXIST%s: %s' "$AIF_C_RED" "$AIF_C_RESET" "$(printf '%s\n' "$missing" | paste -sd, - | sed 's/,/, /g')")"
  if [ -z "$recorded" ] && [ -n "$kind" ]; then
    printf '  %stest.kind is not recorded%s in .aif/project.json — inferred %s from test.command; add "kind": "%s" under "test" so nothing has to guess\n' \
      "$AIF_C_YELLOW" "$AIF_C_RESET" "$kind" "$kind"
  elif [ -z "$kind" ]; then
    printf '  %sthe runner is not known%s — no test.kind, and the test command names neither jest nor pytest; the stations work from their general rules\n' \
      "$AIF_C_YELLOW" "$AIF_C_RESET"
  fi
  if aif_guide_unwritten "$root"; then
    printf '\n%sNext%s: read it, then write "How this project mocks its boundaries" — or open Claude Code here and type %s/aif-setup%s, which writes it with you from the tests the guide names.\n' \
      "$AIF_C_BOLD" "$AIF_C_RESET" "$AIF_C_BOLD" "$AIF_C_RESET"
  fi
  printf '%sThen commit it — the stations run in a checkout cut from HEAD, and read that copy:  git add %s%s\n' \
    "$AIF_C_DIM" "$AIF_GUIDE_FILE" "$AIF_C_RESET"
  [ -z "$missing" ]
}
