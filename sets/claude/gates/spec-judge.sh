#!/usr/bin/env bash
#
# Gate: spec-judge — is there a valid, current pass from the specification judge?
#
# The judge is an executor with an unknown error rate and nothing gating it, so
# the gate makes the judge's output falsifiable rather than trusting it:
#
#   - Every finding must quote spec.md verbatim. A judge that invents a problem
#     it cannot locate has malfunctioned — that is exit 3 (rerun), not exit 1
#     (the spec is fine, the judge is broken).
#   - The verdict binds to the spec's bytes. Edit spec.md after judging and the
#     recorded hash no longer matches, so the pass lapses on its own.
#
# What it does NOT establish: that the judge was right. A judge that passes a bad
# spec, or blocks a good one, is not caught here — that is the limit of a judge
# with no oracle, and it is why the human still decides completeness.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source-path=SCRIPTDIR source=_lib.sh
. "$here/_lib.sh"

aif_g_need jq

work="${1:-}"
[ -n "$work" ] || aif_g_error "usage: spec-judge.sh <work-dir>"

spec="$work/spec.md"
verdict="$work/verdict-spec.json"

[ -f "$spec" ] || aif_g_error "spec.md missing"
[ -f "$verdict" ] || aif_g_reject "not judged — no verdict-spec.json (run: aif station run spec-judge)"

if ! jq -e . "$verdict" >/dev/null 2>&1; then
  aif_g_error "verdict-spec.json is not valid JSON"
fi

spec_hash="$(aif_g_sha256 "$spec")"
spec_meta="$(aif_g_meta_or_die "$spec" "spec.md")" || exit $?
spec_ids="$(printf '%s' "$spec_meta" | jq -c '[.acceptance[]?.id]')"

# exit 1 (act on the boundary): a stale verdict means re-run the judge. The spec
# is not wrong, the verdict is old.
if [ "$(jq -r '.subject_sha256 // ""' "$verdict")" != "$spec_hash" ]; then
  aif_g_reject "verdict is for a different spec — it changed since it was judged; re-run the judge"
fi

# exit 3 (the judge malfunctioned): a verdict that is malformed, or that points
# at an AC the spec does not have, or quotes text not in the spec, is unusable.
# Re-running the judge is the fix, not editing the spec — so this must not read
# as a spec defect and send the author in circles.
malformed="$(
  jq -r \
    --argjson spec_ids "$spec_ids" '
    [
      (if .subject != "spec.md" then "subject is not spec.md" else empty end),
      (if (.pass | type) != "boolean" then "pass is not a boolean" else empty end),
      (if (.pass == false) and ((.findings // []) | length) == 0
        then "fails but lists no findings" else empty end),
      ( (.findings // [])
        | to_entries[]
        | .key as $i | .value as $f
        | (
          (if ($f.severity // "") != "blocker"
            then "findings[" + ($i|tostring) + "].severity must be blocker" else empty end),
          (if ($f.ac != null) and (($spec_ids | index($f.ac)) == null)
            then "findings[" + ($i|tostring) + "].ac \"" + ($f.ac|tostring) + "\" is not an AC in spec.md"
            else empty end),
          (if (($f.quote // "") | length) == 0
            then "findings[" + ($i|tostring) + "].quote is empty" else empty end)
        )
      )
    ] | .[]
  ' "$verdict" 2>&1
)" || aif_g_error "spec-judge: jq failed — $malformed"

# Every quote must be locatable verbatim; one that is not is a hallucination.
while IFS= read -r q; do
  [ -n "$q" ] || continue
  if ! grep -qF -- "$q" "$spec"; then
    malformed="$malformed
quoted text not found in spec.md: \"$q\""
  fi
done <<EOF
$(jq -r '.findings[]?.quote // empty' "$verdict")
EOF

if [ -n "$(printf '%s' "$malformed" | grep -v '^$' || true)" ]; then
  printf 'ERROR  the judge produced an unusable verdict — rerun it:\n' >&2
  printf '%s\n' "$malformed" | grep -v '^$' | sed 's/^/  - /' >&2
  exit "$AIF_G_ERROR"
fi

# exit 1 (fix the artifact): a well-formed verdict with a blocker means the spec
# has a defect. Also fail a self-contradictory pass-with-blocker verdict.
blockers="$(jq '[.findings[]? | select(.severity == "blocker")] | length' "$verdict")"
passed="$(jq -r '.pass' "$verdict")"

if [ "$passed" != "true" ] || [ "$blockers" -gt 0 ]; then
  printf 'REJECT spec.md: judge found %s blocker(s)\n' "$blockers" >&2
  jq -r '.findings[]? | "  - " + (.ac // "spec") + ": " + .why + "\n      \"" + .quote + "\""' "$verdict" >&2
  exit "$AIF_G_REJECT"
fi

printf 'spec-judge: passed, no blockers\n'
