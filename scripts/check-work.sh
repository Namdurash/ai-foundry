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
#  35  aif project guide writes the project's guide to its own tests from
#      what the repository declares — the runner's configuration, the setup
#      files, the manual mocks and factories, the fixtures a conftest
#      defines, what the tests import most, a test to read first — keeps what
#      the human wrote outside its block when it regenerates, and goes stale
#      honestly: a cited path gone is a doctor ✗ and a refused run, naming it
#  36  the worker appends the runner fragment and the guide to the plan and
#      tests stations' prompts and not to the implementer's; says so when a
#      project records no runner or one the set has no fragment for, and
#      refuses a worktree whose branch does not carry the guide
#  37  a project.json from an older template: aif project check lists what
#      the gates now read differently (a retired failure class still counted
#      as red, a type-check bound to green alone, a cap not set, the runner
#      not recorded), aif project upgrade brings exactly that forward and
#      leaves the project's own fields alone; the worker warns at preflight
#      and runs the new stage on 16 dispatches whatever the file omits; the
#      tests station gets four rejections in a row, the others three
#  38  aif init refreshes its own hook registration event by event and keeps
#      the user's hooks beside it, records the edit so uninstall takes only
#      ours back, and a dry run previews the updates without announcing them
#      as retirements; doctor reads the guard's registration before any probe
#  42  a branch cut under an older set is brought up to the checkout's set
#      before anything reads it, in a commit of its own; a run that stopped
#      restarts on the tree it started from when the ticket or the set moved,
#      the stopped plan's leftovers put back and never committed; a resumed
#      plan station reads the repository as the branch has it
#  39  one worker per ticket on this machine: a second is refused and touches
#      nothing, --clean is refused from under a run, `aif work <ID> --stop`
#      from another terminal ends the run as its Ctrl-C would and settles the
#      card saying who, a lock whose worker is gone is taken over or settled;
#      and the loop's Ctrl-C takes no new card, while a --stop on its run in
#      flight is not counted against the cards
#  40  the loop builds several tickets at once: two by default, each in its
#      own worktree, inside a station together; the third card is taken when
#      a slot frees, none twice; the suite probe in the developer's checkout
#      runs once for the loop; one Ctrl-C lets the runs in flight finish and
#      takes no new card, a second stops them — a Ctrl-C typed at a terminal
#      too; a worker that cannot start stops the loop taking cards before a
#      second one starts
#  41  on a terminal the loop draws its dashboard: a frame from a fixture
#      keeps every line inside the terminal and every border where it belongs
#      around Cyrillic titles, in colour or not, wide, compact or ASCII; live,
#      on a pty, the keys select a worker and stop it, the card saying who,
#      and the terminal is left as it was found, the summary on it
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
# One test per marker line a declared file holds — `# <ticket> AC-nnn asserts
# <word> — expects <literal>` — NAMED with its marker, the way verify-red reads
# a criterion off a collected test's id and not off a file's text. Red until
# <word> is in src/app.py; for the word `feat`, until src/feat.py stops
# throwing the not-implemented marker (the plan's skeleton). Words after the
# dash are the harness's switches: BUG is red whatever the code does, BROKEN a
# syntax error, BADCALL a TypeError, FLAKY flips on every run.
fails() { # <id> <file> <message-attr> <message>
  printf '<testcase classname="%s" name="%s"><failure message="%s">%s\n    at %s/%s:1</failure></testcase>' "$(cn "$2")" "$1" "$3" "$4" "$PWD" "$2"
}
flip="$(cat .aif/tmp/flip 2>/dev/null || echo 0)"; flip=$((flip + 1)); printf '%s' "$flip" >.aif/tmp/flip
for n in 1 2 3; do
  [ -f "tests/t$n.py" ] || continue
  while IFS= read -r line; do
    case "$line" in "# "*AC-[0-9]*) ;; *) continue ;; esac
    id="$(printf '%s' "$line" | sed 's/^# \(\([A-Za-z0-9-]* \)\{0,1\}AC-[0-9]*\).*/\1/') t$n"
    word="$(printf '%s' "$line" | sed -n 's/.*asserts \([a-z0-9]*\).*/\1/p')"
    g=0
    if [ "$word" = feat ]; then grep -q 'not implemented' src/feat.py 2>/dev/null || g=1
    else grep -q "$word" src/app.py 2>/dev/null && g=1; fi
    case "$line" in
      *" BUG"*) body="$body$(fails "$id" "tests/t$n.py" 'wrong literal' 'AssertionError: wrong literal')" ;;
      *" BROKEN"*) body="$body$(fails "$id" "tests/t$n.py" 'invalid syntax' 'SyntaxError: invalid syntax')" ;;
      *" BADCALL"*) body="$body$(fails "$id" "tests/t$n.py" 'not a function' 'TypeError: users_v2 is not a function')" ;;
      *" FLAKY"*) body="$body$(row "$id" "tests/t$n.py" $((flip % 2)))" ;;
      *) if [ "$word" = feat ] && [ "$g" = 0 ]; then body="$body$(fails "$id" "tests/t$n.py" 'not implemented' 'NotImplementedError: aif: not implemented: feat')"
         else body="$body$(row "$id" "tests/t$n.py" "$g")"; fi ;;
    esac
  done <"tests/t$n.py"
done
printf '<testsuites><testsuite>%s</testsuite></testsuites>' "$body" > .aif/tmp/report.xml
SUITE
  chmod +x .aif/suite.sh
  local tmp
  tmp="$(mktemp)"
  jq '.test.command = "bash .aif/suite.sh"
      | .test.roots = ["tests"]
      | .test.report.path = ".aif/tmp/report.xml"' .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
  # The project's guide to its own tests, which the worker refuses to run
  # without and appends to the plan and tests stations' prompts. Written from
  # the repository, offline, and committed with the rest — the stations read
  # the branch's copy.
  "$AIF" project guide >/dev/null 2>&1 || {
    printf 'check-work: aif project guide failed — cannot continue\n'
    exit 1
  }
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
# The misbehaviours of docs/DEFECTS.md (log 6): FAKE_TYPEBUG (every attempt) and
# FAKE_TESTS_TYPEBUG_FIRST put a mistyped mock in each test, FAKE_IMPL_BADTYPE_FIRST
# a type error in the first implementation, FAKE_DRIFT has the implement
# station change an installed dependency nobody tracks, and FAKE_DEPS has the
# plan name package.json and its lockfile, the first implement attempt add a
# dependency around the lock and the retry through it. For docs/DEFECTS.md (log 7),
# FAKE_TESTS_REHOME has a retried tests station move every test into
# tests/t1.py and leave the other declared files in place as helpers. Each
# dispatch's prompt is kept as .aif/tmp/fake-prompt-<station>-<n>, so a
# scenario can read what a retry was told.
cat >"$SANDBOX/fake-station.sh" <<'FAKE'
#!/bin/bash
set -u
# A stop reaches a station as a signal to the worker's whole process group,
# and a real station — `claude -p` — dies of it at once. This stub holds a
# dispatch open with a loop of short sleeps, and bash 3.2 lets a signal that
# lands as one of those sleeps ends slip past an untrapped shell: measured, 10
# of 200 group SIGINTs left the loop running (docs/DEFECTS.md 11.1), which made
# a stop that should be prompt wait out the hold. Trapped, 0 of 200.
trap 'exit 130' INT TERM
station="$1" ticket="$2" wt="$3" prompt="$5" out="${10}"
work="$wt/tasks/$ticket"
count_file="$wt/.aif/tmp/fake-$station.count"
mkdir -p "$wt/.aif/tmp"
n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" >"$count_file"
printf '%s' "$prompt" >"$wt/.aif/tmp/fake-prompt-$station-$n"
# The system prompt too — the station's instructions, and whatever the worker
# appended after them (the runner fragment, the project's guide).
cp "$4" "$wt/.aif/tmp/fake-sys-$station-$n" 2>/dev/null
# The budget the worker handed this dispatch — empty when there is no ceiling,
# and the real runner then omits --max-budget-usd entirely.
printf '%s' "${8:-}" >"$wt/.aif/tmp/fake-budget"
# FAKE_SLEEP_IN="<ticket>:<station> …" holds those dispatches open — for
# FAKE_SLEEP_SECS (37), or until the file FAKE_RELEASE appears — a station
# still running, for a stop or a second worker to land in. Each says when it
# has started, in its worktree and, with FAKE_MARKS, in that directory too,
# where a scenario sees every worker's. FAKE_TIMELINE names a file every
# dispatch appends its start and its end to: what ran at once.
[ -z "${FAKE_TIMELINE:-}" ] || printf 'start %s %s\n' "$ticket" "$station" >>"$FAKE_TIMELINE"
for hold in ${FAKE_SLEEP_IN:-}; do
  if [ "$hold" = "$ticket:$station" ]; then
    : >"$wt/.aif/tmp/fake-running-$ticket-$station"
    [ -z "${FAKE_MARKS:-}" ] || : >"$FAKE_MARKS/$ticket-$station"
    if [ -n "${FAKE_RELEASE:-}" ]; then
      i=0
      while [ ! -f "$FAKE_RELEASE" ] && [ "$i" -lt 300 ]; do
        sleep 0.1
        i=$((i + 1))
      done
    else
      sleep "${FAKE_SLEEP_SECS:-37}"
    fi
  fi
done
retry=0; printf '%s' "$prompt" | grep -q "was REJECTED" && retry=1
repair=0; printf '%s' "$prompt" | grep -q "^REPAIR" && repair=1
# What the worker handed this dispatch: the turn cap and the tools.
printf '%s' "${7:-}" >"$wt/.aif/tmp/fake-turns-$station-$n"
printf '%s' "${9:-}" >"$wt/.aif/tmp/fake-tools-$station-$n"

# The criteria the ticket actually carries — so a reworked ticket with a new
# criterion produces a plan and a test for it, exactly as a real station would.
acs="$(sed -n '/^<!-- aif:meta$/,/^-->$/p' "$work/ticket.md" | sed '1d;$d' | jq -r '.acceptance[].id')"
nums="$(printf '%s\n' "$acs" | sed 's/AC-00//')"
tests_json="$(printf '%s\n' "$nums" | jq -R 'select(length>0) | "tests/t" + . + ".py"' | jq -sc .)"

case "$station" in
  plan)
    change='["src/app.py"]'
    [ "${FAKE_DEPS:-0}" = 1 ] && change='["src/app.py", "package.json", "package-lock.json"]'
    # A wide plan (FAKE_WIDEPLAN=N): src/w1.py … src/wN.py changed as well — a
    # manifest past the 12-file cap the plan gate no longer holds it to.
    if [ -n "${FAKE_WIDEPLAN:-}" ]; then
      change="$(jq -cn --argjson n "$FAKE_WIDEPLAN" '["src/app.py"] + [range(1; $n + 1) | "src/w\(.).py"]')"
    fi
    if [ "${FAKE_PLAN_BAD_FIRST:-0}" = 1 ] && [ "$retry" = 0 ]; then change='["src/nowhere.py"]'; fi
    # The contract: with FAKE_CREATE the plan creates src/feat.py and writes
    # its skeleton — a signature whose body throws the marker — the way the
    # plan station does; AC-001 is then served by it.
    create='[]'
    if [ "${FAKE_CREATE:-0}" = 1 ]; then
      create='["src/feat.py"]'
      printf 'def feat():\n    raise NotImplementedError("aif: not implemented: feat")\n' >"$wt/src/feat.py"
    fi
    cov="$(printf '%s\n' "$acs" | jq -R 'select(length>0)' | jq -sc --argjson c "$change" --argjson cr "$create" \
      'map({ key: ., value: (if . == "AC-001" and ($cr | length) > 0 then $cr else $c end) }) | from_entries')"
    # A verdict per criterion: buildable, unless the harness says AC-001 is
    # something else (a spec stop).
    verdicts="$(printf '%s\n' "$acs" | jq -R 'select(length>0)' | jq -sc --arg v "${FAKE_VERDICT:-buildable}" \
      'map({ key: ., value: (if . == "AC-001" and $v != "buildable" then { verdict: $v, because: "src/app.py:2 — the harness says so" } else { verdict: "buildable" } end) }) | from_entries')"
    cat >"$work/plan.md" <<PLAN
<!-- aif:meta
{ "schema": 3, "ticket": "$ticket", "risk": "low",
  "files": { "create": $create, "change": $change, "tests": $tests_json },
  "no_skeleton": [],
  "verdicts": $verdicts,
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
        suffix=""
        if [ "${FAKE_TYPEBUG:-0}" = 1 ] || { [ "${FAKE_TESTS_TYPEBUG_FIRST:-0}" = 1 ] && [ "$retry" = 0 ]; }; then
          suffix=" TYPEBUG"
        fi
        # The station's own defects, each a rejection it gets back: a test
        # that always fails (BUG — the repair loop's subject, dropped when the
        # station is dispatched to repair), one that did not load, one calling
        # a name the contract does not export, one that flips.
        if [ "${FAKE_TESTS_BUG:-0}" = 1 ] && [ "$repair" = 0 ]; then suffix="$suffix BUG"; fi
        if [ "${FAKE_TESTS_BROKEN_FIRST:-0}" = 1 ] && [ "$retry" = 0 ]; then suffix="$suffix BROKEN"; fi
        if [ "${FAKE_TESTS_BADCALL_FIRST:-0}" = 1 ] && [ "$retry" = 0 ]; then suffix="$suffix BADCALL"; fi
        # FAKE_TESTS_SEQ: one word per tests dispatch, in order — NONAME,
        # BROKEN, BADCALL or OK — so a station can be wrong three different
        # ways in a row (the convergence rule stops the SAME complaint twice)
        # and right on the fourth.
        seqword="$(printf '%s\n' ${FAKE_TESTS_SEQ:-} | sed -n "${n}p")"
        case "$seqword" in
          BROKEN) suffix="$suffix BROKEN" ;;
          BADCALL) suffix="$suffix BADCALL" ;;
        esac
        if [ "${FAKE_TESTS_FLAKY_FIRST:-0}" = 1 ] && [ "$retry" = 0 ]; then suffix="$suffix FLAKY"; fi
        word="impl$i"
        [ "${FAKE_CREATE:-0}" = 1 ] && [ "$i" = 1 ] && word="feat"
        # The marker carries the ticket — `AIF-1 AC-001` — unless the harness
        # asks for the old, unscoped spelling, which the gate refuses.
        marker="$ticket AC-00$i"
        if [ "${FAKE_TESTS_NONAME_FIRST:-0}" = 1 ] && [ "$retry" = 0 ]; then marker="AC-00$i"; fi
        [ "$seqword" != NONAME ] || marker="AC-00$i"
        printf '# %s asserts %s — expects %s%s\n' "$marker" "$word" "$exp" "$suffix" >"$wt/tests/t$i.py"
      fi
    done
    # The station's note: what it cannot write a red test for.
    if [ "${FAKE_TESTS_NOTE_UNF:-0}" = 1 ]; then
      printf '{ "unfalsifiable": [{ "id": "AC-001", "because": "no literal observation decides it" }] }\n' >"$work/tests.note.json"
    fi
    if [ "${FAKE_TESTS_NOTE_BUILT:-0}" = 1 ]; then
      printf '{ "already_built": ["AC-001"] }\n' >"$work/tests.note.json"
    fi
    # A tests station that edits the contract it was handed.
    if [ "${FAKE_SKELETON_EDIT:-0}" = 1 ]; then
      printf 'def feat():\n    return 7  # the tests station wrote the behaviour\n' >"$wt/src/feat.py"
    fi
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
    # The implementer's note: a replan (the contract cannot hold it), or a
    # claim that a frozen test is wrong.
    if [ "${FAKE_REPLAN:-0}" = 1 ] || { [ "${FAKE_REPLAN_FIRST:-0}" = 1 ] && [ "$n" = 1 ]; }; then
      printf '{ "replan": "the contract cannot hold the behaviour: users() has nowhere to put the marker" }\n' >"$work/implement.note.json"
    fi
    if [ "${FAKE_IMPL_CLAIMS:-0}" = 1 ]; then
      printf '{ "tests_wrong": [{ "test": "AC-001", "because": "it asserts the wrong literal" }] }\n' >"$work/implement.note.json"
    fi
    if [ "${FAKE_STALL:-0}" = 1 ]; then
      printf 'def users():\n    return []  # wrong\n' >"$wt/src/app.py"
    else
      body=""
      for i in $nums; do [ -n "$i" ] && body="$body impl$i"; done
      [ "${FAKE_IMPL_BADTYPE_FIRST:-0}" = 1 ] && [ "$retry" = 0 ] && body="$body BADTYPE"
      printf 'def users():\n    return []  #%s\n' "$body" >"$wt/src/app.py"
      # The skeleton, filled: the marker's throw replaced by the behaviour.
      [ "${FAKE_CREATE:-0}" != 1 ] || printf 'def feat():\n    return 7\n' >"$wt/src/feat.py"
    fi
    # A large change (FAKE_BIGDIFF=N): N more lines in a planned file — past the
    # 400-line cap scope no longer holds a change to.
    if [ -n "${FAKE_BIGDIFF:-}" ]; then
      i=0
      while [ "$i" -lt "$FAKE_BIGDIFF" ]; do
        printf '# line %s of a large change\n' "$i"
        i=$((i + 1))
      done >>"$wt/src/app.py"
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

