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
#  18  --loop drains Ready in the board's order, stops when it is empty, at
#      --max-tickets, and after two runs in a row that did not build
#  19  land: the yes after review — merge, suite on the result, Done, the
#      worktree and branch gone, the ticket that depended on it released; a
#      red suite or a conflict undoes the merge and posts why
#  20  verify-red measures a failing pre-existing test against the tree the
#      tests station started from: red there is the repo's (a stop, named);
#      green there is the new tests' interaction (admitted, recorded, and
#      green stops if the implementation does not reach it)
#  21  a check's complaint carries its first lines; at red, legitimate_at_red
#      sends a mistyped test back before the freeze; at green, a failure in a
#      frozen test that recurs without the implementation stops the run
#  22  a pre-existing test broken outside the tracked tree stops the run
#      instead of being retried against the implementation
#  23  a dependency manifest and its lockfile are planned together, scope lets
#      only a planned lockfile move, and no amendment reaches one
#  24  a station that moves the dependencies has them installed again from
#      the lock, and one that went around the lock is sent back
#  25  land, when the merge moves the dependencies: without --prepare the
#      suite's verdict says it ran against the install from before the merge,
#      with the command; with it the install is made here, and made again
#      after an undo
#  26  verify-red counts a criterion covered only by a test the runner
#      collected: its only test in a declared file the runner never collects
#      is sent back to the tests station, naming the file, which may stay as
#      a helper; coarse mode, which cannot tell, reads every file and says so
#  27  a land stopped between its merge and its verdict — Ctrl-C to its
#      process group, an INT or a TERM to its pid, an error on the way —
#      undoes the merge, leaves the card in Review and names an install it
#      had started; a red land's own exit is a verdict, not a stop
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
    # With the stack line a real runner prints: an absolute path, which is the
    # copy's path when a gate runs the suite in a copy of the tree.
    printf '<testcase classname="%s" name="%s"><failure message="assert marker missing">AssertionError: assert marker missing\n    at %s/%s:1</failure></testcase>' "$(cn "$2")" "$1" "$PWD" "$2"
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
# The misbehaviours of docs/DEFECTS-6.md: FAKE_TYPEBUG (every attempt) and
# FAKE_TESTS_TYPEBUG_FIRST put a mistyped mock in each test, FAKE_IMPL_BADTYPE_FIRST
# a type error in the first implementation, FAKE_DRIFT has the implement
# station change an installed dependency nobody tracks, and FAKE_DEPS has the
# plan name package.json and its lockfile, the first implement attempt add a
# dependency around the lock and the retry through it. For docs/DEFECTS-7.md,
# FAKE_TESTS_REHOME has a retried tests station move every test into
# tests/t1.py and leave the other declared files in place as helpers. Each
# dispatch's prompt is kept as .aif/tmp/fake-prompt-<station>-<n>, so a
# scenario can read what a retry was told.
cat >"$SANDBOX/fake-station.sh" <<'FAKE'
#!/bin/bash
set -u
station="$1" ticket="$2" wt="$3" prompt="$5" out="${10}"
work="$wt/tasks/$ticket"
count_file="$wt/.aif/tmp/fake-$station.count"
mkdir -p "$wt/.aif/tmp"
n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" >"$count_file"
printf '%s' "$prompt" >"$wt/.aif/tmp/fake-prompt-$station-$n"
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
    [ "${FAKE_DEPS:-0}" = 1 ] && change='["src/app.py", "package.json", "package-lock.json"]'
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
        typebug=""
        if [ "${FAKE_TYPEBUG:-0}" = 1 ] || { [ "${FAKE_TESTS_TYPEBUG_FIRST:-0}" = 1 ] && [ "$retry" = 0 ]; }; then
          typebug=" TYPEBUG"
        fi
        printf '# AC-00%s asserts impl%s — expects %s%s\n' "$i" "$i" "$exp" "$typebug" >"$wt/tests/t$i.py"
      fi
    done
    if [ "${FAKE_TESTS_REHOME:-0}" = 1 ] && [ "$retry" = 1 ]; then
      # Told that a criterion's only test is in a file the runner never
      # collects: every test moves into the first file, which it collects.
      for i in $nums; do
        [ -n "$i" ] && [ "$i" != 1 ] || continue
        cat "$wt/tests/t$i.py" >>"$wt/tests/t1.py"
        printf '# a helper: no test in here\n' >"$wt/tests/t$i.py"
      done
    fi
    ;;
  implement)
    if [ "${FAKE_STALL:-0}" = 1 ]; then
      printf 'def users():\n    return []  # wrong\n' >"$wt/src/app.py"
    else
      body=""
      for i in $nums; do [ -n "$i" ] && body="$body impl$i"; done
      [ "${FAKE_IMPL_BADTYPE_FIRST:-0}" = 1 ] && [ "$retry" = 0 ] && body="$body BADTYPE"
      printf 'def users():\n    return []  #%s\n' "$body" >"$wt/src/app.py"
    fi
    if [ "${FAKE_DRIFT:-0}" = 1 ]; then
      mkdir -p "$wt/deps" && : >"$wt/deps/drift"
    fi
    if [ "${FAKE_DEPS:-0}" = 1 ]; then
      printf '{ "dependencies": { "dep-a": "1", "dep-new": "2" } }\n' >"$wt/package.json"
      [ "$retry" = 0 ] || cp "$wt/package.json" "$wt/package-lock.json"
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
  "depends_on": ${4:-[]},
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
eq "…still told which signal fired" "$(printf '%s' "$armed" | grep -c "SENTINEL INT'")" "1"

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

# =============================== 18. --loop ==================================
printf '\n18. --loop drains Ready in the board'"'"'s order and stops when it is empty\n'
fresh_project "$SANDBOX/p18"
col() { "$AIF" board status --json | jq -r --arg t "$1" '[ .[] | select(.ticket == $t) ] | .[0].column // empty'; }
ticket_for AIF-16
ticket_for AIF-17
git add -A && git commit -qm "two tickets" >/dev/null
"$AIF" board create tasks/AIF-16/ticket.md --column ready >/dev/null
"$AIF" board create tasks/AIF-17/ticket.md --column ready >/dev/null
rc=0
"$AIF" work --loop >"$OUT/run16.out" 2>&1 || rc=$?
eq "exit 0 — every ticket taken was built" "$rc" "0"
eq "in the board's order" "$(grep -o 'loop [0-9] — AIF-1[67]' "$OUT/run16.out" | tr '\n' ';')" "loop 1 — AIF-16;loop 2 — AIF-17;"
eq "both cards are in Review" "$(col AIF-16),$(col AIF-17)" "review,review"
eq "each on its own branch" "$(git branch --list 'aif/AIF-1[67]' | wc -l | tr -d ' ')" "2"
eq "it stopped because Ready was empty" "$(grep -c 'Ready is empty' "$OUT/run16.out")" "1"
eq "the developer's checkout is untouched" "$(grep -c impl1 src/app.py)" "0"

