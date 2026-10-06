#!/usr/bin/env bash
#
# scripts/check-board.sh — the board adapter, both backends, and the secrets
# store, OFFLINE.
#
# The board is the coupling between the analyst, the worker and the project
# manager, so every transition in the pipeline goes through `aif board`. This
# drives the adapter against the local backend and against a stand-in Trello
# (scripts/mock-trello.py, an HTTP server that answers the handful of endpoints
# lib/board.sh calls), then drives `aif work` through it with the scripted
# runner from check-work.sh. What it proves:
#
#   1  secrets: set with echo off or --stdin, never on the command line; the
#      file is 0600; the environment overrides the store; the CLI never prints
#      a value
#   2  the local board: create/move/next-ready/comment/show/label/status, and a
#      move made from inside a worktree lands on the developer's board; head
#      is the first line of the newest comment aif or a role wrote — under a
#      person's reply — and nothing, exit 1, on a card with only theirs
#   3  trello: init maps the columns it can and creates the rest only when
#      told; check refuses a missing token loudly; create writes the ticket as
#      the card's description and pull reads it back byte for byte; a card the
#      analyst did not write is refused at pull; comment, label, status, show,
#      head; a comment is held to Trello's 16384 characters counted as Trello
#      counts them — a Ukrainian one that fits by characters is posted whole, a
#      longer one is cut on a letter, saying where the whole text is
#      (DEFECTS.md 10.1); through the mock's fault file, a comments read that
#      fails three times is a loud failure, not a card with no comment (14.7),
#      a 429 or a 5xx on a GET is retried and the answer is as before, and a
#      503 on a comment's POST is one attempt (13.8); a card's column is read
#      without its comments: `aif work <ID> --stop` on a worker that is gone
#      settles its card under that same failing comments read, and keeps the
#      lock when the board cannot be read at all
#   4  doctor reports per role what is missing, and stops saying "not ready"
#      the moment the token is set
#   5  the worker pulls the next Ready card, moves it through In Progress to
#      Review with the report as a comment, and to Needs Human when the ticket
#      is not ready; when the board refuses the comment, it says the report is
#      not on the card, and the command it prints posts it once the board
#      answers; a land whose comments read fails lands from the card's column,
#      and one whose board cannot say where the card is exits 3, nothing landed
#
# Run by `make check`. Requires git, jq, curl and python3.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
AIF="$ROOT/bin/aif"

for tool in git jq curl python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'check-board: %s not found — cannot run\n' "$tool"
    exit 1
  }
done

fails=0
ok() { printf '  ✓ %s\n' "$1"; }
bad() {
  printf '  ✗ %s\n' "$1"
  fails=$((fails + 1))
}
eq() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2', wanted '$3'"; fi
}

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/aif-board-XXXXXX")"
OUT="$SANDBOX/out"
mkdir -p "$OUT"
printf '\nboard, offline (sandbox: %s)\n' "$SANDBOX"

# Never the developer's real keychain.
export AIF_SECRETS_DIR="$SANDBOX/secrets"
# The worker scenarios run --no-worktree, which is refused unless the checkout
# is declared disposable. These sandboxes are.
export AIF_DISPOSABLE=1
# The adapter sleeps between its retries — Retry-After when the server names
# one, else 1, 3, 7 seconds (lib/board.sh, docs/DEFECTS.md 13.8). The faults
# the mock serves below are the retry path's whole point, and every one of
# those sleeps would be this check waiting for nothing.
export AIF_TRELLO_RETRY_SLEEP="0 0 0"
# The mock's fault file: `fault <code> <count> [<path-substring>]` writes the
# one line scripts/mock-trello.py reads on every request, and the mock answers
# <code> that many times to the requests whose path has the substring, then
# removes the file — so its absence after a command says every fault was met.
FAULT="$SANDBOX/mock.fault"
fault() { printf '%s\n' "$*" >"$FAULT"; }

