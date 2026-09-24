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

# Every scenario runs --no-worktree, which the worker refuses unless the
# checkout is declared disposable. These are.
export AIF_DISPOSABLE=1

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
# FAKE_STALL makes every implement attempt identical and wrong, FAKE_COMMIT
# has the implement station commit its own work (a station with Bash can),
# FAKE_ZERO_COST reports total_cost_usd 0 the way subscription auth does.
cat >"$SANDBOX/fake-station.sh" <<'FAKE'
#!/bin/bash
set -u
station="$1" ticket="$2" wt="$3" prompt="$5" out="${10}"
work="$wt/tasks/$ticket"
count_file="$wt/.aif/tmp/fake-$station.count"
mkdir -p "$wt/.aif/tmp"
n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" >"$count_file"
# The budget the worker handed this dispatch — empty when there is no ceiling,
# and the real runner then omits --max-budget-usd entirely.
printf '%s' "${8:-}" >"$wt/.aif/tmp/fake-budget"
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
        # The expect literal goes into the test, because that is what
        # verify-red greps for. An expect of "-1" is a grep OPTION unless the
        # gate passes `--`, and without it this scenario fails outright.
        exp="$(sed -n '/^<!-- aif:meta$/,/^-->$/p' "$work/ticket.md" | sed '1d;$d' |
          jq -r --arg id "AC-00$i" '.acceptance[] | select(.id==$id) | .expect')"
        printf '# AC-00%s asserts impl%s — expects %s\n' "$i" "$i" "$exp" >"$wt/tests/t$i.py"
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
    if [ "${FAKE_COMMIT:-0}" = 1 ]; then
      git -C "$wt" add src >/dev/null 2>&1
      git -C "$wt" -c user.email=s@x -c user.name=station commit -qm "wip: the station committed" >/dev/null 2>&1
    fi
    ;;
esac

cost=0.01
[ "${FAKE_ZERO_COST:-0}" = 1 ] && cost=0
jq -n --arg st "$station" --argjson n "$n" --argjson cost "$cost" \
  '{type:"result",subtype:"success",is_error:false,result:("fake " + $st + " done"),
    num_turns:2,total_cost_usd:$cost,duration_ms:5,
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
      "then": "writes the marker", "expect": "-1" }${3:-} ],
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
# The report diffs base..HEAD. A resume used to reset base to the current
# HEAD, so this exact run — nothing dispatched — reported "no code changed"
# about a branch holding all of it.
eq "and its report still describes the ticket's work, not this invocation's" \
  "$(grep -c 'no code changed' tasks/AIF-1/report.md)" "0"

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

# ================= 7. a run that dies still frees the card ==================
# The card says work is happening from the moment it moves to In Progress, and
# the ways out are not only Ctrl-C: any aif_die between the move and the report
# used to leave it saying that for ever. Forced here by removing the gate the
# worker needs at intake, which is an aif_die on the far side of the move.
printf '\n7. a run that cannot start does not leave the card In Progress\n'
fresh_project "$SANDBOX/p7"
ticket_for AIF-7
git add -A && git commit -qm "ticket" >/dev/null
rm -f .aif/gates/ready.sh

rc=0
"$AIF" work AIF-7 --no-worktree >"$OUT/run7.out" 2>&1 || rc=$?
eq "exit 1 — the run stopped" "$rc" "1"
eq "the card was put back where a human will look" \
  "$(jq -r '.column' .aif/board/AIF-7.json 2>/dev/null)" "needs_human"
eq "and the worker said so" "$(grep -c 'did not finish' "$OUT/run7.out")" "1"

# The handler above is armed once and then has to survive every library that
# takes a trap of its own. aif_ledger_append takes one for its lock, and its
# `trap -` on the way out used to clear the worker's with it — which made the
# trap dead from the first ledger write of every run, silently.
mkdir -p "$SANDBOX/trapwork"
armed="$(/bin/bash -c '
  . "$1/lib/common.sh"; . "$1/lib/paths.sh"; . "$1/lib/ledger.sh"
  aif_ledger_init "$2" T-1
  aif_trap_arm "true # SENTINEL"
  aif_ledger_append "$2" "{\"gate\":\"x\",\"result\":\"pass\"}"
  trap -p INT