# two tickets that are not ready: the first goes to Needs Human and the loop
# goes on; the second does too, and two in a row stop it — with nothing spent
ticket_for AIF-19 '[ { "id": "Q-001", "question": "which users?", "default": "all", "affects": ["AC-001"] } ]'
ticket_for AIF-20 '[ { "id": "Q-001", "question": "which users?", "default": "all", "affects": ["AC-001"] } ]'
git add -A && git commit -qm "two not-ready tickets" >/dev/null
"$AIF" board create tasks/AIF-19/ticket.md --column ready >/dev/null
"$AIF" board create tasks/AIF-20/ticket.md --column ready >/dev/null
rc=0
"$AIF" work --loop >"$OUT/run16b.out" 2>&1 || rc=$?
eq "exit 1 — not every ticket built" "$rc" "1"
eq "both went to Needs Human" "$(col AIF-19),$(col AIF-20)" "needs_human,needs_human"
eq "and two in a row stopped the loop" "$(grep -c 'two runs in a row did not build' "$OUT/run16b.out")" "1"
eq "nothing was dispatched" "$(grep -c '"station"' tasks/AIF-19/ledger.json tasks/AIF-20/ledger.json 2>/dev/null | awk -F: '{ s += $2 } END { print s + 0 }')" "0"

# --max-tickets takes that many and leaves the rest in Ready
ticket_for AIF-21
ticket_for AIF-22
git add -A && git commit -qm "two more" >/dev/null
"$AIF" board create tasks/AIF-21/ticket.md --column ready >/dev/null
"$AIF" board create tasks/AIF-22/ticket.md --column ready >/dev/null
rc=0
"$AIF" work --loop --max-tickets 1 >"$OUT/run16c.out" 2>&1 || rc=$?
eq "--max-tickets 1: exit 0" "$rc" "0"
eq "one built, one still in Ready" "$(col AIF-21),$(col AIF-22)" "review,ready"
eq "and says why it stopped" "$(grep -c 'max-tickets 1 reached' "$OUT/run16c.out")" "1"
rc=0
"$AIF" work AIF-22 --loop >"$OUT/run16d.out" 2>&1 || rc=$?
eq "--loop with a ticket is refused" "$rc" "1"

# =============================== 19. land ====================================
printf '\n19. land — the yes after review, as one command\n'
# Still in p18: AIF-16 and AIF-17 are in Review on their branches. A ticket
# that needs AIF-16 waits in Backlog, and says so in its own meta block.
ticket_for AIF-18 '[]' '' '["AIF-16"]'
git add -A && git commit -qm "a ticket waiting on AIF-16" >/dev/null
"$AIF" board create tasks/AIF-18/ticket.md --column backlog >/dev/null
rc=0
"$AIF" land AIF-16 >"$OUT/land16.out" 2>&1 || rc=$?
eq "exit 0 — landed" "$rc" "0"
eq "main has the implementation" "$(grep -c impl1 src/app.py)" "1"
eq "as one merge commit" "$(git log --format=%s -1)" "aif: land AIF-16 — one-command user export"
if [ -f tasks/AIF-16/report.md ]; then ok "the report came with it"; else bad "no report on main"; fi
eq "the card is in Done" "$(col AIF-16)" "done"
if [ -e .aif/worktrees/AIF-16 ]; then bad "the worktree is still there"; else ok "the worktree is gone"; fi
if git show-ref --verify --quiet refs/heads/aif/AIF-16; then bad "the branch is still there"; else ok "the branch is gone"; fi
eq "the landing note is on the card" \
  "$("$AIF" board show AIF-16 --json | jq -r '.comments[-1].text' | grep -c 'landed')" "1"
eq "the ticket waiting on it moved to Ready" "$(col AIF-18)" "ready"
eq "with a comment saying why" \
  "$("$AIF" board show AIF-18 --json | jq -r '.comments[-1].text' | grep -c 'released by aif land AIF-16')" "1"
eq "the summary names what moved" "$(grep -c '^released: AIF-18 → Ready' "$OUT/land16.out")" "1"
eq "the checkout is clean afterwards" "$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')" "0"

# refusals touch nothing
head_before="$(git rev-parse HEAD)"
rc=0
"$AIF" land AIF-18 >"$OUT/land18.out" 2>&1 || rc=$?
eq "no branch: refused" "$rc" "1"
eq "…and says so" "$(grep -c 'no branch aif/AIF-18' "$OUT/land18.out")" "1"
"$AIF" board move AIF-17 backlog >/dev/null
rc=0
"$AIF" land AIF-17 >"$OUT/land17a.out" 2>&1 || rc=$?
eq "a card not in Review: refused" "$rc" "1"
eq "…naming the column" "$(grep -c 'is in backlog, not Review' "$OUT/land17a.out")" "1"
eq "nothing merged" "$(git rev-parse HEAD)" "$head_before"
"$AIF" board move AIF-17 review >/dev/null

# a red suite on the RESULT undoes the merge: main grew a test after the
# build, and the branch does not satisfy it
printf '# t2 waits for impl2\n' >tests/t2.py
git add -A && git commit -qm "main grew a test after the build" >/dev/null
head_before="$(git rev-parse HEAD)"
rc=0
"$AIF" land AIF-17 >"$OUT/land17b.out" 2>&1 || rc=$?
eq "red on the result: exit 1" "$rc" "1"
eq "the merge was undone" "$(git rev-parse HEAD)" "$head_before"
eq "the card is in Needs Human" "$(col AIF-17)" "needs_human"
eq "with the reason" "$("$AIF" board show AIF-17 --json | jq -r '.comments[-1].text' | grep -c 'suite is red')" "1"
if git show-ref --verify --quiet refs/heads/aif/AIF-17; then ok "the branch is untouched"; else bad "the branch is gone"; fi
eq "the checkout is clean" "$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')" "0"

# a conflict is aborted, never resolved
"$AIF" board move AIF-17 review >/dev/null
git rm -q tests/t2.py
printf 'def users():\n    return []  # main moved on\n' >src/app.py
git add -A && git commit -qm "main moved the same line" >/dev/null
head_before="$(git rev-parse HEAD)"
rc=0
"$AIF" land AIF-17 >"$OUT/land17c.out" 2>&1 || rc=$?
eq "a conflict: exit 1" "$rc" "1"
eq "the merge was aborted" "$(git rev-parse HEAD)" "$head_before"
eq "no merge in progress" "$([ -f .git/MERGE_HEAD ] && echo yes || echo no)" "no"
eq "the card is in Needs Human" "$(col AIF-17)" "needs_human"
eq "with the reason" "$("$AIF" board show AIF-17 --json | jq -r '.comments[-1].text' | grep -c 'does not merge cleanly')" "1"


# ====== 20. verify-red measures a pre-existing failure against a baseline =====
#
# verify-red runs the suite after the tests station has written its files, and
# for one release it read every failure outside them as "the pre-existing suite
# is not green — fix the repo". On a live project the failure was a jest test
# that runs tsc over the whole tree, and what turned it red was a new test
# importing a module the plan had not created yet — as a red-first test in a
# typed project must. Two tickets in a row stopped there on false advice
# (docs/DEFECTS-6.md #1). The stub below makes the pre-existing t0 fail under a
# condition each case sets.
#
# t0_red_when <shell condition> — the pre-existing t0 fails whenever it holds.
t0_red_when() {
  local tmp
  tmp="$(mktemp)"
  awk -v cond="$1" '
    /^body="\$\(row t0 tests\/t0.py 1\)/ {
      print "g0=1; if " cond "; then g0=0; fi"
      sub(/row t0 tests\/t0.py 1/, "row t0 tests/t0.py \"$g0\"")
    }
    { print }' .aif/suite.sh >"$tmp" && mv "$tmp" .aif/suite.sh && chmod +x .aif/suite.sh
}
printf '\n20. a pre-existing test the new test files turn red is told apart from a red repo\n'
fresh_project "$SANDBOX/p20"
t0_red_when '[ -f tests/t1.py ] && ! grep -q impl1 src/app.py 2>/dev/null'
ticket_for AIF-20
git add -A && git commit -qm "ticket 20" >/dev/null
rc=0
"$AIF" work AIF-20 --no-worktree >"$OUT/run20.out" 2>&1 || rc=$?
eq "red only with the new tests, cleared by the implementation: built" "$rc" "0"
eq "verify-red admitted it, and says so on the line the ledger keeps" \
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | last | .reason' tasks/AIF-20/ledger.json |
     grep -c '1 pre-existing test(s) red only with them')" "1"