[ -z "${FAKE_TIMELINE:-}" ] || printf 'end %s %s\n' "$ticket" "$station" >>"$FAKE_TIMELINE"
cost=0.01
[ "${FAKE_ZERO_COST:-0}" = 1 ] && cost=0
jq -n --arg st "$station" --argjson n "$n" --argjson cost "$cost" --arg prompt "$prompt" \
  '{type:"result",subtype:"success",is_error:false,result:("fake " + $st + " done\n" + $prompt),
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
# The numbers the stability figure is read from (docs/REBUILD-4.md §0).
eq "the report carries the convergence numbers" \
  "$(grep -c '^- tests: 1 declared file(s), 1 collected; 1 red at the freeze, 0 green at the freeze$' tasks/AIF-1/report.md),$(grep -c '^- loops: 0 repair(s) of the oracle, 0 replan(s)$' tasks/AIF-1/report.md)" "1,1"
# Each station's own turn cap, from its aif:meta, over the project-wide one.
eq "the plan and tests stations got their own turn caps, implement its own" \
  "$(cat .aif/tmp/fake-turns-plan-1),$(cat .aif/tmp/fake-turns-tests-1),$(cat .aif/tmp/fake-turns-implement-1)" "60,60,60"
# The tests station's Bash is for `aif _verify`, and it is granted only once
# `aif doctor --probe` has watched the guard deny a command here. It has not.
eq "the tests station ran without Bash — the guard has not been seen to deny here" \
  "$(cat .aif/tmp/fake-tools-tests-1 | tr ',' '\n' | grep -c '^Bash$')" "0"

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
eq "under the line the project manager routes on: the ticket's problem" \
  "$("$AIF" board show AIF-6 --json | jq -r '.comments[0].text' | sed -n 1p)" \
  "blocked: ticket — not ready — the ready gate's questions are below, for the analyst"
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
eq "the report says why" "$(grep -c 'rewrote nothing\|rejected .* time\|same complaint twice' tasks/AIF-5/report.md)" "1"
# The convergence rule: the same complaint twice in a row is a station that
# cannot act on it, and the third attempt it used to get was the same coin.
eq "implement was dispatched twice, not attempts_max times — the same complaint twice is a stop" \
  "$(jq '[.entries[] | select(.station == "implement")] | length' tasks/AIF-5/ledger.json)" "2"
eq "the accepted stations are committed, the failed one is not" \
  "$(git log --format=%s | grep -c '^aif: implement AIF-5')" "0"
eq "run.json status" "$(jq -r '.status' tasks/AIF-5/run.json)" "stopped"
eq "the card says whose problem stopped it — the run's — with the report under it" \
  "$("$AIF" board show AIF-5 --json | jq -r '.comments[-1].text' | sed -n 1p | grep -c '^blocked: run — implement was rejected with the same complaint twice'),$("$AIF" board show AIF-5 --json | jq -r '.comments[-1].text' | grep -c '^# AIF-5 — stopped')" "1,1"

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
  "$(jq -c '.green_at_freeze' tasks/AIF-1/tests.lock.json)" '["tests.t1::AIF-1 AC-001 t1"]'
eq "so only the new test is covering" \
  "$(jq -c '.covering' tasks/AIF-1/tests.lock.json)" '["tests.t2::AIF-1 AC-002 t2"]'
eq "and the report says the green-at-freeze test was never proven red" \
  "$(grep -c 'tests tests.t1::AIF-1 AC-001 t1' tasks/AIF-1/report.md)" "1"
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
eq "…and so does the card: the machine, with the error the worker printed" \
  "$("$AIF" board show AIF-7 --json | jq -r '.comments[-1].text' | sed -n 1p | grep -c '^blocked: environment — the worker exited (code 1) during intake; the last error it printed: the ready gate is not installed')" "1"

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
# The card is taken before the checkout is cut, so a refusal there is on the
# board, not only in the terminal of whoever ran it — and it is not left in
# Ready for the next run to take again.
eq "the card was taken, and is back with why: Needs Human, blocked: environment" \
  "$(jq -r .column .aif/board/AIF-14.json 2>/dev/null),$("$AIF" board show AIF-14 --json | jq -r '.comments[-1].text' | sed -n 1p | grep -c '^blocked: environment — the suite cannot run in the worktree')" "needs_human,1"
eq "…with the probe's own words under it" \
  "$("$AIF" board show AIF-14 --json | jq -r '.comments[-1].text' | grep -c 'wrote no report')" "1"
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
# (docs/DEFECTS.md 5.2). Only a project with none of pyproject/pytest.ini/
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
# enough to matter (docs/DEFECTS.md 5.3). The path is on the FIRST line here
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
# build, and the branch does not satisfy it. AIF-16's and AIF-17's tests both
# live in tests/t1.py and each carries its own ticket's marker, so main holds
# AIF-16's; it adopts AIF-17's first, so that this step is about the red suite
# and not about a conflict — which is the step after.
git show aif/AIF-17:tests/t1.py >tests/t1.py
printf '# MAIN-1 AC-002 asserts impl2 — expects impl2\n' >tests/t2.py
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
# (docs/DEFECTS.md 6.1). The stub below makes the pre-existing t0 fail under a
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
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | first | .result' tasks/AIF-20/ledger.json)" "pass"
# Out of the implementation's reach and the new tests' doing: not a stop any
# more but a REPAIR — the tests station is dispatched in a copy without the
# implementation, twice, and when the oracle still breaks the suite the run
# stops at limits.repairs_max rather than at a human on the first attempt.
eq "green attributed it to the oracle, as a repair" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | first | .result' tasks/AIF-20/ledger.json)" "repair"
eq "and said it is out of the implementation's reach" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | first | .reason' tasks/AIF-20/ledger.json |
     grep -c 'out of the implementation.s reach')" "1"
eq "implement was dispatched once, not attempts_max times" \
  "$(jq '[.entries[] | select(.station == "implement")] | length' tasks/AIF-20/ledger.json)" "1"
eq "the tests station was dispatched for each repair, in the copy" \
  "$(jq '[.entries[] | select(.station == "tests")] | length' tasks/AIF-20/ledger.json),$(jq -r '.repairs' tasks/AIF-20/run.json)" "3,2"
eq "and the run stopped at the repair cap, saying so" \
  "$(grep -c 'after 2 repair(s)' tasks/AIF-20/report.md)" "1"
eq "the report says the new tests break it, and not to reinstall" \
  "$(grep -q 'the new tests' tasks/AIF-20/report.md && echo yes),$(grep -c 'Run "prepare"' tasks/AIF-20/report.md)" "yes,0"
eq "and its first line no longer blames the environment" \
  "$(grep -c 'that is the environment, not the artifact' tasks/AIF-20/report.md)" "0"

# ====== 21. a check's failure carries its location, and is attributed ========
#
# The project's typecheck is a check, and a check's complaint used to be its
# LAST line: for tsc, "Source has 0 element(s) but target requires 1." — no
# file, no line. And a type error inside a frozen test file sent the implement
# station round three times at something it may not edit (docs/DEFECTS.md (log 6)
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
eq "a type error frozen into a test, repaired twice to the same type error: stopped" "$rc" "1"
# A check failing in a frozen test file the same way without the code is the
# oracle's: a REPAIR, not a stop. This station mistypes the mock on every
# attempt, so the repair cap is what stops it — at the cap, not at a human on
# the first attempt.
eq "green attributed it to the frozen tests, as a repair" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | first | .result' tasks/AIF-21/ledger.json)" "repair"
eq "…and says the failure is the frozen tests'" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | first | .reason' tasks/AIF-21/ledger.json |
     grep -c 'fails in the frozen tests, not in the implementation')" "1"
eq "implement was dispatched once, not attempts_max times" \
  "$(jq '[.entries[] | select(.station == "implement")] | length' tasks/AIF-21/ledger.json)" "1"
eq "the tests station was dispatched twice more, in the copy" \
  "$(jq '[.entries[] | select(.station == "tests")] | length' tasks/AIF-21/ledger.json)" "3"
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
# three times (docs/DEFECTS.md 6.3). Here the drift is a file in a gitignored
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
# undone, a ticket with nothing wrong in it in Needs Human (docs/DEFECTS.md (log 6)
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
printf '# MAIN-1 AC-002 asserts impl2 — expects impl2\n' >tests/t2.py
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
# test lived there was checked by nothing (docs/DEFECTS.md 7.1). The stub
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
  "$(grep -c 'AC-002 is named only in a file the runner collected no test from: tests/t2.py' .aif/tmp/fake-prompt-tests-2)" "1"
eq "…and that a test in that file runs nowhere" \
  "$(grep -c 'the runner collected no test from: tests/t2.py — a test there runs neither' .aif/tmp/fake-prompt-tests-2)" "1"
eq "the file stayed declared, as a helper, and is frozen with the rest" \
  "$(jq -r '.tests | has("tests/t2.py")' tasks/AIF-26/tests.lock.json)" "true"
eq "the covering tests are the ones the runner collects, both now in t1" \
  "$(jq -c '.covering' tasks/AIF-26/tests.lock.json)" '["tests.t1::AIF-26 AC-001 t1","tests.t1::AIF-26 AC-002 t1"]'

# By hand, on the tree before the implementation: the helper passes and is
# named on the way through, and the first attempt's files are exit 1.
printf 'def users():\n    return []\n' >src/app.py
rc=0
/bin/bash .aif/gates/verify-red.sh "$PWD/tasks/AIF-26" >"$OUT/red26.out" 2>&1 || rc=$?
eq "a declared helper with no test in it passes" "$rc" "0"
eq "…and is named on the pass path" \
  "$(grep -c '! the runner collected no test from: tests/t2.py' "$OUT/red26.out")" "1"
printf '# AIF-26 AC-001 asserts impl1 — expects -1\n' >tests/t1.py
printf '# AIF-26 AC-002 asserts impl2 — expects impl2\n' >tests/t2.py
rc=0
/bin/bash .aif/gates/verify-red.sh "$PWD/tasks/AIF-26" >"$OUT/red26b.out" 2>&1 || rc=$?
eq "the first attempt's files: exit 1, a rejection" "$rc" "1"
eq "…of coverage" "$(sed -n 1p "$OUT/red26b.out")" "REJECT coverage: 2 problem(s)"

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
printf '# MAIN-1 AC-002 asserts impl2 — expects impl2\n' >tests/t2.py
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

# ====== 28. the contract: the plan writes the skeleton the tests are red against
#
# A test file importing a module that does not exist yet fails to load, and
# jest-junit drops the whole file from the report: on the batch of 2026-09-29,
# 24 new tests were never seen by any gate that way (docs/FINDINGS.md #22). So
# the plan station writes every new module as a SKELETON — the real exports,
# bodies that throw "aif: not implemented" — and the tests are red against
# something that loads. Here the plan creates src/feat.py, AC-001's test calls
# it, and the stub reports the marker until the implementation replaces it.
printf '\n28. the contract: a skeleton on disk, red against it, the skeleton restored for the recheck\n'
fresh_project "$SANDBOX/p28"
ticket_for AIF-28
git add -A && git commit -qm "ticket 28" >/dev/null
rc=0
FAKE_CREATE=1 "$AIF" work AIF-28 --no-worktree >"$OUT/run28.out" 2>&1 || rc=$?
eq "a ticket that creates a module: built" "$rc" "0"
plan_commit="$(git log --format='%H %s' | awk '/aif: plan AIF-28/ { print $1; exit }')"
eq "the plan's commit carries the skeleton, throwing the marker" \
  "$(git show "$plan_commit:src/feat.py" | grep -c 'aif: not implemented: feat')" "1"
eq "the plan gate counted it" \
  "$(jq -r '[.entries[] | select(.gate == "plan")] | last | .reason' tasks/AIF-28/ledger.json | grep -c '1 skeleton(s)')" "1"
eq "verify-red saw the test red for the marker, twice" \
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | last | .reason' tasks/AIF-28/ledger.json)" \
  "verify-red: 1 new test(s) red for the right reason, twice, all criteria covered"
eq "the freeze holds the skeleton's hash, and creates nothing" \
  "$(jq -r '(.impl_frozen | has("src/feat.py") | tostring) + "," + (.impl_created | length | tostring)' tasks/AIF-28/tests.lock.json)" "true,0"
eq "green's recheck put the skeleton back and the test went red again" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | last | .reason' tasks/AIF-28/ledger.json | grep -c 'depend on the implementation')" "1"
eq "the branch has the behaviour" "$(grep -c 'return 7' src/feat.py)" "1"

# A tests station that edits the contract it was handed is sent back, before
# the freeze: the skeleton is the plan's, measured against the plan's commit.
fresh_project "$SANDBOX/p28b"
ticket_for AIF-28
git add -A && git commit -qm "ticket 28b" >/dev/null
rc=0
FAKE_CREATE=1 FAKE_SKELETON_EDIT=1 "$AIF" work AIF-28 --no-worktree >"$OUT/run28b.out" 2>&1 || rc=$?
eq "a tests station that wrote the behaviour into the skeleton: stopped" "$rc" "1"
eq "verify-red rejected it, every time, naming the skeleton" \
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | map(.result) | join(",")' tasks/AIF-28/ledger.json)" "fail,fail"
eq "…with the reason" \
  "$(grep -c 'the test station changed the skeleton src/feat.py' .aif/tmp/fake-prompt-tests-2)" "1"
eq "…and the convergence rule stopped it at the second identical complaint" \
  "$(grep -c 'same complaint twice' tasks/AIF-28/report.md)" "1"

# ====== 29. spec stops: the ticket's problem, found first and cheaply ==========
#
# The plan station is the first thing that reads the criteria against the real
# code, so "already true" is found there — one dispatch, nothing frozen, and
# the analyst gets the plan's reason (docs/REBUILD-4.md §2.1). The tests
# station's note is the second place: a criterion it cannot falsify, or every
# criterion already built, by its own account, confirmed green by the gate.
printf '\n29. a spec stop: the ticket, not the artifact, at the first station that can tell\n'
fresh_project "$SANDBOX/p29"
ticket_for AIF-29
git add -A && git commit -qm "ticket 29" >/dev/null
rc=0
FAKE_VERDICT=already_true "$AIF" work AIF-29 --no-worktree >"$OUT/run29.out" 2>&1 || rc=$?
eq "a criterion the plan finds already true: exit 1, for a human" "$rc" "1"
eq "the run's status is spec" "$(jq -r '.status' tasks/AIF-29/run.json)" "spec"
eq "the plan gate recorded a spec verdict" \
  "$(jq -r '[.entries[] | select(.gate == "plan")] | last | .result' tasks/AIF-29/ledger.json)" "spec"
eq "with the plan's reason, for the analyst" \
  "$(grep -c 'AC-001 is already_true: src/app.py:2' tasks/AIF-29/report.md)" "1"
eq "one dispatch, and the tests station never ran" \
  "$(jq '[.entries[] | select(.station != null)] | length' tasks/AIF-29/ledger.json)" "1"
eq "nothing was frozen" "$(test -f tasks/AIF-29/tests.lock.json && echo yes || echo no)" "no"
eq "the card went to Needs Human" "$(jq -r '.column' .aif/board/AIF-29.json)" "needs_human"
eq "the report is headed as a spec stop" "$(head -1 tasks/AIF-29/report.md)" "# AIF-29 — spec"

fresh_project "$SANDBOX/p29b"
ticket_for AIF-29
git add -A && git commit -qm "ticket 29b" >/dev/null
rc=0
FAKE_TESTS_NOTE_UNF=1 "$AIF" work AIF-29 --no-worktree >"$OUT/run29b.out" 2>&1 || rc=$?
eq "a criterion the tests station cannot falsify: a spec stop" "$rc,$(jq -r '.status' tasks/AIF-29/run.json)" "1,spec"
eq "verify-red recorded it as spec, with the station's reason" \
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | last | .result' tasks/AIF-29/ledger.json),$(grep -c 'AC-001 cannot be falsified: no literal observation decides it' tasks/AIF-29/report.md)" "spec,1"
eq "the tests station was dispatched once" \
  "$(jq '[.entries[] | select(.station == "tests")] | length' tasks/AIF-29/ledger.json)" "1"

