#!/usr/bin/env bash
#
# `aif explain <ticket>` — the reasoning behind a ticket's artifacts, drawn.
# Sourced by bin/aif; not meant to be executed directly.
#
# This command runs no model and costs nothing. That is not an optimisation, it
# is the whole design: a picture of "how the agent got here" that a model draws
# by reading the finished artifact is a plausible story about the artifact, not
# a record of anything, and it would raise a reader confidence no gate had
# earned. So this renders ONLY fields the stations wrote while deciding and the
# gates check afterwards — acceptance.from, assumptions.because/instead_of/
# affects, decisions.because/serves. It can draw nothing that was not written,
# and nothing it draws is unchecked.
#
# Derived, like everything else here. explain.md is regenerated, never edited,
# and it records the sha256 of the artifacts it was drawn from so a stale copy
# is visible as stale rather than confidently wrong.
#
# It lives under tasks/ with the rest of the ticket, which is also what keeps it
# out of scope's way: scope diffs the working tree and tasks/ is on its
# denylist, so generating this mid-cycle cannot dirty an implementation station.

_aif_explain_usage() {
  cat <<EOF
usage: aif explain <ticket> [options]

  Draws the chain behind a ticket: what in the ticket each criterion came from,
  which assumptions it rests on, and which decisions the plan made for it.

options:
  --spec            only the specification
  --plan            only the plan
  --format mermaid  write tasks/<ticket>/explain.md (default)
  --format tree     print an indented tree to stdout instead
  --auto <moment>   called by the orchestrator at "approve" or "plan"; honours
                    the project's explain.auto setting and does nothing when it
                    is off. Typing the command by hand always renders.
EOF
}

# Labels and ids, sanitised for mermaid. Kept in one place because every node
# below needs both and mermaid fails as a whole diagram, not per node: one
# unescaped bracket and the reader gets a parse error instead of a picture.
# shellcheck disable=SC2016  # a jq program, quoted so the shell leaves it alone
_AIF_EXPLAIN_JQ_PRELUDE='
  def clip($n): if (length > $n) then (.[0:$n] + "…") else . end;
  def lbl($n): tostring
    | gsub("[\n\r\t]"; " ")
    | gsub("\""; "#quot;")
    | gsub("[\\[\\]{}()<>|#]"; " ")
    | gsub(" +"; " ")
    | sub("^ +"; "") | sub(" +$"; "")
    | clip($n);
  def nid: tostring | gsub("[^A-Za-z0-9_]"; "_");
'

