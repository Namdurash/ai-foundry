#!/usr/bin/env bash
#
# Gate: plan-judge — did the reasoning cross the boundary, and is the manifest
# complete?
#
# The judge ran on the implementer's model and reported two things: every place
# it would have to guess, and every file it would have to edit that the plan's
# manifest does not permit. The gate is simple because the judgement is — any
# guess means the plan left work for the implementer to invent, and any missing
# file means scope is going to reject the implementation for a defect that was
# visible here, before it was written.
#
# The second list is the cheaper half of the same question. scope catches an
# out-of-manifest edit AFTER the implementation exists and has been paid for; the
# judge is looking at the same repository beforehand.
#
# Like spec-judge, the gate makes the judge's output falsifiable: every guess must
# name a file the plan touches, every missing file must name one it does not, and
# the verdict binds to the plan's bytes. It does not establish that the judge was
# thorough — a gap it missed is not caught here.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source-path=SCRIPTDIR source=_lib.sh
. "$here/_lib.sh"

aif_g_need jq

work="${1:-}"
[ -n "$work" ] || aif_g_error "usage: plan-judge.sh <work-dir>"

plan="$work/plan.md"
spec="$work/spec.md"
verdict="$work/verdict-plan.json"

[ -f "$plan" ] || aif_g_error "plan.md missing"
[ -f "$verdict" ] || aif_g_reject "not judged — no verdict-plan.json (the plan-judge station has not run)"

if ! jq -e . "$verdict" >/dev/null 2>&1; then
  aif_g_error "verdict-plan.json is not valid JSON"
fi

plan_hash="$(aif_g_sha256 "$plan")"
plan_meta="$(aif_g_meta_or_die "$plan" "plan.md")" || exit $?
plan_files="$(printf '%s' "$plan_meta" | jq -c '((.files.create // []) + (.files.change // []))')"
plan_risk="$(printf '%s' "$plan_meta" | jq -r '.risk // ""')"

