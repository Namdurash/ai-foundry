#!/usr/bin/env bash
#
# The board adapter: every state transition in the pipeline goes through here.
# Sourced by bin/aif; not meant to be executed directly.
#
# The board is where the project's state is SEEN — so that it is not held in a
# head — and it owns what lives between tickets: which column each is in, its
# order, its labels, the reviewer's comments. Inside a ticket, `tasks/<ID>/`
# owns the artifacts (docs/REBUILD-3.md §5). The split has one rule at the
# seam: the board is canonical for the ticket's TEXT until intake, the
# repository after — `aif work` copies the card into ticket.md, hashes it, and
# from then on the run reads only the bytes it froze.
#
# Bash, REST, deterministic, no model. A model "remembering" to move the card
# is fail-open bookkeeping, and FINDINGS #11 is what that costs: a card that
# quietly did not move is a meter that quietly did not fire. The skills that
# manage the board (`/aif-pjm`) work through this one surface too, so there is
# one access path and one token.
#
# Two backends behind one interface:
#
#   local   — .aif/board/<ID>.json in the MAIN checkout, gitignored. This
#             machine's board for a project without one. Resolved through the
#             git common dir, so a move made from inside a worktree lands on
#             the same board the developer looks at.
#   trello  — the REST API, curl + jq. One key, one token, both from
#             lib/secret.sh; the six columns are list ids in project.json.
#             AIF_TRELLO_API overrides the base URL (the offline check runs the
#             adapter against a stand-in server).
#
# Columns are canonical names — backlog ready in_progress review done
# needs_human — and the backend maps them.

AIF_BOARD_COLUMNS="backlog ready in_progress review done needs_human"
AIF_TRELLO_API_DEFAULT="https://api.trello.com/1"

# aif_board_column <name> — the canonical column, or empty. Accepts the dashed
# and spaced spellings a human types.
aif_board_column() {
  case "$(printf '%s' "$1" | tr 'A-Z -' 'a-z__')" in
    backlog | todo | to_do) printf 'backlog' ;;
    ready) printf 'ready' ;;
    in_progress | doing | progress) printf 'in_progress' ;;
    review | in_review) printf 'review' ;;
    done) printf 'done' ;;
    needs_human | blocked | human) printf 'needs_human' ;;
    *) printf '' ;;
  esac
}

# aif_board_kind <root> — local | trello, from project.json; local when absent.
aif_board_kind() {
  local k
  k="$(jq -r '.board.kind // "local"' "$(aif_project_config "$1")" 2>/dev/null)"
  [ -n "$k" ] || k="local"
  printf '%s' "$k"
}

# aif_board_ticket_re <root> — the project's ticket pattern, for card names.
aif_board_ticket_re() {
  jq -r '.ticket_pattern // "^[A-Z]{2,10}-[0-9]+$"' "$(aif_project_config "$1")" 2>/dev/null
}

# _aif_board_title <ticket.md> — the ticket's title line, without its id.
_aif_board_title() {
  local line
  line="$(grep -m1 '^# ' "$1" 2>/dev/null | sed 's/^# *//')"
  printf '%s' "$line" | sed -E 's/^[A-Z][A-Z0-9]{1,9}-[0-9]+[[:space:]]*[—:-]+[[:space:]]*//'
}

# _aif_board_ticket_id <ticket.md> — the id from the meta block.
_aif_board_ticket_id() {
  aif_meta_json "$1" 2>/dev/null | jq -r '.ticket // empty' 2>/dev/null
}

_aif_board_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# ---------------------------------------------------------------------------
# local
# ---------------------------------------------------------------------------

aif_board_local_dir() {
  printf '%s/.aif/board' "$(aif_main_root "$1")"
}

_aif_board_local_card() {
  printf '%s/%s.json' "$(aif_board_local_dir "$1")" "$2"
}

_aif_board_local_require() {
  local f
  f="$(_aif_board_local_card "$1" "$2")"
  [ -f "$f" ] || aif_die "no card for $2 on the local board — create it: aif board create $AIF_TASKS_DIR/$2/ticket.md"
  printf '%s' "$f"
}

