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
#      move made from inside a worktree lands on the developer's board
#   3  trello: init maps the columns it can and creates the rest only when
#      told; check refuses a missing token loudly; create writes the ticket as
#      the card's description and pull reads it back byte for byte; a card the
#      analyst did not write is refused at pull; comment, label, status, show
#   4  doctor reports per role what is missing, and stops saying "not ready"
#      the moment the token is set
#   5  the worker pulls the next Ready card, moves it through In Progress to
#      Review with the report as a comment, and to Needs Human when the ticket
#      is not ready
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
if [ -f tests/t1.py ]; then g=0; grep -q impl1 src/app.py 2>/dev/null && g=1; body="$body$(row t1 tests/t1.py "$g")"; fi
printf '<testsuites><testsuite>%s</testsuite></testsuites>' "$body" > .aif/tmp/report.xml
SUITE
  chmod +x .aif/suite.sh
  local tmp
  tmp="$(mktemp)"
  jq '.test.command = "bash .aif/suite.sh" | .test.roots = ["tests"] | .test.report.path = ".aif/tmp/report.xml"' \
    .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
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
{ "schema": 2, "ticket": "$ticket", "ticket_sha256": "$(bind ticket_sha256)", "risk": "low",
  "files": { "create": [], "change": ["src/app.py"], "tests": ["tests/t1.py"] },
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
  tests) printf '# AC-001 asserts impl1\n' >"$wt/tests/t1.py" ;;
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
python3 "$ROOT/scripts/mock-trello.py" 0 >"$OUT/mock.port" 2>"$OUT/mock.err" &
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
eq "pull initialises the ledger" "$(test -f tasks/AIF-1/ledger.json && echo yes)" "yes"
"$AIF" board comment AIF-1 "$OUT/note.md" >/dev/null
eq "the comment reached the server" "$(mock | jq -r '[.comments[][]] | .[0].data.text')" "the export must be signed"
eq "show lists it" "$("$AIF" board show AIF-1 --json | jq -r '.comments[0].text')" "the export must be signed"
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
# A card whose description outgrows a pipe buffer. The finder used to pipe a
# pretty-printed jq into `grep -q .`: grep left at the opening brace, jq took
# SIGPIPE on the rest of the description, pipefail made that 141, and the card
# read as absent — only for tickets long enough to be worth building, and only
# for show/move/comment/pull, so status went on listing a card the worker could
# not find (docs/DEFECTS-5.md #1). 76 KiB of ticket here, past any buffer.
ticket_for AIF-5
{ i=0; while [ "$i" -lt 900 ]; do
    printf 'Line %04d of a long ticket body, padding the description well past the pipe buffer.\n' "$i"
    i=$((i + 1))
  done; } >>tasks/AIF-5/ticket.md
eq "a 76 KiB ticket makes a card" "$("$AIF" board create tasks/AIF-5/ticket.md --column ready 2>&1 | grep -c '^created AIF-5')" "1"
eq "with the whole description on it" \
  "$(mock | jq -r '[.cards[] | select(.name | startswith("AIF-5")) | .desc | length] | .[0] > 65536')" "true"
eq "show finds it" "$("$AIF" board show AIF-5 --json | jq -r .ticket)" "AIF-5"
eq "move finds it" "$("$AIF" board move AIF-5 in_progress 2>&1)" "moved AIF-5 → in_progress"

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
eq "and no station ran" "$(jq '[.entries[] | select(.station != null)] | length' tasks/AIF-1/ledger.json)" "0"
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
eq "with the gate's question as the comment" "$("$AIF" board show AIF-3 --json | jq -r '.comments[0].text' | grep -c 'open question Q-001')" "1"
rc=0
"$AIF" work --no-worktree >"$OUT/work-local2.out" 2>&1 || rc=$?
eq "the next run takes AIF-1 and builds it" "$rc" "0"
eq "AIF-1 → review" "$("$AIF" board status --json | jq -r '.[] | select(.ticket == "AIF-1") | .column')" "review"
eq "the report is on the card, by the worker" "$("$AIF" board show AIF-1 --json | jq -r '.comments[0].by')" "aif work"
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