# Every criterion already built, said in the note and confirmed green: the
# ticket is done, which is the human's to say — not three attempts at red.
fresh_project "$SANDBOX/p29c"
printf 'def users():\n    return []  # impl1\n' >src/app.py
ticket_for AIF-29
git add -A && git commit -qm "ticket 29c, already built" >/dev/null
rc=0
FAKE_TESTS_NOTE_BUILT=1 "$AIF" work AIF-29 --no-worktree >"$OUT/run29c.out" 2>&1 || rc=$?
eq "every criterion already built, by the station's account: a spec stop" "$rc,$(jq -r '.status' tasks/AIF-29/run.json)" "1,spec"
eq "…saying so" "$(grep -c 'every criterion is already built' tasks/AIF-29/report.md)" "1"
eq "…after one tests dispatch, not attempts_max" \
  "$(jq '[.entries[] | select(.station == "tests")] | length' tasks/AIF-29/ledger.json)" "1"
# Without the note, the same tree is the old rejection: nothing red remains.
fresh_project "$SANDBOX/p29d"
printf 'def users():\n    return []  # impl1\n' >src/app.py
ticket_for AIF-29
git add -A && git commit -qm "ticket 29d, already built, unsaid" >/dev/null
rc=0
"$AIF" work AIF-29 --no-worktree >"$OUT/run29d.out" 2>&1 || rc=$?
eq "unsaid, it is a rejection the station gets back, and the convergence rule stops it" \
  "$rc,$(jq -r '[.entries[] | select(.gate == "verify-red")] | last | .result' tasks/AIF-29/ledger.json)" "1,fail"
eq "…naming the note as the way to say it" \
  "$(grep -c 'tests.note.json, already_built' .aif/tmp/fake-prompt-tests-2)" "1"

# ====== 30. the tests station's own defects come back to it, not to a human ====
#
# A test that did not load used to be a stop at the first attempt — "verify-red
# cannot certify a broken oracle". It cannot; but the author is still there,
# and a rejection with the runner's message is what it needs. The same for a
# test failing in a way that is neither an assertion nor the skeleton's marker
# (it calls a name the contract does not export), a marker not in the test's
# own name, and a test that flips between two runs.
printf '\n30. a broken, mis-calling, unnamed or flaky test is a rejection, with the reason\n'
red_rejection() { # <label> <env> <reason-grep>
  local dir="$SANDBOX/p30-$1" rc=0
  fresh_project "$dir"
  ticket_for AIF-30
  git add -A && git commit -qm "ticket 30 $1" >/dev/null
  env "$2=1" "$AIF" work AIF-30 --no-worktree >"$OUT/run30-$1.out" 2>&1 || rc=$?
  eq "$1: sent back, then built" "$rc" "0"
  eq "$1: verify-red rejected then admitted" \
    "$(jq -r '[.entries[] | select(.gate == "verify-red") | .result] | join(",")' tasks/AIF-30/ledger.json)" "fail,pass"
  eq "$1: the retry was told why" "$(grep -c "$3" .aif/tmp/fake-prompt-tests-2)" "1"
}
red_rejection broken FAKE_TESTS_BROKEN_FIRST 'did not run — it is broken, not red: .*SyntaxError: invalid syntax'
red_rejection badcall FAKE_TESTS_BADCALL_FIRST 'neither an assertion nor the missing implementation: .*TypeError: users_v2 is not a function'
red_rejection unnamed FAKE_TESTS_NONAME_FIRST 'AC-001 is carried by no collected test — put "AIF-30 AC-001" in the name'
red_rejection flaky FAKE_TESTS_FLAKY_FIRST 'is non-deterministic'

# And the station's own loop: `aif _verify` is the same gate, dry. Red tests on
# the tree before the implementation pass it and nothing is frozen; a file
# the station broke is told so, with exit 1.
cd "$SANDBOX/p30-broken" || exit 1
printf 'def users():\n    return []\n' >src/app.py
rm -f tasks/AIF-30/tests.lock.json
rc=0
"$AIF" _verify AIF-30 >"$OUT/verify30.out" 2>&1 || rc=$?
eq "aif _verify on red tests: exit 0, the verdict, nothing frozen" \
  "$rc,$(grep -c 'verify-red (dry): 1 new test(s) red for the right reason' "$OUT/verify30.out"),$(test -f tasks/AIF-30/tests.lock.json && echo frozen || echo none)" "0,1,none"
eq "…and it said it froze nothing" "$(grep -c 'nothing frozen' "$OUT/verify30.out")" "1"
printf '# AIF-30 AC-001 asserts impl1 — expects -1 BROKEN\n' >tests/t1.py
rc=0
"$AIF" _verify AIF-30 >"$OUT/verify30b.out" 2>&1 || rc=$?
eq "aif _verify on a broken test: exit 1, the complaint" "$rc,$(grep -c 'it is broken, not red' "$OUT/verify30b.out")" "1,1"
eq "no checks record was left for the real gate to fold" "$(test -f .aif/tmp/checks-red.json && echo left || echo none)" "none"

# ====== 31. the repair loop: a frozen test the implementer declares wrong =======
#
# A red-first test is red without the code by design, so green cannot tell a
# wrong frozen test from wrong code by measurement. What the implementer may do
# is SAY so, in its note, naming the test. green then hands the claim to the
# tests station — dispatched in a copy of the tree with the implementation
# reverted to the skeleton, so it cannot read the code — which amends the test
# or keeps it; the amended oracle must be red there and comes back here, and
# the implementation is judged again without a dispatch (docs/REBUILD-4.md §2.3).
printf '\n31. the repair loop: the oracle is repaired without the implementation in view\n'
fresh_project "$SANDBOX/p31"
ticket_for AIF-31
git add -A && git commit -qm "ticket 31" >/dev/null
rc=0
FAKE_TESTS_BUG=1 FAKE_IMPL_CLAIMS=1 "$AIF" work AIF-31 --no-worktree >"$OUT/run31.out" 2>&1 || rc=$?
eq "a wrong frozen test, claimed and repaired: built" "$rc" "0"
eq "green said repair, then passed" \
  "$(jq -r '[.entries[] | select(.gate == "green") | .result] | join(",")' tasks/AIF-31/ledger.json)" "repair,pass"
eq "the tests station was dispatched twice: the freeze, and the repair" \
  "$(jq '[.entries[] | select(.station == "tests")] | length' tasks/AIF-31/ledger.json)" "2"
eq "implement was dispatched once — judged again, not run again" \
  "$(jq '[.entries[] | select(.station == "implement")] | length' tasks/AIF-31/ledger.json)" "1"
# The repair ran in the copy, so its prompt file went with the copy; the
# envelope the worker kept carries the prompt (the fake runner puts it there).
eq "the repair dispatch was told it was one, with the claim, and its envelope was kept as the fourth" \
  "$(jq -r '.result' tasks/AIF-31/stations/04-tests.json | grep -c '^REPAIR'),$(jq -r '.result' tasks/AIF-31/stations/04-tests.json | grep -c 'it asserts the wrong literal')" "1,1"
eq "the repaired oracle was admitted in the copy, red against the skeleton" \
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | last | .reason' tasks/AIF-31/ledger.json | grep -c '^repair 1: verify-red: 1 new test(s) red')" "1"
repair_commit="$(git log --format='%H %s' | awk '/aif: tests AIF-31 \(repair 1\)/ { print $1; exit }')"
eq "the repair commit holds the oracle and not the implementation" \
  "$(git show "$repair_commit:tests/t1.py" | grep -c BUG),$(git show "$repair_commit:src/app.py" | grep -c impl1)" "0,0"
eq "the run record counts it" "$(jq -r '.repairs' tasks/AIF-31/run.json)" "1"
eq "and the report does too" "$(grep -c '^- loops: 1 repair(s) of the oracle, 0 replan(s)$' tasks/AIF-31/report.md)" "1"
eq "the branch is clean, with the implementation committed at the end" \
  "$(git status --porcelain | wc -l | tr -d ' '),$(git show HEAD~1:src/app.py | grep -c impl1)" "0,1"

# Unclaimed, a failing frozen test is the implementation's: rejected, retried,
# and the convergence rule stops the second identical complaint.
fresh_project "$SANDBOX/p31b"
ticket_for AIF-31
git add -A && git commit -qm "ticket 31b" >/dev/null
rc=0
FAKE_TESTS_BUG=1 "$AIF" work AIF-31 --no-worktree >"$OUT/run31b.out" 2>&1 || rc=$?
eq "unclaimed: rejected, and stopped on the same complaint twice" \
  "$rc,$(jq -r '[.entries[] | select(.gate == "green") | .result] | join(",")' tasks/AIF-31/ledger.json)" "1,fail,fail"
eq "…without a repair" "$(jq -r '.repairs' tasks/AIF-31/run.json)" "0"

# ====== 32. the replan loop: the contract cannot hold the behaviour ============
#
# The implementer's other declaration. The tree goes back to what the plan
# station first saw — skeleton, tests, lock and plan gone — and the plan
# station runs again with the declaration in front of it. One per ticket.
printf '\n32. the replan loop: the plan station again, with the implementer'"'"'s declaration\n'
fresh_project "$SANDBOX/p32"
ticket_for AIF-32
git add -A && git commit -qm "ticket 32" >/dev/null
rc=0
FAKE_CREATE=1 FAKE_REPLAN_FIRST=1 "$AIF" work AIF-32 --no-worktree >"$OUT/run32.out" 2>&1 || rc=$?
eq "a contract declared unable to hold it, replanned once: built" "$rc" "0"
eq "every station ran twice" \
  "$(jq -r '[.entries[] | select(.station != null) | .station] | join(",")' tasks/AIF-32/ledger.json)" "plan,tests,implement,plan,tests,implement"
eq "the replan is in the ledger" \
  "$(jq -r '[.entries[] | select(.gate == "replan")] | last | .result' tasks/AIF-32/ledger.json)" "pass"
eq "the second plan dispatch was told it was a replan, with the words" \
  "$(grep -c '^REPLAN' .aif/tmp/fake-prompt-plan-2),$(grep -c 'nowhere to put the marker' .aif/tmp/fake-prompt-plan-2)" "1,1"
eq "the run record counts it, and the report" \
  "$(jq -r '.replans' tasks/AIF-32/run.json),$(grep -c '^- loops: 0 repair(s) of the oracle, 1 replan(s)$' tasks/AIF-32/report.md)" "1,1"
eq "the first attempt's note did not survive into the second plan's tree" \
  "$(git log --format=%s | grep -c '^aif: plan AIF-32')" "2"
eq "the branch is clean" "$(git status --porcelain | wc -l | tr -d ' ')" "0"

fresh_project "$SANDBOX/p32b"
ticket_for AIF-32
git add -A && git commit -qm "ticket 32b" >/dev/null
rc=0
FAKE_REPLAN=1 "$AIF" work AIF-32 --no-worktree >"$OUT/run32b.out" 2>&1 || rc=$?
eq "declared twice: stopped at the replan cap" "$rc,$(jq -r '.status' tasks/AIF-32/run.json)" "1,stopped"
eq "…saying so" "$(grep -q 'after 1 replan(s)' tasks/AIF-32/report.md && echo yes)" "yes"
eq "…with the replan recorded as refused" \
  "$(jq -r '[.entries[] | select(.gate == "replan") | .result] | join(",")' tasks/AIF-32/ledger.json)" "pass,fail"

# ====== 33. the tests station's Bash, once the guard has been seen to deny ======
# Granted only once `aif doctor --probe` has watched the hook deny a command in
# a spawned run on this machine, and remembered per runner version. The
# scripted runner stands in for that run here; the marker is what the worker
# reads.
printf '\n33. the tests station gets Bash only once the guard has been seen to deny\n'
fresh_project "$SANDBOX/p33"
mkdir -p .aif/state && printf 'probed\n' >.aif/state/guard-probed
ticket_for AIF-33
git add -A && git commit -qm "ticket 33" >/dev/null
rc=0
"$AIF" work AIF-33 --no-worktree >"$OUT/run33.out" 2>&1 || rc=$?
eq "built" "$rc" "0"
eq "the tests station was handed Bash, for aif _verify" \
  "$(tr ',' '\n' <.aif/tmp/fake-tools-tests-1 | grep -c '^Bash$')" "1"
eq "the implement station always had it" \
  "$(tr ',' '\n' <.aif/tmp/fake-tools-implement-1 | grep -c '^Bash$')" "1"
eq "doctor reports the capability from the marker" \
  "$("$AIF" doctor --json 2>/dev/null | jq -r '.capabilities["station-guard"].ok')" "true"

# ====== 34. aif project init writes the type-check the project already has ====
# Bound to contract, red and green, without a question: the plan's skeleton,
# the tests and the code are all held to the project's own compiler. Only
# what the project declares — a tsconfig and typescript installed, or a
# typecheck script; a project with neither gets nothing.
printf '\n34. project init binds the project'"'"'s own type-check to every phase\n'
mkdir -p "$SANDBOX/p34" && cd "$SANDBOX/p34" || exit 1
git init -q && git config user.email p@aif && git config user.name P
printf '{ "name": "p34", "devDependencies": { "jest": "29", "typescript": "5" } }\n' >package.json
printf '{}\n' >tsconfig.json
"$AIF" init anthropic >/dev/null 2>&1
rc=0
"$AIF" project init </dev/null >"$OUT/init34.out" 2>&1 || rc=$?
eq "detected jest, and recorded the kind" "$rc,$(jq -r '.test.kind' .aif/project.json)" "0,jest"
eq "typecheck bound to contract, red and green" \
  "$(jq -c '[.checks[] | select(.name == "typecheck") | .command, (.phase | join(","))]' .aif/project.json)" '["npx tsc --noEmit","contract,red,green"]'
eq "…said so" "$(grep -c 'typecheck.*bound to contract, red and green' "$OUT/init34.out")" "1"
eq "a contract phase validates" "$("$AIF" project check >/dev/null 2>&1; echo $?)" "0"
rm -f .aif/project.json
"$AIF" project init --no-checks >/dev/null 2>&1
eq "--no-checks writes none, as it says" "$(jq '.checks | length' .aif/project.json)" "0"

