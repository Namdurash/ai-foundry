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
#   files.delete  scope permits exactly these to go, and requires that they do
#   ac_coverage   the map from a criterion to the files that serve it
#   external      what the run will not validate, re-emitted on the checklist
#
# So this gate checks that those fields are there, are literal, and name the
# repository as it actually is. Whether the plan is any GOOD is answered by the
# outcome — tests that will not go green, a diff that leaves the manifest — and
# a wrong plan therefore costs a retry rather than a judge.
#
# Two things the plan carries since docs/REBUILD-4.md, and both are checked
# here because both are what the later stations stand on:
#
#   the contract   every path in files.create that is code exists already, as
#                  a SKELETON the plan station wrote: real signatures, real
#                  types, bodies that throw the not-implemented marker. The
#                  tests are then red against something that loads — a test
#                  file importing a module that does not exist vanishes from a
#                  junit report whole (24 tests never seen by any gate on one
#                  batch) — and the seams are decided once, in code, instead of
#                  guessed twice. The project's checks bound to the `contract`
#                  phase (a compiler) run over the tree as the plan left it: a
#                  contract that calls a library wrongly does not compile, and
#                  the plan is rejected with the compiler's own lines
#   the verdicts   one per criterion. `buildable`, or the reason it is not —
#                  already true in the tree, unfalsifiable, in conflict with
#                  another, waiting on a product decision. Anything but
#                  buildable is a SPEC STOP (exit 2): the ticket's problem,
#                  found by the first station that read the code, at the cost
#                  of one dispatch, with nothing frozen
#
# What went, and why it is not missed: a hedged `statement`, a `because` that
# names an achievement rather than a constraint, a `serves` pointing at nothing,
# a surface mapped two ways — every one of them was a rejection that sent an
# opus station round again over the WORDING of a decision the code would have
# settled. They are still written (the report and `aif explain` draw them); they
# are no longer gates.
#
# Exit 0 admitted · 1 the plan is rejected · 2 the ticket is not buildable as
# written (a spec stop) · 3 the gate could not run.

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
acs="$(printf '%s' "$tmeta" | jq -c '[.acceptance[]?.id]')"
ticket_id="$(printf '%s' "$tmeta" | jq -r '.ticket // ""')"
ticket_risk="$(printf '%s' "$tmeta" | jq -r '.risk // ""')"
check_names="$(jq -c '[.checks[]?.name]' "$project")"