eq "the lock names it" "$(jq -c '.red_with_tests' tasks/AIF-20/tests.lock.json)" '["tests.t0::t0"]'
eq "and green passed once the code existed" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | last | .result' tasks/AIF-20/ledger.json)" "pass"

# A repository already red: still a stop — but naming the test, and saying it
# was measured without this ticket's files. In a worktree, as the worker runs
# by default: every absolute path there runs through .aif/worktrees/, and the
# probe used to read the red test's own stack trace as the runner collecting
# the worker's checkouts, and refuse the run.
fresh_project "$SANDBOX/p20b"
t0_red_when 'true'
ticket_for AIF-20
git add -A && git commit -qm "ticket 20b" >/dev/null
rc=0
"$AIF" work AIF-20 >"$OUT/run20b.out" 2>&1 || rc=$?
w20=.aif/worktrees/AIF-20/tasks/AIF-20
eq "red before the new tests existed: stopped" "$rc" "1"
eq "…and not refused as a runner collecting the worker's checkouts" \
  "$(grep -c 'it collects .aif/worktrees/ too' "$OUT/run20b.out")" "0"
eq "verify-red could not render a verdict" \
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | last | .result' "$w20/ledger.json")" "error"
eq "and it names the test, on the line the ledger keeps" \
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | last | .reason' "$w20/ledger.json" |
     grep -c 'red without this ticket.s test files too (1 failing: tests.t0::t0)')" "1"
eq "nothing was frozen" "$(test -f "$w20/tests.lock.json" && echo yes || echo no)" "no"

# Red with the new tests and NOT cleared by the implementation — a test that
# the new files break whatever the code does. Admitted at the freeze; green
# measures it without the implementation, finds it failing the same way, and
# stops instead of retrying the implement station against it.
fresh_project "$SANDBOX/p20c"
t0_red_when '[ -f tests/t1.py ]'
ticket_for AIF-20
git add -A && git commit -qm "ticket 20c" >/dev/null
rc=0
"$AIF" work AIF-20 --no-worktree >"$OUT/run20c.out" 2>&1 || rc=$?
eq "red with the tests, out of the implementation's reach: stopped" "$rc" "1"
eq "verify-red admitted it" \
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | last | .result' tasks/AIF-20/ledger.json)" "pass"
eq "green could not render a verdict on the implementation" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | last | .result' tasks/AIF-20/ledger.json)" "error"
eq "and said it is out of the implementation's reach" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | last | .reason' tasks/AIF-20/ledger.json |
     grep -c 'out of the implementation.s reach')" "1"
eq "implement was dispatched once, not attempts_max times" \
  "$(jq '[.entries[] | select(.station == "implement")] | length' tasks/AIF-20/ledger.json)" "1"
eq "the report says the new tests break it, and not to reinstall" \
  "$(grep -c 'the new tests' tasks/AIF-20/report.md),$(grep -c 'Run "prepare"' tasks/AIF-20/report.md)" "1,0"
eq "and its first line no longer blames the environment" \
  "$(grep -c 'that is the environment, not the artifact' tasks/AIF-20/report.md)" "0"

# ====== 21. a check's failure carries its location, and is attributed ========
#
# The project's typecheck is a check, and a check's complaint used to be its
# LAST line: for tsc, "Source has 0 element(s) but target requires 1." — no
# file, no line. And a type error inside a frozen test file sent the implement
# station round three times at something it may not edit (docs/DEFECTS-6.md
# #2). The stand-in for tsc below prints one located line per problem: a
# missing module for every new test whose implementation is absent, a mistyped
# mock in a test marked TYPEBUG, a bad argument in code marked BADTYPE.
typed() { # <dir> <checks json>
  fresh_project "$1"
  cat >.aif/typecheck.sh <<'TSC'
#!/bin/bash
out=""
add() { out="$out$1
"; }
for f in tests/t[1-8].py; do
  [ -f "$f" ] || continue
  n="${f#tests/t}"
  n="${n%.py}"
  grep -q "impl$n" src/app.py 2>/dev/null ||
    add "$f(1,1): error TS2307: Cannot find module '../src/impl$n' or its corresponding type declarations."
  if grep -q TYPEBUG "$f"; then
    # Absolute, the way eslint prints paths — and the gates run it in copies.
    add "$PWD/$f(2,5): error TS2322: Type 'Mock<Category, []>' is not assignable to type 'Mock<Category | null, [string]>'."
    add "  Types of parameters 'args' and 'args' are incompatible."
    add "    Source has 0 element(s) but target requires 1."
  fi
done
if grep -q BADTYPE src/app.py 2>/dev/null; then
  add "src/app.py(2,12): error TS2345: Argument of type 'string' is not assignable to parameter of type 'number'."
fi
[ -n "$out" ] || exit 0
printf '%s' "$out"
exit 2
TSC
  chmod +x .aif/typecheck.sh
  local tmp
  tmp="$(mktemp)"
  jq --argjson c "$2" '.checks = $c' .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
  git add -A && git commit -qm "a typecheck" >/dev/null
}
printf '\n21. a check says where it failed, and a failure in the frozen tests stops the run\n'

# At red, with legitimate_at_red: the missing modules are let through, and the
# mistyped mock is sent back to the tests station — before the freeze, while
# it can still be fixed.
typed "$SANDBOX/p21" '[{ "name": "typecheck", "command": "bash .aif/typecheck.sh",
  "phase": ["red", "green"], "required": true, "legitimate_at_red": ["error TS2307"] }]'
eq "legitimate_at_red validates" "$("$AIF" project check >/dev/null 2>&1; echo $?)" "0"
ticket_for AIF-21
git add -A && git commit -qm "ticket 21" >/dev/null
rc=0
FAKE_TESTS_TYPEBUG_FIRST=1 "$AIF" work AIF-21 --no-worktree >"$OUT/run21.out" 2>&1 || rc=$?
eq "a mistyped test is sent back before the freeze, and the retry builds" "$rc" "0"
eq "verify-red rejected it, then admitted the fix" \
  "$(jq -r '[.entries[] | select(.gate == "verify-red") | .result] | join(",")' tasks/AIF-21/ledger.json)" "fail,pass"
eq "the retry was told where the error is" \
  "$(grep -c 'tests/t1.py(2,5): error TS2322' .aif/tmp/fake-prompt-tests-2)" "1"
eq "…all of it, not the last line alone" \
  "$(grep -c 'Source has 0 element(s) but target requires 1' .aif/tmp/fake-prompt-tests-2)" "1"
eq "…and nothing the missing implementation causes" \
  "$(grep -c 'TS2307' .aif/tmp/fake-prompt-tests-2)" "0"
eq "the red check that let the missing module through says so" \
  "$(jq -r '[.entries[] | select(.event == "check" and .phase == "red")] | last | .result' tasks/AIF-21/ledger.json)" "expected"
eq "and the same check passed at green" \
  "$(jq -r '[.entries[] | select(.event == "check" and .phase == "green")] | last | .result' tasks/AIF-21/ledger.json)" "pass"
