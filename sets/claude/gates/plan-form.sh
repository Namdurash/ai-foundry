#!/usr/bin/env bash
#
# Gate: plan-form — is the plan a distillate, and does it bind to the spec?
#
# The plan is the artifact that lets implementation run on a cheap model. Two
# things have to hold for that, and both are checkable here:
#
#   1. It binds to the exact spec it was written from (spec_sha256). Without
#      that, editing the spec later leaves a plan that looks valid and is not.
#   2. It is a distillate of decisions, not a trace of the debate. The natural
#      way to prompt for a plan produces exactly the trace, so the byte cap and
#      the banned headings are load-bearing, not tidiness.
#
# It also catches the most common failure of a planning model outright: a plan
# written against a repository it imagined. Every path to be created must not
# exist; every path to be changed must.
#
# Three coverage questions of one shape are asked here, and they are the same
# question about three kinds of entity:
#
#   a file the plan creates      must be named by a criterion — or declared
#                                uncovered, where a human can see it;
#   a surface the spec names     must have one file set, so that two criteria
#                                on one surface cannot quietly mean two things;
#   an external dependency       must name what validates it — a check, or a
#                                criterion that exercises it for real.
#
# The last is the one this pipeline lacked. Every `because` in a plan points
# backwards into the spec, which proves conformance to the SPEC and is
# structurally incapable of proving conformance to REALITY: on a live ticket two
# decisions asserted the shape of a third-party API from memory, both were
# wrong, and every gate passed.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source-path=SCRIPTDIR source=_lib.sh
. "$here/_lib.sh"

aif_g_need jq

work="${1:-}"
[ -n "$work" ] || aif_g_error "usage: plan-form.sh <work-dir>"

plan="$work/plan.md"
spec="$work/spec.md"
project="$(aif_g_project "$work")" || exit $?
root="$(dirname "$(dirname "$project")")"

[ -f "$spec" ] || aif_g_error "spec.md missing — plan cannot be checked without it"

meta="$(aif_g_meta_or_die "$plan" "plan.md")" || exit $?
spec_meta="$(aif_g_meta_or_die "$spec" "spec.md")" || exit $?

spec_hash="$(aif_g_sha256 "$spec")"
files_max="$(jq -r '.limits.plan_files_max // 12' "$project")"
spec_acs="$(printf '%s' "$spec_meta" | jq -c '[.acceptance[]?.id]')"
spec_surfaces="$(printf '%s' "$spec_meta" | jq -c '[.surfaces[]?]')"
spec_risk="$(printf '%s' "$spec_meta" | jq -r '.risk // ""')"
spec_ticket="$(printf '%s' "$spec_meta" | jq -r '.ticket // ""')"
# The names a plan may point an external dependency at. Read from the project
# rather than taken on trust: this is what stops the answer being self-attested.
check_names="$(jq -c '[.checks[]?.name]' "$project")"

