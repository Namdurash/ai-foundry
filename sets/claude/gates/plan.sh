#!/usr/bin/env bash
#
# Gate: plan — can the rest of the pipeline actually read this plan?
#
# It replaces two gates and a station: plan-form (372 lines of form and prose
# lint) and plan-judge (a second model reading the first one's plan, plus 206
# lines making its verdict falsifiable). Both are gone, and the reason is in
# what a plan is FOR. It is not prose to be graded — it is DATA that verify-red,
# green and scope dereference:
#
#   files.tests   verify-red runs and freezes exactly these
#   files.create  scope permits exactly these to appear
#   files.change  scope permits exactly these to be edited
#   ac_coverage   the map from a criterion to the files that serve it
#   external      what the run will not validate, re-emitted on the checklist
#
# So this gate checks that those fields are there, are literal, and name the
# repository as it actually is. Nothing else. Whether the plan is any GOOD is
# answered by the outcome — tests that will not go green, a diff that leaves the
# manifest — and a wrong plan therefore costs a retry rather than a judge.
#
# What went, and why it is not missed: a hedged `statement`, a `because` that
# names an achievement rather than a constraint, a `serves` pointing at nothing,
# a surface mapped two ways — every one of them was a rejection that sent an
# opus station round again over the WORDING of a decision the code would have
# settled. They are still written (the report and `aif explain` draw them); they
# are no longer gates.
#
# Exit 0 admitted · 1 the plan is rejected · 3 the gate could not run.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source-path=SCRIPTDIR source=_lib.sh
. "$here/_lib.sh"

aif_g_need jq

work="${1:-}"
[ -n "$work" ] || aif_g_error "usage: plan.sh <work-dir>"

plan="$work/plan.md"
ticket="$work/ticket.md"
project="$(aif_g_project "$work")" || exit $?
root="$(dirname "$(dirname "$project")")"

[ -f "$ticket" ] || aif_g_error "ticket.md missing — a plan cannot be checked without the criteria it serves"

meta="$(aif_g_meta_or_die "$plan" "plan.md")" || exit $?
tmeta="$(aif_g_meta_or_die "$ticket" "ticket.md")" || exit $?

ticket_hash="$(aif_g_sha256 "$ticket")"
files_max="$(jq -r '.limits.plan_files_max // 12' "$project")"
acs="$(printf '%s' "$tmeta" | jq -c '[.acceptance[]?.id]')"
ticket_id="$(printf '%s' "$tmeta" | jq -r '.ticket // ""')"
ticket_risk="$(printf '%s' "$tmeta" | jq -r '.risk // ""')"
check_names="$(jq -c '[.checks[]?.name]' "$project")"