eq "legitimate_at_red on a check not bound to red is refused" \
  "$(jq '.checks[0].phase = ["green"]' .aif/project.json >"$OUT/bad21.json" &&
     /bin/bash -c '. "$1/lib/common.sh"; . "$1/lib/paths.sh"; . "$1/lib/project.sh"; aif_project_validate "$2"' \
       _ "$ROOT" "$OUT/bad21.json" 2>&1 | grep -c 'only the red phase reads it')" "1"

# A red check that fails and names none of the test files cannot be read as
# the tests' — and read as "expected" it would be a check that never fails.
typed "$SANDBOX/p21d" '[{ "name": "legacy", "phase": ["red"], "required": true,
  "command": "echo \"src/legacy.py(3,1): error TS1005: ; expected.\"; exit 2",
  "legitimate_at_red": ["error TS2307"] }]'
ticket_for AIF-21
git add -A && git commit -qm "ticket 21d" >/dev/null
rc=0
"$AIF" work AIF-21 --no-worktree >"$OUT/run21d.out" 2>&1 || rc=$?
eq "a red check failing outside the tests: stopped" "$rc" "1"
eq "verify-red could not render a verdict, and said where it failed" \
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | last | .result + ": " + .reason' tasks/AIF-21/ledger.json |
     grep -c '^error: .*fails somewhere other than this ticket.s test files')" "1"
eq "the tests station was not sent round again for it" \
  "$(jq '[.entries[] | select(.station == "tests")] | length' tasks/AIF-21/ledger.json)" "1"

# Green only: the mistyped mock is frozen. The typecheck fails in the frozen
# test, fails the same way without the implementation, and the run stops at
# the first attempt instead of the third.
typed "$SANDBOX/p21b" '[{ "name": "typecheck", "command": "bash .aif/typecheck.sh",
  "phase": ["green"], "required": true }]'
ticket_for AIF-21
git add -A && git commit -qm "ticket 21b" >/dev/null
rc=0
FAKE_TYPEBUG=1 "$AIF" work AIF-21 --no-worktree >"$OUT/run21b.out" 2>&1 || rc=$?
eq "a type error frozen into a test: stopped" "$rc" "1"
eq "green could not render a verdict on the implementation" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | last | .result' tasks/AIF-21/ledger.json)" "error"
eq "…and says the failure is the frozen tests'" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | last | .reason' tasks/AIF-21/ledger.json |
     grep -c 'fails in the frozen tests, not in the implementation')" "1"
eq "implement was dispatched once, not attempts_max times" \
  "$(jq '[.entries[] | select(.station == "implement")] | length' tasks/AIF-21/ledger.json)" "1"
eq "the report carries the located line" \
  "$(grep -c 'tests/t1.py(2,5): error TS2322' tasks/AIF-21/report.md)" "1"

# Green only, and the type error is the implementation's own: a rejection, with
# the check's first lines in the complaint rather than its last.
typed "$SANDBOX/p21c" '[{ "name": "typecheck", "command": "bash .aif/typecheck.sh",
  "phase": ["green"], "required": true }]'
ticket_for AIF-21
git add -A && git commit -qm "ticket 21c" >/dev/null
rc=0
FAKE_IMPL_BADTYPE_FIRST=1 "$AIF" work AIF-21 --no-worktree >"$OUT/run21c.out" 2>&1 || rc=$?
eq "a type error the implementation added: rejected, retried, built" "$rc" "0"
eq "green rejected it, then passed" \
  "$(jq -r '[.entries[] | select(.gate == "green") | .result] | join(",")' tasks/AIF-21/ledger.json)" "fail,pass"
eq "the retry was told the file and the line" \
  "$(grep -c 'src/app.py(2,12): error TS2345' .aif/tmp/fake-prompt-implement-2)" "1"

# ====== 22. a pre-existing test broken outside the tree stops the run ========
#
# A station installed a package around the lockfile and node_modules drifted:
# twelve pre-existing tests red, and green blamed the implementation for them
# three times (docs/DEFECTS-6.md #3). Here the drift is a file in a gitignored
# directory the implement station writes and the suite reads. Without the
# implementation the tree is the tree that passed at the freeze — and it still
# fails, so what moved is outside it.
printf '\n22. a pre-existing test broken outside the tracked tree stops the run\n'
fresh_project "$SANDBOX/p22"
printf 'deps/\n' >>.gitignore
t0_red_when '[ -f deps/drift ]'
ticket_for AIF-22
git add -A && git commit -qm "ticket 22" >/dev/null
rc=0
FAKE_DRIFT=1 "$AIF" work AIF-22 --no-worktree >"$OUT/run22.out" 2>&1 || rc=$?
eq "an installed dependency moved under the run: stopped" "$rc" "1"
eq "green could not render a verdict on the implementation" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | last | .result' tasks/AIF-22/ledger.json)" "error"
eq "and said the test is out of the implementation's reach" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | last | .reason' tasks/AIF-22/ledger.json |
     grep -c 'out of the implementation.s reach')" "1"
eq "implement was dispatched once" \
  "$(jq '[.entries[] | select(.station == "implement")] | length' tasks/AIF-22/ledger.json)" "1"
eq "the report says where to look" "$(grep -c 'Run "prepare" in the worktree' tasks/AIF-22/report.md)" "1"
eq "…and gives no advice that belongs to another kind of failure" \
  "$(grep -c 'the new tests' tasks/AIF-22/report.md)" "0"

# ====== 23. a manifest and its lockfile move together, or not at all ==========
printf '\n23. a dependency manifest and its lockfile move together, or not at all\n'
mkdir -p "$SANDBOX/p23"
cp -R "$SANDBOX/p1/." "$SANDBOX/p23/" 2>/dev/null || true
cd "$SANDBOX/p23" || exit 1
printf '{ "dependencies": { "dep-a": "1" } }\n' >package.json
cp package.json package-lock.json
mkdir -p packages/web && printf '{ "name": "web" }\n' >packages/web/package.json
git add -A && git commit -qm "dependencies" >/dev/null
plan_files() { # <files.change json> — the plan's manifest, rewritten through jq
  local meta
  meta="$(sed -n '/^<!-- aif:meta$/,/^-->$/p' tasks/AIF-1/plan.md | sed '1d;$d' |
    jq -c --argjson c "$1" '.files.change = $c | .ac_coverage |= map_values(["src/app.py"])')"
  printf '<!-- aif:meta\n%s\n-->\n# AIF-1 — plan\n' "$meta" >tasks/AIF-1/plan.md
}
pg() { /bin/bash .aif/gates/plan.sh "$PWD/tasks/AIF-1" 2>&1; }
plan_files '["src/app.py", "package.json"]'
eq "a manifest without its lockfile is refused" \
  "$(pg | grep -c 'names "package.json" but not "package-lock.json"')" "1"
plan_files '["src/app.py", "package.json", "package-lock.json"]'
rc=0
pg >"$OUT/plan23.out" || rc=$?
eq "with it, the plan is admitted" "$rc" "0"
plan_files '["src/app.py", "package-lock.json"]'
eq "a lockfile without its manifest is refused" \
  "$(pg | grep -c '"package-lock.json", a lockfile, and no manifest it pins')" "1"
plan_files '["src/app.py", "packages/web/package.json"]'
eq "a workspace manifest needs the lockfile at the root" \
  "$(pg | grep -c 'names "packages/web/package.json" but not "package-lock.json"')" "1"
plan_files '["src/app.py", "packages/web/package.json", "package-lock.json"]'
rc=0
pg >"$OUT/plan23b.out" || rc=$?
eq "…and is admitted with it" "$rc" "0"

