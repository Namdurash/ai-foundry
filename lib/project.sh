#!/usr/bin/env bash
#
# project.json — how the pipeline verifies THIS project.
# Discovery and validation, shared by `aif project`, `aif work`, and
# `aif doctor`.
# Sourced by bin/aif; not meant to be executed directly.
#
# project.json is a hard precondition. Every gate downstream reads it to learn
# how to run the tests and what "red" versus "broken" looks like here. Missing
# or invalid, and every gate degrades to theatre — so it fails loudly, early.

# aif_project_config <root> — path to .aif/project.json, or empty.
aif_project_config() {
  printf '%s/.aif/project.json' "$1"
}

# The phases a check may bind to, as a jq array literal. A phase is the moment
# in the cycle at which a check is meaningful, and it is not optional:
#
#   contract — the plan station's boundary: the skeleton it wrote, over the
#              tree as it left it. A compiler here is the linker for the
#              contract — a signature that calls a library the way the station
#              remembered it rather than the way it is does not compile, and
#              the plan is rejected with the compiler's lines
#   red      — the tests station's boundary, BEFORE any behaviour exists. With
#              the contract on disk every symbol a test touches exists, typed,
#              so a type-check is clean here and a type error is the test's.
#              Without one (`legitimate_at_red`), only a check that is true of
#              the test files alone belongs here.
#   green    — the implement station's boundary, after the code exists.
#              Compilers, linters, builds and dependency-integrity checks.
#
# A phase-blind `checks` list would reject the red phase for being red by
# design, which is the same distinction `failure_classes` already draws one
# level down: a legitimate failure is not a broken one.
AIF_PROJECT_CHECK_PHASES='["contract","red","green"]'

# What `aif explain` does when a SKILL calls it, as opposed to when a person
# types it. The moments are the places in the cycle where a drawing is worth
# the pause, and they are named rather than numbered so a setting keeps meaning
# something if the pipeline gains a station:
#
#   ready — when the analyst has the ticket ready and the human is still in the
#           room to read it. The default. (`approve` is the older name for the
#           same moment and is still accepted.)
#   plan  — after the plan gate admits the plan.
#
# Off by nobody: `never` silences the automatic call, and typing the command by
# hand still renders. A setting that overrode a person asking a direct question
# would be a different feature and a worse one.
AIF_EXPLAIN_DEFAULT="ready"

# aif_explain_auto <root> — never | ready | always.
#
# Three layers, most specific first, and the split is not arbitrary: the project
# file is committed and says what this REPOSITORY does, the user file is not and
# says what THIS DEVELOPER can afford. "I have the budget for it" is a fact
# about a person; putting it in a shared file makes it everyone else's setting
# too.
aif_explain_auto() {
  local root="$1" v=""

  case "${AIF_EXPLAIN:-}" in
    approve)
      printf 'ready'
      return 0
      ;;
    never | ready | always)
      printf '%s' "$AIF_EXPLAIN"
      return 0
      ;;
    "") ;;
    *) aif_warn "AIF_EXPLAIN=$AIF_EXPLAIN is not never|ready|always — ignored" ;;
  esac

  local user_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/aif/config.json"
  if [ -f "$user_cfg" ]; then
    v="$(jq -r '.explain.auto // empty' "$user_cfg" 2>/dev/null)"
    case "$v" in
      approve)
        printf 'ready'
        return 0
        ;;
      never | ready | always)
        printf '%s' "$v"
        return 0
        ;;
    esac
  fi

  v="$(jq -r '.explain.auto // empty' "$(aif_project_config "$root")" 2>/dev/null)"
  case "$v" in
    approve) printf 'ready' ;;
    never | ready | always) printf '%s' "$v" ;;
    *) printf '%s' "$AIF_EXPLAIN_DEFAULT" ;;
  esac
}

# aif_explain_enabled <root> <moment> — rc 0 if the orchestrator should draw.
aif_explain_enabled() {
  local setting
  setting="$(aif_explain_auto "$1")"
  case "$setting" in
    always) return 0 ;;
    ready) [ "$2" = "ready" ] || [ "$2" = "approve" ] ;;
    *) return 1 ;;
  esac
}