# ====== 35. aif project guide: the project's guide to its own tests ===========
#
# Scenarios 35 and 36 are one function: the guide is markdown, every
# assertion greps a backticked path out of it, and one directive covers them
# all here where a directive per line would bury the assertions.
# shellcheck disable=SC2016  # the backticks are markdown code spans, not substitution
knowledge_layer_scenarios() {
#
# Written from what the repository declares, never from what a model remembers
# (docs/REBUILD-4.md §6): the runner's configuration lines, the setup files it
# names, the manual mocks and the factories, the fixtures a conftest defines,
# the modules and packages the tests import most, a test to read first for
# each. The block between the markers is regenerated in place; the section
# the human writes is kept. Every path in backticks is checked, and a guide
# naming a path that is gone is a ✗ in doctor and a refused run.
printf '\n35. aif project guide writes the guide from the repository, keeps what the human wrote, and goes stale honestly\n'
mkdir -p "$SANDBOX/p35" && cd "$SANDBOX/p35" || exit 1
git init -q && git config user.email p@aif && git config user.name P
mkdir -p src/__mocks__ test/helpers test/factories test/api
printf '{ "name": "p35", "devDependencies": { "jest": "29", "typescript": "5", "supertest": "6", "nock": "13" } }\n' >package.json
printf '{ "compilerOptions": { "strict": true, "noUnusedParameters": true } }\n' >tsconfig.json
cat >jest.config.js <<'J'
module.exports = {
  testMatch: ['**/*.test.ts', '**/*.spec.ts'],
  setupFilesAfterEach: ['<rootDir>/test/setup.ts'],
  moduleNameMapper: { '\\.svg$': '<rootDir>/test/svgMock.js' },
};
J
printf 'export {};\n' >test/setup.ts
printf 'module.exports = {};\n' >test/svgMock.js
printf 'export const axios = {};\n' >src/__mocks__/axios.ts
printf 'export const db = () => ({});\n' >test/helpers/db.ts
printf 'export const makeUser = () => ({ id: 1 });\n' >test/factories/user.ts
printf 'export const users = () => [];\n' >src/users.ts
cat >src/users.test.ts <<'T'
import { users } from './users';
import { db } from '../test/helpers/db';
import request from 'supertest';
it('lists', () => { expect(users()).toEqual([]); });
T
cat >test/api/users.test.ts <<'T'
import { db } from '../helpers/db';
import { makeUser } from '../factories/user';
import request from 'supertest';
it('x', () => {});
T
cat >test/api/orders.spec.ts <<'T'
import { db } from '../helpers/db';
import nock from 'nock';
it('y', () => {});
T
git add -A && git commit -qm init >/dev/null
"$AIF" init anthropic >/dev/null 2>&1
"$AIF" project init jest --no-checks >/dev/null 2>&1
tmp="$(mktemp)"
jq '.test.roots = ["test"]' .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
G=.aif/guide/tests.md
rc=0
"$AIF" project guide >"$OUT/guide35.out" 2>&1 || rc=$?
eq "written, and every path it cites exists" "$rc,$(test -f $G && echo yes),$(grep -c 'all exist' "$OUT/guide35.out")" "0,yes,1"
eq "the configuration lines that select the tests, with their line numbers" "$(grep -c "^2:  testMatch: \['\*\*/\*.test.ts', '\*\*/\*.spec.ts'\]," $G)" "1"
eq "the setup file the runner loads, read out of the config" "$(grep -c '^- `test/setup.ts` — a setup file the runner loads' $G)" "1"
eq "the manual mocks, by the module each one mocks" "$(grep -c '^- `src/__mocks__/` — jest manual mocks for: axios$' $G)" "1"
eq "the factories and the helpers directories" "$(grep -c '^- `test/factories/` — 1 file(s)$' $G),$(grep -c '^- `test/helpers/` — 1 file(s)$' $G)" "1,1"
eq "the roots, with the tests under them and the files that are not tests" "$(grep -c '^- `test/` (test.roots) — 2 test file(s), 4 other file(s)' $G)" "1"
eq "a test beside its source is counted outside the roots, by directory" "$(grep -c '^- 1 test file(s) outside test.roots' $G),$(grep -c '^  - `src/` — 1$' $G)" "1,1"
eq "the helper the tests import most, counted by distinct test file" "$(grep -c '^- `test/helpers/db.ts` — 3$' $G)" "1"
eq "the packages, counted the same way and never in backticks" "$(grep -c '^- supertest — 2$' $G),$(grep -c '^- nock — 1$' $G),$(grep -c '`supertest`' $G)" "1,1,0"
eq "a test to read first, the shortest one using the top helper" "$(grep -c '^- `test/api/orders.spec.ts` — uses `test/helpers/db.ts`$' $G)" "1"
eq "the tsconfig flags a skeleton has to satisfy" "$(grep -c 'on here: strict, noUnusedParameters' $G),$(grep -c 'a skeleton `void`s each parameter' $G)" "1,1"
eq "the runner fragment the stations get is named, and installed" "$(grep -c '^- the runner fragment the stations get before this guide: `.aif/stacks/jest.md`$' $G),$(test -f .aif/stacks/jest.md && echo yes)" "1,yes"
eq "the human's section is left as a placeholder, and the output says what to do next" "$(grep -c '^_Not written yet\.' $G),$(grep -c 'How this project mocks its boundaries' "$OUT/guide35.out")" "1,1"

# The human writes the boundaries section; the repository moves; the guide is
# regenerated — the block follows the repository, the section stays.
awk '/^_Not written yet\./ {
  print "- HTTP: never real — nock in the test; see `test/api/orders.spec.ts`"
  print "- the database: `test/helpers/db.ts` opens an in-memory one per test"
  next } { print }' $G >"$G.new" && mv "$G.new" $G
printf 'export const makeOrder = () => ({});\n' >test/factories/order.ts
rc=0
"$AIF" project guide >"$OUT/guide35b.out" 2>&1 || rc=$?
eq "regenerated: the block follows the repository" "$rc,$(grep -c '^- `test/factories/` — 2 file(s)$' $G),$(grep -c '^regenerated' "$OUT/guide35b.out")" "0,1,1"
eq "…and what the human wrote outside it is kept, the placeholder gone" "$(grep -c 'opens an in-memory one per test' $G),$(grep -c '^_Not written yet\.' $G)" "1,0"
eq "…with exactly one pair of markers" "$(grep -c 'aif:guide:begin' $G),$(grep -c 'aif:guide:end' $G)" "1,1"
git add -A && git commit -qm "the guide" >/dev/null
eq "doctor: test-guide is ready — committed, every path present" \
  "$("$AIF" doctor --json 2>/dev/null | jq -r '.capabilities["test-guide"].ok')" "true"
eq "…and the worker requires it" \
  "$("$AIF" doctor --json 2>/dev/null | jq -r '.roles[] | select(.role == "worker") | .requires | index("test-guide") != null')" "true"

# Stale: a path the guide cites is gone from the repository.
git rm -q test/helpers/db.ts && git commit -qm "the helper moved" >/dev/null
eq "doctor: a cited path gone is ✗, and named" \
  "$("$AIF" doctor --json 2>/dev/null | jq -r '.capabilities["test-guide"] | (.ok | tostring) + " " + .detail' | grep -c '^false .*test/helpers/db.ts')" "1"
rc=0
"$AIF" work AIF-35 --no-worktree >"$OUT/run35.out" 2>&1 || rc=$?
eq "aif work refuses a stale guide — exit 3, nothing spent, the path named" \
  "$rc,$(grep -c 'test/helpers/db.ts' "$OUT/run35.out"),$(test -d tasks/AIF-35 && echo yes || echo no)" "3,1,no"
rm -f $G
rc=0
"$AIF" work AIF-35 --no-worktree >"$OUT/run35b.out" 2>&1 || rc=$?
eq "…and refuses without one, naming the command" "$rc,$(grep -c 'aif project guide' "$OUT/run35b.out")" "3,1"
eq "doctor: no guide is ✗ with the command" \
  "$("$AIF" doctor --json 2>/dev/null | jq -r '.capabilities["test-guide"] | (.ok | tostring) + " " + .detail' | grep -c '^false no .aif/guide/tests.md .*aif project guide')" "1"
if command -v claude >/dev/null 2>&1; then
  eq "…and doctor's next step is the command" "$("$AIF" doctor 2>/dev/null | grep -c '^next: .*aif project guide')" "1"
fi

# A pytest-shaped repository: the ini_options section, the fixtures a conftest
# defines, imports resolved through pythonpath and through a relative import.
mkdir -p "$SANDBOX/p35py" && cd "$SANDBOX/p35py" || exit 1
git init -q && git config user.email p@aif && git config user.name P
mkdir -p src/app tests/api tests/factories
cat >pyproject.toml <<'P'
[project]
name = "p35"

[tool.pytest.ini_options]
testpaths = ["tests"]
pythonpath = ["src"]
python_files = ["test_*.py"]
P
: >src/app/__init__.py
printf 'def users():\n    return []\n' >src/app/users.py
cat >tests/conftest.py <<'C'
import pytest


@pytest.fixture
def db():
    return {}


@pytest.fixture(scope="session")
def client(db):
    return db
C
printf 'def make_user():\n    return {}\n' >tests/factories/__init__.py
cat >tests/test_users.py <<'T'
import responses
from freezegun import freeze_time
from app.users import users
from tests.factories import make_user


def test_lists(db):
    assert users() == []
T
cat >tests/api/test_orders.py <<'T'
import pytest
from ..factories import make_user


def test_x():
    pass
T
git add -A && git commit -qm init >/dev/null
"$AIF" init anthropic >/dev/null 2>&1
"$AIF" project init pytest --no-checks >/dev/null 2>&1
"$AIF" project guide >/dev/null 2>&1
eq "pytest: the runner as recorded, and the ini_options section shown" "$(grep -c '^- \*\*pytest\*\* (test.kind' $G),$(grep -c '^pythonpath = \["src"\]$' $G)" "1,1"
eq "pytest: the fixtures a conftest defines, by name" "$(grep -c '^- `tests/conftest.py` — fixtures: db, client$' $G)" "1"
eq "pytest: an absolute import resolved through pythonpath" "$(grep -c '^- `src/app/users.py` — 1$' $G)" "1"
eq "pytest: a relative and an absolute import of one module count as one" "$(grep -c '^- `tests/factories/__init__.py` — 2$' $G)" "1"
eq "pytest: the test-side packages" "$(grep -c '^- responses — 1$' $G),$(grep -c '^- freezegun — 1$' $G),$(grep -c '^- pytest — 1$' $G)" "1,1,1"
eq "pytest: named as the runner collects them" "$(grep -c '^- named: test_\*.py 2, \*_test.py 0$' $G)" "1"
eq "pytest: the roots" "$(grep -c '^- `tests/` (test.roots) — 2 test file(s), 2 other file(s)' $G)" "1"

# ====== 36. the knowledge layer reaches the stations that need it =============
#
# The runner fragment the set ships for the project's kind, then the guide,
# appended to the plan and tests stations' system prompts after their own
# instructions — not to the implementer's. A project that records no runner,
# or one the set has no fragment for, is told so in the prompt and in the run;
# a guide the branch does not carry refuses the worktree.
printf '\n36. the worker appends the runner fragment and the guide to the plan and tests stations\n'
fresh_project "$SANDBOX/p36"
ticket_for AIF-36
git add -A && git commit -qm "ticket 36" >/dev/null
rc=0
"$AIF" work AIF-36 --no-worktree >"$OUT/run36.out" 2>&1 || rc=$?
eq "built" "$rc" "0"
eq "the plan station got the pytest fragment, then the guide" \
  "$(grep -c '^# pytest — what the gates see' .aif/tmp/fake-sys-plan-1),$(grep -c 'aif:guide:begin' .aif/tmp/fake-sys-plan-1)" "1,1"
eq "…after its own instructions, in that order" \
  "$(awk '/^You are the planning station/ { a = NR } /^# pytest — what the gates see/ { b = NR } /aif:guide:begin/ { c = NR } END { print (a > 0 && b > a && c > b) ? "yes" : "no" }' .aif/tmp/fake-sys-plan-1)" "yes"
eq "the tests station got both too" \
  "$(grep -c '^# pytest — what the gates see' .aif/tmp/fake-sys-tests-1),$(grep -c 'aif:guide:begin' .aif/tmp/fake-sys-tests-1)" "1,1"
eq "the implementer got neither" "$(grep -c 'what the gates see\|aif:guide:begin' .aif/tmp/fake-sys-implement-1)" "0"
eq "the run said which stack each of the two was handed" "$(grep -c '· stack pytest + guide$' "$OUT/run36.out")" "2"
eq "the guide in the prompt is the branch's: it names this project's roots" "$(grep -c '^- `tests/` (test.roots)' .aif/tmp/fake-sys-tests-1)" "1"

# No test.kind, and a command that names neither runner: no fragment, said.
fresh_project "$SANDBOX/p36b"
tmp="$(mktemp)"
jq 'del(.test.kind)' .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
git add -A && git commit -qm "no kind" >/dev/null
ticket_for AIF-36
git add -A && git commit -qm "ticket 36b" >/dev/null
rc=0
"$AIF" work AIF-36 --no-worktree >"$OUT/run36b.out" 2>&1 || rc=$?
eq "no test.kind: built all the same" "$rc" "0"
eq "…the station told there is no fragment, and handed the guide" \
  "$(grep -c 'records no test.kind' .aif/tmp/fake-sys-plan-1),$(grep -c 'aif:guide:begin' .aif/tmp/fake-sys-plan-1)" "1,1"
eq "…and the run said so, for the two stations" "$(grep -c 'no runner fragment — project.json records no test.kind' "$OUT/run36b.out")" "2"
eq "doctor's stack line says the same" "$("$AIF" doctor 2>/dev/null | grep -c 'stack .*no test.kind')" "1"

# A runner the set ships no fragment for.
fresh_project "$SANDBOX/p36c"
tmp="$(mktemp)"
jq '.test.kind = "go"' .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
git add -A && git commit -qm "go" >/dev/null
ticket_for AIF-36
git add -A && git commit -qm "ticket 36c" >/dev/null
rc=0
"$AIF" work AIF-36 --no-worktree >"$OUT/run36c.out" 2>&1 || rc=$?
eq "an unknown runner: built, the station told no fragment ships for it" \
  "$rc,$(grep -c 'No runner fragment ships for "go"' .aif/tmp/fake-sys-tests-1)" "0,1"
eq "…and the run said so" "$(grep -c "no runner fragment for 'go'" "$OUT/run36c.out")" "2"

# A guide written and never committed: the branch is brought up to the
# checkout's set before a run and lands back into it afterwards, so a file git
# does not track here is refused at preflight — before the card is taken — with
# the one remedy that fits (docs/DEFECTS.md 9.1 moved the misreading of a
# branch older than the guide out of this check).
fresh_project "$SANDBOX/p36d"
git rm -q --cached .aif/guide/tests.md && git commit -qm "the guide, uncommitted" >/dev/null
ticket_for AIF-36
git add -A tasks && git commit -qm "ticket 36d" >/dev/null
rc=0
"$AIF" work AIF-36 >"$OUT/run36d.out" 2>&1 || rc=$?
eq "an uncommitted guide is refused at preflight — exit 3, saying to commit it" \
  "$rc,$(grep -c 'is not committed in your checkout' "$OUT/run36d.out"),$(grep -c 'git add .aif/guide/tests.md' "$OUT/run36d.out")" "3,1,1"
eq "nothing was spent, and the card was never taken" \
  "$(test -f .aif/board/AIF-36.json && jq -r .column .aif/board/AIF-36.json || echo none),$(test -d .aif/worktrees/AIF-36 && echo cut || echo none)" "none,none"
eq "doctor said it first" "$("$AIF" doctor --json 2>/dev/null | jq -r '.capabilities["test-guide"] | (.ok | tostring) + " " + .detail' | grep -c '^false .*not committed')" "1"
}
knowledge_layer_scenarios

# ====== 37. a project.json behind its template =================================
#
# .aif/project.json is the project's and aif init never rewrites it — which
# left an upgraded project telling verify-red that a TypeError is a legitimate
# red, its type-check bound to green alone, and the new stage running on the
# old dispatch cap, in silence (docs/DEFECTS.md 8.1, #4). What moved is now
# said by check, doctor and the worker, and `aif project upgrade` brings
# exactly that forward.
printf '\n37. a project.json from an older template is reported, upgraded, and run on the caps the stage was designed for\n'
mkdir -p "$SANDBOX/p37" && cd "$SANDBOX/p37" || exit 1
git init -q && git config user.email p@aif && git config user.name P
mkdir -p src tests && printf 'def users():\n    return []\n' >src/app.py && printf '# t0\n' >tests/t0.py
git add -A && git commit -qm init >/dev/null
"$AIF" init anthropic >/dev/null 2>&1
"$AIF" project init pytest --no-checks >/dev/null 2>&1
tmp="$(mktemp)"
# As 0.10.x wrote it: no kind, the retired classes as legitimate, no loop
# caps, the type-check on green only; the project's own answers beside them.
jq 'del(.test.kind) | del(.failure_classes.retired)
    | .failure_classes.legitimate = ["AssertionError", "ModuleNotFoundError", "ImportError", "AttributeError", "NameError", "TypeError"]
    | del(.limits.run_dispatches_max) | del(.limits.repairs_max) | del(.limits.replans_max)
    | .test.roots = ["tests", "spec"] | .test.command = "python3 -m pytest -q --junitxml=.aif/tmp/report.xml -p no:cacheprovider"
    | .checks = [ { name: "typecheck", command: "mypy src", phase: ["green"], required: true },
                  { name: "lint", command: "ruff check .", phase: ["green"], required: true } ]' \
  .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
rc=0
"$AIF" project check >"$OUT/check37.out" 2>&1 || rc=$?
eq "check: valid, and what moved is listed" "$rc,$(grep -c 'thing(s) have moved' "$OUT/check37.out")" "0,1"
eq "…a retired class still counted as red, by name" "$(grep -c 'still counts "TypeError" as a legitimate red' "$OUT/check37.out"),$(grep -c 'still counts "ImportError"' "$OUT/check37.out")" "1,1"
eq "…a template class the file lacks" "$(grep -c 'lacks "aif: not implemented"' "$OUT/check37.out")" "1"
eq "…the type-check bound to green alone" "$(grep -c 'check "typecheck" is a type-check bound to \[green\]' "$OUT/check37.out")" "1"
eq "…a cap the file does not set, with the template value" "$(grep -c 'limits.run_dispatches_max is not set — the pytest template puts it at 16' "$OUT/check37.out")" "1"
eq "…the runner not recorded, inferred from the command" "$(grep -c 'test.kind is not recorded' "$OUT/check37.out")" "1"
eq "…and the remedy" "$(grep -c '^aif project upgrade brings these forward' "$OUT/check37.out")" "1"
eq "doctor: project.json is valid but behind its template" "$("$AIF" doctor 2>/dev/null | grep -c 'project.json .*behind its template')" "1"
if command -v claude >/dev/null 2>&1; then
  eq "…and its next step is the upgrade" "$("$AIF" doctor 2>/dev/null | grep -c '^next: .*aif project upgrade')" "1"