sg() { /bin/bash .aif/gates/scope.sh "$PWD/tasks/AIF-1" 2>&1; }
dispatched_now() {
  jq --arg b "$(git rev-parse HEAD)" '.dispatch_base = $b' tasks/AIF-1/run.json >"$OUT/run23.json" &&
    cp "$OUT/run23.json" tasks/AIF-1/run.json
}
plan_files '["src/app.py", "package.json", "package-lock.json"]'
git add -A && git commit -qm "the plan names the lockfile" >/dev/null
dispatched_now
printf '{ "dependencies": { "dep-a": "1", "dep-b": "2" } }\n' >package.json
cp package.json package-lock.json
rc=0
sg >"$OUT/scope23.out" || rc=$?
eq "scope lets a lockfile the plan names move" "$rc" "0"
git checkout -q -- package.json package-lock.json
plan_files '["src/app.py"]'
git add -A && git commit -qm "the plan names neither" >/dev/null
dispatched_now
printf '{ "dependencies": { "dep-a": "2" } }\n' >package-lock.json
eq "and refuses one it does not" \
  "$(sg | grep -c 'package-lock.json is a lockfile, and the plan does not name it')" "1"
git checkout -q -- package-lock.json

# Every lockfile the table knows is refused as an amendment — the table lives
# in the gates' _lib.sh and the refusal in lib/cmd_amend.sh.
refused=0
known=0
for n in $(/bin/bash -c '. "$1/sets/claude/gates/_lib.sh"
  for m in package.json pyproject.toml Cargo.toml go.mod; do aif_g_lock_names "$m"; done' _ "$ROOT"); do
  known=$((known + 1))
  # Held, then matched: piped, pipefail would hand the pipeline aif's own exit
  # 1 — which is the refusal this counts — and read every match as a miss.
  said="$("$AIF" _amend-plan AIF-1 "packages/web/$n" "a dependency" 2>&1)"
  case "$said" in
    *"a lockfile changes only"*) refused=$((refused + 1)) ;;
  esac
done
eq "an amendment may not reach any lockfile ($known known)" "$refused" "$known"
eq "the worker's dependency patterns are the gates' own" \
  "$(/bin/bash -c '. "$1/lib/paths.sh"; printf "%s|%s" "$AIF_DEP_MANIFESTS" "$AIF_DEP_LOCKFILES"' _ "$ROOT")" \
  "$(/bin/bash -c '. "$1/sets/claude/gates/_lib.sh"; printf "%s|%s" "$AIF_G_MANIFESTS" "$AIF_G_LOCKFILES"' _ "$ROOT")"
eq "and the gates' table agrees with their patterns" \
  "$(/bin/bash -c '. "$1/sets/claude/gates/_lib.sh"
     for m in package.json pyproject.toml Cargo.toml go.mod; do
       printf "%s\n" "$m" | grep -Ev "$AIF_G_MANIFESTS"
       aif_g_lock_names "$m" | grep -Ev "$AIF_G_LOCKFILES"
     done' _ "$ROOT" | wc -l | tr -d ' ')" "0"

# ====== 24. a station that moves the dependencies gets them installed again ===
#
# "prepare" is the project's install (npm ci). The stand-in below installs what
# the lockfile pins and refuses a manifest the lockfile does not match, as npm
# ci does. The first implement attempt adds a dependency to package.json alone —
# around the lock — and is sent back with prepare's own words; the retry adds
# it through the lock, and the dependencies are installed from it.
printf '\n24. a station that moves the dependencies has them installed again from the lock\n'
fresh_project "$SANDBOX/p24"
printf '{ "dependencies": { "dep-a": "1" } }\n' >package.json
cp package.json package-lock.json
printf 'deps/\n' >>.gitignore
cat >.aif/prepare.sh <<'PREP'
#!/bin/bash
want="$(grep -o '"dep-[a-z]*"' package.json | sort | tr '\n' ' ')"
have="$(grep -o '"dep-[a-z]*"' package-lock.json | sort | tr '\n' ' ')"
if [ "$want" != "$have" ]; then
  echo "npm error \`npm ci\` can only install packages when your package.json and package-lock.json are in sync."
  echo "npm error Missing: dep-new@2 from lock file"
  exit 1
fi
mkdir -p deps
printf '%s\n' $have >deps/installed
PREP
chmod +x .aif/prepare.sh
tmp="$(mktemp)"
jq '.prepare = "bash .aif/prepare.sh"' .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
ticket_for AIF-24
git add -A && git commit -qm "ticket 24" >/dev/null
rc=0
FAKE_DEPS=1 "$AIF" work AIF-24 --no-worktree >"$OUT/run24.out" 2>&1 || rc=$?
eq "a dependency added around the lock, then through it: built" "$rc" "0"
eq "the first attempt was sent back by prepare, before any gate" \
  "$(jq -r '[.entries[] | select(.gate == "prepare") | .result] | join(",")' tasks/AIF-24/ledger.json)" "fail"
eq "with prepare's own words in the retry" "$(grep -c 'are in sync' .aif/tmp/fake-prompt-implement-2)" "1"
eq "implement was dispatched twice" \
  "$(jq '[.entries[] | select(.station == "implement")] | length' tasks/AIF-24/ledger.json)" "2"
eq "the dependencies were installed from the lockfile the retry left" \
  "$(tr '\n' ' ' <deps/installed)" '"dep-a" "dep-new" '
eq "and scope let the lockfile the plan names move" \
  "$(jq -r '[.entries[] | select(.gate == "scope")] | last | .result' tasks/AIF-24/ledger.json)" "pass"

# ====== 25. land, when the merge moves the dependencies =======================
#
# land runs the suite on the merge in the developer's checkout, against what is
# installed THERE — and a merge that moved package.json and its lockfile was
# judged against the install from before it: "the suite is red", the merge
# undone, a ticket with nothing wrong in it in Needs Human (docs/DEFECTS-6.md
# #3). Installing in someone's own checkout is theirs to allow. Without
# --prepare a red says what it was measured against and gives the command that
# lands it installed, and a green lands and says the install is not the
# merge's; with it, "prepare" runs before the suite, and again after an undo,
# for the lockfile the undo put back. The stand-in is scenario 24's npm ci,
# which can also be offline — and then, as npm ci does, leaves no install at
# all. t0 is red while the lockfile pins dep-new and the install lacks it: a
# test importing a package that is not installed.
printf '\n25. land, when the merge moves the dependencies: named, or installed when asked\n'
fresh_project "$SANDBOX/p25"
printf '{ "dependencies": { "dep-a": "1" } }\n' >package.json
cp package.json package-lock.json
printf 'deps/\n' >>.gitignore
cat >.aif/prepare.sh <<'PREP'
#!/bin/bash
if [ -n "${PREP_OFFLINE:-}" ]; then
  rm -rf deps
  echo "npm error request to https://registry.npmjs.org/dep-new failed, reason: getaddrinfo ENOTFOUND registry.npmjs.org"
  exit 1
fi
want="$(grep -o '"dep-[a-z]*"' package.json | sort | tr '\n' ' ')"
have="$(grep -o '"dep-[a-z]*"' package-lock.json | sort | tr '\n' ' ')"
if [ "$want" != "$have" ]; then
  echo "npm error \`npm ci\` can only install packages when your package.json and package-lock.json are in sync."
  exit 1
