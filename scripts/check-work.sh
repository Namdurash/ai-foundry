#!/usr/bin/env bash
#
# scripts/check-work.sh — the worker, end to end, OFFLINE.
#
# `aif work` is the machine half of the foundry: it drives a ticket through the
# stations with no human at any boundary. Everything in it that is NOT a model
# call is deterministic and is exercised here — the worktree, the intake
# freeze, the state-driven loop, the retry with the gate's complaint, the caps,
# the report, the commits — through AIF_WORK_STATION_CMD, the seam that puts a
# script where the runner would be. The script writes each station's artifact
# by hand and a fake envelope, the same trade demo.sh and check-cycle.sh make:
# the machine end to end, no model, no tokens.
#
# What it proves:
#   1  a ready ticket goes to `built` with every station recorded, metered as
#      headless, committed once per accepted station, and a report on the
#      branch — under a decimal-comma locale, where a %f-formatted number is
#      not JSON and the run used to die at the first station
#   2  a rejection is retried with the gate's complaint in the prompt, and both
#      attempts are in the ledger
#   3  a ticket that is not ready — a stub, or an open question — stops at
#      intake with nothing spent, and the report carries the gate's questions
#   5  the worktree path: the run lands on aif/<ID> in .aif/worktrees/<ID>,
#      the developer's checkout is untouched, and --clean removes the checkout
#      but not the branch
#   6  the dispatch cap stops a station that never converges
#
# Run by `make check`. Requires git, jq and python3; skips without python3.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
AIF="$ROOT/bin/aif"

for tool in git jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'check-work: %s not found — cannot run\n' "$tool"
    exit 1
  }
done
if ! command -v python3 >/dev/null 2>&1; then
  printf 'check-work: skipped — python3 is required for per-test verify-red\n'
  exit 0
fi

# A locale that writes 0,0100 where jq wants 0.0100, if this machine has one.
# Scenario 1 runs under it: the worker's money is awk's %f on the way into a
# JSON run record, and for one release every run on a European laptop stopped
# at the first station with a jq usage message for an explanation.
DEC_COMMA=""
# `locale -a | grep -q` would be the obvious spelling and is a trap: grep -q
# leaves early, locale takes the SIGPIPE, and under pipefail the whole pipeline
# reads as "no such locale". The list is four kilobytes; hold it and match it.
installed_locales="$(locale -a 2>/dev/null || true)"
for loc in de_DE.UTF-8 fr_FR.UTF-8 uk_UA.UTF-8; do
  case "$installed_locales" in
    *"$loc"*)
      DEC_COMMA="$loc"
      break
      ;;
  esac
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

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/aif-work-XXXXXX")"
OUT="$SANDBOX/out"
mkdir -p "$OUT"
printf '\nworker, offline (sandbox: %s)\n' "$SANDBOX"