' _ "$ROOT" "$SANDBOX/trapwork" 2>&1)"
eq "a ledger write leaves the armed handler in place" \
  "$(printf '%s' "$armed" | grep -c 'SENTINEL')" "1"

# =========== 8. a report that contradicts the runner is not a verdict ========
#
# A junit reporter emits one <testcase> per test, so a suite that fails to RUN
# contributes none — and jest-junit emits no failing <testsuite> for it either.
# The file is simply absent, and the report then reads as "everything passed"
# about a run that plainly did not. Measured on a live ticket: `npm test` said
# `1 failed, 26 passed`, the report held zero mentions of the failing file, and
# green passed the ticket on it. Seven acceptance criteria reached review
# verified by nothing.
#
# The stub below reproduces exactly that: it keeps writing its all-pass report
# and starts exiting non-zero the moment the implementation lands.
printf '\n8. a report that contradicts the runner is not a verdict\n'
fresh_project "$SANDBOX/p8"
cat >>.aif/suite.sh <<'BREAK'
grep -q impl1 src/app.py 2>/dev/null && exit 1
exit 0
BREAK
ticket_for AIF-8
git add -A && git commit -qm "ticket 8" >/dev/null
rc=0
"$AIF" work AIF-8 --no-worktree >"$OUT/run8.out" 2>&1 || rc=$?
eq "exit 1 — the run stopped instead of passing" "$rc" "1"
eq "green could not render a verdict" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | last | .result' tasks/AIF-8/ledger.json)" "error"
eq "and said the report contradicts the runner" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | last | .reason' tasks/AIF-8/ledger.json |
     grep -c 'contradicts the runner')" "1"
# An un-renderable verdict is a 3, so the loop stops. Retrying implement here
# buys nothing: the suite is broken somewhere the report does not describe.
eq "implement was dispatched once, not attempts_max times" \
  "$(jq '[.entries[] | select(.station == "implement")] | length' tasks/AIF-8/ledger.json)" "1"
eq "the ticket did not reach review" "$(jq -r '.status' tasks/AIF-8/run.json)" "stopped"

# ======== 9. the lock says how sharp it was, and green repeats it ============
printf '\n9. a coarse freeze says so, and green does not claim a check it skipped\n'
eq "a per-test freeze records the mode and an empty reason" \
  "$(jq -r '.mode + "/" + (.mode_reason | tostring)' "$SANDBOX/p1/tasks/AIF-1/tests.lock.json")" "per-test/"
# The revert-recheck is the check that catches a test asserting nothing, and it
# iterates over `covering`. A coarse freeze leaves covering empty BY
# CONSTRUCTION, so the loop did nothing and the gate went on printing its
# strongest sentence anyway. Drive green against a lock with no covering test
# and it must say so instead.
mkdir -p "$SANDBOX/p9"
cp -R "$SANDBOX/p1/." "$SANDBOX/p9/" 2>/dev/null || true
cd "$SANDBOX/p9" || exit 1
tmp="$(mktemp)"
jq '.covering = [] | .mode = "coarse" | .mode_reason = "python3 is not on PATH"' \
  tasks/AIF-1/tests.lock.json >"$tmp" && mv "$tmp" tasks/AIF-1/tests.lock.json
green_out="$(/bin/bash .aif/gates/green.sh "$PWD/tasks/AIF-1" 2>&1)"
eq "green still passes the suite" "$(printf '%s' "$green_out" | grep -c '^green: suite passes')" "1"
eq "but says the revert-recheck was not done" \
  "$(printf '%s' "$green_out" | grep -c 'revert-recheck NOT done')" "1"
eq "and names the coarse freeze as the reason" \
  "$(printf '%s' "$green_out" | grep -c 'python3 is not on PATH')" "1"