# aif_project_validate <file> — echo one violation per line; empty output = valid.
#
# Structural only: the keys the gates dereference must exist and be the right
# shape. It cannot check that the test command is correct — only that there is
# one.
#
# On test.roots, because its name invites the wrong reading and a project once
# paid for it: roots is the SMUGGLING NET over the project's shared test tree —
# the tree green re-hashes so that logic cannot be hidden in a fixture no plan
# lists. It is NOT the source of truth for one ticket's tests; that is the
# plan's files.tests, and verify-red freezes the union of the two.
aif_project_validate() {
  local file="$1"

  if [ ! -f "$file" ]; then
    printf 'project.json not found at %s\n' "$file"
    return 0
  fi

  if ! jq -e . "$file" >/dev/null 2>&1; then
    printf 'project.json is not valid JSON\n'
    return 0
  fi

  jq -r --argjson phases "$AIF_PROJECT_CHECK_PHASES" '
    [
      (if .schema != 1 then "schema must be 1" else empty end),
      (if (.ticket_pattern | type) != "string" then "ticket_pattern must be a string" else empty end),
      (if (.test | type) != "object" then "test must be an object" else empty end),
      (if (.test.roots | type) != "array" or (.test.roots | length) < 1
        then "test.roots must be a non-empty array" else empty end),
      (if (.test.command | type) != "string" then "test.command must be a string" else empty end),
      # test.kind — optional: the runner, as `aif project init` detected it
      # (jest, pytest). What chooses the stack fragment the stations read; a
      # project.json from before the field keeps working without one.
      (if ((.test.kind // "") | type) != "string"
        then "test.kind must be a string — the runner, e.g. \"jest\" or \"pytest\"" else empty end),
      (if (.test.report.path | type) != "string" then "test.report.path must be a string" else empty end),
      (if (.test.report.format | type) != "string" then "test.report.format must be a string" else empty end),
      # prepare — optional: the command that makes a fresh worktree able to run
      # the suite (npm ci, bundle install). git checks out tracked files only.
      (if ((.prepare // "") | type) != "string"
        then "prepare must be a string — a shell command, e.g. \"npm ci\"" else empty end),
      (if (.failure_classes.legitimate | type) != "array"
        then "failure_classes.legitimate must be an array" else empty end),
      (if (.failure_classes.broken | type) != "array"
        then "failure_classes.broken must be an array" else empty end),
      # checks — the rest of the Definition of Done for this project. Optional
      # as a key (a project whose DoD really is "the tests pass" writes []), but
      # every entry in it is checked hard: a check with a typo in its phase
      # never runs, and a check that never runs is indistinguishable from one
      # that passes.
      (if (.checks // []) | type != "array"
        then "checks must be an array" else empty end),
      ( (if (.checks // []) | type == "array" then (.checks // []) else [] end)
        | to_entries[]
        | .key as $i | .value as $c
        | (
          (if (($c.name // "") | length) == 0
            then "checks[" + ($i|tostring) + "].name is empty" else empty end),
          (if (($c.command // "") | length) == 0
            then "checks[" + ($i|tostring) + "].command is empty" else empty end),
          (if ($c.phase | type) != "array" or (($c.phase // []) | length) == 0
            then "checks[" + ($i|tostring) + "].phase must be a non-empty array of "
                 + ($phases | join("|"))
            else ( $c.phase[]
                   | select(. as $p | ($phases | index($p)) == null)
                   | "checks[" + ($i|tostring) + "].phase \"" + (. | tostring)
                     + "\" is not one of " + ($phases | join("|"))
                     + " — a check bound to a phase nothing runs never runs" )
            end),
          (if ($c.required | type) != "boolean"
            then "checks[" + ($i|tostring) + "].required must be true or false"
            else empty end),
          # legitimate_at_red — optional: the failures of a red-phase check
          # that a missing implementation causes (tsc: TS2307, TS2305). Present,
          # it has to be read by something, and only the red phase reads it.
          (if ($c | has("legitimate_at_red")) | not then empty
           elif ($c.legitimate_at_red | type) != "array"
             or ($c.legitimate_at_red | map(type == "string" and length > 0) | all | not)
             then "checks[" + ($i|tostring) + "].legitimate_at_red must be an array of non-empty patterns"
           elif (($c.phase // []) | index("red")) == null
             then "checks[" + ($i|tostring) + "].legitimate_at_red is set, but the check is not bound to \"red\" — only the red phase reads it"
           else empty end)
        )
      ),
      ( (if (.checks // []) | type == "array" then [(.checks // [])[].name] else [] end)
        | select(length != (unique | length))
        | "two checks share a name — a per-check ledger row could not be attributed" ),

      # explain — optional, because a project that never had it must keep
      # validating. Present and wrong is a different thing from absent: a typo
      # here silently reverts to the default, which is the failure mode the
      # phase check above exists to prevent one level up.
      (if (.explain // {}) | type != "object"
        then "explain must be an object" else empty end),
      # Bound first: inside index() the input is the ARRAY, so a bare
      # .explain.auto there would be read against ["never",…] and error.
      ( (.explain.auto // "") as $ea
        | if ($ea | length) > 0
             and (["never","ready","approve","always"] | index($ea)) == null
            then "explain.auto \"" + ($ea | tostring)
                 + "\" is not one of never|ready|always"
            else empty end ),

      # board — optional; absent means the local board. Present, it must be one
      # of the two backends, and trello must say which board, which lists, and
      # the NAMES of the secrets (never their values — those live in the
      # keychain, see lib/secret.sh). The lists may still be incomplete right
      # after `aif board init`; `aif board check` is what says whether every
      # column has one.
      (if (.board // {}) | type != "object" then "board must be an object" else empty end),
      ( (.board // {}) as $b
        | if ($b | type) != "object" or ($b | length) == 0 then empty
          elif (["local","trello"] | index($b.kind // "")) == null
            then "board.kind \"" + (($b.kind // "") | tostring) + "\" is not local or trello"
          elif $b.kind == "trello" then
            ( (if (($b.board_id // "") | length) == 0
                then "board.board_id is required for trello (aif board init trello --board <id or url>)" else empty end),
              (if (($b.secret // "") | length) == 0
                then "board.secret must NAME the token secret, e.g. TRELLO_TOKEN" else empty end),
              (if (($b.key_secret // "") | length) == 0
                then "board.key_secret must NAME the API key secret, e.g. TRELLO_KEY" else empty end),
              (if (($b.lists // {}) | type) != "object" then "board.lists must be an object" else empty end) )
          else empty end ),

      (if (.limits | type) != "object" then "limits must be an object" else empty end),
      # run_budget_usd — optional, and null (or absent) means no dollar
      # ceiling. A string here would read as 0 in awk and stop the run at the
      # first cent, blaming a budget nobody set.
      (if (.limits.run_budget_usd // null) == null then empty
       elif (.limits.run_budget_usd | type) != "number"
         then "limits.run_budget_usd must be a number, or null for no ceiling"
       elif .limits.run_budget_usd <= 0
         then "limits.run_budget_usd must be greater than 0, or null for no ceiling"
       else empty end),
      # repairs_max / replans_max — optional, bounded per ticket: how many
      # times green may send the oracle back to the tests station, and how
      # many times the implementer may send the contract back to the plan
      # (docs/REBUILD-4.md §2.4). Absent, 2 and 1.
      (if (.limits.repairs_max // null) == null then empty
       elif (.limits.repairs_max | type) != "number" or .limits.repairs_max < 0
         then "limits.repairs_max must be a number of 0 or more" else empty end),
      (if (.limits.replans_max // null) == null then empty
       elif (.limits.replans_max | type) != "number" or .limits.replans_max < 0
         then "limits.replans_max must be a number of 0 or more" else empty end),
      (if (.tiers | type) != "object" then "tiers must be an object" else empty end),
      (if (.tiers.routine // "") == "" then "tiers.routine is required" else empty end),
      (if (.tiers.careful // "") == "" then "tiers.careful is required" else empty end)
    ] | .[]
  ' "$file" 2>/dev/null
}

# --- the knowledge layer -----------------------------------------------------
# What a station knows about the stack is DATA the pipeline supplies, not
# knowledge the model is expected to carry from run to run (docs/REBUILD-4.md
# §6, principle P7). Two files, both appended by the worker to the plan and
# tests stations' prompts, after the station's own instructions:
#
#   .aif/stacks/<kind>.md  — the runner fragment. Ships with the set, one per
#                            runner template, installed by `aif init`: what red
#                            looks like under this runner, how the report names
#                            a test, how a skeleton is written in this
#                            language, what the gate rejects — in the runner's
#                            own terms. Chosen by test.kind.
#   .aif/guide/tests.md    — this project's guide. Written by `aif project
#                            guide` from what the repository declares (the
#                            runner's configuration, where the tests and the
#                            doubles live, what the tests import most), and
#                            finished by the human: how this project mocks its
#                            boundaries. Committed, so the worker's checkouts
#                            carry it.
#
# The project's own CLAUDE.md reaches the stations already — `claude -p` runs
# without --bare — and nothing here replaces it.
#
# `doctor` reports both: the fragment as a line (a runner aif has no fragment
# for is the one honest limit of the stations' self-sufficiency, and they work
# from their general rules there), the guide as the worker's `test-guide`
# capability — it exists, it is committed, and every path it cites still
# exists. A guide naming a helper that was renamed would send the stations to
# a file that is not there.
# shellcheck disable=SC2034  # read by the modules that source this file
AIF_STACKS_DIR=".aif/stacks"
AIF_GUIDE_FILE=".aif/guide/tests.md"
# The generated block's markers. Everything outside them is the human's, and
# `aif project guide` leaves it alone.
# shellcheck disable=SC2034
AIF_GUIDE_BEGIN="<!-- aif:guide:begin"
# shellcheck disable=SC2034
AIF_GUIDE_END="<!-- aif:guide:end -->"
# The one sentence the generator leaves where the human's section goes, and
# that `doctor` looks for to say the section is still unwritten.
# shellcheck disable=SC2034
AIF_GUIDE_PLACEHOLDER="_Not written yet."

aif_guide_path() {
  printf '%s/%s' "$1" "$AIF_GUIDE_FILE"
}

# aif_project_kind <project.json> — the runner: test.kind as `aif project init`
# recorded it, or, for a project.json from before the field, inferred from the
# command it runs (a command that runs jest is a jest project). Empty when
# neither says.
aif_project_kind() {
  local f="$1" k cmd
  k="$(jq -r '.test.kind // empty' "$f" 2>/dev/null)"
  if [ -z "$k" ]; then
    cmd="$(jq -r '.test.command // empty' "$f" 2>/dev/null)"
    case "$cmd" in
      *pytest*) k=pytest ;;
      *jest*) k=jest ;;
    esac
  fi
  printf '%s' "$k"
}

# aif_project_kind_recorded <project.json> — test.kind alone, or empty.
aif_project_kind_recorded() {
  jq -r '.test.kind // empty' "$1" 2>/dev/null
}

# aif_stack_fragment <root> <kind> — the installed fragment for this runner, or
# nothing.
aif_stack_fragment() {
  local f="$1/$AIF_STACKS_DIR/$2.md"
  [ -n "$2" ] && [ -f "$f" ] || return 0
  printf '%s' "$f"
}

# aif_guide_cited_paths <guide> — every path the guide cites, one per line.
#
# A path is a backticked token that looks like one: no spaces or shell/glob
# characters, not an option, not a URL, not absolute, and either holding a
# slash or ending in a source or config extension. `jest.mock` has an
# extension nobody checks, `@scope/pkg` is a package, `<rootDir>/x` a pattern
# — none is a path. The generator writes packages without backticks for the
# same reason. .aif/tmp/ is scratch the suite writes and is never asserted.
# shellcheck disable=SC2016  # the backticks are markdown code spans, not substitution
aif_guide_cited_paths() {
  grep -o '`[^`]*`' "$1" 2>/dev/null | tr -d '`' | awk '
    {
      p = $0
      if (p ~ /[[:space:]*?\[\]{}<>$|;&()=,'"'"'"]/) next
      if (p ~ /^[-@~\/]/) next
      if (p ~ /:\/\//) next
      if (p ~ /^\.aif\/tmp\//) next
      sub(/\/+$/, "", p)
      if (p == "" || p == "." || p == "..") next
      if (p ~ /\// || p ~ /\.(py|pyi|ts|tsx|js|jsx|mjs|cjs|mts|cts|json|toml|ini|cfg|yaml|yml|md|txt|rb|go|rs|sh)$/) print p
    }' | sort -u || true
}

# aif_guide_missing_paths <root> — the cited paths that no longer exist, one
# per line. Empty for a guide that is current.
aif_guide_missing_paths() {
  local root="$1" p
  aif_guide_cited_paths "$(aif_guide_path "$root")" | while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -e "$root/$p" ] || printf '%s\n' "$p"
  done
}

# aif_guide_committed <root> — rc 0 when the guide is in HEAD, which is where
# a worker's checkout is cut from. A guide written and never committed exists
# for the developer and for nobody else.
aif_guide_committed() {
  git -C "$1" cat-file -e "HEAD:$AIF_GUIDE_FILE" 2>/dev/null
}

# aif_guide_unwritten <root> — rc 0 when the human's section still holds the
# generator's placeholder.
aif_guide_unwritten() {
  grep -qF -- "$AIF_GUIDE_PLACEHOLDER" "$(aif_guide_path "$1")" 2>/dev/null
}