# fresh_project <dir> — a project on the rails, with a state-sensitive stub
# suite. One per scenario: the worker commits into the project it runs in, so a
# shared one would carry one scenario's implementation into the next.
fresh_project() {
  mkdir -p "$1" && cd "$1" || exit 1
  git init -q
  git config user.email work@aif
  git config user.name "Work"
  mkdir -p src tests
  printf 'def users():\n    return []\n' >src/app.py
  printf '# a pre-existing, green test\n' >tests/t0.py
  # A pre-existing SKIPPED test — a platform guard, a slow marker, an
  # importorskip. Ordinary in any real repository, and for one release it made
  # green unpassable: it rejected anything not "pass" across the whole report,
  # while verify-red explicitly allowed a skip. Every scenario here now carries
  # one, so the disagreement cannot come back unnoticed.
  printf '# skipped on this platform\n' >tests/t9.py
  git add -A && git commit -qm init >/dev/null

  "$AIF" init anthropic >/dev/null 2>&1 || {
    printf 'check-work: aif init failed — cannot continue\n'
    exit 1
  }
  "$AIF" project init pytest --no-checks >/dev/null 2>&1

  # The report shape pytest has written since 6.0: junit_family=xunit2, whose
  # schema has no @file — the test file is only recoverable from the dotted
  # @classname. Written that way here on purpose: with @file spelled out, this
  # whole harness passed while verify-red was blind on every project on a
  # current pytest.
  cat >.aif/suite.sh <<'SUITE'
#!/bin/bash
mkdir -p .aif/tmp
cn() { printf '%s' "${1%.py}" | tr '/' '.'; } # pytest's classname for a file
row() { # <id> <file> <green?>
  if [ "$3" = 1 ]; then
    printf '<testcase classname="%s" name="%s"/>' "$(cn "$2")" "$1"
  else
    printf '<testcase classname="%s" name="%s"><failure message="assert marker missing">AssertionError: assert marker missing</failure></testcase>' "$(cn "$2")" "$1"
  fi
}
body="$(row t0 tests/t0.py 1)<testcase classname=\"tests.t9\" name=\"t9\"><skipped message=\"not on this platform\"/></testcase>"
for n in 1 2 3; do
  [ -f "tests/t$n.py" ] || continue
  g=0; grep -q "impl$n" src/app.py 2>/dev/null && g=1
  body="$body$(row "t$n" "tests/t$n.py" "$g")"
done
printf '<testsuites><testsuite>%s</testsuite></testsuites>' "$body" > .aif/tmp/report.xml
SUITE
  chmod +x .aif/suite.sh
  local tmp
  tmp="$(mktemp)"
  jq '.test.command = "bash .aif/suite.sh"
      | .test.roots = ["tests"]
      | .test.report.path = ".aif/tmp/report.xml"' .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
  git add -A && git commit -qm "aif init" >/dev/null
}

# --- the fake runner ---------------------------------------------------------
# Receives exactly what the real runner would, plus station and ticket first:
#   <station> <ticket> <workdir> <sys-prompt-file> <user-prompt> <model>
#   <max-turns> <budget> <tools> <out> <err>
# Reads the dispatch bindings out of the prompt the way a station would, writes
# the station's artifact, and writes an envelope. FAKE_PLAN_BAD_FIRST makes the
# first plan attempt name a file that does not exist (plan-form rejects it),
# FAKE_STALL makes every implement attempt identical and wrong.
cat >"$SANDBOX/fake-station.sh" <<'FAKE'
#!/bin/bash
set -u
station="$1" ticket="$2" wt="$3" prompt="$5" out="${10}"
work="$wt/tasks/$ticket"
count_file="$wt/.aif/tmp/fake-$station.count"
mkdir -p "$wt/.aif/tmp"
n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" >"$count_file"
retry=0; printf '%s' "$prompt" | grep -q "was REJECTED" && retry=1

# The criteria the ticket actually carries — so a reworked ticket with a new
# criterion produces a plan and a test for it, exactly as a real station would.
acs="$(sed -n '/^<!-- aif:meta$/,/^-->$/p' "$work/ticket.md" | sed '1d;$d' | jq -r '.acceptance[].id')"
nums="$(printf '%s\n' "$acs" | sed 's/AC-00//')"
tests_json="$(printf '%s\n' "$nums" | jq -R 'select(length>0) | "tests/t" + . + ".py"' | jq -sc .)"

case "$station" in
  plan)
    change='["src/app.py"]'
    if [ "${FAKE_PLAN_BAD_FIRST:-0}" = 1 ] && [ "$retry" = 0 ]; then change='["src/nowhere.py"]'; fi
    cov="$(printf '%s\n' "$acs" | jq -R 'select(length>0)' | jq -sc --argjson c "$change" \
      'map({ key: ., value: $c }) | from_entries')"
    cat >"$work/plan.md" <<PLAN
<!-- aif:meta
{ "schema": 2, "ticket": "$ticket", "risk": "low",
  "files": { "create": [], "change": $change, "tests": $tests_json },
  "decisions": [
    { "id": "D-001", "statement": "Write the markers from the app module.",
      "because": "every criterion is about the app's own output", "serves": [] } ],
  "ac_coverage": $cov,
  "uncovered": [],
  "external": [] }
