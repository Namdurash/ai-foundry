#!/usr/bin/env bash
#
# `aif start` — the shift: the human's half of the board, one session at a
# time, with the board moved by fixed rules. Sourced by bin/aif; not meant to
# be executed directly.
#
# The loop builds (`aif work --loop`, in this terminal or another); what is
# left is everything a person did by hand between builds — read a report and
# say yes, send a card back, cut the next slice, put a blocked card back in
# Ready — and a shift is that, with the person present only at the control
# point: one session (a review, the analyst, the owner) or one move at a time,
# each on a key, the rest by rules a `case` can read off a card's first line
# (docs/AUTOPILOT-RESEARCH.md §6, docs/AUTOPILOT-PHASE1.md).
#
# Every tick runs the same three steps, and only the last one acts:
#
#   facts    what bash reads, once a tick, off the board (one status read,
#            the head of each card that changed), off this machine (each
#            card's run: its lock, worktree, branch and record — what `aif
#            work --status` says), off the repository (what landed, what is
#            uncommitted, the tickets with no card, the requests) and off the
#            shift itself (what it offered, retried, held). One JSON document;
#            nothing decided in it.
#   oracle   lib/start.jq: a pure function from those facts to a plan — the
#            moves bash makes without a key, the units it offers at the
#            control point, the lines it will not touch, a wait, or the end.
#            Pure, so every row of the policy runs over a fixture with `jq -f`
#            alone: no board, no model, no terminal.
#   driver   makes the moves, offers the first unit, runs what the person
#            chose, and ticks again.
#
# The facts and the oracle are the first half of this file; the driver follows
# them.

# _aif_start_why <captured output> — the first line of what a failing board
# call said, bare: the `error:` prefix and the colour codes off, so it can
# follow a dash (as lib/release.sh does for the sweep).
_aif_start_why() {
  local esc
  esc="$(printf '\033')"
  printf '%s\n' "$1" | sed -n 1p | sed "s/$esc\[[0-9;]*m//g; s/^error: //"
}

# _aif_start_parallel <root> — how many the build takes at once when this shift
# builds: the driver's resolved --parallel (AIF_START_PARALLEL), else PARALLEL
# in .aif/start.local, else 2. Anything that is not a whole number above 0 is
# 2. A loop in another terminal says its own (its lock's owner.json), and the
# facts take that one instead.
_aif_start_parallel() {
  local p="${AIF_START_PARALLEL:-}"
  # shellcheck disable=SC2153  # AIF_START_STATE is lib/paths.sh's, not a misspelt AIF_START_STTY
  [ -n "$p" ] || p="$(aif_meta_get "$(aif_main_root "$1")/$AIF_START_STATE" PARALLEL 2)"
  case "$p" in
    '' | *[!0-9]* | 0*) p=2 ;;
  esac
  printf '%s' "$p"
}

# _aif_start_board <root> — the board's status for one tick, a JSON array on
# stdout; rc 3 with the reason on stderr when it did not answer twice.
#
# One read a tick, and every verdict of the tick rests on it, so a board that
# did not answer is never an empty board (research R1; docs/DEFECTS.md 14.7 is
# that mistake made in the comments read). Once more after
# AIF_START_BOARD_RETRY_SECS (5 — a 429 or a dropped connection is usually
# over by then, and the adapter has already retried its own GETs); twice is
# the board, and the shift ends on it with exit 3. Inside `$(…)`: on Trello a
# failure is aif_die, which would otherwise end the shift with it.
_aif_start_board() {
  local root="$1" out="" rc n=1
  while :; do
    rc=0
    out="$(aif_board_status_json "$root" 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then
      printf '%s\n' "$out"
      return 0
    fi
    [ "$n" -lt 2 ] || break
    n=$((n + 1))
    sleep "${AIF_START_BOARD_RETRY_SECS:-5}" 2>/dev/null || true
  done
  out="$(_aif_start_why "$out")"
  aif_err "the board did not answer twice${out:+ — $out}"
  return 3
}

# _aif_start_facts <root> — the facts of one tick, one compact JSON object on
# stdout:
#
#   { now (epoch), shift_started_at (ISO UTC), host, board_kind, ticket_re,
#     build: { mode: "here"|"elsewhere"|"none", parallel, hold: null|"<why>",
#              loop: { live, pid, host, idle, parallel, logdir }|null },
#     flags: { po, pjm, retry_runs }, hold_labels: [..], dirty: [ "<path>" ],
#     cards: [ { ticket, title, column, pos, labels, moved_at, unread, unread_why,
#                head: { line, at, body, after, heads: [ { line, at } ] }|null,
#                local: <_aif_work_status_json>|null,
#                ticket_file, meta: { depends_on, request, slice }|null,
#                deps: [ { ticket, column, landed } ], ready_gate, land_commit } ],
#     loose_tasks: [ { ticket, stub, tracked, landed, request, slice } ],
#     requests: <aif_requests_json>,
#     memory: { done: [ { key, note } ], retried_env: [..], retried_run: [..] } }
#
# rc 0 · 3 the board did not answer twice (said on stderr; the shift ends
# with 3) · 1 the document could not be put together here (said on stderr).
#
# What the driver hands it, in the environment — its state between ticks, so
# that this stays a reader with no state of its own:
#
#   AIF_START_SHIFT_DIR      the shift's directory; the heads are cached under
#                            its cards/. Empty (--dry-run): nothing cached,
#                            every head read
#   AIF_START_STARTED_AT     when the shift started, ISO UTC (default: now)
#   AIF_START_DONE           the keys acted on, skipped or offered: one per
#                            line, `<key>\t<note>`
#   AIF_START_RETRIED_ENV    the cards R16 retried this shift, and
#   AIF_START_RETRIED_RUN    the cards R17 retried — ids, space-separated
#   AIF_START_BUILD_HOLD     why the build is held (R13), or empty
#   AIF_START_FLAG_NO_BUILD  1 under --no-build
#   AIF_START_FLAG_PO        1 under --po
#   AIF_START_FLAG_PJM       0 under --no-pjm (default 1)
#   AIF_START_FLAG_RETRY_RUNS 1 under --retry-runs
#   AIF_START_PARALLEL       the resolved --parallel (_aif_start_parallel)
#
# Three knobs of the reading itself: AIF_START_BOARD_RETRY_SECS (above),
# AIF_RELEASE_HOLD_LABELS (the sweep's, one name for both — lib/release.sh),
# and AIF_START_HEADS_PER_TICK (_aif_start_cards).
_aif_start_facts() {
  local root="$1" tmp rc=0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/aif-facts-XXXXXX")" || {
    aif_err "could not make a temporary directory for the shift's facts"
    return 1
  }
  _aif_start_facts_in "$root" "$tmp" || rc=$?
  rm -rf "${tmp:?}"
  return "$rc"
}

