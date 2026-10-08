#!/usr/bin/env bash
#
# scripts/check-start.sh — `aif start`, the shift, OFFLINE.
#
# A shift opens claude sessions in a person's terminal and moves cards by
# rules read off their first lines, for hours, beside a loop that builds. Its
# decisions are a pure function — lib/start.jq, a facts document in, a plan
# out — so most of what it decides is proved here over fixtures, with no
# board, no model and no terminal; the rest is the driver around that
# function: the start that refuses, the moves and the units on a real local
# board, a stand-in Trello, and the keys and signals of a real terminal.
# Sessions are a script in claude's place (AIF_START_SESSION_CMD, the seam
# lib/runner_claude.sh keeps inside its job-control bracket), keys come from
# AIF_START_KEYS outside a pty, and the stations are check-board's fake. What
# it proves:
#
#   A  the oracle, row by row of the policy (docs/AUTOPILOT-PHASE1.md cluster
#      E §2): every In Progress class, Review head, Backlog release and pull,
#      Needs Human head, the analyst's list and its threshold, the build in
#      each mode, the shift's memory (a fact offered once is a line after,
#      a newer fact is offered again: a build keyed on each card's entry
#      into Ready, the owner's seed on the rework and not the request it
#      rewrites; a line never the bare move that would undo what the shift
#      held back), a shared board's block on another machine a line, the
#      wait — for a loop not started yet too, never for the cards a loop
#      elsewhere holds, each a line — and the end; a requeue that stops only
#      what is the dead run's, never a process in its worktree nothing else
#      ties to it — and
#      lib/requests.sh over requests shaped like a real project's: a status
#      the tickets that name the request overrule, a blank line before it,
#      a fenced block in a slice, two old-format requests with no status
#   B  the start refuses before it touches anything — a Claude Code session,
#      a worker's checkout, a profile that does not load, a board that fails
#      its check, no terminal and no seam, a shift already open (named by its
#      pid), a model the profile does not map — each with no session opened,
#      the board and the locks as they were and no shift directory; a lock
#      whose shift is gone is taken over, and a board that cannot be read
#      twice ends the shift with 3
#   C  shifts end to end on the local board: a built card reviewed and
#      landed; wrong: sent back as rework: with no session; blocked: ticket
#      to the analyst and back in Ready; a release by the sweep with no key;
#      the keys s, p, q and none at a land; a failing session ends the shift; a
#      session that changed nothing pauses — also while a loop elsewhere
#      moves the board under it; --dry-run touches nothing; the build in this
#      terminal (mode here), never offered twice for the same Ready, and
#      offered again for a card built, reworked and back in Ready in the
#      same shift; the wait beside a loop in another terminal; pulls beside
#      it, the next cards offered once the first were passed by; a worker
#      killed outright, its station stopped and its card requeued — a child
#      its group gains after the facts were read stopped with it (the TERM
#      is the group's, not each pid's), and another checkout's station on
#      the same id left running; a process opened by hand in a dead worker's
#      worktree named, never stopped, the card not requeued; a loop in
#      another terminal holding the one card in Ready — a line, no wait, the
#      shift's end
#   T  Trello, against scripts/mock-trello.py with the real clock: this
#      host's claim is requeued and another host's is a line; a card's head
#      is read again when a comment moves its last activity, and a block by
#      the environment during the shift goes back to Ready behind one
#      preflight
#   D  a real terminal (a pty): a Ctrl-C at the control point ends 130 with
#      the terminal as it was; a Ctrl-C inside a session ends the session, not
#      the shift, which pauses; a closed window at the control point and in a
#      pause ends 129 with the summary in shift.log; a key typed on the
#      Ukrainian layout read as its Latin key, and a key no unit has a
#      pause; Ctrl-Z in a session continued, and a window closed over it
#      still 129 with the session in the summary; a window whose hang-up
#      never reaches the shift — a shell that ignores it, zsh with NO_HUP —
#      129 all the same, summary.json written and the lock gone; a session
#      killed -9 at --max-units leaves no screen mode behind
#
# Run by `make check`. Requires git, jq and curl; skips without python3.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
AIF="$ROOT/bin/aif"

for tool in git jq curl; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'check-start: %s not found — cannot run\n' "$tool"
    exit 1
  }
done
if ! command -v python3 >/dev/null 2>&1; then
  printf 'check-start: skipped — python3 is needed to run a shift detached from a terminal, and on a pty\n'
  exit 0
fi

# Run from a Claude Code session, `make check` exports CLAUDECODE — and the
# shift refuses to start inside one (its first rule). The rest is whatever
# the developer's shell carries that would steer a shift or a loop here.
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT TRELLO_KEY TRELLO_TOKEN AIF_TRELLO_API
unset AIF_START_KEYS AIF_START_SESSION_CMD AIF_START_HEADS_PER_TICK AIF_WORK_LOOP_LOGDIR
unset AIF_RELEASE_HOLD_LABELS AIF_NO_TUI AIF_WORK_LOOP

fails=0
ok() { printf '  ✓ %s\n' "$1"; }
bad() {
  printf '  ✗ %s\n' "$1"
  fails=$((fails + 1))
}
eq() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2', wanted '$3'"; fi
}

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/aif-start-XXXXXX")"
OUT="$SANDBOX/out"
mkdir -p "$OUT"
printf '\nshift, offline (sandbox: %s)\n' "$SANDBOX"

# Never the developer's real keychain. Worker scenarios may run --no-worktree.
# The control point's countdown, the wait's poll, the board's retry and the
# loop's poll in whole seconds a harness can afford: each `_` key is one
# countdown or one poll, and a board that fails is failed again at once.
export AIF_SECRETS_DIR="$SANDBOX/secrets" AIF_DISPOSABLE=1
export AIF_START_WAIT=1 AIF_START_POLL=1 AIF_START_BOARD_RETRY_SECS=0 AIF_WORK_LOOP_POLL=1
# A claude configuration of the harness's own, never the developer's: one
# exported in the shell that runs `make check` (several accounts, a session
# started with one) would prefix every `claude --resume` the summary prints,
# and the row that reads them would fail on the developer's machine alone.
# Set, it is what the summary must name.
export CLAUDE_CONFIG_DIR="$SANDBOX/claude-config"
export AIF_TRELLO_RETRY_SLEEP="0 0 0"