_aif_board_local_next_ready() {
  local dir
  dir="$(aif_board_local_dir "$1")"
  [ -d "$dir" ] || return 0
  # Lowest pos first: `move --top` sets a pos below every other card's, so the
  # project manager's ordering is what the worker pulls.
  jq -rs '[ .[] | select(.column == "ready") ] | sort_by(.pos) | .[0].ticket // empty' \
    "$dir"/*.json 2>/dev/null
}

_aif_board_local_ready_list() {
  local dir
  dir="$(aif_board_local_dir "$1")"
  [ -d "$dir" ] || return 0
  ls "$dir"/*.json >/dev/null 2>&1 || return 0
  jq -rs '[ .[] | select(.column == "ready") ] | sort_by(.pos) | .[].ticket' "$dir"/*.json 2>/dev/null
}

_aif_board_local_pull() {
  # The ticket already lives in tasks/; the local board holds no text. Nothing
  # to copy — but say so, so the two backends are called the same way.
  _aif_board_local_require "$1" "$2" >/dev/null
  printf 'pulled %s (local board: the ticket is already in %s/%s/)\n' "$2" "$AIF_TASKS_DIR" "$2"
}

# _aif_board_local_pos <root> top|bottom — a pos strictly below every card's,
# or strictly above. It was `date +%s` for a plain move: two moves in one
# second tied, `sort_by(.pos)` broke the tie by whatever order the glob
# returned, and `next-ready` stopped being deterministic exactly when the
# project manager was reordering the queue quickly (docs/DEFECTS.md 3.12).
#
# The glob is tested first, on purpose. Handed a pattern that matched nothing,
# `jq -s` still runs the filter over an empty slurp AND exits non-zero — so a
# `|| printf 1` fallback printed a second number after jq's, and the first
# card on a fresh board was created with `--argjson p 11`… which is not JSON.
_aif_board_local_pos() {
  local dir n=""
  dir="$(aif_board_local_dir "$1")"
  if ls "$dir"/*.json >/dev/null 2>&1; then
    case "$2" in
      top) n="$(jq -rs '[ .[].pos ] | (min // 1000000) - 1' "$dir"/*.json 2>/dev/null)" ;;
      *) n="$(jq -rs '[ .[].pos ] | (max // 0) + 1' "$dir"/*.json 2>/dev/null)" ;;
    esac
  fi
  case "$n" in
    '' | *[!0-9.-]*) n=1 ;;
  esac
  printf '%s' "$n"
}

_aif_board_local_move() {
  local root="$1" id="$2" col="$3" where="${4:-}" f pos
  f="$(_aif_board_local_require "$root" "$id")"
  case "$where" in
    top) pos="$(_aif_board_local_pos "$root" top)" ;;
    *) pos="$(_aif_board_local_pos "$root" bottom)" ;;
  esac
  jq --arg c "$col" --argjson p "${pos:-0}" --arg at "$(_aif_board_now)" \
    '.column = $c | .pos = $p | .moved_at = $at' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
  printf 'moved %s → %s\n' "$id" "$col"
}

_aif_board_local_comment() {
  local root="$1" id="$2" file="$3" f by
  f="$(_aif_board_local_require "$root" "$id")"
  by="${AIF_BOARD_BY:-${USER:-aif}}"
  jq --rawfile t "$file" --arg by "$by" --arg at "$(_aif_board_now)" \
    '.comments += [ { at: $at, by: $by, text: $t } ]' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
  printf 'commented on %s (%s bytes)\n' "$id" "$(wc -c <"$file" | tr -d ' ')"
}

_aif_board_local_create() {
  local root="$1" ticket="$2" col="$3" id title f dir
  id="$(_aif_board_ticket_id "$ticket")"
  [ -n "$id" ] || aif_die "$ticket has no aif:meta ticket id"
  title="$(_aif_board_title "$ticket")"
  dir="$(aif_board_local_dir "$root")"
  mkdir -p "$dir"
  f="$dir/$id.json"
  if [ -f "$f" ]; then
    jq --arg t "$title" --arg c "$col" --arg at "$(_aif_board_now)" \
      '.title = $t | .column = $c | .moved_at = $at' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
    printf 'updated %s (%s) → %s\n' "$id" "$title" "$col"
  else
    jq -n --arg id "$id" --arg t "$title" --arg c "$col" --arg at "$(_aif_board_now)" \
      --argjson p "$(_aif_board_local_pos "$root" bottom)" \
      '{ ticket: $id, title: $t, column: $c, pos: $p, labels: [], comments: [],
         created_at: $at, moved_at: $at }' >"$f"
    printf 'created %s (%s) → %s\n' "$id" "$title" "$col"
  fi
}

_aif_board_local_status_json() {
  local dir
  dir="$(aif_board_local_dir "$1")"
  if [ ! -d "$dir" ] || ! ls "$dir"/*.json >/dev/null 2>&1; then
    printf '[]'
    return 0
  fi
  jq -s '[ .[] | { ticket, title, column, pos, labels, moved_at,
                    comments: (.comments | length) } ]
         | sort_by(.column, .pos)' "$dir"/*.json
}

_aif_board_local_show_json() {
  local f
  f="$(_aif_board_local_require "$1" "$2")"
  jq '{ ticket, title, column, labels, moved_at, comments }' "$f"
}

# The column alone, from the card file: rc 1 when there is no card, 2 with the
# reason when the file cannot be read (see aif_board_card_column).
_aif_board_local_card_column() {
  local f
  f="$(_aif_board_local_card "$1" "$2")"
  [ -f "$f" ] || return 1
  jq -r '.column // empty' "$f" 2>/dev/null || {
    printf 'could not read %s\n' "${f#"$(aif_main_root "$1")"/}" >&2
    return 2
  }
}

_aif_board_local_label() {
  local root="$1" id="$2" label="$3" f
  f="$(_aif_board_local_require "$root" "$id")"
  jq --arg l "$label" '.labels = ((.labels + [$l]) | unique)' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
  printf 'labelled %s: %s\n' "$id" "$label"
}

# ---------------------------------------------------------------------------
# trello
# ---------------------------------------------------------------------------

_aif_trello_secret() { # <root> <field: secret|key_secret>
  local name v
  name="$(jq -r --arg f "$2" '.board[$f] // empty' "$(aif_project_config "$1")" 2>/dev/null)"
  [ -n "$name" ] || aif_die "project.json board.$2 names no secret — run: aif board init trello"
  v="$(aif_secret_get "$name")" || aif_die "$name is not set — run in your terminal: aif secret set $name"
  printf '%s' "$v"
}

# _aif_trello_call <root> <method> <path> [curl args…] — JSON on stdout.
#
# The key and token travel in the Authorization header, not the query string,
# so they are in no URL, no shell history and no log line — and the one file
# this writes is curl's dump of the RESPONSE headers, which carry neither. -f
# turns an HTTP error into a non-zero exit; the caller decides what that means.
#
# Timeouts, because the call had none: a connection the API held open hung the
# worker that held a card In Progress, or the loop's poll, for as long as the
# socket lived (docs/DEFECTS.md 13.8). Ten seconds to connect and a minute for
# the whole exchange is room for a 76 KiB description on a slow link.
#
# A retry, for what a second attempt can fix and nothing else: a 429, the 5xx
# a gateway or an overloaded API answers, and curl's own could-not-connect (7),
# timed-out (28), empty-reply (52) and network (56). Only for GET and PUT —
# both say the same thing twice. A POST does not: a comment whose first attempt
# landed and whose answer was lost would be posted twice, and the comment is
# the card's record; a label or a card, twice (13.8; docs/AUTOPILOT-RESEARCH.md
# §6.11, verification 6). Between attempts: Retry-After when the server names
# a wait of up to a minute, else the attempt's number of AIF_TRELLO_RETRY_SLEEP.
# That list is a string, not an array, because it comes in from the
# environment, which carries no arrays — and because an empty array is an error
# under set -u on bash 3.2. The final failure prints curl's last message, as
# one attempt did, and returns its rc, so every caller's `|| aif_die "… $out"`
# reads as before.
_aif_trello_call() {
  local root="$1" method="$2" path="$3" key token base
  shift 3
  key="$(_aif_trello_secret "$root" key_secret)" || return 3
  token="$(_aif_trello_secret "$root" secret)" || return 3
  base="${AIF_TRELLO_API:-$AIF_TRELLO_API_DEFAULT}"
  local tries="${AIF_TRELLO_RETRIES:-3}" attempt=1 hdr out rc
  case "$method" in
    GET | PUT) ;;
    *) tries=1 ;;
  esac
  case "$tries" in
    '' | *[!0-9]* | 0) tries=1 ;;
  esac
  # The header dump exists for Retry-After, which only a retry reads: a POST,
  # or a single attempt, writes none and leaves nothing behind to remove.
  hdr=""
  [ "$tries" -le 1 ] || hdr="$(mktemp "${TMPDIR:-/tmp}/aif-trello-XXXXXX")"
  while :; do
    rc=0
    out="$(curl -sS -f -X "$method" "$base$path" \
      --connect-timeout 10 --max-time 60 ${hdr:+-D "$hdr"} \
      -H "Authorization: OAuth oauth_consumer_key=\"$key\", oauth_token=\"$token\"" \
      -H "Accept: application/json" \
      "$@" 2>&1)" || rc=$?
    [ "$rc" -ne 0 ] || break
    [ "$attempt" -lt "$tries" ] || break
    _aif_trello_retryable "$rc" "$out" || break
    sleep "$(_aif_trello_retry_wait "$hdr" "$attempt")" 2>/dev/null || sleep 1
    attempt=$((attempt + 1))
  done
  [ -z "$hdr" ] || rm -f "$hdr"
  printf '%s' "$out"
  return "$rc"
}

# _aif_trello_retryable <curl rc> <curl's message> — rc 0 when another attempt
# makes sense. The HTTP code is read out of curl's own line — `curl: (22) The
# requested URL returned error: 503` — because -f discards the body, and -w
# would write the code into the JSON the caller parses. Every other failure
# (a 401, a 404, a 400 for a malformed comment) says the same thing twice
# (docs/DEFECTS.md 13.8).
_aif_trello_retryable() {
  local rc="$1" code
  case "$rc" in
    7 | 28 | 52 | 56) return 0 ;;
    22) ;;
    *) return 1 ;;
  esac
  code="$(printf '%s\n' "$2" | sed -n 's/.*returned error: \([0-9][0-9][0-9]\).*/\1/p' | sed -n 1p)"
  case "$code" in
    429 | 500 | 502 | 503 | 504) return 0 ;;
  esac
  return 1
}