MOCK_PID=""
cleanup() { [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null; }
trap cleanup EXIT

fresh_project() {
  mkdir -p "$1" && cd "$1" || exit 1
  git init -q
  git config user.email board@aif
  git config user.name "Board"
  mkdir -p src tests
  printf 'def users():\n    return []\n' >src/app.py
  printf '# a pre-existing, green test\n' >tests/t0.py
  git add -A && git commit -qm init >/dev/null
  "$AIF" init anthropic >/dev/null 2>&1 || {
    printf 'check-board: aif init failed — cannot continue\n'
    exit 1
  }
  "$AIF" project init pytest --no-checks >/dev/null 2>&1
  cat >.aif/suite.sh <<'SUITE'
#!/bin/bash
mkdir -p .aif/tmp
row() { if [ "$3" = 1 ]; then printf '<testcase name="%s" file="%s"/>' "$1" "$2"
  else printf '<testcase name="%s" file="%s"><failure message="assert marker missing">AssertionError: assert marker missing</failure></testcase>' "$1" "$2"; fi; }
body="$(row t0 tests/t0.py 1)"
# The test is named with its marker, `<ticket> AC-001`, read off the first
# line the fake tests station writes: verify-red looks for the marker in a
# collected test's id, not in the file's text.
if [ -f tests/t1.py ]; then g=0; grep -q impl1 src/app.py 2>/dev/null && g=1; body="$body$(row "$(sed -n '1s/^# \([A-Z0-9-]* AC-[0-9]*\).*/\1/p' tests/t1.py) t1" tests/t1.py "$g")"; fi
printf '<testsuites><testsuite>%s</testsuite></testsuites>' "$body" > .aif/tmp/report.xml
SUITE
  chmod +x .aif/suite.sh
  local tmp
  tmp="$(mktemp)"
  jq '.test.command = "bash .aif/suite.sh" | .test.roots = ["tests"] | .test.report.path = ".aif/tmp/report.xml"' \
    .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
  # The worker requires the project's guide to its tests (test-guide), and
  # reads it from the branch: written here, committed with the rest.
  "$AIF" project guide >/dev/null 2>&1 || {
    printf 'check-board: aif project guide failed — cannot continue\n'
    exit 1
  }
  git add -A && git commit -qm "aif init" >/dev/null
}

ticket_for() { # <id> [open-json]
  "$AIF" _ticket-init "$1" >/dev/null 2>&1 || true
  mkdir -p "tasks/$1"
  cat >"tasks/$1/ticket.md" <<TICKET
<!-- aif:meta
{ "schema": 2, "ticket": "$1", "lang": "en", "risk": "low",
  "surfaces": ["export"],
  "acceptance": [
    { "id": "AC-001", "surface": "export",
      "given": "users exist", "when": "the export runs",
      "then": "writes the marker", "expect": "impl1" } ],
  "open": ${2:-[]},
  "decided": [ { "question": "may the export be deferred?", "answer": "no", "by": "default" } ],
  "verification_gaps": [],
  "non_goals": [] }
-->
# $1 — one-command user export

Support needs a one-command export of the user list.
TICKET
}

# The scripted runner from check-work.sh, trimmed to the four stations.
cat >"$SANDBOX/fake-station.sh" <<'FAKE'
#!/bin/bash
set -u
station="$1" ticket="$2" wt="$3" prompt="$5" out="${10}"
work="$wt/tasks/$ticket"
bind() { printf '%s\n' "$prompt" | awk -v k="$1" '$1 == k":" { print $2; exit }'; }
case "$station" in
  plan)
    cat >"$work/plan.md" <<PLAN
<!-- aif:meta
{ "schema": 3, "ticket": "$ticket", "ticket_sha256": "$(bind ticket_sha256)", "risk": "low",
  "files": { "create": [], "change": ["src/app.py"], "tests": ["tests/t1.py"] },
  "no_skeleton": [], "verdicts": { "AC-001": { "verdict": "buildable" } },
  "decisions": [ { "id": "D-001", "statement": "Write the marker from the app module.",
      "because": "AC-001 is about the app's own output", "serves": ["AC-001"] } ],
  "ac_coverage": { "AC-001": ["src/app.py"] }, "uncovered": [],
  "surface_map": { "export": ["src/app.py"] }, "external": [] }
-->
# $ticket — plan
PLAN
    ;;
  plan-judge)
    jq -n --arg s "$(bind subject_sha256)" '{schema:1,gate:"plan-judge",subject:"plan.md",subject_sha256:$s,
      judge_agent:"aif-plan-judge",at:"t",guesses:[],missing_files:[]}' >"$work/verdict-plan.json" ;;
  tests) printf '# %s AC-001 asserts impl1\n' "$ticket" >"$wt/tests/t1.py" ;;
  implement) printf 'def users():\n    return []  # impl1\n' >"$wt/src/app.py" ;;
esac
jq -n --arg st "$station" '{type:"result",subtype:"success",is_error:false,result:("fake " + $st),
  num_turns:1,total_cost_usd:0.01,duration_ms:1,
  usage:{input_tokens:1,output_tokens:2,cache_read_input_tokens:0,cache_creation_input_tokens:0},
  modelUsage:{"fake-model":{}}}' >"$out"
FAKE
chmod +x "$SANDBOX/fake-station.sh"
export AIF_WORK_STATION_CMD="$SANDBOX/fake-station.sh"

# =============================== 1. secrets ==================================
printf '\n1. secrets — never through a model, never on a command line\n'
fresh_project "$SANDBOX/p1"
rc=0
printf 'tok-123\n' | "$AIF" secret set TEST_TOKEN --stdin >/dev/null 2>&1 || rc=$?
eq "set via --stdin" "$rc" "0"
eq "check says set (file)" "$("$AIF" secret check TEST_TOKEN 2>/dev/null | grep -c '(file)')" "1"
eq "the file is 0600" "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$AIF_SECRETS_DIR/TEST_TOKEN")" "0o600"
eq "list names it, and nothing else" "$("$AIF" secret list)" "TEST_TOKEN"
rc=0
"$AIF" secret set OTHER hunter2 >/dev/null 2>&1 || rc=$?
eq "a value on the command line is refused" "$rc" "1"
eq "the CLI has no way to print a value" "$("$AIF" secret get TEST_TOKEN >/dev/null 2>&1; echo $?)" "1"
eq "the environment overrides the store" "$(TEST_TOKEN=from-env "$AIF" secret check TEST_TOKEN 2>/dev/null | grep -c '(env)')" "1"
"$AIF" secret rm TEST_TOKEN >/dev/null 2>&1
rc=0
"$AIF" secret check TEST_TOKEN >/dev/null 2>&1 || rc=$?
eq "rm forgets it" "$rc" "1"