fi
rm -rf deps && mkdir -p deps
printf '%s\n' $have >deps/installed
# npm install, where npm ci was meant: it installs, and rewrites the lockfile
[ -z "${PREP_REWRITES:-}" ] || printf '\n' >>package-lock.json
PREP
chmod +x .aif/prepare.sh
tmp="$(mktemp)"
jq '.prepare = "bash .aif/prepare.sh"' .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
t0_red_when 'grep -q dep-new package-lock.json && ! grep -q dep-new deps/installed 2>/dev/null'
ticket_for AIF-25
git add -A && git commit -qm "ticket 25, and a lockfile" >/dev/null
bash .aif/prepare.sh # the developer's own install
installed() { cat deps/installed 2>/dev/null | tr '\n' ' '; }
last_comment() { "$AIF" board show "$1" --json | jq -r '.comments[-1].text'; }
"$AIF" board create tasks/AIF-25/ticket.md --column ready >/dev/null
rc=0
FAKE_DEPS=1 "$AIF" work AIF-25 >"$OUT/run25.out" 2>&1 || rc=$?
eq "a ticket that adds a dependency through the lock: built, in Review" "$rc,$(col AIF-25)" "0,review"

# without --prepare: red against the install from before the merge, and the
# reason says so, with a command that works from Needs Human
head_before="$(git rev-parse HEAD)"
rc=0
"$AIF" land AIF-25 >"$OUT/land25a.out" 2>&1 || rc=$?
eq "red against the old install: exit 1, the merge undone" "$rc,$(git rev-parse HEAD)" "1,$head_before"
eq "it named what moved, before the suite ran" "$(grep -E '^(deps|suite) ' "$OUT/land25a.out" | head -1)" \
  "deps      package-lock.json, package.json moved — not installed here (--prepare installs them)"
eq "the install here was not touched" "$(installed)" '"dep-a" '
eq "the reason says what the suite ran against" \
  "$(last_comment AIF-25 | grep -c 'the suite ran against the dependencies installed here before it')" "1"
eq "…and the command that lands it installed" \
  "$(last_comment AIF-25 | grep -c 'aif board move AIF-25 review && aif land AIF-25 --prepare')" "1"
eq "the terminal has the command too" \
  "$(grep -c 'aif board move AIF-25 review && aif land AIF-25 --prepare' "$OUT/land25a.out")" "1"
eq "the card is in Needs Human" "$(col AIF-25)" "needs_human"

# green without --prepare: in a copy of this checkout whose developer had
# installed dep-new by hand, trying the branch. It lands, and says the install
# here was not made from the lockfile it merged.
mkdir -p "$SANDBOX/p25b"
cp -R "$SANDBOX/p25/." "$SANDBOX/p25b/"
cd "$SANDBOX/p25b" || exit 1
"$AIF" board move AIF-25 review >/dev/null
printf '"dep-a"\n"dep-new"\n' >deps/installed
rc=0
"$AIF" land AIF-25 >"$OUT/land25b.out" 2>&1 || rc=$?
eq "green against the install from before the merge: landed" "$rc,$(col AIF-25)" "0,done"
eq "the summary says it was not installed from the merge, and how to" \
  "$(grep -c '^deps: .*not installed here; the suite ran against the install from before the merge. Install them: bash .aif/prepare.sh' "$OUT/land25b.out")" "1"
eq "so does the landing note" "$(last_comment AIF-25 | grep -c '^- dependencies: .*not installed here')" "1"
eq "and the install was left alone" "$(installed)" '"dep-a" "dep-new" '
cd "$SANDBOX/p25" || exit 1

# --prepare with no "prepare" to run is refused, and nothing moves
"$AIF" board move AIF-25 review >/dev/null
jq 'del(.prepare)' .aif/project.json >"$OUT/p25.json" && cp "$OUT/p25.json" .aif/project.json
rc=0
"$AIF" land AIF-25 --prepare >"$OUT/land25c.out" 2>&1 || rc=$?
eq "--prepare with no prepare to run: refused" "$rc" "1"
eq "…saying so" "$(grep -c 'names no "prepare"' "$OUT/land25c.out")" "1"
eq "…before anything moved" "$(git rev-parse HEAD),$(col AIF-25)" "$head_before,review"
git checkout -q -- .aif/project.json

# --prepare, and red anyway: main grew a test after the build. Installed
# before the suite — only the new test fails, not t0 — and installed again,
# for the lockfile the undo put back.
printf '# t2 waits for impl2\n' >tests/t2.py
git add -A && git commit -qm "main grew a test after the build" >/dev/null
head_before="$(git rev-parse HEAD)"
rc=0
"$AIF" land AIF-25 --prepare >"$OUT/land25d.out" 2>&1 || rc=$?
eq "--prepare, red on the result: exit 1, the merge undone" "$rc,$(git rev-parse HEAD)" "1,$head_before"
eq "it installed, before the suite ran" "$(grep -E '^(prepare|suite) ' "$OUT/land25d.out" | head -1)" \
  "prepare   package-lock.json, package.json moved — bash .aif/prepare.sh"
eq "…so only the new test failed" "$(grep -c '(exit 0, 1 failing)' "$OUT/land25d.out")" "1"
eq "the undo installed again, from the lockfile it put back" "$(installed)" '"dep-a" '
eq "…and the reason says so" \
  "$(last_comment AIF-25 | grep -c 'installed again, from the lockfile the undo put back')" "1"
eq "the checkout is clean" "$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')" "0"

# --prepare, offline: the install fails on the result and again after the
# undo, and leaves nothing installed. Said, with the command.
"$AIF" board move AIF-25 review >/dev/null
rc=0
PREP_OFFLINE=1 "$AIF" land AIF-25 --prepare >"$OUT/land25e.out" 2>&1 || rc=$?
eq "--prepare and the install fails: exit 1, the merge undone" "$rc,$(git rev-parse HEAD)" "1,$head_before"
eq "the reason is prepare's, in its own words" \
  "$(last_comment AIF-25 | grep -c 'failed on the result (exit 1)'),$(last_comment AIF-25 | grep -c 'getaddrinfo ENOTFOUND')" "1,1"
eq "…and says the install here may not match, with the command" \
  "$(last_comment AIF-25 | grep -c 'what is installed here may not match it. Run:')" "1"
eq "the terminal says so too" "$(grep -c 'what is installed here may not match it' "$OUT/land25e.out")" "1"
eq "landing it again keeps --prepare" \
  "$(last_comment AIF-25 | grep -c 'run: aif board move AIF-25 review && aif land AIF-25 --prepare$')" "1"
bash .aif/prepare.sh # the developer runs it, online again

# --prepare, and the install rewrites the lockfile: not the install the merge
# pinned, and it would leave the checkout dirty. Refused like a failed one —
# and the undo's own install rewrites it too, which the undo puts back.
"$AIF" board move AIF-25 review >/dev/null
rc=0
PREP_REWRITES=1 "$AIF" land AIF-25 --prepare >"$OUT/land25g.out" 2>&1 || rc=$?
eq "--prepare and the install rewrites the lockfile: exit 1, the merge undone" \
  "$rc,$(git rev-parse HEAD)" "1,$head_before"
eq "…saying which file" "$(grep -c '(bash .aif/prepare.sh) rewrote package-lock.json' "$OUT/land25g.out")" "1"
eq "the checkout is clean" "$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')" "0"

# --prepare, green: landed, with what the merged lockfile pins installed here
"$AIF" board move AIF-25 review >/dev/null
git rm -q tests/t2.py
git commit -qm "main dropped the test" >/dev/null
rc=0
"$AIF" land AIF-25 --prepare >"$OUT/land25f.out" 2>&1 || rc=$?
eq "--prepare: landed" "$rc,$(col AIF-25)" "0,done"
eq "as one merge commit" "$(git log --format=%s -1)" "aif: land AIF-25 — one-command user export"
eq "with the merged lockfile's dependencies installed here" "$(installed)" '"dep-a" "dep-new" '
eq "the summary says so" \
  "$(grep -c '^deps: .*moved — installed here (bash .aif/prepare.sh)' "$OUT/land25f.out")" "1"