# What runs in the background — shifts, idle loops, the stand-in Trello — and
# what holds them: a held fake session waits for a file (FAKE_SESSION_HOLD),
# runs in a process group of its own (the opener's `set -m`) where a group
# kill of the shift does not reach it, and a TERM to the shift waits for it
# (docs/FINDINGS.md #23). So the harness's way out releases the holds first,
# TERMs the session it recorded, and only then stops each background group,
# every wait bounded — nothing outlives the run, and a scenario that failed
# half way does not hang it.
BG_PIDS=""
HOLDS=""
MOCK_PID=""
cleanup() {
  local p f i
  for f in $HOLDS; do { : >"$f"; } 2>/dev/null; done
  if [ -f "$SANDBOX/session.pid" ]; then
    kill -TERM "$(cat "$SANDBOX/session.pid" 2>/dev/null)" 2>/dev/null
  fi
  for p in $BG_PIDS; do
    kill -0 "$p" 2>/dev/null || continue
    kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null
    i=0
    while kill -0 "$p" 2>/dev/null && [ "$i" -lt 50 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    kill -KILL -- "-$p" 2>/dev/null || kill -KILL "$p" 2>/dev/null
  done
  [ -z "$MOCK_PID" ] || kill "$MOCK_PID" 2>/dev/null
  return 0
}
trap cleanup EXIT

# wait_for <file> — up to ten seconds. wait_said <file> <text> — until the
# text is in the file, up to <secs> (default ten) seconds.
wait_for() {
  local i=0
  while [ ! -f "$1" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
}
wait_said() {
  local i=0 n=$((${3:-10} * 10))
  while ! grep -q -- "$2" "$1" 2>/dev/null && [ "$i" -lt "$n" ]; do
    sleep 0.1
    i=$((i + 1))
  done
}

# wait_exit <pid> <secs> — the exit code of a background process, waited for
# at most <secs>; past that it is stopped with its group and the code is 124
# (scripts/check-work.sh, where an idle loop that never ends taught it).
wait_exit() {
  local i=0 rc=0
  while kill -0 "$1" 2>/dev/null && [ "$i" -lt $(($2 * 10)) ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$1" 2>/dev/null; then
    bad "pid $1 did not end within $2 s — stopped by the harness"
    kill -TERM -- "-$1" 2>/dev/null || kill -TERM "$1" 2>/dev/null
    i=0
    while kill -0 "$1" 2>/dev/null && [ "$i" -lt 50 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    kill -KILL -- "-$1" 2>/dev/null || kill -KILL "$1" 2>/dev/null
    wait "$1" 2>/dev/null
    return 124
  fi
  wait "$1" 2>/dev/null || rc=$?
  forget "$1"
  return "$rc"
}
# forget <pid> — off BG_PIDS once reaped: a pid the system hands out again
# must not be stopped, with its group, by the way out.
forget() {
  BG_PIDS=" $BG_PIDS "
  BG_PIDS="${BG_PIDS// $1 / }"
}

# start_bg <out> <command…> — a command in a session of its own, with no
# terminal: stdin /dev/null, stdout and stderr to <out>; its pid in BG (and
# BG_PIDS). Every shift outside layer D runs this way. A bash in a
# background process group of a real terminal that runs `set -m` — as the
# shift does around every session — takes the terminal and does not give it
# back (docs/FINDINGS.md #28): under a `make check` typed in a terminal, a
# shift started with a plain `&` would stop the run. The process becomes the
# leader of its new session, so `kill -- -<pid>` reaches all of it.
start_bg() {
  local out="$1"
  shift
  python3 -c 'import os, sys
os.setsid()
os.execvp(sys.argv[1], sys.argv[1:])' "$@" </dev/null >"$out" 2>&1 &
  BG=$!
  BG_PIDS="$BG_PIDS $BG"
}
# run_bg <out> <secs> <command…> — start_bg, then its exit code (wait_exit).
run_bg() {
  local out="$1" secs="$2"
  shift 2
  start_bg "$out" "$@"
  wait_exit "$BG" "$secs"
}

# The suite the fake stations' work is judged by, keyed on the ticket: each
# ticket's test (tests/t_<slug>.py, its marker `<ID> AC-001` on its first
# line) passes when that ticket's own module carries `impl-<ID>`. A marker
# shared by every ticket would make the next ticket's tests green before its
# implement once one had landed, and verify-red would reject them; a module
# per ticket also keeps two builds of one project from meeting in a merge.
fresh_project() {
  mkdir -p "$1" && cd "$1" || exit 1
  git init -q
  git config user.email start@aif
  git config user.name "Start"
  mkdir -p src tests
  printf 'def users():\n    return []\n' >src/app.py
  printf '# a pre-existing, green test\n' >tests/t0.py
  git add -A && git commit -qm init >/dev/null
  "$AIF" init anthropic >/dev/null 2>&1 || {
    printf 'check-start: aif init failed — cannot continue\n'
    exit 1
  }
  "$AIF" project init pytest --no-checks >/dev/null 2>&1
  cat >.aif/suite.sh <<'SUITE'
#!/bin/bash
mkdir -p .aif/tmp
row() { if [ "$3" = 1 ]; then printf '<testcase name="%s" file="%s"/>' "$1" "$2"
  else printf '<testcase name="%s" file="%s"><failure message="assert marker missing">AssertionError: assert marker missing</failure></testcase>' "$1" "$2"; fi; }
body="$(row t0 tests/t0.py 1)"
for t in tests/t_*.py; do
  [ -f "$t" ] || continue
  m="$(sed -n '1s/^# \([A-Z0-9-]* AC-[0-9]*\).*/\1/p' "$t")"
  g=0; grep -q "impl-${m%% *}\$" "src/${t#tests/t_}" 2>/dev/null && g=1
  body="$body$(row "$m t1" "$t" "$g")"
done
printf '<testsuites><testsuite>%s</testsuite></testsuites>' "$body" > .aif/tmp/report.xml
SUITE
  chmod +x .aif/suite.sh
  jq '.test.command = "bash .aif/suite.sh" | .test.roots = ["tests"] | .test.report.path = ".aif/tmp/report.xml"' \
    .aif/project.json >"$OUT/project.json.tmp" && mv "$OUT/project.json.tmp" .aif/project.json
  "$AIF" project guide >/dev/null 2>&1 || {
    printf 'check-start: aif project guide failed — cannot continue\n'
    exit 1
  }
  git add -A && git commit -qm "aif init" >/dev/null
}

# ticket_for <id> [depends_on-json] — tasks/<id>/ticket.md (check-work's
# shape) and the module its build changes, src/<slug>.py.
ticket_for() {
  local slug
  slug="$(printf '%s' "$1" | tr 'A-Z-' 'a-z_')"
  "$AIF" _ticket-init "$1" >/dev/null 2>&1 || true
  mkdir -p "tasks/$1" src
  printf 'def run():\n    return []\n' >"src/$slug.py"
  cat >"tasks/$1/ticket.md" <<TICKET
<!-- aif:meta
{ "schema": 2, "ticket": "$1", "lang": "en", "risk": "low",
  "depends_on": ${2:-[]},
  "surfaces": ["export"],
  "acceptance": [
    { "id": "AC-001", "surface": "export",
      "given": "users exist", "when": "the export runs",
      "then": "writes the marker", "expect": "impl-$1" } ],
  "open": [],
  "decided": [ { "question": "may the export be deferred?", "answer": "no", "by": "default" } ],
  "verification_gaps": [],
  "non_goals": [] }
-->
# $1 — one-command user export

Support needs a one-command export of the user list.
TICKET
}

col() { "$AIF" board status --json | jq -r --arg t "$1" '[ .[] | select(.ticket == $t) ] | .[0].column // empty'; }
# The card's head line (`aif board head`) — not named `head`, which this
# script also runs as the command.
card_head() { "$AIF" board head "$1" 2>/dev/null; }
ready_list() { "$AIF" board status --json | jq -r '[ .[] | select(.column == "ready") | .ticket ] | join(" ")'; }
card() { "$AIF" board create "tasks/$1/ticket.md" --column "$2" >/dev/null; }
# say <ID> <by> <text> — a comment on the card, in <by>'s name.
say() {
  printf '%s\n' "$3" >"$OUT/say.txt"
  AIF_BOARD_BY="$2" "$AIF" board comment "$1" "$OUT/say.txt" >/dev/null
}
board_sum() { cat .aif/board/*.json 2>/dev/null | cksum | tr -d ' '; }
shift_dirs() { find .aif/tmp -maxdepth 1 -name 'shift-*' 2>/dev/null | wc -l | tr -d ' '; }
newest_shift() { find .aif/tmp -maxdepth 1 -name 'shift-*' 2>/dev/null | sort | tail -1; }
sessions_n() { if [ -f "$SANDBOX/sessions.log" ]; then wc -l <"$SANDBOX/sessions.log" | tr -d ' '; else echo 0; fi; }
lock_gone() { if [ -d .aif/state/shift ]; then echo held; else echo gone; fi; }
dead_pid() {
  sleep 0 &
  DEAD=$!
  wait "$DEAD" 2>/dev/null
}
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# The fake stations (check-board's four, the ticket's own module and test),
# with check-work's hold: FAKE_SLEEP_IN="<ticket>:<station> …" holds those
# dispatches for FAKE_SLEEP_SECS (37), or until the file FAKE_RELEASE exists
# (at most a minute); each says it started in its worktree and, with
# FAKE_MARKS, in that directory too. Trapped, as check-work's is: a signal
# that lands as one of the hold's sleeps ends would otherwise slip past an
# untrapped bash 3.2 (docs/DEFECTS.md 11.1).
cat >"$SANDBOX/fake-station.sh" <<'FAKE'
#!/bin/bash
set -u
trap 'exit 130' INT TERM
station="$1" ticket="$2" wt="$3" prompt="$5" out="${10}"
work="$wt/tasks/$ticket"
slug="$(printf '%s' "$ticket" | tr 'A-Z-' 'a-z_')"
bind() { printf '%s\n' "$prompt" | awk -v k="$1" '$1 == k":" { print $2; exit }'; }
for hold in ${FAKE_SLEEP_IN:-}; do
  if [ "$hold" = "$ticket:$station" ]; then
    mkdir -p "$wt/.aif/tmp"
    : >"$wt/.aif/tmp/fake-running-$ticket-$station"
    [ -z "${FAKE_MARKS:-}" ] || : >"$FAKE_MARKS/$ticket-$station"
    if [ -n "${FAKE_RELEASE:-}" ]; then
      i=0
      spawned=""
      while [ ! -f "$FAKE_RELEASE" ] && [ "$i" -lt 600 ]; do
        # FAKE_CHILD_AFTER: once that file is there, a child that leaves for
        # / with no ticket in its argv, in this station's group — started
        # after a shift has read what its dead worker left (layer C).
        if [ -n "${FAKE_CHILD_AFTER:-}" ] && [ -z "$spawned" ] && [ -f "$FAKE_CHILD_AFTER" ]; then
          spawned=1
          (cd / && exec sleep 58.7 </dev/null >/dev/null 2>&1) &
        fi
        sleep 0.1
        i=$((i + 1))
      done
    else
      sleep "${FAKE_SLEEP_SECS:-37}"
    fi
  fi
done
case "$station" in
  plan)
    cat >"$work/plan.md" <<PLAN
<!-- aif:meta
{ "schema": 3, "ticket": "$ticket", "ticket_sha256": "$(bind ticket_sha256)", "risk": "low",
  "files": { "create": [], "change": ["src/$slug.py"], "tests": ["tests/t_$slug.py"] },
  "no_skeleton": [], "verdicts": { "AC-001": { "verdict": "buildable" } },
  "decisions": [ { "id": "D-001", "statement": "Write the marker from the ticket's module.",
      "because": "AC-001 is about the module's own output", "serves": ["AC-001"] } ],
  "ac_coverage": { "AC-001": ["src/$slug.py"] }, "uncovered": [],
  "surface_map": { "export": ["src/$slug.py"] }, "external": [] }
-->
# $ticket — plan
PLAN
    ;;
  plan-judge)
    jq -n --arg s "$(bind subject_sha256)" '{schema:1,gate:"plan-judge",subject:"plan.md",subject_sha256:$s,
      judge_agent:"aif-plan-judge",at:"t",guesses:[],missing_files:[]}' >"$work/verdict-plan.json" ;;
  tests) printf '# %s AC-001 asserts impl-%s\n' "$ticket" "$ticket" >"$wt/tests/t_$slug.py" ;;
  implement) printf 'def run():\n    return []  # impl-%s\n' "$ticket" >"$wt/src/$slug.py" ;;
esac
jq -n --arg st "$station" '{type:"result",subtype:"success",is_error:false,result:("fake " + $st),
  num_turns:1,total_cost_usd:0.01,duration_ms:1,
  usage:{input_tokens:1,output_tokens:2,cache_read_input_tokens:0,cache_creation_input_tokens:0},
  modelUsage:{"fake-model":{}}}' >"$out"
FAKE
chmod +x "$SANDBOX/fake-station.sh"
export AIF_WORK_STATION_CMD="$SANDBOX/fake-station.sh"

# The fake session, in claude's place: <cwd> <prompt> <model> <name> <sid>,
# as aif_runner_claude_session hands them to AIF_START_SESSION_CMD. It says
# its pid while it runs (the harness's way out TERMs it), writes one line
# `name|model|sid|prompt` to sessions.log, and then does what the role would,
# by its prompt — enough for the board or the repository to change the way
# the real session changes them:
#   /aif-review <ID>   FAKE_REVIEW=land (default) runs `aif land`; =wrong
#                      posts the human's `wrong:` with a second line;
#                      =nothing does nothing
#   /aif-ba <ID>       the card back in Ready (a ticket with no card: its
#                      card made there)
#   /aif-ba requests/<slug>.md slice <N> [<ID>]
#                      a ticket naming the request and its slice, in Ready
#   /aif-po [requests/<slug>.md]
#                      the request written with its ## Slices and ## Status
#   /aif-pjm <ID>      rework: posted and the card to Backlog
# FAKE_SESSION_NOOP=1 does nothing at all; FAKE_SESSION_HOLD=<file> first
# waits for that file (at most a minute); FAKE_SESSION_RC is its exit code.
# A Ctrl-C ends it 130, as claude's does. For the terminal's rows (layer D),
# claude's own ways out: FAKE_SESSION_KILL9=1 puts the screen in claude's
# modes (the alternate screen, mouse and paste reporting) and dies of kill -9;
# FAKE_SESSION_TSTP=1 is claude's Ctrl+Z — it says it was suspended and stops
# itself; FAKE_SESSION_TTY=1 then reads a line from its terminal, and leaves
# when the terminal is gone, as claude does (docs/FINDINGS.md #28).
cat >"$SANDBOX/fake-session.sh" <<'SESS'
#!/bin/bash
set -u
cwd="$1" prompt="$2" model="$3" name="$4" sid="$5"
printf '%s\n' "$$" >"$FAKE_SB/session.pid"
trap 'rm -f "$FAKE_SB/session.pid"' EXIT
trap 'exit 130' INT TERM
printf '%s|%s|%s|%s\n' "$name" "$model" "$sid" "$prompt" >>"$FAKE_SB/sessions.log"
cd "$cwd" || exit 70
if [ -n "${FAKE_SESSION_HOLD:-}" ]; then
  i=0
  while [ ! -f "$FAKE_SESSION_HOLD" ] && [ "$i" -lt 600 ]; do
    sleep 0.1
    i=$((i + 1))
  done
fi
if [ "${FAKE_SESSION_KILL9:-0}" = 1 ]; then
  { printf '\033[?1049h\033[?1000h\033[?2004h' >/dev/tty; } 2>/dev/null
  kill -9 $$
fi
if [ "${FAKE_SESSION_TSTP:-0}" = 1 ]; then
  printf 'Claude Code has been suspended. Run `fg` to bring Claude Code back.\n'
  kill -TSTP $$
  printf 'resumed\n'
fi
if [ "${FAKE_SESSION_TTY:-0}" = 1 ]; then
  { IFS= read -r line </dev/tty; } 2>/dev/null || true
fi
ticket() { # <id> <request> <slice>
  mkdir -p "tasks/$1"
  cat >"tasks/$1/ticket.md" <<TICKET
<!-- aif:meta
{ "schema": 2, "ticket": "$1", "request": "$2", "slice": $3, "lang": "en", "risk": "low",
  "surfaces": ["export"],
  "acceptance": [ { "id": "AC-001", "surface": "export", "given": "g", "when": "w",
      "then": "t", "expect": "impl-$1" } ],
  "open": [], "decided": [], "verification_gaps": [], "non_goals": [] }
-->
# $1 — a slice the analyst cut

The slice, as the analyst wrote it.
TICKET
}
if [ "${FAKE_SESSION_NOOP:-0}" != 1 ]; then
  case "$prompt" in
    "/aif-review "*)
      id="${prompt#/aif-review }"
      case "${FAKE_REVIEW:-land}" in
        land) "$FAKE_AIF" land "$id" ;;
        wrong)
          printf 'wrong: the export misses the header row\nThe second line of the review.\n' >"$FAKE_SB/wrong.txt"
          AIF_BOARD_BY=reviewer "$FAKE_AIF" board comment "$id" "$FAKE_SB/wrong.txt" >/dev/null
          ;;
      esac
      ;;
    "/aif-ba requests/"*)
      set -- ${prompt#/aif-ba }
      id="${4:-}"
      if [ -z "$id" ]; then
        n="$(ls tasks 2>/dev/null | sed -n 's/^AIF-\([0-9]*\)$/\1/p' | sort -n | tail -1)"
        id="AIF-$((${n:-0} + 1))"
      fi
      ticket "$id" "$1" "$3"
      "$FAKE_AIF" board create "tasks/$id/ticket.md" --column ready >/dev/null
      ;;
    "/aif-ba "*)
      id="${prompt#/aif-ba }"
      if "$FAKE_AIF" board show "$id" >/dev/null 2>&1; then
        "$FAKE_AIF" board move "$id" ready >/dev/null
      else
        ticket "$id" "" 1
        "$FAKE_AIF" board create "tasks/$id/ticket.md" --column ready >/dev/null
      fi
      ;;
    "/aif-po"*)
      f="${prompt#/aif-po}"
      f="${f# }"
      [ -n "$f" ] || f="requests/a-need.md"
      mkdir -p requests
      printf '# %s\n\n## Now\nA need.\n\n## Slices\n1. the first\n2. the second\n\n## Status\nnot cut\n' "$f" >"$f"
      ;;
    "/aif-pjm "*)
      id="${prompt#/aif-pjm }"
      printf 'rework: what the person asked for\n' >"$FAKE_SB/pjm.txt"
      AIF_BOARD_BY="aif pjm" "$FAKE_AIF" board comment "$id" "$FAKE_SB/pjm.txt" >/dev/null
      "$FAKE_AIF" board move "$id" backlog >/dev/null
      ;;
  esac
fi
exit "${FAKE_SESSION_RC:-0}"
SESS
chmod +x "$SANDBOX/fake-session.sh"
export AIF_START_SESSION_CMD="$SANDBOX/fake-session.sh" FAKE_AIF="$AIF" FAKE_SB="$SANDBOX"

# =================================== A ======================================
printf '\nA. the oracle — one facts document per row of the policy, and the requests\n'

# fx <label> <jq assertion> — the facts fixture on stdin, through the shift's
# own call of the oracle (_aif_start_oracle, `jq -f lib/start.jq`); the
# assertion must print true over the plan.
fxn=0
fx() {
  local f out got
  fxn=$((fxn + 1))
  f="$OUT/oracle-$fxn"
  cat >"$f.json"
  if ! out="$(AIF_ROOT="$ROOT" /bin/bash -c '. "$1/lib/cmd_start.sh"; _aif_start_oracle "$2"' _ "$ROOT" "$f.json" 2>&1)"; then
    bad "$1: the oracle failed — $out"
    return
  fi
  printf '%s\n' "$out" >"$f.plan"
  got="$(printf '%s' "$out" | jq "$2" 2>&1)"
  if [ "$got" = true ]; then ok "$1"; else bad "$1 — $2 is $got over $f.plan"; fi
}

S='"shift_started_at":"2026-10-07T10:00:00Z","host":"mac"'
TK='{"line":"taken: mac pid 6000 at 2026-10-07T09:00:00Z — aif work","at":"2026-10-07T09:00:01Z"}'

# ------------------------------------------------------------- In Progress
fx "R2: a run live here — a line and a wait, nothing to do" '.lines[0].rule == "R2" and (.lines[0].text | contains("pid 4242, implement attempt 2")) and .lines[0].command == null and (.moves | length) == 0 and (.units | length) == 0 and .wait.why == "1 being built" and ."end" == null' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-1","column":"in_progress","pos":1,"head":{"line":"taken: mac pid 4242 at 2026-10-07T09:00:00Z — aif work","at":"2026-10-07T09:00:00Z","after":0,"heads":[]},
  "local":{"class":"live","lock":{"held":true,"live":true,"pid":4242,"stage":"implement","attempt":2}}}]}
JSON

fx "R3a: built here, the card says built — only the move to Review" '.moves[0].rule == "R3a" and .moves[0].kind == "report" and .moves[0].to == "review" and .moves[0].where == null and .moves[0].key == "R3a AIF-2 2026-10-07T09:30:00Z" and (.units | length) == 0 and ."end" == null' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-2","column":"in_progress","pos":1,
  "head":{"line":"# AIF-2 — built","at":"2026-10-07T09:30:02Z","after":0,"heads":[$TK,{"line":"# AIF-2 — built","at":"2026-10-07T09:30:02Z"}]},
  "local":{"class":"built","lock":{"held":false,"live":false},"run":{"where":"worktree","status":"built","branch_status":"built","branch_finished_at":"2026-10-07T09:30:00Z","finished_at":"2026-10-07T09:30:00Z"},"report":{"head":"# AIF-2 — built"}}}]}
JSON

fx "R3a: built here, the card says taken: — the report from the branch, then the move" '.moves[0].rule == "R3a" and .moves[0].where == "branch" and .moves[0].to == "review" and (.moves | length) == 1' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-3","column":"in_progress","pos":1,
  "head":{"line":"taken: mac pid 6000 at 2026-10-07T09:00:00Z — aif work","at":"2026-10-07T09:00:01Z","after":0,"heads":[$TK]},
  "local":{"class":"built","lock":{"held":true,"live":false,"pid":6000},"run":{"where":"worktree","status":"built","branch_status":"built","branch_finished_at":"2026-10-07T09:30:00Z"},"report":{"head":"# AIF-3 — built"}}}]}
JSON

fx "R3a: a build older than the newest take, its lock dead — R3b, built from the start" '(.moves | length) == 0 and .units[0].rule == "R3b" and .units[0].key == "R3b AIF-4 1791300100" and (.units[0].text | contains("of a round before")) and (.units[0].text | contains("builds it from the start"))' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-4","column":"in_progress","pos":1,
  "head":{"line":"taken: mac pid 5555 at 2026-10-07T10:05:00Z — aif work","at":"2026-10-07T10:05:01Z","after":0,
          "heads":[{"line":"# AIF-4 — built","at":"2026-10-06T18:00:02Z"},{"line":"rework: x","at":"2026-10-07T08:00:00Z"},{"line":"taken: mac pid 5555 at 2026-10-07T10:05:00Z — aif work","at":"2026-10-07T10:05:01Z"}]},
  "local":{"class":"built","lock":{"held":true,"live":false,"pid":5555,"pid_alive":false,"phase":"worktree","started":1791300100,"orphans":[]},
           "run":{"where":"worktree","status":"built","stage":"done","branch_status":"built","branch_finished_at":"2026-10-06T18:00:00Z"},"report":{"head":"# AIF-4 — built"}}}]}
JSON

fx "R3a: a build older than the newest take, no lock — a line: aif work" '(.moves | length) == 0 and (.units | length) == 0 and .lines[0].rule == "R3a" and .lines[0].command == "aif work AIF-5" and (.lines[0].text | contains("older than its newest take"))' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-5","column":"in_progress","pos":1,
  "head":{"line":"taken: mac pid 5555 at 2026-10-07T10:05:00Z — aif work","at":"2026-10-07T10:05:01Z","after":0,"heads":[{"line":"taken: mac pid 5555 at 2026-10-07T10:05:00Z — aif work","at":"2026-10-07T10:05:01Z"}]},
  "local":{"class":"built","lock":{"held":false,"live":false},"run":{"status":"built","branch_status":"built","branch_finished_at":"2026-10-06T18:00:00Z"}}}]}
JSON

fx "R3b: a worker gone mid-implement — requeue to the top; a group TERMed only where the dead worker led it" '.units[0].rule == "R3b" and .units[0].kind == "requeue" and .units[0].default == "go" and .units[0].top == true and .units[0].to == "ready" and .units[0].key == "R3b AIF-6 1791300200" and .units[0].kill[0].group == true and .units[0].kill[1].group == false and (.units[0].text | contains("pid 6000) is gone mid-implement, attempt 2; back to the top of Ready, where a loop resumes it from implement")) and (.units[0].comment | startswith("released by aif start: its worker (pid 6000) was gone mid-implement")) and (.moves | length) == 0' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-6","column":"in_progress","pos":1,"head":{"line":"taken: mac pid 6000 at 2026-10-07T09:00:00Z — aif work","at":"2026-10-07T09:00:01Z","after":0,"heads":[$TK]},
  "local":{"class":"interrupted","why":"its worker (pid 6000) is gone mid-implement",
           "lock":{"held":true,"live":false,"pid":6000,"pid_alive":false,"phase":"run","stage":"implement","attempt":2,"started":1791300200,
                   "orphans":[{"pid":6001,"pgid":6000,"command":"claude -p Ticket AIF-6. Your working directory"},{"pid":7001,"pgid":7000,"command":"sh -c Ticket AIF-6. x"}]},
           "run":{"where":"worktree","status":"running","stage":"implement"}}}]}
JSON

# A lock its worker never wrote a phase into, and no record: where it died is
# not known — not "during its its run" (docs/DEFECTS.md 15.9).
fx "R3b: a lock with no phase and no record — its phase unknown, built from the start" '.units[0].rule == "R3b" and (.units[0].text | contains("pid 6100) is gone, its phase unknown, before its intake; back to the top of Ready, where a loop builds it from the start")) and (.units[0].text | contains("its its") | not)' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-61","column":"in_progress","pos":1,"head":{"line":"taken: mac pid 6100 at 2026-10-07T09:00:00Z — aif work","at":"2026-10-07T09:00:01Z","after":0,"heads":[$TK]},
  "local":{"class":"interrupted","why":"its worker (pid 6100) is gone, its phase unknown, before its intake — no station ran",
           "lock":{"held":true,"live":false,"pid":6100,"pid_alive":false,"phase":null,"started":1791300300,"orphans":[]},"run":{"where":null,"status":null,"stage":null}}}]}
JSON

# A process tied to the dead run by nothing but its working directory in the
# worktree — a person's shell or editor, maybe — is never stopped, and the
# card is not requeued while it runs (docs/DEFECTS.md 14.1): alone, it is a
# line naming it; beside the dead run's own group, the requeue stops the group
# and keeps it, said so.
fx "R3b: only a process in the worktree that nothing else ties to the run — a line naming it, no requeue, nothing stopped" '(.units | length) == 0 and (.moves | length) == 0 and .lines[0].rule == "R3b" and .lines[0].command == "aif work --status AIF-62" and (.lines[0].text | contains("pid 6201 (vim notes.md) runs in its worktree — nothing but the directory ties it to the run, so the shift stops nothing and requeues nothing while it runs"))' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-62","column":"in_progress","pos":1,"head":{"line":"taken: mac pid 6200 at 2026-10-07T09:00:00Z — aif work","at":"2026-10-07T09:00:01Z","after":0,"heads":[$TK]},
  "local":{"class":"interrupted","lock":{"held":true,"live":false,"pid":6200,"pid_alive":false,"phase":"run","stage":"plan","started":1791300400,
           "orphans":[{"pid":6201,"pgid":6201,"why":"cwd","command":"vim notes.md"}]},"run":{"where":"worktree","status":"running","stage":"plan"}}}]}
JSON

fx "R3b: the dead run's group and a process in the worktree — the requeue stops the group only, and keeps the other, said" '.units[0].rule == "R3b" and ([.units[0].kill[] | .pid] == [6301]) and ([.units[0].keep[] | .pid] == [6302]) and (.units[0].text | contains("1 process it left running, stopped first · pid 6302 (zsh) in its worktree, never stopped — not requeued while it runs"))' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-63","column":"in_progress","pos":1,"head":{"line":"taken: mac pid 6300 at 2026-10-07T09:00:00Z — aif work","at":"2026-10-07T09:00:01Z","after":0,"heads":[$TK]},
  "local":{"class":"interrupted","lock":{"held":true,"live":false,"pid":6300,"pid_alive":false,"phase":"run","stage":"plan","started":1791300500,
           "orphans":[{"pid":6301,"pgid":6300,"why":"group","command":"claude -p Ticket AIF-63. x"},{"pid":6302,"pgid":6302,"why":"cwd","command":"zsh"}]},"run":{"where":"worktree","status":"running","stage":"plan"}}}]}
JSON

fx "R3b on Trello, the newest taken: this host's — offered" '.units[0].rule == "R3b" and (.lines | length) == 0' <<JSON
{$S,"board_kind":"trello","build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-7","column":"in_progress","pos":1,"head":{"line":"taken: mac pid 6000 at 2026-10-07T09:00:00Z — aif work","at":"2026-10-07T09:00:01Z","after":0,"heads":[$TK]},
  "local":{"class":"interrupted","lock":{"held":true,"live":false,"pid":6000,"pid_alive":false,"phase":"run","stage":"plan","started":1},"run":{"status":"running","stage":"plan"}}}]}
JSON

fx "R3b on Trello, another host's claim — a line, nothing to do here" '(.units | length) == 0 and (.moves | length) == 0 and .lines[0].rule == "R4" and .lines[0].command == null and .lines[0].text == "taken by other pid 9 at 2026-10-07T09:10:00Z — built there; nothing to do here"' <<JSON
{$S,"board_kind":"trello","build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-8","column":"in_progress","pos":1,"head":{"line":"taken: other pid 9 at 2026-10-07T09:10:00Z — aif work","at":"2026-10-07T09:10:01Z","after":0,
   "heads":[$TK,{"line":"taken: other pid 9 at 2026-10-07T09:10:00Z — aif work","at":"2026-10-07T09:10:01Z"}]},
  "local":{"class":"interrupted","lock":{"held":true,"live":false,"pid":6000,"pid_alive":false,"stage":"plan","started":1},"run":{"status":"running","stage":"plan"}}}]}
JSON

fx "R3b on Trello, no taken: at all — a line" '(.units | length) == 0 and .lines[0].rule == "R4" and (.lines[0].text | startswith("no taken: line on the card")) and .lines[0].command == "aif work --status AIF-9"' <<JSON
{$S,"board_kind":"trello","build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-9","column":"in_progress","pos":1,"head":{"line":null,"at":null,"after":0,"heads":[]},
  "local":{"class":"interrupted","why":"its worker (pid 1) is gone mid-plan","lock":{"held":true,"live":false,"pid":1,"stage":"plan","started":1},"run":{"status":"running","stage":"plan"}}}]}
JSON

fx "R3c: stopped, a fresh blocked file — posted, then Needs Human" '.moves[0].rule == "R3c" and .moves[0].to == "needs_human" and .moves[0].where == "file" and .moves[0].file == "/p/.aif/tmp/blocked-AIF-10.md" and .moves[0].comment == null and .moves[0].key == "R3c AIF-10 2026-10-07T09:40:00Z"' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-10","column":"in_progress","pos":1,"head":{"line":"taken: mac pid 6000 at 2026-10-07T09:00:00Z — aif work","at":"2026-10-07T09:00:01Z","after":0,"heads":[$TK]},
  "local":{"class":"stopped","lock":{"held":false,"live":false},"run":{"where":"worktree","status":"stopped","why_head":"wall clock: past 120 minutes","branch_status":"stopped","branch_finished_at":"2026-10-07T09:40:00Z"},
           "report":{"head":"# AIF-10 — stopped"},"blocked_file":{"path":"/p/.aif/tmp/blocked-AIF-10.md","exists":true,"fresh":true}}}]}
JSON

fx "R3c: the card says only taken: — the blocked: line recomposed, the report as body" '.moves[0].rule == "R3c" and .moves[0].comment == "blocked: ticket — the gate asked: which currency?" and .moves[0].where == "branch" and .moves[0].file == null' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-11","column":"in_progress","pos":1,"head":{"line":"taken: mac pid 6000 at 2026-10-07T09:00:00Z — aif work","at":"2026-10-07T09:00:01Z","after":0,"heads":[$TK]},
  "local":{"class":"spec","lock":{"held":false,"live":false},"run":{"where":"worktree","status":"spec","why_head":"the gate asked: which currency?","branch_status":"spec","branch_finished_at":"2026-10-07T09:40:00Z"},
           "report":{"head":"# AIF-11 — spec"},"blocked_file":{"exists":true,"fresh":false}}}]}
JSON

fx "R3c: the card already says blocked: — only the move" '.moves[0].rule == "R3c" and .moves[0].to == "needs_human" and .moves[0].comment == null and .moves[0].where == null' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-12","column":"in_progress","pos":1,"head":{"line":"blocked: stopped — by Ctrl-C, during plan","at":"2026-10-07T09:05:00Z","after":0,"heads":[$TK,{"line":"blocked: stopped — by Ctrl-C, during plan","at":"2026-10-07T09:05:00Z"}]},
  "local":{"class":"settled_running","lock":{"held":false,"live":false},"run":{"where":"worktree","status":"running","stage":"plan","started_at":"2026-10-07T09:00:00Z"},"blocked_file":{"fresh":false}}}]}
JSON

fx "R4: nothing of it on this machine — a line" '.lines[0].rule == "R4" and .lines[0].text == "nothing of it on this machine" and .lines[0].command == "aif board move AIF-13 ready" and (.moves | length) == 0 and (.units | length) == 0' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-13","column":"in_progress","pos":1,"head":{"line":null,"after":0,"heads":[]},"local":{"class":"none","why":"nothing of it on this machine","lock":{"held":false,"live":false}}}]}
JSON

fx "R3a on Trello, built by another host — a line" '(.moves | length) == 0 and .lines[0].rule == "R4" and (.lines[0].text | startswith("taken by other pid 9"))' <<JSON
{$S,"board_kind":"trello","build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-14","column":"in_progress","pos":1,"head":{"line":"taken: other pid 9 at 2026-10-07T09:10:00Z — aif work","at":"2026-10-07T09:10:01Z","after":0,"heads":[{"line":"taken: other pid 9 at 2026-10-07T09:10:00Z — aif work","at":"2026-10-07T09:10:01Z"}]},
  "local":{"class":"built","lock":{"held":false,"live":false},"run":{"status":"built","branch_status":"built","branch_finished_at":"2026-10-06T09:30:00Z"}}}]}
JSON

fx "R3c on Trello, another host's run — a line" '(.moves | length) == 0 and .lines[0].rule == "R4" and (.lines[0].text | startswith("taken by other"))' <<JSON
{$S,"board_kind":"trello","build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-15","column":"in_progress","pos":1,"head":{"line":"taken: other pid 9 at 2026-10-07T09:10:00Z — aif work","at":"2026-10-07T09:10:01Z","after":0,"heads":[{"line":"taken: other pid 9 at 2026-10-07T09:10:00Z — aif work","at":"2026-10-07T09:10:01Z"}]},
  "local":{"class":"settled_running","lock":{"held":false,"live":false},"run":{"status":"running","stage":"plan"}}}]}
JSON

# ----------------------------------------------------------------- Review
fx "R5: wrong: — back to Backlog as rework:, the body kept" '.moves[0].rule == "R5" and .moves[0].kind == "rework" and .moves[0].to == "backlog" and .moves[0].from == "review" and .moves[0].key == "R5 AIF-20 2026-10-07T10:10:00Z" and .moves[0].comment == "rework: the export is empty\nit writes no rows\nsee the log\n" and (.units | length) == 0 and ."end" == null' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-20","column":"review","pos":1,"head":{"line":"wrong: the export is empty","at":"2026-10-07T10:10:00Z","body":"it writes no rows\nsee the log\n","after":0,"heads":[]},
  "local":{"class":"built","branch":{"exists":true},"lock":{"live":false}}}]}
JSON

fx "R5: cancel: — to Done as cancelled:" '.moves[0].rule == "R5" and .moves[0].kind == "cancel" and .moves[0].to == "done" and .moves[0].comment == "cancelled: not needed any more"' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-21","column":"review","pos":1,"head":{"line":"cancel: not needed any more","at":"2026-10-07T10:10:00Z","body":"","after":0,"heads":[]}}]}
JSON

fx "R5d: demo not as expected — a unit, rework by default, l lands" '.units[0].rule == "R5d" and .units[0].kind == "demo" and .units[0].default == "rework" and .units[0].keys.l == "land" and .units[0].to == "backlog" and .units[0].comment == "rework: the allowance shows the day before\n- ticket: \"x\" — met\n- request: \"y\" — missed\nto see by hand: open it" and .units[0].key == "R5d AIF-22 2026-10-07T10:11:00Z" and (.moves | length) == 0' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-22","column":"review","pos":1,"head":{"line":"demo: not as expected — the allowance shows the day before","at":"2026-10-07T10:11:00Z","body":"- ticket: \"x\" — met\n- request: \"y\" — missed\nto see by hand: open it","after":0,"heads":[]}}]}
JSON

fx "R6: demo as expected — a land unit, skipped by default" '.units[0].rule == "R6" and .units[0].kind == "land" and .units[0].default == "skip" and .units[0].ticket == "AIF-23"' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-23","column":"review","pos":1,"head":{"line":"demo: as expected — the user sees the allowance","at":"2026-10-07T10:12:00Z","body":"to see by hand: x","after":0,"heads":[]}}]}
JSON

fx "R7: built here — the review session" '.units[0].rule == "R7" and .units[0].kind == "session" and .units[0].role == "review" and .units[0].prompt == "/aif-review AIF-24" and .units[0].name == "aif review AIF-24" and .units[0].default == "open" and .units[0].warn == null and .units[0].key == "R7 AIF-24 2026-10-07T09:30:02Z"' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-24","column":"review","pos":1,"head":{"line":"# AIF-24 — built","at":"2026-10-07T09:30:02Z","after":0,"heads":[]},
  "local":{"class":"built","branch":{"exists":true},"lock":{"held":false,"live":false},"run":{"branch_status":"built"}}}]}
JSON

fx "R7 with tracked changes — warned before the land refuses" '.units[0].rule == "R7" and .units[0].warn == "aif land will refuse while these are uncommitted: requests/x.md, src/a.py — commit them first"' <<JSON
{$S,"build":{"mode":"none","parallel":2},"dirty":["requests/x.md","src/a.py"],"cards":[
 {"ticket":"AIF-25","column":"review","pos":1,"head":{"line":"# AIF-25 — built","at":"2026-10-07T09:30:02Z","after":0,"heads":[]},
  "local":{"class":"built","branch":{"exists":true},"lock":{"held":false,"live":false}}}]}
JSON

fx "R8: the land's own refusals — no branch, not built, a live run, --no-worktree" '(.units | length) == 0 and ([.lines[] | select(.rule == "R8")] | length) == 4 and (.lines[0].text == "no branch aif/AIF-26 — nothing was built for AIF-26 (aif work AIF-26)") and .lines[0].command == "aif work AIF-26" and (.lines[1].text == "the run on aif/AIF-27 did not end built (status: stopped) — nothing to land") and (.lines[2].text == "a worker is taking it here (pid 77)") and (.lines[3].text | startswith("built with --no-worktree"))' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-26","column":"review","pos":1,"head":{"line":"# AIF-26 — built","at":"t1","after":0,"heads":[]},
  "local":{"class":"none","why":"nothing of it on this machine","branch":{"exists":false},"lock":{"held":false,"live":false},"run":{"where":null}}},
 {"ticket":"AIF-27","column":"review","pos":2,"head":{"line":"# AIF-27 — built","at":"t1","after":0,"heads":[]},
  "local":{"class":"stopped","branch":{"exists":true},"lock":{"held":false,"live":false},"run":{"where":"worktree","status":"stopped","branch_status":"stopped"}}},
 {"ticket":"AIF-28","column":"review","pos":3,"head":{"line":"# AIF-28 — built","at":"t1","after":0,"heads":[]},
  "local":{"class":"live","branch":{"exists":true},"lock":{"held":true,"live":true,"pid":77}}},
 {"ticket":"AIF-29","column":"review","pos":4,"head":{"line":"# AIF-29 — built","at":"t1","after":0,"heads":[]},
  "local":{"class":"built","branch":{"exists":false},"lock":{"held":false,"live":false},"run":{"where":"checkout","branch_status":"built"}}}]}
JSON

fx "half-done Review moves finished — rework:, cancelled:, landed, taken: over a build" '([.moves[] | [.rule, .kind, .ticket, .to, .comment, .where]] == [["R5","finish","AIF-30","backlog",null,null],["R5","finish","AIF-31","done",null,null],["R6","finish","AIF-32","done",null,null],["R3a","report","AIF-34","review",null,"branch"]]) and .lines[0].ticket == "AIF-33" and .lines[0].rule == "R8" and (.units | length) == 0' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-30","column":"review","pos":1,"head":{"line":"rework: the export is empty","at":"t2","after":0,"heads":[]}},
 {"ticket":"AIF-31","column":"review","pos":2,"head":{"line":"cancelled: not needed","at":"t2","after":0,"heads":[]}},
 {"ticket":"AIF-32","column":"review","pos":3,"land_commit":true,"head":{"line":"# AIF-32 — landed","at":"t2","after":0,"heads":[]}},
 {"ticket":"AIF-33","column":"review","pos":4,"land_commit":false,"head":{"line":"# AIF-33 — landed","at":"t2","after":0,"heads":[]}},
 {"ticket":"AIF-34","column":"review","pos":5,"head":{"line":"taken: mac pid 6000 at 2026-10-07T09:00:00Z — aif work","at":"t2","after":0,"heads":[]},
  "local":{"class":"built","branch":{"exists":true},"lock":{"held":false,"live":false},"run":{"where":"worktree","branch_status":"built","branch_finished_at":"2026-10-07T09:30:00Z"}}}]}
JSON

fx "R9: a person's words after the head — the project manager" '.units[0].rule == "R9" and .units[0].role == "pjm" and .units[0].prompt == "/aif-pjm AIF-35" and .units[0].name == "aif pjm AIF-35" and .units[0].key == "R9 AIF-35 -" and .units[1].rule == "R9" and .units[1].key == "R9 AIF-36 2026-10-07T09:50:00Z"' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-35","column":"review","pos":1,"head":{"line":null,"at":null,"after":2,"heads":[]}},
 {"ticket":"AIF-36","column":"review","pos":2,"head":{"line":"sync: the branch did not merge","at":"2026-10-07T09:50:00Z","after":1,"heads":[]}}]}
JSON

fx "R9 under --no-pjm — a line" '(.units | length) == 0 and .lines[0].rule == "R9" and .lines[0].command == "claude '"'"'/aif-pjm AIF-37'"'"'"' <<JSON
{$S,"flags":{"pjm":false},"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-37","column":"review","pos":1,"head":{"line":null,"at":null,"after":2,"heads":[]}}]}
JSON

fx "R8: any other head — a line naming it" '(.units | length) == 0 and .lines[0].rule == "R8" and .lines[0].command == "aif land AIF-38" and .lines[1].text == "sync: x — nothing the shift acts on"' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-38","column":"review","pos":1,"head":{"line":"land: the suite went red on the result","at":"t","after":0,"heads":[]}},
 {"ticket":"AIF-39","column":"review","pos":2,"head":{"line":"sync: x","at":"t","after":0,"heads":[]}}]}
JSON

# ------------------------------------------------------------ Backlog, build
fx "R10: every dependency Done and landed — one sweep; the rest are lines" '(.moves | length) == 1 and .moves[0].rule == "R10" and .moves[0].kind == "sweep" and .moves[0].key == "R10 AIF-40 AIF-42" and ([.lines[] | .text] == ["waits on AIF-2 (review)","waits on AIF-3 (Done, but no \"aif: land AIF-3\" commit here — merged by hand? then: aif board move AIF-43 ready)","held: label parked"]) and .lines[1].command == "aif board move AIF-43 ready" and ."end" == null' <<JSON
{$S,"build":{"mode":"none","parallel":2},"hold_labels":["parked"],"cards":[
 {"ticket":"AIF-40","column":"backlog","pos":1,"ticket_file":true,"head":{"line":null,"after":0,"heads":[]},"meta":{"depends_on":["AIF-1"]},"deps":[{"ticket":"AIF-1","column":"done","landed":true}]},
 {"ticket":"AIF-41","column":"backlog","pos":2,"ticket_file":true,"head":{"line":null,"after":0,"heads":[]},"meta":{"depends_on":["AIF-2"]},"deps":[{"ticket":"AIF-2","column":"review","landed":false}]},
 {"ticket":"AIF-42","column":"backlog","pos":3,"ticket_file":true,"head":{"line":null,"after":0,"heads":[]},"meta":{"depends_on":["AIF-1"]},"deps":[{"ticket":"AIF-1","column":"done","landed":true}]},
 {"ticket":"AIF-43","column":"backlog","pos":4,"ticket_file":true,"head":{"line":null,"after":0,"heads":[]},"meta":{"depends_on":["AIF-3"]},"deps":[{"ticket":"AIF-3","column":"done","landed":false}]},
 {"ticket":"AIF-44","column":"backlog","pos":5,"ticket_file":true,"labels":["parked"],"head":{"line":null,"after":0,"heads":[]},"meta":{"depends_on":["AIF-1"]},"deps":[{"ticket":"AIF-1","column":"done","landed":true}]}]}
JSON

fx "R12 here: Ready holds cards — a build unit, keyed on each card's entry into Ready" '.units[0].rule == "R12" and .units[0].kind == "build" and .units[0].default == "go" and .units[0].key == "R12 AIF-50@2026-10-07T09:01:00Z AIF-51@2026-10-07T09:00:00Z" and (.units | length) == 1' <<JSON
{$S,"build":{"mode":"here","parallel":2,"hold":null},"cards":[
 {"ticket":"AIF-51","column":"ready","pos":1,"moved_at":"2026-10-07T09:00:00Z"},{"ticket":"AIF-50","column":"ready","pos":2,"moved_at":"2026-10-07T09:01:00Z"}]}
JSON

fx "R12: a card back in Ready since its build (rework, analyst, Ready) — the build offered again" '.units[0].rule == "R12" and .units[0].key == "R12 AIF-7@2026-10-07T11:00:00Z" and ."end" == null' <<JSON
{$S,"build":{"mode":"here","parallel":2,"hold":null},"memory":{"done":[{"key":"R12 AIF-7@2026-10-07T09:00:00Z","note":"the loop ended rc 0 — taken 1, built 1"}],"retried_env":[],"retried_run":[]},"cards":[
 {"ticket":"AIF-7","column":"ready","pos":1,"moved_at":"2026-10-07T11:00:00Z"}]}
JSON

fx "R12: the same Ready read again after its build — a line, and the end" '(.units | length) == 0 and .lines[0].rule == "R12" and .lines[0].text == "the loop ended rc 0 — taken 0, built 0" and ."end".rc == 0' <<JSON
{$S,"build":{"mode":"here","parallel":2,"hold":null},"memory":{"done":[{"key":"R12 AIF-7@2026-10-07T09:00:00Z","note":"the loop ended rc 0 — taken 0, built 0"}],"retried_env":[],"retried_run":[]},"cards":[
 {"ticket":"AIF-7","column":"ready","pos":1,"moved_at":"2026-10-07T09:00:00Z"}]}
JSON

fx "R12 here with the build held — a line, b builds again" '(.units | length) == 0 and .lines[0].rule == "R12" and .lines[0].text == "the build is held: two runs in a row did not build — b at the control point builds again" and ."end".rc == 0' <<JSON
{$S,"build":{"mode":"here","parallel":2,"hold":"two runs in a row did not build"},"cards":[
 {"ticket":"AIF-52","column":"ready","pos":1}]}
JSON

fx "R12 with a loop elsewhere — no unit, a wait" '(.units | length) == 0 and (.lines | length) == 0 and .wait.why == "1 in Ready — the loop in another terminal (pid 999)" and ."end" == null' <<JSON
{$S,"build":{"mode":"elsewhere","parallel":2,"hold":null,"loop":{"live":true,"pid":999,"idle":true,"parallel":2}},"cards":[
 {"ticket":"AIF-53","column":"ready","pos":1}]}
JSON

# What a loop elsewhere holds — taken once, its run ended with the card still
# in Ready, never taken again by it — is not its load (docs/DEFECTS.md 15.3):
# left out of the wait, a line each with why and its command; a Ready of
# nothing else is no work in flight, and the shift ends where it waited for
# good; the pulls count the free slots without them.
fx "R12 with a loop elsewhere holding a card — the card a line with why, the wait for the rest only" '(.units | length) == 0 and .wait.why == "1 in Ready — the loop in another terminal (pid 999)" and ([.lines[] | select(.rule == "R12")] | length) == 1 and .lines[0].ticket == "AIF-81" and .lines[0].text == "the loop in another terminal will not take it again — its worker exited 1 before it took the card: no profile; aif work AIF-81, or restart the loop" and .lines[0].command == "aif work AIF-81" and ."end" == null' <<JSON
{$S,"build":{"mode":"elsewhere","parallel":2,"hold":null,"loop":{"live":true,"pid":999,"idle":true,"parallel":2,"held":[{"ticket":"AIF-81","why":"its worker exited 1 before it took the card: no profile"}]}},"cards":[
 {"ticket":"AIF-81","column":"ready","pos":1},{"ticket":"AIF-82","column":"ready","pos":2}]}
JSON

fx "…Ready holding only what the loop elsewhere holds — no wait: the shift ends, each card a line" '(.units | length) == 0 and .wait == null and ."end".rc == 0 and ([.lines[] | .ticket] == ["AIF-83","AIF-84"]) and ([.lines[] | .command] == ["aif work AIF-83","aif work AIF-84"])' <<JSON
{$S,"build":{"mode":"elsewhere","parallel":2,"hold":null,"loop":{"live":true,"pid":999,"idle":true,"parallel":2,"held":[{"ticket":"AIF-83","why":"a"},{"ticket":"AIF-84","why":"b"},{"ticket":"AIF-89","why":"no longer in Ready"}]}},"cards":[
 {"ticket":"AIF-83","column":"ready","pos":1},{"ticket":"AIF-84","column":"ready","pos":2},{"ticket":"AIF-89","column":"done","pos":1}]}
JSON

fx "…and the pulls count the loop's free slots without its held cards" '([.units[] | .rule + " " + .ticket] == ["R14 AIF-86","R14 AIF-87"]) and .lines[0].ticket == "AIF-85"' <<JSON
{$S,"build":{"mode":"elsewhere","parallel":2,"hold":null,"loop":{"live":true,"pid":999,"idle":true,"parallel":2,"held":[{"ticket":"AIF-85","why":"x"}]}},"cards":[
 {"ticket":"AIF-85","column":"ready","pos":1},
 {"ticket":"AIF-86","column":"backlog","pos":1,"ticket_file":true,"head":{"line":null,"after":0,"heads":[]},"meta":{"depends_on":[]},"ready_gate":0},
 {"ticket":"AIF-87","column":"backlog","pos":2,"ticket_file":true,"head":{"line":null,"after":0,"heads":[]},"meta":{"depends_on":[]},"ready_gate":0}]}
JSON

fx "R12 under --no-build with no loop yet — a line, and a wait for the loop, never the end" '(.units | length) == 0 and .lines[0].text == "Ready holds 1 — no loop runs on this checkout" and .lines[0].command == "aif work --loop --idle" and .wait.why == "1 in Ready — no loop runs on this checkout yet: aif work --loop --idle in another terminal" and ."end" == null' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[{"ticket":"AIF-54","column":"ready","pos":1}]}
JSON

fx "…and under --po, not the owner while Ready waits for its loop" '(.units | length) == 0 and .wait != null and ."end" == null' <<JSON
{$S,"flags":{"po":true},"build":{"mode":"none","parallel":2},"cards":[{"ticket":"AIF-54","column":"ready","pos":1},{"ticket":"AIF-117","column":"ready","pos":2}]}
JSON

fx "R12: one analyst unit first while Ready is short of a round" '([.units[] | .rule] == ["R19b","R12"]) and .units[0].prompt == "/aif-ba AIF-56"' <<JSON
{$S,"build":{"mode":"here","parallel":2,"hold":null},"cards":[
 {"ticket":"AIF-55","column":"ready","pos":1},
 {"ticket":"AIF-56","column":"needs_human","pos":1,"head":{"line":"blocked: ticket — not ready — the ready gate's questions are below","at":"t","after":0,"heads":[]}}]}
JSON

fx "R12 waits behind a review" '([.units[] | .rule] == ["R7"])' <<JSON
{$S,"build":{"mode":"here","parallel":2,"hold":null},"cards":[
 {"ticket":"AIF-57","column":"ready","pos":1},
 {"ticket":"AIF-58","column":"review","pos":1,"head":{"line":"# AIF-58 — built","at":"t","after":0,"heads":[]},"local":{"class":"built","branch":{"exists":true},"lock":{"live":false}}}]}
JSON

fx "R14 here, 1 ≤ ready < parallel — pulls for the free slots, then the build" '([.units[] | .rule + " " + (.ticket // "-")] == ["R14 AIF-60","R14 AIF-61","R12 -"]) and .units[0].default == "skip" and .units[0].keys.y == "pull" and .units[0].key == "R14 AIF-60" and (.units[0].comment | startswith("released by aif start: pulled from Backlog")) and .lines[0].ticket == "AIF-62" and .lines[0].command == "aif _ready AIF-62"' <<JSON
{$S,"build":{"mode":"here","parallel":3,"hold":null},"cards":[
 {"ticket":"AIF-59","column":"ready","pos":1},
 {"ticket":"AIF-60","column":"backlog","pos":1,"ticket_file":true,"head":{"line":null,"after":0,"heads":[]},"meta":{"depends_on":[]},"ready_gate":0},
 {"ticket":"AIF-61","column":"backlog","pos":2,"ticket_file":true,"head":{"line":null,"after":0,"heads":[]},"meta":{"depends_on":[]},"ready_gate":0},
 {"ticket":"AIF-62","column":"backlog","pos":3,"ticket_file":true,"head":{"line":null,"after":0,"heads":[]},"meta":{"depends_on":[]},"ready_gate":1},
 {"ticket":"AIF-63","column":"backlog","pos":4,"ticket_file":true,"head":{"line":null,"after":0,"heads":[]},"meta":{"depends_on":[]},"ready_gate":0}]}
JSON

fx "R14 elsewhere, nothing in Ready or in flight, parallel 2 — two pulls" '([.units[] | .rule + " " + .ticket] == ["R14 AIF-64","R14 AIF-65"]) and .wait == null and ."end" == null' <<JSON
{$S,"build":{"mode":"elsewhere","parallel":2,"hold":null,"loop":{"live":true,"pid":999,"idle":true,"parallel":2}},"cards":[
 {"ticket":"AIF-64","column":"backlog","pos":1,"ticket_file":true,"head":{"line":null,"after":0,"heads":[]},"meta":{"depends_on":[]},"ready_gate":0},
 {"ticket":"AIF-65","column":"backlog","pos":2,"ticket_file":true,"head":{"line":null,"after":0,"heads":[]},"meta":{"depends_on":[]},"ready_gate":0},
 {"ticket":"AIF-66","column":"backlog","pos":3,"ticket_file":true,"head":{"line":null,"after":0,"heads":[]},"meta":{"depends_on":[]},"ready_gate":0}]}
JSON

fx "R14 elsewhere, 2 in progress and 1 in Ready — no pull, a wait" '(.units | length) == 0 and .wait.why == "2 being built, 1 in Ready — the loop in another terminal (pid 999)"' <<JSON
{$S,"build":{"mode":"elsewhere","parallel":2,"hold":null,"loop":{"live":true,"pid":999,"idle":true,"parallel":2}},"cards":[
 {"ticket":"AIF-67","column":"in_progress","pos":1,"head":{"line":"taken: mac pid 1 at x — aif work","after":0,"heads":[]},"local":{"class":"live","lock":{"live":true,"pid":1,"stage":"plan"}}},
 {"ticket":"AIF-68","column":"in_progress","pos":2,"head":{"line":"taken: mac pid 2 at x — aif work","after":0,"heads":[]},"local":{"class":"live","lock":{"live":true,"pid":2,"stage":"plan"}}},
 {"ticket":"AIF-69","column":"ready","pos":1},
 {"ticket":"AIF-70","column":"backlog","pos":1,"ticket_file":true,"head":{"line":null,"after":0,"heads":[]},"meta":{"depends_on":[]},"ready_gate":0}]}
JSON

fx "R14: no pull while the analyst has work" '([.units[] | .rule] == ["R19b"])' <<JSON
{$S,"build":{"mode":"elsewhere","parallel":2,"hold":null,"loop":{"live":true,"pid":999,"parallel":2}},"cards":[
 {"ticket":"AIF-71","column":"backlog","pos":1,"ticket_file":true,"head":{"line":null,"after":0,"heads":[]},"meta":{"depends_on":[]},"ready_gate":0},
 {"ticket":"AIF-72","column":"needs_human","pos":1,"head":{"line":"blocked: ticket — not ready","at":"t","after":0,"heads":[]}}]}
JSON

# ------------------------------------------------------------ Needs Human
fx "R16: two cards blocked by the environment during the shift — two moves, no end" '([.moves[] | .rule + " " + .ticket + " " + .to] == ["R16 AIF-73 ready","R16 AIF-74 ready"]) and .moves[0].kind == "env-retry" and (.moves[0].comment | startswith("released by aif start: blocked by the environment during this shift")) and ."end" == null and (.units | length) == 0' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-73","column":"needs_human","pos":1,"head":{"line":"blocked: environment — the install failed","at":"2026-10-07T10:05:00Z","after":0,"heads":[]}},
 {"ticket":"AIF-74","column":"needs_human","pos":2,"head":{"line":"blocked: environment — the install failed","at":"2026-10-07T10:06:00Z","after":0,"heads":[]}}]}
JSON

fx "R16: retried once and blocked again — a line" '(.moves | length) == 0 and (.lines[0].text | startswith("blocked by the environment again after its retry")) and .lines[0].command == "aif board move AIF-75 ready" and ."end".rc == 0' <<JSON
{$S,"build":{"mode":"none","parallel":2},"memory":{"done":[],"retried_env":["AIF-75"],"retried_run":[]},"cards":[
 {"ticket":"AIF-75","column":"needs_human","pos":1,"head":{"line":"blocked: environment — the install failed","at":"2026-10-07T10:20:00Z","after":0,"heads":[]}}]}
JSON

fx "R16: blocked before the shift — a line" '(.moves | length) == 0 and (.lines[0].text | startswith("blocked by the environment before this shift"))' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-76","column":"needs_human","pos":1,"head":{"line":"blocked: environment — the install failed","at":"2026-10-07T09:00:00Z","after":0,"heads":[]}}]}
JSON

R17='"heads":[{"line":"taken: mac pid 1 at x — aif work","at":"t0"},{"line":"blocked: run — the worker exited (code 1) during implement","at":"t1"}]'
fx "R17 without --retry-runs — a line" '(.moves | length) == 0 and .lines[0].rule == "R17" and .lines[0].text == "blocked: run — the worker exited (code 1) during implement" and .lines[0].command == "aif board move AIF-77 ready"' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-77","column":"needs_human","pos":1,"head":{"line":"blocked: run — the worker exited (code 1) during implement","at":"t1","after":0,$R17}}]}
JSON

fx "R17 with --retry-runs, an instrument stopped it — back to Ready" '.moves[0].rule == "R17" and .moves[0].kind == "retry-run" and .moves[0].to == "ready" and .moves[0].comment == "released by aif start: the worker exited (code 1) during implement — retried once (--retry-runs)"' <<JSON
{$S,"flags":{"retry_runs":true},"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-78","column":"needs_human","pos":1,"head":{"line":"blocked: run — the worker exited (code 1) during implement","at":"t1","after":0,$R17}}]}
JSON

fx "R17: the wall clock — a line, a cap is for a person" '(.moves | length) == 0 and (.lines[0].text | endswith("not retried: a cap or a rejection is for a person"))' <<JSON
{$S,"flags":{"retry_runs":true},"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-79","column":"needs_human","pos":1,"head":{"line":"blocked: run — wall clock: past 120 minutes","at":"t1","after":0,"heads":[{"line":"blocked: run — wall clock: past 120 minutes","at":"t1"}]}}]}
JSON

fx "R17: a worker that was already gone (its text names --stop) — a move" '.moves[0].rule == "R17" and .moves[0].ticket == "AIF-80"' <<JSON
{$S,"flags":{"retry_runs":true},"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-80","column":"needs_human","pos":1,"head":{"line":"blocked: stopped — by kk (aif work AIF-80 --stop): the worker that took it (pid 9) was already gone, and had left the card In Progress","at":"t1","after":0,
  "heads":[{"line":"blocked: stopped — by kk (aif work AIF-80 --stop): the worker that took it (pid 9) was already gone, and had left the card In Progress","at":"t1"}]}}]}
JSON

fx "R17: by Ctrl-C, or a person's --stop — lines" '(.moves | length) == 0 and (.lines | length) == 2 and (.lines[0].text | endswith("not retried: a person stopped it")) and (.lines[1].text | endswith("not retried: a person stopped it"))' <<JSON
{$S,"flags":{"retry_runs":true},"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-81","column":"needs_human","pos":1,"head":{"line":"blocked: stopped — by Ctrl-C, during plan","at":"t1","after":0,"heads":[{"line":"blocked: stopped — by Ctrl-C, during plan","at":"t1"}]}},
 {"ticket":"AIF-82","column":"needs_human","pos":2,"head":{"line":"blocked: stopped — by kk (aif work AIF-82 --stop), during plan","at":"t1","after":0,"heads":[{"line":"blocked: stopped — by kk (aif work AIF-82 --stop), during plan","at":"t1"}]}}]}
JSON

fx "R17: by a TERM signal, by a hang-up — moves" '([.moves[] | .ticket] == ["AIF-83","AIF-84"])' <<JSON
{$S,"flags":{"retry_runs":true},"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-83","column":"needs_human","pos":1,"head":{"line":"blocked: stopped — by a TERM signal, during plan","at":"t1","after":0,"heads":[{"line":"blocked: stopped — by a TERM signal, during plan","at":"t1"}]}},
 {"ticket":"AIF-84","column":"needs_human","pos":2,"head":{"line":"blocked: stopped — by a hang-up — the terminal closed — during plan","at":"t1","after":0,"heads":[{"line":"blocked: stopped — by a hang-up — the terminal closed — during plan","at":"t1"}]}}]}
JSON

fx "R17: two blocks with taken: and released by between — a line" '(.moves | length) == 0 and (.lines[0].text | endswith("not retried: blocked 2 times in a row"))' <<JSON
{$S,"flags":{"retry_runs":true},"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-85","column":"needs_human","pos":1,"head":{"line":"blocked: run — x","at":"t5","after":0,
  "heads":[{"line":"taken: mac pid 1 at a — aif work","at":"t1"},{"line":"blocked: run — x","at":"t2"},{"line":"released by aif start: x — retried once (--retry-runs)","at":"t3"},{"line":"taken: mac pid 2 at b — aif work","at":"t4"},{"line":"blocked: run — x","at":"t5"}]}}]}
JSON

fx "R17: retried once this shift already — a line" '(.moves | length) == 0 and (.lines[0].text | endswith("retried once this shift already"))' <<JSON
{$S,"flags":{"retry_runs":true},"memory":{"done":[],"retried_env":[],"retried_run":["AIF-86"]},"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-86","column":"needs_human","pos":1,"head":{"line":"blocked: run — x","at":"t5","after":0,"heads":[{"line":"blocked: run — x","at":"t5"}]}}]}
JSON

fx "R16 and R17 on a shared Trello board, blocked on another machine — lines: that machine's to retry, never this one's preflight" '(.moves | length) == 0 and ([.lines[] | [.rule, .ticket, .command]] == [["R16","AIF-118","aif board move AIF-118 ready"],["R17","AIF-119","aif board move AIF-119 ready"]]) and (.lines[0].text | endswith("— blocked on otherhost, not here: that machine'"'"'s to retry"))' <<JSON
{$S,"board_kind":"trello","flags":{"retry_runs":true},"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-118","column":"needs_human","pos":1,"head":{"line":"blocked: environment — the install failed","at":"2026-10-07T10:05:00Z","after":0,
  "heads":[{"line":"taken: otherhost pid 9 at 2026-10-07T10:00:00Z — aif work","at":"2026-10-07T10:00:01Z"},{"line":"blocked: environment — the install failed","at":"2026-10-07T10:05:00Z"}]}},
 {"ticket":"AIF-119","column":"needs_human","pos":2,"head":{"line":"blocked: stopped — by a TERM signal, during plan","at":"2026-10-07T10:06:00Z","after":0,
  "heads":[{"line":"taken: otherhost pid 9 at 2026-10-07T10:01:00Z — aif work","at":"2026-10-07T10:01:01Z"},{"line":"blocked: stopped — by a TERM signal, during plan","at":"2026-10-07T10:06:00Z"}]}}]}
JSON

fx "R18: land:, no head, not landed — lines with the command each names" '(.moves | length) == 0 and (.units | length) == 0 and .lines[0].command == "aif board move AIF-87 review && aif land AIF-87" and .lines[1].command == "aif work --status AIF-88" and (.lines[1].text | startswith("no blocked: line")) and .lines[2].text == "# AIF-89 — not landed"' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-87","column":"needs_human","pos":1,"head":{"line":"land: the merge conflicted","at":"t","after":0,"heads":[]}},
 {"ticket":"AIF-88","column":"needs_human","pos":2,"head":{"line":null,"at":null,"after":0,"heads":[]}},
 {"ticket":"AIF-89","column":"needs_human","pos":3,"head":{"line":"# AIF-89 — not landed","at":"t","after":0,"heads":[]}}]}
JSON

fx "R18a: a person answered under blocked: — a unit, r back to Ready" '.units[0].rule == "R18a" and .units[0].kind == "answered" and .units[0].default == "skip" and .units[0].keys.r == "ready" and .units[0].to == "ready" and .units[0].key == "R18a AIF-90 t1" and (.moves | length) == 0' <<JSON
{$S,"flags":{"retry_runs":true},"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-90","column":"needs_human","pos":1,"head":{"line":"blocked: environment — the install failed","at":"t1","after":1,"heads":[]}}]}
JSON

fx "a hold label in Needs Human — a line, nothing else" '(.units | length) == 0 and .lines[0].text == "held: label parked"' <<JSON
{$S,"hold_labels":["parked"],"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-91","column":"needs_human","pos":1,"labels":["parked"],"head":{"line":"blocked: ticket — not ready","at":"t","after":0,"heads":[]}}]}
JSON

# ------------------------------------------------------------- BA list
fx "R19a: rework: in Backlog — the analyst" '.units[0].rule == "R19a" and .units[0].role == "ba" and .units[0].prompt == "/aif-ba AIF-92" and .units[0].name == "aif ba AIF-92" and .units[0].key == "R19a AIF-92 t" and (.units | length) == 1' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-92","column":"backlog","pos":1,"ticket_file":true,"meta":{"depends_on":[],"request":"requests/a.md"},"head":{"line":"rework: the export is empty","at":"t","body":"it writes no rows","after":0,"heads":[]}}]}
JSON

fx "R19a whose rework names a request — the owner first (R20), keyed on the rework" '([.units[] | .rule] == ["R20","R19a"]) and .units[0].role == "po" and .units[0].prompt == "/aif-po requests/allowance.md" and .units[0].name == "aif po allowance" and .units[0].key == "R20 AIF-93 t" and .units[0].file == "requests/allowance.md"' <<JSON
{$S,"build":{"mode":"none","parallel":2},"requests":[{"file":"requests/allowance.md","slug":"allowance","sha":"abc","effective":"cut","tickets":[{"ticket":"AIF-93","slice":1}]}],"cards":[
 {"ticket":"AIF-93","column":"backlog","pos":1,"ticket_file":true,"meta":{"depends_on":[],"request":"requests/allowance.md","slice":1},
  "head":{"line":"rework: the allowance shows the day before","at":"t","body":"- ticket: \"x\" — met\n- request: \"y\" — the words let it through\nto see by hand: z","after":0,"heads":[]}}]}
JSON

fx "…the owner rewrote the request (a new sha): the analyst next, the owner's seed a line — not offered again ahead of it" '([.units[] | .rule] == ["R19a"]) and ([.lines[] | select(.rule == "R20") | .command] == ["claude '"'"'/aif-po requests/allowance.md'"'"'"])' <<JSON
{$S,"build":{"mode":"none","parallel":2},"memory":{"done":[{"key":"R20 AIF-93 t","note":"aif po allowance — rc 0, changed the board or the repository"}],"retried_env":[],"retried_run":[]},
 "requests":[{"file":"requests/allowance.md","slug":"allowance","sha":"def","effective":"cut","tickets":[{"ticket":"AIF-93","slice":1}]}],"cards":[
 {"ticket":"AIF-93","column":"backlog","pos":1,"ticket_file":true,"meta":{"depends_on":[],"request":"requests/allowance.md","slice":1},
  "head":{"line":"rework: the allowance shows the day before","at":"t","body":"- ticket: \"x\" — met\n- request: \"y\" — the words let it through\nto see by hand: z","after":0,"heads":[]}}]}
JSON

fx "R19b: blocked: ticket — the analyst" '.units[0].rule == "R19b" and .units[0].prompt == "/aif-ba AIF-94" and .units[0].key == "R19b AIF-94 t"' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-94","column":"needs_human","pos":1,"head":{"line":"blocked: ticket — not ready","at":"t","after":0,"heads":[]}}]}
JSON

fx "R19c: a scaffold with no card is cut; a ticket with no card is a line" '([.units[] | .rule + " " + .prompt] == ["R19c /aif-ba requests/x.md slice 2 AIF-95","R19c /aif-ba AIF-97"]) and .units[0].key == "R19c AIF-95" and ([.lines[] | .ticket + " " + .command] == ["AIF-96 aif board create tasks/AIF-96/ticket.md --column ready"])' <<JSON
{$S,"build":{"mode":"none","parallel":2},"loose_tasks":[
 {"ticket":"AIF-95","stub":true,"tracked":false,"landed":false,"request":"requests/x.md","slice":2},
 {"ticket":"AIF-96","stub":false,"tracked":false,"landed":false,"request":null,"slice":null},
 {"ticket":"AIF-97","stub":true,"tracked":false,"landed":false,"request":null,"slice":null},
 {"ticket":"AIF-98","stub":true,"tracked":true,"landed":false},
 {"ticket":"AIF-99","stub":false,"tracked":true,"landed":true}],"cards":[]}
JSON

fx "R19d: a request cut in part — its next slice" '.units[0].rule == "R19d" and .units[0].prompt == "/aif-ba requests/x.md slice 2" and .units[0].name == "aif ba x" and .units[0].key == "R19d requests/x.md 2 s1" and .units[0].file == "requests/x.md"' <<JSON
{$S,"build":{"mode":"none","parallel":2},"requests":[{"file":"requests/x.md","slug":"x","sha":"s1","status_line":"not cut","shape":"slices","slices":3,"tickets":[{"ticket":"AIF-1","slice":1}],"derived":"cut in part","next_slice":2,"effective":"cut in part"}],"cards":[]}
JSON

fx "R19e and R20: not cut — the analyst, or the owner for an old-format request" '([.units[] | .rule + " " + .prompt] == ["R19e /aif-ba requests/y.md","R20 /aif-po requests/z.md","R20 /aif-po requests/w.md"]) and .units[0].key == "R19e requests/y.md s2" and .units[1].key == "R20 requests/z.md s3" and .units[1].role == "po" and .units[1].name == "aif po z"' <<JSON
{$S,"build":{"mode":"none","parallel":2},"requests":[
 {"file":"requests/y.md","slug":"y","sha":"s2","status_line":"not cut","shape":"slices","slices":2,"tickets":[],"derived":null,"next_slice":1,"effective":"not cut"},
 {"file":"requests/z.md","slug":"z","sha":"s3","status_line":"none","shape":"scope","slices":1,"tickets":[],"derived":null,"next_slice":1,"effective":"not cut"},
 {"file":"requests/w.md","slug":"w","sha":"s4","status_line":"none","shape":"none","slices":0,"tickets":[],"derived":null,"next_slice":null,"effective":"not cut"},
 {"file":"requests/v.md","slug":"v","sha":"s5","status_line":"cut","shape":"slices","slices":1,"tickets":[{"ticket":"AIF-1","slice":1}],"derived":"cut","next_slice":null,"effective":"cut"}],"cards":[]}
JSON

fx "the analyst's threshold: (c)–(e) wait while three rounds are queued" '([.units[] | .rule] == ["R19b"]) and ."end" == null' <<JSON
{$S,"build":{"mode":"none","parallel":1},"requests":[{"file":"requests/y.md","slug":"y","sha":"s2","status_line":"not cut","shape":"slices","slices":2,"tickets":[],"effective":"not cut"}],
 "loose_tasks":[{"ticket":"AIF-100","stub":true,"tracked":false,"landed":false}],"cards":[
 {"ticket":"AIF-101","column":"ready","pos":1},{"ticket":"AIF-102","column":"ready","pos":2},
 {"ticket":"AIF-103","column":"in_progress","pos":1,"head":{"line":null,"after":0,"heads":[]},"local":{"class":"none","why":"nothing of it on this machine"}},
 {"ticket":"AIF-104","column":"needs_human","pos":1,"head":{"line":"blocked: ticket — not ready","at":"t","after":0,"heads":[]}}]}
JSON

# ----------------------------------------------------------- keys, memory
fx "a key in memory.done — left out, and a line with its note and command; a wrong: never the bare move that loses its rework:" '(.units | length) == 0 and (.moves | length) == 0 and ([.lines[] | [.rule, .ticket, .column, .text, .command]] == [["R7","AIF-105","review","skipped","claude '"'"'/aif-review AIF-105'"'"'"],["R5","AIF-106","review","the move failed: aif board move AIF-106 backlog","claude '"'"'/aif-pjm AIF-106'"'"'"],["R6","AIF-107","review","offered, not taken (timeout)","aif land AIF-107"]]) and ."end".rc == 0' <<JSON
{$S,"build":{"mode":"none","parallel":2},"memory":{"done":[
  {"key":"R7 AIF-105 2026-10-07T09:30:02Z","note":"skipped"},
  {"key":"R5 AIF-106 2026-10-07T10:10:00Z","note":"the move failed: aif board move AIF-106 backlog"},
  {"key":"R6 AIF-107 t","note":"offered, not taken (timeout)"}],"retried_env":[],"retried_run":[]},"cards":[
 {"ticket":"AIF-105","column":"review","pos":1,"head":{"line":"# AIF-105 — built","at":"2026-10-07T09:30:02Z","after":0,"heads":[]},"local":{"class":"built","branch":{"exists":true},"lock":{"live":false}}},
 {"ticket":"AIF-106","column":"review","pos":2,"head":{"line":"wrong: x","at":"2026-10-07T10:10:00Z","after":0,"heads":[]}},
 {"ticket":"AIF-107","column":"review","pos":3,"head":{"line":"demo: as expected — y","at":"t","after":0,"heads":[]}}]}
JSON

fx "a requeue the shift refused (a station still runs) — a line whose command says what runs, never the move R3b held back" '(.units | length) == 0 and .lines[0].rule == "R3b" and .lines[0].command == "aif work --status AIF-6" and (.lines[0].text | endswith("not requeued"))' <<JSON
{$S,"build":{"mode":"none","parallel":2},"memory":{"done":[{"key":"R3b AIF-6 1791300200","note":"a station still runs in its worktree (pid 6001) — not requeued"}],"retried_env":[],"retried_run":[]},"cards":[
 {"ticket":"AIF-6","column":"in_progress","pos":1,"head":{"line":"taken: mac pid 6000 at 2026-10-07T09:00:00Z — aif work","at":"2026-10-07T09:00:01Z","after":0,"heads":[$TK]},
  "local":{"class":"interrupted","lock":{"held":true,"live":false,"pid":6000,"pid_alive":false,"phase":"run","stage":"implement","started":1791300200,
           "orphans":[{"pid":6001,"pgid":6000,"command":"claude -p Ticket AIF-6. x"}]},"run":{"where":"worktree","status":"running","stage":"implement"}}}]}
JSON

fx "a report the shift could not post — a line naming aif work --status, not the bare move to Review" '(.moves | length) == 0 and .lines[0].rule == "R3a" and .lines[0].command == "aif work --status AIF-3"' <<JSON
{$S,"build":{"mode":"none","parallel":2},"memory":{"done":[{"key":"R3a AIF-3 2026-10-07T09:30:00Z","note":"the shift tried to move it to review and the board did not take it"}],"retried_env":[],"retried_run":[]},"cards":[
 {"ticket":"AIF-3","column":"in_progress","pos":1,
  "head":{"line":"taken: mac pid 6000 at 2026-10-07T09:00:00Z — aif work","at":"2026-10-07T09:00:01Z","after":0,"heads":[$TK]},
  "local":{"class":"built","lock":{"held":true,"live":false,"pid":6000},"run":{"where":"worktree","status":"built","branch_status":"built","branch_finished_at":"2026-10-07T09:30:00Z"},"report":{"head":"# AIF-3 — built"}}}]}
JSON

fx "the same ticket with a newer head — offered again" '.units[0].rule == "R7" and .units[0].key == "R7 AIF-108 2026-10-07T11:00:00Z" and (.lines | length) == 0' <<JSON
{$S,"build":{"mode":"none","parallel":2},"memory":{"done":[{"key":"R7 AIF-108 2026-10-07T09:30:02Z","note":"reviewed — rc 0"}],"retried_env":[],"retried_run":[]},"cards":[
 {"ticket":"AIF-108","column":"review","pos":1,"head":{"line":"# AIF-108 — built","at":"2026-10-07T11:00:00Z","after":0,"heads":[]},"local":{"class":"built","branch":{"exists":true},"lock":{"live":false}}}]}
JSON

fx "a card not read this tick — a line, and a wait" '(.units | length) == 0 and .lines[0].rule == "R1" and .lines[0].text == "not read — not read this tick" and .lines[0].command == "aif board head AIF-109" and .wait.why == "1 card not read yet" and ."end" == null' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-109","column":"review","pos":1,"unread":true,"unread_why":"not read this tick","head":null}]}
JSON

# ---------------------------------------------------------------- the end
fx "R21: nothing left — the end" '(.units | length) == 0 and .wait == null and ."end" == {"rc":0,"why":"nothing left for the shift"}' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[{"ticket":"AIF-110","column":"done","pos":1}]}
JSON

fx "R21 under --po — the owner" '.units[0].rule == "R21" and .units[0].prompt == "/aif-po" and .units[0].name == "aif po" and .units[0].key == "R21" and .units[0].role == "po" and ."end" == null' <<JSON
{$S,"flags":{"po":true},"build":{"mode":"none","parallel":2},"cards":[]}
JSON

fx "R21 under --po with a run in flight — a wait, not the owner" '(.units | length) == 0 and .wait.why == "1 being built" and ."end" == null' <<JSON
{$S,"flags":{"po":true},"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-111","column":"in_progress","pos":1,"head":{"line":"taken: mac pid 1 at x — aif work","after":0,"heads":[]},"local":{"class":"live","lock":{"live":true,"pid":1,"stage":"plan"}}}]}
JSON

fx "R21 offered once — a line, then the end" '(.units | length) == 0 and .lines[0].rule == "R21" and .lines[0].command == "claude '"'"'/aif-po'"'"'" and ."end".rc == 0' <<JSON
{$S,"flags":{"po":true},"build":{"mode":"none","parallel":2},"memory":{"done":[{"key":"R21","note":"owner — rc 0, nothing changed"}],"retried_env":[],"retried_run":[]},"cards":[]}
JSON

fx "never an end in a plan that has moves" '(.moves | length) == 1 and ."end" == null and .wait == null' <<JSON
{$S,"build":{"mode":"none","parallel":2},"cards":[
 {"ticket":"AIF-112","column":"review","pos":1,"head":{"line":"wrong: x","at":"t","after":0,"heads":[]}}]}
JSON

fx "the board's counts" '.counts == {"backlog":1,"ready":2,"in_progress":0,"review":0,"needs_human":0,"done":1}' <<JSON
{$S,"build":{"mode":"elsewhere","parallel":2,"loop":{"live":true,"pid":5}},"cards":[
 {"ticket":"AIF-113","column":"ready","pos":1},{"ticket":"AIF-114","column":"ready","pos":2},{"ticket":"AIF-115","column":"done","pos":1},
 {"ticket":"AIF-116","column":"backlog","pos":1,"ticket_file":true,"head":{"line":"cancelled: x","at":"t","after":0,"heads":[]}}]}
JSON

# The requests, read by bash from their headings alone (lib/requests.sh).
# Four shaped like a real project's (maps/board-set.md §5.4): a `## Status`
# right under its heading that says `not cut` while a ticket already names
# its first slice, a slice spanning paragraphs with an indented fenced block
# whose lines start with numbers; a `## Status` with a blank line before its
# value; two older requests with a `## Scope` and no `## Status` at all. The
# tickets name them every way a ticket does: the path, `./` before it, the
# file name, the bare slug; a slice as a number, as a string, and none.
R="$SANDBOX/req"
mkdir -p "$R/requests" "$R/tasks"
git -C "$R" init -q
cat >"$R/requests/allowance.md" <<'REQ'
# What a day may cost, from a goal

## Now
A goal is set and nothing says what a day may cost.

## After
Every day shows its allowance.

## Slices
1. The allowance from a goal: the user sets a goal and sees what a day may
   cost, worked out the way the bank's own app does it:

       ```
       1. the goal, less what is saved
       2. divided by the days left
       ```

   The second paragraph of the first slice.
2. The allowance moves with the day's spending.
3. A week at a glance.
4. A month at a glance.
5. A notice when a day goes over.

## Later, maybe
- a shared allowance

## Not this
- budgets per category

## Not worth it if
- nobody sets a goal

## Watch out
- rounding to the cent

## Status
not cut
REQ
cat >"$R/requests/history.md" <<'REQ'
# The history on connect, without waiting

## Now
A new connection shows nothing for a minute.

## Slices
1. The last month at once.
2. The rest in the background.

## Not this
- a progress bar

## Status

not cut
REQ
cat >"$R/requests/rhythm.md" <<'REQ'
# A daily rhythm of notices

## Now
Nothing reminds the user.

## Scope
- **Morning**: the day's allowance
  - only on days with a goal
- **Evening**: what was spent

## Later, maybe
- weekly digests
REQ
cat >"$R/requests/first-run.md" <<'REQ'
# The goal before the token, on first run

## Now
The first run asks for a bank token before anything else.

## Scope
- **Goal first**: the goal screen before the token screen

## Open
- what if the user skips the goal?
REQ
reqticket() { # <id> <meta fields, JSON without braces>
  mkdir -p "$R/tasks/$1"
  printf '<!-- aif:meta\n{ "schema": 2, "ticket": "%s"%s }\n-->\n# %s — a slice\n' "$1" "${2:+, $2}" "$1" >"$R/tasks/$1/ticket.md"
}
reqticket AIF-1 '"request": "requests/allowance.md", "slice": 1'
reqticket AIF-2 '"request": "./requests/history.md", "slice": 1'
reqticket AIF-3 '"request": "history", "slice": "2"'
reqticket AIF-4 '"request": "first-run.md"'
reqticket AIF-5 ''
mkdir -p "$R/tasks/AIF-6"
printf '<!-- aif:meta\n{ "schema": 2, "request": "rhythm.md", \n-->\n# AIF-6 — a meta that does not parse\n' >"$R/tasks/AIF-6/ticket.md"
req() { AIF_ROOT="$ROOT" /bin/bash -c 'set -euo pipefail; . "$1/lib/common.sh"; . "$1/lib/paths.sh"; . "$1/lib/requests.sh"; shift; "$@"' _ "$ROOT" "$@"; }
facts3() { printf '%s|%s|%s' "$(req aif_request_status "$1")" "$(req aif_request_slices "$1")" "$(req aif_request_shape "$1")"; }
eq "requests: a status right under its heading; five slices, a fenced block's numbers not counted" \
  "$(facts3 "$R/requests/allowance.md")" "not cut|5|slices"
eq "requests: a blank line before the status" "$(facts3 "$R/requests/history.md")" "not cut|2|slices"
eq "requests: old-format, a ## Scope and no ## Status — one slice, its shape scope" \
  "$(facts3 "$R/requests/rhythm.md"),$(facts3 "$R/requests/first-run.md")" "none|1|scope,none|1|scope"
sed 's/$/\r/' "$R/requests/history.md" >"$OUT/history-crlf.md"
eq "requests: the same request with CRLF line ends reads the same" "$(facts3 "$OUT/history-crlf.md")" "not cut|2|slices"
eq "requests: the tickets that name a request overrule its own line; a broken meta is passed over" \
  "$(req aif_requests_json "$R" | jq -c '[ .[] | [ .file, .status_line, .derived, .next_slice, .effective,
      ([ .tickets[] | .ticket + ":" + (.slice | tostring) ] | join(" ")) ] ]')" \
  '[["requests/allowance.md","not cut","cut in part",2,"cut in part","AIF-1:1"],["requests/first-run.md","none","cut",null,"cut","AIF-4:1"],["requests/history.md","not cut","cut",null,"cut","AIF-2:1 AIF-3:2"],["requests/rhythm.md","none",null,1,"not cut",""]]'
eq "requests: each has its sha — a key for one version of it" \
  "$(req aif_requests_json "$R" | jq -r '[ .[] | .sha | test("^[0-9a-f]{64}$") ] | all')" "true"

# =================================== B ======================================
printf '\nB. the start refuses before it touches anything\n'

# One project for the refusals (and later for a worker killed outright, and
# for the pty): a card the analyst would be offered, so a shift that did
# start has something to open.
PB="$SANDBOX/pB"
fresh_project "$PB"
ticket_for AIF-1
ticket_for AIF-2
git add -A && git commit -qm "tickets" >/dev/null
card AIF-1 needs_human
say AIF-1 "aif work" "blocked: ticket — not ready — the ready gate's questions are below, for the analyst"

# A profile of the developer's own (XDG_CONFIG_HOME), routed to an endpoint
# that maps the three aliases and nothing else — as glm does.
mkdir -p "$SANDBOX/xdg/aif/profiles"
cat >"$SANDBOX/xdg/aif/profiles/routed.profile" <<'PROFILE'
AIF_PROFILE_DESC="a routed endpoint that maps opus, sonnet and haiku (check-start)"
AIF_PROFILE_RUNNER="claude"
AIF_PROFILE_SET="claude"
AIF_PROFILE_SECRET_VAR=""
AIF_PROFILE_SECRET_TARGET=""
AIF_PROFILE_ISOLATE_CONFIG="0"
aif_profile_env() {
  cat <<'EOF'
ANTHROPIC_BASE_URL=http://127.0.0.1:9/anthropic
ANTHROPIC_DEFAULT_OPUS_MODEL=routed-large
ANTHROPIC_DEFAULT_SONNET_MODEL=routed-large
ANTHROPIC_DEFAULT_HAIKU_MODEL=routed-small
EOF
}
PROFILE

# refused <label> <rc> <text> <command…> — a start refused with <rc>, saying
# <text>, and nothing touched: the board's files as they were, no session
# opened, no shift lock and no loop lock, no shift directory. Run in RUN_IN
# when it is set (a worker's checkout), checked in the project.
RUN_IN=""
refused() {
  local label="$1" want="$2" text="$3" out sum n0 d0 rc=0 said=no
  shift 3
  out="$OUT/refused-$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '-' | cut -c1-40)"
  sum="$(board_sum)"
  n0="$(sessions_n)"
  d0="$(shift_dirs)"
  [ -z "$RUN_IN" ] || cd "$RUN_IN" || exit 1
  run_bg "$out" 30 "$@" || rc=$?
  cd "$PB" || exit 1
  ! grep -qF -- "$text" "$out" || said=yes
  eq "$label" "$rc,$said,$(board_sum),$(sessions_n),$(lock_gone),$([ -d .aif/state/loop ] && echo loop || echo noloop),$(shift_dirs)" \
    "$want,yes,$sum,$n0,gone,noloop,$d0"
}

refused "inside a Claude Code session (CLAUDECODE=1): 3" 3 "and this is already one — run it in a terminal" \
  env CLAUDECODE=1 "$AIF" start --no-build
git worktree add -q "$SANDBOX/pB-wt" -b side >/dev/null 2>&1
RUN_IN="$SANDBOX/pB-wt"
refused "in a worker's checkout: 3" 3 "aif start runs in the main checkout — this is a worker's" \
  "$AIF" start --no-build
RUN_IN=""
refused "a profile that does not load: 3" 3 "the profile nope does not load" \
  "$AIF" start --no-build --profile nope
jq '.board.kind = "trello" | .board.board_id = "b1"' .aif/project.json >"$OUT/trello-project.json" &&
  cp "$OUT/trello-project.json" .aif/project.json
refused "a board that fails its check (Trello, no credential): 3" 3 "the board is not reachable as configured" \
  "$AIF" start --no-build
git checkout -q -- .aif/project.json
refused "no terminal and no session seam: 3, before anything is opened" 3 "aif start needs a terminal" \
  env -u AIF_START_SESSION_CMD "$AIF" start --no-build
refused "--model-ba fable under a profile that maps only the three aliases: 1, naming what it maps" 1 \
  "--model-ba fable: the profile routed does not map fable (it maps opus, sonnet, haiku)" \
  env XDG_CONFIG_HOME="$SANDBOX/xdg" "$AIF" start --no-build --profile routed --model-ba fable

# A shift already open: one held on its session, in the background — its
# fake session waits for a file. A second is refused, naming the first's pid,
# and the first's lock stays its own; then the first is let go (its session
# changed nothing, so it pauses, and with no key left the pause ends it).
hold="$SANDBOX/hold-b"
HOLDS="$HOLDS $hold"
start_bg "$OUT/b-held.out" env AIF_START_KEYS=. FAKE_SESSION_HOLD="$hold" FAKE_SESSION_NOOP=1 "$AIF" start --no-build
held=$BG
wait_for "$SANDBOX/session.pid"
sum="$(board_sum)"
n0="$(sessions_n)"
rc=0
run_bg "$OUT/b-second.out" 30 "$AIF" start --no-build || rc=$?
eq "a shift already open: the second refused (3), naming the first's pid; no session of its own; the lock still the first's" \
  "$rc,$(grep -c "a shift is already open on this checkout (pid $held, since " "$OUT/b-second.out"),$(sessions_n),$(jq -r .pid .aif/state/shift/owner.json 2>/dev/null),$(board_sum)" \
  "3,1,$n0,$held,$sum"
: >"$hold"
rc=0
wait_exit "$held" 20 || rc=$?
eq "…the first, let go, pauses on a session that changed nothing and ends at the pause; its lock gone" \
  "$rc,$(grep -c 'paused — the session changed nothing' "$OUT/b-held.out"),$(lock_gone)" "0,1,gone"

# A lock whose shift is gone: taken over, and said.
mkdir -p .aif/state/shift
dead_pid
printf '{ "pid": %s, "host": "x", "started_at": "2026-10-07T00:00:00Z", "started": 1 }\n' "$DEAD" >.aif/state/shift/owner.json
rc=0
run_bg "$OUT/b-dead.out" 30 env AIF_START_KEYS=q "$AIF" start --no-build || rc=$?
eq "a shift lock whose pid is gone: taken over, said, and released at the end" \
  "$rc,$(grep -c "the shift that held this checkout (pid $DEAD) is gone; taken over" "$OUT/b-dead.out"),$(lock_gone)" "0,1,gone"

# A card file that does not parse: the board's status cannot be read, twice.
printf '{' >.aif/board/AIF-X.json
rc=0
run_bg "$OUT/b-board.out" 30 env AIF_START_KEYS=q "$AIF" start --no-build || rc=$?
eq "a board that cannot be read twice: 3, said, the lock gone, the summary's code 3" \
  "$rc,$(grep -q 'the board did not answer twice' "$OUT/b-board.out" && echo said),$(lock_gone),$(jq -r .rc "$(newest_shift)/summary.json" 2>/dev/null)" "3,said,gone,3"
rm -f .aif/board/AIF-X.json

# =================================== C ======================================
printf '\nC. shifts end to end on the local board\n'

# One project for the rows a shift with --no-build meets in a day: a card
# built and waiting for its review (AIF-1), a review that said wrong:
# (AIF-2), a ticket the gate sent back to the analyst (AIF-3), a slice whose
# dependency landed (AIF-4 on AIF-5) behind a card already in Ready (AIF-6).
PC="$SANDBOX/pC"
fresh_project "$PC"
for t in AIF-1 AIF-2 AIF-3 AIF-5 AIF-6 AIF-7 AIF-8; do ticket_for "$t"; done
ticket_for AIF-4 '["AIF-5"]'
git add -A && git commit -qm "tickets" >/dev/null
git commit -q --allow-empty -m "aif: land AIF-5 — one-command user export"
card AIF-1 ready
rc=0
"$AIF" work AIF-1 >"$OUT/c-work1.out" 2>&1 || rc=$?
eq "setup: AIF-1 built, in Review" "$rc,$(col AIF-1),$(card_head AIF-1)" "0,review,# AIF-1 — built"
card AIF-2 review
say AIF-2 reviewer "wrong: the export misses the header row
The second line of the review."
card AIF-3 needs_human
say AIF-3 "aif work" "blocked: ticket — not ready — the ready gate's questions are below, for the analyst"
card AIF-5 "done"
card AIF-4 backlog
card AIF-6 ready
card AIF-7 "done"
card AIF-8 "done"

# --dry-run, first: the plan as it would run, and nothing touched.
sum="$(board_sum)"
n0="$(sessions_n)"
d0="$(shift_dirs)"
rc=0
run_bg "$OUT/c-dry.out" 30 "$AIF" start --dry-run --no-build || rc=$?
eq "--dry-run: the moves it would make, the units in order, the line for Ready" \
  "$rc,$(grep -c '^would move AIF-2 → backlog' "$OUT/c-dry.out"),$(grep -c 'the sweep → ready' "$OUT/c-dry.out"),$(grep -c '^units      1 review AIF-1' "$OUT/c-dry.out"),$(grep -c 'a dry run — nothing was posted, moved, opened or locked' "$OUT/c-dry.out")" \
  "0,1,1,1,1"
eq "--dry-run: the board's files as they were, no lock, no shift directory, no session" \
  "$(board_sum),$(lock_gone),$(shift_dirs),$(sessions_n)" "$sum,gone,$d0,$n0"

# The shift, with keys: Enter at the review (the review lands it), s at the
# analyst's rework, Enter at the analyst's blocked card. Before any key, the
# moves the rules make on their own: wrong: back to Backlog as rework:, and
# the sweep's release — no session for either.
n0="$(sessions_n)"
rc=0
run_bg "$OUT/c-shift1.out" 90 env AIF_START_KEYS=.s. "$AIF" start --no-build || rc=$?
S1="$(newest_shift)"
eq "a shift: Enter, s, Enter — then a wait for the loop Ready's cards are for, never \"nothing left\": q there, exit 0, the lock gone" \
  "$rc,$(jq -r .why "$S1/summary.json" 2>/dev/null),$(grep -c '^waiting — 3 in Ready — no loop runs on this checkout yet: aif work --loop --idle in another terminal' "$OUT/c-shift1.out"),$(jq -r '.next' "$S1/summary.json" 2>/dev/null),$(lock_gone)" \
  "0,ended while waiting (q),1,null,gone"
eq "…the review landed AIF-1: Done, and the land commit" \
  "$(col AIF-1),$(git log --oneline --fixed-strings --grep 'aif: land AIF-1 — ' | wc -l | tr -d ' ')" "done,1"
eq "…wrong: sent AIF-2 back to Backlog as rework:, the review's second line kept, with no session" \
  "$(col AIF-2),$(card_head AIF-2),$("$AIF" board show AIF-2 --json | jq -r '.comments[-1].text | split("\n")[1]'),$(grep -c '/aif-review AIF-2$' "$SANDBOX/sessions.log")" \
  "backlog,rework: the export misses the header row,The second line of the review.,0"
eq "…the sweep released AIF-4 to the bottom of Ready, in the shift's name, with no key" \
  "$(card_head AIF-4 | cut -c1-23),$(ready_list)" "released by aif start: ,AIF-6 AIF-4 AIF-3"
eq "…the analyst opened on blocked: ticket, and the card is back in Ready" \
  "$(col AIF-3),$(grep -c '^aif ba AIF-3|opus|' "$SANDBOX/sessions.log")" "ready,1"
sed -n "$((n0 + 1)),\$p" "$SANDBOX/sessions.log" >"$OUT/c-sessions1"
eq "…two sessions, each named for its role and card, the analyst on opus, the review on claude's own default, a fresh lower-case uuid each" \
  "$(cut -d'|' -f1,2,4 "$OUT/c-sessions1" | tr '\n' ';'),$(cut -d'|' -f3 "$OUT/c-sessions1" | grep -cE "$UUID_RE"),$(cut -d'|' -f3 "$OUT/c-sessions1" | sort -u | wc -l | tr -d ' ')" \
  "aif review AIF-1||/aif-review AIF-1;aif ba AIF-3|opus|/aif-ba AIF-3;,2,2"
eq "…the summary gives claude --resume <uuid> for each session, by uuid, under the claude configuration it ran with" \
  "$(cut -d'|' -f3 "$OUT/c-sessions1" | while read -r u; do grep -c "claude --resume $u   (aif " "$OUT/c-shift1.out"; done | tr '\n' ' '),$(jq -r '[ .sessions[] | .resume ] | join(";")' "$S1/summary.json")" \
  "1 1 ,$(cut -d'|' -f3 "$OUT/c-sessions1" | sed "s|^|CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR claude --resume |" | paste -sd ';' -)"
sed -n '/^shift ended/,$p' "$OUT/c-shift1.out" >"$OUT/c-summary1"
eq "…what is left: the skipped analyst with its command, and Ready with no loop with aif work --loop --idle" \
  "$(jq -r '[ .left[] | (.ticket // .column) + " " + .text + " · " + .command ] | join(";")' "$S1/summary.json"),$(grep -c "AIF-2 backlog · skipped at the control point · yours: claude '/aif-ba AIF-2'" "$OUT/c-summary1")" \
  "ready Ready holds 3 — no loop runs on this checkout · aif work --loop --idle;AIF-2 skipped at the control point · claude '/aif-ba AIF-2',1"

# The same project the next morning: a demo as expected on AIF-7, and the
# analyst's rework still waiting. p at the land pauses, Enter goes on and the
# land is offered again; no key at it then (a land is never made on its
# own); q at the analyst.
"$AIF" board move AIF-7 review >/dev/null
say AIF-7 "aif review" "demo: as expected — every user is in the export
to see by hand: run the export"
n0="$(sessions_n)"
rc=0
run_bg "$OUT/c-shift2.out" 60 env AIF_START_KEYS=p._q "$AIF" start --no-build || rc=$?
S2="$(newest_shift)"
eq "p at the control point pauses; Enter goes on, and the same unit is offered again" \
  "$(grep -c '^paused — at the control point, before: land AIF-7' "$OUT/c-shift2.out"),$(grep -c '^next: land AIF-7 ' "$OUT/c-shift2.out")" "1,2"
eq "no key at a land: not landed, left with aif land; q at the next unit: exit 0, no session" \
  "$rc,$(col AIF-7),$(git log --oneline --fixed-strings --grep 'aif: land AIF-7 — ' | wc -l | tr -d ' '),$(jq -r .why "$S2/summary.json"),$(jq -r '[ .left[] | select(.ticket == "AIF-7") | .text + " · " + .command ] | join(";")' "$S2/summary.json"),$(sessions_n)" \
  "0,review,0,ended at the control point (q),offered, not taken (no key) · aif land AIF-7,$n0"

# A session that fails ends the shift: claude exited 1, and no session
# follows it.
n0="$(sessions_n)"
rc=0
run_bg "$OUT/c-shift3.out" 60 env AIF_START_KEYS=_. FAKE_SESSION_RC=1 FAKE_SESSION_NOOP=1 "$AIF" start --no-build || rc=$?
S3="$(newest_shift)"
eq "a session that exits 1 ends the shift with 1 — one session, the lock gone" \
  "$rc,$(jq -r '[ .rc, (.why | startswith("claude exited 1 — a session that fails is not followed by another")) ] | map(tostring) | join(",")' "$S3/summary.json"),$(($(sessions_n) - n0)),$(lock_gone)" \
  "1,1,true,1,gone"

# A session that changed nothing pauses the shift, and the pause takes its
# key from the seam like every other wait: q.
rc=0
run_bg "$OUT/c-shift4.out" 60 env AIF_START_KEYS=_.q FAKE_SESSION_NOOP=1 "$AIF" start --no-build || rc=$?
eq "a session that changed nothing: paused, and q at the pause ends the shift, exit 0" \
  "$rc,$(grep -c '^paused — the session changed nothing' "$OUT/c-shift4.out"),$(jq -r .why "$(newest_shift)/summary.json")" \
  "0,1,ended at a pause (q)"

# The same, while a loop in another terminal builds: its card leaves Ready
# and gets its taken: line while the session is open. What a session is
# judged by is its own card, the set of cards, requests/ and tasks/, and
# HEAD — not the whole board, which the loop changes all the time — so the
# session that did nothing still pauses the shift.
hold="$SANDBOX/hold-c5"
marks="$SANDBOX/c5-marks"
mkdir -p "$marks"
HOLDS="$HOLDS $hold $marks/go"
start_bg "$OUT/c-shift5.out" env AIF_START_KEYS=_.q FAKE_SESSION_NOOP=1 FAKE_SESSION_HOLD="$hold" "$AIF" start --no-build
shift5=$BG
wait_for "$SANDBOX/session.pid"
start_bg "$OUT/c-loop5.out" env FAKE_SLEEP_IN="AIF-6:plan" FAKE_MARKS="$marks" FAKE_RELEASE="$marks/go" \
  AIF_WORK_LOOP_LOGDIR="$SANDBOX/c-loop5" "$AIF" work --loop --idle --parallel 1
loop5=$BG
wait_for "$marks/AIF-6-plan"
moved5="$(col AIF-6)"
: >"$hold"
rc=0
wait_exit "$shift5" 30 || rc=$?
eq "…the same while a loop elsewhere takes a card under the open session: still paused, q, exit 0" \
  "$moved5,$rc,$(grep -c '^paused — the session changed nothing' "$OUT/c-shift5.out"),$(jq -r .why "$(newest_shift)/summary.json")" \
  "in_progress,0,1,ended at a pause (q)"
rc=0
"$AIF" work --loop --drain >"$OUT/c-drain5.out" 2>&1 || rc=$?
: >"$marks/go"
rc2=0
wait_exit "$loop5" 60 || rc2=$?
eq "…the loop drained: the card it held built, nothing more taken" \
  "$rc,$rc2,$(col AIF-6),$(jq -r '.taken' "$SANDBOX/c-loop5/summary.json")" "0,0,review,1"

# Mode here — no --no-build, and no loop on this checkout: the shift runs the
# loop itself, in the foreground, its logs and summary.json in the shift's
# own directory; then reads that summary, not the loop's code (docs/DEFECTS.md
# 14.3), and offers the review of what it built — never the same Ready again.
PH="$SANDBOX/pH"
fresh_project "$PH"
ticket_for AIF-1
git add -A && git commit -qm "a ticket" >/dev/null
card AIF-1 ready
rc=0
run_bg "$OUT/h-shift.out" 90 env AIF_START_KEYS=. "$AIF" start || rc=$?
SH="$(newest_shift)"
eq "mode here: Enter at the build — the loop ran here, its summary in the shift's directory: taken 1, built 1" \
  "$rc,$(jq -r '[ .taken, .built ] | map(tostring) | join(",")' "$SH/loop-1/summary.json" 2>/dev/null),$(col AIF-1)" "0,1,1,review"
eq "…the next tick offers the review; the build was offered once" \
  "$(grep -c '^next: review AIF-1 ' "$OUT/h-shift.out"),$(grep -c '^next: build' "$OUT/h-shift.out"),$(jq -r '[ .units[] | .rule ] | join(" ")' "$SH/summary.json"),$(jq -r .why "$SH/summary.json")" \
  "1,1,R12,ended at the control point (q)"

# The same Ready is never built twice, which the row above cannot show: the
# loop empties Ready, and nothing is left to offer again. Here the loop
# leaves Ready as it was — its one card is held by a live worker elsewhere
# (a process whose command line is the worker's, its run lock signed) — and
# the build, its default `go`, is not offered a second time.
ticket_for AIF-2
git add -A && git commit -qm "a second ticket" >/dev/null
card AIF-2 ready
(exec -a "aif work AIF-2" sleep 120) &
held2=$!
BG_PIDS="$BG_PIDS $held2"
mkdir -p .aif/state/runs/AIF-2
printf '{ "ticket": "AIF-2", "pid": %s, "started_at": "%s" }\n' "$held2" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >.aif/state/runs/AIF-2/owner.json
rc=0
run_bg "$OUT/h2-shift.out" 90 env AIF_START_KEYS=.. "$AIF" start || rc=$?
SH="$(newest_shift)"
eq "a build that leaves Ready as it was is not offered again — the review lands AIF-1, one build, one loop, then nothing left" \
  "$rc,$(col AIF-1),$(grep -c '^next: build' "$OUT/h2-shift.out"),$(find "$SH" -maxdepth 1 -name 'loop-*' | wc -l | tr -d ' '),$(jq -r .why "$SH/summary.json")" \
  "0,done,1,1,nothing left for the shift"
kill "$held2" 2>/dev/null
wait "$held2" 2>/dev/null
forget "$held2"
rm -rf .aif/state/runs/AIF-2

# The commonest round trip of a shift in this terminal, in one shift: built,
# `wrong:` at the review, rework: to the analyst, back in Ready — and built
# again. The build's key was the Ready ids alone, the same both times, so the
# reworked card was read as built already and the shift ended with it in
# Ready; it is each card's entry into Ready.
PW="$SANDBOX/pW"
fresh_project "$PW"
ticket_for AIF-1
git add -A && git commit -qm "a ticket" >/dev/null
card AIF-1 ready
rc=0
run_bg "$OUT/w-shift.out" 120 env AIF_START_KEYS=.... FAKE_REVIEW=wrong "$AIF" start || rc=$?
SW="$(newest_shift)"
eq "built, wrong: at the review, the analyst's rework back in Ready — and built again in the same shift" \
  "$rc,$(grep -c '^next: build' "$OUT/w-shift.out"),$(grep -c '^next: analyst AIF-1 ' "$OUT/w-shift.out"),$(jq -r '[ .built ] | map(tostring) | join(",")' "$SW/loop-1/summary.json" "$SW/loop-2/summary.json" 2>/dev/null | paste -sd ' ' -),$(col AIF-1),$(jq -r .why "$SW/summary.json")" \
  "0,2,1,1 1,review,ended at the control point (q)"

# Pulls beside a loop in another terminal (a process whose command line is
# the loop's, its lock signed: parallel 2, Ready empty): the first two cards
# of Backlog whose ready gate passes are offered. Passed by — the countdown
# runs out, a pull's default is to leave it — and the next two are offered:
# the gates once stopped at the cards already passed by, so no other card was
# ever offered or listed, and the shift ended beside an idle loop with cards
# it could have pulled.
PP="$SANDBOX/pP"
fresh_project "$PP"
for t in AIF-2 AIF-3 AIF-4 AIF-5 AIF-6; do ticket_for "$t"; done
git add -A && git commit -qm "five to pull" >/dev/null
for t in AIF-2 AIF-3 AIF-4 AIF-5 AIF-6; do card "$t" backlog; done
(exec -a "aif work --loop --idle --parallel 2" sleep 120) &
lp=$!
BG_PIDS="$BG_PIDS $lp"
mkdir -p .aif/state/loop
printf '{ "pid": %s, "host": "x", "started_at": "%s", "parallel": 2, "idle": 1, "logdir": null }\n' "$lp" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >.aif/state/loop/owner.json
rc=0
run_bg "$OUT/p-shift.out" 60 env AIF_START_KEYS=__q "$AIF" start --no-build || rc=$?
SP="$(newest_shift)"
eq "pulls beside a loop elsewhere: AIF-2 and AIF-3 offered and passed by, then AIF-4 — q at it" \
  "$rc,$(grep -c '^next: pull AIF-2 ' "$OUT/p-shift.out"),$(grep -c '^next: pull AIF-3 ' "$OUT/p-shift.out"),$(grep -c '^next: pull AIF-4 ' "$OUT/p-shift.out"),$(jq -r .why "$SP/summary.json")" \
  "0,1,1,1,ended at the control point (q)"
eq "…the two passed by are lines with the move that pulls them, AIF-4 and AIF-5 left as offers, the loop said to run on" \
  "$(jq -r '[ .left[] | (.ticket // "-") + " " + (.command // "-") ] | join(";")' "$SP/summary.json")" \
  "AIF-2 aif board move AIF-2 ready;AIF-3 aif board move AIF-3 ready;AIF-4 aif board move AIF-4 ready;AIF-5 aif board move AIF-5 ready;- aif work --loop --drain"
kill "$lp" 2>/dev/null
wait "$lp" 2>/dev/null
forget "$lp"
rm -rf .aif/state/loop

# A loop in another terminal, idle, one at a time: its first card held at
# plan, a second waiting in Ready. The shift names the loop, offers no build
# and says no "no loop" — and waits for it, a tick a poll; once the card is
# built it offers the review. Then the loop is drained.
PE="$SANDBOX/pE"
fresh_project "$PE"
ticket_for AIF-1
ticket_for AIF-2
git add -A && git commit -qm "tickets" >/dev/null
card AIF-1 ready
card AIF-2 ready
marks="$SANDBOX/pE-marks"
mkdir -p "$marks"
HOLDS="$HOLDS $marks/go"
start_bg "$OUT/e-loop.out" env FAKE_SLEEP_IN="AIF-1:plan" FAKE_MARKS="$marks" FAKE_RELEASE="$marks/go" \
  AIF_WORK_LOOP_LOGDIR="$SANDBOX/e-loop" "$AIF" work --loop --idle --parallel 1
eloop=$BG
wait_for .aif/state/loop/owner.json
wait_for "$marks/AIF-1-plan"
# Sixty `_`: each wait is one poll of a second; the review, once offered,
# takes one (no key: it opens), and the pause after it another (q).
keys=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do keys="${keys}__"; done
n0="$(sessions_n)"
start_bg "$OUT/e-shift.out" env AIF_START_KEYS="$keys" FAKE_SESSION_NOOP=1 "$AIF" start --no-build
eshift=$BG
wait_said "$OUT/e-shift.out" "^waiting — " 20
eq "a loop in another terminal: named with its pid in the header; no build offered, no 'no loop' line; the shift waits for it" \
  "$(grep -c "build: the loop in another terminal (pid $eloop, idle)" "$OUT/e-shift.out"),$(grep -c '^next: build' "$OUT/e-shift.out"),$(grep -c 'no loop runs on this checkout' "$OUT/e-shift.out"),$(grep -q "^waiting — 1 being built, 1 in Ready — the loop in another terminal (pid $eloop)" "$OUT/e-shift.out" && echo waits)" \
  "1,0,0,waits"
: >"$marks/go"
rc=0
wait_exit "$eshift" 90 || rc=$?
eq "…the card built, the review offered (no key: opened; it changed nothing: paused; no key: q)" \
  "$rc,$(grep -c '^next: review AIF-1 ' "$OUT/e-shift.out"),$(sed -n "$((n0 + 1)),\$p" "$SANDBOX/sessions.log" | grep -c '^aif review AIF-1|'),$(grep -c '^next: build' "$OUT/e-shift.out")" \
  "0,1,1,0"
rc=0
"$AIF" work --loop --drain >"$OUT/e-drain.out" 2>&1 || rc=$?
rc2=0
wait_exit "$eloop" 60 || rc2=$?
eq "…and the loop drained" "$rc,$rc2,$(jq -r '.why | startswith("drained by")' "$SANDBOX/e-loop/summary.json")" "0,0,true"

# A worker killed outright mid-plan (kill -9), started under set -m as the
# loop starts its runs, so its station is left running in the group it led
# (docs/DEFECTS.md 14.1). The shift's requeue stops that group, and only
# then puts the card back at the top of Ready, saying why.
cd "$PB" || exit 1
ticket_for AIF-3
git add -A && git commit -qm "two more tickets" >/dev/null
card AIF-2 ready
card AIF-3 ready
set -m
FAKE_SLEEP_IN="AIF-2:plan" FAKE_SLEEP_SECS=41 "$AIF" work AIF-2 >"$OUT/r-work.out" 2>&1 &
w=$!
set +m
wait_for .aif/worktrees/AIF-2/.aif/tmp/fake-running-AIF-2-plan
kill -9 "$w" 2>/dev/null
wait "$w" 2>/dev/null
eq "setup: the worker killed, its station still running" \
  "$(col AIF-2),$(pgrep -f "$SANDBOX/fake-station.sh plan AIF-2" | wc -l | tr -d ' ')" "in_progress,1"
rc=0
run_bg "$OUT/r-shift.out" 60 env AIF_START_KEYS=. "$AIF" start --no-build || rc=$?
eq "R3b: Enter — the dead worker's station stopped, the card at the top of Ready, saying why; the harness untouched" \
  "$rc,$(pgrep -f "$SANDBOX/fake-station.sh plan AIF-2" | wc -l | tr -d ' '),$(ready_list),$(card_head AIF-2 | grep -c "^released by aif start: its worker (pid $w) was gone mid-plan"),$(kill -0 $$ && echo alive)" \
  "0,0,AIF-2 AIF-3,1,alive"

# The same, with a child the dead worker's group gains after the shift has
# read what it left: no listing names it — it went to / with no ticket in its
# argv — and only the TERM to the whole group reaches it. A requeue that
# signalled each listed pid alone passed every row above (a mutation,
# docs/DEFECTS.md 14.1); here the countdown runs out (`_`, 5 s) while the
# child is started, and the requeue must leave nothing of the group behind.
ticket_for AIF-4
git add -A && git commit -qm "one more for the group" >/dev/null
card AIF-4 ready
set -m
FAKE_SLEEP_IN="AIF-4:plan" FAKE_RELEASE="$SANDBOX/rel-4" FAKE_CHILD_AFTER="$SANDBOX/child-4" \
  "$AIF" work AIF-4 >"$OUT/r4-work.out" 2>&1 &
w=$!
set +m
HOLDS="$HOLDS $SANDBOX/rel-4"
wait_for .aif/worktrees/AIF-4/.aif/tmp/fake-running-AIF-4-plan
kill -9 "$w" 2>/dev/null
wait "$w" 2>/dev/null
start_bg "$OUT/r4-shift.out" env AIF_START_KEYS=_ AIF_START_WAIT=5 "$AIF" start --no-build
r4=$BG
wait_said "$OUT/r4-shift.out" "next: requeue AIF-4 " 20
: >"$SANDBOX/child-4"
i=0
while ! pgrep -f 'sleep 58.7' >/dev/null 2>&1 && [ "$i" -lt 30 ]; do
  sleep 0.1
  i=$((i + 1))
done
born="$(pgrep -f 'sleep 58.7' | wc -l | tr -d ' ')"
rc=0
wait_exit "$r4" 60 || rc=$?
eq "R3b: a child the group gains after the facts were read — gone with the group, the card back at the top of Ready; the harness untouched" \
  "$born,$rc,$(pgrep -f 'sleep 58.7' | wc -l | tr -d ' '),$(pgrep -f "$SANDBOX/fake-station.sh plan AIF-4" | wc -l | tr -d ' '),$(ready_list | cut -d' ' -f1),$(kill -0 $$ && echo alive)" \
  "1,0,0,0,AIF-4,alive"
pkill -f 'sleep 58.7' 2>/dev/null

# Another clone of a project on this machine building the same id: its
# station carries the same prompt in its argv, and it is not this card's to
# stop. Here the dead worker left nothing; the requeue lists nothing, TERMs
# nothing, and the other clone's build goes on (docs/DEFECTS.md 15.4).
fresh_project "$SANDBOX/pB2"
ticket_for AIF-5
git add -A && git commit -qm "the same id, another checkout" >/dev/null
card AIF-5 ready
start_bg "$OUT/r5-other.out" env FAKE_SLEEP_IN="AIF-5:plan" FAKE_RELEASE="$SANDBOX/rel-5" "$AIF" work AIF-5
r5o=$BG
HOLDS="$HOLDS $SANDBOX/rel-5"
wait_for .aif/worktrees/AIF-5/.aif/tmp/fake-running-AIF-5-plan
other="$(cat .aif/state/runs/AIF-5/station 2>/dev/null)"
cd "$PB" || exit 1
ticket_for AIF-5
git add -A && git commit -qm "AIF-5 here too" >/dev/null
card AIF-5 ready
set -m
FAKE_SLEEP_IN="AIF-5:plan" FAKE_SLEEP_SECS=42 "$AIF" work AIF-5 >"$OUT/r5-work.out" 2>&1 &
w=$!
set +m
wait_for .aif/worktrees/AIF-5/.aif/tmp/fake-running-AIF-5-plan
kill -9 -- "-$w" 2>/dev/null
wait "$w" 2>/dev/null
rc=0
run_bg "$OUT/r5-shift.out" 60 env AIF_START_KEYS=. "$AIF" start --no-build || rc=$?
eq "R3b: another clone's station on the same id is not listed, and survives the requeue" \
  "$rc,$(grep -c 'next: requeue AIF-5 .* · [0-9]* process' "$OUT/r5-shift.out"),$(ready_list | cut -d' ' -f1),$(kill -0 "${other:-999999}" 2>/dev/null && echo alive)" \
  "0,0,AIF-5,alive"
: >"$SANDBOX/rel-5"
rc=0
wait_exit "$r5o" 60 || rc=$?
eq "…and that clone's build finishes on its own" "$rc,$(cd "$SANDBOX/pB2" && col AIF-5)" "0,review"

# A process someone opened in a dead worker's worktree — nothing but its
# directory ties it to the run: the shift neither stops it nor requeues the
# card while it runs, and the line names it (docs/DEFECTS.md 14.1). It used
# to be TERMed with the rest, and the card put back for the next worker to
# dispatch into the tree beside it.
fresh_project "$SANDBOX/pR"
ticket_for AIF-6
git add -A && git commit -qm "one with a shell in its worktree" >/dev/null
card AIF-6 in_progress
mkdir -p .aif/worktrees/AIF-6
(cd .aif/worktrees/AIF-6 && exec sleep 57.9 >/dev/null 2>&1) &
hand=$!
dead_pid
mkdir -p .aif/state/runs/AIF-6
printf '{ "ticket": "AIF-6", "pid": %s, "started_at": "2026-10-02T00:00:00Z" }\n' "$DEAD" >.aif/state/runs/AIF-6/owner.json
printf 'run\n' >.aif/state/runs/AIF-6/phase
rc=0
run_bg "$OUT/r6-shift.out" 60 env AIF_START_KEYS=. "$AIF" start --no-build || rc=$?
eq "R3b: a process opened by hand in a dead worker's worktree — named in a line, never signalled, the card not requeued" \
  "$rc,$(kill -0 "$hand" 2>/dev/null && echo alive),$(col AIF-6),$(jq -r '.left[] | select(.ticket == "AIF-6") | .text' "$(newest_shift)/summary.json" 2>/dev/null | grep -c "pid $hand (sleep 57.9) runs in its worktree — nothing but the directory ties it to the run"),$(grep -c '^next: requeue' "$OUT/r6-shift.out")" \
  "0,alive,in_progress,1,0"
kill "$hand" 2>/dev/null
wait "$hand" 2>/dev/null

# A loop in another terminal holding the one card in Ready — its worker
# exited before its claim, the stations gone from the checkout after the
# loop's preflight — is no work in flight: the shift waited on it until the
# person pressed q (docs/DEFECTS.md 15.3). Now the card is a line with why and
# the command, and with nothing else left the shift ends.
fresh_project "$SANDBOX/pH3"
ticket_for AIF-7
git add -A && git commit -qm "one for a held card" >/dev/null
start_bg "$OUT/h3-loop.out" env AIF_WORK_LOOP_LOGDIR="$SANDBOX/h3-loop" "$AIF" work --loop --idle --parallel 1 --no-tui
hloop=$BG
wait_said "$SANDBOX/h3-loop/loop.log" "Ready is empty — idle" 30
mv .claude/agents/aif-implement.md "$OUT/aif-implement.md.h3"
card AIF-7 ready
wait_said "$SANDBOX/h3-loop/loop.log" "Ready holds only cards this loop will not take again" 30
mv "$OUT/aif-implement.md.h3" .claude/agents/aif-implement.md
rc=0
run_bg "$OUT/h3-shift.out" 60 env AIF_START_KEYS=____ "$AIF" start --no-build || rc=$?
SH3="$(newest_shift)"
eq "a loop elsewhere holding the one card in Ready: no wait for it — a line with why and aif work AIF-7 — and the shift ends" \
  "$rc|$(grep -c '^waiting — ' "$OUT/h3-shift.out")|$(jq -r '.why' "$SH3/summary.json" 2>/dev/null)|$(jq -r '[.left[] | select(.ticket == "AIF-7") | .command] | join(",")' "$SH3/summary.json" 2>/dev/null)|$(jq -r '.left[] | select(.ticket == "AIF-7") | .text' "$SH3/summary.json" 2>/dev/null)" \
  "0|0|nothing left for the shift|aif work AIF-7|the loop in another terminal will not take it again — its worker exited 1 before it took the card: the stations are not installed — run 'aif init'; aif work AIF-7, or restart the loop"
"$AIF" work --loop --drain >/dev/null 2>&1
wait_exit "$hloop" 60 >/dev/null || true

# =================================== T ======================================
printf '\nT. Trello — the stand-in server, with the real clock\n'

# scripts/mock-trello.py as check-board starts it, but with MOCK_REAL_TIME=1:
# a comment gets the time it was posted and a card the time of its last
# activity, the two clocks the shift reads on Trello — whether a card
# changed since its head was read (its column and its last activity), and
# whether a block came during the shift (its head's time against the
# shift's start).
MOCK_REAL_TIME=1 python3 "$ROOT/scripts/mock-trello.py" 0 >"$OUT/mock.port" 2>"$OUT/mock.err" &
MOCK_PID=$!
i=0
while [ ! -s "$OUT/mock.port" ] && [ "$i" -lt 50 ]; do
  sleep 0.1
  i=$((i + 1))
done
PORT="$(head -1 "$OUT/mock.port")"
if [ -z "$PORT" ]; then
  bad "the mock server did not start ($(head -2 "$OUT/mock.err"))"
else
  export AIF_TRELLO_API="http://127.0.0.1:$PORT/1" TRELLO_KEY=k TRELLO_TOKEN=t
  PT="$SANDBOX/pT"
  fresh_project "$PT"
  for t in AIF-1 AIF-2 AIF-3; do ticket_for "$t"; done
  "$AIF" board init trello --board b1 --create-lists >"$OUT/t-init.out" 2>&1
  git add -A && git commit -qm "tickets, the board" >/dev/null
  # The host as the worker's claim writes it — `hostname -s`, which on a Mac
  # is not `hostname` (lib/common.sh aif_host_short).
  HOST="$(AIF_ROOT="$ROOT" /bin/bash -c '. "$1/lib/common.sh"; aif_host_short' _ "$ROOT")"
  now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

  # A worker of this machine took AIF-1 and is gone: its lock held, its pid
  # dead, its claim the newest on the card.
  "$AIF" board create tasks/AIF-1/ticket.md >/dev/null
  "$AIF" board move AIF-1 in_progress >/dev/null
  dead_pid
  say AIF-1 "aif work" "taken: $HOST pid $DEAD at $(now) — aif work"
  mkdir -p .aif/state/runs/AIF-1
  printf '{ "ticket": "AIF-1", "pid": %s, "started_at": "%s" }\n' "$DEAD" "$(now)" >.aif/state/runs/AIF-1/owner.json
  rc=0
  run_bg "$OUT/t-dry1.out" 30 "$AIF" start --dry-run --no-build || rc=$?
  eq "Trello: In Progress, the newest taken: this host's, its worker gone — the requeue offered (--dry-run)" \
    "$rc,$(grep -c "^units      1 requeue AIF-1 — its worker (pid $DEAD) is gone" "$OUT/t-dry1.out")" "0,1"
  sleep 1
  say AIF-1 "aif work" "taken: elsewhere pid 9 at $(now) — aif work"
  rc=0
  run_bg "$OUT/t-dry2.out" 30 "$AIF" start --dry-run --no-build || rc=$?
  eq "Trello: the same card, another host's claim newer — a line, nothing offered" \
    "$rc,$(grep -c '^units' "$OUT/t-dry2.out"),$(grep -c "AIF-1 in_progress · taken by elsewhere pid 9 at .* — built there; nothing to do here" "$OUT/t-dry2.out")" "0,0,1"

  # A shift that waits on a run live here (a process whose command line is
  # the worker's), with a card the environment blocked BEFORE it started. A
  # block posted DURING the shift moves the card's last activity, so its head
  # is read again; newer than the shift, it goes back to Ready behind one
  # preflight — Trello's dates, milliseconds and all, against this machine's.
  (exec -a "aif work AIF-3" sleep 120) &
  live=$!
  BG_PIDS="$BG_PIDS $live"
  "$AIF" board create tasks/AIF-3/ticket.md >/dev/null
  "$AIF" board move AIF-3 in_progress >/dev/null
  say AIF-3 "aif work" "taken: $HOST pid $live at $(now) — aif work"
  mkdir -p .aif/state/runs/AIF-3
  printf '{ "ticket": "AIF-3", "pid": %s, "started_at": "%s" }\n' "$live" "$(now)" >.aif/state/runs/AIF-3/owner.json
  "$AIF" board create tasks/AIF-2/ticket.md >/dev/null
  "$AIF" board move AIF-2 needs_human >/dev/null
  say AIF-2 "aif work" "blocked: environment — the suite could not start (exit 7)"
  sleep 1.2
  keys=""
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do keys="${keys}__"; done
  start_bg "$OUT/t-shift.out" env AIF_START_KEYS="$keys" FAKE_SESSION_NOOP=1 "$AIF" start --no-build
  tshift=$BG
  wait_said "$OUT/t-shift.out" "^waiting — " 20
  before="$(grep -c 'AIF-2 needs_human · blocked by the environment before this shift' "$OUT/t-shift.out")"
  say AIF-2 "aif work" "blocked: environment — the suite could not start again (exit 7)"
  i=0
  while [ "$(col AIF-2)" != ready ] && [ "$i" -lt 40 ]; do
    sleep 0.5
    i=$((i + 1))
  done
  kill -TERM "$tshift" 2>/dev/null
  rc=0
  wait_exit "$tshift" 20 || rc=$?
  kill "$live" 2>/dev/null
  wait "$live" 2>/dev/null
  forget "$live"
  eq "Trello: a block from before the shift is a line; one posted during it is read again and goes back to Ready, said" \
    "$before,$(col AIF-2),$(card_head AIF-2 | grep -c '^released by aif start: blocked by the environment during this shift; the preflight passes again')" "1,ready,1"
  eq "…a TERM ends the shift: 143, the summary, the lock gone" \
    "$rc,$(jq -r '[ .rc, .why ] | map(tostring) | join(",")' "$(newest_shift)/summary.json"),$(lock_gone)" "143,143,stopped by a TERM signal,gone"
  unset AIF_TRELLO_API TRELLO_KEY TRELLO_TOKEN
fi
kill "$MOCK_PID" 2>/dev/null
wait "$MOCK_PID" 2>/dev/null
MOCK_PID=""

# =================================== D ======================================
printf '\nD. a real terminal — a pty, no key seam\n'

# The shift on a pty, keys typed: AIF_START_KEYS unset, the session still the
# fake, a countdown of a minute so that a key or a close lands in it by
# construction — each only once the `next:` line is on the screen. Modes:
#   ctrlc         under `bash -c '…; echo RC=$?; stty -a'`: Ctrl-C at the
#                 control point
#   sessionctrlc  the same wrapper: Enter (a held session opens), Ctrl-C in
#                 the session, then q at the pause it leaves
#   ua            the same wrapper: і — the s key on the Ukrainian layout —
#                 at the control point, then q at whatever comes next
#   unknown       the same wrapper: z, a key no unit has, then q at the pause
#   tstp          the same wrapper: Enter, a session that stops itself as
#                 claude does on Ctrl+Z; once it says it resumed, a line for
#                 it to read, and q at the pause after it
#   k9            the same wrapper: Enter, a session killed -9 in claude's
#                 screen modes (under --max-units 1, the last unit)
#   close         the shift is the pty's child itself — as a terminal's shell
#                 runs it, the one the hang-up reaches first (a wrapper would
#                 die of the HUP and hide the shift's exit, critics
#                 testability-3): the master closed at the control point
#   pauseclose    the same child: Enter, a session that changes nothing, and
#                 the master closed at the pause
#   tstpclose     the same child: Enter, a session that stops itself, and the
#                 master closed while it is stopped
#   nohupclose    a leader that ignores the hang-up, as a shell that does not
#                 pass it on, with the shift its child: the master closed at
#                 the control point — no HUP reaches the shift, which finds
#                 the terminal gone itself
#   leaderdies    a leader that dies of the hang-up and passes it on to
#                 nobody — zsh with NO_HUP — with the shift a job of its own
#                 in the foreground: Enter (a held session opens), the master
#                 closed; the kernel hangs up on the foreground group, the
#                 session's, and the shift is nobody's child to wait for
# Prints `exit N`, `signal N` or `timeout`; the screen, colour taken off, to
# <out>, and as it came to <out>.raw.
cat >"$SANDBOX/terminal.py" <<'PY3'
import fcntl, os, pty, re, select, signal, struct, sys, termios, time
mode, out, opened = sys.argv[1:4]
argv = sys.argv[4:]
env = dict(os.environ)
env.pop("AIF_START_KEYS", None)
env["TERM"] = "xterm-256color"
env["AIF_START_WAIT"] = "60"
pid, fd = pty.fork()
if pid == 0:
    if mode in ("close", "pauseclose", "tstpclose"):
        os.execve(argv[0], argv, env)
    if mode == "nohupclose":
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        c = os.fork()
        if c == 0:
            signal.signal(signal.SIGHUP, signal.SIG_DFL)
            os.execve(argv[0], argv, env)
        _, st = os.waitpid(c, 0)
        os._exit(os.WEXITSTATUS(st) if os.WIFEXITED(st) else 128 + os.WTERMSIG(st))
    if mode == "leaderdies":
        r, w = os.pipe()
        c = os.fork()
        if c == 0:
            os.setpgid(0, 0)
            os.close(w)
            os.read(r, 1)
            os.execve(argv[0], argv, env)
        os.setpgid(c, c)
        signal.signal(signal.SIGTTOU, signal.SIG_IGN)
        os.tcsetpgrp(0, c)
        os.write(w, b"x")
        os.waitpid(c, 0)
        os._exit(0)
    os.execve("/bin/bash", ["/bin/bash", "-c", '"$0" "$@"; echo "RC=$?"; stty -a'] + argv, env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 160, 0, 0))
buf = b""
live = True
def pump(secs, until=None, since=0):
    global buf, live
    end = time.time() + secs
    while live and time.time() < end:
        if until is not None and re.search(until, buf[since:]):
            return True
        if select.select([fd], [], [], 0.1)[0]:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                live = False
                break
            if not chunk:
                live = False
                break
            buf += chunk
    return until is not None and re.search(until, buf[since:]) is not None
def send(b):
    # A child already gone answers EIO: the screen is still written below.
    try:
        os.write(fd, b)
    except OSError:
        pass
def opens():
    end = time.time() + 10
    while not os.path.exists(opened) and time.time() < end:
        pump(0.1)
pump(30, rb"next: ")
time.sleep(0.5)
if mode == "ctrlc":
    send(b"\x03")
elif mode == "sessionctrlc":
    send(b"\r")
    opens()
    time.sleep(0.5)
    send(b"\x03")
    pump(10, rb"paused")
    time.sleep(0.5)
    send(b"q")
elif mode == "ua":
    mark = len(buf)
    send("\u0456".encode("utf-8"))
    pump(10, rb"waiting|paused|shift ended", mark)
    time.sleep(0.5)
    send(b"q")
elif mode == "unknown":
    mark = len(buf)
    send(b"z")
    pump(10, rb"paused", mark)
    time.sleep(0.5)
    send(b"q")
elif mode == "tstp":
    send(b"\r")
    pump(15, rb"resumed")
    mark = len(buf)
    time.sleep(0.5)
    send(b"x\r")
    pump(10, rb"paused", mark)
    time.sleep(0.5)
    send(b"q")
elif mode == "k9":
    send(b"\r")
elif mode in ("pauseclose",):
    send(b"\r")
    pump(10, rb"paused")
    time.sleep(0.5)
elif mode == "tstpclose":
    send(b"\r")
    pump(10, rb"suspended")
    time.sleep(0.3)
elif mode == "leaderdies":
    send(b"\r")
    opens()
    time.sleep(0.5)
if mode in ("close", "pauseclose", "tstpclose", "nohupclose", "leaderdies"):
    os.close(fd)
    live = False
status = None
end = time.time() + 20
while time.time() < end:
    if live:
        pump(0.1)
    else:
        time.sleep(0.1)
    r, st = os.waitpid(pid, os.WNOHANG)
    if r:
        status = st
        break
if live:
    pump(1)
open(out + ".raw", "wb").write(buf)
text = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", buf.decode(errors="replace")).replace("\r", "")
open(out, "w").write(text)
if status is None:
    try:
        os.killpg(pid, signal.SIGKILL)
    except OSError:
        pass
    print("timeout")
elif os.WIFEXITED(status):
    print("exit %d" % os.WEXITSTATUS(status))
else:
    print("signal %d" % os.WTERMSIG(status))
PY3

# words <file> — the output's words one a line, for the terminal's modes as
# `stty -a` prints them (icanon, -icanon, …).
words() { awk -F'[ ;\t]+' '{ for (i = 1; i <= NF; i++) if ($i != "") print $i }' "$1"; }
cd "$PB" || exit 1
rm -f "$SANDBOX/session.pid"

n0="$(sessions_n)"
r="$(python3 "$SANDBOX/terminal.py" ctrlc "$OUT/d-ctrlc.out" "$SANDBOX/session.pid" "$AIF" start --no-build)"
eq "a Ctrl-C at the control point: the shift ends 130, the terminal back in icanon and echo, the lock gone, no session" \
  "$r,$(grep -c '^RC=130$' "$OUT/d-ctrlc.out"),$(words "$OUT/d-ctrlc.out" | grep -cx icanon),$(words "$OUT/d-ctrlc.out" | grep -cx -- -icanon),$(words "$OUT/d-ctrlc.out" | grep -cx echo),$(words "$OUT/d-ctrlc.out" | grep -cx -- -echo),$(lock_gone),$(sessions_n)" \
  "exit 0,1,1,0,1,0,gone,$n0"
eq "…and said why, the summary on the screen" \
  "$(grep -c 'shift ended — stopped by Ctrl-C · exit 130' "$OUT/d-ctrlc.out")" "1"

hold="$SANDBOX/hold-d-never"
r="$(FAKE_SESSION_HOLD="$hold" python3 "$SANDBOX/terminal.py" sessionctrlc "$OUT/d-session.out" "$SANDBOX/session.pid" "$AIF" start --no-build)"
eq "a Ctrl-C inside a session ends the session (130), not the shift: it pauses, and q ends it with 0" \
  "$r,$(grep -c '^paused — the session ended by a signal (130)' "$OUT/d-session.out"),$(grep -c 'stopped by Ctrl-C' "$OUT/d-session.out"),$(grep -c '^RC=0$' "$OUT/d-session.out"),$(words "$OUT/d-session.out" | grep -cx -- -icanon),$(lock_gone)" \
  "exit 0,1,0,1,0,gone"

n0="$(sessions_n)"
r="$(python3 "$SANDBOX/terminal.py" close "$OUT/d-close.out" "$SANDBOX/session.pid" "$AIF" start --no-build)"
SD="$(newest_shift)"
eq "the window closed at the control point: the shift exits 129 itself (not killed by the signal), the lock gone, no session" \
  "$r,$(lock_gone),$(sessions_n)" "exit 129,gone,$n0"
eq "…its summary in shift.log, and summary.json says it was the hang-up" \
  "$(grep -c '^shift ended — the terminal closed (HUP) · exit 129' "$SD/shift.log"),$(jq -r '[.hup, .rc] | map(tostring) | join(",")' "$SD/summary.json")" "1,true,129"

r="$(FAKE_SESSION_NOOP=1 python3 "$SANDBOX/terminal.py" pauseclose "$OUT/d-pause.out" "$SANDBOX/session.pid" "$AIF" start --no-build)"
SD="$(newest_shift)"
eq "the window closed at a pause: 129, at once, no spin; the lock gone" \
  "$r,$(grep -c '^paused — the session changed nothing' "$OUT/d-pause.out"),$(jq -r '.hup' "$SD/summary.json"),$(lock_gone)" "exit 129,1,true,gone"

# Keys the person did not mean as the shift reads them. bash 3.2 reads one
# byte, and і — the s key on the Ukrainian layout, typed by a person who
# just wrote Ukrainian in a session — was two bytes, neither a key: the
# countdown ran on and did the default. Read as s now. And a key no unit has
# pauses, the pause naming the keys: the default never follows a keypress.
n0="$(sessions_n)"
r="$(python3 "$SANDBOX/terminal.py" ua "$OUT/d-ua.out" "$SANDBOX/session.pid" "$AIF" start --no-build)"
SD="$(newest_shift)"
eq "і at the control point — s on the Ukrainian layout: the unit skipped, no session; q ends the shift, 0" \
  "$r,$(grep -c '^RC=0$' "$OUT/d-ua.out"),$(jq -r '[.units[0].rule, .units[0].what] | join(",")' "$SD/summary.json"),$(sessions_n),$(lock_gone)" \
  "exit 0,1,R19b,skipped,$n0,gone"
r="$(python3 "$SANDBOX/terminal.py" unknown "$OUT/d-unknown.out" "$SANDBOX/session.pid" "$AIF" start --no-build)"
eq "a key no unit has: a pause that names the keys, nothing done, no session; q ends the shift, 0" \
  "$r,$(grep -c '^paused — z is none of this unit.s keys (Enter: open · s: skip · p: pause · q: end the shift)' "$OUT/d-unknown.out"),$(grep -c '^RC=0$' "$OUT/d-unknown.out"),$(sessions_n),$(lock_gone)" \
  "exit 0,1,1,$n0,gone"

# Ctrl-Z inside a session: claude stops its own group, and a non-interactive
# bash under `set -m` never returns from a foreground wait on a stopped child
# (docs/FINDINGS.md #28) — the terminal stayed with the stopped group, and a
# window closed then left the shift alive, holding its lock. The shift's
# watcher continues it within a second.
rm -f "$SANDBOX/session.pid"
r="$(FAKE_SESSION_TSTP=1 FAKE_SESSION_TTY=1 FAKE_SESSION_NOOP=1 python3 "$SANDBOX/terminal.py" tstp "$OUT/d-tstp.out" "$SANDBOX/session.pid" "$AIF" start --no-build)"
eq "Ctrl-Z in a session: continued, said, and the session goes on to its end — then the pause, q, exit 0" \
  "$r,$(grep -c 'resumed$' "$OUT/d-tstp.out"),$(grep -c 'Ctrl-Z does nothing inside a shift' "$OUT/d-tstp.out"),$(grep -c '^paused — the session changed nothing' "$OUT/d-tstp.out"),$(grep -c '^RC=0$' "$OUT/d-tstp.out"),$(lock_gone)" \
  "exit 0,1,1,1,1,gone"
r="$(FAKE_SESSION_TSTP=1 FAKE_SESSION_TTY=1 FAKE_SESSION_NOOP=1 python3 "$SANDBOX/terminal.py" tstpclose "$OUT/d-tstpclose.out" "$SANDBOX/session.pid" "$AIF" start --no-build)"
SD="$(newest_shift)"
eq "the window closed over a session stopped by Ctrl-Z: continued, it leaves on the closed terminal, the shift exits 129 — the lock gone" \
  "$r,$(jq -r '[.rc, .hup] | map(tostring) | join(",")' "$SD/summary.json" 2>/dev/null),$(lock_gone)" "exit 129,129,true,gone"
eq "…the session open when the window closed is in the summary, done, with its claude --resume <uuid>; not left as untouched" \
  "$(jq -r '[.units[0].what, (.sessions | length), (.sessions[0].resume | test("^(CLAUDE_CONFIG_DIR=[^ ]+ )?claude --resume [0-9a-f-]{36}$")), ([.left[] | select(.ticket == "AIF-1")] | length)] | map(tostring) | join(",")' "$SD/summary.json" 2>/dev/null)" \
  "open when the shift ended,1,true,0"

# A closed window whose hang-up does not reach the shift: its shell ignores
# HUP, or dies of it and passes it to nobody (zsh with NO_HUP), the kernel
# then hanging up on the foreground group — the session's. The shift finds
# the terminal gone itself (_aif_start_gone). Its prints to the dead
# terminal had left their bytes in stdio's buffer, and every `$(…)` after
# took them in: the summary's plan was not JSON, no summary.json, and the
# lock's pid was `$$` plus text, so the lock stayed (docs/FINDINGS.md #28).
r="$(python3 "$SANDBOX/terminal.py" nohupclose "$OUT/d-nohup.out" "$SANDBOX/session.pid" "$AIF" start --no-build)"
SD="$(newest_shift)"
eq "no hang-up reaches the shift (its shell ignores HUP), the window closed at the countdown: 129, summary.json, said in shift.log, the lock gone" \
  "$r,$(jq -r '[.rc, .hup] | map(tostring) | join(",")' "$SD/summary.json" 2>/dev/null),$(grep -c '^shift ended — the terminal closed (HUP) · exit 129' "$SD/shift.log"),$(grep -c 'invalid JSON' "$SD/shift.log"),$(lock_gone)" \
  "exit 129,129,true,1,0,gone"
rm -f "$SANDBOX/session.pid"
r="$(FAKE_SESSION_HOLD="$SANDBOX/hold-d-never" python3 "$SANDBOX/terminal.py" leaderdies "$OUT/d-leader.out" "$SANDBOX/session.pid" "$AIF" start --no-build)"
i=0
while [ -d .aif/state/shift ] && [ "$i" -lt 200 ]; do
  sleep 0.1
  i=$((i + 1))
done
SD="$(newest_shift)"
eq "zsh with NO_HUP: its shell and the session die of the hang-up; the shift, nobody's to wait for, finds the terminal gone — summary.json 129 with the session, the lock gone" \
  "$r,$(jq -r '[.rc, .hup, (.sessions | length)] | map(tostring) | join(",")' "$SD/summary.json" 2>/dev/null),$(grep -c '^shift ended — the terminal closed (HUP) · exit 129' "$SD/shift.log"),$(grep -c 'invalid JSON' "$SD/shift.log"),$(lock_gone)" \
  "signal 1,129,true,1,1,0,gone"

# A session killed -9 leaves claude's screen modes on (#28); the reset after
# a 137 has to come before anything that may end the shift — here the unit
# that reaches --max-units, which finished before the reset was printed.
rm -f "$SANDBOX/session.pid"
r="$(FAKE_SESSION_KILL9=1 python3 "$SANDBOX/terminal.py" k9 "$OUT/d-k9.out" "$SANDBOX/session.pid" "$AIF" start --no-build --max-units 1)"
eq "a session killed -9 in claude's screen modes, the unit that reaches --max-units: the alternate screen and paste reporting reset — exit 0" \
  "$r,$(grep -c '^RC=0$' "$OUT/d-k9.out"),$(LC_ALL=C grep -qF "$(printf '\033[?1049l')" "$OUT/d-k9.out.raw" && echo 1049l),$(LC_ALL=C grep -qF "$(printf '\033[?2004l')" "$OUT/d-k9.out.raw" && echo 2004l),$(lock_gone)" \
  "exit 0,1,1049l,2004l,gone"
rm -f "$SANDBOX/session.pid"

# ----------------------------------------------------------------------------

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'start: ok\n'
  cd / && rm -rf "$SANDBOX"
else
  printf 'start: %s failure(s) — sandbox kept at %s\n' "$fails" "$SANDBOX"
  exit 1
fi