# _aif_trello_retry_wait <header dump> <attempt> — the seconds to sleep before
# the next attempt: Retry-After when the server sent one of up to 60 whole
# seconds (a date, or an hour, is not waited on — the list is), else the
# attempt's number of AIF_TRELLO_RETRY_SLEEP, and its last number past its end.
# Every pipeline here exits 0 on its own: a `grep` with no match would end the
# caller under set -e (docs/DEFECTS.md 13.8).
_aif_trello_retry_wait() {
  local hdr="$1" attempt="$2" after wait
  after="$(sed -n 's/^[Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]:[[:space:]]*//p' "$hdr" 2>/dev/null | tr -d '\r ' | sed -n '$p')"
  # One or two digits only: a wider number is past the minute anyway, and a
  # string wider than the shell's integer makes `[` fail rather than compare.
  case "$after" in
    [0-9] | [0-9][0-9]) [ "$after" -gt 60 ] || {
      printf '%s' "$after"
      return 0
    } ;;
  esac
  wait="$(printf '%s\n' "${AIF_TRELLO_RETRY_SLEEP:-1 3 7}" | awk -v n="$attempt" 'NF { print (n <= NF) ? $n : $NF }')"
  case "$wait" in
    '' | *[!0-9.]*) wait=1 ;;
  esac
  printf '%s' "$wait"
}

_aif_trello_board() {
  jq -r '.board.board_id // empty' "$(aif_project_config "$1")" 2>/dev/null
}

_aif_trello_list_id() { # <root> <column>
  jq -r --arg c "$2" '.board.lists[$c] // empty' "$(aif_project_config "$1")" 2>/dev/null
}

# _aif_trello_column_of_list <root> <listId> — the canonical column, or "".
_aif_trello_column_of_list() {
  jq -r --arg l "$2" '.board.lists // {} | to_entries[] | select(.value == $l) | .key' \
    "$(aif_project_config "$1")" 2>/dev/null | sed -n 1p
}

# _aif_trello_find_card <root> <ID> — the card JSON, or rc 1.
#
# Captured once and tested as a variable. This used to pipe a pretty-printed jq
# into `grep -q .` to ask "is there a card": grep left at the opening brace, jq
# — still writing the card's description, which under this foundry IS the
# ticket file — took SIGPIPE, `pipefail` made 141 the pipeline's status, and
# `|| return 1` said the card was absent. Only for a card long enough to be
# worth building; `status` never asks for desc, so it went on listing a card
# the worker then could not find (docs/DEFECTS.md 5.1, FINDINGS #19).
_aif_trello_find_card() {
  local root="$1" id="$2" board out card
  board="$(_aif_trello_board "$root")"
  [ -n "$board" ] || aif_die "project.json board.board_id is empty — run: aif board init trello"
  out="$(_aif_trello_call "$root" GET "/boards/$board/cards" -G \
    --data-urlencode "fields=name,idList,pos,desc,shortUrl,idLabels")" ||
    aif_die "Trello: could not list the board's cards — $out"
  card="$(printf '%s' "$out" | jq -c --arg id "$id" \
    '[ .[] | select(.name | test("^" + $id + "([^A-Za-z0-9-]|$)")) ] | .[0] // empty' 2>/dev/null)"
  [ -n "$card" ] || return 1
  printf '%s' "$card"
}

# Every caller assigns this inside `$(…)` and follows with `|| return 1`, on
# purpose. The die above runs in the substitution's subshell; without the
# guard the caller kept going with an empty card whenever set -e was off —
# and it is off inside any `if`, including the worker's `if ! (aif_board_move
# …)`, which is how "no card named OPES-68" was followed by "could not move
# OPES-68 — 404" from a PUT to /cards/null (docs/DEFECTS.md 5.1).
_aif_trello_require_card() {
  _aif_trello_find_card "$1" "$2" ||
    aif_die "no card named $2 on the Trello board — create it: aif board create $AIF_TASKS_DIR/$2/ticket.md"
}

_aif_trello_next_ready() {
  local root="$1" list out re
  list="$(_aif_trello_list_id "$root" ready)"
  [ -n "$list" ] || aif_die "project.json board.lists.ready is empty — run: aif board init trello"
  re="$(aif_board_ticket_re "$root" | sed 's/^\^//; s/\$$//')"
  out="$(_aif_trello_call "$root" GET "/lists/$list/cards" -G --data-urlencode "fields=name,pos")" ||
    aif_die "Trello: could not read the Ready list — $out"
  printf '%s' "$out" | jq -r --arg re "$re" \
    '[ .[] | select(.name | test("^" + $re)) ] | sort_by(.pos) | .[0].name // empty' |
    grep -oE "^$re" | sed -n 1p
}