# _aif_start_facts_in <root> <tmp> — _aif_start_facts, its scratch in <tmp>.
# The pieces are written to files there and put together by one jq at the
# end: a board's worth of heads and run records is more than an argument list
# should carry.
_aif_start_facts_in() {
  local root="$1" tmp="$2" main kind re status
  main="$(aif_main_root "$root")"
  kind="$(aif_board_kind "$root")"
  re="$(aif_board_ticket_re "$root")"
  [ -n "$re" ] || re='^[A-Z]{2,10}-[0-9]+$'

  status="$(_aif_start_board "$root")" || return 3
  printf '%s\n' "$status" >"$tmp/status.json" || return 1

  # The cards the shift considers: a ticket of this project's, in a column it
  # knows. On Trello a card made by hand (its name is no ticket id) and a card
  # in a list the project does not map (`other`) are not the shift's.
  if ! jq -c --arg re "$re" '[ .[] | select((.ticket // "") | test($re)) | select(.column != "other") ]' \
    "$tmp/status.json" >"$tmp/cards.json" 2>/dev/null; then
    aif_err "the board's cards could not be read against the ticket pattern $re"
    return 1
  fi

  _aif_start_cards "$root" "$tmp" "$kind" || return 1
  _aif_start_build "$root" >"$tmp/build.json" || return 1
  _aif_start_ready_gates "$root" "$tmp" || return 1
  _aif_start_loose "$root" "$tmp" "$re" || return 1

  # Exactly what `aif land` refuses on (lib/cmd_land.sh): tracked files with
  # changes. A new request or ticket the analyst wrote is untracked, and does
  # not stop a land; a rewritten `## Status` in a committed request does
  # (docs/AUTOPILOT-RESEARCH.md R25). A rename names its new path.
  git -C "$main" status --porcelain --untracked-files=no 2>/dev/null |
    cut -c4- | sed 's/.* -> //' >"$tmp/dirty" || : >"$tmp/dirty"
  # Every line that says a ticket landed: `aif: land <ID> — <title>`, the
  # subject `aif land` writes (lib/cmd_land.sh), read once for every card and
  # dependency of the tick — matched below as lib/release.sh matches it, the
  # id with its trailing ` — ` so that AIF-1 does not stand in for AIF-10.
  git -C "$main" log --fixed-strings --grep 'aif: land ' --format=%B 2>/dev/null |
    grep -F 'aif: land ' >"$tmp/lands" || : >"$tmp/lands"
  # In a subshell, as the oracle's call is: a trap fired inside a function
  # call runs with that call's 2>/dev/null (_aif_start_snapshot).
  (aif_requests_json "$root") >"$tmp/requests.json" 2>/dev/null || printf '[]\n' >"$tmp/requests.json"
  jq -e 'type == "array"' "$tmp/requests.json" >/dev/null 2>&1 || printf '[]\n' >"$tmp/requests.json"

  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  jq -n -c --argjson now "$(date +%s)" \
    --arg started "${AIF_START_STARTED_AT:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}" \
    --arg host "$(aif_host_short)" --arg kind "$kind" --arg re "$re" \
    --slurpfile build "$tmp/build.json" \
    --arg po "${AIF_START_FLAG_PO:-0}" --arg pjm "${AIF_START_FLAG_PJM:-1}" \
    --arg rr "${AIF_START_FLAG_RETRY_RUNS:-0}" \
    --arg holds "${AIF_RELEASE_HOLD_LABELS:-parked retired-direction}" \
    --rawfile dirty "$tmp/dirty" --rawfile lands "$tmp/lands" \
    --slurpfile all "$tmp/status.json" --slurpfile cards "$tmp/cards.json" \
    --slurpfile x "$tmp/extras" --slurpfile g "$tmp/gates" --slurpfile loose "$tmp/loose" \
    --slurpfile req "$tmp/requests.json" \
    --arg donekeys "${AIF_START_DONE:-}" \
    --arg renv "${AIF_START_RETRIED_ENV:-}" --arg rrun "${AIF_START_RETRIED_RUN:-}" '
    def words: [ splits("[[:space:]]+") | select(length > 0) ];
    ($lands | split("\n") | map(select(length > 0))) as $ll
    | def landed($id): any($ll[]; contains("aif: land " + $id + " — "));
      ($x | map({ key: .ticket, value: . }) | from_entries) as $e
    | ($g | map({ key: .ticket, value: .rc }) | from_entries) as $gate
    | $all[0] as $a
    | { now: $now, shift_started_at: $started, host: $host, board_kind: $kind, ticket_re: $re,
        build: $build[0],
        flags: { po: ($po == "1"), pjm: ($pjm != "0"), retry_runs: ($rr == "1") },
        hold_labels: ($holds | words),
        dirty: ($dirty | split("\n") | map(select(length > 0))),
        cards: [ $cards[0][] | . as $c | ($e[$c.ticket] // {}) as $y
                 | { ticket, title, column, pos, labels: (.labels // []), moved_at: (.moved_at // null),
                     unread: ($y.unread // false), unread_why: ($y.unread_why // null),
                     head: ($y.head // null), local: ($y.local // null),
                     ticket_file: ($y.ticket_file // false), meta: ($y.meta // null),
                     deps: [ ($y.meta.depends_on // [])[] as $d
                             | { ticket: $d,
                                 column: (first($a[] | select(.ticket == $d) | .column) // null),
                                 landed: landed($d) } ],
                     ready_gate: ($gate[$c.ticket] // null),
                     land_commit: landed($c.ticket) } ],
        loose_tasks: [ $loose[] | . + { landed: landed(.ticket) } ],
        requests: $req[0],
        memory: { done: [ $donekeys | split("\n")[] | select(length > 0) | split("\t")
                          | { key: .[0], note: (.[1:] | join("\t")) } ],
                  retried_env: ($renv | words), retried_run: ($rrun | words) } }' || {
    aif_err "could not put the shift's facts together (jq)"
    return 1
  }
}

# _aif_start_cards <root> <tmp> <kind> — for every card the shift considers,
# one line of <tmp>/extras: its head, what this machine knows of its run, and
# its ticket's meta. Heads are read in the order the shift acts on them —
# Review, Needs Human, In Progress, Backlog, each by position — and not at all
# for Ready (the loop's) and Done.
#
# A head costs two requests on Trello (the card's lookup lists the whole board
# with descriptions, then its comments — lib/board.sh), and a shift ticks
# beside a loop that polls the same token. So a head is read again only when
# its card changed since the last good read — locally its column, moved_at or
# comment count (a comment does not touch moved_at there); on Trello its
# column or dateLastActivity, which a comment does move — cached under the
# shift's directory (cards/<ID>.key and .head) on rc 0 or 1 only; and at most
# AIF_START_HEADS_PER_TICK of them a tick (10 on Trello; no cap on the local
# board, where a read is a file), the rest `unread` this tick and read on a
# later one. With no shift directory (--dry-run) nothing is cached and
# nothing capped.
#
# rc 1 of the head is a card with no aif line on it — kept as a head whose
# line is null, so the count of a person's comments still says whether
# anybody wrote. rc 2 is a card not read, its first line why: never an empty
# head (research R1).
_aif_start_cards() {
  local root="$1" tmp="$2" kind="$3" main shiftdir cap reads=0 tab
  local id col key cache hj hrc unread why loc meta tf f
  main="$(aif_main_root "$root")"
  shiftdir="${AIF_START_SHIFT_DIR:-}"
  cap=0
  if [ -n "$shiftdir" ]; then
    mkdir -p "$shiftdir/cards" 2>/dev/null || true
    if [ -n "${AIF_START_HEADS_PER_TICK:-}" ]; then
      cap="$AIF_START_HEADS_PER_TICK"
    elif [ "$kind" = trello ]; then
      cap=10
    fi
  fi
  case "$cap" in
    '' | *[!0-9]*) cap=10 ;;
  esac

  # shellcheck disable=SC2016  # jq's string interpolation, not the shell's
  jq -r '
    ([ "review", "needs_human", "in_progress", "backlog", "ready", "done" ][]) as $k
    | [ .[] | select(.column == $k) ] | sort_by(.pos) | .[]
    | [ .ticket, .column, "\(.column)|\(.moved_at // "")|\(.comments // "")" ] | @tsv' \
    "$tmp/cards.json" >"$tmp/order" 2>/dev/null || return 1

  : >"$tmp/extras"
  tab="$(printf '\t')"
  # Fd 3, so that nothing in the body reads the list as its stdin.
  while IFS="$tab" read -r id col key <&3; do
    [ -n "$id" ] || continue
    hj=null
    unread=false
    why=""
    case "$col" in
      review | needs_human | in_progress | backlog)
        cache=""
        case "$id" in
          *[!A-Za-z0-9._-]*) ;;
          *) [ -z "$shiftdir" ] || cache="$shiftdir/cards/$id" ;;
        esac
        if [ -n "$cache" ] && [ -f "$cache.key" ] && [ -f "$cache.head" ] &&
          [ "$(cat "$cache.key" 2>/dev/null)" = "$key" ] &&
          hj="$(jq -c 'objects' "$cache.head" 2>/dev/null)" && [ -n "$hj" ]; then
          :
        elif [ "$cap" -gt 0 ] && [ "$reads" -ge "$cap" ]; then
          hj=null
          unread=true
          why="not read this tick"
        else
          reads=$((reads + 1))
          hrc=0
          hj="$(aif_board_head_json "$root" "$id" 2>"$tmp/err" </dev/null)" || hrc=$?
          if [ "$hrc" -le 1 ] && printf '%s' "$hj" | jq -e 'type == "object"' >/dev/null 2>&1; then
            if [ -n "$cache" ]; then
              # The head first, then the key: a key never names a head that
              # was not written.
              rm -f "$cache.key" 2>/dev/null || true
              { printf '%s\n' "$hj" >"$cache.head" && printf '%s' "$key" >"$cache.key"; } 2>/dev/null || true
            fi
          else
            hj=null
            unread=true
            why="$(_aif_start_why "$(cat "$tmp/err" 2>/dev/null)")"
            [ -n "$why" ] || why="the card could not be read"
          fi
        fi
        ;;
    esac
    # What this machine knows of the run — In Progress (R2–R4) and Review
    # (R7/R8) only, the two columns whose routing turns on it.
    loc=null
    case "$col" in
      in_progress | review)
        loc="$(_aif_work_status_json "$root" "$id" 2>/dev/null </dev/null)" || loc=""
        [ -n "$loc" ] || loc=null
        ;;
    esac
    f="$main/$AIF_TASKS_DIR/$id/ticket.md"
    tf=false
    meta=""
    if [ -f "$f" ]; then
      tf=true
      meta="$(aif_meta_json "$f" 2>/dev/null)" || meta=""
    fi
    # A meta that does not parse is no meta (as `aif rules` skips it), not a
    # tick that cannot be read.
    # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
    jq -cn --arg t "$id" --argjson hj "$hj" --argjson unread "$unread" --arg why "$why" \
      --argjson loc "$loc" --argjson tf "$tf" --arg meta "$meta" '
      { ticket: $t, head: $hj, unread: $unread, unread_why: (if $why == "" then null else $why end),
        local: $loc, ticket_file: $tf,
        meta: ((if $meta == "" then null else (try ($meta | fromjson) catch null) end)
               | if type == "object" then
                   { depends_on: (if (.depends_on | type) == "array" then [ .depends_on[] | tostring ] else [] end),
                     request: (if (.request | type) == "string" then .request else null end),
                     slice: (.slice // null) }
                 else null end) }' >>"$tmp/extras" 2>/dev/null || return 1
  done 3<"$tmp/order"
  return 0
}

# _aif_start_build <root> — the facts' `build`: who builds on this checkout.
#
# A loop in another terminal holds the loop lock (lib/paths.sh
# aif_loop_lock_dir), and its owner.json says its pid, host, how many at once,
# whether it idles and where it logs (lib/cmd_work.sh _aif_work_loop_lock):
# `elsewhere`, at the loop's parallel. Its liveness is matched on the command
# that takes that lock, `aif work … --loop` — a pid reused by anything else is
# a dead lock (docs/DEFECTS.md 14.5). No live loop: `none` under --no-build,
# else `here` — this shift runs the loop itself, in the foreground (R12). A
# dead lock is still described, `live: false`: the next loop takes it over.
_aif_start_build() {
  local root="$1" lock live=false owner="" loopj=null mode=here par
  par="$(_aif_start_parallel "$root")"
  lock="$(aif_loop_lock_dir "$root")"
  if [ -d "$lock" ]; then
    ! _aif_work_lock_live_as "$lock" '*aif\ work*--loop*' || live=true
    owner="$(jq -c 'objects' "$lock/owner.json" 2>/dev/null)" || owner=""
    [ -n "$owner" ] || owner='{}'
    # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
    loopj="$(jq -cn --argjson o "$owner" --argjson live "$live" '
      { live: $live, pid: ($o.pid // null), host: ($o.host // null), idle: (($o.idle // 0) == 1),
        parallel: ($o.parallel // null), logdir: ($o.logdir // null) }')" || loopj=null
    [ "$live" = false ] || mode=elsewhere
  fi
  if [ "$mode" != elsewhere ] && [ "${AIF_START_FLAG_NO_BUILD:-0}" = 1 ]; then
    mode=none
  fi
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  jq -cn --arg mode "$mode" --argjson p "$par" --argjson loop "$loopj" --arg hold "${AIF_START_BUILD_HOLD:-}" '
    { mode: $mode,
      parallel: (if $mode == "elsewhere" and ($loop.parallel | type) == "number" and $loop.parallel >= 1
                 then $loop.parallel else $p end),
      hold: (if $hold == "" then null else $hold end),
      loop: $loop }'
}

# _aif_start_ready_gates <root> <tmp> — the ready gate of each card the oracle
# could pull this tick (R14), one `{ ticket, rc }` per line of <tmp>/gates:
# 0 ready · 1 not · 3 the environment (`aif _ready`, the same gate the worker
# runs at intake, offline).
#
# A gate is a process per card, so only when a pull could be offered: the
# build has a free slot (the oracle's own rule — in mode here, Ready holds at
# least one card and fewer than a round; elsewhere, the loop's Ready and its
# live builds short of its parallel) — and only for a candidate (Backlog, no
# depends_on, no aif line, no hold label, a ticket file), in Backlog order,
# until as many have passed as there are slots. The rest stay null.
#
# A candidate the shift has offered already (its `R14 <ID>` key done) is
# still gated — its line in the summary needs the gate's answer — but does not
# fill a slot: the oracle leaves it out, and counting it here stopped the
# gates at the cards the person had just passed by, so no other card in
# Backlog was ever offered or even listed, and the shift ended "nothing left"
# beside an idle loop with cards it could pull.
_aif_start_ready_gates() {
  local root="$1" tmp="$2" main list free id rc passed=0 n=0 nl tab
  nl='
'
  tab="$(printf '\t')"
  main="$(aif_main_root "$root")"
  : >"$tmp/gates"
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  list="$(jq -r --slurpfile x "$tmp/extras" --slurpfile b "$tmp/build.json" \
    --arg holds "${AIF_RELEASE_HOLD_LABELS:-parked retired-direction}" '
    ($x | map({ key: .ticket, value: . }) | from_entries) as $e
    | $b[0] as $b
    | [ $holds | splits("[[:space:]]+") | select(length > 0) ] as $hl
    | ([ .[] | select(.column == "ready") ] | length) as $ready
    | ([ .[] | select(.column == "in_progress") | select(($e[.ticket].local.class // "") == "live") ] | length) as $live
    | (if $b.mode == "here" then (if $ready >= 1 and $ready < $b.parallel then $b.parallel - $ready else 0 end)
       elif $b.mode == "elsewhere" then $b.parallel - ($ready + $live)
       else 0 end) as $free
    | if $free < 1 then "0"
      else ("\($free)",
            ([ .[] | select(.column == "backlog") | . as $c | ($e[$c.ticket] // {}) as $y
               | select($y.unread != true and ($y.head.line // null) == null and $y.ticket_file == true)
               | select((($y.meta.depends_on // []) | length) == 0)
               | select(any(($c.labels // [])[]; . as $l | any($hl[]; . == $l)) | not) ]
             | sort_by(.pos) | .[].ticket))
      end' "$tmp/cards.json" 2>/dev/null)" || return 1
  for id in $list; do
    n=$((n + 1))
    if [ "$n" -eq 1 ]; then
      free="$id"
      continue
    fi
    [ "$passed" -lt "$free" ] || break
    rc=0
    (cd "$main" && "$AIF_ROOT/bin/aif" _ready "$id") >/dev/null 2>&1 </dev/null || rc=$?
    case "$nl${AIF_START_DONE:-}" in
      *"${nl}R14 $id$tab"*) ;;
      *) [ "$rc" -ne 0 ] || passed=$((passed + 1)) ;;
    esac
    jq -cn --arg t "$id" --argjson rc "$rc" '{ ticket: $t, rc: $rc }' >>"$tmp/gates" || return 1
  done
  return 0
}

# _aif_start_loose <root> <tmp> <re> — every ticket in tasks/ with no card on
# the board, one line of <tmp>/loose each: `stub` (its body still carries the
# `_ticket-init` scaffold's prompt — a cut begun and abandoned), `tracked`
# (committed) and its meta's request and slice; `landed` is added with the
# rest of the land lines. On Trello an archived Done card looks exactly like
# this, which is why the oracle asks all three before it cuts one (R19c).
_aif_start_loose() {
  local root="$1" tmp="$2" re="$3" main ids f id stub tracked meta nl
  main="$(aif_main_root "$root")"
  nl='
'
  : >"$tmp/loose"
  # Every card, in any column — one in a list the project does not map is
  # still a card, and its ticket is not loose.
  ids="$(jq -r '.[].ticket // empty' "$tmp/status.json" 2>/dev/null)" || return 1
  for f in "$main/$AIF_TASKS_DIR"/*/ticket.md; do
    [ -f "$f" ] || continue
    id="$(basename "$(dirname "$f")")"
    printf '%s\n' "$id" | grep -Eq -- "$re" || continue
    case "$nl$ids$nl" in
      *"$nl$id$nl"*) continue ;;
    esac
    stub=false
    ! grep -qF '<!-- Describe the need in your own words.' "$f" 2>/dev/null || stub=true
    tracked=false
    ! git -C "$main" ls-files --error-unmatch -- "$AIF_TASKS_DIR/$id/ticket.md" >/dev/null 2>&1 || tracked=true
    meta="$(aif_meta_json "$f" 2>/dev/null)" || meta=""
    # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
    jq -cn --arg t "$id" --argjson stub "$stub" --argjson tracked "$tracked" --arg meta "$meta" '
      ((if $meta == "" then null else (try ($meta | fromjson) catch null) end)
       | if type == "object" then . else {} end) as $m
      | { ticket: $t, stub: $stub, tracked: $tracked,
          request: (if ($m.request | type) == "string" then $m.request else null end),
          slice: ($m.slice // null) }' >>"$tmp/loose" || return 1
  done
  return 0
}

# _aif_start_oracle <facts-file> — the plan for those facts (lib/start.jq), one
# compact JSON object on stdout. Pure: the same facts give the same plan.
_aif_start_oracle() {
  jq -c -f "$AIF_ROOT/lib/start.jq" "$1"
}

# ----------------------------------------------------------------------------
# The driver — what the facts and the oracle leave to bash: the start, the
# moves, the control point, the units, the wait and the end
# (docs/AUTOPILOT-PHASE1.md cluster F).
#
# One process, in the person's terminal, for hours. It is fenced the way the
# loop is: every board call runs in `$(…)` or `( … )` (on Trello a failure is
# aif_die, which would otherwise end the shift with 1); a child that gets the
# terminal — a session, a land, the loop — runs between `set -m` and a `set
# +m` on the very next line (docs/FINDINGS.md #24, #27, #28), its code read
# with `|| rc=$?` under the errexit bin/aif sets; and what a child did is read
# off the board on the next tick, never off its exit code alone — a session's
# code says how claude was stopped, not what the person meant (#28: `/exit`,
# two Ctrl-C and a closed window are all 0).
#
# Its state between ticks is a handful of AIF_START_* globals — what the facts
# read (_aif_start_facts lists them) and what the summary prints; globals,
# because a trap fires with the signal's name only.

_aif_start_usage() {
  cat <<EOF
usage: aif start [options]

  The shift: the human's half of the board, one session at a time, in this
  terminal. Review first — each built card opened as /aif-review in claude —
  then the analyst on what came back, then the owner; the board moved by
  fixed rules on fixed first lines (wrong: back to the analyst, cancel: to
  Done, a slice released once what it depends on has landed, a block by the
  environment during the shift back to Ready), and what a worker on this
  machine left half-done finished without a key (a built run's report and
  its move to Review, a stopped run's blocked: and its move to Needs Human);
  the rest listed with the command that would do it. Each unit waits at the
  control point for a key, and after a countdown acts on its own where that
  is safe — a review opens; a card whose worker died has what it left
  running sent a TERM and goes to the top of Ready, unless any of it
  outlives 30 s; a demo not as expected goes back to Backlog as rework: —
  and leaves what is not: a land, a pull, a person's answer.

    aif start --no-build        here: the reviews, the analyst, the owner —
    aif work --loop --idle      …and in a second terminal: the builds; the
                                shift waits for that loop while Ready holds
                                cards, and leaves it running when it ends
    aif start                   both in this terminal: when Ready holds cards
                                the loop runs here, in the foreground
    aif start --dry-run         what the shift would do now; touches nothing

  At the control point: Enter does it · s skips it for the shift · p pauses
  · q ends the shift; any other key pauses, and the countdown never acts
  after a key. Keys typed on a Ukrainian or Russian layout are read as the
  Latin keys in their place. Ctrl-Z does nothing inside a shift. A session
  that changed nothing — on its card, the board's cards, requests/ or
  tasks/ — pauses the shift instead of opening the next one. The end says
  what was done, what is left with the command for each, and claude
  --resume <uuid> for every session it opened.

  --no-build         never run the loop here; a loop in another terminal builds
  --parallel N       how many the loop here builds at once, and how far ahead
                     the analyst cuts — three rounds (default 2; a loop in
                     another terminal says its own)
  --model M          every role's model: an alias the profile maps, or a full id
  --model-review M   the reviewer's (default: claude's own)
  --model-ba M       the analyst's (default opus)
  --model-po M       the owner's (default opus)
  --model-pjm M      the project manager's (default: claude's own)
  --profile P        which profile; default: the project's (.aif/profile.local)
  --retry-runs       put a card back in Ready, once a shift, when what stopped
                     its run was an instrument — never a cap, a rejection or a
                     person's stop
  --po               when nothing is left, open the owner (/aif-po) instead of
                     ending the shift
  --no-pjm           a person's words under a card's line are listed, not
                     opened with the project manager
  --max-units N      end after N units acted on
  --dry-run          one look at the board, and the plan; nothing posted,
                     moved, opened or locked

Defaults per developer go in .aif/start.local, KEY=VALUE, gitignored: MODEL,
MODEL_REVIEW, MODEL_BA, MODEL_PO, MODEL_PJM, PARALLEL, WAIT (the control
point's countdown, 10 s) and POLL (how often a waiting shift looks again,
30 s). A flag beats the file; for a role, its own flag beats --model.

Exit: 0 nothing left, q or --max-units · 1 a session that failed, a bad flag
· 3 the environment (the start, a board that did not answer twice, a machine
that fails its preflight again, a build that ended 3) · 129 the terminal
closed · 130 Ctrl-C · 143 a TERM.
EOF
}

# _aif_start_log <text> — a line into the shift's own log, its colour taken
# off. Once the terminal is gone (a hang-up) stderr IS that log, and the line
# is not written twice.
_aif_start_log() {
  local esc
  [ "${AIF_START_NOLOG:-0}" = 0 ] || return 0
  [ -n "${AIF_START_SHIFT_DIR:-}" ] && [ -d "$AIF_START_SHIFT_DIR" ] || return 0
  esc="$(printf '\033')"
  printf '%s\n' "$1" | sed "s/$esc\[[0-9;]*m//g" >>"$AIF_START_SHIFT_DIR/shift.log" 2>/dev/null || true
}

# _aif_start_out <text> — a line for the person, on stderr, and into the log.
# A print that fails is nobody's problem: after a hang-up the terminal is
# gone, and under errexit a failed print would be the shift's exit code (the
# loop learned it, lib/cmd_work.sh _aif_work_loop_signal) — but it is flushed
# away (_aif_start_flush).
_aif_start_out() {
  printf '%s\n' "$1" >&2 2>/dev/null || _aif_start_flush
  _aif_start_log "$1"
}

# _aif_start_flush — what a failed print left behind, thrown away. bash 3.2's
# printf writes through stdio, and a write the terminal refused (EIO, the
# window gone) leaves its bytes in the buffer; every `$(…)` after it forks a
# child that inherits the buffer and flushes it into the capture on its way
# out. So a shift whose terminal died without its hang-up reaching it (zsh
# with NO_HUP, a leader that ignores HUP) read the summary's plan as JSON plus
# a countdown's redraw — jq refused it, no summary.json — and the lock's pid
# as `$$` plus text, so the lock stayed (docs/FINDINGS.md #28). A print that
# succeeds empties the buffer, wherever it goes; an empty one does not (its
# format writes nothing, and nothing is flushed — probed).
_aif_start_flush() {
  printf '\n' >/dev/null 2>&1 || true
}

# _aif_start_say <label> <text> — one status line, the worker's shape
# (_aif_work_say): a dim label, then what happened.
_aif_start_say() {
  _aif_start_out "$(printf '%s%-9s%s %s' "$AIF_C_DIM" "$1" "$AIF_C_RESET" "$2")"
}

# ----------------------------------------------------------------- the lock

# _aif_start_lock <root> <shiftdir> <mode> — take this checkout's shift lock
# (lib/paths.sh aif_shift_lock_dir), or say who holds it. rc 0 taken,
# AIF_START_LOCK names it · 1 held, said.
#
# One shift per checkout: two would offer the same review twice, and each
# make the same move once. The run lock's shape (_aif_work_lock) and its
# takeover of a holder that is gone, with the race its comment writes down;
# its liveness matches `aif start`, never the word — a reused pid held by a
# `claude '/aif-review …'` session is not a shift (docs/DEFECTS.md 14.5).
# owner.json names the shift's directory before it exists: it is made only
# once the start has passed, so that a refused start leaves none.
_aif_start_lock() {
  local root="$1" shiftdir="$2" mode="$3" lock pid
  AIF_START_LOCK=""
  lock="$(aif_shift_lock_dir "$root")"
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  if ! mkdir "$lock" 2>/dev/null; then
    if _aif_work_lock_live_as "$lock" '*aif\ start*'; then
      aif_err "a shift is already open on this checkout ($(_aif_start_lock_held "$lock")) — a second would offer the same units again. End that one with q or Ctrl-C in its terminal"
      return 1
    fi
    pid="$(_aif_work_lock_pid "$lock")"
    rm -rf "${lock:?}"
    if ! mkdir "$lock" 2>/dev/null; then
      aif_err "a shift is already open on this checkout — another took its lock just now"
      return 1
    fi
    _aif_start_say "lock" "the shift that held this checkout (pid ${pid:-?}) is gone; taken over"
  fi
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  if ! {
    jq -n --argjson pid "$$" --arg host "$(aif_host_short)" \
      --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --argjson started "$(date +%s)" \
      --arg mode "$mode" --arg dir "$shiftdir" \
      '{ pid: $pid, host: $host, started_at: $at, started: $started, mode: $mode, shiftdir: $dir }' \
      >"$lock/owner.json.tmp" &&
      mv "$lock/owner.json.tmp" "$lock/owner.json"
  } 2>/dev/null; then
    # Unsigned, it would read as a live shift for a minute.
    rm -rf "${lock:?}"
    aif_err "could not sign the shift lock at $lock — nothing was started"
    return 1
  fi
  AIF_START_LOCK="$lock"
  return 0
}

# _aif_start_lock_held <lock-dir> — "pid N, since T" of the shift that holds it.
_aif_start_lock_held() {
  local held
  held="$(jq -r '"pid " + (.pid | tostring) + ", since " + .started_at' "$1/owner.json" 2>/dev/null)" || held=""
  [ -n "$held" ] || held="its lock was taken a moment ago"
  printf '%s' "$held"
}

# _aif_start_unlock — release the shift lock, if this process holds it.
_aif_start_unlock() {
  local lock="${AIF_START_LOCK:-}"
  [ -n "$lock" ] || return 0
  AIF_START_LOCK=""
  [ "$(_aif_work_lock_pid "$lock")" = "$$" ] || return 0
  rm -rf "${lock:?}" 2>/dev/null || true
}

# _aif_start_early <EXIT|INT|TERM|HUP> — the handler between the shift lock
# and the start's end (_aif_start_signal replaces it): the profile, the board
# check and the probe, each of which may refuse, and the probe a Ctrl-C may
# end. The lock goes with the process either way; nothing else exists yet to
# speak for — no shift directory, no summary. An interrupt, a TERM and a
# hang-up end in 130, 143 and 129; an exit keeps its own code.
_aif_start_early() {
  _aif_start_unlock || true
  case "${1:-}" in
    INT) exit 130 ;;
    TERM) exit 143 ;;
    HUP) exit 129 ;;
  esac
  return 0
}

# ------------------------------------------------------------- the terminal

# _aif_start_tty_ok — rc 0 while this process can still open its terminal.
# Grouped, because a failed `</dev/tty` reports itself before a plain
# 2>/dev/null after it applies (docs/FINDINGS.md #28).
_aif_start_tty_ok() {
  { : </dev/tty; } 2>/dev/null
}

# _aif_start_tty_restore [<rc of what had the terminal>] — the terminal as the
# shift found it. Only a kill -9 of claude leaves it broken (#28): raw, and
# in the alternate screen with mouse, focus and paste reporting on, which no
# stty undoes — so after a 137 those modes are reset too. A trap that exits
# in the middle of the control point's read leaves it -icanon -echo, the
# read's own mode (#28): every way out of the shift comes through here.
_aif_start_tty_restore() {
  if [ -n "${AIF_START_STTY:-}" ]; then
    { stty "$AIF_START_STTY" </dev/tty; } 2>/dev/null || true
  fi
  if [ "${1:-0}" = 137 ]; then
    { printf '\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1004l\033[?2004l\033[?2031l\033[?25h\033[?1049l' >/dev/tty; } 2>/dev/null || true
  fi
  return 0
}

# _aif_start_watch_on / _aif_start_watch_off — around each child the shift
# hands the terminal to (a session, a land, the loop): Ctrl-Z there does
# nothing. A non-interactive bash under `set -m` never returns from a
# foreground wait whose child has stopped (probed on /bin/bash 3.2, a pty, as
# the session leader and as a job of an interactive zsh: the shift S, the
# child T+, the line after the call never ran) — and claude 2.1.226 maps
# Ctrl+Z to suspend: it leaves raw mode, says "Run `fg`", and stops its own
# group. The terminal stayed with the stopped group, nobody's shell could
# type `fg`, Ctrl-C and q waited in the stopped group, and a window closed
# then left the shift alive — the hang-up its trap waits behind the stopped
# child for, the lock still naming it, the next `aif start` refused
# (docs/FINDINGS.md #28). Ignoring TSTP would not do for claude, which stops
# itself with kill(0) and would sit out of raw mode waiting for a SIGCONT.
#
# So a watcher, in the shift's own process group (started before `set -m`,
# never the foreground): once a second, a child of the shift that leads its
# group and is stopped gets SIGCONT — claude's own handler takes raw mode
# back and redraws — and the person is told once, on the terminal and in
# shift.log. It ignores the hang-up a shell forwards to the shift's group, so
# that a stopped child it alone can wake still is woken and ends on the
# closed terminal; it ends when the shift does, or with exit 0 on the TERM
# _aif_start_watch_off sends (a TERM that killed it would be reported as
# "Terminated"), and waits on its `sleep` with `wait`, which a trap
# interrupts. Its traps are its own process's, as the ledger's subshell
# keeps its own (lib/ledger.sh): the shift's handler is untouched.
_aif_start_watch_on() {
  local me=$$
  AIF_START_WATCH=""
  (
    set +e
    trap 'exit 0' TERM
    trap '' HUP INT
    said=" "
    while kill -0 "$me" 2>/dev/null; do
      sleep 1 &
      wait "$!" 2>/dev/null
      gs="$(ps -A -o pid= -o ppid= -o pgid= -o stat= 2>/dev/null |
        awk -v me="$me" '$2 == me && $1 == $3 && $4 ~ /^T/ { print $3 }')"
      for g in $gs; do
        kill -CONT -- "-$g" 2>/dev/null
        case "$said" in
          *" $g "*) continue ;;
        esac
        said="$said$g "
        { printf '\r\n%s\r\n' "aif start: Ctrl-Z does nothing inside a shift — it goes on (/exit ends a session, Ctrl-C a land or the loop)" >/dev/tty; } 2>/dev/null
        _aif_start_log "a child of the shift stopped (Ctrl-Z, pid $g) — continued"
      done
    done
  ) </dev/null >/dev/null 2>&1 &
  AIF_START_WATCH=$!
}

_aif_start_watch_off() {
  local w="${AIF_START_WATCH:-}"
  AIF_START_WATCH=""
  [ -n "$w" ] || return 0
  kill -TERM "$w" 2>/dev/null || true
  wait "$w" 2>/dev/null || true
}

# _aif_start_key <secs> [<prefix> <suffix>] — the one reader of every key the
# shift waits for: the control point's countdown, the wait, every pause.
# Sets AIF_START_KEY to the key, `enter`, `none` (<secs> passed with no key)
# or `gone` (the terminal is). <secs> 0 is no timeout — a pause. The line
# <prefix><seconds left><suffix> is redrawn each second; with no timeout it
# is printed once, <prefix><suffix>.
#
# One read a second (bash 3.2's `read -t` takes whole seconds), on a fresh
# open of /dev/tty, which works when stdin is not the terminal (#28) — opened
# on a descriptor of its own (6) and read with `read -u`, never as a
# redirection of the read itself: bash runs a trap in the middle of the
# builtin it interrupts, inside that builtin's redirections, so a Ctrl-C
# during `{ read … </dev/tty; } 2>/dev/null` ran the shift's INT handler with
# its stderr on /dev/null, and the summary it printed reached nobody (probed
# on /bin/bash 3.2, a pty; writes to /dev/tty arrived, writes to fd 2 did
# not). The open is the one grouped under 2>/dev/null, and it lasts past the
# group because it is an exec.
#
# On 3.2 a timeout is rc 1 with the variable left as it was, and Enter is rc
# 0 with it empty: the variable is emptied before every read and the rc
# decides first. A terminal that is gone answers at once — the open fails, or the
# read returns rc 1 without waiting — and a countdown counted in reads would
# run out in milliseconds and act on its default, a pause would spin; so the
# open is tried before each read, the countdown is wall time (SECONDS), and
# three reads in a row that return without a second passing are the
# terminal gone too (critics operations-14). A typed Ctrl-C during the read
# runs the INT trap, which exits.
#
# The seam: with AIF_START_KEYS set, its first character is the key and is
# taken off — `.` Enter, `_` no key (the timeout, after <secs> seconds; in a
# pause, where nothing times out, `q`), anything else that key; an empty
# string is `q`. A harness can drive every wait with it and never hang.
_aif_start_key() {
  local secs="$1" pre="${2:-}" suf="${3:-}" key k2 rc fast=0 t0 left deadline c
  AIF_START_KEY=""
  if [ -n "${AIF_START_KEYS+x}" ]; then
    if [ -n "$pre$suf" ]; then
      if [ "$secs" -gt 0 ]; then _aif_start_out "$pre$secs$suf"; else _aif_start_out "$pre$suf"; fi
    fi
    c="${AIF_START_KEYS:0:1}"
    AIF_START_KEYS="${AIF_START_KEYS:1}"
    case "$c" in
      '') AIF_START_KEY=q ;;
      .) AIF_START_KEY=enter ;;
      _)
        if [ "$secs" -gt 0 ]; then
          sleep "$secs" 2>/dev/null || true
          AIF_START_KEY=none
        else
          AIF_START_KEY=q
        fi
        ;;
      *) AIF_START_KEY="$c" ;;
    esac
    return 0
  fi
  if [ "$secs" -eq 0 ] && [ -n "$pre$suf" ]; then
    _aif_start_out "$pre$suf"
  fi
  deadline=$((SECONDS + secs))
  while :; do
    if [ "$secs" -gt 0 ]; then
      left=$((deadline - SECONDS))
      if [ "$left" -le 0 ]; then
        printf '\n' >&2 2>/dev/null || _aif_start_flush
        AIF_START_KEY=none
        return 0
      fi
      printf '\r\033[K%s%s%s' "$pre" "$left" "$suf" >&2 2>/dev/null || _aif_start_flush
    fi
    if ! { exec 6</dev/tty; } 2>/dev/null; then
      AIF_START_KEY=gone
      return 0
    fi
    key=""
    rc=0
    t0=$SECONDS
    IFS= read -r -u 6 -t 1 -n 1 -s key || rc=$?
    # bash 3.2 reads one BYTE, in every locale (probed: C, en_US.UTF-8,
    # uk_UA.UTF-8), and a person who just wrote Ukrainian in a session types
    # the control point's keys on that layout: q is й, two bytes, neither a
    # key — the countdown ran on to the default, and `s` on a demo posted the
    # rework it was pressed to stop. A Cyrillic lead byte takes the next one,
    # and the letter is read as the key in its place (_aif_start_layout).
    if [ "$rc" -eq 0 ] && { [ "$key" = $'\xd0' ] || [ "$key" = $'\xd1' ]; }; then
      k2=""
      IFS= read -r -u 6 -t 1 -n 1 -s k2 || true
      _aif_start_layout "$key$k2"
      key="$AIF_START_LATIN"
    fi
    exec 6<&-
    if [ "$rc" -eq 0 ]; then
      [ "$secs" -eq 0 ] || printf '\n' >&2 2>/dev/null || _aif_start_flush
      if [ -z "$key" ]; then AIF_START_KEY=enter; else AIF_START_KEY="$key"; fi
      _aif_start_log "key: ${AIF_START_KEY}"
      return 0
    fi
    if [ "$rc" -eq 1 ] && [ "$SECONDS" -eq "$t0" ]; then
      fast=$((fast + 1))
      if [ "$fast" -ge 3 ]; then
        AIF_START_KEY=gone
        return 0
      fi
    else
      fast=0
    fi
  done
}

# _aif_start_layout <bytes> — AIF_START_LATIN: the key on the Latin layout
# that types this Cyrillic letter on the Ukrainian and Russian ЙЦУКЕН layouts
# (й q, і or ы s, з p, д l, к r, н y, и b), or `?` for any other — which the
# control point takes as a key it does not know, and pauses on. Quoted
# patterns, matched whole: the same in C and in a UTF-8 locale (probed).
_aif_start_layout() {
  case "$1" in
    $'\xd0\xb9') AIF_START_LATIN=q ;;
    $'\xd1\x96' | $'\xd1\x8b') AIF_START_LATIN=s ;;
    $'\xd0\xb7') AIF_START_LATIN=p ;;
    $'\xd0\xb4') AIF_START_LATIN=l ;;
    $'\xd0\xba') AIF_START_LATIN=r ;;
    $'\xd0\xbd') AIF_START_LATIN=y ;;
    $'\xd0\xb8') AIF_START_LATIN=b ;;
    *) AIF_START_LATIN='?' ;;
  esac
}

# _aif_start_gone — the terminal is gone and no hang-up said so (an emulator
# that signals only the foreground group, a shell that does not pass HUP on):
# the hang-up's way out all the same, exit 129.
_aif_start_gone() {
  _aif_start_signal HUP
}

# _aif_start_pause <why> — wait for the person: Enter goes on, q ends the
# shift (exit 0). What follows a session that changed nothing, a session or
# a land ended by a signal, a build stopped by Ctrl-C, a unit with a warning
# nobody answered, and the p key — anything where acting on its own would
# chain work nobody is watching. No timeout.
_aif_start_pause() {
  local why="$1"
  while :; do
    _aif_start_key 0 "paused — $why — Enter: go on · q: end the shift$(_aif_start_b_hint)" ""
    case "$AIF_START_KEY" in
      enter) return 0 ;;
      q) _aif_start_finish 0 "ended at a pause (q)" ;;
      gone) _aif_start_gone ;;
      b)
        if _aif_start_b_ok; then
          _aif_start_build_now "$AIF_START_ROOT"
          return 0
        fi
        ;;
    esac
  done
}

# _aif_start_b_ok — rc 0 when `b` means something now: this shift builds
# (mode here) and its build is held (R13).
_aif_start_b_ok() {
  [ -n "${AIF_START_BUILD_HOLD:-}" ] || return 1
  [ -f "${AIF_START_FACTS:-}" ] || return 1
  [ "$(jq -r '.build.mode // empty' "$AIF_START_FACTS" 2>/dev/null)" = here ]
}

_aif_start_b_hint() {
  if _aif_start_b_ok; then printf ' · b: build again'; fi
  return 0
}

# _aif_start_wait <why> — work in flight elsewhere (the oracle's wait): one
# line redrawn each second, the control point's keys, and a new look every
# POLL seconds. Not an end — a shift beside a loop in another terminal ends
# only once nothing is left on either side (critics operations-1).
_aif_start_wait() {
  local why="$1" poll="$AIF_START_POLL_S" deadline left
  deadline=$((SECONDS + poll))
  while :; do
    left="$poll"
    if [ -z "${AIF_START_KEYS+x}" ]; then
      left=$((deadline - SECONDS))
      [ "$left" -gt 0 ] || return 0
    fi
    _aif_start_key "$left" "waiting — $why · p: pause · q: end the shift$(_aif_start_b_hint) (next look in " "s)"
    case "$AIF_START_KEY" in
      none | enter) return 0 ;;
      p)
        _aif_start_pause "paused while waiting — $why"
        return 0
        ;;
      q) _aif_start_finish 0 "ended while waiting (q)" ;;
      gone) _aif_start_gone ;;
      b)
        if _aif_start_b_ok; then
          _aif_start_build_now "$AIF_START_ROOT"
          return 0
        fi
        ;;
    esac
  done
}

# ------------------------------------------------------------------- memory

# _aif_start_done <key> <note> — the shift has had this fact: offered, acted
# on, skipped, or a move tried. The oracle leaves it out from now on and
# lists it as a line with the note (lib/start.jq, research R24).
_aif_start_done() {
  local note
  note="$(printf '%s' "$2" | tr '\t\n' '  ')"
  AIF_START_DONE="${AIF_START_DONE}$1	${note}
"
}

# _aif_start_record <unit> <what> [<rc> <after> <model> <session-id> <changed 0|1>]
# — one unit for the summary.
_aif_start_record() {
  local r
  r="$(_aif_start_record_json "$@")" || return 0
  [ -n "$r" ] || return 0
  AIF_START_UNITS="${AIF_START_UNITS}${r}
"
}

# _aif_start_record_json — the record _aif_start_record keeps, on stdout.
_aif_start_record_json() {
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  printf '%s' "$1" | jq -c --arg what "$2" --arg rc "${3:-}" --arg after "${4:-}" \
    --arg model "${5:-}" --arg sid "${6:-}" --arg changed "${7:-}" '
    { rule, key, kind, ticket, file, role, name, before: .column,
      after: (if $after == "" then null else $after end),
      model: (if .kind == "session" and $sid != "" then (if $model == "" then "default" else $model end) else null end),
      session_id: (if $sid == "" then null else $sid end),
      rc: (if $rc == "" then null else ($rc | tonumber) end),
      changed: (if $changed == "" then null else ($changed == "1") end),
      what: $what }' 2>/dev/null
}

# _aif_start_acted — one more unit acted on; at --max-units the shift ends.
_aif_start_acted() {
  AIF_START_ACTED=$((AIF_START_ACTED + 1))
  if [ "${AIF_START_MAX_UNITS:-0}" -gt 0 ] && [ "$AIF_START_ACTED" -ge "$AIF_START_MAX_UNITS" ]; then
    _aif_start_refresh
    _aif_start_finish 0 "--max-units $AIF_START_MAX_UNITS reached"
  fi
  return 0
}

# ------------------------------------------------------------ the board

# _aif_start_post <root> <ID> <file> [<full-at>] — one comment in the shift's
# voice. rc 0 · 1, AIF_START_ERR the first line of why.
_aif_start_post() {
  local err rc=0
  AIF_START_ERR=""
  err="$( (AIF_BOARD_BY="aif start" AIF_BOARD_FULL_AT="${4:-}" aif_board_comment "$1" "$2" "$3" >/dev/null) 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || AIF_START_ERR="$(_aif_start_why "$err")"
  return "$rc"
}

# _aif_start_mv <root> <ID> <column> [top] — one move. rc 0 · 1, AIF_START_ERR.
_aif_start_mv() {
  local err rc=0
  AIF_START_ERR=""
  err="$( (aif_board_move "$1" "$2" "$3" "${4:-}" >/dev/null) 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || AIF_START_ERR="$(_aif_start_why "$err")"
  return "$rc"
}

# _aif_start_comment_move <root> <ID> <comment> <column> [top] — the comment
# first, then the move, and no move without the comment (lib/release.sh: a
# card in Ready with nothing on it to say what put it there reads as a
# hand-drag). A comment that did not go through is kept in the shift's
# directory and named with the commands that finish it by hand. rc 0 · 1
# (said).
#
# AIF_START_BYHAND is those commands after a failure, empty after a success:
# the caller puts them in the note it records the key with, so the line the
# fact becomes carries them (lib/start.jq as_line gives a move with a comment
# no command of its own — the bare move would lose the comment).
_aif_start_comment_move() {
  local root="$1" id="$2" text="$3" to="$4" top="${5:-}" f keep flag=""
  AIF_START_BYHAND=""
  [ "$top" != top ] || flag=" --top"
  if [ -n "$text" ]; then
    f="$(mktemp "${TMPDIR:-/tmp}/aif-start-XXXXXX")"
    printf '%s\n' "$text" >"$f"
    if ! _aif_start_post "$root" "$id" "$f"; then
      keep="$AIF_START_SHIFT_DIR/comment-$id.md"
      cp "$f" "$keep" 2>/dev/null || keep="$f"
      [ "$keep" = "$f" ] || rm -f "$f"
      AIF_START_BYHAND="aif board comment $id $keep && aif board move $id $to$flag"
      _aif_start_say "board" "$id — the comment did not go through (${AIF_START_ERR:-the board refused it}); nothing moved. By hand: $AIF_START_BYHAND"
      return 1
    fi
    rm -f "$f"
  fi
  if ! _aif_start_mv "$root" "$id" "$to" "$top"; then
    AIF_START_BYHAND="aif board move $id $to$flag"
    _aif_start_say "board" "$id — the move to $to did not go through (${AIF_START_ERR:-the board refused it}). By hand: $AIF_START_BYHAND"
    return 1
  fi
  return 0
}

# _aif_start_column <root> <ID> — the card's column now, or `?`.
_aif_start_column() {
  local c
  c="$( (aif_board_card_column "$1" "$2") 2>/dev/null)" || c=""
  printf '%s' "${c:-?}"
}

# _aif_start_report <root> <ID> <branch|checkout> <out> — the run's report.md
# into <out>: the branch's (what `aif land` takes), or a --no-worktree run's
# in this checkout. rc 1 when there is none.
_aif_start_report() {
  local main
  main="$(aif_main_root "$1")"
  if [ "$3" = checkout ]; then
    cp "$main/$AIF_TASKS_DIR/$2/report.md" "$4" 2>/dev/null && [ -s "$4" ]
    return
  fi
  git -C "$main" show "aif/$2:$AIF_TASKS_DIR/$2/report.md" >"$4" 2>/dev/null && [ -s "$4" ]
}

# ---------------------------------------------------------------- the moves

# _aif_start_moves <root> <plan> — every move of the tick, in the plan's
# order, each one's key recorded whether it went through or not: a move that
# failed is a line with the command that does it by hand, and the next tick
# waits POLL seconds before it looks again — no tight loop against a board
# answering 429, and a POST is never retried (lib/board.sh). The environment
# retries (R16) are made last, together, behind ONE preflight.
_aif_start_moves() {
  local root="$1" plan="$2" n i=0 m env=""
  n="$(jq '.moves | length' "$plan")"
  while [ "$i" -lt "$n" ]; do
    m="$(jq -c ".moves[$i]" "$plan")"
    i=$((i + 1))
    if [ "$(printf '%s' "$m" | jq -r '.kind')" = env-retry ]; then
      env="$env$m
"
      continue
    fi
    _aif_start_move "$root" "$m"
  done
  [ -z "$env" ] || _aif_start_env_retries "$root" "$env"
  return 0
}

# _aif_start_move <root> <move> — one move: its comment first (where it has
# one), then the column. One line for the person when it went through.
_aif_start_move() {
  local root="$1" m="$2" rule key kind id to from where file comment text ok=0 note rc out f full kind2 why
  rule="$(printf '%s' "$m" | jq -r '.rule')"
  key="$(printf '%s' "$m" | jq -r '.key')"
  kind="$(printf '%s' "$m" | jq -r '.kind')"
  id="$(printf '%s' "$m" | jq -r '.ticket // empty')"
  to="$(printf '%s' "$m" | jq -r '.to // empty')"
  from="$(printf '%s' "$m" | jq -r '.from // empty')"
  where="$(printf '%s' "$m" | jq -r '.where // empty')"
  file="$(printf '%s' "$m" | jq -r '.file // empty')"
  comment="$(printf '%s' "$m" | jq -r '.comment // empty')"
  text="$(printf '%s' "$m" | jq -r '.text // empty')"
  note="moved to $to by the shift"
  AIF_START_BYHAND=""
  case "$kind" in
    sweep)
      # R10: the sweep checks every card again and posts its own comment in
      # the shift's voice; inside `$(…)`, where its aif_die on a board that
      # did not answer ends only the substitution (critics code-fit-17).
      rc=0
      out="$(aif_release_sweep "$root" "aif start" 0 2>&1)" || rc=$?
      if [ "$rc" -eq 0 ]; then
        _aif_start_say "sweep" "$text"
        printf '%s\n' "$out" | while IFS= read -r f; do
          [ -z "$f" ] || _aif_start_out "          $f"
        done
        note="the sweep ran — $(printf '%s\n' "$out" | sed -n '$p')"
        AIF_START_MOVES="${AIF_START_MOVES}sweep — $(printf '%s\n' "$out" | sed -n '$p')
"
      else
        why="$(_aif_start_why "$out")"
        _aif_start_say "sweep" "the sweep did not run (${why:-the board did not answer}) — by hand: aif board release"
        note="the sweep did not run — ${why:-the board did not answer}"
        ok=1
      fi
      _aif_start_done "$key" "$note"
      [ "$ok" -eq 0 ] || AIF_START_FAILED_MOVE=1
      return 0
      ;;
    report)
      # R3a: built here, and the report or the move to Review was lost. The
      # report is posted from where the run wrote it, as the worker posts it
      # (AIF_BOARD_FULL_AT says where the whole of it is when a board cuts
      # it), unless the card already says built.
      if [ -n "$where" ]; then
        f="$(mktemp "${TMPDIR:-/tmp}/aif-start-XXXXXX")"
        full="$AIF_TASKS_DIR/$id/report.md on branch aif/$id"
        [ "$where" != checkout ] || full="$AIF_TASKS_DIR/$id/report.md in $(aif_main_root "$root")"
        if ! _aif_start_report "$root" "$id" "$where" "$f"; then
          _aif_start_say "board" "$id — its report could not be read from the $where; nothing moved. By hand: aif work --status $id"
          ok=1
        elif ! _aif_start_post "$root" "$id" "$f" "$full"; then
          _aif_start_say "board" "$id — the report did not go through (${AIF_START_ERR:-the board refused it}); nothing moved. By hand: aif board comment $id <report.md> && aif board move $id $to"
          ok=1
        fi
        rm -f "$f"
      fi
      if [ "$ok" -eq 0 ] && [ "$from" != "$to" ] && ! _aif_start_mv "$root" "$id" "$to"; then
        _aif_start_say "board" "$id — the move to $to did not go through (${AIF_START_ERR:-the board refused it}). By hand: aif board move $id $to"
        ok=1
      fi
      ;;
    blocked)
      # R3c: stopped here, and only the move to Needs Human was lost — never
      # back to Ready. The comment the worker meant, when the board refused
      # it then (kept in .aif/tmp/blocked-<ID>.md, removed once it is
      # posted — it would otherwise read as fresh to no run); recomposed in
      # the worker's own words when the card says only `taken:`; none when
      # it already says why.
      if [ "$where" = file ] && [ -n "$file" ]; then
        if _aif_start_post "$root" "$id" "$file"; then
          rm -f "$file" 2>/dev/null || true
        else
          _aif_start_say "board" "$id — its blocked: line did not go through (${AIF_START_ERR:-the board refused it}); nothing moved. By hand: aif board comment $id $file && aif board move $id $to"
          ok=1
        fi
        if [ "$ok" -eq 0 ] && ! _aif_start_mv "$root" "$id" "$to"; then
          _aif_start_say "board" "$id — the move to $to did not go through (${AIF_START_ERR:-the board refused it}). By hand: aif board move $id $to"
          ok=1
        fi
      elif [ -n "$comment" ]; then
        kind2="${comment#blocked: }"
        kind2="${kind2%% — *}"
        why="${comment#* — }"
        f=""
        full=""
        if [ -n "$where" ]; then
          f="$(mktemp "${TMPDIR:-/tmp}/aif-start-XXXXXX")"
          _aif_start_report "$root" "$id" "$where" "$f" || : >"$f"
          full="$AIF_TASKS_DIR/$id/report.md on branch aif/$id"
        fi
        # The worker's own block (lib/cmd_work.sh): its next-step paragraph,
        # its move even when the comment is refused, its kept file — in the
        # shift's voice. A subshell: the board's aif_die ends only it.
        out="$( (
          # shellcheck disable=SC2034  # read by _aif_work_block, lib/cmd_work.sh
          AIF_WORK_BLOCK_BY="aif start"
          _aif_work_block "$root" "$id" "$kind2" "$why" "$f" "$full"
        ) 2>&1)" || true
        [ -z "$out" ] || _aif_start_out "$out"
        [ -z "$f" ] || rm -f "$f"
        [ "$(_aif_start_column "$root" "$id")" = "$to" ] || ok=1
      elif [ "$from" != "$to" ] && ! _aif_start_mv "$root" "$id" "$to"; then
        _aif_start_say "board" "$id — the move to $to did not go through (${AIF_START_ERR:-the board refused it}). By hand: aif board move $id $to"
        ok=1
      fi
      ;;
    *)
      # R5 (wrong: → rework:, cancel: → cancelled:), R17 (--retry-runs), and
      # the half-made moves finished (a comment on the card, its move lost):
      # the comment first when there is one, then the move.
      if [ "$from" = "$to" ]; then
        if [ -n "$comment" ]; then
          f="$(mktemp "${TMPDIR:-/tmp}/aif-start-XXXXXX")"
          printf '%s\n' "$comment" >"$f"
          _aif_start_post "$root" "$id" "$f" || ok=1
          rm -f "$f"
        fi
      elif ! _aif_start_comment_move "$root" "$id" "$comment" "$to"; then
        ok=1
      fi
      if [ "$ok" -eq 0 ] && [ "$kind" = retry-run ]; then
        AIF_START_RETRIED_RUN="${AIF_START_RETRIED_RUN:+$AIF_START_RETRIED_RUN }$id"
      fi
      ;;
  esac
  if [ "$ok" -eq 0 ]; then
    _aif_start_out "moved $id → $to — $text"
    AIF_START_MOVES="${AIF_START_MOVES}$rule $id → $to — $text
"
  else
    note="the shift tried to move it to $to and the board did not take it${AIF_START_BYHAND:+ — by hand: $AIF_START_BYHAND}"
    AIF_START_FAILED_MOVE=1
  fi
  _aif_start_done "$key" "$note"
  return 0
}

# _aif_start_env_retries <root> <moves, one JSON a line> — R16: cards the
# environment blocked during this shift go back to Ready, once each — after
# ONE preflight for all of them, the worker's own (_aif_work_preflight), in a
# subshell because it exits, with AIF_WORK_LOOP=1 because the suite probe is
# the loop's to run, not a supervisor's in the developer's checkout. A
# preflight that fails again is the machine: the shift ends 3, each card's
# line said.
_aif_start_env_retries() {
  local root="$1" list="$2" m id key n rc=0 head
  n="$(printf '%s' "$list" | grep -c . || true)"
  _aif_start_say "preflight" "$n card(s) blocked by the environment during this shift — the machine is checked once before they go back to Ready (its lines in shift.log)"
  (AIF_WORK_LOOP=1 _aif_work_preflight "$root" "$AIF_START_PROFILE") >>"$AIF_START_SHIFT_DIR/shift.log" 2>&1 </dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      id="$(printf '%s' "$m" | jq -r '.ticket')"
      head="$(jq -r --arg t "$id" 'first(.cards[] | select(.ticket == $t) | .head.line) // empty' "$AIF_START_FACTS" 2>/dev/null)" || head=""
      _aif_start_say "env" "$id — ${head:-blocked by the environment}"
    done <<EOF
$list
EOF
    _aif_start_finish 3 "the environment blocked cards during this shift, and the preflight fails again (exit $rc) — the machine, not the cards; shift.log has its lines"
  fi
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    id="$(printf '%s' "$m" | jq -r '.ticket')"
    key="$(printf '%s' "$m" | jq -r '.key')"
    if _aif_start_comment_move "$root" "$id" "$(printf '%s' "$m" | jq -r '.comment // empty')" ready; then
      AIF_START_RETRIED_ENV="${AIF_START_RETRIED_ENV:+$AIF_START_RETRIED_ENV }$id"
      _aif_start_out "moved $id → ready — retried once: the preflight passes again"
      AIF_START_MOVES="${AIF_START_MOVES}R16 $id → ready — retried once: the preflight passes again
"
      _aif_start_done "$key" "retried once this shift — the preflight passed"
    else
      AIF_START_FAILED_MOVE=1
      _aif_start_done "$key" "the shift tried to put it back in Ready and the board did not take it${AIF_START_BYHAND:+ — by hand: $AIF_START_BYHAND}"
    fi
  done <<EOF
$list
EOF
  return 0
}

# ---------------------------------------------------------------- the units

# _aif_start_model <role> — the model a role's session is opened with: empty
# is claude's own default (no --model).
_aif_start_model() {
  case "$1" in
    review) printf '%s' "${AIF_START_MODEL_REVIEW:-}" ;;
    ba) printf '%s' "${AIF_START_MODEL_BA:-}" ;;
    po) printf '%s' "${AIF_START_MODEL_PO:-}" ;;
    pjm) printf '%s' "${AIF_START_MODEL_PJM:-}" ;;
  esac
}

# _aif_start_uuid — a fresh session id, lower case: a uuid already used is
# refused by claude, and macOS uuidgen prints upper case (#28).
_aif_start_uuid() {
  local u
  u="$(uuidgen 2>/dev/null)" || u=""
  [ -n "$u" ] || u="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)" || u=""
  [ -n "$u" ] || return 1
  printf '%s' "$u" | tr 'A-F' 'a-f'
}

# _aif_start_snapshot <root> <ID|""> <out> — what a session could have
# changed, into <out>; its first line is the card's column (`-` with no card).
#
# Per unit, never the whole board: the loop in the other terminal moves cards
# and posts `taken:` all the time, and a whole-board comparison would read
# every session as having done something — the session that ended on a usage
# limit or a double Ctrl-C (rc 0, #28) would be followed by the next after ten
# seconds, which is the chain the comparison exists to stop (critics
# operations-4). So: the unit's own card — its column and its newest line;
# the set of cards (the analyst makes some); requests/ and tasks/ — what git
# says of them, and the content of every file it names; and HEAD (a land).
_aif_start_snapshot() {
  local root="$1" id="$2" out="$3" main st col="-" ids hj head="" paths p
  main="$(aif_main_root "$root")"
  st="$(aif_board_status_json "$root" 2>/dev/null)" || st=""
  if [ -n "$st" ] && printf '%s' "$st" | jq -e 'type == "array"' >/dev/null 2>&1; then
    ids="$(printf '%s' "$st" | jq -r '[ .[].ticket ] | sort | join(" ")')"
    if [ -n "$id" ]; then
      col="$(printf '%s' "$st" | jq -r --arg t "$id" 'first(.[] | select(.ticket == $t) | .column) // "-"')"
    fi
  else
    ids="(the board did not answer)"
  fi
  if [ -n "$id" ]; then
    hj="$(aif_board_head_json "$root" "$id" 2>/dev/null)" || true
    head="$(printf '%s' "$hj" | jq -r '"\(.line)|\(.at)"' 2>/dev/null)" || head=""
  fi
  paths="$(git -C "$main" status --porcelain --untracked-files=all -- requests tasks 2>/dev/null)" || paths=""
  # A subshell, not a group: bash runs a trap inside the redirections of what
  # it interrupts (docs/FINDINGS.md #28), so a Ctrl-C in these seconds of
  # hashing ran the shift's INT handler with its stderr on /dev/null, and the
  # summary reached shift.log and not the person.
  (
    printf '%s\n' "$col"
    printf 'cards: %s\n' "$ids"
    printf 'head: %s\n' "$head"
    printf '%s\n' "$paths"
    printf '%s\n' "$paths" | cut -c4- | sed 's/.* -> //' | while IFS= read -r p; do
      [ -f "$main/$p" ] || continue
      printf '%s %s\n' "$(aif_sha256 "$main/$p")" "$p"
    done
    for p in "$main/$AIF_REQUESTS_DIR"/*.md; do
      [ -f "$p" ] || continue
      printf '%s %s\n' "$(aif_sha256 "$p")" "${p#"$main"/}"
    done
    git -C "$main" rev-parse HEAD 2>/dev/null || true
  ) >"$out" 2>/dev/null || true
}

# _aif_start_offer <root> <unit> — the control point (R22): the unit's line
# with its countdown, and what the key says.
#
# Enter does it. No key does the unit's default — a review is opened, a
# requeue made, a demo's rework sent back — except that a unit whose default
# is to leave it (a land, a pull, a person's answer) is left, and a unit with
# a warning pauses instead. s skips it for the shift, p pauses, q ends the
# shift; a unit's own keys (l: land over a demo, r: back to Ready, y: pull);
# b builds again when this shift's build is held. Any other key pauses, the
# pause naming the keys: a key the person pressed is never followed by the
# default — ignored, the countdown ran on and acted on what the key was
# pressed to stop (an `s` typed on another layout, a demo sent back as
# rework:). Every unit offered gets its key recorded with what came of it, so
# that nothing offered once disappears from the plan.
_aif_start_offer() {
  local root="$1" u="$2" kind key text dflt warn verb own deadline left act="" shown
  kind="$(printf '%s' "$u" | jq -r '.kind')"
  key="$(printf '%s' "$u" | jq -r '.key')"
  text="$(printf '%s' "$u" | jq -r '.text')"
  dflt="$(printf '%s' "$u" | jq -r '.default // "open"')"
  warn="$(printf '%s' "$u" | jq -r '.warn // empty')"
  case "$kind" in
    session) verb=open ;;
    land) verb=land ;;
    build) verb=build ;;
    requeue) verb=requeue ;;
    demo) verb=rework ;;
    pull) verb=pull ;;
    answered) verb="back to Ready" ;;
    *) verb=go ;;
  esac
  own="$(printf '%s' "$u" | jq -r '(.keys // {}) | to_entries | map(" · \(.key): \(.value)") | join("")')"
  [ -z "$warn" ] || _aif_start_say "warn" "$warn"
  deadline=$((SECONDS + AIF_START_WAIT_S))
  while [ -z "$act" ]; do
    left="$AIF_START_WAIT_S"
    if [ -z "${AIF_START_KEYS+x}" ]; then
      left=$((deadline - SECONDS))
      [ "$left" -gt 0 ] || left=0
    fi
    if [ "$left" -le 0 ]; then
      AIF_START_KEY=none
    else
      _aif_start_key "$left" "next: $text — Enter: $verb$own · s: skip · p: pause · q: end the shift$(_aif_start_b_hint) (" ")"
    fi
    case "$AIF_START_KEY" in
      enter) act=run ;;
      none)
        if [ -n "$warn" ]; then
          act=warn
        else
          case "$dflt" in
            skip) act=missed ;;
            *) act=run ;;
          esac
        fi
        ;;
      s) act=skip ;;
      p) act=pause ;;
      q) _aif_start_finish 0 "ended at the control point (q)" ;;
      gone) _aif_start_gone ;;
      b) if _aif_start_b_ok; then act=build; else act=unknown; fi ;;
      *)
        act="$(printf '%s' "$u" | jq -r --arg k "$AIF_START_KEY" '(.keys // {})[$k] // empty' 2>/dev/null)" || act=""
        [ -n "$act" ] || act=unknown
        ;;
    esac
  done
  case "$act" in
    pause)
      _aif_start_pause "at the control point, before: $text"
      ;;
    unknown)
      # Named only when it is a plain letter or digit: an arrow key is
      # three bytes, an Escape first, and a layout's letter is `?`.
      case "$AIF_START_KEY" in
        [a-zA-Z0-9]) shown="$AIF_START_KEY" ;;
        *) shown="that key" ;;
      esac
      _aif_start_pause "$shown is none of this unit's keys (Enter: $verb$own · s: skip · p: pause · q: end the shift) — nothing done; before: $text"
      ;;
    warn)
      _aif_start_pause "$warn"
      ;;
    skip)
      _aif_start_done "$key" "skipped at the control point"
      _aif_start_record "$u" "skipped"
      ;;
    missed)
      _aif_start_done "$key" "offered, not taken (no key)"
      _aif_start_record "$u" "offered, not taken (no key)"
      ;;
    build)
      _aif_start_build_now "$root"
      ;;
    land)
      _aif_start_run_land "$root" "$u"
      ;;
    *)
      case "$kind" in
        session) _aif_start_run_session "$root" "$u" ;;
        land) _aif_start_run_land "$root" "$u" ;;
        build) _aif_start_run_build "$root" "$u" ;;
        requeue) _aif_start_run_requeue "$root" "$u" ;;
        demo | pull | answered) _aif_start_run_send "$root" "$u" ;;
        *)
          _aif_start_done "$key" "a unit the shift does not know how to run ($kind)"
          _aif_start_record "$u" "not run — unknown kind $kind"
          ;;
      esac
      ;;
  esac
  return 0
}

# _aif_start_run_session <root> <unit> — one interactive session, in the
# foreground (lib/runner_claude.sh aif_runner_claude_session), and what came
# of it (R23, as the probes corrected it, #28): a signal (rc > 128) — the
# terminal put back, a pause; claude failing (1..128) — the end, exit 1, for
# a session that fails is not followed by another; rc 0 with nothing changed
# — a pause, or an absent person, a double Ctrl-C or a usage limit would
# chain empty sessions; rc 0 with something changed — the next tick. A closed
# window is rc 0 as well: the HUP trap, run by bash once claude returns and
# before the next line, ends the shift with 129 first.
_aif_start_run_session() {
  local root="$1" u="$2" role prompt name id file model sid rc=0 b a changed=1 col0 col1 what rec key dir="$AIF_START_SHIFT_DIR"
  role="$(printf '%s' "$u" | jq -r '.role // empty')"
  prompt="$(printf '%s' "$u" | jq -r '.prompt')"
  name="$(printf '%s' "$u" | jq -r '.name')"
  id="$(printf '%s' "$u" | jq -r '.ticket // empty')"
  file="$(printf '%s' "$u" | jq -r '.file // empty')"
  key="$(printf '%s' "$u" | jq -r '.key')"
  model="$(_aif_start_model "$role")"
  if ! sid="$(_aif_start_uuid)"; then
    _aif_start_finish 3 "no uuidgen on this machine — a session needs a fresh id of its own"
  fi
  b="$dir/snapshot-before"
  a="$dir/snapshot-after"
  _aif_start_snapshot "$root" "$id" "$b"
  if [ -z "${AIF_START_SESSION_CMD:-}" ] && ! _aif_start_tty_ok; then
    _aif_start_gone
  fi
  _aif_start_say "open" "$name — model ${model:-default} · afterwards: ${CLAUDE_CONFIG_DIR:+CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR }claude --resume $sid"
  # The session, as the summary should name it should the shift end before
  # its record below: a closed window runs the HUP trap the moment the
  # session returns, before the next line, and a Ctrl-C can land in the
  # after-snapshot's seconds of board reads — either way the summary had no
  # unit and no `claude --resume <uuid>` for a session the person was just
  # in, and listed the unit as untouched, with a fresh session as its command.
  AIF_START_OPEN="$(_aif_start_record_json "$u" "open when the shift ended" "" "" "$model" "$sid" "")" || AIF_START_OPEN=""
  _aif_start_watch_on
  aif_runner_claude_session "$root" "$prompt" "$model" "$name" "$sid" || rc=$?
  _aif_start_watch_off
  _aif_start_snapshot "$root" "$id" "$a"
  if cmp -s "$b" "$a"; then changed=0; fi
  col0="$(sed -n 1p "$b" 2>/dev/null)"
  col1="$(sed -n 1p "$a" 2>/dev/null)"
  # The summary prints a card's column before → after beside its unit; the
  # note the plan lists it under says it in words.
  if [ "$changed" -eq 0 ]; then
    what="changed nothing"
    rec="$name — rc $rc, changed nothing"
  elif [ -n "$id" ] && [ "$col0" != "$col1" ]; then
    what="$col0 → $col1"
    rec="$name — rc $rc"
  else
    what="changed the board or the repository"
    rec="$name — rc $rc, $what"
  fi
  _aif_start_done "$key" "$name — rc $rc, $what"
  _aif_start_record "$u" "$rec" "$rc" "$([ -z "$id" ] || printf '%s' "$col1")" "$model" "$sid" "$changed"
  AIF_START_OPEN=""
  # The terminal first, before anything that may end the shift: --max-units
  # reached by this very session finishes inside _aif_start_acted, and the
  # EXIT trap's restore, which knows no rc, would leave a kill -9's alternate
  # screen and mouse reporting on under the person's prompt (#28).
  [ "$rc" -le 128 ] || _aif_start_tty_restore "$rc"
  _aif_start_say "closed" "$name — rc $rc, $what${file:+ ($file)}"
  if [ "$rc" -ge 1 ] && [ "$rc" -le 128 ]; then
    _aif_start_finish 1 "claude exited $rc — a session that fails is not followed by another (claude --resume $sid to look)"
  fi
  _aif_start_acted
  if [ "$rc" -gt 128 ]; then
    _aif_start_pause "the session ended by a signal ($rc)"
  elif [ "$changed" -eq 0 ]; then
    _aif_start_pause "the session changed nothing — on its card, the board's cards, requests/ or tasks/"
  fi
  return 0
}

# _aif_start_run_land <root> <unit> — `aif land <ID>` in the foreground, with
# its own lines and its own traps (R6, or `l` over a demo). What came of it
# is read off the board on the next tick; a land stopped by a signal pauses
# the shift, as a stopped build does — a person who pressed Ctrl-C may have
# meant everything (critics operations-17).
_aif_start_run_land() {
  local root="$1" u="$2" id key rc=0 col
  id="$(printf '%s' "$u" | jq -r '.ticket')"
  key="$(printf '%s' "$u" | jq -r '.key')"
  _aif_start_say "land" "aif land $id"
  _aif_start_watch_on
  set -m
  "$AIF_ROOT/bin/aif" land "$id" || rc=$?
  set +m
  _aif_start_watch_off
  # Before _aif_start_acted, which may end the shift (_aif_start_run_session).
  [ "$rc" -le 128 ] || _aif_start_tty_restore "$rc"
  col="$(_aif_start_column "$root" "$id")"
  _aif_start_done "$key" "aif land — rc $rc, the card in $col"
  _aif_start_record "$u" "aif land — rc $rc" "$rc" "$col"
  _aif_start_acted
  if [ "$rc" -gt 128 ]; then
    _aif_start_pause "the land was stopped ($rc)"
  fi
  return 0
}

# _aif_start_run_send <root> <unit> — a comment and a move the oracle wrote
# for the unit: a demo's rework back to Backlog (R5d), a pull to the bottom
# of Ready (R14), a card a person answered back to Ready (R18a).
_aif_start_run_send() {
  local root="$1" u="$2" id key to comment col
  id="$(printf '%s' "$u" | jq -r '.ticket')"
  key="$(printf '%s' "$u" | jq -r '.key')"
  to="$(printf '%s' "$u" | jq -r '.to')"
  comment="$(printf '%s' "$u" | jq -r '.comment // empty')"
  if _aif_start_comment_move "$root" "$id" "$comment" "$to"; then
    _aif_start_out "moved $id → $to — $(printf '%s' "$u" | jq -r '.text')"
    _aif_start_done "$key" "sent to $to at the control point"
    _aif_start_record "$u" "sent to $to" "" "$to"
  else
    col="$(_aif_start_column "$root" "$id")"
    _aif_start_done "$key" "the shift tried to move it to $to and the board did not take it${AIF_START_BYHAND:+ — by hand: $AIF_START_BYHAND}"
    _aif_start_record "$u" "not moved — the board did not take it" "" "$col"
    AIF_START_FAILED_MOVE=1
  fi
  _aif_start_acted
  return 0
}

# _aif_start_run_requeue <root> <unit> — R3b: a card whose worker died
# outright goes back to the top of Ready, where a loop resumes it — but only
# once nothing it left is still writing in its worktree: the next worker
# would take the lock over and dispatch into a tree a station is still
# editing (docs/DEFECTS.md 14.1). Each process the dead worker left is sent a
# TERM — to its whole group when that group is the dead worker's own (its id
# the lock's pid, and that pid gone), else to the process alone, never a
# group some other program leads (critics operations-3) — and given 30
# seconds to go.
_aif_start_run_requeue() {
  local root="$1" u="$2" id key rows pid pgid grp alive t0 col
  id="$(printf '%s' "$u" | jq -r '.ticket')"
  key="$(printf '%s' "$u" | jq -r '.key')"
  rows="$(printf '%s' "$u" | jq -r '(.kill // [])[] | "\(.pid) \(.pgid) \(.group)"')"
  if [ -n "$rows" ]; then
    while read -r pid pgid grp; do
      [ -n "$pid" ] || continue
      if [ "$grp" = true ]; then
        kill -TERM -- "-$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      else
        kill -TERM "$pid" 2>/dev/null || true
      fi
    done <<EOF
$rows
EOF
    t0=$SECONDS
    while :; do
      alive=""
      for pid in $(printf '%s\n' "$rows" | awk '{ print $1 }'); do
        if _aif_work_pid_alive "$pid"; then alive="${alive:+$alive }$pid"; fi
      done
      [ -n "$alive" ] || break
      [ $((SECONDS - t0)) -lt 30 ] || break
      sleep 1
    done
    if [ -n "$alive" ]; then
      _aif_start_say "requeue" "$id — a station still runs in its worktree (pid $alive) — not requeued; aif work --status $id says what it is"
      _aif_start_done "$key" "a station still runs in its worktree (pid $alive) — not requeued"
      _aif_start_record "$u" "not requeued — a station still runs (pid $alive)" "" "in_progress"
      _aif_start_acted
      return 0
    fi
  fi
  if _aif_start_comment_move "$root" "$id" "$(printf '%s' "$u" | jq -r '.comment // empty')" ready top; then
    _aif_start_out "moved $id → ready (top) — $(printf '%s' "$u" | jq -r '.text')"
    _aif_start_done "$key" "requeued to the top of Ready"
    _aif_start_record "$u" "requeued to the top of Ready" "" ready
  else
    col="$(_aif_start_column "$root" "$id")"
    _aif_start_done "$key" "the shift tried to requeue it and the board did not take it${AIF_START_BYHAND:+ — by hand: $AIF_START_BYHAND}"
    _aif_start_record "$u" "not requeued — the board did not take it" "" "$col"
    AIF_START_FAILED_MOVE=1
  fi
  _aif_start_acted
  return 0
}

# _aif_start_run_build <root> <unit> — R12: the loop in this terminal, in the
# foreground with its own dashboard, its logs and summary.json in the shift's
# directory (AIF_WORK_LOOP_LOGDIR). Then R13, from that summary.json and never
# from the exit code alone (docs/DEFECTS.md 14.3).
#
# No summary.json is a loop that never started: refused because a loop
# already runs on this checkout (the next tick sees it, `elsewhere`), or dead
# in its preflight — the build is held. A loop that ended on two runs in a
# row that did not build, on a stop or a drain from another terminal, or with
# 1 or 143, holds the build too: research R13, hold, not restart — no R12
# until `b`. 3 is the environment, already checked again by the loop's own
# preflight: the shift ends 3. 130 is the person's Ctrl-C: a pause. 129, the
# terminal: the shift's own HUP trap has run by now, or the terminal is
# checked here.
_aif_start_run_build() {
  local root="$1" u="$2" key par logdir rc=0 why="" pf taken built hold="" note tail
  key="$(printf '%s' "$u" | jq -r '.key')"
  par="$(jq -r '.build.parallel // 2' "$AIF_START_FACTS" 2>/dev/null)" || par=2
  case "$par" in
    '' | *[!0-9]* | 0*) par=2 ;;
  esac
  AIF_START_LOOPS=$((AIF_START_LOOPS + 1))
  logdir="$AIF_START_SHIFT_DIR/loop-$AIF_START_LOOPS"
  pf=()
  [ -z "${AIF_START_PROFILE_ARG:-}" ] || pf=(--profile "$AIF_START_PROFILE_ARG")
  _aif_start_say "build" "aif work --loop --parallel $par — in this terminal; its logs in ${logdir#"$(aif_main_root "$root")"/}"
  _aif_start_watch_on
  set -m
  AIF_WORK_LOOP_LOGDIR="$logdir" "$AIF_ROOT/bin/aif" work --loop --parallel "$par" ${pf[@]+"${pf[@]}"} || rc=$?
  set +m
  _aif_start_watch_off
  # A loop killed -9 never ran its own trap: its dashboard's alternate screen
  # and hidden cursor, and its key read's -icanon -echo, stay for the rest of
  # the shift. The 137 reset covers both (\e[?25h\e[?1049l, the saved stty).
  [ "$rc" -le 128 ] || _aif_start_tty_restore "$rc"
  if [ ! -f "$logdir/summary.json" ]; then
    if [ "$rc" -eq 3 ] && [ -d "$(aif_loop_lock_dir "$root")" ] &&
      _aif_work_lock_live_as "$(aif_loop_lock_dir "$root")" '*aif\ work*--loop*'; then
      note="a loop already runs on this checkout — the shift waits for it"
    elif [ "$rc" -eq 130 ]; then
      note="the loop was stopped before it started (130)"
    else
      note="the loop did not start (rc $rc)"
      if [ -f "$logdir/loop.log" ]; then
        tail="$(tail -n 5 "$logdir/loop.log" 2>/dev/null)" || tail=""
        [ -z "$tail" ] || _aif_start_out "$tail"
      fi
      hold="$note"
    fi
  else
    why="$(jq -r '.why // empty' "$logdir/summary.json" 2>/dev/null)" || why=""
    taken="$(jq -r '.taken // 0' "$logdir/summary.json" 2>/dev/null)" || taken=0
    built="$(jq -r '.built // 0' "$logdir/summary.json" 2>/dev/null)" || built=0
    note="the loop ended rc $rc — taken $taken, built $built${why:+; $why}"
    case "$why" in
      "two runs in a row"* | "stopped by"* | "drained by"*) hold="$why" ;;
    esac
    if [ -z "$hold" ] && { [ "$rc" -eq 1 ] || [ "$rc" -eq 143 ]; }; then
      hold="${why:-the loop ended rc $rc}"
    fi
  fi
  _aif_start_done "$key" "$note"
  _aif_start_record "$u" "$note" "$rc"
  _aif_start_say "build" "$note"
  if [ "$rc" -eq 3 ] && [ -f "$logdir/summary.json" ]; then
    _aif_start_finish 3 "the build ended 3 — the environment${why:+: $why}"
  fi
  if [ -n "$hold" ]; then
    AIF_START_BUILD_HOLD="$hold"
    _aif_start_say "build" "held — no new build until b at the control point"
  fi
  _aif_start_acted
  case "$rc" in
    130) _aif_start_pause "the loop was stopped (130)" ;;
    129)
      _aif_start_tty_ok || _aif_start_gone
      _aif_start_pause "the loop ended by a hang-up (129)"
      ;;
  esac
  return 0
}

# _aif_start_build_now <root> — `b`: the build held by R13 is let go, and the
# loop runs now on what Ready holds.
_aif_start_build_now() {
  local root="$1" ids keys u
  AIF_START_BUILD_HOLD=""
  ids="$(jq -r '[ .cards[] | select(.column == "ready") | .ticket ] | sort | join(" ")' "$AIF_START_FACTS" 2>/dev/null)" || ids=""
  if [ -z "$ids" ]; then
    _aif_start_say "build" "the hold is let go; Ready is empty — the next card there is built"
    return 0
  fi
  # The oracle's R12 key exactly (lib/start.jq: each card's id and when it
  # came into Ready), so the build `b` ran is not offered again for the same
  # Ready.
  keys="$(jq -r '[ .cards[] | select(.column == "ready")
    | "\(.ticket)@\(.moved_at | if . == null or . == "" then "-" else tostring end)" ] | sort | join(" ")' \
    "$AIF_START_FACTS" 2>/dev/null)" || keys="$ids"
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  u="$(jq -nc --arg ids "$ids" --arg keys "$keys" '{ rule: "R12", key: ("R12 " + $keys), kind: "build", ticket: null, file: null,
    column: "ready", role: null, name: null, text: ("build — Ready holds " + $ids + " (b)") }')"
  _aif_start_run_build "$root" "$u"
}

# ----------------------------------------------------------- what is shown

# _aif_start_plan_text <plan> <dry 0|1> — the plan as the person reads it:
# the board in one line of counts, the units in order, the lines the shift
# will not touch with the command that would; a dry run adds the moves it
# would make and the wait or the end.
_aif_start_plan_text() {
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  jq -r --arg q "'" --argjson dry "$2" '
    def pad($s): ($s + "            ")[0:11];
    def cfmt: "backlog \(.backlog) · ready \(.ready) · in progress \(.in_progress) · review \(.review) · needs human \(.needs_human) · done \(.done)";
    def lab: if .ticket != null then .ticket + (if .column != null then " " + .column else "" end)
             elif .file != null then .file elif .column != null then .column else .rule end;
    def lfmt: lab + " · " + .text + (if .command != null then " · yours: " + .command else "" end);
    (pad("board") + (.counts | cfmt)),
    (if $dry == 1 then (.moves | to_entries[] | (if .key == 0 then pad("would move") else pad("") end)
       + (.value | "\(.ticket // "the sweep") → \(.to) — \(.text) (\(.rule))")) else empty end),
    (.units | to_entries[] | (if .key == 0 then pad("units") else pad("") end) + "\(.key + 1) \(.value.text)"),
    (.lines | to_entries[] | (if .key == 0 then pad("left") else pad("") end) + (.value | lfmt)),
    (if $dry == 1 and .wait != null then pad("wait") + .wait.why else empty end),
    (if $dry == 1 and ."end" != null then pad("end") + ."end".why + " (exit \(."end".rc))" else empty end)' "$1"
}

# _aif_start_print_plan <plan> — the plan, when it changed since it was last
# shown.
_aif_start_print_plan() {
  local digest text
  digest="$(jq -c '{ counts, units: [ .units[] | [ .key, .text ] ],
    lines: [ .lines[] | [ .ticket, .file, .text, .command ] ] }' "$1" 2>/dev/null)" || digest=""
  [ "$digest" != "${AIF_START_DIGEST:-}" ] || return 0
  AIF_START_DIGEST="$digest"
  text="$(_aif_start_plan_text "$1" 0 2>/dev/null)" || return 0
  _aif_start_out "$text"
}

# _aif_start_header <facts> — the shift in one line: where, which board and
# profile, how many at once, each role's model, who builds.
_aif_start_header() {
  local f="$1" kind par mode pid idle build
  kind="$(jq -r '.board_kind // "local"' "$f")"
  par="$(jq -r '.build.parallel // 2' "$f")"
  mode="$(jq -r '.build.mode // "here"' "$f")"
  pid="$(jq -r '.build.loop.pid // "?"' "$f")"
  idle="$(jq -r 'if .build.loop.idle == true then ", idle" else "" end' "$f")"
  case "$mode" in
    elsewhere) build="the loop in another terminal (pid $pid$idle)" ;;
    none) build="no loop — aif work --loop --idle in another terminal" ;;
    *) build="here — the loop runs in this terminal when Ready holds cards" ;;
  esac
  printf 'shift · %s · %s · profile %s · parallel %s · models: review %s · ba %s · po %s · pjm %s · build: %s' \
    "$(basename "$AIF_START_ROOT")" "$kind" "$AIF_START_PROFILE" "$par" \
    "${AIF_START_MODEL_REVIEW:-default}" "${AIF_START_MODEL_BA:-default}" \
    "${AIF_START_MODEL_PO:-default}" "${AIF_START_MODEL_PJM:-default}" "$build"
}

# _aif_start_summary <rc> <why> — the end (research §6.7): what was done, unit
# by unit; the board's counts before and after; what is left, with the
# command for each — every unit offered and not taken among it; and how to
# get back into every session, by its uuid, never its name, which stops
# resolving once two sessions share it (#28). On stderr, and as
# <shiftdir>/summary.json. Once.
_aif_start_summary() {
  local rc="$1" why="$2" dir="${AIF_START_SHIFT_DIR:-}" p b json text mins
  [ "${AIF_START_ENDED:-0}" = 0 ] || return 0
  AIF_START_ENDED=1
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  # Whatever a print to a terminal that is gone left in the buffer, out of
  # the way of the captures below (_aif_start_flush).
  _aif_start_flush
  p="$(jq -c '.' "$dir/plan.json" 2>/dev/null)" || p=""
  [ -n "$p" ] || p='{}'
  b="$(jq -c '.build // {}' "$dir/facts.json" 2>/dev/null)" || b=""
  [ -n "$b" ] || b='{}'
  mins=$((($(date +%s) - ${AIF_START_T0:-$(date +%s)}) / 60))
  # A session open when the shift ended (AIF_START_OPEN, _aif_start_run_session)
  # is one of its units, done: its record, and its `claude --resume <uuid>`.
  # A loop in another terminal is not the shift's to end: it runs on, and the
  # summary says so with the command that ends it (docs/DEFECTS.md 11.1).
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  json="$(jq -n --argjson rc "$rc" --arg why "$why" --argjson hup "${AIF_START_HUP:-0}" \
    --arg started "${AIF_START_STARTED_AT:-}" --arg ended "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson minutes "$mins" --argjson before "${AIF_START_COUNTS0:-null}" --argjson p "$p" --argjson b "$b" \
    --arg units "${AIF_START_UNITS:-}" --arg open "${AIF_START_OPEN:-}" \
    --arg moves "${AIF_START_MOVES:-}" --arg donekeys "${AIF_START_DONE:-}" \
    --arg cfg "${CLAUDE_CONFIG_DIR:-}" --arg q "'" '
    def ucmd: if .kind == "session" then "claude \($q)\(.prompt)\($q)"
              elif .kind == "land" then "aif land \(.ticket)"
              elif .kind == "demo" then "claude \($q)/aif-pjm \(.ticket)\($q)"
              elif .kind == "build" then "aif work --loop"
              elif .kind == "requeue" then "aif work --status \(.ticket)"
              elif .ticket != null and .to != null then "aif board move \(.ticket) \(.to)"
              else null end;
    (($units + "\n" + $open) | split("\n") | map(select(length > 0) | fromjson)) as $u
    | ([ $donekeys | split("\n")[] | select(length > 0) | split("\t")[0] ]
       + [ $open | select(length > 0) | fromjson | .key ]) as $dk
    | def fresh: .key as $k | all($dk[]; . != $k);
      { rc: $rc, why: $why, hup: ($hup == 1), started_at: $started, ended_at: $ended, minutes: $minutes,
        counts_before: $before, counts_after: ($p.counts // null),
        units: $u,
        moves: ($moves | split("\n") | map(select(length > 0))),
        left: ([ ($p.lines // [])[] | { rule, ticket, file, column, text, command } ]
               + [ ($p.moves // [])[] | select(fresh)
                   | { rule, ticket, file, column, text,
                       command: (if .kind == "sweep" then "aif board release"
                                 elif .kind == "rework" or .kind == "cancel" then "claude \($q)/aif-pjm \(.ticket)\($q)"
                                 elif .comment == null and .where == null then "aif board move \(.ticket) \(.to)"
                                 else "aif start" end) } ]
               + [ ($p.units // [])[] | select(fresh) | { rule, ticket, file, column, text, command: ucmd } ]
               + (if $b.mode == "elsewhere" and $b.loop.live == true
                  then [ { rule: "R12", ticket: null, file: null, column: null,
                           text: ("the loop in another terminal" + (if $b.loop.pid == null then "" else " (pid \($b.loop.pid))" end)
                                  + " runs on after the shift"),
                           command: "aif work --loop --drain" } ]
                  else [] end)),
        sessions: [ $u[] | select(.session_id != null)
                    | { name, session_id,
                        resume: ((if $cfg == "" then "" else "CLAUDE_CONFIG_DIR=\($cfg) " end) + "claude --resume \(.session_id)") } ],
        next: (if $why == "nothing left for the shift" then "/aif-po — bring a need" else null end) }')" || json=""
  [ -n "$json" ] || return 0
  { printf '%s\n' "$json" >"$dir/summary.json.tmp" && mv "$dir/summary.json.tmp" "$dir/summary.json"; } 2>/dev/null || true
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  text="$(printf '%s' "$json" | jq -r '
    def pad($s): ($s + "            ")[0:11];
    def cfmt: "backlog \(.backlog) · ready \(.ready) · in progress \(.in_progress) · review \(.review) · needs human \(.needs_human) · done \(.done)";
    def lab: if .ticket != null then .ticket + (if .column != null then " " + .column else "" end)
             elif .file != null then .file elif .column != null then .column else .rule end;
    "",
    "shift ended — \(.why) · exit \(.rc) · \(.minutes) min",
    (.units | to_entries[] | (if .key == 0 then pad("done") else pad("") end)
       + (.value | "\(.rule) \(.ticket // .file // .kind) — \(.what)"
          + (if .after != null and .before != null and .after != .before then " · \(.before) → \(.after)" else "" end))),
    (.moves | to_entries[] | (if .key == 0 then pad("moved") else pad("") end) + .value),
    (if .counts_before != null and .counts_after != null
     then pad("board") + (.counts_before | cfmt) + "\n" + pad("") + "→ " + (.counts_after | cfmt) else empty end),
    (.left | to_entries[] | (if .key == 0 then pad("left") else pad("") end)
       + (.value | lab + " · " + .text + (if .command != null then " · yours: " + .command else "" end))),
    (.sessions | to_entries[] | (if .key == 0 then pad("sessions") else pad("") end) + "\(.value.resume)   (\(.value.name))"),
    (if .next != null then pad("next") + .next else empty end)' 2>/dev/null)" || text=""
  _aif_start_out "$text"
}

# _aif_start_refresh — one more look before an end the shift chose itself
# (--max-units), so that what the summary says is left is what is left now,
# not what was left before the last unit. A board that does not answer
# leaves the last plan as it was.
_aif_start_refresh() {
  local dir="$AIF_START_SHIFT_DIR"
  if (_aif_start_facts "$AIF_START_ROOT" >"$dir/facts.json.tmp" 2>/dev/null) &&
    (_aif_start_oracle "$dir/facts.json.tmp" >"$dir/plan.json.tmp" 2>/dev/null); then
    mv "$dir/facts.json.tmp" "$dir/facts.json"
    mv "$dir/plan.json.tmp" "$dir/plan.json"
  else
    rm -f "$dir/facts.json.tmp" "$dir/plan.json.tmp"
  fi
  return 0
}

# _aif_start_finish <rc> <why> — the end the shift chose: the summary, the
# lock, the exit (the EXIT trap then finds both done).
_aif_start_finish() {
  _aif_start_summary "$1" "$2"
  _aif_start_unlock || true
  exit "$1"
}

# _aif_start_signal <EXIT|INT|TERM|HUP> — the shift's handler, armed once the
# start has passed (_aif_start_early before it).
#
# INT and TERM arrive between units — inside a session, a land or the loop
# the child has the terminal, and the person's Ctrl-C is the child's. The
# terminal first: a trap that exits in the middle of the control point's read
# leaves it -icanon -echo (#28). Then the summary, the lock, 130 or 143. HUP:
# the terminal is gone, so the summary goes to shift.log as the loop does it
# (lib/cmd_work.sh), and summary.json says hup; bash runs it once a
# foreground session returns, before the next line, so no next unit is
# opened. EXIT: the job control off, the terminal back, the lock released,
# and summary.json written if nothing wrote it — the shift failing on an
# error of its own. Every write here is `|| true`: errexit holds inside a
# trap, and a failed write would turn the promised code into 1.
_aif_start_signal() {
  local rc_in=$? sig="${1:-EXIT}"
  _aif_start_watch_off || true
  case "$sig" in
    INT | TERM)
      set +m
      _aif_start_tty_restore
      printf '\n' >&2 2>/dev/null || _aif_start_flush
      if [ "$sig" = INT ]; then
        _aif_start_summary 130 "stopped by Ctrl-C" || true
        _aif_start_unlock || true
        exit 130
      fi
      _aif_start_summary 143 "stopped by a TERM signal" || true
      _aif_start_unlock || true
      exit 143
      ;;
    HUP)
      set +m
      exec >>"${AIF_START_SHIFT_DIR:-/dev/null}/shift.log" 2>&1 || exec >/dev/null 2>&1
      # What the prints to the dead terminal left in the buffer — the
      # countdown's redraws, a `closed` line — thrown away, not into the
      # plan the summary captures, nor into the log, which has them already
      # (_aif_start_flush). The way here that needs it is the one with no
      # hang-up: _aif_start_gone, after prints that failed.
      _aif_start_flush
      AIF_START_NOLOG=1
      AIF_START_HUP=1
      _aif_start_summary 129 "the terminal closed (HUP)" || true
      _aif_start_unlock || true
      exit 129
      ;;
    EXIT)
      set +m
      _aif_start_tty_restore
      _aif_start_flush
      _aif_start_unlock || true
      if [ -n "${AIF_START_SHIFT_DIR:-}" ] && [ -d "$AIF_START_SHIFT_DIR" ] &&
        [ ! -f "$AIF_START_SHIFT_DIR/summary.json" ]; then
        _aif_start_summary "$rc_in" "the shift ended on an error before it could say why — shift.log says where" || true
      fi
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------- the tick

# _aif_start_shift <root> — tick after tick until the plan, a key or a signal
# ends it: the facts, the plan; the moves, if any, and look again; else the
# end, if the plan says so; else the first unit at the control point; else
# the wait.
_aif_start_shift() {
  local root="$1" dir="$AIF_START_SHIFT_DIR" rc first=1 why
  AIF_START_FACTS="$dir/facts.json"
  while :; do
    if [ "${AIF_START_FAILED_MOVE:-0}" = 1 ]; then
      AIF_START_FAILED_MOVE=0
      _aif_start_wait "a move did not go through — the board is looked at again"
    fi
    rc=0
    _aif_start_facts "$root" >"$dir/facts.json.tmp" || rc=$?
    case "$rc" in
      0) mv "$dir/facts.json.tmp" "$dir/facts.json" ;;
      3) _aif_start_finish 3 "the board did not answer twice" ;;
      *) _aif_start_finish 1 "the shift's facts could not be read (rc $rc) — the lines above say why" ;;
    esac
    # In a subshell: a trap that ran inside this call would print with its
    # stderr on oracle.err (_aif_start_key says why).
    rc=0
    (_aif_start_oracle "$dir/facts.json" >"$dir/plan.json.tmp" 2>"$dir/oracle.err") || rc=$?
    if [ "$rc" -ne 0 ]; then
      why="$(sed -n 1p "$dir/oracle.err" 2>/dev/null)"
      _aif_start_finish 1 "the plan could not be made (jq: ${why:-rc $rc})"
    fi
    mv "$dir/plan.json.tmp" "$dir/plan.json"
    if [ "$first" -eq 1 ]; then
      first=0
      _aif_start_out "$(_aif_start_header "$dir/facts.json")"
      AIF_START_COUNTS0="$(jq -c '.counts' "$dir/plan.json")"
    fi
    if [ "$(jq '.moves | length' "$dir/plan.json")" -gt 0 ]; then
      _aif_start_moves "$root" "$dir/plan.json"
      continue
    fi
    if jq -e '."end" != null' "$dir/plan.json" >/dev/null 2>&1; then
      _aif_start_print_plan "$dir/plan.json"
      _aif_start_finish "$(jq -r '."end".rc // 0' "$dir/plan.json")" "$(jq -r '."end".why // "the end"' "$dir/plan.json")"
    fi
    _aif_start_print_plan "$dir/plan.json"
    if [ "$(jq '.units | length' "$dir/plan.json")" -gt 0 ]; then
      _aif_start_offer "$root" "$(jq -c '.units[0]' "$dir/plan.json")"
      continue
    fi
    if jq -e '.wait != null' "$dir/plan.json" >/dev/null 2>&1; then
      _aif_start_wait "$(jq -r '.wait.why' "$dir/plan.json")"
      continue
    fi
    _aif_start_finish 0 "nothing left for the shift"
  done
}

# _aif_start_dry_run <root> — one tick of facts and plan, printed; nothing
# posted, moved, opened or locked, no shift directory and so no head cache
# (research §7 #10: how a shift is first tried on a real board).
_aif_start_dry_run() {
  local root="$1" tmp rc=0 lock
  lock="$(aif_shift_lock_dir "$root")"
  if [ -d "$lock" ] && _aif_work_lock_live_as "$lock" '*aif\ start*'; then
    printf 'a shift is open on this checkout (%s) — what it does next may already be under way\n' "$(_aif_start_lock_held "$lock")"
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/aif-start-facts-XXXXXX")"
  _aif_start_facts "$root" >"$tmp" || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    exit "$rc"
  fi
  printf '%s\n' "$(_aif_start_header "$tmp" | sed 's/^shift · /shift (dry run) · /')"
  rc=0
  _aif_start_oracle "$tmp" >"$tmp.plan" || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp" "$tmp.plan"
    aif_err "the plan could not be made (jq rc $rc)"
    exit 1
  fi
  _aif_start_plan_text "$tmp.plan" 1
  rm -f "$tmp" "$tmp.plan"
  printf 'a dry run — nothing was posted, moved, opened or locked\n'
  exit 0
}

# ---------------------------------------------------------------- the start

# _aif_start_pick_model <role> <role-flag> <model-flag> <file> <built-in> —
# one role's model and where it came from (for the refusal that names it), as
# "<model>\t<source>": the role's own flag, --model, MODEL_<ROLE> in the
# file, MODEL there, the built-in.
_aif_start_pick_model() {
  local role="$1" own="$2" all="$3" file="$4" builtin="$5" up v
  up="$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]')"
  if [ -n "$own" ]; then
    printf '%s\t--model-%s %s' "$own" "$role" "$own"
    return 0
  fi
  if [ -n "$all" ]; then
    printf '%s\t--model %s' "$all" "$all"
    return 0
  fi
  v="$(aif_meta_get "$file" "MODEL_$up" "" | tr -d '[:space:]')"
  if [ -n "$v" ]; then
    printf '%s\tMODEL_%s=%s in %s' "$v" "$up" "$v" "$AIF_START_STATE"
    return 0
  fi
  v="$(aif_meta_get "$file" MODEL "" | tr -d '[:space:]')"
  if [ -n "$v" ]; then
    printf '%s\tMODEL=%s in %s' "$v" "$v" "$AIF_START_STATE"
    return 0
  fi
  printf '%s\tthe built-in %s for %s' "$builtin" "$builtin" "$role"
}

# _aif_start_number <value> <default> — a whole number above 0, else the
# default: what .aif/start.local and the seams say about seconds.
_aif_start_number() {
  case "$1" in
    '' | *[!0-9]* | 0*) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}

# aif_cmd_start [options] — the shift.
#
# The start, in an order the exit codes depend on: everything that can refuse
# does so before anything exists to clean up, and a refusal leaves no shift
# directory. Free checks first (a nested Claude Code session, a terminal, the
# main checkout), then the lock — with a handler that releases it from there
# on — then the profile, its models, the board, and the one billed probe;
# only then the shift's directory, the saved terminal, and the shift's own
# handler.
aif_cmd_start() {
  local no_build=0 parallel="" model="" m_review="" m_ba="" m_po="" m_pjm="" profile="" profile_arg
  local retry_runs=0 po=0 pjm=1 max_units=0 dry=0 root main shiftdir cfg role pick mdl src mapped err out

  while [ $# -gt 0 ]; do
    case "$1" in
      --no-build) no_build=1 ;;
      --parallel)
        shift
        parallel="${1:-}"
        case "$parallel" in
          '' | *[!0-9]* | 0*) aif_die "--parallel takes a positive whole number — how many the loop here builds at once" ;;
        esac
        ;;
      --model | --model-review | --model-ba | --model-po | --model-pjm)
        [ $# -ge 2 ] && [ -n "$2" ] || aif_die "$1 takes a model: an alias the profile maps (opus, sonnet, haiku) or a full model id"
        case "$1" in
          --model) model="$2" ;;
          --model-review) m_review="$2" ;;
          --model-ba) m_ba="$2" ;;
          --model-po) m_po="$2" ;;
          --model-pjm) m_pjm="$2" ;;
        esac
        shift
        ;;
      --profile)
        shift
        profile="${1:-}"
        [ -n "$profile" ] || aif_die "--profile takes a profile name (aif profiles lists them)"
        ;;
      --retry-runs) retry_runs=1 ;;
      --po) po=1 ;;
      --no-pjm) pjm=0 ;;
      --max-units)
        shift
        max_units="${1:-}"
        case "$max_units" in
          '' | *[!0-9]* | 0*) aif_die "--max-units takes a positive whole number" ;;
        esac
        ;;
      --dry-run) dry=1 ;;
      -h | --help)
        _aif_start_usage
        return 0
        ;;
      *) aif_die "unknown option: $1 (aif start --help)" ;;
    esac
    shift
  done

  # 1. A Claude Code session: the shift opens sessions of its own, in the
  # foreground of a terminal, and nested ones are confounded (FINDINGS #7).
  if [ "$dry" -eq 0 ] && [ "${CLAUDECODE:-}" = 1 ]; then
    aif_err "aif start opens claude sessions of its own, and this is already one — run it in a terminal"
    exit 3
  fi
  # 2. A terminal: the sessions take it, and the control point reads keys
  # from it. Lifted under the session seam (a harness has none) and for a
  # dry run, which asks nothing.
  if [ "$dry" -eq 0 ] && [ -z "${AIF_START_SESSION_CMD:-}" ]; then
    if ! [ -t 2 ] || ! _aif_start_tty_ok; then
      aif_err "aif start needs a terminal — it opens claude sessions in it and waits for keys at its control point. Run it in one (aif start --dry-run shows the plan anywhere)"
      exit 3
    fi
  fi
  # 3. The main checkout, set up: a worker's checkout is a branch, and the
  # board, the locks and what landed are the main checkout's.
  root="$(aif_require_project)"
  main="$(aif_main_root "$root")"
  if [ "$main" != "$root" ]; then
    aif_err "aif start runs in the main checkout — this is a worker's ($root); run it in $main"
    exit 3
  fi
  if [ ! -f "$(aif_project_config "$root")" ]; then
    aif_err "no .aif/project.json — run 'aif project init' first"
    exit 3
  fi
  cfg="$root/$AIF_START_STATE"

  # The state every tick reads (_aif_start_facts) and the summary prints —
  # set here, whatever the environment held.
  AIF_START_ROOT="$root"
  AIF_START_SHIFT_DIR=""
  AIF_START_LOCK=""
  AIF_START_STTY=""
  AIF_START_DONE=""
  AIF_START_RETRIED_ENV=""
  AIF_START_RETRIED_RUN=""
  AIF_START_BUILD_HOLD=""
  AIF_START_FLAG_NO_BUILD="$no_build"
  AIF_START_FLAG_PO="$po"
  AIF_START_FLAG_PJM="$pjm"
  AIF_START_FLAG_RETRY_RUNS="$retry_runs"
  AIF_START_PARALLEL="$parallel"
  AIF_START_MAX_UNITS="$max_units"
  AIF_START_ACTED=0
  AIF_START_UNITS=""
  AIF_START_OPEN=""
  AIF_START_WATCH=""
  AIF_START_BYHAND=""
  AIF_START_MOVES=""
  AIF_START_COUNTS0=""
  AIF_START_ENDED=0
  AIF_START_HUP=0
  AIF_START_NOLOG=0
  AIF_START_LOOPS=0
  AIF_START_FAILED_MOVE=0
  AIF_START_DIGEST=""
  AIF_START_FACTS=""
  AIF_START_T0="$(date +%s)"
  AIF_START_STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  AIF_START_WAIT_S="$(_aif_start_number "${AIF_START_WAIT:-$(aif_meta_get "$cfg" WAIT "" | tr -d '[:space:]')}" 10)"
  AIF_START_POLL_S="$(_aif_start_number "${AIF_START_POLL:-$(aif_meta_get "$cfg" POLL "" | tr -d '[:space:]')}" 30)"

  # 4. The shift's directory, named and not made: the lock says where it
  # will be, and a refusal below leaves none.
  shiftdir="$main/.aif/tmp/shift-$(date '+%Y%m%d-%H%M%S')"
  [ ! -e "$shiftdir" ] || shiftdir="$shiftdir-$$"

  # 5. The lock, and from here a handler that releases it on every way out.
  if [ "$dry" -eq 0 ]; then
    if [ "$no_build" -eq 1 ]; then mdl=none; else mdl=here; fi
    _aif_start_lock "$root" "$shiftdir" "$mdl" || exit 3
    aif_trap_arm _aif_start_early
  fi

  # 6. The profile — refused with 3, not the 1 aif_profile_load exits with
  # — its runner, its environment, and each role's model through it.
  profile_arg="$profile"
  if [ -z "$profile" ]; then
    if [ -f "$root/$AIF_PROFILE_STATE" ]; then
      profile="$(tr -d '[:space:]' <"$root/$AIF_PROFILE_STATE")"
    else
      aif_err "no profile — run 'aif init' or pass --profile"
      exit 3
    fi
  fi
  if ! (aif_profile_load "$profile") >/dev/null 2>&1; then
    err="$( (aif_profile_load "$profile") 2>&1 >/dev/null)" || true
    err="$(_aif_start_why "$err")"
    aif_err "the profile $profile does not load — ${err:-aif profiles lists the ones there are}"
    exit 3
  fi
  aif_profile_load "$profile"
  if [ "$AIF_PROFILE_RUNNER" != claude ]; then
    aif_err "aif start opens claude sessions; profile $profile runs $AIF_PROFILE_RUNNER"
    exit 3
  fi
  # shellcheck source=lib/runner_claude.sh
  . "$AIF_ROOT/lib/runner_claude.sh"
  aif_profile_export_env
  if [ "${AIF_PROFILE_ISOLATE_CONFIG:-0}" = "1" ]; then
    CLAUDE_CONFIG_DIR="$(aif_runner_config_dir "$profile")"
    export CLAUDE_CONFIG_DIR
    mkdir -p "$CLAUDE_CONFIG_DIR"
  fi
  if [ -z "${AIF_START_SESSION_CMD:-}" ]; then
    if ! aif_runner_claude_available; then
      aif_err "claude is not installed — aif start opens its sessions"
      exit 3
    fi
    if [ -n "$AIF_PROFILE_SECRET_VAR" ] && [ -z "$(aif_profile_secret)" ]; then
      aif_err "$AIF_PROFILE_SECRET_VAR is not set — export it to use profile '$profile'"
      exit 3
    fi
  fi
  AIF_START_PROFILE="$profile"
  AIF_START_PROFILE_ARG="$profile_arg"
  # An alias the profile does not map is sent as it is to an endpoint that
  # never heard of it, after a session was opened for a person
  # (docs/DEFECTS.md 14.6) — refused here, with what the profile does map.
  for role in review ba po pjm; do
    case "$role" in
      review) pick="$(_aif_start_pick_model review "$m_review" "$model" "$cfg" "")" ;;
      ba) pick="$(_aif_start_pick_model ba "$m_ba" "$model" "$cfg" opus)" ;;
      po) pick="$(_aif_start_pick_model po "$m_po" "$model" "$cfg" opus)" ;;
      pjm) pick="$(_aif_start_pick_model pjm "$m_pjm" "$model" "$cfg" "")" ;;
    esac
    mdl="${pick%%	*}"
    src="${pick#*	}"
    if [ -n "$mdl" ] && ! aif_profile_maps_model "$mdl"; then
      mapped=""
      [ -z "${ANTHROPIC_DEFAULT_OPUS_MODEL:-}" ] || mapped="opus"
      [ -z "${ANTHROPIC_DEFAULT_SONNET_MODEL:-}" ] || mapped="${mapped:+$mapped, }sonnet"
      [ -z "${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}" ] || mapped="${mapped:+$mapped, }haiku"
      aif_die "$src: the profile $profile does not map $mdl (it maps ${mapped:-no alias}) — name one of those or a full model id"
    fi
    case "$role" in
      review) AIF_START_MODEL_REVIEW="$mdl" ;;
      ba) AIF_START_MODEL_BA="$mdl" ;;
      po) AIF_START_MODEL_PO="$mdl" ;;
      pjm) AIF_START_MODEL_PJM="$mdl" ;;
    esac
  done

  # 7. The board, as the worker's preflight asks it.
  if ! (aif_board_check "$root") >/dev/null 2>&1; then
    (aif_board_check "$root") >&2 || true
    aif_err "the board is not reachable as configured — fix that first (aif board check)"
    exit 3
  fi

  if [ "$dry" -eq 1 ]; then
    _aif_start_dry_run "$root"
  fi

  # 8. Whether claude answers under this profile — one billed turn, before a
  # person is handed a session that cannot.
  if [ -z "${AIF_START_SESSION_CMD:-}" ]; then
    _aif_start_say "probe" "claude under profile $profile — one billed turn, before any session"
    if ! out="$(cd "$root" && aif_runner_claude_probe)"; then
      aif_err "claude does not answer under profile $profile — $out"
      exit 3
    fi
    _aif_start_say "probe" "$out"
  fi

  # 9. Only now the shift exists: its directory, the terminal as it was (to
  # put back on every way out), its handler.
  if ! mkdir -p "$shiftdir/cards" 2>/dev/null || ! : >"$shiftdir/shift.log" 2>/dev/null; then
    aif_err "could not make the shift's directory $shiftdir"
    exit 3
  fi
  AIF_START_SHIFT_DIR="$shiftdir"
  AIF_START_STTY="$({ stty -g </dev/tty; } 2>/dev/null)" || AIF_START_STTY=""
  aif_trap_arm _aif_start_signal
  cd "$root" || _aif_start_finish 3 "could not enter $root"
  if [ -f "$cfg" ] && ! git -C "$root" check-ignore -q "$AIF_START_STATE" 2>/dev/null; then
    # A project set up before the shift existed: its ignore block does not
    # name the file until its next `aif init` (docs/DEFECTS.md 15.2).
    aif_warn "$AIF_START_STATE is not gitignored here — aif init adds it to the ignore block; until then, keep it out of your commits"
  fi
  _aif_start_log "shift started $AIF_START_STARTED_AT · pid $$ · $shiftdir"
  _aif_start_shift "$root"
}
