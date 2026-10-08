#!/usr/bin/env bash
#
# The product partner's requests, read by bash. Sourced by bin/aif; not meant
# to be executed directly.
#
# A request (requests/<slug>.md, AIF_REQUESTS_DIR) is prose a person and the
# product partner wrote — the outcome, the slices it is cut into, what it is
# not — and no gate reads it. A shift (`aif start`) still has to know two
# things of each without opening a session: is there something left for the
# analyst to cut, and is it the old one-section shape the owner cuts into
# slices first (docs/AUTOPILOT-RESEARCH.md §4.6, R19 and R20). That is all
# this file answers, from the headings alone: never the prose.
#
# The shapes it reads are the skills' (sets/claude/skills/aif-po/SKILL.md, the
# request's template; sets/claude/skills/aif-ba/SKILL.md, the `## Status` it
# keeps), and the requests a real project holds: a `## Status` with a blank
# line before its value, a slice spanning paragraphs and an indented fenced
# block, two older requests with a `## Scope` and no `## Status` at all.
#
# One rule for every reader below: a line's `\r` is taken off first (a file
# edited in a browser comes back with CRLF, docs/DEFECTS.md 3.10), and a
# section runs from its `## ` heading to the next `## ` heading or the end of
# the file. When a heading appears twice — a careless rewrite left the old one
# above the new — the LAST one is the request's. And a fenced block that
# starts at column 0 is the request's prose, not its structure: a `## ` line
# or a `1. ` line inside one — a request that quotes a template, a log, a
# list it was sent — is neither a heading nor a slice (docs/DEFECTS.md 15.5).