-->
# $ticket — plan (attempt $n)
PLAN
    ;;
  tests)
    for i in $nums; do
      [ -n "$i" ] || continue
      if [ "${FAKE_TESTS_BAD_FIRST:-0}" = 1 ] && [ "$retry" = 0 ]; then
        # No criterion id and no literal: verify-red rejects on coverage,
        # BEFORE it has written the lock file its verdict would bind to.
        printf '# nothing to see here\n' >"$wt/tests/t$i.py"
      else
        printf '# AC-00%s asserts impl%s\n' "$i" "$i" >"$wt/tests/t$i.py"
      fi
    done
    ;;
  implement)
    if [ "${FAKE_STALL:-0}" = 1 ]; then
      printf 'def users():\n    return []  # wrong\n' >"$wt/src/app.py"
    else
      body=""
      for i in $nums; do [ -n "$i" ] && body="$body impl$i"; done
      printf 'def users():\n    return []  #%s\n' "$body" >"$wt/src/app.py"
    fi
    ;;
esac

jq -n --arg st "$station" --argjson n "$n" \
  '{type:"result",subtype:"success",is_error:false,result:("fake " + $st + " done"),
    num_turns:2,total_cost_usd:0.01,duration_ms:5,
    usage:{input_tokens:10,output_tokens:(20*$n),cache_read_input_tokens:0,cache_creation_input_tokens:0},
    modelUsage:{"fake-model":{}}}' >"$out"
FAKE
chmod +x "$SANDBOX/fake-station.sh"
export AIF_WORK_STATION_CMD="$SANDBOX/fake-station.sh"

ticket_for() { # <id> [open-json] — the analyst's output: criteria in the
  # ticket, one question decided by default, one recorded gap.
  "$AIF" _ticket-init "$1" >/dev/null
  cat >"tasks/$1/ticket.md" <<TICKET
<!-- aif:meta
{ "schema": 2, "ticket": "$1", "lang": "en", "risk": "low",
  "surfaces": ["export"],
  "acceptance": [
    { "id": "AC-001", "surface": "export",
      "given": "users exist", "when": "the export runs",
      "then": "writes the marker", "expect": "impl1" }${3:-} ],
  "open": ${2:-[]},
  "decided": [
    { "question": "may the export be deferred to a queue?", "answer": "no — synchronous", "by": "default" } ],
  "verification_gaps": [
    { "id": "VG-001", "text": "nothing here runs against a real user list", "leaves": ["AC-001"] } ],
  "non_goals": [] }
-->
# $1 — one-command user export

Support needs a one-command export: write the current user list so it can be
pulled without touching the database.
TICKET
}

# =============================== 1. built ====================================
printf '\n1. a ready ticket, in place (--no-worktree)\n'
fresh_project "$SANDBOX/p1"
ticket_for AIF-1
git add -A && git commit -qm "ticket" >/dev/null

if [ -n "$DEC_COMMA" ]; then
  printf '  · under %s — every number the run writes is still JSON\n' "$DEC_COMMA"
else
  printf '  · no decimal-comma locale on this machine — the locale half is weaker here\n'
fi
rc=0
LC_ALL="$DEC_COMMA" "$AIF" work AIF-1 --no-worktree >"$OUT/run1.out" 2>&1 || rc=$?
eq "exit 0 — built" "$rc" "0"
eq "report says built" "$(head -1 tasks/AIF-1/report.md 2>/dev/null)" "# AIF-1 — built"
eq "run.json status" "$(jq -r '.status' tasks/AIF-1/run.json)" "built"
eq "run.json froze the ticket's hash" \
  "$(jq -r '.ticket_sha256' tasks/AIF-1/run.json)" "$(shasum -a 256 tasks/AIF-1/ticket.md | cut -d' ' -f1)"
eq "three stations metered, headless" \
  "$(jq '[.entries[] | select(.station != null and .mode == "headless")] | length' tasks/AIF-1/ledger.json)" "3"