eq "so does the landing note" "$(last_comment AIF-25 | grep -c '^- dependencies: .*installed here (bash')" "1"
eq "the checkout is clean afterwards" "$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')" "0"

# ====== 26. a criterion is covered only by a test the runner collected ========
#
# verify-red read coverage from the text of every declared test file, and asked
# only that the declared files, together, contribute a collected test. One the
# runner never collects — a name outside testMatch or python_files, a jest
# suite that fails to load, which jest-junit leaves out of the report — then
# counted in full: "all criteria covered", the file frozen, none of its tests
# in `covering`, and none of them run at green either. A criterion whose only
# test lived there was checked by nothing (docs/DEFECTS-7.md #1). The stub
# runner below never collects tests/t2.py, and the tests station's first
# attempt puts AC-002's only test in it.
#
# never_collects <n> — the stub runner leaves tests/t<n>.py out of its report.
never_collects() {
  local tmp
  tmp="$(mktemp)"
  awk -v n="$1" '
    { print }
    index($0, "[ -f \"tests/t$n.py\" ] || continue") { print "  [ \"$n\" != " n " ] || continue" }
  ' .aif/suite.sh >"$tmp" && mv "$tmp" .aif/suite.sh && chmod +x .aif/suite.sh
}
printf '\n26. a criterion is covered only by a test the runner collected\n'
fresh_project "$SANDBOX/p26"
never_collects 2
ticket_for AIF-26 '[]' ',
    { "id": "AC-002", "surface": "export",
      "given": "the export ran", "when": "the output is read",
      "then": "writes the manifest marker", "expect": "impl2" }'
git add -A && git commit -qm "ticket 26" >/dev/null
rc=0
FAKE_TESTS_REHOME=1 "$AIF" work AIF-26 --no-worktree >"$OUT/run26.out" 2>&1 || rc=$?
eq "a criterion whose only test is never collected: sent back, then built" "$rc" "0"
eq "verify-red rejected it — the tests station's to fix — then admitted the fix" \
  "$(jq -r '[.entries[] | select(.gate == "verify-red") | .result] | join(",")' tasks/AIF-26/ledger.json)" "fail,pass"
eq "the retry was told which criterion, and the file its test is in" \
  "$(grep -c 'AC-002 is referenced only where the runner collected no test: tests/t2.py' .aif/tmp/fake-prompt-tests-2)" "1"
eq "…where its literal is too" \
  "$(grep -c 'AC-002 expected value (impl2) appears only where the runner collected no test: tests/t2.py' .aif/tmp/fake-prompt-tests-2)" "1"
eq "…and that a test in that file runs nowhere" \
  "$(grep -c 'the runner collected no test from: tests/t2.py — a test there runs neither' .aif/tmp/fake-prompt-tests-2)" "1"
eq "the file stayed declared, as a helper, and is frozen with the rest" \
  "$(jq -r '.tests | has("tests/t2.py")' tasks/AIF-26/tests.lock.json)" "true"
eq "the covering test is the one the runner collects" \
  "$(jq -c '.covering' tasks/AIF-26/tests.lock.json)" '["tests.t1::t1"]'

# By hand, on the tree before the implementation: the helper passes and is
# named on the way through, and the first attempt's files are exit 1.
printf 'def users():\n    return []\n' >src/app.py
rc=0
/bin/bash .aif/gates/verify-red.sh "$PWD/tasks/AIF-26" >"$OUT/red26.out" 2>&1 || rc=$?
eq "a declared helper with no test in it passes" "$rc" "0"
eq "…and is named on the pass path" \
  "$(grep -c '! the runner collected no test from: tests/t2.py' "$OUT/red26.out")" "1"
printf '# AC-001 asserts impl1 — expects -1\n' >tests/t1.py
printf '# AC-002 asserts impl2 — expects impl2\n' >tests/t2.py
rc=0
/bin/bash .aif/gates/verify-red.sh "$PWD/tasks/AIF-26" >"$OUT/red26b.out" 2>&1 || rc=$?
eq "the first attempt's files: exit 1, a rejection" "$rc" "1"
eq "…of coverage" "$(sed -n 1p "$OUT/red26b.out")" "REJECT coverage: 3 problem(s)"

# Coarse mode has no per-test report and cannot tell a collected file from one
# the runner never saw. It reads every declared file, as it did — the same two
# files pass it — and says what it could not tell.
tmp="$(mktemp)"
jq '.test.command = "mkdir -p .aif/tmp && printf \"<testsuites/>\" >.aif/tmp/report.xml && exit 1"' \
  .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
rc=0
/bin/bash .aif/gates/verify-red.sh "$PWD/tasks/AIF-26" >"$OUT/red26c.out" 2>&1 || rc=$?
eq "coarse: the same two files are red, and pass" "$rc" "0"
eq "…saying the coverage could not see what the runner collects" \
  "$(grep -c 'coverage was read from every declared test file' "$OUT/red26c.out")" "1"

# ====== 27. a land stopped before its verdict undoes itself ====================
#
# land merges into the developer's checkout first, and only then installs
# (--prepare) and runs the suite: minutes, with npm ci, which empties
# node_modules before it fills it. A Ctrl-C there, or a supervisor's TERM, left
# the merge commit on the branch, the card in Review, the worktree gone and
# half an install, and nothing said so. A stop now undoes the merge and says
# so; the card stays in Review, because a stop decides nothing; and an install
# that had started is named with its command, not run again. The stand-ins
# wait where the land is to be stopped (STOP_IN) until released or killed.
#
# A signal arrives two ways, and both are sent. Ctrl-C goes to the terminal's
# whole foreground process group, so the stand-in dies with the land. A signal
# to the land's pid alone reaches bash while it waits on a child, and bash runs
# the trap only once the child returns — here a suite that came back green,
# which the stop must still beat. With no trap, that INT was not even a stop:
# bash saw the suite exit normally, took it that the suite had handled the
# INT, and the land went on to Done.
printf '\n27. a land stopped between its merge and its verdict undoes itself\n'
fresh_project "$SANDBOX/p27"
printf '{ "dependencies": { "dep-a": "1" } }\n' >package.json
cp package.json package-lock.json
printf 'deps/\n' >>.gitignore
cat >.aif/stop-here.sh <<'STOP'
#!/bin/bash
# stop-here.sh <point> — where the land is to be stopped, say so and wait:
# until released, and for thirty seconds at most.
[ "${STOP_IN:-}" = "$1" ] || exit 0
touch "$STOP_MARK"
i=0
while [ ! -f "$STOP_GO" ] && [ "$i" -lt 300 ]; do
  sleep 0.1
  i=$((i + 1))
done
STOP
# scenario 24's npm ci, with the wait where the real one spends its minutes:
# after node_modules is emptied, before it is filled
cat >.aif/prepare.sh <<'PREP'
#!/bin/bash
[ -z "${STOP_LOG:-}" ] || echo prepare >>"$STOP_LOG"
want="$(grep -o '"dep-[a-z]*"' package.json | sort | tr '\n' ' ')"
have="$(grep -o '"dep-[a-z]*"' package-lock.json | sort | tr '\n' ' ')"
if [ "$want" != "$have" ]; then
  echo "npm error \`npm ci\` can only install packages when your package.json and package-lock.json are in sync."
  exit 1
