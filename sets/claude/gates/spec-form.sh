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

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source-path=SCRIPTDIR source=_lib.sh
. "$here/_lib.sh"

aif_g_need jq

work="${1:-}"
[ -n "$work" ] || aif_g_error "usage: spec-form.sh <work-dir>"

spec="$work/spec.md"
project="$(aif_g_project "$work")" || exit $?
meta="$(aif_g_meta_or_die "$spec" "spec.md")" || exit $?

ac_max="$(jq -r '.limits.spec_ac_max // 15' "$project")"
ticket_re="$(jq -r '.ticket_pattern // "^[A-Z]{2,10}-[0-9]+$"' "$project")"

violations="$(
  printf '%s' "$meta" | jq -r \
    --argjson ac_max "$ac_max" \
    --arg ticket_re "$ticket_re" '

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
    | [
      # ---- envelope ----------------------------------------------------
      (if ($m.schema? // null) != 1
        then "meta.schema must be 1" else empty end),
      (if (($m.ticket? // "") | test($ticket_re) | not)
        then "meta.ticket \"" + ($m.ticket? // "") + "\" does not match " + $ticket_re
        else empty end),
      (if ($m.lang? // "") == ""
        then "meta.lang is required" else empty end),
      (if (["low","medium","high"] | index($m.risk? // "")) == null
        then "meta.risk must be one of low|medium|high" else empty end),
      (if ($surfaces | length) < 1
        then "meta.surfaces must name at least one surface" else empty end),
      (if ($m | has("assumptions") | not)
        then "meta.assumptions is required (may be [])" else empty end),
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
            else empty end)
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
            then ($as.id // "assumption") + ".text is empty" else empty end)
        )
      )
    ]
    | map(select(type == "string"))
    | .[]
  ' 2>&1
)" || aif_g_error "spec-form: jq failed — $violations"

aif_g_report "$violations" "spec.md"

printf 'spec-form: %s criteria, all admissible\n' \
  "$(printf '%s' "$meta" | jq '.acceptance | length')"