eq "station rows carry the model that ran" \
  "$(jq -r '[.entries[] | select(.station == "plan")] | last | .model' tasks/AIF-1/ledger.json)" "fake-model"
eq "the ready gate's pass is in the ledger" \
  "$(jq -r '[.entries[] | select(.gate == "ready")] | length > 0' tasks/AIF-1/ledger.json 2>/dev/null || echo skip)" "true"
eq "one commit per accepted station, plus intake and report" \
  "$(git log --format=%s | grep -c '^aif: ')" "5"
eq "the run record reached done" "$(jq -r '.stage' tasks/AIF-1/run.json)" "done"
eq "the spend crossed into the run record as a number, not a locale string" \
  "$(jq -r '(.spent_usd | type) + ":" + ((.spent_usd > 0) | tostring)' tasks/AIF-1/run.json)" "number:true"
eq "a pre-existing skipped test did not block green" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | last | .result' tasks/AIF-1/ledger.json)" "pass"
eq "and green said it allowed one" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | last | .reason' tasks/AIF-1/ledger.json | grep -c 'skipped elsewhere')" "1"
eq "the freeze recorded what the rest of the suite looked like" \
  "$(jq -r '.suite_at_freeze["tests.t9::t9"]' tasks/AIF-1/tests.lock.json)" "skipped"
eq "the tool wrote the plan's binding, not the model" \
  "$(sed -n '/^<!-- aif:meta$/,/^-->$/p' tasks/AIF-1/plan.md | sed '1d;$d' | jq -r '.ticket_sha256')" \
  "$(shasum -a 256 tasks/AIF-1/ticket.md | cut -d' ' -f1)"
eq "each station left its own account behind" \
  "$(find tasks/AIF-1/stations -name '*.json' | wc -l | tr -d ' ')" "3"
eq "the report shows what fell to a default, beside the code" \
  "$(grep -c 'by default, not by the human' tasks/AIF-1/report.md)" "1"
eq "the report carries the gap as a checklist item" \
  "$(grep -c '^- \[ \] \*\*ticket VG-001' tasks/AIF-1/report.md)" "1"
eq "the tree is clean after the run" "$(git status --porcelain | wc -l | tr -d ' ')" "0"
eq "nothing staged is left behind" "$(find .aif/tmp -name 'meter-*.jsonl' 2>/dev/null | wc -l | tr -d ' ')" "0"
if grep -q "the runner produced no envelope" "$OUT/run1.out"; then bad "runner errors in output"; fi

# =============================== 2. retry ====================================
printf '\n2. a rejection is retried with the complaint, and both attempts are recorded\n'
fresh_project "$SANDBOX/p2"
ticket_for AIF-2
git add -A && git commit -qm "ticket 2" >/dev/null
rc=0
FAKE_PLAN_BAD_FIRST=1 FAKE_TESTS_BAD_FIRST=1 "$AIF" work AIF-2 --no-worktree >"$OUT/run2.out" 2>&1 || rc=$?
eq "exit 0 — built after the retry" "$rc" "0"
eq "plan was dispatched twice" \
  "$(jq '[.entries[] | select(.station == "plan")] | length' tasks/AIF-2/ledger.json)" "2"
eq "the plan gate recorded a fail then a pass" \
  "$(jq -r '[.entries[] | select(.gate == "plan") | .result] | join(",")' tasks/AIF-2/ledger.json)" "fail,pass"
eq "the second attempt saw the complaint" "$(grep -c 'attempt 2' tasks/AIF-2/plan.md)" "1"
eq "the report counts both attempts" \
  "$(grep -E '^\| plan \|' tasks/AIF-2/report.md | awk -F'|' '{ gsub(/ /,"",$3); print $3 }')" "2"
eq "the tests station was retried too" \
  "$(jq '[.entries[] | select(.gate == "verify-red")] | length' tasks/AIF-2/ledger.json)" "2"