# ============ 10. a station that commits does not empty the gates ===========
#
# The implement station has Bash, and models reach for `git commit -am` by
# habit. The gates used to diff against "the last commit" — which, after that,
# was the station's own: scope passed everything with "0 lines", and green's
# revert-recheck checked out from an index that already held the
# implementation, so it blamed the tests for not depending on it. The worker
# now records HEAD before every dispatch and the gates judge against that.
printf '\n10. a station that commits its own work is still judged on the real diff\n'
fresh_project "$SANDBOX/p10"
ticket_for AIF-10
git add -A && git commit -qm "ticket 10" >/dev/null
rc=0
FAKE_COMMIT=1 "$AIF" work AIF-10 --no-worktree >"$OUT/run10.out" 2>&1 || rc=$?
eq "exit 0 — built" "$rc" "0"
eq "the station's commit is in the history" "$(git log --format=%s | grep -c 'the station committed')" "1"
eq "scope judged the real change, not an empty diff" \
  "$(jq -r '[.entries[] | select(.gate == "scope")] | last | .reason' tasks/AIF-10/ledger.json)" \
  "scope: change confined to the plan (2 lines)"
eq "green's revert-recheck held — the tests do depend on the code" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | last | .reason' tasks/AIF-10/ledger.json | grep -c 'depend on the implementation')" "1"
eq "the run record carries the dispatch baseline" \
  "$(jq -r '.dispatch_base | length' tasks/AIF-10/run.json)" "40"
# The note on scope's pass path: the ledger keeps a gate's first line only, so
# it is read off a gate run by hand — against a tree built to show exactly the
# defect: a baseline recorded at dispatch, and a station commit after it. Then
# the record is removed, which is the old behaviour, and the change vanishes.
mkdir -p "$SANDBOX/p10b" && cd "$SANDBOX/p10b" || exit 1
git init -q && git config user.email s@x && git config user.name station
mkdir -p .aif tasks/AIF-10 src
cp "$SANDBOX/p10/.aif/project.json" .aif/project.json
cp -R "$SANDBOX/p10/.aif/gates" .aif/gates
printf 'def users():\n    return []\n' >src/app.py
printf '<!-- aif:meta\n{ "files": { "create": [], "change": ["src/app.py"], "tests": [] } }\n-->\n# plan\n' >tasks/AIF-10/plan.md
git add -A && git commit -qm base >/dev/null
jq -n --arg b "$(git rev-parse HEAD)" '{ dispatch_base: $b }' >tasks/AIF-10/run.json
printf 'def users():\n    return []  # impl1\n' >src/app.py
git add src && git commit -qm "wip: the station committed" >/dev/null
eq "scope, with the baseline: judges the real diff and says HEAD moved" \
  "$(/bin/bash .aif/gates/scope.sh "$PWD/tasks/AIF-10" 2>&1 |
     grep -cE '^scope: change confined to the plan \(2 lines\)|HEAD moved during the station')" "2"
rm -f tasks/AIF-10/run.json
eq "without it — the old behaviour — the same change is invisible" \
  "$(/bin/bash .aif/gates/scope.sh "$PWD/tasks/AIF-10" 2>&1 | head -1)" "scope: change confined to the plan (0 lines)"

# ============ 11. the dollar ceiling: off by default, and real when set =====
#
# Two things at once. A ceiling nobody asked for could not be honoured: under
# subscription auth the runner reports total_cost_usd 0 for every station and
# .aif/prices.json ships empty, so the old default of 20 read as a guarantee
# and was not one. It is off now unless asked for. And when it IS asked for it
# has to fire on the token-priced cost, not on the runner's zero.
#
# priced() — a project whose price table knows the fake model, so a station
# that reports $0 still costs something.
priced() {
  fresh_project "$1"
  local t
  t="$(mktemp)"
  jq '.models["fake-model"] = { input: 1000, output: 1000, cache_read: 0, cache_write: 0 }' \
    .aif/prices.json >"$t" && mv "$t" .aif/prices.json
}
printf '\n11. the dollar ceiling is opt-in, and fires on token-priced cost when it is set\n'

