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
# above the new — the LAST one is the request's.

# _aif_request_scan <file> — the three facts of one request, in one read, as
# one line `<status>|<slices>|<shape>` (none of the three can hold a `|`: the
# status is one of five words, not the line as written). rc 1 when the file
# cannot be read, nothing printed.
#
# One awk program for the three public readers below, so that they cannot
# disagree on where a section starts or ends.
_aif_request_scan() {
  [ -r "$1" ] || return 1
  awk '
    { sub(/\r$/, "") }
    /^## / {
      sec = ""
      if ($0 ~ /^## Status[[:space:]]*$/) { sec = "status"; has_status = 1; status = ""; status_seen = 0 }
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
#     tickets: [ { ticket, slice } ], derived, next_slice, effective }
#
# `status_line` is aif_request_status; `tickets` every tasks/<ID>/ticket.md
# whose meta names the request; `derived` the status those tickets add up to
# (null when none names it): every slice 1..slices with a ticket is `cut`,
# some is `cut in part`, none is `not cut` — and a request with no slice to
# number (`slices` 0) that a ticket names is `cut`, nothing being known to be
# left; `next_slice` the smallest slice with no ticket (null when there is
# none, or nothing to number); `effective` what a reader acts on. `sha` is
# the file's sha256: a key that changes when the request does, so a shift
# offers one version of it once.
#
# Why the tickets win over the request's own line: `## Status` is a cache the
# analyst rewrites by hand when it cuts, and nothing checks it — on a real
# project it said `not cut` for a request whose first slice had already
# landed (docs/AUTOPILOT-RESEARCH.md §2.3). A ticket that names its request
# and slice in its meta is the cut itself. So `effective` is the derived
# status whenever one ticket names the request, the line only when none does
# (tickets written before the analyst recorded `request` name nothing), and
# `not cut` when the line says neither of the three.
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
  local main dir f slug scan st n shape sha reqs="" tix="" meta line id
  main="$(aif_main_root "$1")"
  dir="$main/$AIF_REQUESTS_DIR"

  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    scan="$(_aif_request_scan "$f")" || continue
    st="${scan%%|*}"
    shape="${scan##*|}"
    n="${scan#*|}"
    n="${n%%|*}"
    slug="$(basename "$f" .md)"
    sha="$(aif_sha256 "$f")" || sha=""
    line="$(jq -cn --arg file "$AIF_REQUESTS_DIR/$slug.md" --arg slug "$slug" --arg sha "$sha" \
      --arg st "$st" --arg shape "$shape" --argjson n "$n" \
      '{ k: "r", file: $file, slug: $slug, sha: $sha, status_line: $st, shape: $shape, slices: $n }')" || continue
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

  printf '%s%s' "$reqs" "$tix" | jq -sc '
    def slugof: tostring | split("/") | last | sub("\\.md$"; "");
    def idkey: capture("^(?<p>.*?)(?<n>[0-9]+)$") // { p: ., n: "0" } | [.p, (.n | tonumber)];
    def asslice: (tonumber? // 1) | floor;
    [ .[] | select(.k == "t") | { ticket, slug: (.request | slugof), slice: (.slice | asslice) } ] as $t
    | [ .[] | select(.k == "r") | del(.k)
        | .slug as $s
        | .tickets = ([ $t[] | select(.slug == $s) | { ticket, slice } ]
                      | sort_by([.slice, (.ticket | idkey)]))
        | ([ .tickets[].slice ] | unique) as $cov
        | [ range(1; .slices + 1) | select(. as $n | any($cov[]; . == $n) | not) ] as $open
        | .derived = (if (.tickets | length) == 0 then null
                      elif ($open | length) == 0 then "cut"
                      elif ($open | length) == .slices then "not cut"
                      else "cut in part" end)
        | .next_slice = (if ($open | length) == 0 then null else $open[0] end)
        | .effective = (.derived // (if .status_line == "not cut" or .status_line == "cut in part"
                                        or .status_line == "cut"
                                     then .status_line else "not cut" end)) ]
    | sort_by(.file)'
}