# _aif_request_scan <file> [list] — the three facts of one request, in one
# read, as one line `<status>|<slices>|<shape>` (none of the three can hold a
# `|`: the status is one of five words, not the line as written). rc 1 when
# the file cannot be read, nothing printed.
#
# With `list`, the slice list the analyst keeps under its `## Status` follows,
# a line per entry, `<N><TAB><what the entry says after its arrow>` — the
# `- slice N → OPES-61, OPES-62` and `- slice N → not cut` lines of the last
# `## Status` (sets/claude/skills/aif-ba/SKILL.md, step 5): what aif_requests_json
# reads as the request's second source on its cut (docs/DEFECTS.md 15.5).
#
# One awk program for every reader below, so that they cannot disagree on
# where a section starts or ends, or on what a fence hides.
_aif_request_scan() {
  [ -r "$1" ] || return 1
  awk -v want_list="${2:-}" '
    { sub(/\r$/, "") }
    # Inside a fence opened at column 0: only the fence that closes it — the
    # same character, at least as many, nothing after it — means anything
    # (CommonMark). An indented fence needs none of this: its lines are
    # indented too, and neither rule below reads an indented line.
    fence != "" {
      if (substr($0, 1, 1) == fence && match($0, /^(`+|~+)[[:space:]]*$/)) {
        closer = $0
        sub(/[[:space:]]+$/, "", closer)
        if (length(closer) >= flen) fence = ""
      }
      next
    }
    /^(```|~~~)/ {
      fence = substr($0, 1, 1)
      match($0, /^(`+|~+)/)
      flen = RLENGTH
      next
    }
    /^## / {
      sec = ""
      if ($0 ~ /^## Status[[:space:]]*$/) { sec = "status"; has_status = 1; status = ""; status_seen = 0; list = "" }
      else if ($0 ~ /^## Slices[[:space:]]*$/) { sec = "slices"; has_slices = 1; n = 0 }
      else if ($0 ~ /^## Scope[[:space:]]*$/) { has_scope = 1 }
      next
    }
    # The first line with anything on it: the analyst writes the value right
    # under the heading, and a real request has a blank line between them.
    sec == "status" && !status_seen && /[^[:space:]]/ {
      status = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", status)
      status_seen = 1
    }
    # The analyst lists every slice under the status, one a line, with the
    # tickets it became or `not cut`; the arrow as written or as typed.
    sec == "status" && /^[-*][[:space:]]+[Ss]lice[[:space:]]+[0-9]+[[:space:]]*(→|->)/ {
      entry = $0
      sub(/^[-*][[:space:]]+[Ss]lice[[:space:]]+/, "", entry)
      match(entry, /^[0-9]+/)
      num = substr(entry, 1, RLENGTH)
      entry = substr(entry, RLENGTH + 1)
      sub(/^[[:space:]]*(→|->)[[:space:]]*/, "", entry)
      gsub(/\t/, " ", entry)
      list = list num "\t" entry "\n"
    }
    # A slice is a numbered item at column 0. Its continuation paragraphs and
    # the fenced block a slice may carry are indented under it, and a line
    # in them that starts with a number is not a new slice.
    sec == "slices" && /^[0-9]+[.)][[:space:]]/ { n++ }
    END {
      if (!has_status) st = "none"
      else if (status == "cut in part") st = "cut in part"
      else if (status == "not cut") st = "not cut"
      else if (status == "cut") st = "cut"
      else st = "unknown"
      if (has_slices) { shape = "slices"; count = n }
      else if (has_scope) { shape = "scope"; count = 1 }
      else { shape = "none"; count = 0 }
      printf "%s|%d|%s\n", st, count, shape
      if (want_list == "list") printf "%s", list
    }
  ' "$1"
}

# aif_request_status <file> — what the request says of itself: `not cut`,
# `cut in part` or `cut` (the three values the analyst writes, matched
# exactly, the line trimmed); `unknown` for any other first line; `none` when
# it has no `## Status` (a request older than the line, or the owner never
# finished it). rc 1 when the file cannot be read.
#
# This is a cache, and a stale one is normal: see aif_requests_json for what
# wins over it.
aif_request_status() {
  local scan
  scan="$(_aif_request_scan "$1")" || return 1
  printf '%s\n' "${scan%%|*}"
}

# aif_request_slices <file> — how many slices the request is cut into: the
# numbered items of its `## Slices`; 1 for an older request with a `## Scope`
# and no `## Slices` (the analyst cuts it as one, sets/claude/skills/aif-ba);
# 0 for neither — nothing to cut until the owner has written one. A
# `## Slices` with no numbered item in it is 0 too, not a guess. rc 1 when the
# file cannot be read.
aif_request_slices() {
  local scan rest
  scan="$(_aif_request_scan "$1")" || return 1
  rest="${scan#*|}"
  printf '%s\n' "${rest%%|*}"
}

# aif_request_shape <file> — `slices` (the template's), `scope` (the older
# one-section request the owner cuts into slices before the analyst does) or
# `none`. rc 1 when the file cannot be read.
aif_request_shape() {
  local scan
  scan="$(_aif_request_scan "$1")" || return 1
  printf '%s\n' "${scan##*|}"
}

# aif_requests_json <root> — every request of the project, as one JSON array
# (compact), sorted by file name:
#
#   { file: "requests/<slug>.md", slug, sha, status_line, shape, slices,
#     tickets: [ { ticket, slice } ], listed: [ { slice, tickets: [ID] } ],
#     derived, next_slice, effective }
#
# `status_line` is aif_request_status; `tickets` every tasks/<ID>/ticket.md
# whose meta names the request; `listed` the slices the analyst's list under
# `## Status` maps to tickets (below); `derived` the status those two add up
# to (null when neither says anything): every slice 1..slices with a ticket is
# `cut`, some is `cut in part`, none is `not cut` — and a request with no
# slice to number (`slices` 0) that a ticket names is `cut`, nothing being
# known to be left; `next_slice` the smallest slice with no ticket (null when
# there is none, or nothing to number — and, with nothing derived, null for a
# request whose line says it is cut, in part or whole: which slice is next is
# not known, and slice 1 was the wrong guess); `effective` what a reader acts
# on. `sha` is the file's sha256: a key that changes when the request does, so
# a shift offers one version of it once.
#
# Why the tickets win over the request's own line: `## Status` is a cache the
# analyst rewrites by hand when it cuts, and nothing checks it — on a real
# project it said `not cut` for a request whose first slice had already
# landed (docs/AUTOPILOT-RESEARCH.md §2.3). A ticket that names its request
# and slice in its meta is the cut itself. So `effective` is the derived
# status whenever something derives it, the line only when nothing does, and
# `not cut` when the line says neither of the three.
#
# The list is the second source, under the tickets. Tickets cut before the
# analyst recorded `request` in their meta name nothing, and a project that
# had cut its requests that way read every one as `not cut` — on a copy of a
# real one, four requests and 24 tickets, all four would have been offered to
# be cut again (docs/DEFECTS.md 15.5). The analyst's list under the status —
# `- slice 2 → OPES-62, OPES-63` — says which ticket each slice became. A
# slice counts as cut by the list when an id it names (a word that matches the
# project's ticket pattern; `not cut` names none) is a ticket that names no
# request in its meta: a ticket that names one is placed by its own meta,
# which wins, slice by slice.
#
# A ticket names a request by its file however it was spelled: the basename
# without `.md` is compared, so `requests/x.md`, `./requests/x.md`, `x.md` and
# `x` are one request. `slice` defaults to 1 — a single-slice request's ticket
# has a `request` and no `slice`. A ticket whose meta does not parse is
# skipped, as `aif rules` does: one broken file does not hide every request.
#
# Read from the main checkout (aif_main_root): requests and tickets are
# committed, and a worktree holds only its own branch's copy. No requests
# directory, or nothing in it: `[]`.
aif_requests_json() {
  local main dir f slug scan facts list st n shape sha reqs="" tix="" meta line id re
  main="$(aif_main_root "$1")"
  dir="$main/$AIF_REQUESTS_DIR"
  # The ids a list names are read by the project's own ticket pattern, the one
  # its cards are matched by (lib/board.sh aif_board_ticket_re).
  re="$(jq -r '.ticket_pattern // empty' "$main/.aif/project.json" 2>/dev/null)" || re=""
  [ -n "$re" ] || re='^[A-Z]{2,10}-[0-9]+$'

  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    scan="$(_aif_request_scan "$f" list)" || continue
    facts="$(printf '%s\n' "$scan" | sed -n 1p)"
    list="$(printf '%s\n' "$scan" | sed 1d)"
    st="${facts%%|*}"
    shape="${facts##*|}"
    n="${facts#*|}"
    n="${n%%|*}"
    slug="$(basename "$f" .md)"
    sha="$(aif_sha256 "$f")" || sha=""
    # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
    line="$(jq -cn --arg file "$AIF_REQUESTS_DIR/$slug.md" --arg slug "$slug" --arg sha "$sha" \
      --arg st "$st" --arg shape "$shape" --argjson n "$n" --arg list "$list" '
      { k: "r", file: $file, slug: $slug, sha: $sha, status_line: $st, shape: $shape, slices: $n,
        status_list: [ $list | split("\n")[] | select(length > 0) | split("\t")
                       | { slice: (.[0] | tonumber), text: (.[1:] | join(" ")) } ] }')" || continue
    reqs="$reqs$line
"
  done

  if [ -n "$reqs" ]; then
    for f in "$main/$AIF_TASKS_DIR"/*/ticket.md; do
      [ -f "$f" ] || continue
      meta="$(aif_meta_json "$f")" || continue
      # Most tickets name no request (every ticket cut before the analyst
      # recorded one): those are passed over without a jq of their own.
      case "$meta" in
        *'"request"'*) ;;
        *) continue ;;
      esac
      id="$(basename "$(dirname "$f")")"
      line="$(jq -cn --arg id "$id" --argjson meta "$meta" '
        if ($meta | type) == "object" and (($meta.request // null) | type) == "string"
        then { k: "t", ticket: $id, request: $meta.request, slice: ($meta.slice // 1) }
        else empty end' 2>/dev/null)" || continue
      [ -n "$line" ] || continue
      tix="$tix$line
"
    done
  fi

  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flag
  printf '%s%s' "$reqs" "$tix" | jq -sc --arg re "$re" '
    def slugof: tostring | split("/") | last | sub("\\.md$"; "");
    def idkey: capture("^(?<p>.*?)(?<n>[0-9]+)$") // { p: ., n: "0" } | [.p, (.n | tonumber)];
    def asslice: (tonumber? // 1) | floor;
    # The ticket ids one list entry names: `not cut` none; otherwise its words,
    # punctuation off their ends, that match the ticket pattern — so that
    # `OPES-62 (landed)` and `OPES-62, OPES-63` read as what they say.
    def ids: if (ascii_downcase | sub("^\\s+"; "") | sub("\\s+$"; "")) == "not cut" then []
             else [ splits("[\\s,;]+") | sub("^[^A-Za-z0-9]+"; "") | sub("[^A-Za-z0-9]+$"; "")
                    | select(length > 0) | select(test($re)) ] end;
    [ .[] | select(.k == "t") | { ticket, slug: (.request | slugof), slice: (.slice | asslice) } ] as $t
    | [ $t[].ticket ] as $named
    | [ .[] | select(.k == "r") | del(.k)
        | .slug as $s
        | .tickets = ([ $t[] | select(.slug == $s) | { ticket, slice } ]
                      | sort_by([.slice, (.ticket | idkey)]))
        | ((.status_list // []) | length > 0) as $haslist
        | .listed = ([ (.status_list // [])[]
                       | { slice, tickets: [ .text | ids | .[] | select(. as $i | any($named[]; . == $i) | not) ] }
                       | select((.tickets | length) > 0) ] | sort_by(.slice))
        | del(.status_list)
        | ([ .tickets[].slice ] + [ .listed[].slice ] | unique) as $cov
        | [ range(1; .slices + 1) | select(. as $n | any($cov[]; . == $n) | not) ] as $open
        | .derived = (if (.tickets | length) == 0 and ($haslist | not) then null
                      elif ($open | length) == 0 then "cut"
                      elif ($open | length) == .slices then "not cut"
                      else "cut in part" end)
        | .effective = (.derived // (if .status_line == "not cut" or .status_line == "cut in part"
                                        or .status_line == "cut"
                                     then .status_line else "not cut" end))
        | .next_slice = (if .derived != null then (if ($open | length) == 0 then null else $open[0] end)
                         elif .effective == "not cut" and .slices >= 1 then 1
                         else null end) ]
    | sort_by(.file)'
}