fi
rc=0
"$AIF" project upgrade >"$OUT/upgrade37.out" 2>&1 || rc=$?
eq "upgrade: brought forward" "$rc,$(grep -c '^upgraded' "$OUT/upgrade37.out")" "0,1"
eq "the runner is recorded" "$(jq -r '.test.kind' .aif/project.json)" "pytest"
eq "the failure classes are those of the template, the retired ones gone" \
  "$(jq -c '.failure_classes.legitimate' .aif/project.json)" '["AssertionError","assert ","NotImplementedError","aif: not implemented"]'
eq "…said so" "$(grep -c 'retired: ModuleNotFoundError, ImportError, AttributeError, NameError, TypeError' "$OUT/upgrade37.out")" "1"
eq "the caps the stage was designed for are set" \
  "$(jq -c '[.limits.run_dispatches_max, .limits.repairs_max, .limits.replans_max, .limits.attempts_max]' .aif/project.json)" "[16,2,1,3]"
eq "the type-check is bound to contract, red and green; lint as it was" \
  "$(jq -c '[.checks[] | [.name, (.phase | join(","))]]' .aif/project.json)" '[["typecheck","contract,red,green"],["lint","green"]]'
eq "its own answers are as they were" \
  "$(jq -c '[.test.roots, .test.command, .checks[0].command]' .aif/project.json)" '[["tests","spec"],"python3 -m pytest -q --junitxml=.aif/tmp/report.xml -p no:cacheprovider","mypy src"]'
eq "check is quiet now, and a second upgrade has nothing to do" \
  "$("$AIF" project check 2>/dev/null | grep -c 'current with the pytest template'),$("$AIF" project upgrade 2>/dev/null | grep -c 'nothing to bring forward')" "1,1"
eq "a project.json kept by hand with a class of its own keeps it" \
  "$(tmp="$(mktemp)"; jq '.failure_classes.legitimate += ["MyProjectError"]' .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json; "$AIF" project upgrade >/dev/null 2>&1; jq -r '.failure_classes.legitimate | index("MyProjectError") != null' .aif/project.json)" "true"

# The worker: a file that omits the cap runs the new stage on 16, and says the
# file is behind its template, once, before anything is spent.
fresh_project "$SANDBOX/p37b"
tmp="$(mktemp)"
jq 'del(.limits.run_dispatches_max)' .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
git add -A && git commit -qm "no cap" >/dev/null
ticket_for AIF-37
git add -A && git commit -qm "ticket 37" >/dev/null
rc=0
"$AIF" work AIF-37 --no-worktree >"$OUT/run37.out" 2>&1 || rc=$?
eq "built, on 16 dispatches" "$rc,$(grep -c '≤16 dispatches' "$OUT/run37.out")" "0,1"
eq "…and warned that project.json is behind its template" "$(grep -c 'project.json is behind its template — 1 thing(s) moved' "$OUT/run37.out")" "1"

# The tests station gets four rejections in a row (max_attempts in its
# aif:meta); three different complaints, then a good fourth.
fresh_project "$SANDBOX/p37c"
ticket_for AIF-37
git add -A && git commit -qm "ticket 37c" >/dev/null
rc=0
FAKE_TESTS_SEQ="NONAME BROKEN BADCALL OK" "$AIF" work AIF-37 --no-worktree >"$OUT/run37c.out" 2>&1 || rc=$?
eq "three rejections, then built on the fourth attempt" "$rc,$(jq -r '[.entries[] | select(.gate == "verify-red") | .result] | join(",")' tasks/AIF-37/ledger.json)" "0,fail,fail,fail,pass"
eq "the tests station was dispatched four times" "$(jq '[.entries[] | select(.station == "tests")] | length' tasks/AIF-37/ledger.json)" "4"
eq "…each retry told the attempt it was, of four" "$(grep -c 'tests rejected (attempt 3/4)' "$OUT/run37c.out")" "1"
eq "the plan station declares no cap of its own, so it is held to three" \
  "$(sed -n '/^<!-- aif:meta$/,/^-->$/p' .claude/agents/aif-plan.md | sed '1d;$d' | jq -r '.max_attempts // "none"')" "none"