fi
rm -rf deps
bash .aif/stop-here.sh prepare
mkdir -p deps
printf '%s\n' $have >deps/installed
PREP
tmp="$(mktemp)"
jq '.prepare = "bash .aif/prepare.sh"' .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
tmp="$(mktemp)"
{
  head -1 .aif/suite.sh
  printf 'bash .aif/stop-here.sh suite\n'
  tail -n +2 .aif/suite.sh
} >"$tmp" && mv "$tmp" .aif/suite.sh && chmod +x .aif/suite.sh
ticket_for AIF-27
git add -A && git commit -qm "ticket 27, a lockfile, and stand-ins that can be stopped" >/dev/null
bash .aif/prepare.sh # the developer's own install
"$AIF" board create tasks/AIF-27/ticket.md --column ready >/dev/null
rc=0
FAKE_DEPS=1 "$AIF" work AIF-27 >"$OUT/run27.out" 2>&1 || rc=$?
eq "a ticket that moves the dependencies: built, in Review" "$rc,$(col AIF-27)" "0,review"
head_before="$(git rev-parse HEAD)"
branch_sha="$(git rev-parse aif/AIF-27)"
changed() { git status --porcelain --untracked-files=no | wc -l | tr -d ' '; }

# land_bg <stop-at> <out> [land options] — aif land AIF-27 in the background,
# back once its stand-in waits at <stop-at>. Not a bare `"$AIF" land … &`: a
# job a script puts in the background starts with SIGINT ignored, and bash can
# neither trap nor reset a signal it started ignoring — the INT would reach
# nothing, and the land would finish as if it had never been sent. python3 puts
# SIGINT back as a terminal leaves it, and the land in a process group of its
# own, for a Ctrl-C to signal whole.
STOP_MARK="$SANDBOX/p27.at"
STOP_GO="$SANDBOX/p27.go"
STOP_LOG="$SANDBOX/p27.log"
land_bg() {
  local at="$1" out="$2" i=0
  shift 2
  rm -f "$STOP_MARK" "$STOP_GO" "$STOP_LOG"
  STOP_IN="$at" STOP_MARK="$STOP_MARK" STOP_GO="$STOP_GO" STOP_LOG="$STOP_LOG" python3 -c '
import os, signal, sys
os.setpgrp()
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])' "$AIF" land AIF-27 ${1+"$@"} >"$out" 2>&1 &
  LAND_PID=$!
  while [ ! -f "$STOP_MARK" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
}

# An error on the way is a stop too — here a worktree the land cannot remove,
# which failed under set -e with the merge already made. The exit keeps its
# own code. (Root removes a read-only directory anyway, so not as root.)
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p .aif/worktrees/AIF-27/build/ro && touch .aif/worktrees/AIF-27/build/ro/f
  chmod 555 .aif/worktrees/AIF-27/build/ro
  rc=0
  "$AIF" land AIF-27 >"$OUT/land27a.out" 2>&1 || rc=$?
  chmod -R u+w .aif/worktrees/AIF-27
  eq "an error after the merge: its exit 1 kept, the merge undone" "$rc,$(git rev-parse HEAD)" "1,$head_before"
  eq "…said as a stop" "$(grep -c 'stopped by the error above — the merge was undone' "$OUT/land27a.out")" "1"
  eq "…the card still in Review, the checkout clean" "$(col AIF-27),$(changed)" "review,0"
fi

# INT to the land's pid alone, during the suite: bash runs the trap once the
# suite returns, and it returns green — the stop still wins
land_bg suite "$OUT/land27b.out"
kill -INT "$LAND_PID" 2>/dev/null
touch "$STOP_GO"
rc=0
wait "$LAND_PID" || rc=$?
eq "INT to the land during the suite: exit 130, the merge undone" "$rc,$(git rev-parse HEAD)" "130,$head_before"
eq "…though the suite had come back green" \
  "$([ -f .aif/tmp/report.xml ] && grep -c '<failure' .aif/tmp/report.xml)" "0"
eq "…the card still in Review, the branch untouched" "$(col AIF-27),$(git rev-parse aif/AIF-27)" "review,$branch_sha"
eq "…the checkout clean" "$(changed)" "0"
eq "…and it said so, with the command that lands it from there" \
  "$(grep -c 'interrupted — the merge was undone' "$OUT/land27b.out"),$(grep -c 'To land it: aif land AIF-27$' "$OUT/land27b.out")" "1,1"
eq "…naming no install, as none had started" "$(grep -c 'may be partial' "$OUT/land27b.out")" "0"

# Ctrl-C during --prepare's install, as a terminal sends it: to the whole
# group, so the install dies with the land, its deps/ emptied and not filled
land_bg prepare "$OUT/land27c.out" --prepare
kill -INT -- "-$LAND_PID" 2>/dev/null
rc=0
wait "$LAND_PID" || rc=$?
eq "Ctrl-C during --prepare's install: exit 130, the merge undone" "$rc,$(git rev-parse HEAD)" "130,$head_before"
eq "…the card still in Review, the checkout clean" "$(col AIF-27),$(changed)" "review,0"
eq "…the install run once, and not again: what it emptied stays empty" \
  "$(grep -c prepare "$STOP_LOG" 2>/dev/null),$([ -e deps/installed ] && echo filled || echo empty)" "1,empty"
eq "…said to be partial, with its command" \
  "$(grep -c 'installed may be partial' "$OUT/land27c.out"),$(grep -c '^ *bash .aif/prepare.sh$' "$OUT/land27c.out")" "1,1"
eq "…and landing it again keeps --prepare" "$(grep -c 'To land it: aif land AIF-27 --prepare$' "$OUT/land27c.out")" "1"

# a supervisor's TERM, to the land's pid: the same undo, and 143
land_bg suite "$OUT/land27d.out"
kill -TERM "$LAND_PID" 2>/dev/null
touch "$STOP_GO"
rc=0
wait "$LAND_PID" || rc=$?
eq "TERM during the suite: exit 143, the merge undone, still in Review" \
  "$rc,$(git rev-parse HEAD),$(col AIF-27)" "143,$head_before,review"
eq "…said" "$(grep -c 'terminated — the merge was undone' "$OUT/land27d.out")" "1"

# a verdict is not a stop: a red land undoes its merge itself, and its own
# exit 1 does not come back through the handler as a second undo
printf '# t2 waits for impl2\n' >tests/t2.py
git add -A && git commit -qm "main grew a test after the build" >/dev/null
head_before="$(git rev-parse HEAD)"
rc=0
"$AIF" land AIF-27 >"$OUT/land27e.out" 2>&1 || rc=$?
eq "red on the result: exit 1, the merge undone, Needs Human" \
  "$rc,$(git rev-parse HEAD),$(col AIF-27)" "1,$head_before,needs_human"
eq "…a verdict, not a stop" "$(grep -c 'a stop decides nothing' "$OUT/land27e.out")" "0"

# and what every stop left is landable
git rm -q tests/t2.py
git commit -qm "main dropped the test" >/dev/null
"$AIF" board move AIF-27 review >/dev/null
rc=0
"$AIF" land AIF-27 --prepare >"$OUT/land27f.out" 2>&1 || rc=$?
eq "then it lands: exit 0, Done, as one merge commit" "$rc,$(col AIF-27),$(git log --format=%s -1)" \
  "0,done,aif: land AIF-27 — one-command user export"
eq "…installed from the lockfile it merged, the checkout clean" \
  "$(tr '\n' ' ' <deps/installed),$(changed)" '"dep-a" "dep-new" ,0'

# ----------------------------------------------------------------------------
printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'work: ok\n'
  cd / && rm -rf "$SANDBOX"
else
  printf 'work: %s failure(s) — sandbox kept at %s\n' "$fails" "$SANDBOX"
  exit 1
fi