priced "$SANDBOX/p11"
eq "the template ships no ceiling" "$(jq -r '.limits.run_budget_usd' .aif/project.json)" "null"
ticket_for AIF-11
git add -A && git commit -qm "ticket 11" >/dev/null
rc=0
FAKE_ZERO_COST=1 "$AIF" work AIF-11 --no-worktree >"$OUT/run11.out" 2>&1 || rc=$?
eq "no ceiling: built" "$rc" "0"
eq "and the run says so on its first line" "$(grep -c 'budget off' "$OUT/run11.out")" "1"
# The station is invoked without --max-budget-usd at all, not with the 0.01
# floor the remaining-budget arithmetic would otherwise produce.
eq "the station was handed no budget" "$(cat .aif/tmp/fake-budget)" ""
eq "the spend was still recorded" "$(jq -r '.spent_usd > 0' tasks/AIF-11/run.json)" "true"

priced "$SANDBOX/p11b"
ticket_for AIF-11
git add -A && git commit -qm "ticket 11b" >/dev/null
rc=0
FAKE_ZERO_COST=1 "$AIF" work AIF-11 --no-worktree --budget 0.05 >"$OUT/run11b.out" 2>&1 || rc=$?
eq "--budget 0.05: exit 1 — stopped" "$rc" "1"
eq "stopped by the budget" "$(jq -r '.why' tasks/AIF-11/run.json | grep -c '^budget:')" "1"
eq "with a spend above zero, though every envelope said USD 0" \
  "$(jq -r '.spent_usd > 0' tasks/AIF-11/run.json)" "true"
eq "and the ledger priced the same tokens" \
  "$(jq -r '[.entries[] | select(.station != null)] | first | .cost_source' tasks/AIF-11/ledger.json)" "priced"
eq "the station was handed what was left of it" \
  "$([ -n "$(cat .aif/tmp/fake-budget)" ] && echo yes || echo no)" "yes"

# The project can set it, and --no-budget overrides the project.
priced "$SANDBOX/p11c"
tmp="$(mktemp)"
jq '.limits.run_budget_usd = 0.05' .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
ticket_for AIF-11
git add -A && git commit -qm "ticket 11c" >/dev/null
eq "a ceiling in project.json still validates" "$("$AIF" project check >/dev/null 2>&1; echo $?)" "0"
rc=0
FAKE_ZERO_COST=1 "$AIF" work AIF-11 --no-worktree >"$OUT/run11c.out" 2>&1 || rc=$?
eq "limits.run_budget_usd alone stops the run" "$rc" "1"
eq "and the first line names it" "$(grep -c "budget .0.05" "$OUT/run11c.out")" "1"
rc=0
FAKE_ZERO_COST=1 "$AIF" work AIF-11 --no-worktree --no-budget >"$OUT/run11d.out" 2>&1 || rc=$?
eq "--no-budget overrides the project and builds" "$rc" "0"
eq "a non-numeric --budget is refused, not read as zero" \
  "$("$AIF" work AIF-11 --no-worktree --budget lots 2>&1 | grep -c 'positive dollar amount')" "1"
eq "a string in project.json is refused by the validator" \
  "$(jq '.limits.run_budget_usd = "20"' .aif/project.json >"$OUT/bad.json" &&
     /bin/bash -c '. "$1/lib/common.sh"; . "$1/lib/paths.sh"; . "$1/lib/project.sh"; aif_project_validate "$2"' \
       _ "$ROOT" "$OUT/bad.json" 2>&1 | grep -c 'run_budget_usd must be a number')" "1"

# ============ 12. --no-worktree needs a disposable checkout ==================
printf '\n12. --no-worktree is refused unless the checkout is declared disposable\n'
fresh_project "$SANDBOX/p12"
ticket_for AIF-12
git add -A && git commit -qm "ticket 12" >/dev/null
rc=0
env -u AIF_DISPOSABLE -u CI "$AIF" work AIF-12 --no-worktree >"$OUT/run12.out" 2>&1 || rc=$?
eq "refused, exit 1" "$rc" "1"
eq "and it says how to declare it" "$(grep -c 'AIF_DISPOSABLE=1' "$OUT/run12.out")" "1"
eq "nothing ran" "$(test -f tasks/AIF-12/run.json && echo yes || echo no)" "no"
rc=0
CI=1 "$AIF" work AIF-12 --no-worktree >"$OUT/run12b.out" 2>&1 || rc=$?
eq "CI=1 is enough — a CI job has it already" "$rc" "0"