# ====== 38. aif init refreshes its own hooks, keeps the user's, previews honestly
#
# A project initialised before 0.5.3 kept a guard matcher without Bash through
# every later init, because init skipped any event the file already had and
# could not tell the user's hooks from its own (docs/DEFECTS.md 8.2); and a
# dry run announced every updated file as retired (#5).
printf '\n38. aif init refreshes its own hook registration, keeps the user'"'"'s, and a dry run previews honestly\n'
mkdir -p "$SANDBOX/p38" && cd "$SANDBOX/p38" || exit 1
git init -q && git config user.email p@aif && git config user.name P
mkdir -p src tests .claude && printf 'def users():\n    return []\n' >src/app.py && printf '# t0\n' >tests/t0.py
cat >.claude/settings.json <<'J'
{ "hooks": {
    "PreToolUse": [
      { "matcher": "Write|Edit|MultiEdit|NotebookEdit",
        "hooks": [ { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.aif/hooks/guard.sh" } ] },
      { "matcher": "Write", "hooks": [ { "type": "command", "command": "./my-hook.sh" } ] } ],
    "Stop": [ { "hooks": [ { "type": "command", "command": "./bye.sh" } ] } ] } }
J
git add -A && git commit -qm init >/dev/null
rc=0
"$AIF" init anthropic >"$OUT/init38.out" 2>&1 || rc=$?
eq "init: the stale registration is refreshed, the matcher it had named" \
  "$rc,$(grep -c 'refresh .*hooks.PreToolUse' "$OUT/init38.out"),$(grep -c 'ours was registered for "Write|Edit|MultiEdit|NotebookEdit"' "$OUT/init38.out")" "0,1,1"
eq "…the metering hook registered, the user hook kept and said" \
  "$(grep -c 'register .*hooks.SubagentStop' "$OUT/init38.out"),$(grep -c 'kept your own 1 hook(s) on PreToolUse' "$OUT/init38.out")" "1,1"
eq "…and no warning calls the user hooks ours, or ours theirs" "$(grep -c 'you already have' "$OUT/init38.out")" "0"
eq "the guard now matches Bash" \
  "$(jq -r '[.hooks.PreToolUse[] | select(.hooks[0].command | contains(".aif/hooks/guard.sh")) | .matcher] | .[0]' .claude/settings.json)" "Write|Edit|MultiEdit|NotebookEdit|Bash"
eq "the user PreToolUse and Stop hooks are untouched" \
  "$(jq -c '[.hooks.PreToolUse[] | select(.hooks[0].command == "./my-hook.sh") | .matcher], (.hooks.Stop | length)' .claude/settings.json | paste -sd, -)" '["Write"],1'
eq "the edit is in the manifest, so uninstall can take ours back" \
  "$(jq -r '[.edits[] | select(.path == ".claude/settings.json") | .kind] | .[0]' .aif/manifest.json)" "json_merge"
rc=0
"$AIF" init anthropic >"$OUT/init38b.out" 2>&1 || rc=$?
eq "a second init has nothing to refresh" "$rc,$(grep -c 'refresh\|register' "$OUT/init38b.out")" "0,0"
eq "doctor reads the registration: Bash present, so the probe decides" \
  "$(AIF_WORK_STATION_CMD='' "$AIF" doctor --json 2>/dev/null | jq -r '.capabilities["station-guard"].ok')" "null"
# Without Bash in the matcher, doctor says so before any probe.
tmp="$(mktemp)"
jq '(.hooks.PreToolUse[] | select(.hooks[0].command | contains("guard.sh")) | .matcher) = "Write|Edit"' .claude/settings.json >"$tmp" && mv "$tmp" .claude/settings.json
eq "…and a matcher without Bash is ✗ with the remedy, probe or not" \
  "$(AIF_WORK_STATION_CMD='' "$AIF" doctor --json 2>/dev/null | jq -r '.capabilities["station-guard"] | (.ok | tostring) + " " + .detail' | grep -c '^false .*without Bash .*aif init refreshes')" "1"
eq "…shown in the text output too" "$(AIF_WORK_STATION_CMD='' "$AIF" doctor 2>/dev/null | grep -c '✗ station-guard .*without Bash')" "1"
"$AIF" init anthropic >/dev/null 2>&1
eq "init puts Bash back" \
  "$(jq -r '[.hooks.PreToolUse[] | select(.hooks[0].command | contains("guard.sh")) | .matcher] | .[0]' .claude/settings.json)" "Write|Edit|MultiEdit|NotebookEdit|Bash"

# A dry run of an upgrade: an updated file is previewed as an update, once,
# and never as a retirement. The update is staged by moving one installed
# file and its recorded hash together, which is what a newer set looks like.
printf '\n# a newer set\n' >>.claude/agents/aif-plan.md
tmp="$(mktemp)"
jq --arg h "$(shasum -a 256 .claude/agents/aif-plan.md | cut -d' ' -f1)" \
  '(.files[] | select(.path == ".claude/agents/aif-plan.md") | .sha256) = $h' .aif/manifest.json >"$tmp" && mv "$tmp" .aif/manifest.json
rc=0
"$AIF" init anthropic --dry-run >"$OUT/dry38.out" 2>&1 || rc=$?
eq "dry run: the update is previewed, and nothing is retired" \
  "$rc,$(grep -c '^  update .*aif-plan.md' "$OUT/dry38.out"),$(grep -c 'retire' "$OUT/dry38.out")" "0,1,0"
eq "…and the summary agrees with the real run" \
  "$(grep -o '[0-9]* updated' "$OUT/dry38.out"),$("$AIF" init anthropic 2>&1 | grep -o '[0-9]* updated')" "1 updated,1 updated"

# Uninstall takes back ours and only ours.
"$AIF" uninstall >/dev/null 2>&1
eq "uninstall: our hooks gone, the user hooks kept" \
  "$(jq -c '[.hooks.PreToolUse[] | .hooks[0].command], (.hooks.Stop | length), (.hooks | has("SubagentStop"))' .claude/settings.json | paste -sd, -)" '["./my-hook.sh"],1,false'

# ====== 39. one worker per ticket, a stop from anywhere, a card that says why ==
# The lock: nothing used to stop a second `aif work` on a ticket already being
# built — it reused the worktree and resumed the same run record. The stop:
# `aif work <ID> --stop` from another terminal ends the run the way its own
# Ctrl-C would, by TERM — a worker a script or a loop started in the
# background cannot be reached by an INT (docs/FINDINGS.md #23). And the
# loop's Ctrl-C: the run in flight settled its card and exited, bash saw its
# child handle the signal and went on, and the loop took the next card.
printf '\n39. one worker per ticket, a stop from anywhere, and a card that always says why\n'
fresh_project "$SANDBOX/p39"
wait_for() { # <file> — up to ten seconds
  local i=0
  while [ ! -f "$1" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
}
wait_said() { # <file> <text> — until the text is in the file, up to ten seconds
  local i=0
  while ! grep -q -- "$2" "$1" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
}
# ctrl_c_twice <loop-pid> <out> — as a person does it: the second once the loop
# has said what the first meant, and off the loop's one-second tick. Sent
# exactly a second after the first, the second landed where the tick's sleep
# ends and the shell is between commands, and bash 3.2 lost it about one time
# in three (docs/DEFECTS.md 11.1) — a race in the loop's shell this harness
# must not be the thing that hits.
ctrl_c_twice() {
  kill -INT -- "-$1" 2>/dev/null
  wait_said "$2" "Ctrl-C — no new card"
  sleep 0.4
  kill -INT -- "-$1" 2>/dev/null
}
ticket_for AIF-39
git add -A && git commit -qm "ticket 39" >/dev/null
"$AIF" board create tasks/AIF-39/ticket.md --column ready >/dev/null

# A worker on AIF-39, its plan station still running.
FAKE_SLEEP_IN="AIF-39:plan" "$AIF" work AIF-39 --no-worktree >"$OUT/run39a.out" 2>&1 &
w1=$!
wait_for .aif/tmp/fake-running-AIF-39-plan
eq "the card is taken first, and the run lock names the worker" \
  "$(col AIF-39),$(jq -r .pid .aif/state/runs/AIF-39/owner.json 2>/dev/null)" "in_progress,$w1"

rc=0
"$AIF" work AIF-39 --no-worktree >"$OUT/run39b.out" 2>&1 || rc=$?
eq "a second worker on the same ticket: refused, exit 3, naming the first" \
  "$rc,$(grep -c "AIF-39 is being built by another worker on this machine (pid $w1" "$OUT/run39b.out")" "3,1"
eq "…and the first is still at it, its card untouched" \
  "$(kill -0 "$w1" 2>/dev/null && echo alive),$(col AIF-39)" "alive,in_progress"
rc=0
"$AIF" work AIF-39 --clean >"$OUT/run39c.out" 2>&1 || rc=$?
eq "--clean from under a live run is refused" \
  "$rc,$(grep -c 'stop it first: aif work AIF-39 --stop' "$OUT/run39c.out")" "1,1"

# The stop, from another terminal — in seconds, not after the station: a TERM
# to the worker alone would wait out the 37 seconds its station sleeps.
t0="$(date +%s)"
rc=0
"$AIF" work AIF-39 --stop >"$OUT/run39d.out" 2>&1 || rc=$?
secs=$(($(date +%s) - t0))
rc1=0
wait "$w1" || rc1=$?
eq "--stop: the worker exits 143 at once, and the stop says where the card went" \
  "$rc,$rc1,$(grep -c 'stopped AIF-39 — the card is in needs_human' "$OUT/run39d.out"),$([ "$secs" -lt 15 ] && echo prompt || echo "${secs}s")" "0,143,1,prompt"
eq "…the card says who stopped it, and during which stage" \
  "$(col AIF-39),$(last_comment AIF-39 | sed -n 1p)" "needs_human,blocked: stopped — by Work (aif work AIF-39 --stop), during plan"
eq "…the station it was running is gone, not orphaned" \
  "$(pgrep -f 'fake-station.sh plan AIF-39' | wc -l | tr -d ' ')" "0"
eq "…and the run lock is released" "$(test -d .aif/state/runs/AIF-39 && echo held || echo released)" "released"
"$AIF" board move AIF-39 ready >/dev/null
rc=0
"$AIF" work AIF-39 --no-worktree >"$OUT/run39e.out" 2>&1 || rc=$?
eq "back in Ready, it resumes where it was stopped and builds" \
  "$rc,$(grep -c 'resume ' "$OUT/run39e.out"),$(col AIF-39)" "0,1,review"

# A worker killed outright — kill -9, a closed laptop — leaves its lock and its
# card. --stop settles the card; a new run takes the lock over. A project of
# its own: these runs build in place, and AIF-39's build is in that tree now.
fresh_project "$SANDBOX/p39b"
ticket_for AIF-40
git add -A && git commit -qm "ticket 40" >/dev/null
"$AIF" board create tasks/AIF-40/ticket.md --column ready >/dev/null
sleep 0 &
dead=$!
wait "$dead" 2>/dev/null || true
mkdir -p .aif/state/runs/AIF-40
printf '{ "ticket": "AIF-40", "pid": %s, "started_at": "2026-10-02T00:00:00Z" }\n' "$dead" >.aif/state/runs/AIF-40/owner.json
"$AIF" board move AIF-40 in_progress >/dev/null
rc=0
"$AIF" work AIF-40 --stop >"$OUT/run39f.out" 2>&1 || rc=$?
eq "--stop on a worker that is gone settles its card from here, and removes the lock" \
  "$rc,$(col AIF-40),$(last_comment AIF-40 | sed -n 1p | grep -c "^blocked: stopped — by Work (aif work AIF-40 --stop): the worker that took it (pid $dead) was already gone"),$(test -d .aif/state/runs/AIF-40 && echo held || echo released)" \
  "0,needs_human,1,released"
mkdir -p .aif/state/runs/AIF-40
printf '{ "ticket": "AIF-40", "pid": %s, "started_at": "2026-10-02T00:00:00Z" }\n' "$dead" >.aif/state/runs/AIF-40/owner.json
"$AIF" board move AIF-40 ready >/dev/null
rc=0
"$AIF" work AIF-40 --no-worktree >"$OUT/run39g.out" 2>&1 || rc=$?
eq "a lock whose worker is gone is taken over, and the run builds" \
  "$rc,$(grep -c "the worker that held it (pid $dead) is gone; taken over" "$OUT/run39g.out"),$(col AIF-40)" "0,1,review"
rc=0
"$AIF" work AIF-40 --stop >"$OUT/run39k.out" 2>&1 || rc=$?
eq "--stop with nothing running is refused, touching nothing" \
  "$rc,$(grep -c 'no worker on this machine is building AIF-40' "$OUT/run39k.out"),$(col AIF-40)" "1,1,review"

# The loop and Ctrl-C, as a terminal sends it: to the loop's process group.
# Each worker runs in a group of its own, so the first Ctrl-C reaches the
# loop alone — no new card, the run in flight finishes — and the second is
# the loop's to forward. Worktrees and one at a time here: the in-place runs
# above would leave each other's code in the tree.
fresh_project "$SANDBOX/p39c"
for t in AIF-41 AIF-42 AIF-43 AIF-44; do
  ticket_for "$t"
done
git add -A && git commit -qm "four more" >/dev/null
for t in AIF-41 AIF-42 AIF-43 AIF-44; do
  "$AIF" board create "tasks/$t/ticket.md" --column ready >/dev/null
done
launch() { # <out> [loop options…] — a loop as a terminal starts one
  local out="$1"
  shift
  python3 -c '
import os, signal, sys
os.setpgrp()
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])' "$AIF" work --loop ${1+"$@"} >"$out" 2>&1 &
  loop=$!
}

FAKE_SLEEP_IN="AIF-41:plan" FAKE_SLEEP_SECS=3 launch "$OUT/run39h.out" --parallel 1
wait_for .aif/worktrees/AIF-41/.aif/tmp/fake-running-AIF-41-plan
kill -INT -- "-$loop" 2>/dev/null
rc=0
wait "$loop" || rc=$?
eq "one Ctrl-C: no new card, and the run in flight finishes and builds — exit 130" \
  "$rc,$(col AIF-41),$(col AIF-42)" "130,review,ready"
eq "…the loop said what it does with a Ctrl-C, and why it stopped" \
  "$(grep -c 'Ctrl-C — no new card; the runs in flight finish on their own. Ctrl-C again stops them.' "$OUT/run39h.out"),$(grep -c 'stopped by Ctrl-C — no new card taken' "$OUT/run39h.out")" "1,1"

FAKE_SLEEP_IN="AIF-42:plan" launch "$OUT/run39i.out" --parallel 1
wait_for .aif/worktrees/AIF-42/.aif/tmp/fake-running-AIF-42-plan
t0="$(date +%s)"
ctrl_c_twice "$loop" "$OUT/run39i.out"
rc=0
wait "$loop" || rc=$?
secs=$(($(date +%s) - t0))
eq "Ctrl-C twice: the run in flight is stopped at once, and no new card taken — exit 130" \
  "$rc,$(col AIF-42),$(col AIF-43),$([ "$secs" -lt 15 ] && echo prompt || echo "${secs}s")" "130,needs_human,ready,prompt"
eq "…the card says Ctrl-C stopped it" "$(last_comment AIF-42 | sed -n 1p)" "blocked: stopped — by Ctrl-C, during plan"

# --stop on the loop's run in flight stops that run only; the loop goes on.
FAKE_SLEEP_IN="AIF-43:plan" "$AIF" work --loop --parallel 1 >"$OUT/run39j.out" 2>&1 &
loop=$!
wait_for .aif/worktrees/AIF-43/.aif/tmp/fake-running-AIF-43-plan
"$AIF" work AIF-43 --stop >/dev/null 2>&1 || true
rc=0
wait "$loop" || rc=$?
eq "--stop on the loop's run in flight: that card to Needs Human, the next one built" \
  "$rc,$(col AIF-43),$(col AIF-44)" "1,needs_human,review"
eq "…and not counted against the cards" \
  "$(grep -c 'AIF-43 was stopped (exit 143) — not counted against the cards; the loop goes on' "$OUT/run39j.out")" "1"

# ====== 40. the loop builds several tickets at once ============================
# N workers = N worktrees (docs/REBUILD-3.md §3). Two at a time unless told,
# started one after another — each once the last one's worktree is ready — so
# that installs and probes do not run side by side and a machine that cannot
# run the suite costs one card, not two. The suite probe in the developer's
# checkout is the loop's, once. The runs are proven concurrent rather than
# timed: each holds its plan station open until the scenario has seen both
# inside, and only then lets them go.
printf '\n40. the loop builds several tickets at once\n'
fresh_project "$SANDBOX/p40"
p40="$(pwd -P)"
# Every run of the suite says where it ran, and keeps the suite's own exit.
tmp="$(mktemp)"
jq --arg log "$SANDBOX/p40-suite-runs" \
  '.test.command = "bash .aif/suite.sh; s=$?; pwd -P >>" + ($log | @sh) + "; (exit $s)"' \
  .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
for t in AIF-50 AIF-51 AIF-52 AIF-53 AIF-54 AIF-55 AIF-56 AIF-57 AIF-58 AIF-59 AIF-60 AIF-61 AIF-62 AIF-63; do
  ticket_for "$t"
done
git add -A && git commit -qm "the suite says where it ran; fourteen tickets" >/dev/null
for t in AIF-50 AIF-51 AIF-52; do
  "$AIF" board create "tasks/$t/ticket.md" --column ready >/dev/null
done
marks="$SANDBOX/p40-marks"
mkdir -p "$marks"
: >"$SANDBOX/p40-suite-runs"

FAKE_SLEEP_IN="AIF-50:plan AIF-51:plan" FAKE_MARKS="$marks" FAKE_RELEASE="$marks/go-a" \
  FAKE_TIMELINE="$SANDBOX/p40-timeline" "$AIF" work --loop >"$OUT/run40a.out" 2>&1 &
loop=$!
wait_for "$marks/AIF-50-plan"
wait_for "$marks/AIF-51-plan"
eq "two at once by default: both inside their plan station together, the third not taken" \
  "$([ -f "$marks/AIF-50-plan" ] && [ -f "$marks/AIF-51-plan" ] && echo both),$(col AIF-52)" "both,ready"
: >"$marks/go-a"
rc=0
wait "$loop" || rc=$?
eq "…then all three built, and the loop ended on an empty Ready — exit 0" \
  "$rc,$(col AIF-50),$(col AIF-51),$(col AIF-52),$(grep -c '^loop 3 taken, 3 built — Ready is empty' "$OUT/run40a.out")" \
  "0,review,review,review,1"
eq "…the third taken only when a run had ended and freed its slot" \
  "$(awk '/^end AIF-5[01] implement/ && !e { e = NR } /^start AIF-52 plan/ && !s { s = NR } END { print (e > 0 && s > e) }' "$SANDBOX/p40-timeline")" "1"
eq "…each card taken once, each on its own branch" \
  "$(grep -c '^loop [0-9] — AIF-5[012] ' "$OUT/run40a.out"),$(git branch --list 'aif/AIF-5[012]' | wc -l | tr -d ' ')" "3,3"
eq "…the suite probed in this checkout once, for the loop — not once per worker" \
  "$(grep -cx "$p40" "$SANDBOX/p40-suite-runs")" "1"
eq "…each worker's output in its own log, and the summary says how to land each" \
  "$(grep -c '^# AIF-51 — built' .aif/tmp/loop-*/AIF-51.log),$(grep -c 'AIF-52 · [0-9]* min · built → Review · aif land AIF-52' "$OUT/run40a.out")" "1,1"

# Ctrl-C with two in flight: both finish, nothing new is taken.
for t in AIF-53 AIF-54 AIF-55; do
  "$AIF" board create "tasks/$t/ticket.md" --column ready >/dev/null
done
FAKE_SLEEP_IN="AIF-53:plan AIF-54:plan" FAKE_MARKS="$marks" FAKE_RELEASE="$marks/go-b" launch "$OUT/run40b.out"
wait_for "$marks/AIF-53-plan"
wait_for "$marks/AIF-54-plan"
kill -INT -- "-$loop" 2>/dev/null
sleep 1
: >"$marks/go-b"
rc=0
wait "$loop" || rc=$?
eq "one Ctrl-C with two in flight: both finish and build, the third is not taken — exit 130" \
  "$rc,$(col AIF-53),$(col AIF-54),$(col AIF-55)" "130,review,review,ready"

# The same Ctrl-C typed at a terminal, which sends it to the process group it
# has in the foreground. Were job control left on after the spawn, bash would
# hand the terminal to every command the loop runs in the foreground — the
# tick's sleep, a jq — and the Ctrl-C would end that command and never reach
# the loop, which would go on taking cards (docs/FINDINGS.md #24).
"$AIF" board move AIF-55 backlog >/dev/null
for t in AIF-61 AIF-62 AIF-63; do
  "$AIF" board create "tasks/$t/ticket.md" --column ready >/dev/null
done
rc="$(FAKE_SLEEP_IN="AIF-61:plan AIF-62:plan" FAKE_MARKS="$marks" FAKE_RELEASE="$marks/go-g" \
  python3 - "$OUT/run40g.out" "$marks/AIF-61-plan" "$marks/AIF-62-plan" "$marks/go-g" "$AIF" <<'PY3'
import os, pty, re, select, sys, time
out, m1, m2, release, aif = sys.argv[1:6]
pid, fd = pty.fork()
if pid == 0:
    os.execv(aif, [aif, "work", "--loop"])
buf = b""
def pump(secs):
    global buf
    end = time.time() + secs
    while time.time() < end:
        if select.select([fd], [], [], 0.1)[0]:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                return False
            if not chunk:
                return False
            buf += chunk
    return True
deadline = time.time() + 30
while not (os.path.exists(m1) and os.path.exists(m2)) and time.time() < deadline:
    pump(0.1)
os.write(fd, b"\x03")
pump(1.5)
open(release, "w").close()
while pump(1):
    pass
_, status = os.waitpid(pid, 0)
open(out, "w").write(re.sub(r"\x1b\[[0-9;]*m", "", buf.decode(errors="replace")).replace("\r", ""))
print(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status))
PY3
)"
eq "a Ctrl-C typed at a terminal reaches the loop: both runs finish, the third is not taken — exit 130" \
  "$rc,$(col AIF-61),$(col AIF-62),$(col AIF-63)" "130,review,review,ready"

# Ctrl-C twice with two in flight: both stopped, each card saying so.
"$AIF" board move AIF-63 backlog >/dev/null
for t in AIF-56 AIF-57; do
  "$AIF" board create "tasks/$t/ticket.md" --column ready >/dev/null
done
FAKE_SLEEP_IN="AIF-56:plan AIF-57:plan" FAKE_MARKS="$marks" FAKE_RELEASE="$marks/never" launch "$OUT/run40c.out"
wait_for "$marks/AIF-56-plan"
wait_for "$marks/AIF-57-plan"
"$AIF" board create tasks/AIF-58/ticket.md --column ready >/dev/null
t0="$(date +%s)"
ctrl_c_twice "$loop" "$OUT/run40c.out"
rc=0
wait "$loop" || rc=$?
secs=$(($(date +%s) - t0))
eq "Ctrl-C twice with two in flight: both stopped at once, the next card not taken — exit 130" \
  "$rc,$(col AIF-56),$(col AIF-57),$(col AIF-58),$([ "$secs" -lt 15 ] && echo prompt || echo "${secs}s")" \
  "130,needs_human,needs_human,ready,prompt"
eq "…each card saying Ctrl-C stopped it" \
  "$(last_comment AIF-56 | sed -n 1p)|$(last_comment AIF-57 | sed -n 1p)" \
  "blocked: stopped — by Ctrl-C, during plan|blocked: stopped — by Ctrl-C, during plan"

# A machine that cannot run a ticket: the first worker finds it, the second
# never starts.
"$AIF" board move AIF-58 backlog >/dev/null
for t in AIF-59 AIF-60; do
  "$AIF" board create "tasks/$t/ticket.md" --column ready >/dev/null
done
tmp="$(mktemp)"
jq '.prepare = "exit 7"' .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
rc=0
"$AIF" work --loop >"$OUT/run40d.out" 2>&1 || rc=$?
eq "a worker that cannot start: its card to Needs Human, the next never started — exit 3" \
  "$rc,$(col AIF-59),$(col AIF-60)" "3,needs_human,ready"
eq "…and the loop said why it took no new card" \
  "$(grep -c 'AIF-59 could not start (exit 3) — the environment, not the card; the loop takes no new card' "$OUT/run40d.out")" "1"
git checkout -- .aif/project.json

rc=0
"$AIF" work --loop --parallel 2 --no-worktree >"$OUT/run40e.out" 2>&1 || rc=$?
eq "--parallel 2 with --no-worktree is refused: one checkout cannot hold two runs" \
  "$rc,$(grep -c 'needs a worktree per ticket' "$OUT/run40e.out")" "1,1"
rc=0
"$AIF" work AIF-60 --parallel 2 >"$OUT/run40f.out" 2>&1 || rc=$?
eq "--parallel without --loop is refused" "$rc,$(grep -c 'only means something with --loop' "$OUT/run40f.out")" "1,1"

# ====== 41. the loop's dashboard ===============================================
# A frame is a function of what the loop knows (lib/tui.sh): drawn here from a
# fixture with no terminal at all and read back character by character —
# bash pads by bytes, and a Cyrillic title used to push every border after it
# out of line. Then live, on a pty: the dashboard drawn, a worker selected and
# stopped from the keyboard, and the terminal left as it was found.
printf '\n41. the loop draws its dashboard on a terminal, and its keys work\n'
utf8="$(locale -a 2>/dev/null | grep -iE '^(en_US|C)\.UTF-?8$' | sed -n 1p)"
cat >"$SANDBOX/tui-fixture.sh" <<'FIX'
AIF_TUI_COLS="${COLS:-100}" AIF_TUI_ROWS="${ROWS:-40}" AIF_TUI_COLOR="${COLOR:-0}" AIF_TUI_256=1
AIF_TUI_UNICODE="${UNI:-1}" AIF_TUI_UTF8="$UTF8" AIF_TUI_NOW=1000 AIF_TUI_PARALLEL="${PAR:-4}" AIF_TUI_STARTED=0
AIF_TUI_READY="OPES-56 OPES-57 OPES-58" AIF_TUI_BUILT=3 AIF_TUI_BLOCKED=1 AIF_TUI_STOPPED=0
AIF_TUI_LOAD="6.2/14" AIF_TUI_DISK="41 GB free" AIF_TUI_SEL=1 AIF_TUI_BOTTOM=events
AIF_TUI_EVENTS="yellow|12:41|OPES-53 tests rejected (1/4): verify-red: 2 problems
green|12:39|OPES-51 built → Review · 38 min"
AIF_TUI_TYP_plan=600 AIF_TUI_TYP_tests=600 AIF_TUI_TYP_implement=900
for i in 1 2 3 4; do AIF_LS_KIND[i]="" AIF_LS_END[i]="" AIF_LS_PCT[i]=0 AIF_LS_PSTAGE[i]=0; done
AIF_LS_ID[1]=OPES-52 AIF_LS_RESULT[1]=running AIF_LS_START[1]=-860
AIF_LS_LIVE[1]='{"title":"Імпорт фото","phase":"run","stage":"implement","attempt":2,"attempts_max":3,"model":"sonnet","model_id":"claude-sonnet-5","dispatches":6,"dispatches_max":16,"tokens":412000,"stage_started":400,"last":"green rejected (1/3): 1 test still red","last_tone":"retry"}'
AIF_LS_ID[2]=OPES-53 AIF_LS_RESULT[2]=running AIF_LS_START[2]=280
AIF_LS_LIVE[2]='{"title":"Експорт у CSV","phase":"run","stage":"tests","attempt":1,"attempts_max":4,"model":"opus","model_id":"claude-opus-5-5","dispatches":3,"dispatches_max":16,"tokens":188000,"stage_started":700,"last":"plan admitted","last_tone":"ok"}'
AIF_LS_ID[3]=OPES-54 AIF_LS_RESULT[3]=running AIF_LS_START[3]=940
AIF_LS_LIVE[3]='{"title":"Push-сповіщення","phase":"worktree"}'
AIF_LS_ID[4]=OPES-51 AIF_LS_RESULT[4]=built AIF_LS_START[4]=-1280 AIF_LS_END[4]=1000 AIF_LS_PCT[4]=97 AIF_LS_PSTAGE[4]=3
AIF_LS_LIVE[4]='{"title":"Тема інтерфейсу","phase":"report","stage":"implement","attempt":1,"attempts_max":3,"model":"sonnet","model_id":"claude-sonnet-5","dispatches":7,"dispatches_max":16,"tokens":530000,"last":"implement admitted","last_tone":"ok"}'
FIX
frame() { # [VAR=value …] — one frame of the fixture, as lib/tui.sh draws it
  # shellcheck disable=SC2016 # the inner bash expands them, not this one
  env UTF8="$utf8" "$@" /bin/bash -c '. "$1/lib/tui.sh"; . "$2"; aif_tui_init; aif_tui_frame; printf "%s\n" "$AIF_TUI_FRAME"' \
    _ "$ROOT" "$SANDBOX/tui-fixture.sh"
}
frame >"$OUT/frame41.txt"
eq "a frame from a fixture: every line inside the terminal, and the borders where they belong around Cyrillic titles" \
  "$(python3 - "$OUT/frame41.txt" <<'PY3'
import sys
rows = open(sys.argv[1], encoding="utf-8").read().split("\n")
inside = max(len(r) for r in rows) <= 99
left = all(len(rows[r]) > 33 and rows[r][33] in "│╮╯┬" for r in range(9))
right = all(len(rows[r]) == 99 and rows[r][65] in "│╭╰┴" and rows[r][98] in "│╮╯" for r in range(9))
print(int(inside and left and right))
PY3
)" "1"
eq "…each worker with its title, station and attempt, model, progress and last verdict" \
  "$(grep -c '▸1 · OPES-52' "$OUT/frame41.txt"),$(grep -c 'Імпорт фото' "$OUT/frame41.txt"),$(grep -c 'implement        attempt 2/3' "$OUT/frame41.txt"),$(grep -c 'sonnet → claude-sonnet-5' "$OUT/frame41.txt"),$(grep -c '~81%' "$OUT/frame41.txt"),$(grep -c 'green rejected (1/3)' "$OUT/frame41.txt")" \
  "1,1,1,2,1,1"
