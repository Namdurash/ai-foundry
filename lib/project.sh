#!/usr/bin/env bash
#
# project.json — how the pipeline verifies THIS project.
# Discovery and validation, shared by `aif project`, `aif work`, and `aif doctor`.
# Sourced by bin/aif; not meant to be executed directly.
#
# project.json is a hard precondition. Every gate downstream reads it to learn
# how to run the tests and what "red" versus "broken" looks like here. Missing
# or invalid, and every gate degrades to theatre — so it fails loudly, early.

# aif_project_config <root> — path to .aif/project.json, or empty.
aif_project_config() {
  printf '%s/.aif/project.json' "$1"
}

# aif_project_validate <file> — echo one violation per line; empty output = valid.
#
# Structural only: the keys the gates dereference must exist and be the right
# shape. It cannot check that the test command is correct — only that there is
# one.
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

  jq -r '
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
      (if (.limits | type) != "object" then "limits must be an object" else empty end),
      (if (.tiers | type) != "object" then "tiers must be an object" else empty end),
      (if (.tiers.low // "") == "" then "tiers.low is required" else empty end)
    ] | .[]
  ' "$file" 2>/dev/null
}