# ============ 13. a CRLF ticket still has a meta block =======================
# A card edited in a browser can come back with \r\n, and `<!-- aif:meta\r`
# used to match nothing — the pull then said the analyst never wrote it.
printf '\n13. a meta block survives CRLF line endings\n'
printf '<!-- aif:meta\r\n{ "ticket": "AIF-9", "schema": 2 }\r\n-->\r\n# AIF-9\r\n' >"$SANDBOX/crlf.md"
eq "aif_meta_json reads it" \
  "$(/bin/bash -c '. "$1/lib/common.sh"; aif_meta_json "$2" | jq -r .ticket' _ "$ROOT" "$SANDBOX/crlf.md" 2>&1)" "AIF-9"
eq "and the gates' copy agrees" \
  "$(/bin/bash -c '. "$1/sets/claude/gates/_lib.sh"; aif_g_meta "$2" | jq -r .ticket' _ "$ROOT" "$SANDBOX/crlf.md" 2>&1)" "AIF-9"

# ====== 14. a fresh worktree that cannot run the suite is refused ===========
#
# `git worktree add` checks out tracked files. node_modules is gitignored, so
# a fresh worktree has none, and jest dies validating its config — no report,
# exit 1. Three runs of one ticket were admitted as coarse RED that way, froze
# an empty `covering`, and passed green on a build nobody had seen fail. The
# preflight probe could not see it: it runs in the developer's checkout, where
# node_modules exists. Here the suite needs a file under a gitignored directory
# that the developer's checkout has and a fresh worktree does not.
printf '\n14. a fresh worktree that cannot run the suite is refused, and prepare fixes it\n'
fresh_project "$SANDBOX/p14"
printf 'deps/\n' >>.gitignore
mkdir -p deps && : >deps/ok
tmp="$(mktemp)"
{ printf '#!/bin/bash\n[ -f deps/ok ] || { echo "Validation Error: deps missing"; exit 1; }\n'; tail -n +2 .aif/suite.sh; } >"$tmp"
mv "$tmp" .aif/suite.sh && chmod +x .aif/suite.sh
ticket_for AIF-14
git add -A && git commit -qm "ticket 14" >/dev/null
rc=0
"$AIF" work AIF-14 >"$OUT/run14.out" 2>&1 || rc=$?
eq "refused, exit 3 — the environment, and nothing was spent" "$rc" "3"
eq "it says the suite wrote no report there" "$(grep -c 'wrote no report' "$OUT/run14.out")" "1"
eq "and points at prepare" "$(grep -c '"prepare"' "$OUT/run14.out")" "1"
eq "the card never moved" "$(test -f .aif/board/AIF-14.json && jq -r .column .aif/board/AIF-14.json || echo none)" "none"
eq "no run started in the worktree" \
  "$(test -f .aif/worktrees/AIF-14/tasks/AIF-14/run.json && echo yes || echo no)" "no"
# The project now says how a checkout becomes able to run its suite. Read from
# the developer's config on purpose: the branch was cut before the field
# existed, and the worktree it cut is reused, not re-cut.
tmp="$(mktemp)"
jq '.prepare = "mkdir -p deps && : >deps/ok"' .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
git add -A && git commit -qm "prepare" >/dev/null
rc=0
"$AIF" work AIF-14 >"$OUT/run14b.out" 2>&1 || rc=$?
eq "with prepare: built" "$rc" "0"
eq "prepare ran, in the worktree" "$(grep -c 'prepare .*deps/ok' "$OUT/run14b.out")" "1"
eq "and left its marker, so a resume does not repeat it" \
  "$(test -f .aif/worktrees/AIF-14/.aif/tmp/prepared && echo yes || echo no)" "yes"
