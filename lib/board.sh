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
# project manager was reordering the queue quickly (docs/DEFECTS-3.md #12).
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
# so they are in no URL, no shell history and no log line. -f turns an HTTP
# error into a non-zero exit; the caller decides what that means.
_aif_trello_call() {
  local root="$1" method="$2" path="$3" key token base
  shift 3
  key="$(_aif_trello_secret "$root" key_secret)" || return 3
  token="$(_aif_trello_secret "$root" secret)" || return 3
  base="${AIF_TRELLO_API:-$AIF_TRELLO_API_DEFAULT}"
  curl -sS -f -X "$method" "$base$path" \
    -H "Authorization: OAuth oauth_consumer_key=\"$key\", oauth_token=\"$token\"" \
    -H "Accept: application/json" \
    "$@" 2>&1
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
    "$(aif_project_config "$1")" 2>/dev/null | head -1
}

# _aif_trello_find_card <root> <ID> — the card JSON, or rc 1.
_aif_trello_find_card() {
  local root="$1" id="$2" board out
  board="$(_aif_trello_board "$root")"
  [ -n "$board" ] || aif_die "project.json board.board_id is empty — run: aif board init trello"
  out="$(_aif_trello_call "$root" GET "/boards/$board/cards" -G \
    --data-urlencode "fields=name,idList,pos,desc,shortUrl,idLabels")" ||
    aif_die "Trello: could not list the board's cards — $out"
  printf '%s' "$out" | jq -e --arg id "$id" \
    '[ .[] | select(.name | test("^" + $id + "([^A-Za-z0-9-]|$)")) ] | .[0] // empty' 2>/dev/null |
    grep -q . || return 1
  printf '%s' "$out" | jq -c --arg id "$id" \
    '[ .[] | select(.name | test("^" + $id + "([^A-Za-z0-9-]|$)")) ] | .[0]'
}

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
    grep -oE "^$re" | head -1
}

# _aif_trello_pull <root> <ID> — the card's description becomes ticket.md.
#
# The board is canonical for the text until intake: what the analyst wrote (or
# the human edited) on the card is what gets built. Written into THIS
# checkout's tasks/ — the worker calls this from its worktree.
_aif_trello_pull() {
  local root="$1" id="$2" card work
  card="$(_aif_trello_require_card "$root" "$id")"
  work="$(aif_task_dir "$root" "$id")"
  mkdir -p "$work"
  # -j, not -r: the description is the file's bytes and the file's bytes are
  # what gets hashed; a newline jq adds on output is a hash that does not match.
  # tr -d '\r': Trello's editor can hand back \r\n, and the file written here is
  # the bytes the run hashes and the bytes `board create` pushes back — LF, so a
  # round trip does not change them (docs/DEFECTS-3.md #10).
  printf '%s' "$card" | jq -j '.desc' | tr -d '\r' >"$work/ticket.md.tmp"
  if ! grep -q '^<!-- aif:meta$' "$work/ticket.md.tmp"; then
    rm -f "$work/ticket.md.tmp"
    aif_die "the card $id has no aif:meta block in its description — it was not written by the analyst (/aif-ba)"
  fi
  mv "$work/ticket.md.tmp" "$work/ticket.md"
  [ -f "$(aif_ledger_path "$work")" ] || aif_ledger_init "$work" "$id"
  printf 'pulled %s → %s/%s/ticket.md (%s bytes)\n' "$id" "$AIF_TASKS_DIR" "$id" \
    "$(wc -c <"$work/ticket.md" | tr -d ' ')"
}

_aif_trello_move() {
  local root="$1" id="$2" col="$3" where="${4:-}" card cid list out
  card="$(_aif_trello_require_card "$root" "$id")"
  cid="$(printf '%s' "$card" | jq -r '.id')"
  list="$(_aif_trello_list_id "$root" "$col")"
  [ -n "$list" ] || aif_die "project.json board.lists.$col is empty — run: aif board init trello"
  out="$(_aif_trello_call "$root" PUT "/cards/$cid" --data-urlencode "idList=$list" \
    --data-urlencode "pos=${where:-bottom}")" ||
    aif_die "Trello: could not move $id — $out"
  printf 'moved %s → %s\n' "$id" "$col"
}

