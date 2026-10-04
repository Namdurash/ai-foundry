#!/usr/bin/env bash
#
# `aif rules [<word>…]` — the map the analyst writes against: every ticket's
# rules, and where the ticket stands on the board. Sourced by bin/aif; not
# meant to be executed directly.
#
# The analyst used to learn what the product does from `main` alone, and a
# ticket written but not built, or built and waiting in Review, was invisible
# to it: the next ticket could restate a rule that one owned, or quietly change
# it (docs/DEFECTS.md 12.2). The code says what exists; it does not say what
# was meant, nor what is coming. The tickets say both — the rules of a Done
# ticket are what the product does by intent, every other column is in flight.
#
# Computed, never kept. A document describing the product would drift from the
# tickets the moment one changed; this reads tasks/*/ticket.md and the board
# every time it runs. A rule a later ticket changed (rules[].changes) is left
# out — the later rule is the one in force — unless --all asks for the history.
# A ticket written before rules existed shows its criteria instead.

_aif_rules_usage() {
  cat <<EOF
usage: aif rules [<word>…] [--all] [--json]

  Every ticket's rules, with the ticket's column on the board: Done is what the
  product does by intent, every other column is what is coming. Read it before
  writing a ticket, so a rule another ticket owns is not written again and a
  rule changed is named (rules[].changes in the new ticket).

  <word>…  only the tickets whose title, surfaces, rules or criteria contain
           one of the words; case does not matter
  --all    the rules a later ticket changed too, each with the rule that did
  --json   the same, as JSON
EOF
}

aif_cmd_rules() {
  local all=false json=0 words="[]" root dir f id title meta board tickets view
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) all=true ;;
      --json) json=1 ;;
      -h | --help)
        _aif_rules_usage
        return 0
        ;;
      -*) aif_die "aif rules: unknown option $1 (aif rules --help)" ;;
      *) words="$(printf '%s' "$words" | jq -c --arg w "$1" '. + [$w]')" ;;
    esac
    shift
  done

  root="$(aif_require_project)"
  dir="$root/$AIF_TASKS_DIR"

  # One JSON line per ticket: its id, its title line, its meta. A file whose
  # meta does not parse is skipped here and named below, rather than taking
  # the whole map down with it. Held in a variable: this command only reads,
  # and leaves nothing behind when it is interrupted.
  tickets=""
  local unreadable="" line
  for f in "$dir"/*/ticket.md; do
    [ -f "$f" ] || continue
    id="$(basename "$(dirname "$f")")"
    title="$(awk -v id="$id" '
      /^-->$/ { body = 1; next }
      body && /^# / { sub(/^# /, ""); sub("^" id " [—-]+ ", ""); print; exit }
    ' "$f")"
    meta="$(aif_meta_json "$f")"
    if ! line="$(jq -cn --arg id "$id" --arg title "$title" --argjson meta "$meta" \
      'if ($meta | type) == "object" then { id: $id, title: $title, meta: $meta } else error("not an object") end' 2>/dev/null)"; then
      unreadable="$unreadable $id"
      continue
    fi
    tickets="$tickets$line
"
  done

  # Where each ticket stands. The board is the one place that knows, and an
  # unreachable board is said so, not guessed: the columns read "?".
  board="$(aif_board_status_json "$root" 2>/dev/null)" || board=""
  if ! printf '%s' "$board" | jq -e 'type == "array"' >/dev/null 2>&1; then
    board="[]"
    aif_warn "the board did not answer — every column below reads \"?\""
  fi

  view="$(printf '%s' "$tickets" | jq -s --argjson board "$board" --argjson words "$words" --argjson all "$all" '
    def esc: gsub("(?<c>[.^$|?*+()\\[\\]{}\\\\])"; "\\\(.c)");
    def idkey: capture("^(?<p>.*?)(?<n>[0-9]+)$") // { p: ., n: "0" } | [.p, (.n | tonumber)];
    . as $tickets
    | ($board | map({ key: .ticket, value: .column }) | from_entries) as $col
    # what each rule or criterion was changed by: "<ID> R-n" → "<ID> R-k"
    | ([ $tickets[] | .id as $t | (.meta.rules // [])[]? | objects | .id as $r
         | (.changes // [])[]? | strings | { key: ., value: ($t + " " + $r) } ]
       | from_entries) as $changed_by
    | [ $tickets[]
        | .id as $t | .meta as $m
        | select(($m.schema // 0) == 2)
        | ($m.acceptance // []) as $acs
        | (($m.rules | type) == "array" and (($m.rules // []) | length) > 0) as $has_rules
        | { ticket: $t, title: .title, column: ($col[$t] // "?"),
            surfaces: ($m.surfaces // []),
            kind: (if $has_rules then "rules" else "criteria" end),
            entries: (if $has_rules then
                [ $m.rules[] | objects | . as $r
                  | { id: ($r.id // "?"), text: ($r.text // ""),
                      criteria: [ $acs[]? | select(.rule == $r.id) | .id ],
                      changes: ($r.changes // []),
                      changed_by: ($changed_by[$t + " " + ($r.id // "?")] // null) } ]
              else
                [ $acs[]? | objects
                  | { id: (.id // "?"),
                      text: ("given " + (.given // "") + ", when " + (.when // "")
                             + ", then " + (.then // "") + " → " + (.expect | tostring)),
                      given: (.given // ""), when: (.when // ""),
                      criteria: [], changes: [],
                      changed_by: ($changed_by[$t + " " + (.id // "?")] // null) } ]
              end) }
        | .entries |= (if $all then . else map(select(.changed_by == null)) end)
        | select((.entries | length) > 0)
        | select(($words | length) == 0
            or ( ([ .title, .surfaces[], (.entries[] | .text, (.given // ""), (.when // "")) ]
                  | join("\n")) as $hay
                 | any($words[]; esc as $w | $hay | test($w; "i")) ))
      ]
    | sort_by(.ticket | idkey)
  ')" || aif_die "could not read the tickets under $AIF_TASKS_DIR/"

  if [ "$json" -eq 1 ]; then
    printf '%s\n' "$view"
    return 0
  fi

  local n
  n="$(printf '%s' "$view" | jq 'length')"
  if [ "$n" -eq 0 ]; then
    if [ "$words" = "[]" ]; then
      printf 'no ticket under %s/ carries rules or criteria yet\n' "$AIF_TASKS_DIR"
    else
      printf 'no ticket mentions: %s\n' "$(printf '%s' "$words" | jq -r 'join(", ")')"
    fi
  else
    printf '%s' "$view" | jq -r '
      .[]
      | (.ticket + " · " + .column + " · " + .title),
        ( .entries[]
          | "  " + .id + " — " + .text
            + (if (.criteria | length) > 0 then "  (" + (.criteria | join(", ")) + ")" else "" end)
            + (if (.changes | length) > 0 then "  — changes " + (.changes | join(", ")) else "" end)
            + (if .changed_by then "  ✗ changed by " + .changed_by else "" end) ),
        ""'
    printf '%sDone is what the product does by intent; every other column is in flight.\nA ticket written before rules shows its criteria instead.%s\n' "$AIF_C_DIM" "$AIF_C_RESET"
  fi
  [ -z "$unreadable" ] || aif_warn "skipped, their aif:meta does not parse:$unreadable"
}