# _aif_explain_spec <spec.md> <format> — the specification chain.
_aif_explain_spec() {
  local spec="$1" format="$2" meta
  meta="$(aif_meta_json "$spec")"

  if [ "$(printf '%s' "$meta" | jq -r '.schema // 0')" != "2" ]; then
    printf 'spec.md is schema %s — it predates the provenance fields, so there is no chain to draw.\n' \
      "$(printf '%s' "$meta" | jq -r '.schema // "?"')"
    printf 'Re-run the spec station to get one.\n'
    return 0
  fi

  printf '%s' "$meta" | jq -r --arg format "$format" "$_AIF_EXPLAIN_JQ_PRELUDE"'
    . as $m
    | ([ .acceptance[]? | select(((.from // "") | test("^AS-[0-9]{3}$")) | not)
         | (.from // "") | select(length > 0) ] | unique) as $quotes
    | ($quotes | to_entries | map({ key: .value, value: ("T" + (.key | tostring)) })
       | from_entries) as $qid
    | if $format == "tree" then
        ( "specification"
        , ( $m.acceptance[]?
            | . as $ac
            | "  " + $ac.id + " — " + ($ac.then // "") + " → " + ($ac.expect | tostring)
            , ( if (($ac.from // "") | test("^AS-[0-9]{3}$"))
                  then "    rests on " + $ac.from
                  else "    from the ticket: \"" + ($ac.from // "") + "\"" end ) )
        , ( if (($m.assumptions // []) | length) > 0 then "  assumptions" else empty end )
        , ( $m.assumptions[]?
            | "    " + .id + " — " + .text
            , "      because       " + (.because // "")
            , "      instead of    " + (.instead_of // "")
            , "      carries       " + (if ((.affects // []) | length) > 0
                                        then ((.affects // []) | join(", "))
                                        else "nothing — no criterion depends on it" end) )
        , ( if (($m.verification_gaps // []) | length) > 0 then "  not established by this cycle" else empty end )
        , ( $m.verification_gaps[]?
            | "    " + .id + " — " + .text
            , "      leaves unproven " + (if ((.leaves // []) | length) > 0
                                          then ((.leaves // []) | join(", "))
                                          else "no criterion in particular" end) ) )
      else
        ( "```mermaid"
        , "flowchart LR"
        , ( $quotes[]? | "  " + $qid[.] + "(\"" + (. | lbl(90)) + "\")" )
        , ( $m.acceptance[]?
            | "  " + (.id | nid) + "[\"" + (.id | lbl(12)) + " — "
              + ((.then // "") | lbl(60)) + " → " + ((.expect | tostring) | lbl(20)) + "\"]" )
        , ( $m.assumptions[]?
            | "  " + (.id | nid) + "{{\"" + (.id | lbl(12)) + " — " + (.text | lbl(70)) + "\"}}" )
        , ( $m.verification_gaps[]?
            | "  " + (.id | nid) + "[/\"" + (.id | lbl(12)) + " — " + (.text | lbl(70)) + "\"/]" )
        , ( $m.acceptance[]?
            | select((((.from // "") | test("^AS-[0-9]{3}$")) | not) and ((.from // "") | length) > 0)
            | "  " + $qid[.from] + " --> " + (.id | nid) )
        , ( $m.acceptance[]?
            | select(((.from // "") | test("^AS-[0-9]{3}$")))
            | "  " + (.from | nid) + " -->|\"exists only because of this\"| " + (.id | nid) )
        , ( $m.assumptions[]?
            | . as $as | ($as.affects // [])[]?
            | . as $acid
            | select([ $m.acceptance[]? | select(.id == $acid) | (.from // "") ]
                     | index($as.id) | not)
            | "  " + ($as.id | nid) + " -.->|\"rests on\"| " + ($acid | nid) )
        , ( $m.verification_gaps[]?
            | . as $vg | ($vg.leaves // [])[]?
            | "  " + ($vg.id | nid) + " -.->|\"leaves unproven\"| " + (. | nid) )
        , "```"
        , ""
        , "### Assumptions — the decisions the ticket did not make"
        , ""
        , ( $m.assumptions[]?
            | "**" + .id + " — " + .text + "**"
            , ""
            , "- the ticket left it open: " + (.because // "—")
            , "- instead of: " + (.instead_of // "—")
            , "- carries: " + (if ((.affects // []) | length) > 0
                               then ((.affects // []) | join(", "))
                               else "**nothing — no criterion depends on it, so nothing would fail if it were wrong**" end)
            , "" )
        , ( if (($m.verification_gaps // []) | length) > 0
            then ( "### What this cycle will not establish", "" ) else empty end )
        , ( $m.verification_gaps[]?
            | "- **" + .id + "** " + .text
              + " (leaves unproven: "
              + (if ((.leaves // []) | length) > 0
                 then ((.leaves // []) | join(", "))
                 else "no criterion in particular" end) + ")" )
        , "" )
      end
  '
}

# _aif_explain_plan <plan.md> <format> — the plan chain.
_aif_explain_plan() {
  local plan="$1" format="$2" meta
  meta="$(aif_meta_json "$plan")"

  if [ "$(printf '%s' "$meta" | jq -r '.schema // 0')" != "2" ]; then
    printf 'plan.md is schema %s — it predates decisions.because and decisions.serves.\n' \
      "$(printf '%s' "$meta" | jq -r '.schema // "?"')"
    printf 'Re-run the plan station to get a chain.\n'
    return 0
  fi

  printf '%s' "$meta" | jq -r --arg format "$format" "$_AIF_EXPLAIN_JQ_PRELUDE"'
    . as $m
    | ([ (.ac_coverage // {})[]? ] | flatten | unique) as $files
    | ($files | to_entries | map({ key: .value, value: ("F" + (.key | tostring)) })
       | from_entries) as $fid
    | if $format == "tree" then
        ( "plan"
        , ( $m.decisions[]?
            | "  " + .id + " — " + .statement
            , "      because   " + (.because // "")
            , ( if ((.rejected // "") | length) > 0 then "      not       " + .rejected else empty end )
            , "      serves    " + (if ((.serves // []) | length) > 0
                                    then ((.serves // []) | join(", "))
                                    else "nothing the spec asked for" end) )
        , ( if ((.ac_coverage // {}) | length) > 0 then "  criteria, and where they land" else empty end )
        , ( (.ac_coverage // {}) | to_entries[]?
            | "    " + .key + " → " + (.value | join(", ")) )
        , ( if (($m.external // []) | length) > 0 then "  external surface" else empty end )
        , ( $m.external[]?
            | "    " + .name + " — " + (if (.check // null) != null then "checked by " + .check
                                        elif (.ac // null) != null then "exercised by " + .ac
                                        else "NOTHING VALIDATES THIS" end) ) )
      else
        ( "```mermaid"
        , "flowchart LR"
        , ( $m.decisions[]?
            | "  " + (.id | nid) + "[\"" + (.id | lbl(12)) + " — " + (.statement | lbl(70)) + "\"]" )
        , ( (.ac_coverage // {}) | keys[]?
            | "  " + (. | nid) + "([\"" + (. | lbl(12)) + "\"])" )
        , ( $files[]? | "  " + $fid[.] + "[/\"" + (. | lbl(50)) + "\"/]" )
        , ( $m.decisions[]?
            | . as $d | ($d.serves // [])[]?
            | "  " + ($d.id | nid) + " -->|\"serves\"| " + (. | nid) )
        , ( (.ac_coverage // {}) | to_entries[]?
            | . as $e | $e.value[]?
            | "  " + ($e.key | nid) + " --> " + $fid[.] )
        , ( $m.external[]?
            | select((.check // null) == null and (.ac // null) == null)
            | "  X" + (.name | nid) + "{{\"" + (.name | lbl(40)) + " — nothing validates this\"}}" )
        , "```"
        , ""
        , "### Decisions — what was settled so the implementer does not guess"
        , ""
        , ( $m.decisions[]?
            | "**" + .id + " — " + .statement + "**"
            , ""
            , "- because: " + (.because // "—")
            , ( if ((.rejected // "") | length) > 0 then "- rather than: " + .rejected else empty end )
            , "- serves: " + (if ((.serves // []) | length) > 0
                              then ((.serves // []) | join(", "))
                              else "**nothing the spec asked for**" end)
            , "" )
        , ( if (($m.external // []) | length) > 0
            then ( "### External surface", "" ) else empty end )
        , ( $m.external[]?
            | "- **" + .name + "** — "
              + (if (.check // null) != null then "checked by `" + .check + "`"
                 elif (.ac // null) != null then "exercised by " + .ac
                 else "**nothing in this run validates this**" end) )
        , "" )
      end
  '
}

aif_cmd_explain() {
  local ticket="" format="mermaid" want_spec=0 want_plan=0 moment=""

  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help)
        _aif_explain_usage
        return 0
        ;;
      --spec) want_spec=1 ;;
      --plan) want_plan=1 ;;
      --format)
        shift
        format="${1:-mermaid}"
        ;;
      --auto)
        shift
        moment="${1:-}"
        ;;
      -*) aif_die "unknown option: $1" ;;
      *) ticket="$1" ;;
    esac
    shift
  done

  [ -n "$ticket" ] || {
    _aif_explain_usage >&2
    aif_die "usage: aif explain <ticket>"
  }
  case "$format" in
    mermaid | tree) ;;
    *) aif_die "unknown format: $format (mermaid | tree)" ;;
  esac

  local root work
  root="$(aif_require_project)"
  work="$(aif_task_dir "$root" "$ticket")"
  [ -d "$work" ] || aif_die "no such ticket: $ticket"

  # The toggle applies to the orchestrator calling this on its own schedule, and
  # only there. A person who typed the command has answered the question the
  # setting exists to answer.
  if [ -n "$moment" ] && ! aif_explain_enabled "$root" "$moment"; then
    printf 'explain: off for this project at "%s" (explain.auto = %s)\n' \
      "$moment" "$(aif_explain_auto "$root")"
    return 0
  fi

  # Neither flag means both, as far as the artifacts exist.
  if [ "$want_spec" -eq 0 ] && [ "$want_plan" -eq 0 ]; then
    want_spec=1
    want_plan=1
  fi

  local spec="$work/spec.md" plan="$work/plan.md"
  [ "$want_spec" -eq 1 ] && [ ! -f "$spec" ] && want_spec=0
  [ "$want_plan" -eq 1 ] && [ ! -f "$plan" ] && want_plan=0

  if [ "$want_spec" -eq 0 ] && [ "$want_plan" -eq 0 ]; then
    aif_die "nothing to draw for $ticket — no spec.md, no plan.md"
  fi

  if [ "$format" = "tree" ]; then
    [ "$want_spec" -eq 1 ] && _aif_explain_spec "$spec" tree
    [ "$want_plan" -eq 1 ] && _aif_explain_plan "$plan" tree
    return 0
  fi

  local out="$work/explain.md"
  # Everything written here is markdown: the backticks are code spans, not
  # command substitution, and the single quotes are what keeps them that way.
  # shellcheck disable=SC2016
  {
    printf '# %s — how this was arrived at\n\n' "$ticket"
    printf 'Generated by `aif explain`. Every line below was written by a station\n'
    printf 'while it decided and is checked by that station gate — nothing here is\n'
    printf 'narrated after the fact. Regenerate it; do not edit it.\n\n'

    if [ "$want_spec" -eq 1 ]; then
      printf -- '## Specification\n\n'
      _aif_explain_spec "$spec" mermaid
    fi
    if [ "$want_plan" -eq 1 ]; then
      printf -- '## Plan\n\n'
      _aif_explain_plan "$plan" mermaid
    fi

    # The bindings. A drawing of an artifact that has since changed is worse
    # than no drawing, so it says which bytes it was drawn from and the reader
    # can tell.
    printf -- '---\n\n'
    printf 'Drawn from:\n\n'
    [ "$want_spec" -eq 1 ] && printf -- '- `spec.md` sha256 `%s`\n' "$(aif_sha256 "$spec")"
    [ "$want_plan" -eq 1 ] && printf -- '- `plan.md` sha256 `%s`\n' "$(aif_sha256 "$plan")"
    printf '\nIf those no longer match the files, this drawing is stale — run `aif explain %s` again.\n' "$ticket"
  } >"$out.tmp" && mv "$out.tmp" "$out"

  printf '%s\n' "${out#"$root"/}"
}
