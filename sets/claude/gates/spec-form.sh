#!/usr/bin/env bash
#
# Gate: spec-form — is the specification admissible?
#
# This is the machine half of "admission only in falsifiable form". It checks
# FORM, never content: whether each acceptance criterion is *written* so that a
# failing test could be composed from it. Whether it is the right criterion is a
# human question and is gated separately.
#
# What these checks CANNOT catch, stated here because a gate that oversells
# itself is worse than no gate:
#
#   - Grammatically clean, semantically empty. `then: "returns a valid
#     response"` passes. The vagueness list is unbounded and always one word
#     behind.
#   - Falsifiable but testing the wrong thing. No text check ever reaches intent.
#   - A compound assertion hiding behind one verb: "returns a valid JWT".
#   - An AC that is already true. Only verify-red catches that — which is the
#     honest division of labour: spec-form checks an AC is written falsifiably,
#     verify-red checks it actually was.
#   - Incompleteness. Nothing mechanical ever catches a missing AC. That is
#     precisely why the human gate is at the input, and why the question put to
#     the human is "is anything missing", not "is this right".
#
# Structured meta fields are English by design: every proxy below is a word
# list, and per-language conjunction and verb tables would fail in ways nobody
# predicts. The narrative body is in whatever language the ticket is in.
#
# PROVENANCE. Every criterion declares `from`: either a verbatim fragment of
# ticket.md or the id of the assumption it rests on. The check is a literal
# substring lookup — no regex, no fuzzy match — and it is the one thing here
# that reaches past FORM into WHERE THE SCOPE CAME FROM. A criterion that can
# point at neither a sentence the human wrote nor a decision the spec recorded
# is scope nobody asked for, and until this field existed there was no place
# where that showed: spec-judge reads the ticket, but "does the ticket support
# this" is a judgement, and this is a lookup.
#
# The same idea one level down: an assumption declares `because` (what left the
# question open), `instead_of` (the road not taken) and `affects` (the criteria
# that rest on it). Those three are not decoration — they are what `aif explain`
# draws, and it can draw nothing the station did not write. An empty `affects`
# is NOT rejected: forcing a link would buy a plausible id instead of an honest
# gap. It is printed on the pass path, the way plan-form prints an unvalidated
# external surface.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source-path=SCRIPTDIR source=_lib.sh
. "$here/_lib.sh"

aif_g_need jq

work="${1:-}"
[ -n "$work" ] || aif_g_error "usage: spec-form.sh <work-dir>"

spec="$work/spec.md"
ticket="$work/ticket.md"
project="$(aif_g_project "$work")" || exit $?
meta="$(aif_g_meta_or_die "$spec" "spec.md")" || exit $?

# Not a rejection: without the ticket the provenance of every criterion is
# uncheckable, and a gate that cannot ask its question must not answer it.
[ -f "$ticket" ] || aif_g_error "ticket.md missing — a spec's provenance cannot be checked without it"

ac_max="$(jq -r '.limits.spec_ac_max // 15' "$project")"
ticket_re="$(jq -r '.ticket_pattern // "^[A-Z]{2,10}-[0-9]+$"' "$project")"
ticket_hash="$(aif_g_sha256 "$ticket")"