eq "…a worker still getting ready, one built, and the loop with what is left in Ready" \
  "$(grep -c '◌ preparing its worktree' "$OUT/frame41.txt"),$(grep -c '✓ built → Review' "$OUT/frame41.txt"),$(grep -c 'Ready 3 → OPES-56, OPES-57 …' "$OUT/frame41.txt")" "1,1,1"
frame COLOR=1 | sed 's/\x1b\[[0-9;]*m//g' >"$OUT/frame41c.txt"
eq "…colour moves nothing: the coloured frame, its colour taken out, is the same frame" \
  "$(cmp -s "$OUT/frame41.txt" "$OUT/frame41c.txt" && echo same || echo different),$(frame COLOR=1 | grep -c "$(printf '\033')\[38;5;208m")" "same,$(frame COLOR=1 | grep -c "$(printf '\033')\[38;5;208m")"
eq "…a narrow terminal gets the list, an ASCII one no box drawing" \
  "$(frame COLS=80 | sed -n 1p | grep -c '^aif work --loop · '),$(frame COLS=80 | grep -c '▸1 OPES-52 Імпорт фото'),$(frame UNI=0 | grep -c '╭'),$(frame UNI=0 | grep -c '^+- >1 . OPES-52')" \
  "1,1,0,1"

# Live, on a pty of 110 by 40: two held in their plan station, the second
# selected and stopped from the keyboard, the third taking its slot.
fresh_project "$SANDBOX/p41"
for t in AIF-80 AIF-81 AIF-82 AIF-83; do
  ticket_for "$t"
done
git add -A && git commit -qm "four" >/dev/null
for t in AIF-80 AIF-81 AIF-82; do
  "$AIF" board create "tasks/$t/ticket.md" --column ready >/dev/null
done
mkdir -p "$SANDBOX/p41-marks"
rc="$(FAKE_SLEEP_IN="AIF-80:plan AIF-81:plan" FAKE_MARKS="$SANDBOX/p41-marks" FAKE_RELEASE="$SANDBOX/p41-marks/go" \
  python3 - "$AIF" "$SANDBOX/p41-marks" "$OUT/screen41" "$utf8" <<'PY3'
import fcntl, os, pty, select, struct, sys, termios, time
aif, marks, raw, utf8 = sys.argv[1:5]
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.environ["LANG"] = utf8 or "en_US.UTF-8"
    os.execv(aif, [aif, "work", "--loop"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 110, 0, 0))
buf = b""
def pump(secs):
    global buf
    end = time.time() + secs
    while time.time() < end:
        if select.select([fd], [], [], 0.05)[0]:
            try:
                c = os.read(fd, 65536)
            except OSError:
                return False
            if not c:
                return False
            buf += c
    return True
deadline = time.time() + 40
while not (os.path.exists(marks + "/AIF-80-plan") and os.path.exists(marks + "/AIF-81-plan")) and time.time() < deadline:
    pump(0.2)
pump(2.5)
open(raw + ".both", "wb").write(buf)
os.write(fd, b"2")
pump(1.5)
os.write(fd, b"s")
pump(1.5)
open(raw + ".ask", "wb").write(buf)
os.write(fd, b"y")
pump(5)
open(marks + "/go", "w").close()
while pump(1):
    pass
_, status = os.waitpid(pid, 0)
open(raw, "wb").write(buf)
print(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status))
PY3
)"
lastframe() { # <raw> — the last frame drawn, its colour taken out
  python3 - "$1" <<'PY3'
import re, sys
raw = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
print(re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", raw.split("\x1b[H")[-1]).replace("\r", ""))
PY3
}
eq "a stop from the dashboard: that card in Needs Human saying who, the others built, the third in its slot — exit 1" \
  "$rc,$(col AIF-80),$(col AIF-81),$(col AIF-82),$(last_comment AIF-81 | sed -n 1p)" \
  "1,review,needs_human,review,blocked: stopped — by Work (aif work AIF-81 --stop), during plan"
eq "…the dashboard drew both workers around the loop, then asked before stopping the selected one" \
  "$(lastframe "$OUT/screen41.both" | grep -c '▸1 · AIF-80'),$(lastframe "$OUT/screen41.both" | grep -c '2 · AIF-81'),$(lastframe "$OUT/screen41.both" | grep -c 'aif work --loop'),$(lastframe "$OUT/screen41.ask" | grep -c 'stop AIF-81? y: yes')" \
  "1,1,1,1"
eq "…on the terminal's alternate screen, left again, with the summary on the screen it came from" \
  "$(python3 - "$OUT/screen41" <<'PY3'
import sys
raw = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
enter, leave = raw.find("\x1b[?1049h"), raw.rfind("\x1b[?1049l")
print(int(0 <= enter < leave and "3 taken, 2 built" in raw[leave:] and "\x1b[?25h" in raw[leave - 8:]))
PY3
)" "1"
"$AIF" board create tasks/AIF-83/ticket.md --column ready >/dev/null
python3 - "$AIF" "$OUT/screen41b" <<'PY3'
import os, pty, select, sys, time
aif, raw = sys.argv[1:3]
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execv(aif, [aif, "work", "--loop", "--no-tui"])
buf = b""
while True:
    if select.select([fd], [], [], 0.2)[0]:
        try:
            c = os.read(fd, 65536)
        except OSError:
            break
        if not c:
            break
        buf += c
os.waitpid(pid, 0)
open(raw, "wb").write(buf)
PY3
eq "--no-tui on a terminal: lines, not the dashboard" \
  "$(grep -c "$(printf '\033')\[?1049h" "$OUT/screen41b"),$(sed 's/\x1b\[[0-9;]*m//g' "$OUT/screen41b" | grep -c 'loop 1 — AIF-83')" "0,1"

# ====== 42. an older branch, and a stopped run restarted =======================
#
# Everything a run reads about aif, it reads from the worktree, and `aif init`
# upgrades only the checkout it runs in — so every branch cut before an upgrade
# kept the old set, and the 0.11.0 driver would have dispatched 0.9.0's plan
# station to be judged by 0.9.0's gate (docs/DEFECTS.md 9.1). And a plan that
# stopped left its skeleton on the floor for the next plan to read as the
# repository (10.3). Now: the set is brought forward and committed before any
# of it is read; a stopped run restarts on the tree it started from when the
# ticket or the set moved; a resumed plan station sees the branch as it is.
printf '\n42. an older branch is brought up to the set, and a stopped run restarts on the tree it started from\n'
fresh_project "$SANDBOX/p42"
ticket_for AIF-42
git add -A && git commit -qm "ticket 42" >/dev/null
rc=0
FAKE_CREATE=1 FAKE_VERDICT=already_true "$AIF" work AIF-42 >"$OUT/run42a.out" 2>&1 || rc=$?
WT=.aif/worktrees/AIF-42
eq "a spec stop, in a worktree, leaves the stopped plan's skeleton uncommitted" \
  "$rc,$(jq -r '.status' "$WT/tasks/AIF-42/run.json"),$(git -C "$WT" status --porcelain | grep -c 'src/feat.py')" "1,spec,1"
eq "the run record names the set it ran under" "$(jq -r '.set_version' "$WT/tasks/AIF-42/run.json")" "$(jq -r '.set_version' .aif/manifest.json)"
# The branch as an older set would have left it: an older gate and station, a
# gate this set no longer ships, no guide and no fragments, a manifest naming
# the old version, a run record from before records named their set — and one
# more file the stopped plan left on the floor.
printf '\n# an older gate\n' >>"$WT/.aif/gates/plan.sh"
printf '\nAn older instruction.\n' >>"$WT/.claude/agents/aif-plan.md"
rm -rf "$WT/.aif/guide" "$WT/.aif/stacks"
printf '#!/bin/bash\nexit 0\n' >"$WT/.aif/gates/plan-form.sh"
tmp="$(mktemp)"
jq '.set_version = "0.9.0" | .files += [{ path: ".aif/gates/plan-form.sh", sha256: "0" }]' "$WT/.aif/manifest.json" >"$tmp" && mv "$tmp" "$WT/.aif/manifest.json"
tmp="$(mktemp)"
jq 'del(.set_version)' "$WT/tasks/AIF-42/run.json" >"$tmp" && mv "$tmp" "$WT/tasks/AIF-42/run.json"
printf 'def leftover():\n    pass\n' >"$WT/src/leftover.py"
git -C "$WT" add -A -- .aif .claude tasks >/dev/null 2>&1
git -C "$WT" -c user.email=o@x -c user.name=old commit -qm "as the old set left it" >/dev/null
eq "doctor names the worktree still on the older set, and what happens to it" \
  "$("$AIF" doctor 2>/dev/null | grep -c 'worktrees .*on an older set: AIF-42 (0.9.0) — brought up to')" "1"
rc=0
FAKE_CREATE=1 "$AIF" work AIF-42 >"$OUT/run42b.out" 2>&1 || rc=$?
eq "built, the ticket unchanged, the set moved" "$rc" "0"
eq "the branch was brought up to the checkout's set first, and said so" \
  "$(grep -c "aif/AIF-42 brought up to the checkout's set (0.9.0 → " "$OUT/run42b.out")" "1"
eq "…in a commit of its own, before the stations" "$(git -C "$WT" log --format=%s | grep -c '^aif: set .* for AIF-42')" "1"
eq "the gate and the station are the checkout's again; the retired gate is gone; the guide and the fragments are there" \
  "$(cmp -s .aif/gates/plan.sh "$WT/.aif/gates/plan.sh" && echo same),$(cmp -s .claude/agents/aif-plan.md "$WT/.claude/agents/aif-plan.md" && echo same),$(test -f "$WT/.aif/gates/plan-form.sh" && echo kept || echo gone),$(test -f "$WT/.aif/guide/tests.md" && echo yes),$(test -f "$WT/.aif/stacks/pytest.md" && echo yes)" "same,same,gone,yes,yes"
eq "the run restarted because the set moved, and said so" \
  "$(grep -c 'restart .*the set moved since the last run (an older set → ' "$OUT/run42b.out")" "1"
eq "…with the stopped plan's leftovers put back first, never committed" \
  "$(grep -c 'file(s) put back to' "$OUT/run42b.out"),$(git -C "$WT" log --all --format=%s -- src/leftover.py | grep -c .),$(test -e "$WT/src/leftover.py" && echo there || echo gone)" "1,0,gone"
eq "the restart is a commit that says so, and the new record names the set" \
  "$(git -C "$WT" log --format=%s | grep -c '^aif: restart AIF-42 — the tree put back to'),$(jq -r '.set_version' "$WT/tasks/AIF-42/run.json")" "1,$(jq -r '.set_version' .aif/manifest.json)"
eq "doctor's worktrees line is quiet now — the branch is on the checkout's set" "$("$AIF" doctor 2>/dev/null | grep -c 'on an older set')" "0"

# The ticket changes after a spec stop (what a spec stop asks for): the restart
# puts the stopped plan's leftovers back before the new plan reads the tree.
fresh_project "$SANDBOX/p42b"
ticket_for AIF-42
git add -A && git commit -qm "ticket 42b" >/dev/null
rc=0
FAKE_CREATE=1 FAKE_VERDICT=already_true "$AIF" work AIF-42 --no-worktree >"$OUT/run42c.out" 2>&1 || rc=$?
eq "a spec stop in place" "$rc,$(jq -r '.status' tasks/AIF-42/run.json),$(test -f src/feat.py && echo left)" "1,spec,left"
printf 'def leftover():\n    pass\n' >src/leftover.py
ticket_for AIF-42 '[]' ',
    { "id": "AC-002", "surface": "export",
      "given": "the export ran", "when": "the output is read",
      "then": "writes the manifest marker", "expect": "impl2" }'
rc=0
FAKE_CREATE=1 "$AIF" work AIF-42 --no-worktree >"$OUT/run42d.out" 2>&1 || rc=$?
eq "the reworked ticket: restarted and built" "$rc,$(jq -r '.status' tasks/AIF-42/run.json)" "0,built"
eq "…the restart line says the ticket changed and what was put back" \
  "$(grep -c 'restart .*the ticket changed since the last run .* file(s) put back to' "$OUT/run42d.out")" "1"
eq "…and the stopped plan's leftover is gone, in no commit" \
  "$(test -e src/leftover.py && echo there || echo gone),$(git log --all --format=%s -- src/leftover.py | grep -c .)" "gone,0"
eq "the record kept its ledger across the restart" "$(jq '[.entries[] | select(.gate == "plan")] | length' tasks/AIF-42/ledger.json)" "2"
# A spec stop re-run with the ticket unchanged resumes the plan station on a
# clean tree: the leftovers are put back, said so.
fresh_project "$SANDBOX/p42c"
ticket_for AIF-42
git add -A && git commit -qm "ticket 42c" >/dev/null
FAKE_CREATE=1 FAKE_VERDICT=already_true "$AIF" work AIF-42 --no-worktree >/dev/null 2>&1 || true
printf 'def leftover():\n    pass\n' >src/leftover.py
rc=0
FAKE_CREATE=1 "$AIF" work AIF-42 --no-worktree >"$OUT/run42e.out" 2>&1 || rc=$?
eq "resumed at plan: the stopped plan's files put back, said so, built" \
  "$rc,$(grep -c 'resume .*plan — .*file(s) the stopped plan left are put back' "$OUT/run42e.out"),$(git log --all --format=%s -- src/leftover.py | grep -c .)" "0,1,0"

# ====== 43. the size cap counts rules, not examples ===========================
# A criterion is an example of a rule, and what a person calls an acceptance
# criterion is a rule: capped at fifteen examples, the analyst cut ordinary
# six-rule stories into fragments (docs/DEFECTS.md 12.1). The cap counts rules
# now; the examples keep a backstop; over the cap only the human keeps a ticket
# whole; a ticket without rules is held to its old cap; and the worker builds a
# ticket with rules as it did before — the criteria are what it reads.
printf '\n43. the size cap counts rules, not examples; over it, only the human keeps a ticket whole\n'
fresh_project "$SANDBOX/p43"
rules_ticket() { # <id> <rules> <examples per rule> [decided-json] — rules 0: none, the old shape
  "$AIF" _ticket-init "$1" >/dev/null
  {
    printf '%s\n' '<!-- aif:meta'
    jq -n --arg id "$1" --argjson r "$2" --argjson e "$3" --argjson dec "${4:-[]}" '
      def pad3: tostring | if length == 1 then "00" + . elif length == 2 then "0" + . else . end;
      { schema: 2, ticket: $id, lang: "en", risk: "low", surfaces: ["export"],
        acceptance: [ range(0; (if $r > 0 then $r * $e else $e end)) as $i
          | { id: ("AC-" + (($i + 1) | pad3)), surface: "export",
              given: ("case " + (($i + 1) | tostring)), when: "the export runs",
              then: "writes the marker", expect: ("impl" + (($i + 1) | tostring)) }
          + (if $r > 0 then { rule: ("R-" + ((($i / $e) | floor) + 1 | tostring)) } else {} end) ],
        open: [], decided: $dec, verification_gaps: [], non_goals: [] }
      + (if $r > 0
         then { rules: [ range(1; $r + 1) | { id: ("R-" + tostring), text: ("the export keeps rule " + tostring) } ] }
         else {} end)'
    printf '%s\n' '-->' "# $1 — one-command user export" '' 'Support needs a one-command export of the user list.'
  } >"tasks/$1/ticket.md"
}
ready_says() { # <id> — the ready gate's exit code and its words, as the analyst sees them
  rc=0
  "$AIF" _ready "$1" >"$OUT/ready-$1.out" 2>&1 || rc=$?
}
rules_ticket AIF-44 6 3
ready_says AIF-44
eq "six rules with eighteen examples — refused by the old cap of fifteen — are ready" \
  "$rc,$(grep -c 'ready: 6 rule(s) · 18 criteria' "$OUT/ready-AIF-44.out")" "0,1"
rules_ticket AIF-45 7 1
ready_says AIF-45
eq "seven rules: refused, naming the order to work in, and never 'split the ticket'" \
  "$rc,$(grep -c 'meta.rules has 7 rules, limit is 6 — in this order: a rule that only lists cases is restated' "$OUT/ready-AIF-45.out"),$(grep -c 'split the ticket' "$OUT/ready-AIF-45.out")" "1,1,0"
rules_ticket AIF-46 7 1 '[{ "question": "keep it whole?", "answer": "yes — one flow, no axis to cut along", "by": "human", "kind": "size" }]'
ready_says AIF-46
eq "…ready once the user keeps it whole, and the pass says so with their words" \
  "$rc,$(grep -c 'KEPT WHOLE BY THE HUMAN — 7 rules, over the limit of 6' "$OUT/ready-AIF-46.out"),$(grep -c 'keep it whole? → yes — one flow' "$OUT/ready-AIF-46.out")" "0,1,1"
rules_ticket AIF-47 7 1 '[{ "question": "keep it whole?", "answer": "yes", "by": "default", "kind": "size" }]'
ready_says AIF-47
eq "…but a size decision taken by default is refused: the analyst cannot lift its own limit" \
  "$rc,$(grep -c 'keeps the ticket whole by default' "$OUT/ready-AIF-47.out"),$(grep -c 'meta.rules has 7 rules' "$OUT/ready-AIF-47.out")" "1,1,1"
jq '.limits.ticket_rules_max = 7' .aif/project.json >"$OUT/p43.json" && cp "$OUT/p43.json" .aif/project.json
ready_says AIF-45
eq "a project that sets its own rules cap is held to it" "$rc" "0"
jq '.limits.ticket_rules_max = 6' .aif/project.json >"$OUT/p43.json" && cp "$OUT/p43.json" .aif/project.json
rules_ticket AIF-48 1 6
ready_says AIF-48
eq "six examples on one rule: ready, with the crowded rule named on the pass path" \
  "$rc,$(grep -c 'MANY EXAMPLES ON ONE RULE' "$OUT/ready-AIF-48.out"),$(grep -c 'R-1: 6 examples (AC-001, AC-002, AC-003, AC-004, AC-005, AC-006)' "$OUT/ready-AIF-48.out")" "0,1,1"
rules_ticket AIF-49 6 6
ready_says AIF-49
eq "thirty-six examples: the backstop refuses, pointing at the key examples, not at a second ticket" \
  "$rc,$(grep -c 'meta.acceptance has 36 criteria, and the backstop is 30 — keep the key examples' "$OUT/ready-AIF-49.out")" "1,1"
sed -i.bak 's/"rule": "R-6"/"rule": "R-9"/' tasks/AIF-44/ticket.md && rm -f tasks/AIF-44/ticket.md.bak
ready_says AIF-44
eq "a criterion naming a rule that is not there, and a rule nothing illustrates: both refused" \
  "$rc,$(grep -c 'AC-016.rule "R-9" is not in meta.rules' "$OUT/ready-AIF-44.out"),$(grep -c 'R-6 has no criterion' "$OUT/ready-AIF-44.out")" "1,1,1"
rules_ticket AIF-51 0 16
ready_says AIF-51
eq "a ticket without rules keeps the old cap — sixteen refused, told to group them under rules" \
  "$rc,$(grep -c 'a ticket without rules is held to 15 — group them under meta.rules' "$OUT/ready-AIF-51.out")" "1,1"
rules_ticket AIF-52 0 15
ready_says AIF-52
eq "…and fifteen pass, the summary as it always was" \
  "$rc,$(grep -c 'ready: 15 criteria · 0 decided · 0 gap(s)$' "$OUT/ready-AIF-52.out"),$(grep -c 'rule(s)' "$OUT/ready-AIF-52.out")" "0,1,0"
"$AIF" explain AIF-46 --format tree >"$OUT/explain46.out" 2>&1
eq "explain draws the rules, each criterion's rule, and the size decision" \
  "$(grep -c '^    R-1 — the export keeps rule 1  (AC-001)$' "$OUT/explain46.out"),$(grep -c 'AC-001 \[R-1\] — given' "$OUT/explain46.out"),$(grep -c '(size: kept whole over the cap)' "$OUT/explain46.out")" "1,1,1"
# The caps reach a project made before them through the upgrade, and the gate
# falls back to the template's values until then.
jq 'del(.limits.ticket_rules_max, .limits.ticket_examples_max, .limits.rule_examples_warn)' .aif/project.json >"$OUT/p43.json" && cp "$OUT/p43.json" .aif/project.json
ready_says AIF-45
eq "without the keys the gate holds the template's caps" "$rc,$(grep -c 'limit is 6' "$OUT/ready-AIF-45.out")" "1,1"
eq "…and project check names them as moved" "$("$AIF" project check 2>&1 | grep -c 'limits.ticket_rules_max is not set — the pytest template puts it at 6')" "1"
"$AIF" project upgrade >/dev/null 2>&1
eq "the upgrade brings all three forward" "$(jq -c '[.limits.ticket_rules_max, .limits.ticket_examples_max, .limits.rule_examples_warn]' .aif/project.json)" "[6,30,5]"
# A ticket with rules goes through the worker untouched: the plan, the tests
# and verify-red read the criteria, one by one, as before.
rules_ticket AIF-53 3 1
git add -A && git commit -qm "tickets 43" >/dev/null
rc=0
"$AIF" work AIF-53 --no-worktree >"$OUT/run43.out" 2>&1 || rc=$?
eq "a ticket with rules is built" "$rc,$(jq -r '.status' tasks/AIF-53/run.json)" "0,built"
eq "…its intake read the rules" \
  "$(jq -r '[.entries[] | select(.gate == "ready")] | first | .reason' tasks/AIF-53/ledger.json)" "ready: 3 rule(s) · 3 criteria · 0 decided · 0 gap(s)"

# ====== 44. a ticket is a delta on the tickets before it ======================
# The analyst read main and nothing in flight, so a new ticket could restate a
# rule another ticket owned, or change it without a word (docs/DEFECTS.md
# 12.2). Now a rule names what it replaces, the ready gate holds the name to a
# ticket and a rule under tasks/, and `aif rules` is the map: every ticket's
# rules in force with its column, computed from the tickets and the board.
printf '\n44. a rule names the rule it replaces, the gate holds the name, and aif rules is the map\n'
fresh_project "$SANDBOX/p44"
delta_ticket() { # <id> <title> <rules-json or "-"> <acceptance-json>
  "$AIF" _ticket-init "$1" >/dev/null
  {
    printf '%s\n' '<!-- aif:meta'
    jq -n --arg id "$1" --argjson acs "$4" --arg rules "$3" '
      { schema: 2, ticket: $id, lang: "uk", risk: "low", surfaces: ["home"],
        acceptance: $acs, open: [], decided: [], verification_gaps: [], non_goals: [] }
      + (if $rules == "-" then {} else { rules: ($rules | fromjson) } end)'
    printf '%s\n' '-->' "# $1 — $2" '' 'Людина бачить, скільки можна витратити сьогодні.'
  } >"tasks/$1/ticket.md"
}
ex() { # <AC-nnn> <rule or -> <then> <expect> — one criterion, as JSON
  jq -cn --arg id "$1" --arg r "$2" --arg t "$3" --arg e "$4" \
    '{ id: $id, surface: "home", given: "місяць іде", when: "Home відкрито", then: $t, expect: $e }
     + (if $r == "-" then {} else { rule: $r } end)'
}
delta_ticket AIF-60 "денна норма на Home" \
  '[{ "id": "R-1", "text": "Залишок місяця — сума всіх транзакцій місяця" },
    { "id": "R-2", "text": "Норма — залишок, поділений на дні до кінця місяця" }]' \
  "[$(ex AC-001 R-1 'залишок дорівнює' 15000), $(ex AC-002 R-2 'норма дорівнює' 200)]"
delta_ticket AIF-61 "валюта на ручних картках" - "[$(ex AC-001 - 'валюта картки дорівнює' 980)]"
delta_ticket AIF-62 "норма від цілі" \
  '[{ "id": "R-1", "text": "Залишок місяця — дохід мінус ціль мінус витрачене", "changes": ["AIF-60 R-1"] },
    { "id": "R-2", "text": "Ціль задається одним числом у гривнях", "changes": ["AIF-61 AC-001"] }]' \
  "[$(ex AC-001 R-1 'залишок дорівнює' 9000), $(ex AC-002 R-2 'ціль дорівнює' 5000)]"