# A gate that rejects BEFORE its subject exists — verify-red, whose subject is
# the lock file it has not written yet — used to record the rejection with an
# empty reason, because consecutive tabs collapse in a bash IFS and every
# field after the empty subject shifted left. Two live rejections were logged
# that way before anyone noticed.
eq "every rejection says why" \
  "$(jq '[.entries[] | select(.result == "fail") | select((.reason // "") == "")] | length' tasks/AIF-2/ledger.json)" "0"
eq "and the subject column did not eat it" \
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | first | .subject' tasks/AIF-2/ledger.json)" ""
eq "the verify-red reason is the gate's own words" \
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | first | .reason' tasks/AIF-2/ledger.json | grep -c 'REJECT')" "1"

# =============================== 3. not ready ================================
printf '\n3. a ticket that is not ready stops at intake, nothing spent\n'
fresh_project "$SANDBOX/p3"
"$AIF" _ticket-init AIF-3 >/dev/null
git add -A && git commit -qm "stub" >/dev/null
rc=0
"$AIF" work AIF-3 --no-worktree >"$OUT/run3.out" 2>&1 || rc=$?
eq "a stub: exit 1 — needs a person" "$rc" "1"
eq "says why" "$(grep -c 'scaffold stub' "$OUT/run3.out")" "1"
eq "no station ran" "$(jq '[.entries[] | select(.station != null)] | length' tasks/AIF-3/ledger.json)" "0"

ticket_for AIF-6 '[{ "id": "Q-001", "question": "should the export be signed?", "default": "no", "affects": ["AC-001"] }]'
git add -A && git commit -qm "open question" >/dev/null
rc=0
"$AIF" work AIF-6 --no-worktree >"$OUT/run6.out" 2>&1 || rc=$?
eq "an open question: exit 1 — back to the analyst" "$rc" "1"
# Nothing was spent, so there is no run to report on — the card carries the
# gate's own questions instead, which is where the analyst reads them.
eq "the card carries the question and its default" \
  "$("$AIF" board show AIF-6 --json | jq -r '.comments[0].text' | grep -c 'open question Q-001.*default: no')" "1"
eq "and no report was written for a run that never started" \
  "$(test -f tasks/AIF-6/report.md && echo yes || echo no)" "no"
eq "no station ran on it" "$(jq '[.entries[] | select(.station != null)] | length' tasks/AIF-6/ledger.json)" "0"

# =============================== 4. worktree =================================
printf '\n4. the worktree path\n'
fresh_project "$SANDBOX/p4"
ticket_for AIF-4
# Deliberately NOT committed: the analyst just wrote it, and the worker must
# carry it into the worktree itself.
rc=0
"$AIF" work AIF-4 >"$OUT/run4.out" 2>&1 || rc=$?
eq "exit 0 — built in a worktree" "$rc" "0"
if [ -d .aif/worktrees/AIF-4 ]; then ok "worktree at .aif/worktrees/AIF-4"; else bad "no worktree"; fi
eq "on branch aif/AIF-4" "$(git -C .aif/worktrees/AIF-4 rev-parse --abbrev-ref HEAD)" "aif/AIF-4"
eq "the report is on the branch" \
  "$(git -C .aif/worktrees/AIF-4 log --format=%s -1)" "aif: report AIF-4 (built)"
eq "the developer's checkout has no implementation" "$(grep -c impl1 src/app.py)" "0"
eq "the branch has it" "$(git show aif/AIF-4:src/app.py | grep -c impl1)" "1"
eq "the uncommitted ticket was carried in" \
  "$(git -C .aif/worktrees/AIF-4 log --format=%s | grep -c 'aif: intake AIF-4')" "1"
eq "the worktrees dir is ignored in the developer's checkout" \
  "$(git status --porcelain | grep -c 'worktrees')" "0"
"$AIF" work AIF-4 --clean >/dev/null 2>&1
if [ -e .aif/worktrees/AIF-4 ]; then bad "--clean left the worktree"; else ok "--clean removed the worktree"; fi
if git show-ref --verify --quiet refs/heads/aif/AIF-4; then ok "--clean kept the branch"; else bad "--clean removed the branch"; fi