violations="$(
  printf '%s' "$meta" | jq -r \
    --argjson files_max "$files_max" \
    --argjson acs "$acs" \
    --argjson check_names "$check_names" \
    --arg ticket_hash "$ticket_hash" \
    --arg ticket_id "$ticket_id" \
    --arg ticket_risk "$ticket_risk" '

    . as $m
    | (($m.files.create // []) + ($m.files.change // [])) as $impl
    | ($m.files.tests // []) as $tests
    | ($m.ac_coverage // {}) as $cov
    | ([ $cov[]? ] | flatten) as $covered
    | ($m.uncovered // []) as $unc
    | [
      # ---- the envelope, and the one binding -----------------------------
      (if ($m.schema? // null) != 2
        then "meta.schema must be 2" else empty end),
      (if ($m.ticket? // "") != $ticket_id
        then "meta.ticket \"" + ($m.ticket? // "") + "\" does not match ticket.md (" + $ticket_id + ")"
        else empty end),

      # Written by `aif _record` after the station returns, never by the
      # station itself — so this is not a spelling check on the model. It
      # catches a plan being judged against a ticket that has moved under it:
      # a resumed run, a reworked ticket.
      (if ($m.ticket_sha256? // "") != $ticket_hash
        then "meta.ticket_sha256 is not ticket.md as it now stands — this plan was made for a different ticket; re-run the plan station"
        else empty end),
      (if ($m.risk? // "") != $ticket_risk
        then "meta.risk \"" + ($m.risk? // "") + "\" contradicts ticket.md (" + $ticket_risk + ") — risk picks the implementation engine"
        else empty end),

      # ---- the file manifest, which three gates dereference ---------------
      (if ($impl | length) == 0
        then "meta.files lists nothing to create or change" else empty end),
      (if ($tests | length) == 0
        then "meta.files.tests is empty — there would be nothing for verify-red to run"
        else empty end),
      (if ($impl | length) > $files_max
        then "meta.files touches " + ($impl | length | tostring)
             + " implementation files, limit is " + ($files_max | tostring)
             + " — split the ticket" else empty end),
      (if ($impl | length) != ($impl | unique | length)
        then "meta.files lists the same path twice" else empty end),

      # Tests and implementation must be disjoint: the two stations are split
      # exactly so that the oracle cannot be edited by the code it judges, and
      # green re-hashes the test tree to hold that.
      ( ($impl | map(select(. as $p | $tests | index($p))))[]?
        | "\"" + . + "\" is both an implementation file and a test file" ),

      # A glob would let the plan claim a surface it never named, which is the
      # one thing scope cannot then check.
      ( ($impl + $tests)[]?
        | select(test("[*?\\[\\]]") or startswith("/") or test("\\.\\."))
        | "\"" + . + "\" must be a literal relative path (no globs, no .., not absolute)" ),

      # ---- every criterion has somewhere to land --------------------------
      ( $acs[]?
        | select(. as $ac | ($cov | has($ac)) | not)
        | "ac_coverage is missing " + . + " — every criterion needs a file that serves it" ),
      ( ($cov | keys[]?)
        | select(. as $ac | ($acs | index($ac)) == null)
        | "ac_coverage names " + . + ", which is not a criterion in ticket.md" ),
      ( ($cov | to_entries[]?)
        | .key as $ac | .value as $paths
        | ( if ($paths | length) == 0 then "ac_coverage." + $ac + " lists no files" else empty end,
            ( $paths[]? | select(. as $p | ($impl | index($p)) == null)
              | "ac_coverage." + $ac + " names \"" + .
                + "\", which is not in files.create or files.change" ) ) ),

      # A file the plan orders into existence that no criterion points at is a
      # blind spot by construction — on a live ticket that file was the module
      # barrel, it threw on import, and no test noticed. Not rejected: DECLARED,
      # in a list the human is shown on the pass path below.
      ( ($m.files.create // [])[]?
        | select(. as $p | ($covered | index($p)) == null)
        | select(. as $p | ($unc | index($p)) == null)
        | "files.create names \"" + .
          + "\", which no criterion covers — give it one, or list it in meta.uncovered so it is seen" ),

      # ---- the external surface: name a validator you have, or none --------
      (if ($m | has("external") | not)
        then "meta.external is required (may be []) — the third-party modules, runtime globals and system APIs this implementation will touch"
        else empty end),
      ( ($m.external // []) | to_entries[]
        | .key as $i | .value as $e
        | ( (if (($e.name // "") | length) == 0
              then "external[" + ($i | tostring) + "].name is empty" else empty end),
            (if ($e.check // null) != null and ($check_names | index($e.check)) == null
              then "external[" + ($i | tostring) + "].check \"" + ($e.check | tostring)
                   + "\" is not a check in .aif/project.json"
                   + (if ($check_names | length) == 0 then " (that project declares none — add one, or name a criterion instead)"
                      else " — one of: " + ($check_names | join(", ")) end)
              else empty end),
            (if ($e.ac // null) != null and ($acs | index($e.ac)) == null
              then "external[" + ($i | tostring) + "].ac \"" + ($e.ac | tostring)
                   + "\" is not a criterion in ticket.md" else empty end) ) )
    ]
    | map(select(type == "string"))
    | .[]
  ' 2>&1
)" || aif_g_error "plan: jq failed — $violations"

# --- what no implementation may touch, whatever the plan says ---------------
#
# The same list scope holds against the diff, applied here to the manifest. One
# list, two gates: when it was a private constant of one of them they
# disagreed, and a plan named a lockfile that scope would then have rejected
# the implementation for editing.
fs=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if printf '%s' "$p" | grep -qE "$AIF_G_DENYLIST"; then
    fs="$fs
the manifest names \"$p\", which no implementation may touch (pipeline, config, CI, or a dependency lockfile) — scope would reject the work this plan orders; plan around it"
  fi
done <<EOF
$(printf '%s' "$meta" | jq -r '((.files.create // []) + (.files.change // []) + (.files.tests // []))[]? // empty')
EOF

# --- the repository as it actually is ---------------------------------------
#
# The most common failure of a planning model, and entirely mechanical to
# catch: a plan written against a repository it imagined.
while IFS= read -r p; do
  [ -n "$p" ] || continue
  [ -e "$root/$p" ] && fs="$fs
files.create names \"$p\", which already exists — use files.change"
done <<EOF
$(printf '%s' "$meta" | jq -r '.files.create[]? // empty')
EOF

while IFS= read -r p; do
  [ -n "$p" ] || continue
  [ -e "$root/$p" ] || fs="$fs
files.change names \"$p\", which does not exist — use files.create"
done <<EOF
$(printf '%s' "$meta" | jq -r '.files.change[]? // empty')
EOF

aif_g_report "$(printf '%s\n%s' "$violations" "${fs# }" | grep -v '^$' || true)" "plan.md"

printf 'plan: %s implementation file(s), %s test file(s), %s criteria covered\n' \
  "$(printf '%s' "$meta" | jq '(.files.create // []) + (.files.change // []) | length')" \
  "$(printf '%s' "$meta" | jq '.files.tests | length')" \
  "$(printf '%s' "$meta" | jq '.ac_coverage | length')"

# --- what passed, and what passed unwatched ---------------------------------
# On the PASS path, always. Each is a hole the plan is allowed to have and a
# human is not allowed to be unaware of; a list that only appears when someone
# goes looking is the same as no list.
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