_aif_trello_comment() {
  local root="$1" id="$2" file="$3" card cid out tmp
  card="$(_aif_trello_require_card "$root" "$id")"
  cid="$(printf '%s' "$card" | jq -r '.id')"
  # Trello caps a comment at 16384 characters. Cut, and say where the rest is,
  # rather than fail after the work is done.
  tmp="$(mktemp "${TMPDIR:-/tmp}/aif-comment-XXXXXX")"
  if [ "$(wc -c <"$file" | tr -d ' ')" -gt 16000 ]; then
    head -c 15800 "$file" >"$tmp"
    printf '\n\n_(truncated — the full report is %s on the branch)_\n' "${file#"$root"/}" >>"$tmp"
  else
    cp "$file" "$tmp"
  fi
  out="$(_aif_trello_call "$root" POST "/cards/$cid/actions/comments" --data-urlencode "text@$tmp")"
  local rc=$?
  rm -f "$tmp"
  [ "$rc" -eq 0 ] || aif_die "Trello: could not comment on $id — $out"
  printf 'commented on %s (%s bytes)\n' "$id" "$(wc -c <"$file" | tr -d ' ')"
}

# _aif_trello_create <root> <ticket.md> <column> — a card, or the existing
# card's description brought up to date. The description IS the ticket file,
# aif:meta block and all: that is what `pull` reads back at intake.
_aif_trello_create() {
  local root="$1" ticket="$2" col="$3" id title list card cid out
  id="$(_aif_board_ticket_id "$ticket")"
  [ -n "$id" ] || aif_die "$ticket has no aif:meta ticket id"
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

_aif_trello_show_json() {
  local root="$1" id="$2" card cid comments col
  card="$(_aif_trello_require_card "$root" "$id")"
  cid="$(printf '%s' "$card" | jq -r '.id')"
  col="$(_aif_trello_column_of_list "$root" "$(printf '%s' "$card" | jq -r '.idList')")"
  comments="$(_aif_trello_call "$root" GET "/cards/$cid/actions" -G \
    --data-urlencode "filter=commentCard" --data-urlencode "limit=20")" || comments="[]"
  printf '%s' "$card" | jq --arg col "${col:-other}" --argjson c "$comments" '
    { ticket: (.name | split(" ")[0]), title: (.name | sub("^[^ ]+ *[—:-]+ *"; "")),
      column: $col, url: .shortUrl, description: .desc,
      comments: [ $c[] | { at: .date, by: (.memberCreator.username // .memberCreator.fullName // "?"),
                           text: .data.text } ] | reverse }'
}

_aif_trello_label() {
  local root="$1" id="$2" label="$3" card cid board labels lid out
  card="$(_aif_trello_require_card "$root" "$id")"
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
aif_board_pull() { "_aif_board_$(aif_board_kind "$1")_pull" "$1" "$2"; }
aif_board_move() { "_aif_board_$(aif_board_kind "$1")_move" "$1" "$2" "$3" "${4:-}"; }
aif_board_comment() { "_aif_board_$(aif_board_kind "$1")_comment" "$1" "$2" "$3"; }
aif_board_create() { "_aif_board_$(aif_board_kind "$1")_create" "$1" "$2" "$3"; }
aif_board_status_json() { "_aif_board_$(aif_board_kind "$1")_status_json" "$1"; }
aif_board_show_json() { "_aif_board_$(aif_board_kind "$1")_show_json" "$1" "$2"; }
aif_board_label() { "_aif_board_$(aif_board_kind "$1")_label" "$1" "$2" "$3"; }

# The trello functions are named _aif_trello_*; alias them under the interface's
# naming so the dispatch above is one line per operation.
_aif_board_trello_next_ready() { _aif_trello_next_ready "$@"; }
_aif_board_trello_pull() { _aif_trello_pull "$@"; }
_aif_board_trello_move() { _aif_trello_move "$@"; }
_aif_board_trello_comment() { _aif_trello_comment "$@"; }
_aif_board_trello_create() { _aif_trello_create "$@"; }
_aif_board_trello_status_json() { _aif_trello_status_json "$@"; }
_aif_board_trello_show_json() { _aif_trello_show_json "$@"; }
_aif_board_trello_label() { _aif_trello_label "$@"; }

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