ready_says AIF-62
eq "a rule naming the rule it replaces — and a criterion of a ticket from before rules — is ready, and the pass says what moves" \
  "$rc,$(grep -c 'CHANGES RULES OF OTHER TICKETS' "$OUT/ready-AIF-62.out"),$(grep -c 'R-1 replaces AIF-60 R-1' "$OUT/ready-AIF-62.out"),$(grep -c 'R-2 replaces AIF-61 AC-001' "$OUT/ready-AIF-62.out")" "0,1,1,1"
delta_ticket AIF-63 "зламані посилання" \
  '[{ "id": "R-1", "text": "a", "changes": ["AIF-99 R-1"] },
    { "id": "R-2", "text": "b", "changes": ["AIF-60 R-7"] },
    { "id": "R-3", "text": "c", "changes": ["AIF-63 R-1"] },
    { "id": "R-4", "text": "d", "changes": "AIF-60 R-1" }]' \
  "[$(ex AC-001 R-1 x 1), $(ex AC-002 R-2 x 2), $(ex AC-003 R-3 x 3), $(ex AC-004 R-4 x 4)]"
ready_says AIF-63
eq "a name that resolves to nothing, or to itself, or is not a list: each refused, once" \
  "$rc,$(grep -c 'there is no AIF-99 under tasks/' "$OUT/ready-AIF-63.out"),$(grep -c 'AIF-60 has no R-7' "$OUT/ready-AIF-63.out"),$(grep -c 'R-3.changes names this ticket' "$OUT/ready-AIF-63.out"),$(grep -c 'R-4.changes must be a list' "$OUT/ready-AIF-63.out"),$(grep -c '^ *- ' "$OUT/ready-AIF-63.out")" "1,1,1,1,1,4"
rm -rf tasks/AIF-63
"$AIF" board create tasks/AIF-60/ticket.md --column "done" >/dev/null
"$AIF" board create tasks/AIF-61/ticket.md --column ready >/dev/null
"$AIF" board create tasks/AIF-62/ticket.md --column backlog >/dev/null
"$AIF" rules >"$OUT/rules44.out" 2>&1
eq "the map: each ticket with its column; the rule a later ticket changed is left out, the one in force is in" \
  "$(grep -c '^AIF-60 · done · денна норма на Home$' "$OUT/rules44.out"),$(grep -c 'R-1 — Залишок місяця — сума' "$OUT/rules44.out"),$(grep -c '^  R-2 — Норма — залишок' "$OUT/rules44.out"),$(grep -c '^  R-1 — Залишок місяця — дохід мінус ціль мінус витрачене  (AC-001)  — changes AIF-60 R-1$' "$OUT/rules44.out")" "1,0,1,1"
eq "…a ticket written before rules shows its criteria — or nothing, once a later rule changed them all" \
  "$(grep -c '^AIF-61 ·' "$OUT/rules44.out")" "0"
"$AIF" rules --all >"$OUT/rules44all.out" 2>&1
eq "--all keeps the history, each changed rule marked with the rule that changed it" \
  "$(grep -c 'R-1 — Залишок місяця — сума всіх транзакцій місяця  (AC-001)  ✗ changed by AIF-62 R-1' "$OUT/rules44all.out"),$(grep -c '^AIF-61 · ready · валюта на ручних картках$' "$OUT/rules44all.out"),$(grep -c 'AC-001 — given місяць іде, when Home відкрито, then валюта картки дорівнює → 980  ✗ changed by AIF-62 R-2' "$OUT/rules44all.out")" "1,1,1"
eq "a word narrows the map, whatever its case — Cyrillic too" \
  "$("$AIF" rules НОРМА 2>/dev/null | grep -c '^AIF-6[0-9] ·'),$("$AIF" rules ЦІЛЬ 2>/dev/null | grep -c '^AIF-62 ·'),$("$AIF" rules nothing-like-this 2>/dev/null)" "2,1,no ticket mentions: nothing-like-this"
eq "--json is the same map, for a script" \
  "$("$AIF" rules --json 2>/dev/null | jq -c '[.[] | {ticket, column, n: (.entries | length)}]')" \
  '[{"ticket":"AIF-60","column":"done","n":1},{"ticket":"AIF-62","column":"backlog","n":2}]'

# ====== 45. the size of a plan and of a change are said, not capped ===========
# The plan gate refused a manifest past 12 implementation files and scope a
# change past 400 lines. On a live project neither ever fired; both shaped
# tickets before any run, through the analyst's estimate of them
# (docs/DEFECTS.md 12.4). Retired: the gates say the size and refuse nothing
# for it, and a project.json that still sets the caps is told they do nothing.
printf '\n45. a plan of fourteen files and a change of five hundred lines are built; the retired caps leave project.json\n'
fresh_project "$SANDBOX/p45"
i=1
while [ "$i" -le 13 ]; do
  printf 'W%s = %s\n' "$i" "$i" >"src/w$i.py"
  i=$((i + 1))
done
ticket_for AIF-70
git add -A && git commit -qm "ticket 45" >/dev/null
rc=0
FAKE_WIDEPLAN=13 FAKE_BIGDIFF=520 "$AIF" work AIF-70 --no-worktree >"$OUT/run45.out" 2>&1 || rc=$?
eq "built" "$rc,$(jq -r '.status' tasks/AIF-70/run.json)" "0,built"
eq "the plan named fourteen implementation files, and its gate said so and passed it" \
  "$(jq -r '[.entries[] | select(.gate == "plan" and .result == "pass")] | last | .reason' tasks/AIF-70/ledger.json | grep -c '^plan: 14 implementation file(s)')" "1"
eq "the change ran past five hundred lines, and scope said so and passed it" \
  "$(jq -r '[.entries[] | select(.gate == "scope" and .result == "pass")] | last | .reason' tasks/AIF-70/ledger.json | grep -c -E 'change confined to the plan \(5[0-9][0-9] lines\)')" "1"
jq '.limits.plan_files_max = 12 | .limits.diff_lines_max = 400 | .limits.revisions_max = 5' .aif/project.json >"$OUT/p45.json" && cp "$OUT/p45.json" .aif/project.json
eq "project check names each retired cap the file still sets" \
  "$("$AIF" project check 2>&1 | grep -c 'is set, and nothing reads it any more — aif retired it')" "3"
"$AIF" project upgrade >"$OUT/up45.out" 2>&1
eq "the upgrade takes them out, and says so" \
  "$(jq -c '[.limits | has("plan_files_max", "diff_lines_max", "revisions_max")]' .aif/project.json),$(grep -c 'removed — retired, nothing reads it' "$OUT/up45.out")" "[false,false,false],3"

# ----------------------------------------------------------------------------
printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'work: ok\n'
  cd / && rm -rf "$SANDBOX"
else
  printf 'work: %s failure(s) — sandbox kept at %s\n' "$fails" "$SANDBOX"
  exit 1
fi
