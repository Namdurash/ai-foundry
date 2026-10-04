#!/usr/bin/env bash
#
# Gate: ready — is the ticket buildable as it stands? The Definition of Ready.
#
# ONE script, TWO callers, and that is the point. The analyst runs it at the end
# of the conversation, while the human is still in the room and has maximum
# context; the worker runs it at intake, before the first token. If those were
# two implementations they would drift, and the worker would start refusing
# what the analyst had passed — the class of defect scripts/check-set.sh exists
# to catch between the two readers of a station file.
#
# What it checks is the ticket's CONTRACT with the machine, not its quality:
#
#   - acceptance criteria exist, run AC-001, AC-002, … without a gap, each
#     names a surface, and each carries a literal `expect` a test can assert
#     against. That literal is the one property that turns prose into an
#     oracle: verify-red later greps for it in a test file;
#   - the rules, when the ticket has them, run R-1, R-2, … without a gap, each
#     a sentence with at least one criterion naming it, and every criterion
#     names one. A criterion is an EXAMPLE of a rule, and the size cap counts
#     rules: a person's acceptance criterion is a rule, and the old cap on
#     examples made the analyst cut ordinary stories into fragments
#     (docs/DEFECTS.md 12.1). Over the cap, only the human keeps a ticket
#     whole — a `decided` entry of kind `size`, by human. Examples keep a
#     backstop of their own. A ticket without rules is capped on its criteria,
#     as before;
#   - every open question is answered or its default accepted: `open` is empty
#     and `decided` says what was chosen and by whom. A question the human did
#     not answer is decided by default and SAID SO, on the pass path — it is
#     never silently dropped;
#   - a verification gap, when recorded, says what it leaves unproven, so it
#     can come back on the closing checklist.
#
# It does not judge whether the criteria are the RIGHT ones. That stayed with
# the human, in the conversation, which is where it always belonged; the gates
# downstream verify that the code matches the criteria, and nothing here can
# verify that the criteria match the intent.
#
# Exit 0 ready · 1 not ready, one reason per line — the analyst's next
# question, or the worker's report · 3 the gate could not run.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source-path=SCRIPTDIR source=_lib.sh
. "$here/_lib.sh"

aif_g_need jq

work="${1:-}"
[ -n "$work" ] || aif_g_error "usage: ready.sh <work-dir>"

ticket="$work/ticket.md"
project="$(aif_g_project "$work")" || exit $?

[ -f "$ticket" ] || aif_g_reject "ticket.md missing — nothing to build"

# The scaffold's own placeholder is not a ticket. Named here so the two callers
# say the same thing about it.
if grep -q "Describe the need in your own words" "$ticket" 2>/dev/null; then
  aif_g_reject "ticket.md is still the scaffold stub — write the need into it (/aif-ba)"
fi

meta="$(aif_g_meta_or_die "$ticket" "ticket.md")" || exit $?

# The caps. ticket_ac_max is the old one, on the criteria of a ticket without
# rules; the other three are read only when the ticket has rules. Each falls
# back to the template's value, which is what `aif project check` says when the
# key is missing from project.json.
ac_max="$(jq -r '.limits.ticket_ac_max // .limits.spec_ac_max // 15' "$project")"
rules_max="$(jq -r '.limits.ticket_rules_max // 6' "$project")"
examples_max="$(jq -r '.limits.ticket_examples_max // 30' "$project")"
rule_warn="$(jq -r '.limits.rule_examples_warn // 5' "$project")"
ticket_re="$(jq -r '.ticket_pattern // "^[A-Z]{2,10}-[0-9]+$"' "$project")"
want_id="$(basename "$(cd "$work" && pwd -P)")"