# =============================== 5. the cap ==================================
printf '\n5. a station that never converges hits the attempts cap and stops\n'
fresh_project "$SANDBOX/p5"
ticket_for AIF-5
git add -A && git commit -qm "ticket 5" >/dev/null
rc=0
FAKE_STALL=1 "$AIF" work AIF-5 --no-worktree >"$OUT/run5.out" 2>&1 || rc=$?
eq "exit 1 — stopped" "$rc" "1"
eq "the report says why" "$(grep -c 'rewrote nothing\|rejected .* time' tasks/AIF-5/report.md)" "1"
eq "the accepted stations are committed, the failed one is not" \
  "$(git log --format=%s | grep -c '^aif: implement AIF-5')" "0"
eq "run.json status" "$(jq -r '.status' tasks/AIF-5/run.json)" "stopped"

# =============================== 6. the second round =========================
# What the retired check-cycle.sh guarded, on the only driver there now is: a
# rework over a FINISHED ticket. Six of the ten defects of the 0.4.1 set lived
# on this route, and every fixture used to start clean.
printf '\n6. a rework over a finished ticket\n'
fresh_project "$SANDBOX/p6"
ticket_for AIF-1
git add -A && git commit -qm "ticket" >/dev/null
"$AIF" work AIF-1 --no-worktree >"$OUT/r1.out" 2>&1
eq "round one is built" "$(jq -r '.status' tasks/AIF-1/run.json)" "built"

# A resume with the ticket UNCHANGED keeps the stage rather than rebuilding.
"$AIF" work AIF-1 --no-worktree >"$OUT/r1b.out" 2>&1
eq "an unchanged ticket resumes at done, and dispatches nothing" \
  "$(jq -r '.dispatches' tasks/AIF-1/run.json)" "0"
eq "it says so" "$(grep -c 'resume.*done' "$OUT/r1b.out")" "1"

# Now the analyst adds a criterion. Nothing is reset by hand: the run record
# was bound to the ticket's bytes, and they moved.
ticket_for AIF-1 '[]' ',
    { "id": "AC-002", "surface": "export",
      "given": "the export ran", "when": "the output is read",
      "then": "writes the manifest marker", "expect": "impl2" }'
rm -f .aif/tmp/fake-*.count
"$AIF" work AIF-1 --no-worktree >"$OUT/r2.out" 2>&1
rc=$?
eq "round two is built" "$rc" "0"
eq "the reworked ticket restarted the run, it did not resume" \
  "$(grep -c 'restart.*the ticket changed' "$OUT/r2.out")" "1"
eq "the plan was remade for both criteria" \
  "$(sed -n '/^<!-- aif:meta$/,/^-->$/p' tasks/AIF-1/plan.md | sed '1d;$d' | jq -r '.ac_coverage | keys | join(",")')" "AC-001,AC-002"
eq "and rebound to the new ticket" \
  "$(sed -n '/^<!-- aif:meta$/,/^-->$/p' tasks/AIF-1/plan.md | sed '1d;$d' | jq -r '.ticket_sha256')" \
  "$(shasum -a 256 tasks/AIF-1/ticket.md | cut -d' ' -f1)"
eq "the round-one test was green at freeze, never proven red" \
  "$(jq -c '.green_at_freeze' tasks/AIF-1/tests.lock.json)" '["tests.t1::t1"]'
eq "so only the new test is covering" \
  "$(jq -c '.covering' tasks/AIF-1/tests.lock.json)" '["tests.t2::t2"]'
eq "and the report says the green-at-freeze test was never proven red" \
  "$(grep -c 'tests tests.t1::t1' tasks/AIF-1/report.md)" "1"
eq "the ticket's own gap is on the checklist too" \
  "$(grep -c 'ticket VG-001' tasks/AIF-1/report.md)" "1"

# ----------------------------------------------------------------------------
printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'work: ok\n'
  cd / && rm -rf "$SANDBOX"
else
  printf 'work: %s failure(s) — sandbox kept at %s\n' "$fails" "$SANDBOX"
  exit 1
fi