eq "the freeze was per-test, not coarse" \
  "$(jq -r '.mode' .aif/worktrees/AIF-14/tasks/AIF-14/tests.lock.json)" "per-test"

# ====== 15. a suite that never reaches its reporter is not red ==============
# The gate's half of the same defect: with no report at all, verify-red used
# to fall to coarse mode and accept a non-zero exit as red. A runner that did
# not boot has an exit code that says nothing about the tests.
printf '\n15. a suite that never reaches its reporter is not red\n'
fresh_project "$SANDBOX/p15"
tmp="$(mktemp)"
{ printf '#!/bin/bash\n[ -f tests/t1.py ] && { echo "Validation Error: the runner did not boot"; exit 1; }\n'; tail -n +2 .aif/suite.sh; } >"$tmp"
mv "$tmp" .aif/suite.sh && chmod +x .aif/suite.sh
ticket_for AIF-15
git add -A && git commit -qm "ticket 15" >/dev/null
rc=0
"$AIF" work AIF-15 --no-worktree >"$OUT/run15.out" 2>&1 || rc=$?
eq "exit 1 — stopped" "$rc" "1"
eq "verify-red could not render a verdict" \
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | last | .result' tasks/AIF-15/ledger.json)" "error"
eq "and said the suite did not run" \
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | last | .reason' tasks/AIF-15/ledger.json | grep -c 'did not run')" "1"
eq "nothing was frozen" "$(test -f tasks/AIF-15/tests.lock.json && echo yes || echo no)" "no"
eq "implement was never dispatched" \
  "$(jq '[.entries[] | select(.station == "implement")] | length' tasks/AIF-15/ledger.json)" "0"

# ====== 16. runner detection survives a large tests/ tree ==================
# `find | head -1 | grep -q .` as an elif condition: head leaves after one
# line, a find still walking 5000 files takes SIGPIPE, pipefail makes that
# the condition's status, and the project is reported as having no test kind
# (docs/DEFECTS-5.md #2). Only a project with none of pyproject/pytest.ini/
# setup.cfg/conftest.py gets this far — this one has none.
printf '\n16. runner detection survives a large tests/ tree\n'
fresh_project "$SANDBOX/p16"
rm -f .aif/project.json
i=0; while [ "$i" -lt 5000 ]; do : >"tests/f$i.py"; i=$((i + 1)); done
eq "5000 test files: still detected as pytest" \
  "$("$AIF" project init --no-checks 2>&1 | grep -c 'detected runner: .*pytest')" "1"

# ====== 17. the collision check reads ALL of a large suite output ==========
# `printf '%s' "$out" | grep -q pattern` with the suite's whole output in
# $out: grep leaves at the first match, printf takes SIGPIPE on the rest, and
# under pipefail the `if` reads "not found" — for exactly the suites large
# enough to matter (docs/DEFECTS-5.md #3). The path is on the FIRST line here
# and 280 KB follow it.
printf '\n17. the worktree-collision check reads all of a large suite output\n'
fresh_project "$SANDBOX/p17"
tmp="$(mktemp)"
{
  printf '#!/bin/bash\necho "PASS .aif/worktrees/AIF-1/tests/t0.py"\n'
  # shellcheck disable=SC2016  # a script being written, not expanded
  printf 'i=0; while [ "$i" -lt 4000 ]; do echo "PASS tests/t0.py - filler line $i pushing the output past a pipe buffer"; i=$((i + 1)); done\n'
  tail -n +2 .aif/suite.sh
} >"$tmp"
mv "$tmp" .aif/suite.sh && chmod +x .aif/suite.sh
eq "doctor --probe reports the collision" "$("$AIF" doctor --probe 2>&1 | grep -c 'test scope')" "1"

# ----------------------------------------------------------------------------
printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'work: ok\n'
  cd / && rm -rf "$SANDBOX"
else
  printf 'work: %s failure(s) — sandbox kept at %s\n' "$fails" "$SANDBOX"
  exit 1
fi