violations="$(
  printf '%s' "$meta" | jq -r \
    --argjson acs "$acs" \
    --argjson check_names "$check_names" \
    --arg ticket_hash "$ticket_hash" \
    --arg ticket_id "$ticket_id" \
    --arg ticket_risk "$ticket_risk" '

    . as $m
    | (($m.files.create // []) + ($m.files.change // [])) as $impl
    | ($m.files.tests // []) as $tests
    | ($m.files.delete // []) as $del
    | ($del | if type == "array" then . else [] end) as $dl
    | ($m.ac_coverage // {}) as $cov
    | ([ $cov[]? ] | flatten) as $covered
    | ($m.uncovered // []) as $unc
    | ($m.no_skeleton // []) as $nosk
    | ($m.verdicts // {}) as $verd
    | ["buildable", "already_true", "unfalsifiable", "conflict", "needs_decision"] as $kinds
    | [
      # ---- the envelope, and the one binding -----------------------------
      (if ($m.schema? // null) != 3
        then "meta.schema must be 3 — a plan carries a verdict per criterion and writes the contract (docs/REBUILD-4.md)" else empty end),
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
      (if ($impl | length) != ($impl | unique | length)
        then "meta.files lists the same path twice" else empty end),

      # Tests and implementation must be disjoint: the two stations are split
      # exactly so that the oracle cannot be edited by the code it judges, and
      # green re-hashes the test tree to hold that.
      ( ($impl | map(select(. as $p | $tests | index($p))))[]?
        | "\"" + . + "\" is both an implementation file and a test file" ),

      # A path the plan deletes is deleted, and nothing else: not also created,
      # changed or tested (docs/DEFECTS.md 13.10).
      (if ($del | type) != "array" then "files.delete must be a list of paths" else empty end),
      ( ($dl | map(select(. as $p | ($impl + $tests) | index($p))))[]?
        | "\"" + . + "\" is in files.delete and in files.create, files.change or files.tests — a path the plan deletes is only deleted" ),
      (if ($dl | length) != ($dl | unique | length)
        then "files.delete lists the same path twice" else empty end),

      # A glob would let the plan claim a surface it never named, which is the
      # one thing scope cannot then check.
      ( ($impl + $tests + $dl)[]?
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
            ( $paths[]? | select(. as $p | (($impl + $dl) | index($p)) == null)
              | "ac_coverage." + $ac + " names \"" + .
                + "\", which is not in files.create, files.change or files.delete" ) ) ),

      # A file the plan orders into existence that no criterion points at is a
      # blind spot by construction — on a live ticket that file was the module
      # barrel, it threw on import, and no test noticed. Not rejected: DECLARED,
      # in a list the human is shown on the pass path below.
      ( ($m.files.create // [])[]?
        | select(. as $p | ($covered | index($p)) == null)
        | select(. as $p | ($unc | index($p)) == null)
        | "files.create names \"" + .
          + "\", which no criterion covers — give it one, or list it in meta.uncovered so it is seen" ),

      # ---- what is not code gets no skeleton, and says so -----------------
      ( $nosk[]?
        | select(. as $p | (($m.files.create // []) | index($p)) == null)
        | "no_skeleton names \"" + . + "\", which is not in files.create" ),

      # ---- a verdict per criterion ----------------------------------------
      # The plan station is the first thing that reads the criteria against
      # the real code, so it is where "already done", "cannot be falsified"
      # and "the product has not decided" are cheapest to find. A verdict that
      # is not buildable needs its reason: it goes to the analyst as written.
      (if ($m | has("verdicts") | not)
        then "meta.verdicts is required — one entry per criterion: { \"AC-001\": { \"verdict\": \"buildable\" } }"
        else empty end),
      ( $acs[]?
        | select(. as $ac | ($verd | has($ac)) | not)
        | "verdicts is missing " + . + " — every criterion gets buildable, already_true, unfalsifiable, conflict or needs_decision" ),
      ( ($verd | keys[]?)
        | select(. as $ac | ($acs | index($ac)) == null)
        | "verdicts names " + . + ", which is not a criterion in ticket.md" ),
      ( ($verd | to_entries[]?)
        | .key as $ac | .value as $v
        | ( (if ($v | type) != "object" or (($v.verdict // "") | type) != "string"
              then "verdicts." + $ac + " must be an object with a \"verdict\"" else empty end),
            (if ($v | type) == "object" and (($v.verdict // "") | type) == "string"
                and ($kinds | index($v.verdict // "")) == null
              then "verdicts." + $ac + ".verdict \"" + ($v.verdict // "" | tostring)
                   + "\" is not one of " + ($kinds | join(", ")) else empty end),
            (if ($v | type) == "object" and ($v.verdict // "") != "buildable"
                and ($kinds | index($v.verdict // "")) != null
                and (($v.because // "") | length) == 0
              then "verdicts." + $ac + " is " + ($v.verdict // "")
                   + " and says no \"because\" — the analyst reads that reason, so it has to be there"
              else empty end) ) ),

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
#
# CI and the ignore rules are not on it any more: a ticket whose work is a
# workflow or an ignore line could not be planned (docs/DEFECTS.md 13.10).
# They are the plan's to name — in files.create, .change or .delete, never in
# files.tests — said on the pass path, and a new one is not code: no_skeleton.
fs=""
roots="$(jq -r '.test.roots[]?' "$project" 2>/dev/null)"
planned_only=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if printf '%s' "$p" | grep -qE "$AIF_G_DENYLIST"; then
    fs="$fs
the manifest names \"$p\", which no implementation may touch (the pipeline's own machinery: the gates, the project's config, the hooks, the stations, the tickets' records) — scope would reject the work this plan orders; plan around it"
  elif printf '%s' "$p" | grep -qE "$AIF_G_PLANNED_ONLY"; then
    planned_only="$planned_only$p
"
  fi
done <<EOF
$(printf '%s' "$meta" | jq -r '((.files.create // []) + (.files.change // []) + (.files.delete // []))[]? // empty' 2>/dev/null)
EOF
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if printf '%s' "$p" | grep -qE "$AIF_G_DENYLIST|$AIF_G_PLANNED_ONLY"; then
    fs="$fs
files.tests names \"$p\", which no test is — the pipeline's own machinery, CI or the ignore rules; the tests station writes tests"
  fi
done <<EOF
$(printf '%s' "$meta" | jq -r '(.files.tests // [])[]? // empty')
EOF
while IFS= read -r p; do
  [ -n "$p" ] || continue
  printf '%s' "$p" | grep -qE "$AIF_G_PLANNED_ONLY" || continue
  printf '%s' "$meta" | jq -e --arg p "$p" '(.no_skeleton // []) | index($p) != null' >/dev/null 2>&1 || fs="$fs
files.create names \"$p\", CI or an ignore file — not code, so no skeleton: list it in no_skeleton"
done <<EOF
$(printf '%s' "$meta" | jq -r '(.files.create // [])[]? // empty')
EOF

# --- what the plan deletes ---------------------------------------------------
# A ticket that must remove a file could not pass: the plan had no list for it
# and scope rejected every deleted path (docs/DEFECTS.md 13.10). files.delete
# is that list — literal paths that exist now, removed by the implement station
# and held by scope both ways: a deletion it does not name is refused, and one
# it names that is still there. Not a test (the tests are frozen, and moving
# them is the tests station's), not a manifest or a lockfile (a dependency
# moves through the package manager, never by a deletion), not the pipeline's.
deletes=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  deletes=$((deletes + 1))
  if [ ! -e "$root/$p" ]; then
    fs="$fs
files.delete names \"$p\", which does not exist — there is nothing to delete"
  elif aif_g_test_path "$p" "$roots"; then
    fs="$fs
files.delete names \"$p\", a test — the tests are frozen against the implementation; a test that has to go is the tests station's, in files.tests"
  elif printf '%s' "$p" | grep -qE "$AIF_G_MANIFESTS|$AIF_G_LOCKFILES"; then
    fs="$fs
files.delete names \"$p\", a dependency manifest or lockfile — dependencies move through the package manager, in files.change with the lockfile"
  fi
done <<EOF
$(printf '%s' "$meta" | jq -r '(.files.delete // [])[]? // empty' 2>/dev/null)
EOF

# --- the tests of a rule this ticket replaces --------------------------------
# A rule with `changes` ends another ticket's criteria, and the tests carrying
# them assert what this ticket ends: their files are this plan's to declare,
# for the tests station to remove or rewrite them (aif-plan.md) — and a plan
# that left one out is found here, at the cost of a plan, not at verify-red,
# which refuses such a test still collected, nor at green, where nothing could
# clear it (docs/DEFECTS.md 12.3). Found by name: the criterion's marker in the
# file's text, as a jest title or a pytest name spells it (aif_g_marker_re), in
# every tracked test file outside tasks/.
declared_tests="$(printf '%s' "$meta" | jq -r '(.files.tests // [])[]? // empty')"
while IFS="$(printf '\t')" read -r marker rule ref; do
  [ -n "$marker" ] || continue
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    aif_g_test_path "$f" "$roots" || continue
    printf '%s\n' "$declared_tests" | grep -qxF -- "$f" && continue
    fs="$fs
\"$f\" holds a test of $marker, which $rule replaces (changes $ref) — put it in files.tests, so the tests station removes or rewrites it; green holds the whole suite, and it asserts what this ticket ends"
  done <<EOF2
$(git -C "$root" -c core.quotePath=false grep -l -i -E "$(aif_g_marker_re "$marker")" -- . ':(exclude)tasks' 2>/dev/null)
EOF2
done <<EOF
$(aif_g_replaced_markers "$work")
EOF

# --- a dependency manifest and its lockfile, together -----------------------
#
# Both directions, because both are how a dependency gets in crooked. A
# manifest without its lockfile is what happened: the plan named package.json,
# the station installed a package, the lock stayed as it was, and what landed
# in node_modules was whatever npm resolved that afternoon — an incompatible
# pair, twelve pre-existing tests red, three implement attempts at something
# none of them could reach (docs/DEFECTS.md 6.3). A lockfile without its
# manifest is a dependency moved by hand, with nothing saying why.
impl_paths="$(printf '%s' "$meta" | jq -r '((.files.create // []) + (.files.change // []))[]? // empty')"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if printf '%s' "$p" | grep -qE "$AIF_G_MANIFESTS"; then
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      printf '%s\n' "$impl_paths" | grep -xF -- "$l" >/dev/null || fs="$fs
the manifest names \"$p\" but not \"$l\", its lockfile — a dependency manifest and its lockfile change together, so the worker can install from the lock after the station; add \"$l\" to files.change"
    done <<EOF2
$(aif_g_lockfiles_for "$root" "$p")
EOF2
  fi
  if printf '%s' "$p" | grep -qE "$AIF_G_LOCKFILES"; then
    paired=1
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      printf '%s' "$m" | grep -qE "$AIF_G_MANIFESTS" || continue
      ! aif_g_locks "$p" "$m" || paired=0
    done <<EOF2
$impl_paths
EOF2
    [ "$paired" -eq 0 ] || fs="$fs
the manifest names \"$p\", a lockfile, and no manifest it pins — a lockfile changes only with its manifest; name the manifest too, or leave both alone"
  fi
done <<EOF
$impl_paths
EOF
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if printf '%s' "$p" | grep -qE "$AIF_G_LOCKFILES|$AIF_G_MANIFESTS"; then
    fs="$fs
files.tests names \"$p\", a dependency manifest or lockfile — it is not a test, and the tests station may not move dependencies"
  fi
done <<EOF
$(printf '%s' "$meta" | jq -r '(.files.tests // [])[]? // empty')
EOF

# --- the repository as it actually is ---------------------------------------
#
# The most common failure of a planning model, and entirely mechanical to
# catch: a plan written against a repository it imagined.
#
# A create path is code unless the plan says otherwise, and code the plan
# creates exists ALREADY — as the skeleton the station wrote beside the plan.
# A create path the station did not write is a contract nobody can test
# against; a path in no_skeleton (documentation, a fixture) is the old rule:
# it must not exist yet.
no_skeleton="$(printf '%s' "$meta" | jq -r '.no_skeleton[]? // empty')"
skeletons=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if printf '%s\n' "$no_skeleton" | grep -qxF -- "$p"; then
    [ -e "$root/$p" ] && fs="$fs
files.create names \"$p\" with no skeleton, and it already exists — use files.change"
  elif [ ! -f "$root/$p" ]; then
    fs="$fs
files.create names \"$p\", and no skeleton was written there — the plan writes every new module as signatures whose bodies throw \"$AIF_G_NOT_IMPLEMENTED: <name>\"; a path that is not code goes in no_skeleton"
  elif [ ! -s "$root/$p" ]; then
    fs="$fs
files.create names \"$p\", and the skeleton there is empty — it has to carry the exports the tests will import"
  else
    skeletons=$((skeletons + 1))
    # A skeleton that does not load is a contract nobody can be red against,
    # and in a project with no compiler bound to `contract` nothing between
    # here and verify-red would notice: the tests importing it would fail to
    # load, the reporter would leave them out, and the complaint — "collected
    # no test from" — would reach the tests station, which may not edit this
    # file. The relative imports are the part of loading this gate can settle
    # by itself, as verify-red does for the test files (docs/REBUILD-4.md §2.1:
    # for an untyped stack, an import of each skeleton).
    while IFS= read -r spec_unres; do
      [ -n "$spec_unres" ] || continue
      fs="$fs
the skeleton $p imports '$spec_unres', which resolves to no file — a skeleton that does not load makes every test of it uncollectable, and that complaint would reach the tests station, which may not touch it"
    done <<EOF2
$(aif_g_imports_unresolved "$root" "$p")
EOF2
  fi
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

# --- the contract compiles ---------------------------------------------------
# The project's checks bound to the `contract` phase, over the tree as the plan
# left it. A compiler here is the linker for the skeleton: a signature that
# calls a third-party API the way the station remembered it rather than the
# way it is does not compile, and the rejection carries the compiler's lines.
# This is the gate that would have caught the two decisions that asserted a
# library's shape from memory (docs/DEFECTS.md (log 4)).
#
# A contract check failing the same way on the tree before this ticket, with
# nothing new, is the repository's, and no plan clears it: let through, named
# below (aif_g_checks_run's <base>; docs/DEFECTS.md 13.9). It used to reject
# every plan after one type error landed on the branch they start from.
mkdir -p "$root/.aif/tmp"
ptmp="$(mktemp -d "${TMPDIR:-/tmp}/aif-plan-XXXXXX")" || aif_g_error "no temporary directory for the gate"
trap '[ -z "$ptmp" ] || rm -rf "${ptmp:?}"' EXIT
check_viol="$(aif_g_checks_run "$project" "$root" "contract" "$root/.aif/tmp/checks-contract.json" "" "" \
  "$(aif_g_ticket_base "$work" "$root")" "$ptmp/base")" || exit "$AIF_G_ERROR"
aif_g_report "$check_viol" "contract"
checks_at_base="$(jq -r '[ .[]? | select(.result == "at_base") | .name ] | join(", ")' \
  "$root/.aif/tmp/checks-contract.json" 2>/dev/null)" || checks_at_base=""

# --- the verdicts: anything but buildable is the ticket's, not the plan's -----
# After the form, so the analyst reads a well-formed plan's reasons and not a
# half-written one's. Exit 2: nothing is retried, nothing is frozen, and the
# card goes to the human with these lines.
spec="$(printf '%s' "$meta" | jq -r '
  (.verdicts // {}) | to_entries[] | select(.value.verdict != "buildable")
  | .key + " is " + .value.verdict + ": " + (.value.because // "")')"
if [ -n "$spec" ]; then
  aif_g_spec "$spec"
fi

printf 'plan: %s implementation file(s), %s test file(s), %s criteria covered, %s skeleton(s)' \
  "$(printf '%s' "$meta" | jq '(.files.create // []) + (.files.change // []) | length')" \
  "$(printf '%s' "$meta" | jq '.files.tests | length')" \
  "$(printf '%s' "$meta" | jq '.ac_coverage | length')" \
  "$skeletons"
[ "$deletes" -eq 0 ] || printf ', %s deletion(s)' "$deletes"
# What it let through, on the line the ledger keeps (docs/DEFECTS.md 13.9).
[ -z "$checks_at_base" ] || printf ' — let through, failing the same way before this ticket: check %s' "$checks_at_base"
printf '\n'

# --- what passed, and what passed unwatched ---------------------------------
# On the PASS path, always. Each is a hole the plan is allowed to have and a
# human is not allowed to be unaware of; a list that only appears when someone
# goes looking is the same as no list.
if [ -n "$planned_only" ]; then
  printf '  CI AND IGNORE RULES, named by this plan — scope lets these change and no others:\n'
  printf '%s' "$planned_only" | sed '/^$/d; s/^/    - /'
fi
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