# =============================== 2. local ====================================
printf '\n2. the local board\n'
fresh_project "$SANDBOX/p2"
ticket_for AIF-1
eq "the default board is local" "$("$AIF" board check 2>&1 | grep -c 'local')" "1"
eq "create → backlog" "$("$AIF" board create tasks/AIF-1/ticket.md 2>&1)" "created AIF-1 (one-command user export) → backlog"
eq "nothing is ready yet" "$("$AIF" board next-ready)" ""
"$AIF" board move AIF-1 ready >/dev/null
eq "next-ready" "$("$AIF" board next-ready)" "AIF-1"
ticket_for AIF-2
"$AIF" board create tasks/AIF-2/ticket.md --column ready >/dev/null
"$AIF" board move AIF-2 ready --top >/dev/null
eq "--top reorders Ready, and next-ready follows" "$("$AIF" board next-ready)" "AIF-2"
printf 'the export must be signed\n' >"$OUT/note.md"
"$AIF" board comment AIF-1 "$OUT/note.md" >/dev/null
eq "a comment is on the card" "$("$AIF" board show AIF-1 --json | jq -r '.comments | length')" "1"
eq "and show prints it" "$("$AIF" board show AIF-1 | grep -c 'must be signed')" "1"
# The line a shell routes on: the first line of the newest comment aif or a
# role wrote (AIF_BOARD_HEADS, lib/board.sh). A person's comment is not one —
# with only theirs the card has no head — and their reply under aif's line is
# an answer to it, not the head (docs/AUTOPILOT-RESEARCH.md §6.11,
# verification 3), so the blocked: line is what comes back.
rc=0
"$AIF" board head AIF-1 >"$OUT/head-local1.out" 2>&1 || rc=$?
eq "head on a card with only a person's comment: nothing, exit 1" "$rc,$(wc -c <"$OUT/head-local1.out" | tr -d ' ')" "1,0"
printf '%s\n\n%s\n' "blocked: ticket — not ready — the ready gate's questions are below, for the analyst" "- Q-001 signed? (default: no)" >"$OUT/blocked.md"
"$AIF" board comment AIF-1 "$OUT/blocked.md" >/dev/null
printf 'yes, signed — I will move it back to Ready\n' >"$OUT/reply.md"
"$AIF" board comment AIF-1 "$OUT/reply.md" >/dev/null
eq "head is the blocked: line, under the person's reply" "$("$AIF" board head AIF-1)" "blocked: ticket — not ready — the ready gate's questions are below, for the analyst"
rc=0
"$AIF" board head AIF-9 >/dev/null 2>"$OUT/head-local9.err" || rc=$?
eq "head on a card that is not there: exit 2, the board's problem, named" "$rc,$(grep -c "could not read AIF-9's comments" "$OUT/head-local9.err")" "2,1"
"$AIF" board label AIF-1 blocked >/dev/null
eq "a label is on the card" "$("$AIF" board status --json | jq -r '.[] | select(.ticket == "AIF-1") | .labels[0]')" "blocked"
eq "status renders every card" "$("$AIF" board status | grep -cE '^  (ready|backlog) ')" "2"
git worktree add -q "$SANDBOX/p2-wt" -b wt-branch >/dev/null 2>&1
(cd "$SANDBOX/p2-wt" && "$AIF" board move AIF-1 review >/dev/null)
eq "a move from a worktree lands on the main board" \
  "$("$AIF" board status --json | jq -r '.[] | select(.ticket == "AIF-1") | .column')" "review"
eq "the board dir is ignored by git" "$(git status --porcelain | grep -c 'board')" "0"
eq "a card that does not exist is a clear error" "$("$AIF" board move AIF-9 "done" 2>&1 | grep -c 'no card for AIF-9')" "1"
# Ordering was `date +%s`: three moves inside one second tied on pos, and the
# tie went to whatever order the glob returned. Now a plain move goes strictly
# below every card and --top strictly above, whatever the clock says.
ticket_for AIF-3
"$AIF" board create tasks/AIF-3/ticket.md >/dev/null
ticket_for AIF-4
"$AIF" board create tasks/AIF-4/ticket.md >/dev/null
"$AIF" board move AIF-2 backlog >/dev/null
"$AIF" board move AIF-3 ready >/dev/null
"$AIF" board move AIF-4 ready >/dev/null
"$AIF" board move AIF-2 ready >/dev/null
eq "three moves in one second: the first moved is first in Ready" "$("$AIF" board next-ready)" "AIF-3"
"$AIF" board move AIF-2 ready --top >/dev/null
eq "--top still wins" "$("$AIF" board next-ready)" "AIF-2"
"$AIF" board move AIF-2 ready >/dev/null
eq "and a plain move goes to the bottom, behind the other two" "$("$AIF" board next-ready)" "AIF-3"
eq "every pos is distinct" \
  "$("$AIF" board status --json | jq -r '[.[].pos] | (length == (unique | length))')" "true"