# Recomputed here rather than read from a file plan-form wrote: plan-form runs
# live on every state query, and a gate that writes into tasks/ dirties the tree
# the implement station is scoped against. Same inputs, same answer, no artifact.
spec_meta=""
[ -f "$spec" ] && spec_meta="$(aif_g_meta "$spec")"
drift=""
[ -n "$spec_meta" ] && drift="$(aif_g_surface_drift "$plan_meta" "$spec_meta")"
drift_acs="$(printf '%s' "$drift" | cut -f1 | grep -v '^$' | sort -u | jq -R . | jq -sc .)"

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
    --argjson plan_files "$plan_files" \
    --argjson drift_acs "$drift_acs" \
    --arg risk "$plan_risk" '
    [
      (if .subject != "plan.md" then "subject is not plan.md" else empty end),
      (if (.guesses | type) != "array" then "guesses is not an array" else empty end),
      # Present-but-empty and absent are different claims, and only one of them
      # is a verdict. A judge that omitted the list did not decide it was empty.
      (if has("missing_files") | not then "missing_files is absent — the judge did not report on the manifest"
        elif (.missing_files | type) != "array" then "missing_files is not an array"
        else empty end),
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
      ),
      # The mirror of the rule above: a missing file the plan ALREADY permits is
      # a contradiction, not a finding, and sends the implementer to widen a list
      # that already contains the entry.
      ( (.missing_files // [])
        | to_entries[]
        | .key as $i | .value as $f
        | (
          (if (($f.path // "") | length) == 0
            then "missing_files[" + ($i|tostring) + "].path is empty"
            elif ($plan_files | index($f.path)) != null
            then "missing_files[" + ($i|tostring) + "].path \"" + ($f.path|tostring)
                 + "\" is already in the plan, so it is not missing"
            else empty end),
          (if (($f.why // "") | length) == 0
            then "missing_files[" + ($i|tostring) + "].why is empty" else empty end)
        )
      ),

      # An empty findings list is indistinguishable from a judge that looked at
      # nothing. On a high-risk ticket that difference is the whole verdict, so
      # the judge has to say what it examined. Left optional below high, to
      # avoid taxing cheap tickets for a signal nobody will read.
      (if $risk == "high" and ((.checked // []) | length) == 0
        then "checked is empty on a risk: high ticket — a verdict that lists "
             + "nothing examined cannot be told apart from a judge that ran and "
             + "read nothing"
        else empty end),
      ( (.checked // [])
        | to_entries[]
        | select((.value | type) != "string" or (.value | length) == 0)
        | "checked[" + (.key | tostring) + "] is not a non-empty string" ),

      # An adjudication for a criterion nothing flagged is not a finding; it is
      # the judge answering a question it was not asked, which reads as one of
      # the flags having been dealt with when it has not.
      ( (.surface_adjudications // [])
        | to_entries[]
        | select((.value.ac // "") as $a | ($drift_acs | index($a)) == null)
        | "surface_adjudications[" + (.key | tostring) + "] adjudicates "
          + ((.value.ac // "nothing") | tostring) + ", which was not flagged" )
    ] | .[]
  ' "$verdict" 2>&1
)" || aif_g_error "plan-judge: jq failed — $malformed"

# Surface drift is a routing decision, not a verdict: plan-form flags it and
# refuses to reject on it, because a narrower coverage is often correct and this
# is a signal rather than a proof. What is not acceptable is nobody deciding —
# so every flagged criterion must carry one of the two answers there are.
adj_missing=""
while IFS= read -r ac; do
  [ -n "$ac" ] || continue
  case "$(jq -r --arg a "$ac" \
    '[.surface_adjudications[]? | select(.ac == $a)] | last | .verdict // "none"' "$verdict")" in
    intended | drift) ;;
    none)
      adj_missing="$adj_missing
$ac was flagged for surface drift and the verdict does not adjudicate it"
      ;;
    *)
      adj_missing="$adj_missing
surface_adjudications for $ac must be \"intended\" or \"drift\""
      ;;
  esac
done <<EOF
$(printf '%s' "$drift" | cut -f1 | grep -v '^$' | sort -u)
EOF

if [ -n "$(printf '%s' "${adj_missing# }" | grep -v '^$' || true)" ]; then
  malformed="$malformed$adj_missing"
fi

if [ -n "$malformed" ]; then
  printf 'ERROR  the judge produced an unusable verdict — rerun it:\n' >&2
  printf '%s\n' "$malformed" | sed 's/^/  - /' >&2
  exit "$AIF_G_ERROR"
fi

# exit 1 (fix the artifact): a well-formed verdict with either list non-empty
# means the plan left the implementer something to invent, or something to touch
# that it never permitted. Both are the plan's defect and both are fixed there.
guesses="$(jq '.guesses | length' "$verdict")"
missing="$(jq '.missing_files | length' "$verdict")"
narrowed="$(jq '[.surface_adjudications[]? | select(.verdict == "drift")] | length' "$verdict")"

if [ "$narrowed" -gt 0 ]; then
  printf 'REJECT plan.md: %s criterion(s) mapped to a narrower file set than their own surface\n' \
    "$narrowed" >&2
  jq -r '.surface_adjudications[] | select(.verdict == "drift")
         | "  - " + .ac + ": " + (.why // "the judge gave no reason")' "$verdict" >&2
  printf '  The judge read the criterion and the surface map and decided the narrowing is wrong.\n' >&2
  printf '  A criterion pinned to less than its surface is satisfied by less than it asked for.\n' >&2
  exit "$AIF_G_REJECT"
fi

if [ "$guesses" -gt 0 ] || [ "$missing" -gt 0 ]; then
  if [ "$guesses" -gt 0 ]; then
    printf 'REJECT plan.md: the implementer would have to guess in %s place(s)\n' "$guesses" >&2
    jq -r '.guesses[] | "  - " + .file + ": " + .question' "$verdict" >&2
  fi
  if [ "$missing" -gt 0 ]; then
    printf 'REJECT plan.md: %s file(s) the implementation must edit are not in the manifest\n' "$missing" >&2
    jq -r '.missing_files[] | "  - " + .path + ": " + .why' "$verdict" >&2
    printf '  scope would reject these after the code was written — add them to files.change now\n' >&2
  fi
  exit "$AIF_G_REJECT"
fi

printf 'plan-judge: nothing left to guess, manifest covers the work'
if [ -n "$(printf '%s' "$drift" | grep -v '^$' || true)" ]; then
  printf ', %s surface flag(s) adjudicated as intended' \
    "$(printf '%s' "$drift" | cut -f1 | sort -u | grep -c .)"
fi
printf '\n'
