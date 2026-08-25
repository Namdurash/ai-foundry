#!/usr/bin/env bash
#
# project.json — how the pipeline verifies THIS project.
# Discovery and validation, shared by `aif project`, `aif run`, and
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
#   red    — the tests station's boundary, BEFORE any implementation exists.
#            The suite is red by design there, and so is anything that compiles
#            or links the code the tests call. Only a check that is true of the
#            test files alone belongs here.
#   green  — the implement station's boundary, after the code exists. Compilers,
#            linters, builds and dependency-integrity checks belong here.
#
# A phase-blind `checks` list would reject the red phase for being red by
# design, which is the same distinction `failure_classes` already draws one
# level down: a legitimate failure is not a broken one.
AIF_PROJECT_CHECK_PHASES='["red","green"]'

# What `aif explain` does when the ORCHESTRATOR calls it, as opposed to when a
# person types it. The moments are the two places in the cycle where a drawing
# is worth the pause, and they are named rather than numbered so a setting keeps
# meaning something if the pipeline gains a station:
#
#   approve — before the human answers for the assumptions. The default.
#   plan    — after plan-judge admits the plan, which is the only other place a
#             human is shown something they did not ask to see.
#
# Off by nobody: `never` silences the automatic call, and typing the command by
# hand still renders. A setting that overrode a person asking a direct question
# would be a different feature and a worse one.
AIF_EXPLAIN_DEFAULT="approve"

# aif_explain_auto <root> — never | approve | always.
#
# Three layers, most specific first, and the split is not arbitrary: the project
# file is committed and says what this REPOSITORY does, the user file is not and
# says what THIS DEVELOPER can afford. "I have the budget for it" is a fact
# about a person; putting it in a shared file makes it everyone else's setting
# too.
aif_explain_auto() {
  local root="$1" v=""

  case "${AIF_EXPLAIN:-}" in
    never | approve | always)
      printf '%s' "$AIF_EXPLAIN"
      return 0
      ;;
    "") ;;
    *) aif_warn "AIF_EXPLAIN=$AIF_EXPLAIN is not never|approve|always — ignored" ;;
  esac

  local user_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/aif/config.json"
  if [ -f "$user_cfg" ]; then
    v="$(jq -r '.explain.auto // empty' "$user_cfg" 2>/dev/null)"
    case "$v" in
      never | approve | always)
        printf '%s' "$v"
        return 0
        ;;
    esac
  fi

  v="$(jq -r '.explain.auto // empty' "$(aif_project_config "$root")" 2>/dev/null)"
  case "$v" in
    never | approve | always) printf '%s' "$v" ;;
    *) printf '%s' "$AIF_EXPLAIN_DEFAULT" ;;
  esac
}

# aif_explain_enabled <root> <moment> — rc 0 if the orchestrator should draw.
aif_explain_enabled() {
  local setting
  setting="$(aif_explain_auto "$1")"
  case "$setting" in
    always) return 0 ;;
    approve) [ "$2" = "approve" ] ;;
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
      (if (.test.report.path | type) != "string" then "test.report.path must be a string" else empty end),
      (if (.test.report.format | type) != "string" then "test.report.format must be a string" else empty end),
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
             and (["never","approve","always"] | index($ea)) == null
            then "explain.auto \"" + ($ea | tostring)
                 + "\" is not one of never|approve|always"
            else empty end ),

      (if (.limits | type) != "object" then "limits must be an object" else empty end),
      (if (.tiers | type) != "object" then "tiers must be an object" else empty end),
      (if (.tiers.routine // "") == "" then "tiers.routine is required" else empty end),
      (if (.tiers.careful // "") == "" then "tiers.careful is required" else empty end)
    ] | .[]
  ' "$file" 2>/dev/null
}
