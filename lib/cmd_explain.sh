#!/usr/bin/env bash
#
# `aif explain <ticket>` — the reasoning behind a ticket's artifacts, drawn.
# Sourced by bin/aif; not meant to be executed directly.
#
# This command runs no model and costs nothing. That is not an optimisation, it
# is the whole design: a picture of "how the agent got here" that a model draws
# by reading the finished artifact is a plausible story about the artifact, not
# a record of anything, and it would raise a reader confidence no gate had
# earned. So this renders ONLY fields the analyst and the stations wrote while
# deciding and the gates check afterwards — the ticket's acceptance, decided and
# verification_gaps; the plan's decisions.because/serves. It can draw nothing
# that was not written, and nothing it draws is unchecked.
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

  Draws the chain behind a ticket: its criteria by surface, what was decided
  with the analyst (and what fell to a default), what this cycle will not
  establish, and which decisions the plan made for it.

options:
  --ticket          only the ticket
  --plan            only the plan
  --format mermaid  write tasks/<ticket>/explain.md (default)
  --format tree     print an indented tree to stdout instead
  --auto <moment>   called by a skill at "ready" or "plan"; honours the
                    project's explain.auto setting and does nothing when it is
                    off. Typing the command by hand always renders.
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

# _aif_explain_ticket <ticket.md> <format> — the ticket chain.
#
# Criteria grouped by the surface they are observed on; then what was decided
# with the analyst — a decision the human did not make is drawn as such, because
# "decided by default" is the one thing a reviewer must not be unaware of; then
# what this cycle will not establish, and which criteria that leaves unproven.
_aif_explain_ticket() {
  local ticket="$1" format="$2" meta
  meta="$(aif_meta_json "$ticket")"

  if [ "$(printf '%s' "$meta" | jq -r '.schema // 0')" != "2" ]; then
    printf 'ticket.md is schema %s — it carries no criteria of its own (they lived in spec.md), so there is no chain to draw.\n' \
      "$(printf '%s' "$meta" | jq -r '.schema // "?"')"
    printf 'Rework it with /aif-ba to get one.\n'
    return 0
  fi

  printf '%s' "$meta" | jq -r --arg format "$format" "$_AIF_EXPLAIN_JQ_PRELUDE"'
    . as $m
    | ($m.surfaces // []) as $surfaces
    | if $format == "tree" then
        ( "ticket"
        , ( $surfaces[]?
            | . as $s
            | "  " + $s
            , ( $m.acceptance[]? | select(.surface == $s)
                | "    " + .id + " — given " + (.given // "") + ", when " + (.when // "")
                  + ", then " + (.then // "") + " → " + (.expect | tostring) ) )
        , ( if (($m.decided // []) | length) > 0 then "  decided with the analyst" else empty end )
        , ( $m.decided[]?
            | "    " + (if .by == "default" then "BY DEFAULT  " else "human       " end)
              + .question + " → " + .answer
              + (if (.kind // "") == "architecture" then "  (architecture)" else "" end) )
        , ( if (($m.verification_gaps // []) | length) > 0 then "  not established by this cycle" else empty end )
        , ( $m.verification_gaps[]?
            | "    " + .id + " — " + .text
            , "      leaves unproven " + (if ((.leaves // []) | length) > 0
                                          then ((.leaves // []) | join(", "))
                                          else "no criterion in particular" end) ) )
      else
        ( "```mermaid"
        , "flowchart LR"
        , ( $surfaces[]? | "  " + (. | nid) + "([\"" + (. | lbl(40)) + "\"])" )
        , ( $m.acceptance[]?
            | "  " + (.id | nid) + "[\"" + (.id | lbl(12)) + " — "
              + ((.then // "") | lbl(60)) + " → " + ((.expect | tostring) | lbl(20)) + "\"]" )
        , ( $m.acceptance[]?
            | "  " + ((.surface // "") | nid) + " --> " + (.id | nid) )
        , ( ($m.decided // []) | to_entries[]
            | "  D" + (.key | tostring) + "{{\"" + (.value.question | lbl(50)) + " → "
              + (.value.answer | lbl(40))
              + (if .value.by == "default" then " (BY DEFAULT)" else "" end) + "\"}}" )
        , ( $m.verification_gaps[]?
            | "  " + (.id | nid) + "[/\"" + (.id | lbl(12)) + " — " + (.text | lbl(70)) + "\"/]" )
        , ( $m.verification_gaps[]?
            | . as $vg | ($vg.leaves // [])[]?
            | "  " + ($vg.id | nid) + " -.->|\"leaves unproven\"| " + (. | nid) )
        , "```"
        , ""
        , "### Decided with the analyst"
        , ""
        , ( ($m.decided // []) | if length == 0 then "- nothing was left open" else
            .[] | "- " + (if .by == "default" then "**by default, not by the human:** " else "" end)
              + .question + " → " + .answer
              + (if (.kind // "") == "architecture" then " _(architecture)_" else "" end) end )
        , ""
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
                                    else "nothing the ticket asked for" end) )
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
                              else "**nothing the ticket asked for**" end)
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
  local ticket="" format="mermaid" want_ticket=0 want_plan=0 moment=""

  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help)
        _aif_explain_usage
        return 0
        ;;
      --ticket) want_ticket=1 ;;
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
  if [ "$want_ticket" -eq 0 ] && [ "$want_plan" -eq 0 ]; then
    want_ticket=1
    want_plan=1
  fi

  local tm="$work/ticket.md" plan="$work/plan.md"
  [ "$want_ticket" -eq 1 ] && [ ! -f "$tm" ] && want_ticket=0
  [ "$want_plan" -eq 1 ] && [ ! -f "$plan" ] && want_plan=0

  if [ "$want_ticket" -eq 0 ] && [ "$want_plan" -eq 0 ]; then
    aif_die "nothing to draw for $ticket — no ticket.md, no plan.md"
  fi

  if [ "$format" = "tree" ]; then
    [ "$want_ticket" -eq 1 ] && _aif_explain_ticket "$tm" tree
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

    if [ "$want_ticket" -eq 1 ]; then
      printf -- '## Ticket\n\n'
      _aif_explain_ticket "$tm" mermaid
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
    [ "$want_ticket" -eq 1 ] && printf -- '- `ticket.md` sha256 `%s`\n' "$(aif_sha256 "$tm")"
    [ "$want_plan" -eq 1 ] && printf -- '- `plan.md` sha256 `%s`\n' "$(aif_sha256 "$plan")"
    printf '\nIf those no longer match the files, this drawing is stale — run `aif explain %s` again.\n' "$ticket"
  } >"$out.tmp" && mv "$out.tmp" "$out"

  printf '%s\n' "${out#"$root"/}"
}