# =============================== 3. trello ===================================
printf '\n3. trello, against a stand-in server\n'
MOCK_FAULT_FILE="$FAULT" python3 "$ROOT/scripts/mock-trello.py" 0 >"$OUT/mock.port" 2>"$OUT/mock.err" &
MOCK_PID=$!
i=0
while [ ! -s "$OUT/mock.port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
PORT="$(head -1 "$OUT/mock.port")"
[ -n "$PORT" ] || { bad "the mock server did not start ($(head -2 "$OUT/mock.err"))"; exit 1; }
export AIF_TRELLO_API="http://127.0.0.1:$PORT/1"
mock() { curl -s "http://127.0.0.1:$PORT/_state"; }

fresh_project "$SANDBOX/p3"
ticket_for AIF-1
export TRELLO_KEY=k TRELLO_TOKEN=t

rc=0
"$AIF" board init trello --board b1 >"$OUT/init1.out" 2>&1 || rc=$?
eq "init without --create-lists reports what is missing and stops" "$rc" "1"
eq "four columns missing (two mapped by name)" "$(grep -c 'missing' "$OUT/init1.out")" "4"
rc=0
"$AIF" board init trello --board "https://trello.com/b/b1/mock" --create-lists >"$OUT/init2.out" 2>&1 || rc=$?
eq "init --create-lists from the board URL" "$rc" "0"
eq "six columns mapped in project.json" "$(jq '.board.lists | length' .aif/project.json)" "6"
eq "the mock now has six lists" "$(mock | jq '.lists | length')" "6"
eq "Backlog was mapped, not duplicated" "$(mock | jq '[.lists[] | select(.name == "Backlog")] | length')" "1"
eq "project.json still validates" "$("$AIF" project check >/dev/null 2>&1; echo $?)" "0"
eq "board check is green" "$("$AIF" board check >/dev/null 2>&1; echo $?)" "0"

eq "create → a card in Backlog" "$("$AIF" board create tasks/AIF-1/ticket.md 2>&1 | grep -c '^created AIF-1')" "1"
eq "the card's name carries the id and the title" "$(mock | jq -r '.cards[] | .name')" "AIF-1 — one-command user export"
mock | jq -j '.cards[] | .desc' >"$OUT/desc.md"
if cmp -s "$OUT/desc.md" tasks/AIF-1/ticket.md; then ok "the description IS the ticket file"; else bad "description differs from ticket.md"; fi
"$AIF" board move AIF-1 ready >/dev/null
eq "next-ready reads the Ready list" "$("$AIF" board next-ready)" "AIF-1"
cp tasks/AIF-1/ticket.md "$OUT/orig.md"
rm -rf tasks/AIF-1
"$AIF" board pull AIF-1 >/dev/null
if cmp -s "$OUT/orig.md" tasks/AIF-1/ticket.md; then ok "pull reads the card back byte for byte"; else bad "pull changed the ticket"; fi
# No ledger: the worker makes one at intake, in the worktree it pulls into —
# one made here, in the developer's checkout, met the branch's at land
# (docs/DEFECTS.md 13.2).
eq "pull writes the ticket and no ledger" "$(test -f tasks/AIF-1/ledger.json && echo yes || echo no)" "no"
"$AIF" board comment AIF-1 "$OUT/note.md" >/dev/null
eq "the comment reached the server" "$(mock | jq -r '[.comments[][]] | .[0].data.text')" "the export must be signed"
eq "show lists it" "$("$AIF" board show AIF-1 --json | jq -r '.comments[0].text')" "the export must be signed"
rc=0
"$AIF" board head AIF-1 >"$OUT/head-mock1.out" 2>&1 || rc=$?
eq "trello: head on a card with only a person's comment: nothing, exit 1" "$rc,$(wc -c <"$OUT/head-mock1.out" | tr -d ' ')" "1,0"
"$AIF" board comment AIF-1 "$OUT/blocked.md" >/dev/null
"$AIF" board comment AIF-1 "$OUT/reply.md" >/dev/null
eq "trello: head is the blocked: line, under the person's reply" "$("$AIF" board head AIF-1)" "blocked: ticket — not ready — the ready gate's questions are below, for the analyst"

# A comment in Ukrainian, two bytes a letter (docs/DEFECTS.md 10.1). The cut
# counted bytes: anything over 16000 was cut at byte 15800 — through a letter,
# though it was far under Trello's 16384 characters — and Trello, as the mock
# does now, refused the malformed text with a 400. Now: whole when it fits by
# characters, else cut on a character, counted the way Trello counts them.
python3 - "$OUT/uk-fits.md" "$OUT/uk-long.md" "$OUT/emoji.md" <<'PY3'
import sys
line = "Звіт про збірку: критерій виконано, тести зелені.\n"
open(sys.argv[1], "w", encoding="utf-8").write(line * 240)
open(sys.argv[2], "w", encoding="utf-8").write(line * 400)
open(sys.argv[3], "w", encoding="utf-8").write("\U0001F680" * 9000)
PY3
chars() { python3 -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8").read()))' "$1"; }
posted() { # <ID> — the card's last comment, as the server holds it
  mock | jq -j --arg n "$1 " '[.cards[] | select(.name | startswith($n)) | .id][0] as $c | .comments[$c] | last | .data.text'
}
rc=0
"$AIF" board comment AIF-1 "$OUT/uk-fits.md" >"$OUT/uk-fits.out" 2>&1 || rc=$?
posted AIF-1 >"$OUT/uk-fits.posted"
eq "Ukrainian, $(wc -c <"$OUT/uk-fits.md" | tr -d ' ') bytes in $(chars "$OUT/uk-fits.md") characters: posted whole" \
  "$rc,$(cmp -s "$OUT/uk-fits.posted" "$OUT/uk-fits.md" && echo whole || echo cut)" "0,whole"
rc=0
"$AIF" board comment AIF-1 "$OUT/uk-long.md" >"$OUT/uk-long.out" 2>&1 || rc=$?
posted AIF-1 >"$OUT/uk-long.posted"
eq "Ukrainian, $(chars "$OUT/uk-long.md") characters: taken by the board, cut on a letter near the limit, saying so" \
  "$rc,$(python3 -c '
import sys
a = open(sys.argv[1], encoding="utf-8").read()
b = open(sys.argv[2], encoding="utf-8").read()
i = b.find("\n\n_(cut to fit a Trello comment — the whole text is ")
print(int(i > 16000 and a.startswith(b[:i]) and len(b.encode("utf-16-le")) // 2 <= 16384))' "$OUT/uk-long.md" "$OUT/uk-long.posted")" "0,1"
rc=0
"$AIF" board comment AIF-1 "$OUT/emoji.md" >"$OUT/emoji.out" 2>&1 || rc=$?
eq "9000 emoji are 18000 of Trello's characters: cut to fit, two to an emoji" \
  "$rc,$(posted AIF-1 | python3 -c 'import sys; n = sys.stdin.read().count("\U0001F680"); print(int(8000 < n <= 8192))')" "0,1"
"$AIF" board label AIF-1 blocked >/dev/null
eq "label created on the board and attached" "$(mock | jq '(.labels | length), (.cards[] | .idLabels | length)' | tr '\n' ',')" "1,1,"
eq "status maps lists back to columns" "$("$AIF" board status --json | jq -r '.[0].column')" "ready"
sed -i.bak 's/one-command user export/one-command user EXPORT/' tasks/AIF-1/ticket.md && rm -f tasks/AIF-1/ticket.md.bak
eq "create on an existing card updates it" "$("$AIF" board create tasks/AIF-1/ticket.md --column ready 2>&1 | grep -c '^updated AIF-1')" "1"
eq "still one card" "$(mock | jq '.cards | length')" "1"
eq "with the new text" "$(mock | jq -r '.cards[] | .desc' | grep -c 'user EXPORT')" "1"
ticket_for AIF-2
"$AIF" board create tasks/AIF-2/ticket.md --column ready >/dev/null
"$AIF" board move AIF-2 ready --top >/dev/null
eq "--top on trello, and next-ready follows" "$("$AIF" board next-ready)" "AIF-2"
curl -s -X POST "$AIF_TRELLO_API/cards" -H 'Authorization: OAuth oauth_consumer_key="k", oauth_token="t"' \
  --data-urlencode "idList=$(jq -r '.board.lists.ready' .aif/project.json)" \
  --data-urlencode "name=AIF-9 — written by hand" --data-urlencode "desc=just a sentence" >/dev/null
eq "a card the analyst did not write is refused at pull" "$("$AIF" board pull AIF-9 2>&1 | grep -c 'no aif:meta')" "1"
# A ticket over Trello's description limit (docs/DEFECTS.md 10.2). On a Trello
# board the ticket IS the card's description, and Trello holds that to 16384
# characters counted as JavaScript counts them; one over it passed the ready
# gate and was refused by the board with a bare 400. Now the ready gate says so
# on a Trello project, with the count, and create refuses before sending.
ticket_for AIF-8
python3 - tasks/AIF-8/ticket.md <<'PY3'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(s + "Довгий опис потреби, рядок за рядком, щоб картка не вмістила тікет цілком.\n" * 300)
PY3
rc=0
"$AIF" _ready AIF-8 >"$OUT/ready8.out" 2>&1 || rc=$?
eq "a ticket over 16384 characters fails the ready gate on a Trello project, with the count and what to cut" \
  "$rc,$(grep -c 'characters, and a Trello card.s description holds 16384' "$OUT/ready8.out"),$(grep -c 'to go, counted as Trello counts' "$OUT/ready8.out")" "1,1,1"
rc=0
"$AIF" board create tasks/AIF-8/ticket.md --column ready >"$OUT/create8.out" 2>&1 || rc=$?
eq "create refuses it before sending, with the count and the limit; no card was made" \
  "$rc,$(grep -c 'description holds 16384' "$OUT/create8.out"),$(mock | jq '[.cards[] | select(.name | startswith("AIF-8 "))] | length')" "1,1,0"
eq "a ticket under the limit still passes the gate here" "$("$AIF" _ready AIF-1 >/dev/null 2>&1; echo $?)" "0"

# A card whose description outgrows a pipe buffer. The finder used to pipe a
# pretty-printed jq into `grep -q .`: grep left at the opening brace, jq took
# SIGPIPE on the rest of the description, pipefail made that 141, and the card
# read as absent — only for tickets long enough to be worth building, and only
# for show/move/comment/pull, so status went on listing a card the worker could
# not find (docs/DEFECTS.md 5.1). 76 KiB of ticket here, past any buffer — a
# description no real board would hold since the limit above, so the mock's
# limit is lifted for this one card, and aif's own refusal stepped around:
# the card is made the way a hand-written one is, and what is checked is the
# finder reading it back.
ticket_for AIF-5
{ i=0; while [ "$i" -lt 900 ]; do
    printf 'Line %04d of a long ticket body, padding the description well past the pipe buffer.\n' "$i"
    i=$((i + 1))
  done; } >>tasks/AIF-5/ticket.md
curl -s "http://127.0.0.1:$PORT/_desc/limit/off" >/dev/null
curl -s -X POST "$AIF_TRELLO_API/cards" -H 'Authorization: OAuth oauth_consumer_key="k", oauth_token="t"' \
  --data-urlencode "idList=$(jq -r '.board.lists.ready' .aif/project.json)" \
  --data-urlencode "name=AIF-5 — one-command user export" --data-urlencode "desc@tasks/AIF-5/ticket.md" >/dev/null
curl -s "http://127.0.0.1:$PORT/_desc/limit/on" >/dev/null
eq "a 76 KiB card exists on the mock" "$(mock | jq '[.cards[] | select(.name | startswith("AIF-5 "))] | length')" "1"
eq "with the whole description on it" \
  "$(mock | jq -r '[.cards[] | select(.name | startswith("AIF-5")) | .desc | length] | .[0] > 65536')" "true"
eq "show finds it" "$("$AIF" board show AIF-5 --json | jq -r .ticket)" "AIF-5"
eq "move finds it" "$("$AIF" board move AIF-5 in_progress 2>&1)" "moved AIF-5 → in_progress"

# A board that misbehaves (docs/DEFECTS.md 13.8, 14.7). The adapter retries a
# GET or a PUT on a 429 or a 5xx — at most three attempts, Retry-After or its
# own list between them — and a POST never: a comment whose first attempt
# landed and whose answer was lost would be the card's record twice. And a
# comments read that fails for good used to come back as `[]`, a card with
# nothing to say, which every routing decision downstream read as one. The
# mock's fault file is how each is met here; the request log counts the
# attempts, and the file's absence afterwards says every fault was served.
printf '  · faults from the mock: a 500 three times, a 429 once, a 503 on a POST\n'
actions_gets() { mock | jq '[.log[] | select(test("^GET /1/cards/[^/]+/actions$"))] | length'; }
before="$(actions_gets)"
fault 500 3 /actions
rc=0
"$AIF" board show AIF-1 --json >"$OUT/show-500.out" 2>"$OUT/show-500.err" || rc=$?
eq "three 500s on the comments read: show fails after three attempts, saying so — not a card with no comment" \
  "$rc,$(grep -c 'Trello: could not read the comments of AIF-1' "$OUT/show-500.err"),$(($(actions_gets) - before)),$(test -f "$FAULT" && echo left || echo spent),$(wc -c <"$OUT/show-500.out" | tr -d ' ')" "1,1,3,spent,0"
fault 500 3 /actions
rc=0
"$AIF" board head AIF-1 >"$OUT/head-500.out" 2>"$OUT/head-500.err" || rc=$?
eq "…and head says it is the board, not the card: exit 2, with the reason, nothing on stdout" \
  "$rc,$(grep -c "could not read AIF-1's comments" "$OUT/head-500.err"),$(grep -c 'could not read the comments of AIF-1' "$OUT/head-500.err"),$(wc -c <"$OUT/head-500.out" | tr -d ' ')" "2,1,1,0"
want="$("$AIF" board next-ready)"
fault 429 1 /lists/
rc=0
got="$("$AIF" board next-ready 2>"$OUT/next-429.err")" || rc=$?
eq "one 429 with Retry-After: 0 on a GET: retried, the answer as before, nothing said" \
  "$rc,$got,$(wc -c <"$OUT/next-429.err" | tr -d ' '),$(test -f "$FAULT" && echo left || echo spent)" "0,$want,0,spent"
fault 500 2 /lists/
rc=0
got="$("$AIF" board next-ready 2>"$OUT/next-500.err")" || rc=$?
eq "two 500s, then the answer: the third attempt is the one that counts" \
  "$rc,$got,$(wc -c <"$OUT/next-500.err" | tr -d ' '),$(test -f "$FAULT" && echo left || echo spent)" "0,$want,0,spent"
fault 503 2 /actions/comments
rc=0
"$AIF" board comment AIF-1 "$OUT/note.md" >"$OUT/comment-503.out" 2>&1 || rc=$?
eq "a 503 on the comment's POST is one attempt, not retried: the second fault is left unserved" \
  "$rc,$(cat "$FAULT" 2>/dev/null)" "1,503 1 /actions/comments"
rm -f "$FAULT"

# Two readers only ever wanted a card's column — the land's "is it in
# Review", and --stop's "is the card of a worker that is gone still In
# Progress" — and read it out of `show`, so the loud failure above reached
# them as an empty column: the land refused a landable card as missing, the
# stop removed the lock under an In Progress card and left it there for the
# next `aif work` to take as fresh (docs/DEFECTS.md 14.7). Each reads the
# column on its own now (aif_board_card_column), never asking for the
# comments: a fault on the comments GET alone — `actions?`, its query string
# telling it from the comment's POST — is left unserved, and the card is
# settled; a board that cannot be read at all keeps the lock, and says so.
# The land's half is in section 5, where a build on a branch is.
printf '  · the column of a card is read without its comments\n'
sleep 0 &
dead=$!
wait "$dead" 2>/dev/null || true
stage_dead_lock() { # <ID> — the lock of a worker that is gone, its card In Progress
  mkdir -p ".aif/state/runs/$1"
  printf '{ "ticket": "%s", "pid": %s, "started_at": "2026-10-02T00:00:00Z" }\n' "$1" "$dead" >".aif/state/runs/$1/owner.json"
  "$AIF" board move "$1" in_progress >/dev/null
}
column_of() { "$AIF" board status --json | jq -r --arg t "$1" '.[] | select(.ticket == $t) | .column'; }
stage_dead_lock AIF-1
before="$(actions_gets)"
fault 500 3 'actions?'
rc=0
"$AIF" work AIF-1 --stop >"$OUT/stop-500.out" 2>&1 || rc=$?
eq "--stop on a worker that is gone while the comments GET fails: the card settled from its column, no comments asked, the fault unserved" \
  "$rc,$(column_of AIF-1),$(posted AIF-1 | sed -n 1p | grep -c "^blocked: stopped — by .* (aif work AIF-1 --stop): the worker that took it (pid $dead) was already gone"),$(($(actions_gets) - before)),$(cat "$FAULT" 2>/dev/null),$(test -d .aif/state/runs/AIF-1 && echo held || echo released)" \
  "0,needs_human,1,0,500 3 actions?,released"
rm -f "$FAULT"
stage_dead_lock AIF-1
fault 500 3 /boards/b1/cards
rc=0
"$AIF" work AIF-1 --stop >"$OUT/stop-unread.out" 2>&1 || rc=$?
eq "…and when the board cannot be read at all: the lock is kept, the card untouched, saying so" \
  "$rc,$(grep -c 'the lock is kept' "$OUT/stop-unread.out"),$(grep -c 'could not list the board' "$OUT/stop-unread.out"),$(test -f "$FAULT" && echo left || echo spent),$(test -d .aif/state/runs/AIF-1 && echo held || echo released),$(column_of AIF-1)" \
  "1,1,1,spent,held,in_progress"
rm -rf .aif/state/runs/AIF-1
# Back where section 5 expects it: at the top of Ready, above the card the
# analyst did not write.
"$AIF" board move AIF-1 ready --top >/dev/null

# =============================== 4. doctor ===================================
printf '\n4. doctor says per role what is missing\n'
eq "pjm ready with the token in the environment" "$("$AIF" doctor --json | jq -r '.roles[] | select(.role == "pjm") | .ready')" "true"
eq "worker unknown until the toolchain is probed" "$("$AIF" doctor --json | jq -r '.roles[] | select(.role == "worker") | .ready')" "null"
eq "worker ready once probed" "$("$AIF" doctor --json --probe | jq -r '.roles[] | select(.role == "worker") | .ready')" "true"
unset TRELLO_TOKEN
eq "without the token, check says which secret and how to set it" \
  "$("$AIF" board check 2>&1 | grep -c 'TRELLO_TOKEN is not set — run in your terminal: aif secret set TRELLO_TOKEN')" "1"
eq "doctor: pjm is not ready, and says why" \
  "$("$AIF" doctor --json | jq -r '.roles[] | select(.role == "pjm") | .ready, .missing[0]' | tr '\n' '|')" "false|board: TRELLO_TOKEN is not set — run in your terminal: aif secret set TRELLO_TOKEN|"
eq "doctor text shows the roles table" "$("$AIF" doctor 2>&1 | grep -c '✗ pjm')" "1"
rc=0
"$AIF" work AIF-1 --no-worktree >"$OUT/work-notoken.out" 2>&1 || rc=$?
eq "the worker refuses before spending anything" "$rc" "3"
eq "and no station ran" "$(jq '[.entries[] | select(.station != null)] | length' .aif/state/ledgers/AIF-1.json 2>/dev/null || echo 0)" "0"
export TRELLO_TOKEN=t

# =============================== 5. the worker through the board =============
printf '\n5. the worker goes through the board\n'
"$AIF" board move AIF-2 backlog >/dev/null
rc=0
"$AIF" work --no-worktree >"$OUT/work-trello.out" 2>&1 || rc=$?
eq "aif work with no id builds the top of Ready (trello)" "$rc" "0"
eq "it picked AIF-1" "$(grep -c 'next in Ready: AIF-1' "$OUT/work-trello.out")" "1"
eq "the card is in Review" "$("$AIF" board status --json | jq -r '.[] | select(.ticket == "AIF-1") | .column')" "review"
eq "the report is a comment on the card" "$(mock | jq -r '[.comments[][] | .data.text] | map(select(startswith("# AIF-1 — built"))) | length')" "1"
mock | jq -j '.cards[] | select(.name | startswith("AIF-1")) | .desc' >"$OUT/card-now.md"
eq "the run built the card's current text, byte for byte" \
  "$(jq -r '.ticket_sha256' tasks/AIF-1/run.json)" "$(shasum -a 256 "$OUT/card-now.md" | cut -d' ' -f1)"

# A board that refuses the comment (docs/DEFECTS.md 10.1): "report posted" was
# printed after the move, under the error that said the comment had been
# refused, with a command that could not post it either. Now the worker says
# the report is not on the card, and the command it prints works once the
# board answers — for the report on a card in Review, and for the reason on a
# card sent to Needs Human. A project of its own: AIF-1 is built in this tree.
fresh_project "$SANDBOX/p3b"
"$AIF" board init trello --board b1 >/dev/null 2>&1
ticket_for AIF-6
ticket_for AIF-7 '[{ "id": "Q-001", "question": "signed?", "default": "no" }]'
git add -A && git commit -qm "two tickets" >/dev/null
"$AIF" board create tasks/AIF-6/ticket.md --column ready >/dev/null
"$AIF" board create tasks/AIF-7/ticket.md --column ready >/dev/null
column_of() { "$AIF" board status --json | jq -r --arg t "$1" '.[] | select(.ticket == $t) | .column'; }
later() { # <worker output> — run the command it printed for posting later
  local cmd
  cmd="$(sed -n 's/.*post it when the board answers: aif //p' "$1" | sed -n 1p)"
  [ -n "$cmd" ] || return 9
  # shellcheck disable=SC2086 # the printed command, word for word
  "$AIF" $cmd >/dev/null 2>&1
}
curl -s "http://127.0.0.1:$PORT/_fail/comments/on" >/dev/null
rc=0
"$AIF" work AIF-6 --no-worktree >"$OUT/work-refused.out" 2>&1 || rc=$?
eq "the board refuses the report: built, in Review, and not said to be posted" \
  "$rc,$(column_of AIF-6),$(grep -c 'report posted' "$OUT/work-refused.out"),$(grep -c 'report NOT on the card' "$OUT/work-refused.out")" "0,review,0,1"
rc=0
"$AIF" work AIF-7 --no-worktree >"$OUT/work-refused2.out" 2>&1 || rc=$?
eq "…and the reason for Needs Human: not said to be posted either" \
  "$rc,$(column_of AIF-7),$(grep -c 'why NOT on the card' "$OUT/work-refused2.out")" "1,needs_human,1"
curl -s "http://127.0.0.1:$PORT/_fail/comments/off" >/dev/null
rc=0
later "$OUT/work-refused.out" || rc=$?
eq "the command it printed posts the report once the board answers" \
  "$rc,$(posted AIF-6 | sed -n 1p)" "0,# AIF-6 — built"
rc=0
later "$OUT/work-refused2.out" || rc=$?
eq "…and the reason, under its blocked: line" \
  "$rc,$(posted AIF-7 | sed -n 1p)" "0,blocked: ticket — not ready — the ready gate's questions are below, for the analyst"

# The land's read of a card's column — is it in Review? — went through
# `show` too, and the comments read failing for good (section 3) refused a
# landable card as "no card on the board", the wrong reason, with nothing
# landed; a board that cannot say where the card is is the environment, the
# land's 3 (docs/DEFECTS.md 14.7). A land needs a branch, so a build in a
# worktree, on a project of its own.
fresh_project "$SANDBOX/p3c"
"$AIF" board init trello --board b1 >/dev/null 2>&1
ticket_for AIF-8
git add -A && git commit -qm "one to land" >/dev/null
"$AIF" board create tasks/AIF-8/ticket.md --column ready >/dev/null
rc=0
"$AIF" work AIF-8 >"$OUT/work-land.out" 2>&1 || rc=$?
eq "a build in a worktree against the mock board: in Review, on its branch" \
  "$rc,$(column_of AIF-8),$(git show-ref --verify --quiet refs/heads/aif/AIF-8 && echo branch)" "0,review,branch"
fault 500 3 /boards/b1/cards
rc=0
"$AIF" land AIF-8 >"$OUT/land-unread.out" 2>&1 || rc=$?
eq "land when the board cannot say where the card is: exit 3, said as the board's, nothing landed" \
  "$rc,$(grep -c "could not say where AIF-8's card is" "$OUT/land-unread.out"),$(grep -c 'has no card on the board' "$OUT/land-unread.out"),$(test -f "$FAULT" && echo left || echo spent),$(column_of AIF-8),$(git log --format=%s -1)" \
  "3,1,0,spent,review,one to land"
before="$(actions_gets)"
fault 500 3 'actions?'
rc=0
"$AIF" land AIF-8 >"$OUT/land-500.out" 2>&1 || rc=$?
eq "land while the comments GET fails: landed from the card's column, the comments never asked for" \
  "$rc,$(column_of AIF-8),$(($(actions_gets) - before)),$(cat "$FAULT" 2>/dev/null),$(git log --format=%s -1 | grep -c '^aif: land AIF-8 — ')" "0,done,0,500 3 actions?,1"
rm -f "$FAULT"

fresh_project "$SANDBOX/p5"
unset AIF_TRELLO_API
ticket_for AIF-1
"$AIF" board create tasks/AIF-1/ticket.md --column ready >/dev/null
ticket_for AIF-3 '[{ "id": "Q-001", "question": "signed?", "default": "no" }]'
"$AIF" board create tasks/AIF-3/ticket.md --column ready >/dev/null
"$AIF" board move AIF-3 ready --top >/dev/null
rc=0
"$AIF" work --no-worktree >"$OUT/work-local1.out" 2>&1 || rc=$?
eq "local: the top of Ready was not ready — exit 1" "$rc" "1"
eq "AIF-3 → needs_human" "$("$AIF" board status --json | jq -r '.[] | select(.ticket == "AIF-3") | .column')" "needs_human"
eq "with the gate's question as the comment" "$("$AIF" board show AIF-3 --json | jq -r '.comments[-1].text' | grep -c 'open question Q-001')" "1"
rc=0
"$AIF" work --no-worktree >"$OUT/work-local2.out" 2>&1 || rc=$?
eq "the next run takes AIF-1 and builds it" "$rc" "0"
eq "AIF-1 → review" "$("$AIF" board status --json | jq -r '.[] | select(.ticket == "AIF-1") | .column')" "review"
eq "the report is on the card, by the worker" "$("$AIF" board show AIF-1 --json | jq -r '.comments[-1].by')" "aif work"
rc=0
"$AIF" work --no-worktree >"$OUT/work-local3.out" 2>&1 || rc=$?
eq "nothing left in Ready is said, not guessed" "$(grep -c "nothing in the board's Ready column" "$OUT/work-local3.out")" "1"
eq "the tree is clean" "$(git status --porcelain | wc -l | tr -d ' ')" "0"

# ----------------------------------------------------------------------------
printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'board: ok\n'
  cd / && rm -rf "$SANDBOX"
else
  printf 'board: %s failure(s) — sandbox kept at %s\n' "$fails" "$SANDBOX"
  exit 1
fi