# The whole Ready column, in the board's order — what a loop running several
# workers chooses from, skipping the cards it has already taken. `|| true` at
# the end: grep with nothing to print exits 1, and under pipefail an empty
# column would read as a failed call.
_aif_trello_ready_list() {
  local root="$1" list out re
  list="$(_aif_trello_list_id "$root" ready)"
  [ -n "$list" ] || aif_die "project.json board.lists.ready is empty — run: aif board init trello"
  re="$(aif_board_ticket_re "$root" | sed 's/^\^//; s/\$$//')"
  out="$(_aif_trello_call "$root" GET "/lists/$list/cards" -G --data-urlencode "fields=name,pos")" ||
    aif_die "Trello: could not read the Ready list — $out"
  printf '%s' "$out" | jq -r --arg re "$re" \
    '[ .[] | select(.name | test("^" + $re)) ] | sort_by(.pos) | .[].name' |
    grep -oE "^$re" || true
}

# _aif_trello_pull <root> <ID> — the card's description becomes ticket.md.
#
# The board is canonical for the text until intake: what the analyst wrote (or
# the human edited) on the card is what gets built. Written into THIS
# checkout's tasks/ — the worker calls this from its worktree.
_aif_trello_pull() {
  local root="$1" id="$2" card work
  card="$(_aif_trello_require_card "$root" "$id")" || return 1
  work="$(aif_task_dir "$root" "$id")"
  mkdir -p "$work"
  # -j, not -r: the description is the file's bytes and the file's bytes are
  # what gets hashed; a newline jq adds on output is a hash that does not match.
  # tr -d '\r': Trello's editor can hand back \r\n, and the file written here is
  # the bytes the run hashes and the bytes `board create` pushes back — LF, so a
  # round trip does not change them (docs/DEFECTS.md 3.10).
  printf '%s' "$card" | jq -j '.desc' | tr -d '\r' >"$work/ticket.md.tmp"
  if ! grep -q '^<!-- aif:meta$' "$work/ticket.md.tmp"; then
    rm -f "$work/ticket.md.tmp"
    aif_die "the card $id has no aif:meta block in its description — it was not written by the analyst (/aif-ba)"
  fi
  mv "$work/ticket.md.tmp" "$work/ticket.md"
  # No ledger: the worker makes one at intake, outside git (docs/DEFECTS.md
  # 13.13). One made here, in the developer's checkout, met the branch's at
  # land (13.2).
  printf 'pulled %s → %s/%s/ticket.md (%s bytes)\n' "$id" "$AIF_TASKS_DIR" "$id" \
    "$(wc -c <"$work/ticket.md" | tr -d ' ')"
}

_aif_trello_move() {
  local root="$1" id="$2" col="$3" where="${4:-}" card cid list out
  card="$(_aif_trello_require_card "$root" "$id")" || return 1
  cid="$(printf '%s' "$card" | jq -r '.id')"
  list="$(_aif_trello_list_id "$root" "$col")"
  [ -n "$list" ] || aif_die "project.json board.lists.$col is empty — run: aif board init trello"
  out="$(_aif_trello_call "$root" PUT "/cards/$cid" --data-urlencode "idList=$list" \
    --data-urlencode "pos=${where:-bottom}")" ||
    aif_die "Trello: could not move $id — $out"
  printf 'moved %s → %s\n' "$id" "$col"
}

# Trello takes a comment of 1 to 16384 characters, counted the way JavaScript
# counts them — UTF-16 code units: one for a letter of Latin or Cyrillic, two
# for an emoji. The cut used to count bytes. A Ukrainian report, two bytes a
# letter, was cut at byte 15800: through a letter, and short of a limit it had
# never reached — 16198 bytes were 12347 characters. Trello refused the
# malformed text with a 400, so the card that most needed its report got none
# (docs/DEFECTS.md 10.1).
AIF_TRELLO_COMMENT_MAX=16384