violations="$(
  printf '%s' "$meta" | jq -r \
    --argjson files_max "$files_max" \
    --argjson spec_acs "$spec_acs" \
    --argjson spec_surfaces "$spec_surfaces" \
    --argjson check_names "$check_names" \
    --arg spec_hash "$spec_hash" \
    --arg spec_risk "$spec_risk" \
    --arg spec_ticket "$spec_ticket" '

    def hedges: ["we should","consider","maybe","perhaps","it might","could",
                 "probably","possibly","one option","we could"];

    . as $m
    | (($m.files.create // []) + ($m.files.change // [])) as $impl
    | ($m.files.tests // []) as $tests
    | ($m.ac_coverage // {}) as $cov
    | ([ $cov[]? ] | flatten) as $covered
    | ($m.uncovered // []) as $unc
    | ($m.surface_map // {}) as $smap
    | [
      (if ($m.schema? // null) != 1
        then "meta.schema must be 1" else empty end),
      (if ($m.ticket? // "") != $spec_ticket
        then "meta.ticket \"" + ($m.ticket? // "")
             + "\" does not match spec.md (" + $spec_ticket + ")" else empty end),

      # The binding that makes backward transitions work for free: change the
      # spec and this stops matching, which invalidates the plan automatically.
      (if ($m.spec_sha256? // "") != $spec_hash
        then "meta.spec_sha256 does not match spec.md as it is now — the plan "
             + "was written against a different spec" else empty end),

      (if ($m.risk? // "") != $spec_risk
        then "meta.risk \"" + ($m.risk? // "") + "\" contradicts spec.md ("
             + $spec_risk + ")" else empty end),

      # ---- the file contract -------------------------------------------
      (if ($impl | length) == 0
        then "meta.files lists nothing to create or change" else empty end),
      (if ($tests | length) == 0
        then "meta.files.tests is empty — there is nothing for verify-red to run"
        else empty end),
      (if ($impl | length) > $files_max
        then "meta.files touches " + ($impl | length | tostring)
             + " implementation files, limit is " + ($files_max | tostring)
             + " — split the ticket" else empty end),
      (if ($impl | length) != ($impl | unique | length)
        then "meta.files lists the same path twice" else empty end),

      # Tests and implementation must be disjoint. That separation is the whole
      # reason the stations are split, and scope/green rely on it.
      ( ($impl | map(select(. as $p | $tests | index($p))))[]?
        | "\"" + . + "\" is both an implementation file and a test file" ),

      # Globs would let the plan claim a surface it never named, defeating scope.
      ( ($impl + $tests)[]?
        | select(test("[*?\\[\\]]") or startswith("/") or test("\\.\\."))
        | "\"" + . + "\" must be a literal relative path (no globs, no .., not absolute)" ),

      # ---- decisions ----------------------------------------------------
      ( ($m.decisions // [])
        | to_entries[]
        | .key as $i | .value as $d
        | (
          (if (($d.id // "") | test("^D-[0-9]{3}$") | not)
            then "decisions[" + ($i | tostring) + "].id must look like D-001"
            else empty end),
          (if (($d.statement // "") | length) == 0
            then ($d.id // "decision") + ".statement is empty"
            elif (($d.statement // "") | length) > 200
            then ($d.id // "decision") + ".statement is "
                 + (($d.statement | length) | tostring)
                 + " chars — a decision is one sentence, not an argument"
            else empty end),
          # A hedged decision has not been made, so it does not cross the
          # boundary and implementation is left to re-derive it.
          ( (($d.statement // "") | ascii_downcase) as $s
            | (hedges | map(select(. as $h | $s | startswith($h))))
            | select(length > 0)
            | ($d.id // "decision") + ".statement hedges (\"" + .[0]
              + "\") — state the decision, do not weigh it" )
        )
      ),

      # ---- AC coverage: principle 3, made mechanical --------------------
      ( $spec_acs[]?
        | select(. as $ac | ($cov | has($ac)) | not)
        | "ac_coverage is missing " + . + " — every criterion needs a file that serves it" ),
      ( ($cov | keys[]?)
        | select(. as $ac | ($spec_acs | index($ac)) == null)
        | "ac_coverage names " + . + ", which is not in spec.md" ),
      ( ($cov | to_entries[]?)
        | .key as $ac | .value as $paths
        | ( if ($paths | length) == 0
              then "ac_coverage." + $ac + " lists no files"
              else empty end,
            ( $paths[]?
              | select(. as $p | ($impl | index($p)) == null)
              | "ac_coverage." + $ac + " names \"" + .
                + "\", which is not in files.create or files.change" ) )
      ),

      # ---- a created file no criterion covers ---------------------------
      # A file the plan orders into existence that no criterion points at is a
      # blind spot by construction. On a live ticket that file was the module
      # barrel: it threw on import, so every consumer of the module was broken,
      # and no test noticed because no criterion imported it. Documentation
      # files land in `uncovered` and that is fine — the point is that the list
      # is seen, not that it is empty.
      ( ($m.files.create // [])[]?
        | select(. as $p | ($covered | index($p)) == null)
        | select(. as $p | ($unc | index($p)) == null)
        | "files.create names \"" + .
          + "\", which no acceptance criterion covers — give it one, or list it "
          + "in meta.uncovered so the human sees it" ),
      ( $unc[]?
        | select(. as $p | (($m.files.create // []) | index($p)) == null)
        | "uncovered names \"" + . + "\", which is not in files.create" ),
      ( $unc[]?
        | select(. as $p | ($covered | index($p)) != null)
        | "uncovered names \"" + . + "\", which ac_coverage already covers" ),

      # ---- one surface, one file set ------------------------------------
      (if ($m | has("surface_map") | not)
        then "meta.surface_map is required — one file set per surface named in "
             + "spec.md, declared once, so two criteria on one surface cannot "
             + "quietly mean two different things"
        else empty end),
      ( $spec_surfaces[]?
        | select(. as $s | ($smap | has($s)) | not)
        | "surface_map is missing \"" + . + "\", which spec.md names as a surface" ),
      ( ($smap | keys[]?)
        | select(. as $s | ($spec_surfaces | index($s)) == null)
        | "surface_map names \"" + . + "\", which is not a surface in spec.md" ),
      ( ($smap | to_entries[]?)
        | .key as $s | .value as $paths
        | $paths[]?
        | select(. as $p | ($impl | index($p)) == null)
        | "surface_map." + $s + " names \"" + .
          + "\", which is not in files.create or files.change" ),

      # ---- the external surface, and what validates it -------------------
      # Just an enumeration — not a claim about any of them. aif learns nothing
      # about what these names mean; it learns that the plan named N external
      # identifiers and that each must point at a check or a criterion.
      (if ($m | has("external") | not)
        then "meta.external is required (may be []) — the third-party modules, "
             + "runtime globals and system APIs this implementation will touch"
        else empty end),
      ( ($m.external // [])
        | to_entries[]
        | .key as $i | .value as $e
        | (
          (if (($e.name // "") | length) == 0
            then "external[" + ($i | tostring) + "].name is empty" else empty end),
          (if ($e.check // null) != null and ($check_names | index($e.check)) == null
            then "external[" + ($i | tostring) + "].check \"" + ($e.check | tostring)
                 + "\" is not a check in .aif/project.json"
                 + (if ($check_names | length) == 0
                     then " (that project declares none — add one, or name a criterion instead)"
                     else " — one of: " + ($check_names | join(", ")) end)
            else empty end),
          (if ($e.ac // null) != null and ($spec_acs | index($e.ac)) == null
            then "external[" + ($i | tostring) + "].ac \"" + ($e.ac | tostring)
                 + "\" is not a criterion in spec.md"
            else empty end)
        )
      )
    ]
    | map(select(type == "string"))
    | .[]
  ' 2>&1
)" || aif_g_error "plan-form: jq failed — $violations"

# --- checks that need the filesystem, so they cannot live in jq -------------
#
# A plan written against an imagined repository is the most common planning
# failure and it is entirely mechanical to catch.
fs_violations=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if [ -e "$root/$p" ]; then
    fs_violations="$fs_violations
files.create names \"$p\", which already exists — use files.change"
  fi
done <<EOF
$(printf '%s' "$meta" | jq -r '.files.create[]? // empty')
EOF

while IFS= read -r p; do
  [ -n "$p" ] || continue
  if [ ! -e "$root/$p" ]; then
    fs_violations="$fs_violations
files.change names \"$p\", which does not exist — use files.create"
  fi
done <<EOF
$(printf '%s' "$meta" | jq -r '.files.change[]? // empty')
EOF

# --- the body must be a distillate, not a debate ----------------------------
body_bytes="$(awk 'f { print } /^-->$/ { f = 1 }' "$plan" | wc -c | tr -d ' ')"
if [ "$body_bytes" -gt 12288 ]; then
  fs_violations="$fs_violations
plan body is ${body_bytes} bytes — over 12K reads as a debate trace, not a distillate"
fi

banned="$(grep -nEi '^#{1,3} +(alternatives|options|discussion|analysis|considerations)' "$plan" 2>/dev/null | head -3)"
if [ -n "$banned" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    fs_violations="$fs_violations
plan has a deliberation section: ${line} — record the decision, not the debate"
  done <<EOF
$banned
EOF
fi

all="$(printf '%s\n%s' "$violations" "${fs_violations# }" | grep -v '^$' || true)"
aif_g_report "$all" "plan.md"

printf 'plan-form: %s implementation file(s), %s test file(s), %s AC covered\n' \
  "$(printf '%s' "$meta" | jq '(.files.create // []) + (.files.change // []) | length')" \
  "$(printf '%s' "$meta" | jq '.files.tests | length')" \
  "$(printf '%s' "$meta" | jq '.ac_coverage | length')"

# --- what passed, and what passed unwatched ---------------------------------
# On the PASS path, always. Each of these is a hole the plan is allowed to have
# and a human is not allowed to be unaware of; a list that only appears when
# someone goes looking is the same as no list. The same rule scope already
# follows for an amended manifest.
uncovered="$(printf '%s' "$meta" | jq -r '.uncovered[]? // empty')"
if [ -n "$uncovered" ]; then
  printf '  files created with no criterion (the plan says so, on the record):\n'
  printf '%s\n' "$uncovered" | sed 's/^/    - /'
fi

gaps="$(aif_g_external_gaps "$meta")"
if [ -n "$gaps" ]; then
  printf '  UNVALIDATED EXTERNAL SURFACE — no check and no criterion touches these:\n'
  printf '%s\n' "$gaps" | sed 's/^/    - /'
  printf '  Nothing in this run will establish that they behave as the plan assumes.\n'
fi

drift="$(aif_g_surface_drift "$meta" "$spec_meta")"
if [ -n "$drift" ]; then
  printf '  surface drift, for the plan judge to adjudicate:\n'
  printf '%s\n' "$drift" | awk -F'\t' '{ printf "    - %s (%s): %s\n", $1, $2, $3 }'
fi