violations="$(
  printf '%s' "$meta" | jq -r \
    --argjson ac_max "$ac_max" \
    --arg ticket_re "$ticket_re" \
    --arg ticket_hash "$ticket_hash" '

    # Words that signal a judgement rather than an observation. Not exhaustive
    # and cannot be: this raises the floor, it does not establish falsifiability.
    def vague: [
      "appropriate","appropriately","correct","correctly","proper","properly",
      "as expected","reasonable","reasonably","sensible","valid","invalid",
      "gracefully","graceful","efficient","efficiently","robust","secure",
      "works","working","handled","handles","fast","quick","slow",
      "user-friendly","intuitive","seamless","good","nice","clean","optimal",
      "successfully","success","fails","error","errors"
    ];

    # An observable outcome names one of these. Exactly one — zero means nothing
    # is asserted, two means the AC is not atomic.
    def verbs: [
      "returns","equals","contains","raises","throws","emits","writes","logs",
      "responds with","has status","redirects to","matches","sets","is"
    ];

    def pad3: tostring
      | if length == 1 then "00" + . elif length == 2 then "0" + . else . end;

    def vague_hits($s):
      ($s | ascii_downcase) as $t
      | [ vague[] | select(. as $w | $t | test("\\b" + $w + "\\b")) ];

    def verb_hits($s):
      ($s | ascii_downcase) as $t
      | [ verbs[] | select(. as $w | $t | test("\\b" + $w + "\\b")) ];

    . as $m
    | ($m.acceptance // []) as $acs
    | ($m.surfaces // []) as $surfaces
    | ([ $acs[]?.id ]) as $ids
    | ([ ($m.assumptions // [])[]?.id ]) as $as_ids
    | [
      # ---- envelope ----------------------------------------------------
      (if ($m.schema? // null) != 2
        then "meta.schema must be 2 — a schema 1 spec predates the provenance "
             + "fields (acceptance.from, assumptions.because/instead_of/affects, "
             + "verification_gaps.leaves) and cannot be read as one; re-run the "
             + "spec station rather than hand-patching the number"
        else empty end),
      (if (($m.ticket? // "") | test($ticket_re) | not)
        then "meta.ticket \"" + ($m.ticket? // "") + "\" does not match " + $ticket_re
        else empty end),

      # The binding that makes a rework lapse everything downstream on its own:
      # any edit to ticket.md — a rework appended at approve, a clarification,
      # any route at all — breaks this match, the spec stops passing, and the
      # judge verdict and the human approval below it fall with it. Before this
      # field a reworked ticket kept an approval nobody granted for the new
      # content. The value arrives in the dispatch prompt; the station copies
      # it, exactly as the plan copies spec_sha256.
      (if ($m.ticket_sha256? // "") != $ticket_hash
        then "meta.ticket_sha256 does not match ticket.md as it is now — the "
             + "spec was written against a different ticket (or predates the "
             + "binding); re-run the spec station"
        else empty end),
      (if ($m.lang? // "") == ""
        then "meta.lang is required" else empty end),
      (if (["low","medium","high"] | index($m.risk? // "")) == null
        then "meta.risk must be one of low|medium|high" else empty end),
      (if ($surfaces | length) < 1
        then "meta.surfaces must name at least one surface" else empty end),
      (if ($m | has("assumptions") | not)
        then "meta.assumptions is required (may be [])" else empty end),

      # verification_gaps is a separate list because it holds a separate kind of
      # statement. An assumption says how the system BEHAVES; a gap says what
      # this run will NOT establish — "the device path is not exercised by the
      # suite". Filed together, the second dissolves into the first: a human
      # approved "the API is named get/set/delete" and "the target environment
      # is never verified" with one keystroke, and nothing referred to the
      # second again. aif never learns what "device" means; it learns that
      # statements of this class exist and are not allowed to disappear.
      (if ($m | has("verification_gaps") | not)
        then "meta.verification_gaps is required (may be []) — assumptions that "
             + "describe a LIMIT OF VERIFICATION rather than a behaviour belong "
             + "there, and only there"
        else empty end),
      (if ($m | has("non_goals") | not)
        then "meta.non_goals is required (may be [])" else empty end),
      (if ($acs | length) < 1
        then "meta.acceptance must contain at least one criterion" else empty end),
      (if ($acs | length) > $ac_max
        then "meta.acceptance has " + ($acs | length | tostring)
             + " criteria, limit is " + ($ac_max | tostring)
             + " — split the ticket" else empty end),
      (if ($ids | length) != ($ids | unique | length)
        then "duplicate AC ids" else empty end),

      # ---- per criterion -----------------------------------------------
      ( $acs
        | to_entries[]
        | .key as $i
        | .value as $ac
        | ("AC-" + (($i + 1) | pad3)) as $want
        | ($ac.id // "?") as $id
        | (
          # Contiguous from AC-001, so a deleted criterion is visible rather
          # than silently renumbered.
          (if $ac.id != $want
            then "acceptance[" + ($i | tostring) + "].id is \"" + $id
                 + "\", expected \"" + $want + "\" (ids must run from AC-001)"
            else empty end),

          (if (($ac.given? // "") | length) == 0
            then $id + ".given is empty" else empty end),
          (if (($ac.when? // "") | length) == 0
            then $id + ".when is empty" else empty end),
          (if (($ac.then? // "") | length) == 0
            then $id + ".then is empty" else empty end),

          # Naming the surface forces the criterion to say what it is about,
          # and cross-referencing an enum is the strongest cheap check there is.
          (if ($ac | has("surface") | not)
            then $id + ".surface is required"
            elif ($surfaces | index($ac.surface)) == null
            then $id + ".surface \"" + ($ac.surface | tostring)
                 + "\" is not in meta.surfaces"
            else empty end),

          # ---- falsifiability proxy ----
          # A literal expected value is what a test can assert against. Prose
          # here is the single most common way an AC becomes untestable.
          (if ($ac | has("expect") | not)
            then $id + ".expect is required — a test needs a literal to assert"
            else
              ($ac.expect | type) as $t
              | if ($t == "object" or $t == "array" or $t == "null")
                  then $id + ".expect must be a scalar, got " + $t
                elif ($t == "string" and (($ac.expect | split(" ") | length) > 4))
                  then $id + ".expect is prose (" + ($ac.expect | split(" ") | length | tostring)
                       + " words) — use a literal value"
                elif ($t == "string" and ((vague_hits($ac.expect) | length) > 0))
                  then $id + ".expect contains judgement word(s): "
                       + (vague_hits($ac.expect) | join(", "))
                else empty end
            end),

          (if (($ac.then? // "") | length) > 0
            then (vague_hits($ac.then)) as $v
              | if ($v | length) > 0
                  then $id + ".then contains judgement word(s): " + ($v | join(", "))
                       + " — say what is observable instead"
                  else empty end
            else empty end),

          # ---- atomicity proxy ----
          # An AC is atomic iff exactly one test failure attributes to it. That
          # is not a text property, so this is a proxy: exactly one assertion
          # verb, and no conjunctions joining two checks.
          (if (($ac.then? // "") | length) > 0
            then (verb_hits($ac.then)) as $vh
              | if ($vh | length) == 0
                  then $id + ".then asserts nothing — use one of: "
                       + (verbs | join(", "))
                elif ($vh | length) > 1
                  then $id + ".then has " + ($vh | length | tostring)
                       + " assertions (" + ($vh | join(", "))
                       + ") — split into separate criteria"
                else empty end
            else empty end),

          (if (($ac.then? // "") | test("\\b(and|or)\\b|;|&&"))
            then $id + ".then joins clauses — one criterion, one check"
            else empty end),

          (if (($ac.then? // "") | length) > 160
            then $id + ".then is " + (($ac.then | length) | tostring)
                 + " chars — over 160 suggests more than one check"
            else empty end),

          # ---- provenance ----
          # Two admissible answers and no third: a fragment of what the human
          # wrote, or the assumption this criterion rests on. The fragment
          # itself is looked up in ticket.md below, outside jq.
          (if ($ac | has("from") | not)
            then $id + ".from is required — a verbatim fragment of ticket.md, "
                 + "or the id of the assumption this criterion rests on"
            else ($ac.from | tostring) as $f
              | if ($f | length) == 0
                  then $id + ".from is empty"
                elif ($f | test("^AS-[0-9]{3}$"))
                  then (if ($as_ids | index($f)) == null
                         then $id + ".from names " + $f
                              + ", which is not an assumption in this spec"
                         else empty end)
                elif ($f | length) < 12
                  then $id + ".from is " + (($f | length) | tostring)
                       + " chars — too short to locate in the ticket; quote a "
                       + "phrase, or name the assumption it rests on instead"
                elif ($f | length) > 200
                  then $id + ".from is " + (($f | length) | tostring)
                       + " chars — quote a fragment, not the ticket"
                else empty end
            end)
        )
      ),

      # ---- cross references ---------------------------------------------
      ( ($m.assumptions // [])
        | to_entries[]
        | .key as $i
        | .value as $as
        | (
          (if ($as.id // "") | test("^AS-[0-9]{3}$") | not
            then "assumptions[" + ($i | tostring) + "].id must look like AS-001"
            else empty end),
          (if (($as.text? // "") | length) == 0
            then ($as.id // "assumption") + ".text is empty" else empty end),

          # The questions a reader asks, in the order they are asked. `text`
          # answers the second one only, which is why a spec of nothing but
          # `text` reads as a list of verdicts with no case behind them.
          #
          # No apostrophes anywhere in this jq program: it is single-quoted
          # shell, and one would end it here rather than at the closing quote.
          (if (($as.because? // "") | length) == 0
            then ($as.id // "assumption") + ".because is empty — say what in the "
                 + "ticket left this open, not what you decided about it"
            else empty end),
          (if (($as.instead_of? // "") | length) == 0
            then ($as.id // "assumption") + ".instead_of is empty — name the "
                 + "alternative you did not take; if there is none, the ticket "
                 + "already settled this and it is not an assumption"
            else empty end),
          (if ($as | has("affects") | not)
            then ($as.id // "assumption") + ".affects is required (may be []) — "
                 + "the criteria that rest on this decision"
            elif (($as.affects | type) != "array")
            then ($as.id // "assumption") + ".affects must be an array of AC ids"
            else ( $as.affects[]?
                   | select(. as $a | ($ids | index($a)) == null)
                   | ($as.id // "assumption") + ".affects names "
                     + (. | tostring) + ", which is not a criterion in this spec" )
            end)
        )
      ),
      ( [ ($m.assumptions // [])[].id ]
        | select(length != (unique | length))
        | "duplicate assumption ids — acceptance.from points at these by id" ),

      ( ($m.verification_gaps // [])
        | to_entries[]
        | .key as $i
        | .value as $vg
        | (
          (if ($vg.id // "") | test("^VG-[0-9]{3}$") | not
            then "verification_gaps[" + ($i | tostring) + "].id must look like VG-001"
            else empty end),
          (if (($vg.text? // "") | length) == 0
            then ($vg.id // "gap") + ".text is empty" else empty end),
          (if ($vg | has("leaves") | not)
            then ($vg.id // "gap") + ".leaves is required (may be []) — the "
                 + "criteria this gap leaves unproven"
            elif (($vg.leaves | type) != "array")
            then ($vg.id // "gap") + ".leaves must be an array of AC ids"
            else ( $vg.leaves[]?
                   | select(. as $a | ($ids | index($a)) == null)
                   | ($vg.id // "gap") + ".leaves names " + (. | tostring)
                     + ", which is not a criterion in this spec" )
            end)
        )
      ),
      ( [ ($m.verification_gaps // [])[].id ]
        | select(length != (unique | length))
        | "duplicate verification_gap ids" )
    ]
    | map(select(type == "string"))
    | .[]
  ' 2>&1
)" || aif_g_error "spec-form: jq failed — $violations"

# --- provenance: the quote has to be IN the ticket --------------------------
#
# Outside jq because it needs the other file, and a literal lookup rather than
# grep -F because bash's own case-glob with a quoted variable matches the
# fragment verbatim — no pattern to escape, no regex to get wrong.
#
# Both sides are normalised the same way, and only that way: newlines and tabs
# to spaces, runs of spaces squeezed, ends trimmed. A quote that wraps a line in
# ticket.md would otherwise fail a check it should pass, which teaches the
# station to quote nothing longer than a few words. Nothing else is normalised —
# no case folding, no punctuation stripping — because a paraphrase must not pass.
ticket_norm="$(tr '\n\t' '  ' <"$ticket" | tr -s ' ')"

fs_violations=""
while IFS="$(printf '\t')" read -r ac_id ac_from; do
  [ -n "$ac_id" ] || continue
  case "$ac_from" in
    AS-[0-9][0-9][0-9]) continue ;; # an assumption id; cross-referenced in jq
  esac
  from_norm="$(printf '%s' "$ac_from" | tr '\n\t' '  ' | tr -s ' ' |
    sed 's/^ *//; s/ *$//')"
  [ -n "$from_norm" ] || continue # empty is already a violation above
  case "$ticket_norm" in
    *"$from_norm"*) ;;
    *)
      fs_violations="$fs_violations
$ac_id.from is not in ticket.md verbatim: \"$from_norm\" — quote what the human wrote, or name the assumption this criterion rests on"
      ;;
  esac
done <<EOF
$(printf '%s' "$meta" | jq -r '.acceptance[]? | select(has("from")) | [.id, (.from | tostring)] | @tsv')
EOF

all="$(printf '%s\n%s' "$violations" "${fs_violations# }" | grep -v '^$' || true)"
aif_g_report "$all" "spec.md"

printf 'spec-form: %s criteria, all admissible' \
  "$(printf '%s' "$meta" | jq '.acceptance | length')"

gaps="$(printf '%s' "$meta" | jq '(.verification_gaps // []) | length')"
if [ "$gaps" -gt 0 ]; then
  printf ', %s verification gap(s)\n' "$gaps"
  printf '%s' "$meta" | jq -r '.verification_gaps[] | "  ! " + .id + ": " + .text'
  printf '  These are not behaviours. They are what this run will NOT establish.\n'
else
  printf '\n'
fi

# --- what passed, and what passed resting on nothing ------------------------
# On the PASS path, always, for the same reason plan-form prints its unvalidated
# external surface: an assumption no criterion depends on is one the suite will
# never contradict, however wrong it is. Not a rejection — forcing a link would
# buy a plausible AC id instead of an honest gap — but not silent either.
floating="$(printf '%s' "$meta" |
  jq -r '.assumptions[]? | select((.affects // []) | length == 0)
         | "    - " + .id + ": " + .text')"
if [ -n "$floating" ]; then
  printf '  ASSUMPTIONS THAT REST ON NOTHING — no criterion depends on these:\n'
  printf '%s\n' "$floating"
  printf '  Nothing in this cycle would fail if they were wrong.\n'
fi