# _aif_trello_fit <file> <out> <note> — the file's text as Trello will take it:
# whole when it fits, else cut on a character boundary with <note> after it,
# the two together within AIF_TRELLO_COMMENT_MAX. Through jq, which reads the
# file as UTF-8, slices by character and writes valid UTF-8 back, whatever a
# station left in the report. Echoes the text's length in the limit's units.
# rc 0 whole · 1 cut · 2 the file could not be read.
_aif_trello_fit() {
  local file="$1" out="$2" note="$3" len
  len="$(jq -Rs '[explode[] | if . > 65535 then 2 else 1 end] | add // 0' "$file" 2>/dev/null)" || return 2
  printf '%s' "$len"
  if [ "$len" -le "$AIF_TRELLO_COMMENT_MAX" ]; then
    jq -Rsj '.' "$file" >"$out" || return 2
    return 0
  fi
  jq -Rsj --arg note "$note" --argjson max "$AIF_TRELLO_COMMENT_MAX" '
    def units: if . > 65535 then 2 else 1 end;
    ($max - ([$note | explode[] | units] | add // 0)) as $room
    | explode as $cs
    | (reduce $cs[] as $c ({ n: 0, k: 0, full: false };
        if .full then .
        elif .n + ($c | units) > $room then .full = true
        else .n += ($c | units) | .k += 1 end)) as $r
    | ($cs[0:$r.k] | implode) + $note' "$file" >"$out" || return 2
  return 1
}

# The text of a comment that does not fit is cut, with where the whole of it
# can be read: AIF_BOARD_FULL_AT when the caller knows (the worker names the
# report on its branch), else the file, when it is in the project.
_aif_trello_comment() {
  local root="$1" id="$2" file="$3" card cid out tmp len where note fit=0
  card="$(_aif_trello_require_card "$root" "$id")" || return 1
  cid="$(printf '%s' "$card" | jq -r '.id')"
  where="${AIF_BOARD_FULL_AT:-}"
  if [ -z "$where" ]; then
    case "$file" in
      "$root"/*) where="${file#"$root"/}" ;;
    esac
  fi
  note="$(printf '\n\n_(cut to fit a Trello comment — the whole text is %s)_' "${where:-in the file this was posted from}")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/aif-comment-XXXXXX")"
  len="$(_aif_trello_fit "$file" "$tmp" "$note")" || fit=$?
  if [ "$fit" -eq 2 ]; then
    rm -f "$tmp"
    aif_die "could not read $file as text to comment on $id"
  fi
  if ! out="$(_aif_trello_call "$root" POST "/cards/$cid/actions/comments" --data-urlencode "text@$tmp")"; then
    rm -f "$tmp"
    aif_die "Trello: could not comment on $id — $out"
  fi
  rm -f "$tmp"
  if [ "$fit" -eq 1 ]; then
    printf 'commented on %s (%s characters, cut to fit — the whole text is %s)\n' "$id" "$len" "${where:-in the file}"
  else
    printf 'commented on %s (%s characters)\n' "$id" "$len"
  fi
}

# A card's description holds the same 16384 characters a comment does, counted
# the same way, and a ticket IS its card's description on a Trello board. One
# over the limit was refused with a bare 400 after it had passed the ready
# gate, and finding out why meant counting characters by hand — `wc -c`
# counts bytes, which for Ukrainian is nearly double (docs/DEFECTS.md 10.2).
# So the count is made here before anything is sent, and in the ready gate
# before the analyst hands the ticket over.
AIF_TRELLO_DESC_MAX=16384

# _aif_trello_units <file> — the file's length as Trello counts it.
_aif_trello_units() {
  jq -Rs '[explode[] | if . > 65535 then 2 else 1 end] | add // 0' "$1" 2>/dev/null
}

# _aif_trello_create <root> <ticket.md> <column> — a card, or the existing
# card's description brought up to date. The description IS the ticket file,
# aif:meta block and all: that is what `pull` reads back at intake.
_aif_trello_create() {
  local root="$1" ticket="$2" col="$3" id title list card cid out len
  id="$(_aif_board_ticket_id "$ticket")"
  [ -n "$id" ] || aif_die "$ticket has no aif:meta ticket id"
  len="$(_aif_trello_units "$ticket")"
  if [ "${len:-0}" -gt "$AIF_TRELLO_DESC_MAX" ]; then
    aif_die "$ticket is $len characters, and a Trello card's description holds $AIF_TRELLO_DESC_MAX (counted as Trello counts them: one for a letter, two for an emoji) — cut it before it goes on the board: the narrative first, then the longest decided answers. aif _ready says the same on a Trello project."
  fi
  title="$(_aif_board_title "$ticket")"
  list="$(_aif_trello_list_id "$root" "$col")"
  [ -n "$list" ] || aif_die "project.json board.lists.$col is empty — run: aif board init trello"
  if card="$(_aif_trello_find_card "$root" "$id")"; then
    cid="$(printf '%s' "$card" | jq -r '.id')"
    out="$(_aif_trello_call "$root" PUT "/cards/$cid" --data-urlencode "name=$id — $title" \
      --data-urlencode "desc@$ticket" --data-urlencode "idList=$list")" ||
      aif_die "Trello: could not update $id — $out"
    printf 'updated %s (%s) → %s\n' "$id" "$title" "$col"
  else
    out="$(_aif_trello_call "$root" POST "/cards" --data-urlencode "idList=$list" \
      --data-urlencode "name=$id — $title" --data-urlencode "desc@$ticket" \
      --data-urlencode "pos=bottom")" ||
      aif_die "Trello: could not create $id — $out"
    printf 'created %s (%s) → %s  %s\n' "$id" "$title" "$col" "$(printf '%s' "$out" | jq -r '.shortUrl // ""')"
  fi
}

_aif_trello_status_json() {
  local root="$1" board out lists
  board="$(_aif_trello_board "$root")"
  lists="$(jq -c '.board.lists // {}' "$(aif_project_config "$root")")"
  out="$(_aif_trello_call "$root" GET "/boards/$board/cards" -G \
    --data-urlencode "fields=name,idList,pos,dateLastActivity,labels")" ||
    aif_die "Trello: could not list the board's cards — $out"
  printf '%s' "$out" | jq --argjson lists "$lists" '
    ($lists | to_entries | map({ key: .value, value: .key }) | from_entries) as $col
    | [ .[] | { ticket: (.name | split(" ")[0]),
                title: (.name | sub("^[^ ]+ *[—:-]+ *"; "")),
                column: ($col[.idList] // "other"),
                pos, labels: [ .labels[]?.name ], moved_at: .dateLastActivity } ]
    | sort_by(.column, .pos)'
}

# A read of the comments that failed used to become `comments: []` with rc 0 —
# the JSON of a card nobody has commented on. The first line of the newest
# comment is what every routing decision downstream reads (aif_board_last_line,
# the project manager, the release sweep), so a board that could not be asked
# looked exactly like a card with nothing to say, and was routed as one
# (docs/AUTOPILOT-RESEARCH.md §6.11, verification 3; docs/DEFECTS.md 14.7). Now
# it dies with the reason, after the call's own retries.
_aif_trello_show_json() {
  local root="$1" id="$2" card cid comments col
  card="$(_aif_trello_require_card "$root" "$id")" || return 1
  cid="$(printf '%s' "$card" | jq -r '.id')"
  col="$(_aif_trello_column_of_list "$root" "$(printf '%s' "$card" | jq -r '.idList')")"
  comments="$(_aif_trello_call "$root" GET "/cards/$cid/actions" -G \
    --data-urlencode "filter=commentCard" --data-urlencode "limit=20")" ||
    aif_die "Trello: could not read the comments of $id — $(printf '%s' "$comments" | sed -n 1p)"
  printf '%s' "$card" | jq --arg col "${col:-other}" --argjson c "$comments" '
    { ticket: (.name | split(" ")[0]), title: (.name | sub("^[^ ]+ *[—:-]+ *"; "")),
      column: $col, url: .shortUrl, description: .desc,
      comments: [ $c[] | { at: .date, by: (.memberCreator.username // .memberCreator.fullName // "?"),
                           text: .data.text } ] | reverse }'
}

# The column alone, from one listing of the board's cards — the call
# `_aif_trello_call` retries — and never from the actions call. The listing
# helper dies when the board does not answer, in this substitution's subshell
# with its reason on stderr, and returns 1 with nothing said when there is no
# such card; the two are told apart by whether it said anything (see
# aif_board_card_column).
_aif_trello_card_column() {
  local root="$1" id="$2" card col esc
  card="$(_aif_trello_find_card "$root" "$id" 2>&1)" || {
    [ -n "$card" ] || return 1
    esc="$(printf '\033')"
    printf '%s\n' "$card" | sed -n 1p | sed "s/$esc\[[0-9;]*m//g; s/^error: //" >&2
    return 2
  }
  col="$(_aif_trello_column_of_list "$root" "$(printf '%s' "$card" | jq -r '.idList')")"
  printf '%s\n' "${col:-other}"
}

_aif_trello_label() {
  local root="$1" id="$2" label="$3" card cid board labels lid out
  card="$(_aif_trello_require_card "$root" "$id")" || return 1
  cid="$(printf '%s' "$card" | jq -r '.id')"
  board="$(_aif_trello_board "$root")"
  labels="$(_aif_trello_call "$root" GET "/boards/$board/labels" -G --data-urlencode "fields=name")" ||
    aif_die "Trello: could not read labels — $labels"
  lid="$(printf '%s' "$labels" | jq -r --arg n "$label" '[ .[] | select(.name == $n) ] | .[0].id // empty')"
  if [ -z "$lid" ]; then
    out="$(_aif_trello_call "$root" POST "/labels" --data-urlencode "name=$label" \
      --data-urlencode "idBoard=$board" --data-urlencode "color=null")" ||
      aif_die "Trello: could not create label $label — $out"
    lid="$(printf '%s' "$out" | jq -r '.id')"
  fi
  out="$(_aif_trello_call "$root" POST "/cards/$cid/idLabels" --data-urlencode "value=$lid")" ||
    aif_die "Trello: could not label $id — $out"
  printf 'labelled %s: %s\n' "$id" "$label"
}

# ---------------------------------------------------------------------------
# the interface
# ---------------------------------------------------------------------------

aif_board_next_ready() { "_aif_board_$(aif_board_kind "$1")_next_ready" "$1"; }
aif_board_ready_list() { "_aif_board_$(aif_board_kind "$1")_ready_list" "$1"; }
aif_board_pull() { "_aif_board_$(aif_board_kind "$1")_pull" "$1" "$2"; }
aif_board_move() { "_aif_board_$(aif_board_kind "$1")_move" "$1" "$2" "$3" "${4:-}"; }
aif_board_comment() { "_aif_board_$(aif_board_kind "$1")_comment" "$1" "$2" "$3"; }
aif_board_create() { "_aif_board_$(aif_board_kind "$1")_create" "$1" "$2" "$3"; }
aif_board_status_json() { "_aif_board_$(aif_board_kind "$1")_status_json" "$1"; }
aif_board_show_json() { "_aif_board_$(aif_board_kind "$1")_show_json" "$1" "$2"; }
aif_board_label() { "_aif_board_$(aif_board_kind "$1")_label" "$1" "$2" "$3"; }

# aif_board_card_column <root> <ID> — the card's canonical column and nothing
# else, on either backend. Prints it. rc 0 printed · 1 no such card · 2 the
# board could not be read, the reason on stderr as one bare line, the way
# aif_board_last_line gives it.
#
# `show` reads the card with its comments, and since 14.7 dies when the
# comments cannot be read. Two callers only ever wanted the column — the land,
# asking whether the card is in Review (`_aif_land_column`, lib/cmd_land.sh),
# and `aif work <ID> --stop`, settling the card of a worker that is gone
# (lib/cmd_work.sh) — and both read it out of `show` under `2>/dev/null … ||
# true`, so a comments read that failed for good handed them an empty column:
# the land refused it as "no card on the board", and the stop read it as an
# unknown column, removed the lock and left the card In Progress for the next
# `aif work` to take as fresh. So the column has a read of its own that never
# asks for the comments: on Trello one listing of the board's cards, on the
# local board the card file — and a board that cannot answer is rc 2, said,
# not an empty answer (docs/DEFECTS.md 14.7, 13.8).
aif_board_card_column() { "_aif_board_$(aif_board_kind "$1")_card_column" "$1" "$2"; }

# The trello functions are named _aif_trello_*; alias them under the interface's
# naming so the dispatch above is one line per operation.
_aif_board_trello_next_ready() { _aif_trello_next_ready "$@"; }
_aif_board_trello_ready_list() { _aif_trello_ready_list "$@"; }
_aif_board_trello_pull() { _aif_trello_pull "$@"; }
_aif_board_trello_move() { _aif_trello_move "$@"; }
_aif_board_trello_comment() { _aif_trello_comment "$@"; }
_aif_board_trello_create() { _aif_trello_create "$@"; }
_aif_board_trello_status_json() { _aif_trello_status_json "$@"; }
_aif_board_trello_show_json() { _aif_trello_show_json "$@"; }
_aif_board_trello_label() { _aif_trello_label "$@"; }
_aif_board_trello_card_column() { _aif_trello_card_column "$@"; }

# ---------------------------------------------------------------------------
# the heads — the first lines aif and the roles write on a card
# ---------------------------------------------------------------------------

# AIF_BOARD_HEADS — every first line aif or a role writes on a card, as one
# extended regex, in ONE place: a head is how the project manager, `aif board
# release` and whatever supervises a board route a card without reading its
# comments as prose, so a new head goes here before anything routes on it.
# Who writes each, and where:
#
#   blocked: ticket | run | environment | stopped — <why>
#               the worker, `_aif_work_block` in lib/cmd_work.sh — every way a
#               taken card leaves it short of Review, `aif work --stop` included
#   sync: <headline>
#               `_aif_land_requeue` in lib/cmd_land.sh — the land sending the
#               card back to the worker to be brought onto the branch it lands on
#   rework: <words>  ·  cancelled: <why>
#               the project manager (sets/claude/skills/aif-pjm/SKILL.md), from
#               a reviewer's wrong, a demo not as expected, a `blocked: ticket`
#               or the human's own words; cancelled when nothing will merge
#   wrong: <the first thing>  ·  cancel: <why>
#               the reviewer (sets/claude/skills/aif-review/SKILL.md)
#   land: <headline>
#               `_aif_land_fail` in lib/cmd_land.sh — a land undone after its merge
#   demo: as expected | not as expected — <…>
#               the product partner (sets/claude/skills/aif-po/SKILL.md)
#   released by aif land <ID>: …  ·  released by aif board release: …
#               `_aif_land_release` in lib/cmd_land.sh; `aif_release_sweep` in
#               lib/release.sh — a Backlog card whose dependencies are Done
#   taken: <host> pid <pid> at <time> — aif work
#               the worker's claim when it takes a card (lib/cmd_work.sh), so a
#               second machine on one board can tell a live worker from a
#               hand-drag (docs/DEFECTS.md 14.4); a claim, never a reason to route
#   # <ID> — built | stopped
#               the worker's run report (lib/cmd_work.sh, the note it posts on
#               the card it moves to Review or leaves)
#   # <ID> — landed | not landed
#               the land's note in lib/cmd_land.sh (`not landed` is the head
#               `land:` replaced; older cards still carry it)
#
# A reply a person writes under one of these is not a head, and is left out
# on purpose: see aif_board_last_line.
AIF_BOARD_HEADS='^(blocked: (ticket|run|environment|stopped) — |sync: |rework: |cancelled: |cancel: |wrong: |land: |demo: (as expected|not as expected)|released by aif |taken: |# [A-Za-z0-9-]+ — (built|stopped|landed|not landed))'

# aif_board_last_line <root> <ID> — the first line of the NEWEST comment whose
# first line matches AIF_BOARD_HEADS, on either backend. Prints it.
# rc 0 found · 1 no such comment · 2 the card could not be read, the reason on
# stderr as one bare line (no `error:`, no colour — a caller that captures
# `2>&1` gets just the why).
#
# The newest comment is the last on both backends — the local card appends,
# and the Trello adapter reverses the API's newest-first list — so they are
# walked newest first and the first match wins. A comment that matches no head
# is stepped over, not returned: a person's reply under aif's `blocked:` line
# is not the head, it is an answer to it — the "unblocked" signal of the
# research (docs/AUTOPILOT-RESEARCH.md §6.11, verification 3), for the human
# half to read; what bash routes on stays the last thing aif or a role said.
# Hence the closed set: the newest comment of any shape would make a question
# typed on the card the ticket's state.
aif_board_last_line() {
  local root="$1" id="$2" json line
  json="$(_aif_board_show_or_why "$root" "$id")" || return 2
  line="$(printf '%s' "$json" | jq -r --arg re "$AIF_BOARD_HEADS" '
    [ (.comments // []) | reverse[] | (.text // "") | split("\n")[0] | select(test($re)) ] | .[0] // empty' 2>/dev/null)" ||
    return 2
  [ -n "$line" ] || return 1
  printf '%s\n' "$line"
}

# _aif_board_show_or_why <root> <ID> — the card's show JSON on stdout; or rc 2
# and the reason on stderr as one bare line — no `error:`, no colour — which
# is what both head readers (aif_board_last_line, aif_board_head_json)
# promise their callers.
_aif_board_show_or_why() {
  local json esc
  json="$(aif_board_show_json "$1" "$2" 2>&1)" || {
    esc="$(printf '\033')"
    printf '%s\n' "$json" | sed -n 1p | sed "s/$esc\[[0-9;]*m//g; s/^error: //" >&2
    return 2
  }
  printf '%s\n' "$json"
}

# aif_board_head_json <root> <ID> — the head as a supervisor needs it, not
# only its line: rc 0 a head · 1 no head · 2 the card could not be read (the
# reason bare on stderr, as aif_board_last_line). On 0 and 1 it prints one
# compact object:
#
#   { line, at, body, after, heads: [ { line, at } ] }
#
# `line` is aif_board_last_line's (null when there is none); `at` its time,
# ISO UTC to the second on both backends (Trello's milliseconds taken off, so
# a time from one compares with a time from the other and with `date -u`);
# `body` the head comment's other lines; `after` how many comments came after
# it — a person's words under aif's line, the "answered" of
# docs/AUTOPILOT-RESEARCH.md §6.11 (with no head: every comment); `heads`
# every head on the card with its time, oldest first, which is what a reader
# needs to count blocks in a row or find the newest `taken:` — the line alone
# says only what happened last.
#
# On Trello the comments are the newest 20 (`_aif_trello_show_json` asks for
# no more): a head under twenty replies is not seen, and `heads` holds only
# what those 20 do.
aif_board_head_json() {
  local root="$1" id="$2" json out
  json="$(_aif_board_show_or_why "$root" "$id")" || return 2
  out="$(printf '%s' "$json" | jq -c --arg re "$AIF_BOARD_HEADS" '
    (.comments // []) as $c
    | [ range(0; $c | length) | select((($c[.].text // "") | split("\n")[0]) | test($re)) ] as $ix
    | ($ix | last) as $i
    | { line: (if $i == null then null else ($c[$i].text | split("\n")[0]) end),
        at: (if $i == null then null else (($c[$i].at // "") | sub("\\.[0-9]+Z$"; "Z")) end),
        body: (if $i == null then null else ($c[$i].text | split("\n")[1:] | join("\n")) end),
        after: (if $i == null then ($c | length) else (($c | length) - $i - 1) end),
        heads: [ $ix[] | { line: ($c[.].text | split("\n")[0]),
                           at: (($c[.].at // "") | sub("\\.[0-9]+Z$"; "Z")) } ] }' 2>/dev/null)" || {
    printf '%s\n' "the card's comments did not read as JSON" >&2
    return 2
  }
  printf '%s\n' "$out"
  # The object is built with `line` first, so a missing head is its opening.
  case "$out" in
    '{"line":null,'*) return 1 ;;
  esac
}

# aif_board_check <root> — is the board reachable, as configured? Prints one
# line per fact on stdout; rc 0 usable, 1 not.
#
# This is the `board` capability probe `aif doctor` reports per role, and what
# `aif work` runs before spending anything: a token is not "present", it is
# "one real call succeeded and the six columns exist".
aif_board_check() {
  local root="$1" kind
  kind="$(aif_board_kind "$root")"
  case "$kind" in
    local)
      printf 'board: local (%s)\n' "$(aif_board_local_dir "$root" | sed "s|^$(aif_main_root "$root")/||")"
      return 0
      ;;
    trello) ;;
    *)
      printf 'board: unknown kind "%s" in project.json — local or trello\n' "$kind"
      return 1
      ;;
  esac

  local cfg board missing="" name c out lists lid lname
  cfg="$(aif_project_config "$root")"
  for name in $(jq -r '[.board.key_secret, .board.secret] | .[] // empty' "$cfg"); do
    if [ -z "$(aif_secret_where "$name")" ]; then
      printf 'board: %s is not set — run in your terminal: aif secret set %s\n' "$name" "$name"
      missing=1
    fi
  done
  [ -z "$missing" ] || return 1

  board="$(_aif_trello_board "$root")"
  [ -n "$board" ] || {
    printf 'board: project.json board.board_id is empty — run: aif board init trello --board <id or url>\n'
    return 1
  }
  lists="$(_aif_trello_call "$root" GET "/boards/$board/lists" -G --data-urlencode "fields=name,closed")" || {
    printf 'board: Trello did not answer for board %s — %s\n' "$board" "$(printf '%s' "$lists" | head -1)"
    return 1
  }
  for c in $AIF_BOARD_COLUMNS; do
    lid="$(jq -r --arg c "$c" '.board.lists[$c] // empty' "$cfg")"
    if [ -z "$lid" ]; then
      printf 'board: column %s has no list — run: aif board init trello --board %s --create-lists\n' "$c" "$board"
      missing=1
      continue
    fi
    lname="$(printf '%s' "$lists" | jq -r --arg id "$lid" '[ .[] | select(.id == $id and (.closed | not)) ] | .[0].name // empty')"
    if [ -z "$lname" ]; then
      printf 'board: column %s points at list %s, which is not on the board (or is archived)\n' "$c" "$lid"
      missing=1
    fi
  done
  [ -z "$missing" ] || return 1
  printf 'board: trello %s — %s\n' "$board" \
    "$(printf '%s' "$lists" | jq -r --argjson l "$(jq -c '.board.lists' "$cfg")" \
      '[ ($l | to_entries[]) as $e | (.[] | select(.id == $e.value) | $e.key + "=" + .name) ] | join(", ")')"
  return 0
}

# aif_board_init <root> <kind> [<board id or url>] [<create-lists 0|1>]
#
# Writes project.json's board block. For trello it reads the board's lists,
# maps the six columns by name — Backlog, Ready, In Progress, Review, Done,
# Needs Human, with the obvious variants — and creates the missing ones only
# when told to. The mapping is printed, because a wrong mapping moves cards to
# the wrong column silently, and that is a thing to see once before it does.
aif_board_init() {
  local root="$1" kind="$2" board="${3:-}" create="${4:-0}" cfg tmp
  cfg="$(aif_project_config "$root")"
  [ -f "$cfg" ] || aif_die "no .aif/project.json — run 'aif project init' first"

  case "$kind" in
    local)
      tmp="$(aif_tmpfile "$cfg")"
      jq '.board = { kind: "local" }' "$cfg" >"$tmp" && mv "$tmp" "$cfg"
      printf '%sboard%s local — cards live in .aif/board/ on this machine (gitignored)\n' "$AIF_C_GREEN" "$AIF_C_RESET"
      return 0
      ;;
    trello) ;;
    *) aif_die "unknown board kind: $kind (local | trello)" ;;
  esac

  # A URL is the way a human has the id: https://trello.com/b/<shortLink>/<name>.
  case "$board" in
    http://* | https://*) board="$(printf '%s' "$board" | sed -E 's|^https?://[^/]+/b/([^/?#]+).*|\1|')" ;;
  esac
  [ -n "$board" ] || aif_die "usage: aif board init trello --board <id or url> [--create-lists]"

  # The secrets are named here and resolved on every call; the values are
  # never written anywhere by aif.
  tmp="$(aif_tmpfile "$cfg")"
  jq --arg b "$board" '.board = ((.board // {}) + { kind: "trello", board_id: $b,
      key_secret: (.board.key_secret // "TRELLO_KEY"), secret: (.board.secret // "TRELLO_TOKEN"),
      lists: (.board.lists // {}) })' "$cfg" >"$tmp" && mv "$tmp" "$cfg"

  local name
  for name in $(jq -r '[.board.key_secret, .board.secret] | .[]' "$cfg"); do
    [ -n "$(aif_secret_where "$name")" ] ||
      aif_die "$name is not set. Get an API key and token at https://trello.com/power-ups/admin, then run in your terminal: aif secret set $name"
  done

  local lists out c lid lname
  lists="$(_aif_trello_call "$root" GET "/boards/$board/lists" -G --data-urlencode "fields=name,closed")" ||
    aif_die "Trello did not answer for board $board — $(printf '%s' "$lists" | head -1). Check the id/URL and that the token can see this board."

  printf '%sboard%s trello %s\n' "$AIF_C_BOLD" "$AIF_C_RESET" "$board"
  for c in $AIF_BOARD_COLUMNS; do
    lid="$(printf '%s' "$lists" | jq -r --arg c "$c" '
      def norm: ascii_downcase | gsub("[^a-z]"; "");
      ($c | gsub("_"; "")) as $want
      | [ .[] | select(.closed | not)
          | select((.name | norm) as $n
              | $n == $want
                or ($want == "backlog" and ($n == "todo" or $n == "backlog"))
                or ($want == "inprogress" and ($n == "doing" or $n == "inprogress"))
                or ($want == "review" and ($n == "inreview" or $n == "review"))
                or ($want == "needshuman" and ($n == "needshuman" or $n == "blocked" or $n == "human"))) ]
      | .[0].id // empty')"
    if [ -z "$lid" ]; then
      if [ "$create" -eq 1 ]; then
        # Title-case by awk: BSD sed has no \u.
        lname="$(printf '%s' "$c" | tr '_' ' ' | awk '{ for (i = 1; i <= NF; i++) $i = toupper(substr($i, 1, 1)) substr($i, 2) } 1')"
        out="$(_aif_trello_call "$root" POST "/lists" --data-urlencode "name=$lname" \
          --data-urlencode "idBoard=$board" --data-urlencode "pos=bottom")" ||
          aif_die "could not create list $lname — $out"
        lid="$(printf '%s' "$out" | jq -r '.id')"
        printf '  %-12s → %s  %s(created)%s\n' "$c" "$lname" "$AIF_C_DIM" "$AIF_C_RESET"
      else
        printf '  %-12s → %smissing%s — no list named like it; pass --create-lists to add it\n' \
          "$c" "$AIF_C_YELLOW" "$AIF_C_RESET"
        continue
      fi
    else
      lname="$(printf '%s' "$lists" | jq -r --arg id "$lid" '.[] | select(.id == $id) | .name')"
      printf '  %-12s → %s\n' "$c" "$lname"
    fi
    tmp="$(aif_tmpfile "$cfg")"
    jq --arg c "$c" --arg id "$lid" '.board.lists[$c] = $id' "$cfg" >"$tmp" && mv "$tmp" "$cfg"
  done

  if ! aif_board_check "$root" >/dev/null 2>&1; then
    printf '\n'
    aif_board_check "$root" | sed 's/^/  /' >&2
    aif_die "the board is not usable yet — see above"
  fi
  printf '%swrote%s .aif/project.json board block\n' "$AIF_C_GREEN" "$AIF_C_RESET"
}
