#!/usr/bin/env bash
#
# Gate: plan-judge — did the reasoning cross the boundary?
#
# The judge ran on the implementer's model and listed every place it would have
# to guess. The gate is simple because the judgement is: any guess at all means
# the plan left work for the implementer to invent, which is the thing principle
# 3 forbids. An empty guess list passes.
#
# Like spec-judge, the gate makes the judge's output falsifiable: every guess
# must name a file the plan actually touches, and the verdict binds to the plan's
# bytes. It does not establish that the judge was thorough — a judge that missed
# a gap is not caught here.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source-path=SCRIPTDIR source=_lib.sh
. "$here/_lib.sh"

aif_g_need jq

work="${1:-}"
[ -n "$work" ] || aif_g_error "usage: plan-judge.sh <work-dir>"

plan="$work/plan.md"
verdict="$work/verdict-plan.json"

[ -f "$plan" ] || aif_g_error "plan.md missing"
[ -f "$verdict" ] || aif_g_reject "not judged — no verdict-plan.json (run: aif station run plan-judge)"

if ! jq -e . "$verdict" >/dev/null 2>&1; then
  aif_g_error "verdict-plan.json is not valid JSON"
fi

plan_hash="$(aif_g_sha256 "$plan")"
plan_meta="$(aif_g_meta_or_die "$plan" "plan.md")" || exit $?
plan_files="$(printf '%s' "$plan_meta" | jq -c '((.files.create // []) + (.files.change // []))')"

# exit 1 (act on the boundary): a stale verdict means re-run the judge against
# the current plan. The plan itself is not wrong, but the verdict is old.
if [ "$(jq -r '.subject_sha256 // ""' "$verdict")" != "$plan_hash" ]; then
  aif_g_reject "verdict is for a different plan — it changed since it was judged; re-run the judge"
fi

# exit 3 (the judge malfunctioned): a verdict that is malformed or points at
# things not in the plan is unusable. Re-running the judge is the fix, not
# editing the plan — so this must not read as a plan defect.
malformed="$(
  jq -r \
    --argjson plan_files "$plan_files" '
    [
      (if .subject != "plan.md" then "subject is not plan.md" else empty end),
      (if (.guesses | type) != "array" then "guesses is not an array" else empty end),
      ( (.guesses // [])
        | to_entries[]
        | .key as $i | .value as $g
        | (
          (if (($g.file // "") | length) == 0
            then "guesses[" + ($i|tostring) + "].file is empty"
            elif ($plan_files | index($g.file)) == null
            then "guesses[" + ($i|tostring) + "].file \"" + ($g.file|tostring)
                 + "\" is not a file the plan touches"
            else empty end),
          (if (($g.question // "") | length) == 0
            then "guesses[" + ($i|tostring) + "].question is empty" else empty end)
        )
      )
    ] | .[]
  ' "$verdict" 2>&1
)" || aif_g_error "plan-judge: jq failed — $malformed"

if [ -n "$malformed" ]; then
  printf 'ERROR  the judge produced an unusable verdict — rerun it:\n' >&2
  printf '%s\n' "$malformed" | sed 's/^/  - /' >&2
  exit "$AIF_G_ERROR"
fi

# exit 1 (fix the artifact): a well-formed verdict with guesses means the plan
# left the implementer something to invent.
count="$(jq '.guesses | length' "$verdict")"
if [ "$count" -gt 0 ]; then
  printf 'REJECT plan.md: the implementer would have to guess in %s place(s)\n' "$count" >&2
  jq -r '.guesses[] | "  - " + .file + ": " + .question' "$verdict" >&2
  exit "$AIF_G_REJECT"
fi

printf 'plan-judge: nothing left to guess\n'