violations="$(
  printf '%s' "$meta" | jq -r \
    --argjson ac_max "$ac_max" \
    --argjson rules_max "$rules_max" \
    --argjson examples_max "$examples_max" \
    --arg ticket_re "$ticket_re" \
    --arg want_id "$want_id" '

    # Words that signal a judgement where a test needs a value. Checked on
    # `expect` only — `then` is prose the human wrote with the analyst, and
    # policing its wording was where the old spec gate spent opus runs on
    # nothing. A fully-backticked expect is a literal by declaration (`error`
    # the union value) and skips the list; the gates that read it strip the
    # backticks.
    def vague: ["appropriate","correct","correctly","proper","properly",
                "as expected","reasonable","valid","invalid","gracefully",
                "works","working","handled","successfully","ok"];
    def pad3: tostring
      | if length == 1 then "00" + . elif length == 2 then "0" + . else . end;
    def vague_hits($s):
      ($s | ascii_downcase) as $t
      | [ vague[] | select(. as $w | $t | test("\\b" + $w + "\\b")) ];

    . as $m
    | ($m.acceptance // []) as $acs
    | ($m.surfaces // []) as $surfaces
    | ([ $acs[]?.id ]) as $ids
    | ($m | has("rules")) as $has_rules
    | (if ($m.rules | type) == "array" then $m.rules else [] end) as $rules
    | ([ $rules[]? | objects | .id ]) as $rule_ids
    | ([ ($m.decided // [])[]? | objects
         | select(.kind == "size" and (.by // "human") == "human") ] | length > 0) as $kept_whole
    | [
      # ---- envelope ----------------------------------------------------
      (if ($m.schema? // null) != 2
        then "meta.schema must be 2 — a schema 1 ticket carries no criteria; "
             + "the analyst writes them now (/aif-ba)"
        else empty end),
      (if ($m.ticket? // "") != $want_id
        then "meta.ticket \"" + ($m.ticket? // "") + "\" is not this directory (" + $want_id + ")"
        else empty end),
      (if (($m.ticket? // "") | test($ticket_re) | not)
        then "meta.ticket \"" + ($m.ticket? // "") + "\" does not match " + $ticket_re
        else empty end),
      (if ($m.lang? // "") == "" then "meta.lang is required" else empty end),
      (if (["low","medium","high"] | index($m.risk? // "")) == null
        then "meta.risk must be one of low|medium|high — it picks the implementation engine"
        else empty end),
      (if ($surfaces | length) < 1
        then "meta.surfaces must name at least one observable interface"
        else empty end),
      (if ($acs | length) < 1
        then "meta.acceptance is empty — a ticket with no criterion has no definition of done"
        else empty end),
      (if ($has_rules | not) and (($acs | length) > $ac_max)
        then "meta.acceptance has " + ($acs | length | tostring)
             + " criteria, and a ticket without rules is held to " + ($ac_max | tostring)
             + " — group them under meta.rules, each criterion naming its rule: the limit then counts rules ("
             + ($rules_max | tostring) + "), and examples only up to " + ($examples_max | tostring)
        else empty end),
      (if ($ids | length) != ($ids | unique | length) then "duplicate AC ids" else empty end),

      # ---- rules: what the criteria are examples of ----------------------
      # The cap counts these. Over it, the order is the one the analyst works
      # by — restate, then an axis of variation, then the human — and never a
      # ticket that holds the remainder of another (docs/DEFECTS.md 12.1).
      (if $has_rules and (($m.rules | type) != "array")
        then "meta.rules must be a list of { \"id\": \"R-1\", \"text\": \"<the rule, in a sentence>\" }"
        elif $has_rules and (($rules | length) == 0)
        then "meta.rules is empty — write the rules the criteria are examples of, or leave the key out"
        else empty end),
      (if $has_rules and (($rules | length) > $rules_max) and ($kept_whole | not)
        then "meta.rules has " + ($rules | length | tostring) + " rules, limit is " + ($rules_max | tostring)
             + " — in this order: a rule that only lists cases is restated, not split; then split along an axis of"
             + " variation (a path, a rule, the data, an interface), each part a behaviour of its own; with no such"
             + " axis the user keeps it whole: a decided entry of kind size, by human. Never a ticket that holds"
             + " the remainder of another"
        else empty end),
      (if $has_rules and (($acs | length) > $examples_max)
        then "meta.acceptance has " + ($acs | length | tostring) + " criteria, and the backstop is "
             + ($examples_max | tostring) + " — keep the key examples of each rule (the typical case, each"
             + " boundary that changes the outcome, the nearest counter-example); every other combination"
             + " is for the tests station to cover"
        else empty end),
      ( $rules | to_entries[]
        | .key as $i | .value as $r
        | ("R-" + (($i + 1) | tostring)) as $want
        | if ($r | type) != "object"
            then "rules[" + ($i | tostring) + "] must be { \"id\": \"" + $want + "\", \"text\": \"…\" }"
          else (
            (if ($r.id // "") != $want
              then "rules[" + ($i | tostring) + "].id is \"" + (($r.id // "?") | tostring)
                   + "\", expected \"" + $want + "\" (ids run from R-1 without gaps)"
              else empty end),
            (if (($r.text // "") | tostring | length) == 0
              then $want + ".text is empty — the rule, in one sentence" else empty end),
            (if ([ $acs[]? | select(.rule? == $r.id) ] | length) == 0
              then (($r.id // $want) | tostring) + " has no criterion — a rule no example illustrates is"
                   + " not tested; give it its key example, or drop it"
              else empty end)
          ) end
      ),

      # ---- per criterion -----------------------------------------------
      ( $acs | to_entries[]
        | .key as $i | .value as $ac
        | ("AC-" + (($i + 1) | pad3)) as $want
        | ($ac.id // "?") as $id
        | (
          (if $ac.id != $want
            then "acceptance[" + ($i | tostring) + "].id is \"" + $id
                 + "\", expected \"" + $want + "\" (ids run from AC-001 without gaps)"
            else empty end),
          (if (($ac.given? // "") | length) == 0 then $id + ".given is empty" else empty end),
          (if (($ac.when? // "") | length) == 0 then $id + ".when is empty" else empty end),
          (if (($ac.then? // "") | length) == 0 then $id + ".then is empty" else empty end),
          (if (($ac.then? // "") | test("&&|;")) then $id + ".then joins checks — one criterion, one check" else empty end),
          (if ($ac | has("surface") | not)
            then $id + ".surface is required"
            elif ($surfaces | index($ac.surface)) == null
            then $id + ".surface \"" + ($ac.surface | tostring) + "\" is not in meta.surfaces"
            else empty end),
          (if $has_rules then
             (if ($ac | has("rule") | not)
               then $id + ".rule is required — the rule in meta.rules this criterion is an example of"
               elif ($rule_ids | index($ac.rule)) == null
               then $id + ".rule \"" + ($ac.rule | tostring) + "\" is not in meta.rules"
               else empty end)
           elif ($ac | has("rule"))
             then $id + ".rule names " + ($ac.rule | tostring) + ", and the ticket has no meta.rules"
           else empty end),
          (if ($ac | has("expect") | not)
            then $id + ".expect is required — the literal a test asserts against"
            else ($ac.expect | type) as $t
              | if ($t == "object" or $t == "array" or $t == "null")
                  then $id + ".expect must be a scalar, got " + $t
                elif ($t == "string" and (($ac.expect | length) == 0))
                  then $id + ".expect is empty"
                elif ($t == "string" and (($ac.expect | split(" ") | length) > 6))
                  then $id + ".expect is prose (" + ($ac.expect | split(" ") | length | tostring)
                       + " words) — a test needs a literal value"
                elif ($t == "string" and (($ac.expect | test("^`[^`]+`$")) | not)
                      and ((vague_hits($ac.expect) | length) > 0))
                  then $id + ".expect is a judgement (" + (vague_hits($ac.expect) | join(", "))
                       + ") — name the value; a domain literal on that list is written in backticks"
                else empty end
            end)
        )
      ),

      # ---- open questions: the Definition of Ready proper ----------------
      # Not an error in the ticket — the next question for the human. Each line
      # is one they can answer in a sentence, or accept the default of.
      ( ($m.open // []) | to_entries[]
        | .key as $i | .value as $q
        | "open question " + ($q.id // ("#" + ($i | tostring))) + ": "
          + ($q.question // "(no question text)")
          + (if (($q.default // "") | length) > 0 then " — default: " + $q.default
             else " — no default proposed" end) ),

      # ---- decisions: what was chosen, and by whom ---------------------
      ( ($m.decided // []) | to_entries[]
        | .key as $i | .value as $d
        | (
          (if (($d.question // "") | length) == 0
            then "decided[" + ($i | tostring) + "].question is empty" else empty end),
          (if (($d.answer // "") | length) == 0
            then "decided[" + ($i | tostring) + "].answer is empty — a decision with no answer is an open question"
            else empty end),
          (if (["human","default"] | index($d.by // "human")) == null
            then "decided[" + ($i | tostring) + "].by must be human or default" else empty end),
          # Keeping a ticket whole over the cap is the one size decision, and
          # it is the user to take: a default here would be the analyst
          # lifting its own limit.
          (if ($d.kind // "") == "size" and ($d.by // "human") != "human"
            then "decided[" + ($i | tostring) + "] keeps the ticket whole by default — a size decision"
                 + " is for the user to take: by human, or not at all"
            else empty end)
        )
      ),

      # ---- gaps: what this cycle will not establish ---------------------
      ( ($m.verification_gaps // []) | to_entries[]
        | .key as $i | .value as $g
        | ("VG-" + (($i + 1) | pad3)) as $want
        | (
          (if ($g.id // "") != $want
            then "verification_gaps[" + ($i | tostring) + "].id is \"" + ($g.id // "?")
                 + "\", expected \"" + $want + "\"" else empty end),
          (if (($g.text // "") | length) == 0
            then ($g.id // "gap") + ".text is empty" else empty end),
          (if ($g | has("leaves") | not) or (($g.leaves | type) != "array")
            then ($g.id // "gap") + ".leaves is required — the criteria it leaves unproven, [] if none in particular"
            else ( $g.leaves[]? | select(. as $x | ($ids | index($x)) == null)
                   | ($g.id // "gap") + ".leaves names " + (. | tostring) + ", which is not a criterion" )
            end)
        )
      )
    ]
    | map(select(type == "string"))
    | .[]
  ' 2>&1
)" || aif_g_error "ready: jq failed — $violations"

# The narrative is the human's own account of the need, and a ticket that is
# criteria alone has lost it. One real line will do.
body_lines="$(awk 'f && !/^#/ && !/^[[:space:]]*$/ && !/^<!--/ { n++ } /^-->$/ { f = 1 } END { print n + 0 }' "$ticket")"
if [ "${body_lines:-0}" -eq 0 ]; then
  violations="$(printf '%s\n%s' "$violations" "the narrative is empty — say the need in the human's words, not only in criteria")"
fi

# On a Trello board the ticket IS the card's description, and Trello holds a
# description to 16384 characters, counted as JavaScript counts them (one for
# a letter of Latin or Cyrillic, two for an emoji). A ticket over that passed
# this gate and was refused by the board with a bare 400, after the analyst
# had finished with it (docs/DEFECTS.md 10.2). Said here, while the text can
# still be cut: `wc -c` would say bytes, nearly twice the count for Ukrainian.
if [ "$(jq -r '.board.kind // "local"' "$project" 2>/dev/null)" = "trello" ]; then
  desc_max=16384
  desc_len="$(jq -Rs '[explode[] | if . > 65535 then 2 else 1 end] | add // 0' "$ticket" 2>/dev/null || printf 0)"
  if [ "${desc_len:-0}" -gt "$desc_max" ]; then
    violations="$(printf '%s\n%s' "$violations" "the ticket is $desc_len characters, and a Trello card's description holds $desc_max — the board would refuse it; cut the narrative first, then the longest decided answers ($((desc_len - desc_max)) to go, counted as Trello counts: one per letter, two per emoji)")"
  fi
fi

all="$(printf '%s' "$violations" | grep -v '^$' || true)"
aif_g_report "$all" "ticket.md"

n_ac="$(printf '%s' "$meta" | jq '.acceptance | length')"
n_dec="$(printf '%s' "$meta" | jq '(.decided // []) | length')"
n_gap="$(printf '%s' "$meta" | jq '(.verification_gaps // []) | length')"
n_rules="$(printf '%s' "$meta" | jq 'if has("rules") then (.rules | length) else -1 end')"
if [ "$n_rules" -ge 0 ]; then
  printf 'ready: %s rule(s) · %s criteria · %s decided · %s gap(s)\n' "$n_rules" "$n_ac" "$n_dec" "$n_gap"
else
  printf 'ready: %s criteria · %s decided · %s gap(s)\n' "$n_ac" "$n_dec" "$n_gap"
fi

# On the PASS path, always: a ticket the human kept whole over the cap, and a
# rule crowded with examples. The first is a decision a reviewer must see; the
# second is not wrong, only the shape that most often hides two rules, or a
# concept the ticket has not named (docs/DEFECTS.md 12.1).
if [ "$n_rules" -gt "$rules_max" ]; then
  kept="$(printf '%s' "$meta" | jq -r '.decided[]? | select(.kind == "size" and (.by // "human") == "human") | "    - " + .question + " → " + .answer')"
  printf '  KEPT WHOLE BY THE HUMAN — %s rules, over the limit of %s:\n' "$n_rules" "$rules_max"
  printf '%s\n' "$kept"
fi
crowded="$(printf '%s' "$meta" | jq -r --argjson warn "$rule_warn" '
  (.acceptance // []) as $acs
  | (.rules // [])[] | objects | .id as $r | (.text // "") as $text
  | [ $acs[] | select(.rule == $r) | .id ] as $ex
  | select(($ex | length) > $warn)
  | "    - " + $r + ": " + ($ex | length | tostring) + " examples (" + ($ex | join(", ")) + ") — " + $text')"
if [ -n "$crowded" ]; then
  printf '  MANY EXAMPLES ON ONE RULE — over %s; often two rules, or a concept not yet named:\n' "$rule_warn"
  printf '%s\n' "$crowded"
fi

# On the PASS path, always: what was decided by default rather than by the
# human is exactly what a reviewer must not be unaware of. Same rule as
# the plan gate's unvalidated surface and scope's amendments.
defaults="$(printf '%s' "$meta" | jq -r '.decided[]? | select(.by == "default") | "    - " + .question + " → " + .answer')"
if [ -n "$defaults" ]; then
  printf '  DECIDED BY DEFAULT — the human did not answer these; the analyst took the default:\n'
  printf '%s\n' "$defaults"
fi
gaps="$(printf '%s' "$meta" | jq -r '.verification_gaps[]? | "    - " + .id + ": " + .text')"
if [ -n "$gaps" ]; then
  printf '  NOT ESTABLISHED BY THIS CYCLE — re-emitted on the closing checklist:\n'
  printf '%s\n' "$gaps"
fi
