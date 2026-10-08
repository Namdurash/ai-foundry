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
#  19  land: the yes after review — merged and judged in the ticket's
#      worktree, the checkout fast-forwarded, Done, the worktree and branch
#      gone, the ticket that depended on it released; a red suite or a
#      conflict lands nothing and sends the card back to the worker, saying why
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
#  25  land, when the merge moves the dependencies: judged in the worktree,
#      where they are installed, and landed; named here with the command,
#      installed here only with --prepare, after the fast-forward — a failed
#      install or a rewrite said on a landed card
#  26  verify-red counts a criterion covered only by a test the runner
#      collected: its only test in a declared file the runner never collects
#      is sent back to the tests station, naming the file, which may stay as
#      a helper; coarse mode, which cannot tell, reads every file and says so
#  27  a land stopped before its fast-forward — Ctrl-C to its process group,
#      an INT or a TERM to its pid, an error on the way — lands nothing: the
#      worktree back on its branch, the install it had started there to be
#      made again, the card in Review; a red land's own exit is a verdict,
#      not a stop
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
#      too; a worker that cannot start has the machine checked again before
#      the next card is taken
#  41  on a terminal the loop draws its dashboard: a frame from a fixture
#      keeps every line inside the terminal and every border where it belongs
#      around Cyrillic titles, in colour or not, wide, compact or ASCII; live,
#      on a pty, the keys select a worker and stop it, the card saying who,
#      and the terminal is left as it was found, the summary on it
#  46  the ledger never stops a run, a gate or a land, and is not in git: a
#      lock whose writer is gone or never signed is taken over, one held by a
#      live writer costs a row and a warning, a ledger that is not JSON is set
#      aside; the analyst's uncommitted ticket is taken aside at land, a ticket
#      edited and committed after the cut and a set that moved on are settled
#      by owner, and a developer's own untracked file refuses the land untouched
#  47  a conflict at land goes back to the worker, which brings the branch
#      onto the target in its worktree: a conflict in code settled by the
#      implement station and the merged tree judged again, the card back
#      in Review saying so; the station unable to settle it, or a test
#      file in conflict, and the ticket is built again from the target,
#      the first build kept; a target that moved elsewhere merged clean
#  48  the worker's claim on the card it takes — taken: host, pid, time —
#      under which the report is still the head; a rework committed in the
#      checkout reaches a branch that already carries a ticket, the ticket
#      alone, and the run restarts on it; the loop writes summary.json where
#      AIF_WORK_LOOP_LOGDIR says, for a parent that cannot read its exit code
#      as the board; a hang-up to a worker's group ends it in 129 with the
#      card saying so; and the loop whose own terminal closes over it — every
#      line it prints failing from then on — stops its runs, writes its
#      summary, releases its lock and ends in 129, its dashboard on or off
#  49  aif board release moves the Backlog cards whose every dependency is
#      Done and landed to the bottom of Ready, with a comment; holds one on a
#      rework: head or a parked label; names a Done dependency with no land
#      commit here as a merge by hand, with the move that releases it;
#      --dry-run says the same and touches nothing
#  50  --idle: an empty Ready is not the end — the loop says so once and
#      takes what comes, a card that left Ready and came back included; one
#      loop per checkout, a second refused with exit 3 and nothing touched,
#      not even a log directory it was told to share; a board that does not
#      answer is asked again; `aif work --loop --drain` from another terminal
#      ends it 0, `aif work --loop --stop` ends it 143 with each card saying
#      who stopped it; a drain or a TERM that comes while the loop reads
#      Ready takes no card that read found; a lock whose loop is gone is
#      taken over
#  51  a worker that could not start has the machine asked again — the
#      preflight, without the suite probe — and the loop goes on while it
#      passes: three in a row stop it, a preflight that fails again stops it
#      at the first; a worker that died in its intake is the machine's too,
#      never two in a row; idle, a card the environment blocked and a person
#      moved back is taken again
#  52  aif work --status says what this machine knows of a run, offline: a
#      build on its branch, a worker killed outright mid-station — its lock
#      dead, its station still running in the group it led — a lock whose pid
#      an unrelated program now holds, its group never listed, a build of a
#      ticket since reworked not taken for one; every ticket with a trace here
#  53  a dead lock is taken over by one taker: two released at once, many
#      times over, leave exactly one holder in its own name, the run lock's
#      and the loop's; a pid handed out again to another aif work after the
#      lock was signed is no holder; a takeover mark held now refuses the
#      next taker, one two minutes old is nobody's; a run's takeovers are
#      counted in its record, a resume keeps the count, and the fourth stops
#      the run, blocked: run
#  54  what a dead worker left — named by the group it led, the station's own
#      pid in the lock, this clone's worktree as a cwd — is TERMed before
#      its lock is taken over, a child that left for / with it; a takeover
#      with something still running there refused with exit 3, then made
#      once it is gone; another clone's station on the same id neither listed
#      nor stopped
#  55  aif work --status with no id lists a --no-worktree build, and a lock
#      with no phase says its phase is unknown
#  56  the loop's second Ctrl-C sent a tick after the first — where a
#      foreground sleep's end lost it — stops the runs every time; and a
#      Ctrl-C that lands while the loop waits on a slow `date` leaves it
#      alive, its run built and reported
#  57  an idle loop names in its lock each card it holds, with why, and says
#      when Ready holds only those; a worker that refused to take over a
#      dead run still running is held, not counted as the machine; a process
#      opened by hand in a dead run's worktree is never signalled and refuses
#      the takeover; a card taken twice has a log for each take
#  58  a Ctrl-C during the Ready read is not the board; aif work --loop
#      --stop reaches a loop still in its preflight; a loop that is not idle
#      asks the machine again before one failed Ready read ends it 3
#  59  a .gitignore block written by an older aif, without the worktrees line:
#      the worker adds that line to the block and says so, and every line the
#      block held stays; a block with no end line is left alone; no block at
#      all gets one, the developer's own lines kept
#  60  the land beside the developer's own work: uncommitted edits and staged
#      files it does not touch stay as they are; an edit to a file it changes
#      refuses it, named, nothing touched
#  61  the dependencies are installed where the verdict is reached: a branch
#      that moved them lands with nothing installed here, said with the
#      command; what the target moved is installed in the worktree, an install
#      there that rewrites a lockfile refuses the land, and a worktree the land
#      had to cut is installed before it judges
#  62  the verdict: the worker's stands when the target moved only in tasks/,
#      and no suite runs; a check bound to green that is red on the result
#      sends the card back to the worker, named
#  63  a TERM to a land's group during its verdict, and the KILL 1.4 s after
#      it: nothing landed, main's reflog untouched, the worktree back on its
#      branch, no lock or marker left; a worker on the ticket while the next
#      land runs is refused, and that land lands. Sent as its fast-forward
#      starts, they do not reach it: main ends at the merge, and the next
#      land finishes the bookkeeping
#  64  a KILL alone during the verdict: main untouched, aif doctor names the
#      land that died, aif work puts the worktree back and builds, and the
#      next land says what it settled and lands
#  65  what only a KILL of the fast-forward itself leaves, built by hand: a
#      marker at landed is finished by the next land, no suite run again; one
#      in its fast-forward with git's lock left is exit 3, naming the lock,
#      nothing touched; without the lock, the ticket's own files come back
#      from aside, said, and the land goes on
#  66  the land's merge commit runs the project's hooks, in the worktree — a
#      pre-commit's refusal is a land: line, nothing landed — while the
#      worker's own git ran none of them
#  67  a target that moves while the land runs: nothing landed, the card left
#      in Review, said
#  68  a blocked: line the board refused, kept on this machine, is posted by
#      the next worker run before it takes a card — over its run's own claim
#      only; a card whose head moved on, or in Review, has its stale file
#      removed; one In Progress keeps it for the shift
#  69  the worker keeps its claim's comment id and words in its run lock and
#      edits the claim at every dispatch — `· alive at <time>` — on the local
#      board, no comment added
#  80  the runner's usage limit pauses a run: the same attempt dispatched again
#      once it resets, uncounted, the wait outside the wall clock, the claim
#      beating meanwhile, the wait in the run's record and in its report
#  81  a limit that names no reset, or one past what a run waits, is blocked:
#      environment, naming it, and the loop stops on the hold it leaves,
#      asking nothing of the machine again
#  82  the server's throttle and an overload are asked again, uncounted, and
#      the throttle's words "usage limit" are not read as one
#  83  a runner that wrote nothing, or not JSON, is asked again, then blocked:
#      environment — never the station's, never a dead worker; the loop asks
#      the machine again
#  84  the pause is shared: a worker waits before its station, a loop takes no
#      card until it is over, one model's limit holds that model's stations
#  85  a run stopped while it waits: the card says until when it was paused,
#      the attempt is not counted, and aif work --status says it is paused
#  86  the worker's own git — its commits, the sync's merge, its worktree —
#      runs none of the project's hooks
#  87  a station's model the profile does not map is refused before the claim,
#      naming it and what the profile maps; default passes where opus and
#      sonnet are both mapped
#
# Run by `make check`. Requires git, jq and python3; skips without python3.

set -uo pipefail

# A `make check` run from inside a Claude Code session exports these into
# everything it starts, and aif reads the first as "this is a session" (the
# runner's probe; `aif start` refuses under it). Nothing here is a session.
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT

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

# wait_exit <pid> <secs> — the exit code of a process this harness started,
# waited for at most <secs>. Past that it is a failure: the process is stopped
# with its group — a TERM, a KILL five seconds later — and the code is 124.
# Every idle loop is waited on through here: `aif work --loop --idle` never
# ends on its own, and a drain or a stop that did not land would otherwise
# hang the harness instead of failing it.
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
  return "$rc"
}

# Every idle loop started here, by pid — each a process group of its own
# (launch, scenario 39). Whatever is left of them when the harness exits — a
# scenario that failed half way, a Ctrl-C — is stopped with its group, each
# wait bounded, so no loop outlives the run polling a sandbox.
IDLE_PIDS=""
reap_idle() {
  local p i
  for p in $IDLE_PIDS; do
    kill -0 "$p" 2>/dev/null || continue
    kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null
    i=0
    while kill -0 "$p" 2>/dev/null && [ "$i" -lt 50 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    kill -KILL -- "-$p" 2>/dev/null || kill -KILL "$p" 2>/dev/null
  done
  return 0
}
trap reap_idle EXIT

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
    # What a held station leaves behind when its worker is killed outright
    # (docs/DEFECTS.md 14.1, scenario 54): FAKE_CHILD_CD a child that left the
    # worktree for / with no ticket in its argv — only the group names it —
    # and FAKE_CHILD_DEAF one that ignores TERM, in the worktree. Started
    # before the mark, so a scenario that sees the mark sees them; their
    # output nowhere, so no capture waits on them.
    if [ "${FAKE_CHILD_CD:-0}" = 1 ]; then (cd / && exec sleep 47.3 </dev/null >/dev/null 2>&1) & fi
    if [ "${FAKE_CHILD_DEAF:-0}" = 1 ]; then (trap '' TERM && exec sleep 63.3 </dev/null >/dev/null 2>&1) & fi
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
# The runner's own ends, not the station's (docs/DEFECTS.md 13.7): each knob
# names `<ticket>:<station>`, and the dispatch it hits writes no artifact and
# prints a stream with the fields the CLI writes in stream-json --verbose
# (docs/FINDINGS.md #30) — system/init, the rate_limit_event, the API-error
# assistant line, a result with is_error, api_error_status and
# terminal_reason — and exits 1.
#   FAKE_LIMIT_ONCE=<ID>:<st>:<secs>  the first dispatch: the usage limit,
#       rejected, resetsAt now + secs, of type FAKE_LIMIT_TYPE (five_hour),
#       cut off after a turn
#   FAKE_LIMIT_NORESET=<ID>:<st>      every dispatch: a credit limit, no reset
#   FAKE_THROTTLE_ONCE=<ID>:<st>      the first: the server's throttle — a
#       rejected event with no type, and "usage limit" in its words
#   FAKE_TRANSIENT_ONCE=<ID>:<st>     the first: a 529, overloaded
#   FAKE_NOENVELOPE=<ID>:<st>[:<n>]   nothing written (every dispatch, or the first n)
#   FAKE_NOTJSON=<ID>:<st>[:<n>]      a line that is not JSON
# The default envelope below stays one pretty-printed object: the worker
# reads that shape too.
runner_end() { # <rate_limit_info JSON|""> <API error kind|""> <api_error_status> <result> <turns>
  {
    printf '{"type":"system","subtype":"init","apiKeySource":"none","session_id":"fake"}\n'
    [ -z "$1" ] || jq -nc --argjson r "$1" '{type:"rate_limit_event",rate_limit_info:$r,session_id:"fake"}'
    [ -z "$2" ] || jq -nc --arg e "$2" --arg t "$4" \
      '{type:"assistant",is_api_error_message:true,error:$e,message:{content:[{type:"text",text:$t}]},session_id:"fake"}'
    jq -nc --argjson s "$3" --arg t "$4" --argjson n "$5" \
      '{type:"result",subtype:"success",is_error:true,api_error_status:$s,terminal_reason:"api_error",num_turns:$n,
        result:$t,total_cost_usd:0.002,duration_ms:5,
        usage:{input_tokens:5,output_tokens:3,cache_read_input_tokens:0,cache_creation_input_tokens:0}}'
  } >"$out"
  [ -z "${FAKE_TIMELINE:-}" ] || printf 'end %s %s\n' "$ticket" "$station" >>"$FAKE_TIMELINE"
  exit 1
}
knob() { case "${1:-}" in "$ticket:$station" | "$ticket:$station:"*) return 0 ;; esac; return 1; }
knob_arg() { local v="${1#"$ticket:$station"}"; printf '%s' "${v#:}"; }
if knob "${FAKE_LIMIT_ONCE:-}" && [ "$n" = 1 ]; then
  runner_end "$(jq -nc --arg t "${FAKE_LIMIT_TYPE:-five_hour}" --argjson r "$(($(date +%s) + $(knob_arg "$FAKE_LIMIT_ONCE")))" \
    '{status:"rejected",resetsAt:$r,rateLimitType:$t,overageStatus:"rejected",isUsingOverage:false}')" \
    rate_limit 429 "You've hit your session limit · resets soon" 1
fi
if knob "${FAKE_LIMIT_NORESET:-}"; then
  runner_end '{"status":"rejected","rateLimitType":"overage","overageStatus":"rejected"}' rate_limit 429 "You're out of usage credits" 0
fi
if knob "${FAKE_THROTTLE_ONCE:-}" && [ "$n" = 1 ]; then
  runner_end '{"status":"rejected"}' rate_limit 429 "API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited" 0
fi
if knob "${FAKE_TRANSIENT_ONCE:-}" && [ "$n" = 1 ]; then
  runner_end "" server_error 529 "API Error: Repeated 529 Overloaded errors" 0
fi
if knob "${FAKE_NOENVELOPE:-}"; then
  k="$(knob_arg "$FAKE_NOENVELOPE")"
  if [ -z "$k" ] || [ "$n" -le "$k" ]; then
    : >"$out"
    printf 'claude: the API could not be reached\n' >"${11}"
    exit 1
  fi
fi
if knob "${FAKE_NOTJSON:-}"; then
  k="$(knob_arg "$FAKE_NOTJSON")"
  if [ -z "$k" ] || [ "$n" -le "$k" ]; then
    printf 'Error: something went wrong\n' >"$out"
    exit 1
  fi
fi
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

# The sync's station (docs/DEFECTS.md 13.4): MERGE in the implement station's
# prompt. It settles every conflict the merge left in src/ by keeping both
# sides, then writes in any word a test asserts and the code lacks — the merged
# tree then passes both branches' tests. FAKE_MERGE_FAIL leaves the markers: a
# station that never settles them. Either way the implement branch below stays
# out of it.
if [ "$station" = implement ]; then
  case "$prompt" in
    *MERGE*)
      if [ "${FAKE_MERGE_FAIL:-0}" != 1 ]; then
        # FAKE_MERGE_DROP_FIRST: the first settlement keeps this ticket's side
        # only, dropping the other branch's, and adds nothing — a regression
        # the gates have to name.
        kt=1
        case "$prompt" in
          *"MERGE — this ticket"*) [ "${FAKE_MERGE_DROP_FIRST:-0}" != 1 ] || kt=0 ;;
        esac
        for f in "$wt"/src/*.py; do
          [ -f "$f" ] || continue
          grep -qE '^(<<<<<<<|>>>>>>>) ' "$f" || continue
          awk -v kt="$kt" '/^<<<<<<< /{m=1; next} /^\|\|\|\|\|\|\| /{m=2; next} /^=======$/{m=3; next} /^>>>>>>> /{m=0; next}
            m == 0 || m == 1 || (m == 3 && kt == 1) { print }' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
        done
        if [ "$kt" = 1 ]; then
          for t in "$wt"/tests/t*.py; do
            [ -f "$t" ] || continue
            sed -n 's/.*asserts \([a-z0-9]*\).*/\1/p' "$t" | while IFS= read -r w; do
              [ -n "$w" ] && [ "$w" != feat ] || continue
              grep -q "$w" "$wt/src/app.py" 2>/dev/null || printf '# %s\n' "$w" >>"$wt/src/app.py"
            done
          done
        fi
      fi
      station=merge
      ;;
  esac
fi

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

# copy_project <from> <to> <ticket>… — a copy of a project, entered, to try a
# land in from the same built state as another row: each ticket's worktree
# repaired to point at the copy. A copied worktree still points at the
# project it was copied from, and git run in it writes that one
# (docs/FINDINGS.md #20) — which the land refuses.
copy_project() {
  local from="$1" to="$2" t
  shift 2
  rm -rf "$to" && mkdir -p "$to" && cp -R "$from/." "$to/" && cd "$to" || exit 1
  for t in "$@"; do
    git worktree repair ".aif/worktrees/$t" >/dev/null 2>&1 || true
  done
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
  "$(jq '[.entries[] | select(.station != null and .mode == "headless")] | length' .aif/state/ledgers/AIF-1.json)" "3"
eq "station rows carry the model that ran" \
  "$(jq -r '[.entries[] | select(.station == "plan")] | last | .model' .aif/state/ledgers/AIF-1.json)" "fake-model"
eq "the ready gate's pass is in the ledger" \
  "$(jq -r '[.entries[] | select(.gate == "ready")] | length > 0' .aif/state/ledgers/AIF-1.json 2>/dev/null || echo skip)" "true"
eq "one commit per accepted station, plus intake and report" \
  "$(git log --format=%s | grep -c '^aif: ')" "5"
eq "the run record reached done" "$(jq -r '.stage' tasks/AIF-1/run.json)" "done"
eq "the spend crossed into the run record as a number, not a locale string" \
  "$(jq -r '(.spent_usd | type) + ":" + ((.spent_usd > 0) | tostring)' tasks/AIF-1/run.json)" "number:true"
eq "a pre-existing skipped test did not block green" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | last | .result' .aif/state/ledgers/AIF-1.json)" "pass"
eq "and green said it allowed one" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | last | .reason' .aif/state/ledgers/AIF-1.json | grep -c 'skipped elsewhere')" "1"
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
  "$(jq '[.entries[] | select(.station == "plan")] | length' .aif/state/ledgers/AIF-2.json)" "2"
eq "the plan gate recorded a fail then a pass" \
  "$(jq -r '[.entries[] | select(.gate == "plan") | .result] | join(",")' .aif/state/ledgers/AIF-2.json)" "fail,pass"
eq "the second attempt saw the complaint" "$(grep -c 'attempt 2' tasks/AIF-2/plan.md)" "1"
eq "the report counts both attempts" \
  "$(grep -E '^\| plan \|' tasks/AIF-2/report.md | awk -F'|' '{ gsub(/ /,"",$3); print $3 }')" "2"
eq "the tests station was retried too" \
  "$(jq '[.entries[] | select(.gate == "verify-red")] | length' .aif/state/ledgers/AIF-2.json)" "2"
# A gate that rejects BEFORE its subject exists — verify-red, whose subject is
# the lock file it has not written yet — used to record the rejection with an
# empty reason, because consecutive tabs collapse in a bash IFS and every
# field after the empty subject shifted left. Two live rejections were logged
# that way before anyone noticed.
eq "every rejection says why" \
  "$(jq '[.entries[] | select(.result == "fail") | select((.reason // "") == "")] | length' .aif/state/ledgers/AIF-2.json)" "0"
eq "and the subject column did not eat it" \
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | first | .subject' .aif/state/ledgers/AIF-2.json)" ""
eq "the verify-red reason is the gate's own words" \
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | first | .reason' .aif/state/ledgers/AIF-2.json | grep -c 'REJECT')" "1"

# =============================== 3. not ready ================================
printf '\n3. a ticket that is not ready stops at intake, nothing spent\n'
fresh_project "$SANDBOX/p3"
"$AIF" _ticket-init AIF-3 >/dev/null
git add -A && git commit -qm "stub" >/dev/null
rc=0
"$AIF" work AIF-3 --no-worktree >"$OUT/run3.out" 2>&1 || rc=$?
eq "a stub: exit 1 — needs a person" "$rc" "1"
eq "says why" "$(grep -c 'scaffold stub' "$OUT/run3.out")" "1"
eq "no station ran" "$(jq '[.entries[] | select(.station != null)] | length' .aif/state/ledgers/AIF-3.json)" "0"

ticket_for AIF-6 '[{ "id": "Q-001", "question": "should the export be signed?", "default": "no", "affects": ["AC-001"] }]'
git add -A && git commit -qm "open question" >/dev/null
rc=0
"$AIF" work AIF-6 --no-worktree >"$OUT/run6.out" 2>&1 || rc=$?
eq "an open question: exit 1 — back to the analyst" "$rc" "1"
# Nothing was spent, so there is no run to report on — the card carries the
# gate's own questions instead, which is where the analyst reads them.
eq "the card carries the question and its default" \
  "$("$AIF" board show AIF-6 --json | jq -r '.comments[-1].text' | grep -c 'open question Q-001.*default: no')" "1"
eq "under the line the project manager routes on: the ticket's problem" \
  "$("$AIF" board show AIF-6 --json | jq -r '.comments[-1].text' | sed -n 1p)" \
  "blocked: ticket — not ready — the ready gate's questions are below, for the analyst"
eq "and no report was written for a run that never started" \
  "$(test -f tasks/AIF-6/report.md && echo yes || echo no)" "no"
eq "no station ran on it" "$(jq '[.entries[] | select(.station != null)] | length' .aif/state/ledgers/AIF-6.json)" "0"

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
  "$(jq '[.entries[] | select(.station == "implement")] | length' .aif/state/ledgers/AIF-5.json)" "2"
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
  "$(jq -r '[.entries[] | select(.gate == "green")] | last | .result' .aif/state/ledgers/AIF-8.json)" "error"
eq "and said the report contradicts the runner" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | last | .reason' .aif/state/ledgers/AIF-8.json |
     grep -c 'contradicts the runner')" "1"
# An un-renderable verdict is a 3, so the loop stops. Retrying implement here
# buys nothing: the suite is broken somewhere the report does not describe.
eq "implement was dispatched once, not attempts_max times" \
  "$(jq '[.entries[] | select(.station == "implement")] | length' .aif/state/ledgers/AIF-8.json)" "1"
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
  "$(jq -r '[.entries[] | select(.gate == "scope")] | last | .reason' .aif/state/ledgers/AIF-10.json)" \
  "scope: change confined to the plan (2 lines)"
eq "green's revert-recheck held — the tests do depend on the code" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | last | .reason' .aif/state/ledgers/AIF-10.json | grep -c 'depend on the implementation')" "1"
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
  "$(jq -r '[.entries[] | select(.station != null)] | first | .cost_source' .aif/state/ledgers/AIF-11.json)" "priced"
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
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | last | .result' .aif/state/ledgers/AIF-15.json)" "error"
eq "and said the suite did not run" \
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | last | .reason' .aif/state/ledgers/AIF-15.json | grep -c 'did not run')" "1"
eq "nothing was frozen" "$(test -f tasks/AIF-15/tests.lock.json && echo yes || echo no)" "no"
eq "implement was never dispatched" \
  "$(jq '[.entries[] | select(.station == "implement")] | length' .aif/state/ledgers/AIF-15.json)" "0"

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
eq "nothing was dispatched" "$(grep -c '"station"' .aif/state/ledgers/AIF-19.json .aif/state/ledgers/AIF-20.json 2>/dev/null | awk -F: '{ s += $2 } END { print s + 0 }')" "0"

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
eq "the card went back to the worker, at the top of Ready" "$(col AIF-17)" "ready"
eq "with the reason, on a sync: line" \
  "$("$AIF" board show AIF-17 --json | jq -r '.comments[-1].text' | sed -n 1p | grep -c '^sync: the suite is red')" "1"
if git show-ref --verify --quiet refs/heads/aif/AIF-17; then ok "the branch is untouched"; else bad "the branch is gone"; fi
eq "the checkout is clean" "$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')" "0"

# a conflict in code is aborted here, and the card goes back to the worker,
# which brings the branch onto main in its worktree (scenario 47)
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
eq "the card went back to the worker" "$(col AIF-17),$(grep -c 'not landed — the worker brings it onto' "$OUT/land17c.out")" "ready,1"
eq "with the reason, naming the file" "$("$AIF" board show AIF-17 --json | jq -r '.comments[-1].text' | grep -c -E 'conflicts with [^ ]+ in src/app.py')" "1"


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
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | last | .reason' .aif/state/ledgers/AIF-20.json |
     grep -c '1 pre-existing test(s) red only with them')" "1"
eq "the lock names it" "$(jq -c '.red_with_tests' tasks/AIF-20/tests.lock.json)" '["tests.t0::t0"]'
eq "and green passed once the code existed" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | last | .result' .aif/state/ledgers/AIF-20.json)" "pass"

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
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | last | .result' .aif/state/ledgers/AIF-20.json)" "error"
eq "and it names the test, on the line the ledger keeps" \
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | last | .reason' .aif/state/ledgers/AIF-20.json |
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
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | first | .result' .aif/state/ledgers/AIF-20.json)" "pass"
# Out of the implementation's reach and the new tests' doing: not a stop any
# more but a REPAIR — the tests station is dispatched in a copy without the
# implementation, twice, and when the oracle still breaks the suite the run
# stops at limits.repairs_max rather than at a human on the first attempt.
eq "green attributed it to the oracle, as a repair" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | first | .result' .aif/state/ledgers/AIF-20.json)" "repair"
eq "and said it is out of the implementation's reach" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | first | .reason' .aif/state/ledgers/AIF-20.json |
     grep -c 'out of the implementation.s reach')" "1"
eq "implement was dispatched once, not attempts_max times" \
  "$(jq '[.entries[] | select(.station == "implement")] | length' .aif/state/ledgers/AIF-20.json)" "1"
eq "the tests station was dispatched for each repair, in the copy" \
  "$(jq '[.entries[] | select(.station == "tests")] | length' .aif/state/ledgers/AIF-20.json),$(jq -r '.repairs' tasks/AIF-20/run.json)" "3,2"
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
  "$(jq -r '[.entries[] | select(.gate == "verify-red") | .result] | join(",")' .aif/state/ledgers/AIF-21.json)" "fail,pass"
eq "the retry was told where the error is" \
  "$(grep -c 'tests/t1.py(2,5): error TS2322' .aif/tmp/fake-prompt-tests-2)" "1"
eq "…all of it, not the last line alone" \
  "$(grep -c 'Source has 0 element(s) but target requires 1' .aif/tmp/fake-prompt-tests-2)" "1"
eq "…and nothing the missing implementation causes" \
  "$(grep -c 'TS2307' .aif/tmp/fake-prompt-tests-2)" "0"
eq "the red check that let the missing module through says so" \
  "$(jq -r '[.entries[] | select(.event == "check" and .phase == "red")] | last | .result' .aif/state/ledgers/AIF-21.json)" "expected"
eq "and the same check passed at green" \
  "$(jq -r '[.entries[] | select(.event == "check" and .phase == "green")] | last | .result' .aif/state/ledgers/AIF-21.json)" "pass"
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
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | last | .result + ": " + .reason' .aif/state/ledgers/AIF-21.json |
     grep -c '^error: .*fails somewhere other than this ticket.s test files')" "1"
eq "the tests station was not sent round again for it" \
  "$(jq '[.entries[] | select(.station == "tests")] | length' .aif/state/ledgers/AIF-21.json)" "1"

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
  "$(jq -r '[.entries[] | select(.gate == "green")] | first | .result' .aif/state/ledgers/AIF-21.json)" "repair"
eq "…and says the failure is the frozen tests'" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | first | .reason' .aif/state/ledgers/AIF-21.json |
     grep -c 'fails in the frozen tests, not in the implementation')" "1"
eq "implement was dispatched once, not attempts_max times" \
  "$(jq '[.entries[] | select(.station == "implement")] | length' .aif/state/ledgers/AIF-21.json)" "1"
eq "the tests station was dispatched twice more, in the copy" \
  "$(jq '[.entries[] | select(.station == "tests")] | length' .aif/state/ledgers/AIF-21.json)" "3"
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
  "$(jq -r '[.entries[] | select(.gate == "green") | .result] | join(",")' .aif/state/ledgers/AIF-21.json)" "fail,pass"
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
  "$(jq -r '[.entries[] | select(.gate == "green")] | last | .result' .aif/state/ledgers/AIF-22.json)" "error"
eq "and said the test is out of the implementation's reach" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | last | .reason' .aif/state/ledgers/AIF-22.json |
     grep -c 'out of the implementation.s reach')" "1"
eq "implement was dispatched once" \
  "$(jq '[.entries[] | select(.station == "implement")] | length' .aif/state/ledgers/AIF-22.json)" "1"
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
  "$(jq -r '[.entries[] | select(.gate == "prepare") | .result] | join(",")' .aif/state/ledgers/AIF-24.json)" "fail"
eq "with prepare's own words in the retry" "$(grep -c 'are in sync' .aif/tmp/fake-prompt-implement-2)" "1"
eq "implement was dispatched twice" \
  "$(jq '[.entries[] | select(.station == "implement")] | length' .aif/state/ledgers/AIF-24.json)" "2"
eq "the dependencies were installed from the lockfile the retry left" \
  "$(tr '\n' ' ' <deps/installed)" '"dep-a" "dep-new" '
eq "and scope let the lockfile the plan names move" \
  "$(jq -r '[.entries[] | select(.gate == "scope")] | last | .result' .aif/state/ledgers/AIF-24.json)" "pass"

# ====== 25. land, when the merge moves the dependencies =======================
#
# land ran the suite on the merge in the developer's checkout, against what
# was installed THERE — and a merge that moved package.json and its lockfile
# was judged against the install from before it: "the suite is red", the
# merge undone, a ticket with nothing wrong in it in Needs Human
# (docs/DEFECTS.md 6.3, 13.5). The verdict is reached in the ticket's
# worktree now, where the worker installed what the branch pins, so the land
# lands and says what it did not install here, with the command. Installing in
# someone's own checkout is theirs to allow: with --prepare, "prepare" runs
# here after the fast-forward, and a failure or a rewrite there is said on a
# card that has landed. The stand-in is scenario 24's npm ci, which can also be
# offline — and then, as npm ci does, leaves no install at all. t0 is red
# while the lockfile pins dep-new and the install lacks it: a test importing a
# package that is not installed. A land that lands runs in a copy of the
# project, so that the next row still has the card in Review.
printf '\n25. land, when the merge moves the dependencies: judged where they are installed, installed here when asked\n'
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

# without --prepare: judged in the worktree, where the branch's lockfile is
# installed, and landed; nothing installed here, said with the command
head_before="$(git rev-parse HEAD)"
copy_project "$SANDBOX/p25" "$SANDBOX/p25a" AIF-25
rc=0
"$AIF" land AIF-25 >"$OUT/land25a.out" 2>&1 || rc=$?
eq "without --prepare: landed, on a verdict reached where the dependencies are installed" \
  "$rc,$(git log --format=%s -1)" "0,aif: land AIF-25 — one-command user export"
eq "it says what moved and was not installed here, with the command" \
  "$(grep -c '^deps: .*not installed in this checkout.*When you need them here: bash .aif/prepare.sh' "$OUT/land25a.out")" "1"
eq "the install here was not touched" "$(installed)" '"dep-a" '
eq "the card is in Done" "$(col AIF-25)" "done"
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

# --prepare, and red anyway: main grew a test after the build. Judged in the
# worktree, where the branch's dependencies are installed — only the new test
# fails, not t0 — nothing installed anywhere, and the card goes back to the
# worker.
printf '# MAIN-1 AC-002 asserts impl2 — expects impl2\n' >tests/t2.py
git add -A && git commit -qm "main grew a test after the build" >/dev/null
head_before="$(git rev-parse HEAD)"
rc=0
"$AIF" land AIF-25 --prepare >"$OUT/land25d.out" 2>&1 || rc=$?
eq "--prepare, red on the result: exit 1, the merge undone" "$rc,$(git rev-parse HEAD)" "1,$head_before"
eq "judged in the worktree, where the branch's dependencies are installed" "$(grep -E '^(prepare|suite) ' "$OUT/land25d.out" | head -1)" \
  "suite     bash .aif/suite.sh — in .aif/worktrees/AIF-25"
eq "…so only the new test failed" "$(grep -c '(exit 0, 1 failing)' "$OUT/land25d.out")" "1"
eq "the undo installed again, from the lockfile it put back" "$(installed)" '"dep-a" '
eq "…and the reason says no install was made" \
  "$(last_comment AIF-25 | grep -c 'installed again, from the lockfile the undo put back')" "0"
eq "the checkout is clean" "$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')" "0"
eq "the card went back to the worker" "$(col AIF-25)" "ready"

# The rows that land run in copies of this checkout, main without the test.
git rm -q tests/t2.py
git commit -qm "main dropped the test" >/dev/null
"$AIF" board move AIF-25 review >/dev/null

# --prepare, offline: landed — no verdict needs an install here — and the
# install here, after the fast-forward, fails and leaves nothing installed.
# Said on the landed card and here, with the command.
copy_project "$SANDBOX/p25" "$SANDBOX/p25e" AIF-25
rc=0
PREP_OFFLINE=1 "$AIF" land AIF-25 --prepare >"$OUT/land25e.out" 2>&1 || rc=$?
eq "--prepare and the install here fails: landed all the same, exit 0" "$rc,$(col AIF-25)" "0,done"
eq "the reason is prepare's, in its own words" \
  "$(last_comment AIF-25 | grep -c 'the install here failed (exit 1)'),$(last_comment AIF-25 | grep -c 'getaddrinfo ENOTFOUND')" "1,1"
eq "…and says the install here may not match, with the command" \
  "$(last_comment AIF-25 | grep -c 'what is installed here may not match it')" "1"
eq "the terminal says so too" "$(grep -c 'what is installed here may not match it' "$OUT/land25e.out")" "1"
cd "$SANDBOX/p25" || exit 1

# --prepare, and the install here rewrites the lockfile: not the install the
# merge pinned. Landed, and the rewrite left to the developer, said.
copy_project "$SANDBOX/p25" "$SANDBOX/p25g" AIF-25
rc=0
PREP_REWRITES=1 "$AIF" land AIF-25 --prepare >"$OUT/land25g.out" 2>&1 || rc=$?
eq "--prepare and the install here rewrites the lockfile: landed, exit 0" \
  "$rc,$(col AIF-25)" "0,done"
eq "…saying which file" "$(grep -c 'the install here (bash .aif/prepare.sh) rewrote package-lock.json' "$OUT/land25g.out")" "1"
eq "the rewrite is left to the developer" "$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')" "1"
cd "$SANDBOX/p25" || exit 1

# --prepare, green: landed, with what the merged lockfile pins installed here
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
  "$(jq -r '[.entries[] | select(.gate == "verify-red") | .result] | join(",")' .aif/state/ledgers/AIF-26.json)" "fail,pass"
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

# ====== 27. a land stopped before its fast-forward lands nothing ==============
#
# land merged into the developer's checkout first, and only then installed and
# ran the suite: minutes, with npm ci, which empties node_modules before it
# fills it. A Ctrl-C there, or a supervisor's TERM, left the merge commit on
# the branch (docs/DEFECTS.md 14.8); its undo, a reset, could be cut in half by
# the KILL that follows a review session's TERM (15.1). The merge, the install
# and the verdict are made in the ticket's worktree now, and the developer's
# branch moves only at the end, by a fast-forward: a stop before it lands
# nothing — the worktree goes back on its branch, an install the land had
# started there is to be made again, and the card stays in Review, because a
# stop decides nothing. Main moves here after the build — a note, and a
# manifest and its lockfile of its own — so every land judges, and installs in
# the worktree before it does. The stand-ins wait where the land is to be
# stopped (STOP_IN) until released or killed.
#
# A signal arrives two ways, and both are sent. Ctrl-C goes to the terminal's
# whole foreground process group, so the stand-in dies with the land. A signal
# to the land's pid alone reaches bash while it waits on a child, and bash runs
# the trap only once the child returns — here a suite that came back green,
# which the stop must still beat. With no trap, that INT was not even a stop:
# bash saw the suite exit normally, took it that the suite had handled the
# INT, and the land went on to Done.
printf '\n27. a land stopped before its fast-forward lands nothing\n'
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
# Main moves on after the build, outside the ticket's record: every land below
# judges, and installs in the worktree first — tools/ moved what it had there.
printf 'notes\n' >NOTES.md
mkdir -p tools
printf '{ "dependencies": { "dep-t": "1" } }\n' >tools/package.json
cp tools/package.json tools/package-lock.json
git add -A && git commit -qm "main moved: a note, and the tools' dependencies" >/dev/null
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

# An error on the way is a stop too — here the ticket's own uncommitted file,
# which the land cannot take aside to a read-only .aif/tmp/ just before its
# fast-forward: an aif_die, through EXIT. The exit keeps its own code, and the
# file stays where it was. (Root writes into a read-only directory anyway, so
# not as root.)
if [ "$(id -u)" -ne 0 ]; then
  printf '# the analyst'"'"'s draft of the report\n' >tasks/AIF-27/report.md
  mkdir -p .aif/tmp && chmod 555 .aif/tmp
  rc=0
  "$AIF" land AIF-27 >"$OUT/land27a.out" 2>&1 || rc=$?
  chmod 755 .aif/tmp
  eq "an error after the merge: its exit 1 kept, the merge undone" "$rc,$(git rev-parse HEAD)" "1,$head_before"
  eq "…said as a stop" "$(grep -c 'stopped by the error above — nothing landed' "$OUT/land27a.out")" "1"
  eq "…the card still in Review, the checkout clean" "$(col AIF-27),$(changed)" "review,0"
  eq "…and the ticket's own file still in place" "$(cat tasks/AIF-27/report.md 2>/dev/null)" "# the analyst's draft of the report"
  rm -f tasks/AIF-27/report.md
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
  "$([ -f .aif/worktrees/AIF-27/.aif/tmp/report.xml ] && grep -c '<failure' .aif/worktrees/AIF-27/.aif/tmp/report.xml)" "0"
eq "…the card still in Review, the branch untouched" "$(col AIF-27),$(git rev-parse aif/AIF-27)" "review,$branch_sha"
eq "…the checkout clean" "$(changed)" "0"
eq "…and it said so, with the command that lands it from there" \
  "$(grep -c 'interrupted — nothing landed' "$OUT/land27b.out"),$(grep -c 'To land it: aif land AIF-27$' "$OUT/land27b.out")" "1,1"
eq "…naming no install, as none had started" "$(grep -c 'may be partial' "$OUT/land27b.out")" "0"

# Ctrl-C during the install in the worktree, as a terminal sends it: to the
# whole group, so the install dies with the land, the worktree's deps/
# emptied and not filled — and its install marker gone with it, so the next
# aif work installs again. The developer's own install here is untouched.
land_bg prepare "$OUT/land27c.out" --prepare
kill -INT -- "-$LAND_PID" 2>/dev/null
rc=0
wait "$LAND_PID" || rc=$?
eq "Ctrl-C during --prepare's install: exit 130, the merge undone" "$rc,$(git rev-parse HEAD)" "130,$head_before"
eq "…the card still in Review, the checkout clean" "$(col AIF-27),$(changed)" "review,0"
eq "…the install run once, in the worktree: the one here untouched" \
  "$(grep -c prepare "$STOP_LOG" 2>/dev/null),$([ -e deps/installed ] && echo filled || echo empty)" "1,filled"
eq "…the worktree there, its install marker gone, for the next run to install again" \
  "$([ -e .aif/worktrees/AIF-27/.git ] && echo there),$([ -e .aif/worktrees/AIF-27/.aif/tmp/prepared ] && echo kept || echo gone)" "there,gone"
eq "…nothing here to call partial" \
  "$(grep -c 'installed may be partial' "$OUT/land27c.out"),$(grep -c '^ *bash .aif/prepare.sh$' "$OUT/land27c.out")" "0,0"
eq "…and landing it again keeps --prepare" "$(grep -c 'To land it: aif land AIF-27 --prepare$' "$OUT/land27c.out")" "1"

# a supervisor's TERM, to the land's pid: the same undo, and 143
land_bg suite "$OUT/land27d.out"
kill -TERM "$LAND_PID" 2>/dev/null
touch "$STOP_GO"
rc=0
wait "$LAND_PID" || rc=$?
eq "TERM during the suite: exit 143, the merge undone, still in Review" \
  "$rc,$(git rev-parse HEAD),$(col AIF-27)" "143,$head_before,review"
eq "…said" "$(grep -c 'terminated — nothing landed' "$OUT/land27d.out")" "1"

# a verdict is not a stop: a red land puts back what it touched itself, and
# its own exit 1 does not come back through the handler as a second put-back
printf '# MAIN-1 AC-002 asserts impl2 — expects impl2\n' >tests/t2.py
git add -A && git commit -qm "main grew a test after the build" >/dev/null
head_before="$(git rev-parse HEAD)"
rc=0
"$AIF" land AIF-27 >"$OUT/land27e.out" 2>&1 || rc=$?
eq "red on the result: exit 1, nothing landed, back to the worker in Ready" \
  "$rc,$(git rev-parse HEAD),$(col AIF-27)" "1,$head_before,ready"
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
  "$(jq -r '[.entries[] | select(.gate == "plan")] | last | .reason' .aif/state/ledgers/AIF-28.json | grep -c '1 skeleton(s)')" "1"
eq "verify-red saw the test red for the marker, twice" \
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | last | .reason' .aif/state/ledgers/AIF-28.json)" \
  "verify-red: 1 new test(s) red for the right reason, twice, all criteria covered"
eq "the freeze holds the skeleton's hash, and creates nothing" \
  "$(jq -r '(.impl_frozen | has("src/feat.py") | tostring) + "," + (.impl_created | length | tostring)' tasks/AIF-28/tests.lock.json)" "true,0"
eq "green's recheck put the skeleton back and the test went red again" \
  "$(jq -r '[.entries[] | select(.gate == "green")] | last | .reason' .aif/state/ledgers/AIF-28.json | grep -c 'depend on the implementation')" "1"
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
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | map(.result) | join(",")' .aif/state/ledgers/AIF-28.json)" "fail,fail"
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
  "$(jq -r '[.entries[] | select(.gate == "plan")] | last | .result' .aif/state/ledgers/AIF-29.json)" "spec"
eq "with the plan's reason, for the analyst" \
  "$(grep -c 'AC-001 is already_true: src/app.py:2' tasks/AIF-29/report.md)" "1"
eq "one dispatch, and the tests station never ran" \
  "$(jq '[.entries[] | select(.station != null)] | length' .aif/state/ledgers/AIF-29.json)" "1"
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
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | last | .result' .aif/state/ledgers/AIF-29.json),$(grep -c 'AC-001 cannot be falsified: no literal observation decides it' tasks/AIF-29/report.md)" "spec,1"
eq "the tests station was dispatched once" \
  "$(jq '[.entries[] | select(.station == "tests")] | length' .aif/state/ledgers/AIF-29.json)" "1"

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
  "$(jq '[.entries[] | select(.station == "tests")] | length' .aif/state/ledgers/AIF-29.json)" "1"
# Without the note, the same tree is the old rejection: nothing red remains.
fresh_project "$SANDBOX/p29d"
printf 'def users():\n    return []  # impl1\n' >src/app.py
ticket_for AIF-29
git add -A && git commit -qm "ticket 29d, already built, unsaid" >/dev/null
rc=0
"$AIF" work AIF-29 --no-worktree >"$OUT/run29d.out" 2>&1 || rc=$?
eq "unsaid, it is a rejection the station gets back, and the convergence rule stops it" \
  "$rc,$(jq -r '[.entries[] | select(.gate == "verify-red")] | last | .result' .aif/state/ledgers/AIF-29.json)" "1,fail"
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
    "$(jq -r '[.entries[] | select(.gate == "verify-red") | .result] | join(",")' .aif/state/ledgers/AIF-30.json)" "fail,pass"
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
  "$(jq -r '[.entries[] | select(.gate == "green") | .result] | join(",")' .aif/state/ledgers/AIF-31.json)" "repair,pass"
eq "the tests station was dispatched twice: the freeze, and the repair" \
  "$(jq '[.entries[] | select(.station == "tests")] | length' .aif/state/ledgers/AIF-31.json)" "2"
eq "implement was dispatched once — judged again, not run again" \
  "$(jq '[.entries[] | select(.station == "implement")] | length' .aif/state/ledgers/AIF-31.json)" "1"
# The repair ran in the copy, so its prompt file went with the copy; the
# envelope the worker kept carries the prompt (the fake runner puts it there).
eq "the repair dispatch was told it was one, with the claim, and its envelope was kept as the fourth" \
  "$(jq -r '.result' tasks/AIF-31/stations/04-tests.json | grep -c '^REPAIR'),$(jq -r '.result' tasks/AIF-31/stations/04-tests.json | grep -c 'it asserts the wrong literal')" "1,1"
eq "the repaired oracle was admitted in the copy, red against the skeleton" \
  "$(jq -r '[.entries[] | select(.gate == "verify-red")] | last | .reason' .aif/state/ledgers/AIF-31.json | grep -c '^repair 1: verify-red: 1 new test(s) red')" "1"
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
  "$rc,$(jq -r '[.entries[] | select(.gate == "green") | .result] | join(",")' .aif/state/ledgers/AIF-31.json)" "1,fail,fail"
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
  "$(jq -r '[.entries[] | select(.station != null) | .station] | join(",")' .aif/state/ledgers/AIF-32.json)" "plan,tests,implement,plan,tests,implement"
eq "the replan is in the ledger" \
  "$(jq -r '[.entries[] | select(.gate == "replan")] | last | .result' .aif/state/ledgers/AIF-32.json)" "pass"
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
  "$(jq -r '[.entries[] | select(.gate == "replan") | .result] | join(",")' .aif/state/ledgers/AIF-32.json)" "pass,fail"

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
eq "three rejections, then built on the fourth attempt" "$rc,$(jq -r '[.entries[] | select(.gate == "verify-red") | .result] | join(",")' .aif/state/ledgers/AIF-37.json)" "0,fail,fail,fail,pass"
eq "the tests station was dispatched four times" "$(jq '[.entries[] | select(.station == "tests")] | length' .aif/state/ledgers/AIF-37.json)" "4"
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
# ended and the shell was between commands, and bash 3.2 lost it about one
# time in six (docs/DEFECTS.md 11.1). The tick waits in the `wait` builtin
# now, and scenario 56 sends the second on the tick's end itself; the rows
# that use this one test something else, and keep it off the tick.
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

# A worker that cannot start: the machine is asked again — the preflight
# passes, since "prepare" runs in a worktree only — and the next card is
# taken, and cannot start either. Two cards that hit the environment, fewer
# than three in a row: the loop ends on an empty Ready, rc 1, env 0, and its
# summary says how often the machine was asked (docs/DEFECTS.md 13.8;
# scenario 51 holds the cap).
"$AIF" board move AIF-58 backlog >/dev/null
for t in AIF-59 AIF-60; do
  "$AIF" board create "tasks/$t/ticket.md" --column ready >/dev/null
done
tmp="$(mktemp)"
jq '.prepare = "exit 7"' .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
rc=0
AIF_WORK_LOOP_LOGDIR="$SANDBOX/p40d-loop" "$AIF" work --loop >"$OUT/run40d.out" 2>&1 || rc=$?
eq "a worker that cannot start: the machine checked again and passing, the next card taken — both in Needs Human, exit 1" \
  "$rc,$(col AIF-59),$(col AIF-60)" "1,needs_human,needs_human"
eq "…each blocked by the environment, the machine asked again after each, the loop ending on an empty Ready" \
  "$("$AIF" board head AIF-59 | grep -c '^blocked: environment'),$("$AIF" board head AIF-60 | grep -c '^blocked: environment'),$(grep -c 'could not start (exit 3) — checking the machine again' "$OUT/run40d.out"),$(jq -r '[.rechecks, .env, .why] | map(tostring) | join(",")' "$SANDBOX/p40d-loop/summary.json")" \
  "1,1,2,2,0,Ready is empty"
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
eq "the record kept its ledger across the restart" "$(jq '[.entries[] | select(.gate == "plan")] | length' .aif/state/ledgers/AIF-42.json)" "2"
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
  "$(jq -r '[.entries[] | select(.gate == "ready")] | first | .reason' .aif/state/ledgers/AIF-53.json)" "ready: 3 rule(s) · 3 criteria · 0 decided · 0 gap(s)"

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
  "$(jq -r '[.entries[] | select(.gate == "plan" and .result == "pass")] | last | .reason' .aif/state/ledgers/AIF-70.json | grep -c '^plan: 14 implementation file(s)')" "1"
eq "the change ran past five hundred lines, and scope said so and passed it" \
  "$(jq -r '[.entries[] | select(.gate == "scope" and .result == "pass")] | last | .reason' .aif/state/ledgers/AIF-70.json | grep -c -E 'change confined to the plan \(5[0-9][0-9] lines\)')" "1"
jq '.limits.plan_files_max = 12 | .limits.diff_lines_max = 400 | .limits.revisions_max = 5' .aif/project.json >"$OUT/p45.json" && cp "$OUT/p45.json" .aif/project.json
eq "project check names each retired cap the file still sets" \
  "$("$AIF" project check 2>&1 | grep -c 'is set, and nothing reads it any more — aif retired it')" "3"
"$AIF" project upgrade >"$OUT/up45.out" 2>&1
eq "the upgrade takes them out, and says so" \
  "$(jq -c '[.limits | has("plan_files_max", "diff_lines_max", "revisions_max")]' .aif/project.json),$(grep -c 'removed — retired, nothing reads it' "$OUT/up45.out")" "[false,false,false],3"

# ====== 46. the ledger never stops anything; the ticket's own files land =====
# A ledger write that failed used to exit. A lock left behind made a gate that
# had passed exit 1 — a rejection, to the worker — and the run then died
# writing its report (docs/DEFECTS.md 13.1). And the ticket's own files met the
# branch's at land: the analyst's scaffold, left uncommitted, refused the merge
# (13.3); its empty ledger, committed after the branch was cut, conflicted
# add/add with the branch's — on aif/OPES-74 the only file the merge stopped
# on, the code merging clean (13.2). The ledger has left git since (13.13), and
# the ticket's own text, edited on the checkout's branch, conflicts the same
# way — as does the set the branch was brought up to, with a newer one there.
printf '\n46. the ledger never stops a run, a gate or a land; the ticket'"'"'s own files land with it\n'
fresh_project "$SANDBOX/p46"
ticket_for AIF-80
eq "the analyst's scaffold carries no ledger" "$([ -f tasks/AIF-80/ledger.json ] && echo yes || echo no)" "no"
git add -A && git commit -qm "ticket 46" >/dev/null
# Three things a ledger write used to die on, met in one run: a lock whose
# writer is gone, before the first row; a lock nobody signed, left after the
# plan station; and, after the tests station, a ledger that is not JSON — what
# a merge resolved by hand leaves behind.
sleep 30 &
gone=$!
kill "$gone" 2>/dev/null
wait "$gone" 2>/dev/null
mkdir -p .aif/state/ledgers/AIF-80.json.lock && printf '%s\n' "$gone" >.aif/state/ledgers/AIF-80.json.lock/pid
cat >"$SANDBOX/ledger-station.sh" <<'EOF'
#!/bin/bash
"$REAL_STATION" "$@"
rc=$?
case "$1" in
  plan) mkdir -p "$3/.aif/state/ledgers/$2.json.lock" ;;
  tests) printf '<<<<<<< ours\n' >"$3/.aif/state/ledgers/$2.json" ;;
esac
exit $rc
EOF
chmod +x "$SANDBOX/ledger-station.sh"
real_station="$AIF_WORK_STATION_CMD"
rc=0
REAL_STATION="$real_station" AIF_WORK_STATION_CMD="$SANDBOX/ledger-station.sh" \
  "$AIF" work AIF-80 --no-worktree >"$OUT/run46.out" 2>&1 || rc=$?
eq "built, whatever the ledger met" "$rc,$(jq -r '.status' tasks/AIF-80/run.json)" "0,built"
eq "no station was sent back for the ledger's trouble" "$(grep -c 'rejected' "$OUT/run46.out")" "0"
eq "the locks were taken over, not obeyed, and none is left" \
  "$([ -d .aif/state/ledgers/AIF-80.json.lock ] && echo held || echo gone)" "gone"
eq "the ledger that was not JSON was set aside beside itself, and a new one started" \
  "$(find .aif/state/ledgers -maxdepth 1 -name 'AIF-80.unreadable-*.json' | wc -l | tr -d ' '),$(jq -r '[.entries[] | select(.gate == "green")] | last | .result' .aif/state/ledgers/AIF-80.json)" "1,pass"
eq "no temp file is left beside the ledger or in the ticket's record" \
  "$(find tasks/AIF-80 .aif/state/ledgers -name '.aif-tmp-*' | wc -l | tr -d ' ')" "0"
eq "and no ledger in git: the run committed none" "$(git ls-files tasks/AIF-80 | grep -c 'ledger' || true)" "0"
# A live writer holding the ledger past the wait: the row is skipped with a
# warning, and the gate's exit is its verdict.
sleep 60 &
holder=$!
mkdir -p .aif/state/ledgers/AIF-80.json.lock && printf '%s\n' "$holder" >.aif/state/ledgers/AIF-80.json.lock/pid
rc=0
"$AIF" _gate plan AIF-80 >"$OUT/gate46.out" 2>&1 || rc=$?
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
rm -rf .aif/state/ledgers/AIF-80.json.lock
eq "a ledger held by a live writer: the gate still passes" "$rc" "0"
eq "…and the row it could not write is a warning" \
  "$([ "$(grep -c 'is held by pid' "$OUT/gate46.out")" -ge 1 ] && echo yes || echo no)" "yes"

# The analyst's scaffold, left uncommitted the way /aif-ba leaves it: the
# branch carries the ticket's record, and the land takes the local copy aside.
fresh_project "$SANDBOX/p46b"
ticket_for AIF-81
"$AIF" board create tasks/AIF-81/ticket.md --column ready >/dev/null
rc=0
"$AIF" work AIF-81 >"$OUT/run46b.out" 2>&1 || rc=$?
eq "built on its branch" "$rc,$(col AIF-81)" "0,review"
# A file of the developer's own that the merge would write over: refused
# before anything is touched, the card left in Review.
printf '# mine\n' >tests/t1.py
head_before="$(git rev-parse HEAD)"
rc=0
"$AIF" land AIF-81 >"$OUT/land46a.out" 2>&1 || rc=$?
eq "a developer's untracked file in the way: refused, nothing touched" \
  "$rc,$(col AIF-81),$(git rev-parse HEAD),$(cat tests/t1.py),$(cat tasks/AIF-81/ticket.md | grep -c '^# AIF-81')" \
  "1,review,$head_before,# mine,1"
eq "…naming it" "$(grep -c 'tests/t1.py' "$OUT/land46a.out")" "1"
rm -f tests/t1.py
rc=0
"$AIF" land AIF-81 >"$OUT/land46b.out" 2>&1 || rc=$?
eq "the analyst's uncommitted ticket: landed" "$rc,$(col AIF-81)" "0,done"
eq "the record that landed is the branch's, and no ledger rode it" \
  "$(git ls-files tasks/AIF-81 | grep -c -E '^tasks/AIF-81/(ticket\.md|run\.json|report\.md)$'),$(git ls-files tasks/AIF-81 | grep -c ledger || true)" "3,0"
eq "the local copy was taken aside, the same bytes as landed, and said so" \
  "$(find .aif/tmp -path '*/land-AIF-81-*/tasks/AIF-81/ticket.md' | wc -l | tr -d ' '),$(grep -c '^aside: .*the same as what landed' "$OUT/land46b.out")" "1,1"
eq "the checkout is clean afterwards" "$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')" "0"

# OPES-74's shape, as it stands with the ledger out of git: the analyst's
# ticket committed on the checkout's branch after the ticket's branch was cut —
# edited since, so the two copies differ — and the set moved on there too, while
# the branch carries the one its run was brought up to. An empty ledger an
# older analyst committed beside it collides with nothing now.
fresh_project "$SANDBOX/p46c"
ticket_for AIF-82
"$AIF" board create tasks/AIF-82/ticket.md --column ready >/dev/null
printf '# the set as the run found it\n' >>.aif/gates/green.sh
rc=0
"$AIF" work AIF-82 >"$OUT/run46c.out" 2>&1 || rc=$?
eq "built, its branch brought up to the set the run found, and carrying no ledger" \
  "$rc,$(col AIF-82),$(git show aif/AIF-82:.aif/gates/green.sh | tail -1),$(git ls-tree -r --name-only aif/AIF-82 -- tasks/AIF-82 | grep -c ledger || true)" \
  "0,review,# the set as the run found it,0"
built_ticket="$(git show aif/AIF-82:tasks/AIF-82/ticket.md | shasum -a 256 | cut -d' ' -f1)"
git checkout -q -- .aif/gates/green.sh
printf '# the set as it is now\n' >>.aif/gates/green.sh
printf '\nAn edit the analyst made after the build.\n' >>tasks/AIF-82/ticket.md
jq -n '{ schema: 1, ticket: "AIF-82", entries: [], accepted_at: null }' >tasks/AIF-82/ledger.json
git add -A && git commit -qm "docs(AIF-82): the ticket; the set moved on" >/dev/null
rc=0
"$AIF" land AIF-82 >"$OUT/land46c.out" 2>&1 || rc=$?
eq "the ticket added on both sides and the set changed on both: landed" "$rc,$(col AIF-82)" "0,done"
eq "the ticket's record is the branch's — the bytes that were built" \
  "$(shasum -a 256 tasks/AIF-82/ticket.md | cut -d' ' -f1)" "$built_ticket"
eq "the set is the checkout's" "$(tail -1 .aif/gates/green.sh)" "# the set as it is now"
target46="$(git symbolic-ref --short HEAD)"
eq "both settlements are said, here, on the card and in the merge commit" \
  "$(grep '^settled:  ' "$OUT/land46c.out" | grep -c "tasks/AIF-82/ticket.md (aif/AIF-82)"),$(grep '^settled:  ' "$OUT/land46c.out" | grep -c ".aif/gates/green.sh ($target46)"),$("$AIF" board show AIF-82 --json | jq -r '.comments[-1].text' | grep -c "conflicts in aif's own files, settled by owner"),$(git log -1 --format=%b | grep -c '^Settled by owner')" "1,1,1,1"
eq "one merge commit, nothing left half-merged" \
  "$(git log --format=%s -1),$([ -f .git/MERGE_HEAD ] && echo merging || echo clean),$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')" \
  "aif: land AIF-82 — one-command user export,clean,0"

# ====== 47. a branch is brought onto the branch it lands on, by the machine ===
# Tickets built side by side are cut from one HEAD, and whichever lands second
# meets the first. The land stopped on that and sent the card to a human
# (docs/DEFECTS.md 13.4). It sends it back to the worker now, which merges the
# target into the branch in its worktree, has the implement station settle a
# conflict in code, judges the merged tree with green and scope, and returns
# the card to Review; when the station cannot settle it, or a test file is in
# conflict, the ticket is built again from the target, the first build kept.
printf '\n47. a conflict at land goes back to the worker: settled by the implement station, or the ticket built again\n'
fresh_project "$SANDBOX/p47"
ticket_for AIF-90
git add -A && git commit -qm "ticket 47" >/dev/null
"$AIF" board create tasks/AIF-90/ticket.md --column ready >/dev/null
rc=0
"$AIF" work AIF-90 >"$OUT/run47a.out" 2>&1 || rc=$?
eq "built; nothing to bring it onto yet" \
  "$rc,$(col AIF-90),$(jq -r '.sync // "none"' .aif/worktrees/AIF-90/tasks/AIF-90/run.json)" "0,review,none"
# Another ticket lands meanwhile: the same line of src/app.py, and its test.
printf 'def users():\n    return []  # moved\n' >src/app.py
printf '# AIF-91 AC-001 asserts moved — expects moved\n' >tests/t2.py
git add -A && git commit -qm "aif: land AIF-91 — another ticket" >/dev/null
main47="$(git rev-parse HEAD)"
rc=0
"$AIF" land AIF-90 >"$OUT/land47a.out" 2>&1 || rc=$?
eq "the land meets the conflict: exit 1, nothing merged, the card back in Ready" \
  "$rc,$(git rev-parse HEAD),$(col AIF-90)" "1,$main47,ready"
eq "…saying so on a sync: line" \
  "$("$AIF" board show AIF-90 --json | jq -r '.comments[-1].text' | sed -n 1p | grep -c -E '^sync: aif/AIF-90 conflicts with [^ ]+ in src/app.py')" "1"
rc=0
"$AIF" work AIF-90 >"$OUT/run47b.out" 2>&1 || rc=$?
eq "the worker brings it onto main: built, back in Review" "$rc,$(col AIF-90)" "0,review"
eq "through the implement station, MERGE in its prompt, once" \
  "$(grep -l 'MERGE — this ticket' .aif/worktrees/AIF-90/.aif/tmp/fake-prompt-implement-* 2>/dev/null | wc -l | tr -d ' ')" "1"
eq "the branch holds main, and both sides' code" \
  "$(git merge-base --is-ancestor "$main47" aif/AIF-90 && echo yes),$(git show aif/AIF-90:src/app.py | grep -c -E 'impl1|moved')" "yes,2"
eq "the run record names what it was brought onto, and what the station settled" \
  "$(git show aif/AIF-90:tasks/AIF-90/run.json | jq -r --arg m "$main47" '[(.sync.onto == $m), (.sync.station | join(","))] | map(tostring) | join(",")')" "true,src/app.py"
eq "the report says where the reviewer should look" \
  "$(git show aif/AIF-90:tasks/AIF-90/report.md | grep -c 'conflicts in code, settled by the implement station')" "1"
eq "the sync is one merge commit, and no ledger rode it" \
  "$(git log --format=%s aif/AIF-90 | grep -c '^aif: sync AIF-90 onto '),$(git ls-tree -r --name-only aif/AIF-90 -- tasks/AIF-90 | grep -c ledger || true)" "1,0"
rc=0
"$AIF" land AIF-90 >"$OUT/land47c.out" 2>&1 || rc=$?
eq "then it lands, both tickets' tests green on the result" "$rc,$(col AIF-90)" "0,done"

# The station cannot settle it: three attempts, then the ticket is built again
# from main, and the first build is kept under refs/aif/archive.
fresh_project "$SANDBOX/p47b"
ticket_for AIF-92
git add -A && git commit -qm "ticket 47b" >/dev/null
"$AIF" board create tasks/AIF-92/ticket.md --column ready >/dev/null
"$AIF" work AIF-92 >"$OUT/run47d.out" 2>&1 || true
printf 'def users():\n    return []  # main moved on\n' >src/app.py
git add -A && git commit -qm "main moved the same line" >/dev/null
main47b="$(git rev-parse HEAD)"
"$AIF" land AIF-92 >"$OUT/land47d.out" 2>&1 || true
rc=0
FAKE_MERGE_FAIL=1 "$AIF" work AIF-92 >"$OUT/run47e.out" 2>&1 || rc=$?
eq "not settled: built again from main, back in Review" "$rc,$(col AIF-92)" "0,review"
eq "after the implement station's three attempts" \
  "$(grep -l 'MERGE' .aif/worktrees/AIF-92/.aif/tmp/fake-prompt-implement-* 2>/dev/null | wc -l | tr -d ' ')" "3"
eq "the first build is kept, not lost" \
  "$(git rev-parse -q --verify refs/aif/archive/AIF-92/1 >/dev/null && echo kept)" "kept"
eq "the new build starts from main" \
  "$(git merge-base --is-ancestor "$main47b" aif/AIF-92 && echo yes),$(git show aif/AIF-92:tasks/AIF-92/run.json | jq -r --arg m "$main47b" '[.rebuilds, (.base == $m)] | map(tostring) | join(",")')" "yes,1,true"
eq "the report says it was built again, and where the first build is" \
  "$(git show aif/AIF-92:tasks/AIF-92/report.md | grep -c 'refs/aif/archive/AIF-92/1')" "1"
rc=0
"$AIF" land AIF-92 >"$OUT/land47f.out" 2>&1 || rc=$?
eq "and it lands" "$rc,$(col AIF-92)" "0,done"

# A test file in conflict is the oracle's, and no merge settles it: built again
# from main at once, no station asked.
fresh_project "$SANDBOX/p47c"
ticket_for AIF-93
git add -A && git commit -qm "ticket 47c" >/dev/null
"$AIF" board create tasks/AIF-93/ticket.md --column ready >/dev/null
"$AIF" work AIF-93 >"$OUT/run47g.out" 2>&1 || true
printf '# MAIN-3 AC-009 asserts users — expects users\n' >tests/t1.py
git add -A && git commit -qm "main wrote a test where the ticket did" >/dev/null
"$AIF" land AIF-93 >"$OUT/land47g.out" 2>&1 || true
rc=0
"$AIF" work AIF-93 >"$OUT/run47h.out" 2>&1 || rc=$?
eq "a test file in conflict: built again from main, no station asked to settle it" \
  "$rc,$(col AIF-93),$(grep -l 'MERGE' .aif/worktrees/AIF-93/.aif/tmp/fake-prompt-implement-* 2>/dev/null | wc -l | tr -d ' ')" "0,review,0"
eq "…saying why" "$(git show aif/AIF-93:tasks/AIF-93/run.json | jq -r '.rebuild_why' | grep -c 'in test files')" "1"

# A settlement that drops the other side: the merged tree loses main's
# behaviour, and green names main's test — which came in with the merge, so it
# is pre-existing for this ticket, not one its own tests brought — and the
# station's next attempt keeps both.
fresh_project "$SANDBOX/p47e"
ticket_for AIF-95
git add -A && git commit -qm "ticket 47e" >/dev/null
"$AIF" board create tasks/AIF-95/ticket.md --column ready >/dev/null
"$AIF" work AIF-95 >"$OUT/run47k.out" 2>&1 || true
printf 'def users():\n    return []  # moved\n' >src/app.py
printf '# AIF-96 AC-001 asserts moved — expects moved\n' >tests/t2.py
git add -A && git commit -qm "aif: land AIF-96 — another ticket" >/dev/null
"$AIF" land AIF-95 >"$OUT/land47k.out" 2>&1 || true
rc=0
FAKE_MERGE_DROP_FIRST=1 "$AIF" work AIF-95 >"$OUT/run47l.out" 2>&1 || rc=$?
eq "main's side dropped: rejected, then settled on the next attempt" \
  "$rc,$(col AIF-95),$(grep -l 'MERGE' .aif/worktrees/AIF-95/.aif/tmp/fake-prompt-implement-* 2>/dev/null | wc -l | tr -d ' ')" "0,review,2"
again47="$(grep -l 'MERGE, again — the merged tree was rejected' .aif/worktrees/AIF-95/.aif/tmp/fake-prompt-implement-* 2>/dev/null | sed -n 1p)"
eq "green named main's test as the pre-existing suite broken, not as this ticket's oracle" \
  "$(grep -c 'AIF-96 AC-001 t2 (failure) — the pre-existing suite broke' "$again47" 2>/dev/null),$(grep -c 'REPAIR' "$again47" 2>/dev/null)" "1,0"

# The target moved somewhere else entirely: the branch takes it in on its way
# back to Review, merged clean, judged again, no station asked.
fresh_project "$SANDBOX/p47d"
ticket_for AIF-94
git add -A && git commit -qm "ticket 47d" >/dev/null
"$AIF" board create tasks/AIF-94/ticket.md --column ready >/dev/null
"$AIF" work AIF-94 >"$OUT/run47i.out" 2>&1 || true
printf 'notes\n' >NOTES.md
git add -A && git commit -qm "main moved elsewhere" >/dev/null
main47d="$(git rev-parse HEAD)"
"$AIF" board move AIF-94 ready >/dev/null
rc=0
"$AIF" work AIF-94 >"$OUT/run47j.out" 2>&1 || rc=$?
eq "merged clean on its way back to Review, no station asked" \
  "$rc,$(col AIF-94),$(grep -l 'MERGE' .aif/worktrees/AIF-94/.aif/tmp/fake-prompt-implement-* 2>/dev/null | wc -l | tr -d ' ')" "0,review,0"
eq "the branch holds main, and the report says it merged clean" \
  "$(git merge-base --is-ancestor "$main47d" aif/AIF-94 && echo yes),$(git show aif/AIF-94:tasks/AIF-94/report.md | grep -c 'merged into the branch, clean')" "yes,1"

# ====== 48. the claim, the carry-in, the loop's summary, and a hang-up ========
#
# Four things a supervisor leans on, each read against the code and found
# wanting (docs/AUTOPILOT-RESEARCH.md §6.11). The claim: the move to In
# Progress said that work was happening, not where, and on a Trello board
# shared by two machines a live remote worker looked exactly like a card
# dragged by hand — the run lock that knows the pid is in one machine's .aif
# (docs/DEFECTS.md 14.4). The card's first comment is now `taken: <host> pid
# <pid> at <time> — aif work`, and the report after it is still the head. The
# carry-in: on the local board the checkout is canonical for the ticket's
# text, as the card is on Trello, and a rework committed there never reached
# a branch that already carried a ticket — round two resumed at done and the
# old build went to Review (13.6); the ticket alone is carried in now, never
# the checkout's stale run record over the branch's, and the run restarts on
# it. The summary: the loop's exit code says how it ENDED, not what the board
# holds — rc 0 with a card still in Ready, rc 1 with nothing taken — so a
# parent reads summary.json, in the directory AIF_WORK_LOOP_LOGDIR names
# (14.3). The hang-up: nothing in aif handled HUP, and a closed window left
# its worker building for nobody; a terminal sends it to the whole process
# group, and the worker ends in 129 with its card saying so (14.8).
printf '\n48. the worker says who took a card, carries a rework in, sums the loop up, and ends on a hang-up\n'
fresh_project "$SANDBOX/p48"
ticket_for AIF-100
git add -A && git commit -qm "ticket 48" >/dev/null
"$AIF" board create tasks/AIF-100/ticket.md --column ready >/dev/null
# The host the claim names is the worker's `hostname -s`, with its fallbacks.
host48="$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf '%s' "${HOSTNAME:-?}")"
host48="$(printf '%s' "$host48" | tr -d '[:space:]')"
n_comments() { "$AIF" board show "$1" --json | jq -r '.comments | length'; }
first_line() { "$AIF" board show "$1" --json | jq -r --argjson i "$2" '.comments[$i].text' | sed -n 1p; }
rc=0
"$AIF" work AIF-100 >"$OUT/run48a.out" 2>&1 || rc=$?
eq "built in a worktree, the card in Review" "$rc,$(col AIF-100)" "0,review"
eq "two comments: the claim, then the report" "$(n_comments AIF-100)" "2"
eq "the claim: taken on this host, a pid, a UTC time, by the worker" \
  "$(first_line AIF-100 0 | grep -cE '^taken: [^ ]+ pid [0-9]+ at [0-9T:Z-]+ — aif work( · alive at [0-9T:Z-]+)?$'),$(first_line AIF-100 0 | grep -c "^taken: ${host48:-?} pid "),$("$AIF" board show AIF-100 --json | jq -r '.comments[0].by')" "1,1,aif work"
eq "…and the report after it is still the head" "$(first_line AIF-100 1),$("$AIF" board head AIF-100)" "# AIF-100 — built,# AIF-100 — built"

# The analyst adds a criterion in the checkout and commits it; the card goes
# back to Ready. The branch already carries a ticket — where the rework used
# to be lost. The fake station's attempt counters live in the worktree, and
# are reset as scenario 6 resets them in place.
ticket_for AIF-100 '[]' ',
    { "id": "AC-002", "surface": "export",
      "given": "the export ran", "when": "the output is read",
      "then": "writes the manifest marker", "expect": "impl2" }'
git add -A && git commit -qm "AIF-100 reworked in the checkout" >/dev/null
"$AIF" board move AIF-100 ready >/dev/null
rm -f .aif/worktrees/AIF-100/.aif/tmp/fake-*.count
rc=0
"$AIF" work AIF-100 >"$OUT/run48b.out" 2>&1 || rc=$?
eq "round two: built, back in Review" "$rc,$(col AIF-100)" "0,review"
eq "the ticket was carried into the worktree, and the run restarted on it" \
  "$(grep -c 'the ticket changed in the checkout since the last run — carried in' "$OUT/run48b.out"),$(grep -c 'restart.*the ticket changed' "$OUT/run48b.out")" "1,1"
eq "the branch's ticket is the checkout's, byte for byte" \
  "$(git show aif/AIF-100:tasks/AIF-100/ticket.md | shasum -a 256 | cut -d' ' -f1)" "$(shasum -a 256 tasks/AIF-100/ticket.md | cut -d' ' -f1)"
eq "and the plan on the branch covers both criteria" \
  "$(git show aif/AIF-100:tasks/AIF-100/plan.md | sed -n '/^<!-- aif:meta$/,/^-->$/p' | sed '1d;$d' | jq -r '.ac_coverage | keys | join(",")')" "AC-001,AC-002"
eq "four comments — a claim and a report per run — and the head is the report" "$(n_comments AIF-100),$("$AIF" board head AIF-100)" "4,# AIF-100 — built"
"$AIF" board move AIF-100 ready >/dev/null
rc=0
"$AIF" work AIF-100 >"$OUT/run48c.out" 2>&1 || rc=$?
eq "a third run with the ticket unchanged: nothing carried in, resumed at done" \
  "$rc,$(grep -c 'carried in' "$OUT/run48c.out"),$(grep -c 'resume.*done' "$OUT/run48c.out")" "0,0,1"

# The loop, told where its logs go, and its summary for whoever started it.
ticket_for AIF-101
ticket_for AIF-102
git add -A && git commit -qm "two for the loop" >/dev/null
"$AIF" board create tasks/AIF-101/ticket.md --column ready >/dev/null
"$AIF" board create tasks/AIF-102/ticket.md --column ready >/dev/null
rc=0
AIF_WORK_LOOP_LOGDIR="$SANDBOX/p48-loop" "$AIF" work --loop --no-tui >"$OUT/run48d.out" 2>&1 || rc=$?
eq "the loop: both built, exit 0, the logs where it was told and nowhere else" \
  "$rc,$(col AIF-101),$(col AIF-102),$(test -f "$SANDBOX/p48-loop/AIF-101.log" && test -f "$SANDBOX/p48-loop/AIF-102.log" && echo both),$(grep -c 'logs in .*p48-loop' "$OUT/run48d.out"),$(find .aif/tmp -maxdepth 1 -name 'loop-*' 2>/dev/null | wc -l | tr -d ' ')" "0,review,review,both,1,0"
S48="$SANDBOX/p48-loop/summary.json"
eq "summary.json says how it ended: two taken, two built, Ready empty" \
  "$(jq -r '[.taken, .built, .why] | map(tostring) | join(",")' "$S48")" "2,2,Ready is empty"
eq "…nothing blocked, stopped, killed or hung up on" "$(jq -c '[.blocked, .stopped, .env, .ctrl_c, .killed, .hup]' "$S48")" "[0,0,0,0,null,0]"
eq "…each run's end, its minutes a number, the file written whole" \
  "$(jq -r '[.results[] | .ticket + " " + .what] | sort | join(";")' "$S48"),$(jq -r '[.results[].minutes | type] | unique | join(",")' "$S48"),$(test -e "$S48.tmp" && echo half || echo whole)" \
  "AIF-101 built → Review;AIF-102 built → Review,number,whole"
eq "each of the loop's workers claimed its card first" "$(first_line AIF-101 0 | grep -c '^taken: '),$(first_line AIF-102 0 | grep -c '^taken: ')" "1,1"

# A hang-up, as a terminal sends one: to the worker's whole process group.
# Started under set -m, the way the loop starts its runs, so the job is a
# group of its own — a HUP to the worker's pid alone would leave its station
# sleeping out its 37 seconds. Job control goes off again at once: left on,
# bash would hand the terminal to every foreground command after this
# (docs/FINDINGS.md #24).
ticket_for AIF-103
git add -A && git commit -qm "one to hang up on" >/dev/null
"$AIF" board create tasks/AIF-103/ticket.md --column ready >/dev/null
set -m
FAKE_SLEEP_IN="AIF-103:plan" "$AIF" work AIF-103 >"$OUT/run48e.out" 2>&1 &
w48=$!
set +m
wait_for .aif/worktrees/AIF-103/.aif/tmp/fake-running-AIF-103-plan
t0="$(date +%s)"
kill -HUP -- "-$w48" 2>/dev/null
rc=0
wait "$w48" || rc=$?
secs=$(($(date +%s) - t0))
eq "HUP to the worker's group while its plan station runs: exit 129 at once, the card in Needs Human" \
  "$rc,$(col AIF-103),$([ "$secs" -lt 15 ] && echo prompt || echo "${secs}s")" "129,needs_human,prompt"
eq "…the card says a hang-up stopped it, and during which stage" \
  "$("$AIF" board head AIF-103)" "blocked: stopped — by a hang-up — the terminal closed — during plan"
eq "…the station went with it, and the run lock is released" \
  "$(pgrep -f 'fake-station.sh plan AIF-103' | wc -l | tr -d ' '),$(test -d .aif/state/runs/AIF-103 && echo held || echo released)" "0,released"

# The loop, hung up on by its own terminal — the one event that produces a
# HUP, and the one a HUP to a worker's group does not stand in for: with the
# window gone, every line the loop prints fails (EIO on the pty), and errexit
# holds inside a trap (bash 3.2, probed), so a loop that forwarded the TERM and
# went on to say "stopped (exit 143)" died of the saying — rc 1, no summary,
# a parent waiting for the file (docs/DEFECTS.md 14.8). So the loop runs on a
# pty of its own, as pty.fork gives it, its run holding a station; the master
# closed is the terminal closing: the kernel hangs up on the session leader,
# and the line is dead for whatever it prints next. Its lines from then on
# are in its loop.log, its summary says hup, and the run was stopped.
ticket_for AIF-104
git add -A && git commit -qm "one for the loop to be hung up on" >/dev/null
"$AIF" board create tasks/AIF-104/ticket.md --column ready >/dev/null
rm -rf "$SANDBOX/p48-hup"
rc="$(FAKE_SLEEP_IN="AIF-104:plan" AIF_WORK_LOOP_LOGDIR="$SANDBOX/p48-hup" \
  python3 - "$AIF" "$OUT/screen48" .aif/worktrees/AIF-104/.aif/tmp/fake-running-AIF-104-plan <<'PY3'
import os, pty, select, sys, time
aif, raw, mark = sys.argv[1:4]
pid, fd = pty.fork()
if pid == 0:
    os.execv(aif, [aif, "work", "--loop", "--no-tui"])
buf = b""
deadline = time.time() + 60
while not os.path.exists(mark) and time.time() < deadline:
    if select.select([fd], [], [], 0.2)[0]:
        try:
            buf += os.read(fd, 65536)
        except OSError:
            break
os.close(fd)
_, status = os.waitpid(pid, 0)
open(raw, "wb").write(buf)
print(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status))
PY3
)"
S48h="$SANDBOX/p48-hup/summary.json"
eq "the terminal closes over the loop while its run holds a station: exit 129, the summary written, the run stopped" \
  "$rc,$(jq -r '[.hup, .taken, .built, .stopped, .killed, .why] | map(tostring) | join(",")' "$S48h" 2>/dev/null)" \
  "129,1,1,0,1,TERM,the terminal closed (HUP) — the runs in flight were stopped too"
eq "…its lines after the hang-up are in its own log, and the card is settled as stopped by the loop's TERM" \
  "$(grep -c 'AIF-104 stopped (exit 143)' "$SANDBOX/p48-hup/loop.log"),$(grep -c '1 taken, 0 built — the terminal closed (HUP)' "$SANDBOX/p48-hup/loop.log"),$(col AIF-104),$("$AIF" board head AIF-104 | grep -c '^blocked: stopped — by a TERM signal, during plan')" "1,1,needs_human,1"
eq "…the station went with it, and nothing of the loop is left" \
  "$(pgrep -f 'fake-station.sh plan AIF-104' | wc -l | tr -d ' '),$(test -d .aif/state/runs/AIF-104 && echo held || echo released)" "0,released"

# The same with the dashboard on — the default on a terminal, and how an idle
# loop beside a shift is closed — which the row above, under --no-tui, never
# drew. The dashboard spends its seconds in its key read, the hang-up lands
# inside it, and bash puts the read's own stderr back over the handler's
# redirection on its way out: the loop died 1 on its next print, wrote no
# summary and left its lock (docs/DEFECTS.md 14.8). The master is closed a
# second and a half after the station holds, so the hang-up comes in a read.
ticket_for AIF-105
git add -A && git commit -qm "one for the dashboard to be hung up on" >/dev/null
"$AIF" board create tasks/AIF-105/ticket.md --column ready >/dev/null
rm -rf "$SANDBOX/p48-hup-tui"
rc="$(FAKE_SLEEP_IN="AIF-105:plan" AIF_WORK_LOOP_LOGDIR="$SANDBOX/p48-hup-tui" AIF_WORK_LOOP_POLL=1 TERM=xterm-256color \
  python3 - "$AIF" .aif/worktrees/AIF-105/.aif/tmp/fake-running-AIF-105-plan <<'PY3'
import fcntl, os, pty, select, signal, struct, sys, termios, time
aif, mark = sys.argv[1:3]
pid, fd = pty.fork()
if pid == 0:
    os.execv(aif, [aif, "work", "--loop", "--idle"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
deadline = time.time() + 60
while not os.path.exists(mark) and time.time() < deadline:
    if select.select([fd], [], [], 0.2)[0]:
        try:
            os.read(fd, 65536)
        except OSError:
            break
end = time.time() + 1.5
while time.time() < end:
    if select.select([fd], [], [], 0.1)[0]:
        try:
            os.read(fd, 65536)
        except OSError:
            break
os.close(fd)
status = None
end = time.time() + 90
while time.time() < end:
    r, st = os.waitpid(pid, os.WNOHANG)
    if r:
        status = st
        break
    time.sleep(0.1)
if status is None:
    os.killpg(pid, signal.SIGKILL)
    print("timeout")
else:
    print(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status))
PY3
)"
S48t="$SANDBOX/p48-hup-tui/summary.json"
eq "the dashboard on: the terminal closes over an idle loop whose run holds a station — exit 129, the summary written, the lock gone" \
  "$rc,$(jq -r '[.hup, .taken, .stopped, .killed, .idle] | map(tostring) | join(",")' "$S48t" 2>/dev/null),$(test -d .aif/state/loop && echo held || echo released)" \
  "129,1,1,1,TERM,1,released"
eq "…the run stopped and its card settled, its line and the loop's last words in its loop.log" \
  "$(col AIF-105),$(grep -c 'AIF-105 stopped (exit 143)' "$SANDBOX/p48-hup-tui/loop.log"),$(grep -c '1 taken, 0 built — the terminal closed (HUP)' "$SANDBOX/p48-hup-tui/loop.log"),$(pgrep -f 'fake-station.sh plan AIF-105' | wc -l | tr -d ' ')" \
  "needs_human,1,1,0"

# ====== 49. aif board release: Backlog cards whose dependencies are Done and landed
#
# Backlog holds the later slices of a request, waiting through depends_on, and
# one thing released them: the land of the ticket they name. A ticket merged
# by hand, a land whose move failed on the board, a dependent cut after its
# dependency landed — each left a card nothing would ever release
# (docs/AUTOPILOT-RESEARCH.md §4.4). `aif board release` is the pass that
# does, judging each card on its own (lib/release.sh): Done is not enough — a
# cancelled ticket is in Done too, its branch never merged — so a dependency
# counts when this checkout carries its land commit, and a Done card without
# one is named as the merge by hand it probably is, with the move that
# releases the dependent on purpose; a rework:, blocked: or cancelled: head
# holds the card, a person's reply under it notwithstanding, and so does the
# human's hold label; a released card goes to the bottom of Ready — the top is
# the project manager's — with a comment saying what moved it; and --dry-run
# says all of it and touches nothing.
printf '\n49. aif board release: the Backlog cards whose dependencies are Done and landed, and what holds the rest\n'
fresh_project "$SANDBOX/p49"
ticket_for AIF-110
git add -A && git commit -qm "ticket 49" >/dev/null
"$AIF" board create tasks/AIF-110/ticket.md --column ready >/dev/null
"$AIF" work AIF-110 >"$OUT/run49.out" 2>&1 || true
rc=0
"$AIF" land AIF-110 >"$OUT/land49.out" 2>&1 || rc=$?
eq "the dependency is built and landed by aif land" "$rc,$(col AIF-110),$(git log --format=%s -1)" "0,done,aif: land AIF-110 — one-command user export"
# Cut after the land, so the land released none of them: B on it; C on it,
# under a rework: comment with a person's reply after it; D on E, which a
# human moved to Done with nothing merged; F on it, labelled parked; G on a
# ticket with no card; a card already in Ready; and one in Backlog that waits
# on nothing.
ticket_for AIF-111 '[]' '' '["AIF-110"]'
ticket_for AIF-112 '[]' '' '["AIF-110"]'
ticket_for AIF-113 '[]' '' '["AIF-114"]'
ticket_for AIF-114
ticket_for AIF-115 '[]' '' '["AIF-110"]'
ticket_for AIF-116
ticket_for AIF-117
ticket_for AIF-118 '[]' '' '["AIF-119"]'
git add -A && git commit -qm "the dependents" >/dev/null
for t in AIF-111 AIF-112 AIF-113 AIF-115 AIF-117 AIF-118; do
  "$AIF" board create "tasks/$t/ticket.md" >/dev/null
done
"$AIF" board create tasks/AIF-114/ticket.md --column "done" >/dev/null
"$AIF" board create tasks/AIF-116/ticket.md --column ready >/dev/null
printf 'rework: the export must be signed — back to the analyst\n' >"$OUT/rework49.md"
"$AIF" board comment AIF-112 "$OUT/rework49.md" >/dev/null
printf 'noted — I will get to it on Monday\n' >"$OUT/reply49.md"
"$AIF" board comment AIF-112 "$OUT/reply49.md" >/dev/null
"$AIF" board label AIF-115 parked >/dev/null
rc=0
"$AIF" board release --dry-run >"$OUT/release49a.out" 2>"$OUT/release49a.err" || rc=$?
eq "--dry-run: exit 0, nothing on stderr" "$rc,$(wc -c <"$OUT/release49a.err" | tr -d ' ')" "0,0"
eq "B would be released" "$(grep -c '^AIF-111  would release → Ready (bottom)$' "$OUT/release49a.out")" "1"
eq "C is held on its rework: head, the person's reply under it notwithstanding" \
  "$(grep -c '^AIF-112  held: rework: the export must be signed — back to the analyst$' "$OUT/release49a.out")" "1"
eq "D waits on E — Done, but no land commit here: a merge by hand, named, with the move that releases D" \
  "$(grep -cF 'AIF-113  waits on AIF-114 (Done, but no "aif: land AIF-114" commit here — merged by hand? then: aif board move AIF-113 ready)' "$OUT/release49a.out")" "1"
eq "F is held by its label" "$(grep -c '^AIF-115  held: label parked$' "$OUT/release49a.out")" "1"
eq "G waits on a ticket with no card" "$(grep -c '^AIF-118  waits on AIF-119 (no card on the board)$' "$OUT/release49a.out")" "1"
eq "the landed ticket, the Done one, the card in Ready and the card with no depends_on are not named" \
  "$(grep -cE '^AIF-11[0467] ' "$OUT/release49a.out")" "0"
eq "the count line" "$(tail -1 "$OUT/release49a.out")" "would release 1 · held 2 · waiting 2 · not read 0"
eq "and nothing moved or was posted" "$(col AIF-111),$("$AIF" board show AIF-111 --json | jq -r '.comments | length')" "backlog,0"
rc=0
"$AIF" board release >"$OUT/release49b.out" 2>"$OUT/release49b.err" || rc=$?
eq "the real run: B released, the same verdicts for the rest, nothing on stderr" \
  "$rc,$(grep -c '^AIF-111  released → Ready (bottom)$' "$OUT/release49b.out"),$(tail -1 "$OUT/release49b.out"),$(wc -c <"$OUT/release49b.err" | tr -d ' ')" "0,1,released 1 · held 2 · waiting 2 · not read 0,0"
eq "B is in Ready, below the card that was there — the top is the project manager's" "$(col AIF-111),$("$AIF" board next-ready)" "ready,AIF-116"
eq "with a comment saying what moved it, by whom" \
  "$(last_comment AIF-111)|$("$AIF" board show AIF-111 --json | jq -r '.comments[-1].by')" \
  "released by aif board release: every ticket it depends on is Done and landed (AIF-110)|aif board release"
eq "C, D, F and G are where they were" "$(col AIF-112),$(col AIF-113),$(col AIF-115),$(col AIF-118)" "backlog,backlog,backlog,backlog"
eq "a second pass releases nothing more, and posts nothing" \
  "$("$AIF" board release 2>&1 | tail -1),$("$AIF" board show AIF-111 --json | jq -r '.comments | length')" "released 0 · held 2 · waiting 2 · not read 0,1"
eq "aif board head on each: the land's note, the release, the rework; nothing routable on D, F or E" \
  "$("$AIF" board head AIF-110)|$("$AIF" board head AIF-111)|$("$AIF" board head AIF-112)|$("$AIF" board head AIF-113 >/dev/null 2>&1; echo $?)|$("$AIF" board head AIF-115 >/dev/null 2>&1; echo $?)|$("$AIF" board head AIF-114 >/dev/null 2>&1; echo $?)" \
  "# AIF-110 — landed|released by aif board release: every ticket it depends on is Done and landed (AIF-110)|rework: the export must be signed — back to the analyst|1|1|1"
# The human makes the move the line named, and D is no longer the sweep's. An
# option the sweep does not take is refused before anything is read.
"$AIF" board move AIF-113 ready >/dev/null
eq "after the move the line named, D is not the sweep's any more" "$("$AIF" board release --dry-run 2>&1 | grep -c '^AIF-113 ')" "0"
rc=0
"$AIF" board release --top >"$OUT/release49c.out" 2>&1 || rc=$?
eq "an option it does not take is refused" "$rc,$(grep -c 'unknown option: --top' "$OUT/release49c.out")" "1,1"

# ====== 50. the idle loop, one loop per checkout, a loop told from elsewhere ==
#
# `aif work --loop` ends on an empty Ready, which is right for a loop a person
# starts and watches and wrong for one that runs beside a shift all night,
# while the shift moves cards into Ready. --idle looks again every
# AIF_WORK_LOOP_POLL seconds instead, and a card that left Ready and came back
# — a land's sync:, a shift's retry — is the same loop's again. One loop per
# checkout: a second raced the first for the top of Ready, and is now refused
# before its preflight, touching nothing — not even the summary in a log
# directory both were told to use. And a loop is told to stop from another
# terminal through files in its lock, read with builtins every second, not
# through a signal bash 3.2 can lose as the tick ends (docs/DEFECTS.md 11.1):
# --drain takes no new card, --stop stops the runs in flight too, each card
# saying a person stopped it. Every idle loop is waited on with a bound and
# listed for the EXIT trap, which stops whatever a failure left running.
printf '\n50. the idle loop, one loop per checkout, and a drain or a stop from another terminal\n'
fresh_project "$SANDBOX/p50"
for t in AIF-120 AIF-121 AIF-122; do
  ticket_for "$t"
done
git add -A && git commit -qm "three for the idle loop" >/dev/null
wait_count() { # <file> <pattern> <n> <secs> — until <pattern> is on <n> lines of <file>
  local i=0 c
  while [ "$i" -lt $(($4 * 10)) ]; do
    c="$(grep -c -- "$2" "$1" 2>/dev/null)" || c=0
    [ "${c:-0}" -lt "$3" ] || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
wait_col() { # <id> <column> <secs> — until the card is in that column
  local i=0
  while [ "$(col "$1")" != "$2" ] && [ "$i" -lt $(($3 * 2)) ]; do
    sleep 0.5
    i=$((i + 1))
  done
}
wait_file() { # <file> <secs>
  local i=0
  while [ ! -e "$1" ] && [ "$i" -lt $(($2 * 10)) ]; do
    sleep 0.1
    i=$((i + 1))
  done
}

L50="$SANDBOX/p50-loop"
AIF_WORK_LOOP_POLL=1 AIF_WORK_LOOP_LOGDIR="$L50" launch "$OUT/run50a.out" --idle --no-tui
l50=$loop
IDLE_PIDS="$IDLE_PIDS $l50"
wait_count "$L50/loop.log" 'Ready is empty — idle' 1 30
eq "an idle loop on an empty Ready does not end, and its lock says who it is and where its logs are" \
  "$(kill -0 "$l50" 2>/dev/null && echo alive),$(jq -r '[.pid, .host, .idle, .parallel, .logdir] | map(tostring) | join(",")' .aif/state/loop/owner.json 2>/dev/null)" \
  "alive,$l50,$host48,1,2,$(cd "$L50" && pwd -P)"

# A second loop, told the same log directory: refused before its preflight,
# and the first one's directory is as it was. Started as the first was, and
# waited for with a bound — were it not refused, it would idle too.
AIF_WORK_LOOP_POLL=1 AIF_WORK_LOOP_LOGDIR="$L50" launch "$OUT/run50a2.out" --idle --no-tui
second=$loop
IDLE_PIDS="$IDLE_PIDS $second"
rc=0
wait_exit "$second" 30 || rc=$?
eq "a second loop on the same checkout: refused, exit 3, naming the first's pid and how to stop it" \
  "$rc,$(grep -c "a loop is already running on this checkout (pid $l50, since .*— it takes the cards from Ready, and a second would race it.*aif work --loop --stop" "$OUT/run50a2.out")" "3,1"
eq "…touching nothing: no summary in the directory they share, no log directory of its own, the first still idle and said so once" \
  "$(test -e "$L50/summary.json" && echo summary || echo none),$(find .aif/tmp -maxdepth 1 -name 'loop-*' 2>/dev/null | wc -l | tr -d ' '),$(kill -0 "$l50" 2>/dev/null && echo alive),$(grep -c 'Ready is empty — idle, looking again every 1s · Ctrl-C, q or aif work --loop --drain ends the loop' "$L50/loop.log")" \
  "none,0,alive,1"

# A card comes; then, built, it comes back — as a land sends one back with
# sync:. The loop has looked at an empty Ready in between (it said it was
# idle again), so the card had left Ready, and is the loop's again.
"$AIF" board create tasks/AIF-120/ticket.md --column ready >/dev/null
wait_col AIF-120 review 60
wait_count "$L50/loop.log" 'Ready is empty — idle' 2 30
eq "a card put in Ready is taken by the idle loop and built, and the loop idles again" \
  "$(col AIF-120),$(grep -c 'loop 1 — AIF-120 ' "$OUT/run50a.out"),$(grep -c 'Ready is empty — idle' "$L50/loop.log")" "review,1,2"
"$AIF" board move AIF-120 ready >/dev/null
wait_count "$OUT/run50a.out" 'loop [0-9]* — AIF-120 ' 2 30
wait_col AIF-120 review 60
wait_count "$L50/loop.log" 'Ready is empty — idle' 3 30
eq "the same card back in Ready is the same loop's again: taken a second time, and back in Review" \
  "$(grep -c 'loop [0-9]* — AIF-120 ' "$OUT/run50a.out"),$(col AIF-120)" "2,review"

rc=0
"$AIF" work --loop --drain >"$OUT/run50a3.out" 2>&1 || rc=$?
eq "aif work --loop --drain from another terminal: exit 0, naming the loop" \
  "$rc,$(grep -c "the loop (pid $l50) takes no new card; the runs in flight finish" "$OUT/run50a3.out")" "0,1"
rc=0
wait_exit "$l50" 30 || rc=$?
eq "…the idle loop ends 0 — every card it took was built — its summary saying idle, two taken, nothing held" \
  "$rc,$(jq -r '[.idle, .taken, .built, .rechecks, (.held | length)] | map(tostring) | join(",")' "$L50/summary.json" 2>/dev/null)" \
  "0,1,2,2,0,0"
eq "…drained, by whom, and its lock gone with it" \
  "$(jq -r '.why' "$L50/summary.json" 2>/dev/null),$(test -d .aif/state/loop && echo held || echo released)" \
  "drained by Work (aif work --loop --drain) — no new card taken,released"

# A board that does not answer — a malformed card file makes the local
# board's read fail as a Trello outage would — is not the end of an idle loop.
L50b="$SANDBOX/p50-loop-b"
AIF_WORK_LOOP_POLL=1 AIF_WORK_LOOP_LOGDIR="$L50b" launch "$OUT/run50b.out" --idle --no-tui
l50=$loop
IDLE_PIDS="$IDLE_PIDS $l50"
wait_count "$L50b/loop.log" 'Ready is empty — idle' 1 30
printf '{' >.aif/board/X.json
wait_count "$L50b/loop.log" "the board's Ready column could not be read — looking again in 1s" 1 30
sleep 2.5
eq "idle, a Ready that cannot be read is read again, not the end — said once for the stretch" \
  "$(grep -c "the board's Ready column could not be read — looking again in 1s" "$L50b/loop.log"),$(kill -0 "$l50" 2>/dev/null && echo alive)" "1,alive"
rm -f .aif/board/X.json
"$AIF" board create tasks/AIF-121/ticket.md --column ready >/dev/null
wait_col AIF-121 review 60
eq "…and once it answers the loop goes on: a card put in Ready is built" "$(col AIF-121)" "review"
"$AIF" work --loop --drain >/dev/null 2>&1
rc=0
wait_exit "$l50" 30 || rc=$?
eq "…drained, it ends 0, the environment not blamed" "$rc,$(jq -r '.env' "$L50b/summary.json" 2>/dev/null)" "0,0"

# A stop from another terminal while a station holds: the run is stopped too,
# and its card says a person stopped it, as `aif work <ID> --stop` would — not
# "by a TERM signal", which reads as nobody's and is the one a shift retries.
"$AIF" board create tasks/AIF-122/ticket.md --column ready >/dev/null
L50c="$SANDBOX/p50-loop-c"
FAKE_SLEEP_IN="AIF-122:plan" FAKE_RELEASE="$SANDBOX/p50-never" AIF_WORK_LOOP_POLL=1 AIF_WORK_LOOP_LOGDIR="$L50c" \
  launch "$OUT/run50c.out" --idle --no-tui
l50=$loop
IDLE_PIDS="$IDLE_PIDS $l50"
wait_file .aif/worktrees/AIF-122/.aif/tmp/fake-running-AIF-122-plan 60
t0="$(date +%s)"
rc=0
"$AIF" work --loop --stop >"$OUT/run50c2.out" 2>&1 || rc=$?
secs=$(($(date +%s) - t0))
rc1=0
wait_exit "$l50" 30 || rc1=$?
eq "aif work --loop --stop, a station held: exit 0 once the loop has ended — 143 — in seconds" \
  "$rc,$rc1,$([ "$secs" -lt 30 ] && echo prompt || echo "${secs}s")" "0,143,prompt"
eq "…and it says how the loop ended, in the summary's words" \
  "$(grep -c "stopped the loop (pid $l50) — stopped by Work (aif work --loop --stop) — the runs in flight were stopped too" "$OUT/run50c2.out")" "1"
eq "…the card says a person stopped it, and during which stage" \
  "$(col AIF-122),$("$AIF" board head AIF-122)" "needs_human,blocked: stopped — by Work (aif work AIF-122 --stop), during plan"
eq "…the summary says TERM, the station is gone and so is the lock" \
  "$(jq -r '[.killed, .idle, .stopped] | map(tostring) | join(",")' "$L50c/summary.json" 2>/dev/null),$(pgrep -f 'fake-station.sh plan AIF-122' | wc -l | tr -d ' '),$(test -d .aif/state/loop && echo held || echo released)" \
  "TERM,1,1,0,released"

# A drain, or a TERM, that comes while the loop reads Ready: the read found a
# card, and the loop took it — the drain had answered "takes no new card",
# and the TERM had stopped every run and then started one no signal reached.
# A read that takes its time, held open by hand: a FIFO among the board's
# card files, first in the glob, blocks the loop's read until it is written,
# and a card is put in Ready behind it, under the loop's nose, before it is
# (the local board's file, edited, as no `aif` command — every one reads the
# board — could while the read is held).
ticket_for AIF-123
ticket_for AIF-124
git add -A && git commit -qm "two for a read that takes its time" >/dev/null
"$AIF" board create tasks/AIF-123/ticket.md --column backlog >/dev/null
"$AIF" board create tasks/AIF-124/ticket.md --column backlog >/dev/null
held_read() { # <loop log> <card> <drain|term> <loop pid> — the read held, the card made ready, told, let go
  local i=0 w
  wait_count "$1" 'Ready is empty — idle' 1 30
  mkfifo .aif/board/AAA.json
  while ! pgrep -f 'board/AAA.json' >/dev/null 2>&1 && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  jq '.column = "ready"' ".aif/board/$2.json" >"$OUT/held.json" && mv "$OUT/held.json" ".aif/board/$2.json"
  if [ "$3" = drain ]; then
    "$AIF" work --loop --drain >"$OUT/held-$2.out" 2>&1
  else
    kill -TERM "$4" 2>/dev/null
    sleep 0.5
  fi
  (printf '{}\n' >.aif/board/AAA.json) &
  w=$!
  i=0
  while kill -0 "$w" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  kill "$w" 2>/dev/null
  wait "$w" 2>/dev/null
  rm -f .aif/board/AAA.json
}
L50e="$SANDBOX/p50-loop-e"
AIF_WORK_LOOP_POLL=1 AIF_WORK_LOOP_LOGDIR="$L50e" launch "$OUT/run50e.out" --idle --no-tui
l50=$loop
IDLE_PIDS="$IDLE_PIDS $l50"
held_read "$L50e/loop.log" AIF-123 drain "$l50"
rc=0
wait_exit "$l50" 30 || rc=$?
eq "a drain while the loop reads Ready: the card that read found is not taken — exit 0, nothing taken, the card in Ready" \
  "$rc,$(grep -c "takes no new card" "$OUT/held-AIF-123.out"),$(jq -r '[.taken, (.why | startswith("drained by"))] | map(tostring) | join(",")' "$L50e/summary.json" 2>/dev/null),$(col AIF-123)" \
  "0,1,0,true,ready"
"$AIF" board move AIF-123 backlog >/dev/null
L50f="$SANDBOX/p50-loop-f"
AIF_WORK_LOOP_POLL=1 AIF_WORK_LOOP_LOGDIR="$L50f" launch "$OUT/run50f.out" --idle --no-tui
l50=$loop
IDLE_PIDS="$IDLE_PIDS $l50"
held_read "$L50f/loop.log" AIF-124 term "$l50"
rc=0
wait_exit "$l50" 30 || rc=$?
eq "a TERM while the loop reads Ready: no run started after it — exit 143, nothing taken, the card in Ready" \
  "$rc,$(jq -r '[.taken, .killed] | map(tostring) | join(",")' "$L50f/summary.json" 2>/dev/null),$(col AIF-124)" \
  "143,0,TERM,ready"
"$AIF" board move AIF-124 backlog >/dev/null

# A loop killed outright leaves its lock: a drain finds it dead and removes
# it; the next loop takes one over, and a drain file left in it goes too.
sleep 0 &
dead=$!
wait "$dead" 2>/dev/null || true
mkdir -p .aif/state/loop
printf '{ "pid": %s, "started_at": "2026-10-06T00:00:00Z", "logdir": null }\n' "$dead" >.aif/state/loop/owner.json
rc=0
"$AIF" work --loop --drain >"$OUT/run50d1.out" 2>&1 || rc=$?
eq "a drain told to a loop that is gone: exit 1, saying so, its lock removed" \
  "$rc,$(grep -c "no loop is running on this checkout — the one that held its lock (pid $dead) is gone" "$OUT/run50d1.out"),$(test -d .aif/state/loop && echo held || echo released)" "1,1,released"
mkdir -p .aif/state/loop
printf '{ "pid": %s, "started_at": "2026-10-06T00:00:00Z", "logdir": null }\n' "$dead" >.aif/state/loop/owner.json
printf 'Someone\n' >.aif/state/loop/drain
rc=0
AIF_WORK_LOOP_LOGDIR="$SANDBOX/p50-loop-d" "$AIF" work --loop --no-tui >"$OUT/run50d2.out" 2>&1 || rc=$?
eq "a loop lock whose loop is gone is taken over, and said; the drain left in it is not this loop's" \
  "$rc,$(grep -c "the loop that held this checkout (pid $dead) is gone; taken over" "$OUT/run50d2.out"),$(jq -r .why "$SANDBOX/p50-loop-d/summary.json" 2>/dev/null),$(test -d .aif/state/loop && echo held || echo released)" \
  "0,1,Ready is empty,released"

# What the flags refuse: idle without a loop; a drain with no loop, or of a
# ticket; a stop with neither a ticket nor --loop, which used to be a usage
# line and must not become "stop everything" for one forgotten argument.
rc=0
"$AIF" work --idle >"$OUT/run50e1.out" 2>&1 || rc=$?
rc2=0
"$AIF" work --loop --drain >"$OUT/run50e2.out" 2>&1 || rc2=$?
rc3=0
"$AIF" work AIF-120 --drain >"$OUT/run50e3.out" 2>&1 || rc3=$?
rc4=0
"$AIF" work --stop >"$OUT/run50e4.out" 2>&1 || rc4=$?
eq "refused: --idle without --loop; a drain with no loop; a drain of a ticket; --stop with no ticket, naming the loop's" \
  "$rc,$(grep -c 'only means something with --loop' "$OUT/run50e1.out"),$rc2,$(grep -c 'no loop is running on this checkout — nothing to drain' "$OUT/run50e2.out"),$rc3,$(grep -c 'aif work --loop --drain' "$OUT/run50e3.out"),$rc4,$(grep -c 'the loop: aif work --loop --stop' "$OUT/run50e4.out")" \
  "1,1,1,1,1,1,1,1"

# ====== 51. a worker that could not start: the machine asked again =========
#
# One worker that exited 3 — the environment — stopped the loop: one install
# that met the network, one 429 on the claim, and the queue was parked for
# the night (docs/DEFECTS.md 13.8). The loop now asks the machine again — its
# own preflight, in a subshell, without the suite probe, which runs once per
# loop in the developer's checkout — and goes on while that passes: at most
# three cards in Needs Human for trouble the preflight cannot see, and a stop
# at the first when it can. A worker that died in its claim, worktree or
# intake is the machine's trouble too — its handler says blocked: environment
# — and counts toward those three, never toward two in a row. Idle, a card
# the environment blocked that a person moves back is the loop's again.
printf '\n51. a worker that could not start: the machine asked again, three in a row at most\n'
fresh_project "$SANDBOX/p51"
p51="$(pwd -P)"
tmp="$(mktemp)"
jq --arg log "$SANDBOX/p51-suite-runs" \
  '.test.command = "bash .aif/suite.sh; s=$?; pwd -P >>" + ($log | @sh) + "; (exit $s)"' \
  .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
for t in AIF-130 AIF-131 AIF-132 AIF-133 AIF-134 AIF-135 AIF-136 AIF-137 AIF-138 AIF-139 AIF-140; do
  ticket_for "$t"
done
git add -A && git commit -qm "the suite says where it ran; eleven tickets" >/dev/null
for t in AIF-130 AIF-131 AIF-132 AIF-133; do
  "$AIF" board create "tasks/$t/ticket.md" --column ready >/dev/null
done
: >"$SANDBOX/p51-suite-runs"
jq '.prepare = "exit 7"' .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
rc=0
AIF_WORK_LOOP_LOGDIR="$SANDBOX/p51-a" "$AIF" work --loop --parallel 1 --no-tui >"$OUT/run51a.out" 2>&1 || rc=$?
S51="$SANDBOX/p51-a/summary.json"
eq "four cards, no worker able to start: the machine checks out twice, the third in a row stops the loop — exit 3, the fourth untaken" \
  "$rc,$(col AIF-130),$(col AIF-131),$(col AIF-132),$(col AIF-133)" "3,needs_human,needs_human,needs_human,ready"
eq "…each card blocked by the environment, the machine asked again twice and said so" \
  "$("$AIF" board head AIF-131 | grep -c '^blocked: environment — prepare failed (exit 7)'),$(grep -c 'could not start (exit 3) — checking the machine again' "$OUT/run51a.out"),$(grep -c 'could not start, but the machine checks out (preflight passed) — the loop goes on' "$OUT/run51a.out")" \
  "1,2,2"
eq "…the summary: the environment, two re-checks, the reason ending (three in a row)" \
  "$(jq -r '[.env, .rechecks, .taken, .built] | map(tostring) | join(",")' "$S51" 2>/dev/null),$(jq -r '.why' "$S51" 2>/dev/null | grep -c '^AIF-132 could not start (exit 3) — the environment, not the card; the loop takes no new card (three in a row)$')" \
  "1,2,3,0,1"
eq "…and the suite ran in this checkout once — the loop's own probe; asking the machine again does not run it" \
  "$(grep -c . "$SANDBOX/p51-suite-runs"),$(grep -cx "$p51" "$SANDBOX/p51-suite-runs")" "1,1"

# A machine whose preflight fails again: the first card stops the loop. The
# "prepare" takes the guide from this checkout, which the preflight refuses
# a run without.
"$AIF" board move AIF-133 backlog >/dev/null
for t in AIF-134 AIF-135; do
  "$AIF" board create "tasks/$t/ticket.md" --column ready >/dev/null
done
jq --arg g "$p51/.aif/guide/tests.md" '.prepare = "rm -f " + ($g | @sh) + "; exit 7"' .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
rc=0
AIF_WORK_LOOP_LOGDIR="$SANDBOX/p51-b" "$AIF" work --loop --parallel 1 --no-tui >"$OUT/run51b.out" 2>&1 || rc=$?
git checkout -- .aif/guide/tests.md
eq "a preflight that fails again: the first card that could not start stops the loop — exit 3, the next card untaken, nothing re-checked" \
  "$rc,$(col AIF-134),$(col AIF-135),$(jq -r '[.env, .rechecks] | map(tostring) | join(",")' "$SANDBOX/p51-b/summary.json" 2>/dev/null)" "3,needs_human,ready,1,0"
eq "…saying the preflight fails again" \
  "$(grep -c 'AIF-134 could not start, and the preflight fails again — the environment, not the card; the loop takes no new card' "$OUT/run51b.out")" "1"

# A worker that dies with exit 1 in its intake — the ready gate gone from its
# worktree — is labelled blocked: environment by its handler, and counts as
# the machine's: three of them stop the loop, two never do as two in a row.
"$AIF" board move AIF-135 backlog >/dev/null
for t in AIF-136 AIF-137 AIF-138 AIF-139; do
  "$AIF" board create "tasks/$t/ticket.md" --column ready >/dev/null
done
jq '.prepare = "rm -f .aif/gates/ready.sh"' .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
rc=0
AIF_WORK_LOOP_LOGDIR="$SANDBOX/p51-c" "$AIF" work --loop --parallel 1 --no-tui >"$OUT/run51c.out" 2>&1 || rc=$?
eq "workers that die in their intake: the machine's, three of them stop the loop, never two in a row — exit 3" \
  "$rc,$(col AIF-136),$(col AIF-137),$(col AIF-138),$(col AIF-139),$(grep -c 'two runs in a row' "$OUT/run51c.out")" \
  "3,needs_human,needs_human,needs_human,ready,0"
eq "…each card saying the environment, the summary two re-checks and three in a row" \
  "$("$AIF" board head AIF-136 | grep -c '^blocked: environment — the worker exited (code 1) during intake'),$(jq -r '[.env, .rechecks, .blocked] | map(tostring) | join(",")' "$SANDBOX/p51-c/summary.json" 2>/dev/null),$(jq -r '.why' "$SANDBOX/p51-c/summary.json" 2>/dev/null | grep -c '^AIF-138 could not start — the environment, not the card; the loop takes no new card (three in a row)$')" \
  "1,1,2,3,1"

# Idle: a card the environment blocked, moved back to Ready by a person once
# the machine checked out, is the same loop's again.
"$AIF" board move AIF-139 backlog >/dev/null
jq '.prepare = "exit 7"' .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
"$AIF" board create tasks/AIF-140/ticket.md --column ready >/dev/null
L51="$SANDBOX/p51-d"
AIF_WORK_LOOP_POLL=1 AIF_WORK_LOOP_LOGDIR="$L51" launch "$OUT/run51d.out" --idle --no-tui --parallel 1
l51=$loop
IDLE_PIDS="$IDLE_PIDS $l51"
wait_count "$L51/loop.log" 'AIF-140 could not start, but the machine checks out' 1 60
"$AIF" board move AIF-140 ready >/dev/null
wait_count "$L51/loop.log" 'AIF-140 could not start, but the machine checks out' 2 60
eq "idle: a card the environment blocked, moved back to Ready after the machine checked out, is taken again" \
  "$(grep -c 'loop [0-9]* — AIF-140 ' "$OUT/run51d.out"),$(col AIF-140)" "2,needs_human"
"$AIF" work --loop --drain >/dev/null 2>&1
rc=0
wait_exit "$l51" 30 || rc=$?
eq "…drained, it ends 1 — nothing it took was built — with the environment not blamed and two re-checks" \
  "$rc,$(jq -r '[.idle, .taken, .env, .rechecks] | map(tostring) | join(",")' "$L51/summary.json" 2>/dev/null)" "1,1,2,0,2"
git checkout -- .aif/project.json

# ====== 52. aif work --status: what this machine knows of a run ===============
#
# A shift that finds a card In Progress with nobody seeming to build it
# (docs/AUTOPILOT-RESEARCH.md §6.3, R2–R4) needs what only this machine
# knows: whether the card's worker is alive, what its run record says,
# whether the build is on its branch — and what a worker killed outright left
# running in its worktree (docs/DEFECTS.md 14.1), found by the process group
# it led, and never by a group that is not its: a lock whose pid the system
# has handed to an unrelated program that leads a group of its own would
# otherwise list that program, and a requeue would stop it. A build of a
# ticket reworked since is not a build of the ticket. Offline throughout: a
# board that could not answer changes nothing.
printf '\n52. aif work --status: what this machine knows of a run, a dead worker'"'"'s station included\n'
fresh_project "$SANDBOX/p52"
st52() { "$AIF" work --status "$@" --json 2>/dev/null; }
eq "nothing here yet: an empty array, and a line that says so" \
  "$(st52 | jq -c .),$("$AIF" work --status 2>&1)" "[],no runs on this machine"
ticket_for AIF-150
ticket_for AIF-151
git add -A && git commit -qm "two for --status" >/dev/null
"$AIF" board create tasks/AIF-150/ticket.md --column ready >/dev/null
"$AIF" board create tasks/AIF-151/ticket.md --column ready >/dev/null

rc=0
"$AIF" work AIF-150 >"$OUT/run52a.out" 2>&1 || rc=$?
eq "a built ticket: built, its branch there, the report the build's, the record on the branch, no lock" \
  "$rc,$(st52 AIF-150 | jq -r '[.class, .branch.exists, .report.head, .run.where, .run.status, .run.branch_status, .lock.held] | map(tostring) | join(",")')" \
  "0,built,true,# AIF-150 — built,worktree,built,built,false"
eq "…and as a line: the id, the class, why" \
  "$("$AIF" work --status AIF-150)" "AIF-150  built — the run built it; its report is on branch aif/AIF-150"

# A worker killed outright mid-station. Started under set -m, as the loop
# starts its runs, so it leads a group of its own and its station stays in
# it; job control off again at once (docs/FINDINGS.md #24). Reaped before it
# is read: a zombie still answers kill -0. The station holds its dispatch
# with a `sleep 41` of its own — a process of the group that carries no
# ticket in its command line, which only the group can name.
set -m
FAKE_SLEEP_IN="AIF-151:plan" FAKE_SLEEP_SECS=41 "$AIF" work AIF-151 >"$OUT/run52b.out" 2>&1 &
w52=$!
set +m
wait_for .aif/worktrees/AIF-151/.aif/tmp/fake-running-AIF-151-plan
kill -9 "$w52" 2>/dev/null
wait "$w52" 2>/dev/null
S52="$(st52 AIF-151)"
eq "a worker killed by kill -9 mid-plan: interrupted, its lock held and its pid gone, the record running at plan" \
  "$(printf '%s' "$S52" | jq -r '[.class, .lock.held, .lock.live, .lock.pid, .lock.pid_alive, .lock.phase, .lock.stage, .run.where, .run.status, .run.stage] | map(tostring) | join(",")')" \
  "interrupted,true,false,$w52,false,run,plan,worktree,running,plan"
eq "…its station still running, and the sleep under it, listed with the group the dead worker led" \
  "$(printf '%s' "$S52" | jq -r --argjson p "$w52" '[.lock.orphans[] | select(.pgid == $p and (.command | contains("fake-station.sh plan AIF-151")))] | length'),$(printf '%s' "$S52" | jq -r --argjson p "$w52" '[.lock.orphans[] | select(.pgid == $p and .command == "sleep 41")] | length')" "1,1"
eq "…said for a person" \
  "$(printf '%s' "$S52" | jq -r .why | grep -cE "^its worker \(pid $w52\) is gone mid-plan, attempt 1; [0-9]+ process(es)? still in its group$")" "1"
# --status reads and never stops anything: the harness stops the group.
kill -TERM -- "-$w52" 2>/dev/null
i=0
while pgrep -f 'fake-station.sh plan AIF-151' >/dev/null 2>&1 && [ "$i" -lt 100 ]; do
  sleep 0.1
  i=$((i + 1))
done
eq "…and its group stopped, nothing of it is listed" \
  "$(st52 AIF-151 | jq -r '.lock.orphans | length')" "0"

# A dead worker's lock whose pid the system has handed to an unrelated
# program: a sleep, leading a group of its own. Not a worker, and nothing of
# its group is the dead worker's — the pid of a group with a member is never
# handed out again, so a live pid means the worker's own group is empty.
set -m
sleep 60 &
s52=$!
set +m
mkdir -p .aif/state/runs/AIF-152
printf '{ "ticket": "AIF-152", "pid": %s, "started_at": "2026-10-02T00:00:00Z" }\n' "$s52" >.aif/state/runs/AIF-152/owner.json
eq "a lock whose pid an unrelated program leading its own group now holds: not live, its group not listed, the program untouched" \
  "$(st52 AIF-152 | jq -c '[.lock.live, .lock.pid_alive, .lock.orphans]'),$(kill -0 "$s52" 2>/dev/null && echo alive)" "[false,true,[]],alive"
kill "$s52" 2>/dev/null
wait "$s52" 2>/dev/null

# The ticket reworked in the checkout after its build: the build on the
# branch is of the ticket before. Nobody on it with no lock; with a dead lock
# held, a worker took the card for the rework and died before its intake.
ticket_for AIF-150 '[]' ',
    { "id": "AC-002", "surface": "export",
      "given": "the export ran", "when": "the output is read",
      "then": "writes the manifest marker", "expect": "impl2" }'
git add -A && git commit -qm "AIF-150 reworked in the checkout" >/dev/null
eq "reworked after its build, no lock: not built — the build is of the ticket before" \
  "$(st52 AIF-150 | jq -r '[.class, .run.ticket_changed, .run.branch_status] | map(tostring) | join(",")')" "settled_running,true,built"
sleep 0 &
dead52=$!
wait "$dead52" 2>/dev/null
mkdir -p .aif/state/runs/AIF-150
printf '{ "ticket": "AIF-150", "pid": %s, "started_at": "2026-10-02T00:00:00Z" }\n' "$dead52" >.aif/state/runs/AIF-150/owner.json
eq "…and with a dead lock held: interrupted, not built" \
  "$(st52 AIF-150 | jq -r '[.class, .lock.held, .lock.live, (.lock.orphans | length)] | map(tostring) | join(",")')" "interrupted,true,false,0"

eq "an id with nothing of it on this machine: none" \
  "$(st52 AIF-999 | jq -r '[.class, .lock.held, .worktree.exists, .branch.exists, .run.where] | map(tostring) | join(",")')" "none,false,false,false,null"
eq "no id: every ticket with a lock, a worktree or a branch here, in order" \
  "$(st52 | jq -r '[.[] | .ticket + ":" + .class] | join(" ")')" "AIF-150:interrupted AIF-151:interrupted AIF-152:interrupted"

# A --no-worktree run builds in this checkout, and its record is here, its
# worktree field the checkout's own path. A worktree run's record here is
# the copy a land merged back — an earlier round's — and is not read as one.
ticket_for AIF-153
git add -A && git commit -qm "one to build in place" >/dev/null
"$AIF" board create tasks/AIF-153/ticket.md --column ready >/dev/null
rc=0
"$AIF" work AIF-153 --no-worktree >"$OUT/run52e.out" 2>&1 || rc=$?
mkdir -p tasks/AIF-154
git show aif/AIF-151:tasks/AIF-151/run.json >tasks/AIF-154/run.json
eq "a --no-worktree build: read from this checkout, built, no branch for aif land; a worktree run's record here is not read" \
  "$rc,$(st52 AIF-153 | jq -r '[.class, .run.where, .branch.exists] | map(tostring) | join(",")'),$(st52 AIF-154 | jq -r '[.class, .run.where] | map(tostring) | join(",")')" \
  "0,built,checkout,false,none,null"
rm -rf tasks/AIF-154

# Offline: a board that would refuse every call — Trello, and no credential.
jq '.board.kind = "trello"' .aif/project.json >"$OUT/p52-project.json" && cp "$OUT/p52-project.json" .aif/project.json
rc=0
"$AIF" work --status AIF-151 >"$OUT/run52c.out" 2>&1 || rc=$?
eq "asks no board: on a Trello board with no credential it answers the same" \
  "$rc,$(grep -c '^AIF-151  interrupted — ' "$OUT/run52c.out")" "0,1"
git checkout -- .aif/project.json
rc=0
"$AIF" work --status --loop >"$OUT/run52d.out" 2>&1 || rc=$?
rc2=0
"$AIF" work AIF-150 --json >/dev/null 2>&1 || rc2=$?
eq "--status is refused beside --loop, and --json without --status" \
  "$rc,$(grep -c 'not with --loop' "$OUT/run52d.out"),$rc2" "1,1,1"

# ====== 53. one taker wins a dead lock; a run taken over three times stops ===
# docs/DEFECTS.md 14.5. A dead lock was taken over by `rm -rf` then `mkdir`,
# and two runs that found it in the same instant both removed it and both
# made it again, each believing it held the lock — the run lock, the loop's
# and the shift's alike. Two takers here, each a bash with lib/ sourced,
# spinning on one file and released by it at once, many times over: exactly
# one holds the lock each time, signed in its own name, nothing set aside
# left behind. The loop lock is raced the most (no orphans to look for); the
# run lock, whose takeover first looks for what its dead worker left, fewer
# times. Then the takeover count in the run record: a resume keeps it, and
# at three the next worker stops the run instead of resuming it.
#
# Released at the very same instant, the two old takers removed and made the
# lock again side by side, and one mkdir lost: the old order failed only when
# one taker lagged the other by about one rm and one mkdir (a few ms) — its
# look still at the dead lock, its `rm -rf` after the other's mkdir. So the
# second taker spins a little longer each trial, 0 to about 20 ms (a bash
# 3.2 loop step is about 2.5 µs here, probed), and the trials walk that
# window.
printf '\n53. one taker wins a dead lock, and a run taken over three times stops\n'
fresh_project "$SANDBOX/p53"
p53="$(pwd -P)"
# race53 <loop|run> <trials> — the trials, by number, where the takers did
# not end with exactly one holder: two winners, none, or a lock signed by
# someone else; an aside left counts as a failure too. Empty is every trial
# right.
race53() {
  local kind="$1" trials="$2" i d w ra rb pa pb won owner wrong="" racers off
  for i in $(seq 1 "$trials"); do
    racers=""
    rm -rf .aif/state/loop .aif/state/runs/AIF-530 .aif/state/.loop.dead.* .aif/state/runs/.AIF-530.dead.* "$OUT"/race53.*
    sleep 0 &
    d=$!
    wait "$d" 2>/dev/null
    if [ "$kind" = loop ]; then
      mkdir -p .aif/state/loop
      printf '{ "pid": %s, "started_at": "2026-10-02T00:00:00Z", "logdir": null }\n' "$d" >.aif/state/loop/owner.json
    else
      mkdir -p .aif/state/runs/AIF-530
      printf '{ "ticket": "AIF-530", "pid": %s, "started_at": "2026-10-02T00:00:00Z" }\n' "$d" >.aif/state/runs/AIF-530/owner.json
    fi
    for w in a b; do
      off=0
      [ "$w" = a ] || off=$(((i % 10) * 800))
      /bin/bash -c '
        set -uo pipefail
        . "$1/lib/common.sh"; . "$1/lib/paths.sh"; . "$1/lib/cmd_work.sh"
        : >"$2.ready.$3"
        while [ ! -f "$2.go" ]; do :; done
        j=0
        while [ "$j" -lt "$6" ]; do j=$((j + 1)); done
        rc=0
        if [ "$4" = loop ]; then _aif_work_loop_lock "$5" 1 0 2>/dev/null || rc=$?
        else _aif_work_lock "$5" AIF-530 2>/dev/null || rc=$?; fi
        printf "%s %s\n" "$rc" "$$" >"$2.$3"' _ "$ROOT" "$OUT/race53" "$w" "$kind" "$p53" "$off" &
      racers="$racers $!"
    done
    wait_for "$OUT/race53.ready.a"
    wait_for "$OUT/race53.ready.b"
    : >"$OUT/race53.go"
    for w in $racers; do
      wait_exit "$w" 30 || true
    done
    { read -r ra pa <"$OUT/race53.a"; } 2>/dev/null || ra=x
    { read -r rb pb <"$OUT/race53.b"; } 2>/dev/null || rb=x
    won=""
    [ "$ra" != 0 ] || won="$won$pa"
    [ "$rb" != 0 ] || won="$won${won:+ }$pb"
    if [ "$kind" = loop ]; then
      owner="$(jq -r .pid .aif/state/loop/owner.json 2>/dev/null)"
    else
      owner="$(jq -r .pid .aif/state/runs/AIF-530/owner.json 2>/dev/null)"
    fi
    if [ "$won" != "$owner" ] || [ -n "$(find .aif/state .aif/state/runs -maxdepth 1 -name '.*.dead.*' 2>/dev/null)" ]; then
      wrong="$wrong $i"
    fi
  done
  printf '%s' "${wrong# }"
}
eq "the loop lock: two takers released at once over a dead lock, 40 times — one holder each time, in its own name" \
  "$(race53 loop 40)" ""
eq "the run lock, its orphans looked for first: the same, 8 times" "$(race53 run 8)" ""
rm -rf .aif/state/loop .aif/state/runs/AIF-530

# A dead holder's pid handed out again, to another `aif work` — a loop's
# worker on another card, most likely — which the command glob matches: it
# started after the lock was signed, so it is not the holder.
(exec -a "aif work AIF-999 --loop" sleep 61.3) &
re53=$!
mkdir -p .aif/state/runs/AIF-532 .aif/state/loop
printf '{ "ticket": "AIF-532", "pid": %s, "started_at": "2026-10-02T00:00:00Z" }\n' "$re53" >.aif/state/runs/AIF-532/owner.json
printf '{ "pid": %s, "started_at": "2026-10-02T00:00:00Z", "logdir": null }\n' "$re53" >.aif/state/loop/owner.json
rc=0
"$AIF" work --loop --drain >"$OUT/run53r.out" 2>&1 || rc=$?
eq "a lock whose pid now runs an aif work started after the lock was signed: the run lock not live, the loop lock gone" \
  "$("$AIF" work --status AIF-532 --json | jq -r '[.lock.live, .lock.pid_alive] | map(tostring) | join(",")'),$rc,$(grep -c "the one that held its lock (pid $re53) is gone" "$OUT/run53r.out"),$(test -d .aif/state/loop && echo held || echo removed)" \
  "false,true,1,1,removed"
kill "$re53" 2>/dev/null
wait "$re53" 2>/dev/null
rm -rf .aif/state/runs/AIF-532

# The takeover's mark, `takeover` inside the dead lock: one a taker holds
# right now refuses the next taker and leaves the dead lock as it is; one two
# minutes old was left by a taker that died, and is nobody's.
sleep 0 &
d53=$!
wait "$d53" 2>/dev/null
mkdir -p .aif/state/loop/takeover
printf '{ "pid": %s, "started_at": "2026-10-02T00:00:00Z", "logdir": null }\n' "$d53" >.aif/state/loop/owner.json
loop53() { /bin/bash -c '. "$1/lib/common.sh"; . "$1/lib/paths.sh"; . "$1/lib/cmd_work.sh"; _aif_work_loop_lock "$2" 1 0' _ "$ROOT" "$p53"; }
rc=0
loop53 >"$OUT/run53m.out" 2>&1 || rc=$?
m53="$rc,$(jq -r .pid .aif/state/loop/owner.json)"
t53=$(($(date +%s) - 180))
touch -t "$(date -r "$t53" '+%Y%m%d%H%M.%S' 2>/dev/null || date -d "@$t53" '+%Y%m%d%H%M.%S')" .aif/state/loop/takeover
rc=0
loop53 >"$OUT/run53n.out" 2>&1 || rc=$?
eq "a takeover mark held now: the next taker refused, the dead lock left; a mark two minutes old: taken over" \
  "$m53,$rc,$(grep -c "(pid $d53) is gone; taken over" "$OUT/run53n.out"),$(test -d .aif/state/loop/takeover && echo mark || echo clean)" \
  "1,$d53,0,1,clean"
rm -rf .aif/state/loop

ticket_for AIF-531
git add -A && git commit -qm "one to take over" >/dev/null
"$AIF" board create tasks/AIF-531/ticket.md --column ready >/dev/null
# take53 <out> — a worker on AIF-531 in a group of its own, as the loop starts
# one, held at plan, and killed outright with its whole group once its station
# is in: what a machine that died leaves — the lock, the record at plan, the
# card In Progress, and nothing running.
take53() {
  rm -f .aif/worktrees/AIF-531/.aif/tmp/fake-running-AIF-531-plan
  set -m
  FAKE_SLEEP_IN="AIF-531:plan" FAKE_SLEEP_SECS=45 "$AIF" work AIF-531 >"$1" 2>&1 &
  w53=$!
  set +m
  wait_for .aif/worktrees/AIF-531/.aif/tmp/fake-running-AIF-531-plan
  kill -9 -- "-$w53" 2>/dev/null
  wait "$w53" 2>/dev/null
}
tk53() { jq -r '.takeovers // 0' .aif/worktrees/AIF-531/tasks/AIF-531/run.json 2>/dev/null; }
take53 "$OUT/run53a.out"
n1="$(tk53)"
take53 "$OUT/run53b.out"
n2="$(tk53)"
take53 "$OUT/run53c.out"
eq "three workers killed outright in turn: the second and third took the lock over and resumed, each counted" \
  "$n1,$n2,$(tk53),$(grep -c 'is gone; taken over' "$OUT/run53b.out"),$(grep -c 'takeover 2 of the 3 a run may have' "$OUT/run53c.out")" \
  "0,1,2,1,1"
# A person settles it and puts it back: a resume that is no takeover keeps
# the count.
"$AIF" work AIF-531 --stop >/dev/null 2>&1
"$AIF" board move AIF-531 ready >/dev/null
take53 "$OUT/run53d.out"
n4="$(tk53)"
take53 "$OUT/run53e.out"
eq "…a resume after a --stop keeps the count; the next takeover is the third" \
  "$n4,$(grep -c 'taken over' "$OUT/run53d.out"),$(tk53)" "2,0,3"
rc=0
"$AIF" work AIF-531 >"$OUT/run53f.out" 2>&1 || rc=$?
eq "a fourth takeover stops the run instead of resuming it: exit 1, the card in Needs Human saying why" \
  "$rc,$(col AIF-531),$("$AIF" board head AIF-531 2>/dev/null)" \
  "1,needs_human,blocked: run — taken over 3 times; its workers died the same way each time — read the run before another"
eq "…no station dispatched, and --status reads a stopped run that was taken over three times" \
  "$(grep -c '^station ' "$OUT/run53f.out"),$("$AIF" work --status AIF-531 --json | jq -r '[.class, .run.takeovers, .lock.held] | map(tostring) | join(",")')" \
  "0,stopped,3,false"

# ====== 54. what a dead worker left: named, stopped before a takeover ========
# docs/DEFECTS.md 14.1 and 15.4. The run lock records the worker's group and,
# while a station runs, the station's own pid, written by the station's
# process as it starts. A worker killed outright leaves its station running;
# what it left is named by that group, that pid and this clone's worktree —
# never by the prompt alone, which a second clone building the same id
# carries too — and a takeover TERMs it and waits before it takes the lock,
# or refuses with exit 3 while something still runs there.
printf '\n54. what a dead worker left is named, and stopped before its lock is taken over; another clone'"'"'s station is not\n'
fresh_project "$SANDBOX/p54"
p54="$(pwd -P)"
st54() { "$AIF" work --status "$@" --json 2>/dev/null; }
for t in AIF-540 AIF-541 AIF-542 AIF-543; do
  ticket_for "$t"
done
git add -A && git commit -qm "four for orphans" >/dev/null
for t in AIF-540 AIF-541 AIF-542; do
  "$AIF" board create "tasks/$t/ticket.md" --column ready >/dev/null
done

# Killed outright mid-plan, the worker alone: its station, the station's hold
# and a child that went to / with no ticket in its argv stay behind.
set -m
FAKE_SLEEP_IN="AIF-540:plan" FAKE_SLEEP_SECS=44 FAKE_CHILD_CD=1 "$AIF" work AIF-540 >"$OUT/run54a.out" 2>&1 &
w54=$!
set +m
wait_for .aif/worktrees/AIF-540/.aif/tmp/fake-running-AIF-540-plan
sp54="$(cat .aif/state/runs/AIF-540/station 2>/dev/null)"
eq "the run lock records the worker's group, and the station's pid as the station wrote it" \
  "$(jq -r .pgid .aif/state/runs/AIF-540/owner.json),$(ps -o command= -p "$sp54" 2>/dev/null | grep -c 'fake-station.sh plan AIF-540')" "$w54,1"
kill -9 "$w54" 2>/dev/null
wait "$w54" 2>/dev/null
S54="$(st54 AIF-540)"
eq "killed outright: the lock names the group and the station; the station, its hold and the child that left for / are each named by the group" \
  "$(printf '%s' "$S54" | jq -r --argjson p "$w54" --argjson s "${sp54:-0}" '[.lock.pgid == $p, .lock.station == $s, ([.lock.orphans[] | select(.why == "group")] | length), ([.lock.orphans[] | select(.command == "sleep 47.3" and .why == "group")] | length)] | map(tostring) | join(",")')" \
  "true,true,3,1"
rc=0
"$AIF" work AIF-540 >"$OUT/run54b.out" 2>&1 || rc=$?
eq "the next aif work TERMs the dead worker's group before it takes the lock over, then builds" \
  "$rc,$(grep -c "AIF-540 — the worker that held it (pid $w54) is gone, and 3 process(es) it started still run — TERM" "$OUT/run54b.out"),$(grep -c 'is gone; taken over' "$OUT/run54b.out"),$(col AIF-540)" \
  "0,1,1,review"
eq "…the old station and the child that left the tree are gone" \
  "$(pgrep -f 'fake-station.sh plan AIF-540' | wc -l | tr -d ' '),$(pgrep -f 'sleep 47.3' | wc -l | tr -d ' ')" "0,0"

# A child that ignores TERM, in the worktree: the takeover sends its TERM,
# waits, and refuses — exit 3, the card and the dead lock as they were.
set -m
FAKE_SLEEP_IN="AIF-541:plan" FAKE_SLEEP_SECS=44 FAKE_CHILD_DEAF=1 "$AIF" work AIF-541 >"$OUT/run54c.out" 2>&1 &
w54=$!
set +m
wait_for .aif/worktrees/AIF-541/.aif/tmp/fake-running-AIF-541-plan
deaf54="$(pgrep -f 'sleep 63.3' | head -1)"
kill -9 "$w54" 2>/dev/null
wait "$w54" 2>/dev/null
rc=0
AIF_WORK_TAKEOVER_WAIT=2 "$AIF" work AIF-541 >"$OUT/run54d.out" 2>&1 || rc=$?
eq "a takeover with something still running in the tree after its TERM: refused, exit 3, naming it; the card and the dead lock untouched" \
  "$rc,$(grep -c "what it started still runs: pid $deaf54 (sleep 63.3)" "$OUT/run54d.out"),$(col AIF-541),$(jq -r .pid .aif/state/runs/AIF-541/owner.json)" \
  "3,1,in_progress,$w54"
kill -9 "$deaf54" 2>/dev/null
rc=0
"$AIF" work AIF-541 >"$OUT/run54e.out" 2>&1 || rc=$?
eq "…once it is gone, the takeover goes ahead and builds" "$rc,$(col AIF-541)" "0,review"

# Another clone of a project on this machine building the same id: its
# station's argv carries the same prompt, and it is not this clone's.
fresh_project "$SANDBOX/p54b"
ticket_for AIF-542
git add -A && git commit -qm "the same id, another checkout" >/dev/null
"$AIF" board create tasks/AIF-542/ticket.md --column ready >/dev/null
FAKE_SLEEP_IN="AIF-542:plan" FAKE_RELEASE="$OUT/rel54b" "$AIF" work AIF-542 >"$OUT/run54f.out" 2>&1 &
b54=$!
wait_for .aif/worktrees/AIF-542/.aif/tmp/fake-running-AIF-542-plan
bst54="$(pgrep -f 'fake-station.sh plan AIF-542' | head -1)"
cd "$p54" || exit 1
sleep 0 &
dead54=$!
wait "$dead54" 2>/dev/null
mkdir -p .aif/state/runs/AIF-542
printf '{ "ticket": "AIF-542", "pid": %s, "started_at": "2026-10-02T00:00:00Z" }\n' "$dead54" >.aif/state/runs/AIF-542/owner.json
printf 'run\n' >.aif/state/runs/AIF-542/phase
eq "a dead lock here, and another clone's live station for the same id: not listed as this clone's" \
  "$(st54 AIF-542 | jq -c '[.class, .lock.orphans]'),$(kill -0 "$bst54" 2>/dev/null && echo alive)" '["interrupted",[]],alive'
rc=0
"$AIF" work AIF-542 >"$OUT/run54g.out" 2>&1 || rc=$?
eq "…the takeover here builds, and the other clone's station runs on" \
  "$rc,$(col AIF-542),$(kill -0 "$bst54" 2>/dev/null && echo alive)" "0,review,alive"
: >"$OUT/rel54b"
rc=0
wait_exit "$b54" 60 || rc=$?
eq "…and that clone's build finishes on its own" "$rc,$(cd "$SANDBOX/p54b" && col AIF-542)" "0,review"

# A process in this clone's worktree that no group or station names — what a
# gate's suite or prepare's install leaves when a script started the worker
# without job control: named by its working directory, and the reader is
# not, though it runs from that directory too.
mkdir -p .aif/worktrees/AIF-543
(cd .aif/worktrees/AIF-543 && exec sleep 52.3 >/dev/null 2>&1) &
cwd54=$!
sleep 0 &
dead54=$!
wait "$dead54" 2>/dev/null
mkdir -p .aif/state/runs/AIF-543
printf '{ "ticket": "AIF-543", "pid": %s, "started_at": "2026-10-02T00:00:00Z" }\n' "$dead54" >.aif/state/runs/AIF-543/owner.json
eq "a process whose working directory is this clone's worktree: named by it, and the reader in that directory is not" \
  "$( (cd .aif/worktrees/AIF-543 && "$AIF" work --status AIF-543 --json 2>/dev/null) | jq -c --argjson p "$cwd54" '[.lock.orphans[] | [(.pid == $p), .why]]')" \
  '[[true,"cwd"]]'
kill "$cwd54" 2>/dev/null
wait "$cwd54" 2>/dev/null
rm -rf .aif/worktrees/AIF-543 .aif/state/runs/AIF-543

# ====== 55. --status with no id; a lock with no phase =======================
# docs/DEFECTS.md 15.9: a --no-worktree build, whose one trace is its record
# in the checkout, is listed with the rest — a worktree run's record a land
# brought back is not — and a lock its worker never wrote a phase into says
# so, instead of "during its claim".
printf '\n55. aif work --status lists a --no-worktree build, and a lock with no phase says so\n'
fresh_project "$SANDBOX/p55"
ticket_for AIF-550
git add -A && git commit -qm "one in place" >/dev/null
"$AIF" board create tasks/AIF-550/ticket.md --column ready >/dev/null
rc=0
"$AIF" work AIF-550 --no-worktree >"$OUT/run55a.out" 2>&1 || rc=$?
mkdir -p tasks/AIF-551
jq '.ticket = "AIF-551" | .worktree = ".aif/worktrees/AIF-551"' tasks/AIF-550/run.json >tasks/AIF-551/run.json
eq "no id: a --no-worktree build is listed, built in this checkout; a worktree run's copy here is not" \
  "$rc,$("$AIF" work --status --json | jq -r '[.[] | .ticket + ":" + .class + ":" + (.run.where // "-")] | join(" ")')" \
  "0,AIF-550:built:checkout"
rm -rf tasks/AIF-551
sleep 0 &
dead55=$!
wait "$dead55" 2>/dev/null
mkdir -p .aif/state/runs/AIF-552
printf '{ "ticket": "AIF-552", "pid": %s, "started_at": "2026-10-02T00:00:00Z" }\n' "$dead55" >.aif/state/runs/AIF-552/owner.json
eq "a dead lock with no phase file: its phase unknown, not \"during its claim\"" \
  "$("$AIF" work --status AIF-552 2>&1)" \
  "AIF-552  interrupted — its worker (pid $dead55) is gone, its phase unknown, before its intake — no station ran; nothing of it still runs"
printf 'worktree\n' >.aif/state/runs/AIF-552/phase
eq "…and with one, where it died" \
  "$("$AIF" work --status AIF-552 2>&1)" \
  "AIF-552  interrupted — its worker (pid $dead55) is gone during its worktree, before its intake — no station ran; nothing of it still runs"
rm -rf .aif/state/runs/AIF-552

# ====== 56. the second Ctrl-C one tick after the first ========================
# docs/DEFECTS.md 11.1. The second Ctrl-C sent a tick after the first — the
# alignment this harness used before ctrl_c_twice waited for the loop's word —
# landed as the tick's foreground `sleep 1` ended, where bash 3.2 notes an INT
# and runs no trap: lost 10 times in 60 on the loop at that alignment, and 7 in
# 16 where the offset walks the end of the tick (docs/FINDINGS.md #33). The
# tick waits in the `wait` builtin now, where a trapped INT always runs its
# trap. Twelve times, the second sent a tick and 0 to 10 ms after the first:
# the run stopped by it every time. Each loop waited on with a bound.
printf '\n56. the second Ctrl-C a tick after the first stops the runs, every time\n'
fresh_project "$SANDBOX/p56"
for i in $(seq 1 12); do
  ticket_for "AIF-$((560 + i))"
done
git add -A && git commit -qm "twelve for the second Ctrl-C" >/dev/null
wrong56=""
i=0
for d56 in 1 1.002 1.004 1.006 1.008 1.010 1 1.002 1.004 1.006 1.008 1.010; do
  i=$((i + 1))
  id="AIF-$((560 + i))"
  "$AIF" board create "tasks/$id/ticket.md" --column ready >/dev/null
  m56="$SANDBOX/p56-marks-$i"
  mkdir -p "$m56"
  FAKE_SLEEP_IN="$id:plan" FAKE_MARKS="$m56" FAKE_RELEASE="$m56/go" AIF_WORK_LOOP_LOGDIR="$SANDBOX/p56-loop-$i" \
    launch "$OUT/run56-$i.out" --parallel 1 --no-tui
  l56=$loop
  IDLE_PIDS="$IDLE_PIDS $l56"
  wait_for "$m56/$id-plan"
  # The first anywhere in a tick; the second a tick after it, as `sleep 1`
  # between two kills put it, and a few ms later on.
  sleep "0.$((RANDOM % 9))"
  kill -INT -- "-$l56" 2>/dev/null
  sleep "$d56"
  kill -INT -- "-$l56" 2>/dev/null
  # Forwarded, the second ends the run at once and the loop with it, 130; a
  # lost one leaves the station holding: the harness lets it go and stops
  # the loop itself.
  j=0
  while kill -0 "$l56" 2>/dev/null && [ "$j" -lt 80 ]; do
    sleep 0.1
    j=$((j + 1))
  done
  : >"$m56/go"
  kill -0 "$l56" 2>/dev/null && kill -TERM -- "-$l56" 2>/dev/null
  rc=0
  wait_exit "$l56" 30 || rc=$?
  [ "$rc,$(col "$id")" = "130,needs_human" ] || wrong56="$wrong56 $i:$d56:$rc"
done
eq "Ctrl-C twice, the second a tick and 0–10 ms after the first, 12 times: the run stopped and the loop ended 130 each time" \
  "${wrong56# }" ""

# A Ctrl-C that lands in a `$(…)` the loop assigns from kills the child, and
# under set -e the assignment's 130 then ended the loop itself — its runs left
# to build on with nobody to forward the second Ctrl-C (docs/FINDINGS.md #33).
# The loop forks for nothing it reads each second now. Here its `date` takes a
# second and a half, as a loaded machine's fork can, so a Ctrl-C at a random
# point lands in it more often than not where the loop still asks it: four
# loops, one held run each, one Ctrl-C each — every loop alive after it,
# waiting for its run, which it then reports built.
mkdir -p "$SANDBOX/p56-slow"
cat >"$SANDBOX/p56-slow/date" <<'SLOW'
#!/bin/bash
# The loop's own `date` slow; its workers, which carry AIF_WORK_LOOP=1, not.
[ "${AIF_WORK_LOOP:-}" = 1 ] || sleep 1.5
exec /bin/date "$@"
SLOW
chmod +x "$SANDBOX/p56-slow/date"
wrong56=""
for i in 1 2 3 4; do
  id="AIF-$((572 + i))"
  ticket_for "$id"
  git add -A && git commit -qm "$id for a Ctrl-C in a slow date" >/dev/null
  "$AIF" board create "tasks/$id/ticket.md" --column ready >/dev/null
  m56="$SANDBOX/p56-slow-marks-$i"
  mkdir -p "$m56"
  PATH="$SANDBOX/p56-slow:$PATH" FAKE_SLEEP_IN="$id:plan" FAKE_MARKS="$m56" FAKE_RELEASE="$m56/go" \
    AIF_WORK_LOOP_LOGDIR="$SANDBOX/p56-slow-loop-$i" launch "$OUT/run56s-$i.out" --parallel 2 --no-tui
  l56=$loop
  IDLE_PIDS="$IDLE_PIDS $l56"
  wait_file "$m56/$id-plan" 60
  sleep "$((RANDOM % 3)).$((RANDOM % 10))"
  kill -INT -- "-$l56" 2>/dev/null
  sleep 4
  alive56="$(kill -0 "$l56" 2>/dev/null && echo alive || echo gone)"
  : >"$m56/go"
  rc=0
  wait_exit "$l56" 90 || rc=$?
  b56="$(jq -r '.built' "$SANDBOX/p56-slow-loop-$i/summary.json" 2>/dev/null)"
  [ "$alive56,$rc,$b56,$(col "$id")" = "alive,130,1,review" ] || wrong56="$wrong56 $i:$alive56,$rc,$b56"
done
eq "one Ctrl-C while the loop waits on a slow date, 4 times: the loop still there, its run built and reported — exit 130" \
  "${wrong56# }" ""

# ====== 57. what an idle loop holds, said where a shift can read it =========
# docs/DEFECTS.md 15.3, 15.7 and 14.1. An idle loop holds a card whose run
# ended with the card still in Ready — skipped, never taken again by that
# loop — and said so in its own lines only, and in summary.json once it
# ended: a shift in another terminal read the card as work in flight and
# waited for it for good. The lock's owner.json names each held card with
# why now, and the idle line says Ready holds only such cards. A takeover a
# worker refused because what a dead run of the card started still runs is
# held the same way — no preflight asked again, nothing counted toward the
# environment — and the loop goes on with the next card. A process tied to a
# dead run by nothing but its working directory is never signalled: the
# takeover refuses at once, naming it. And a card taken twice has a log for
# each take, where the second worker's output used to replace the first's.
printf '\n57. an idle loop names what it holds, a refused takeover is not the machine, and each take has its log\n'
fresh_project "$SANDBOX/p57"
for t in AIF-575 AIF-576 AIF-577 AIF-578 AIF-579; do
  ticket_for "$t"
done
git add -A && git commit -qm "five for what an idle loop holds" >/dev/null
L57="$SANDBOX/p57-loop"
AIF_WORK_TAKEOVER_WAIT=2 AIF_WORK_LOOP_POLL=1 AIF_WORK_LOOP_LOGDIR="$L57" launch "$OUT/run57a.out" --idle --no-tui --parallel 1
l57=$loop
IDLE_PIDS="$IDLE_PIDS $l57"
wait_count "$L57/loop.log" 'Ready is empty — idle' 1 30
eq "an idle loop's lock says what it holds: nothing yet" "$(jq -c '.held' .aif/state/loop/owner.json 2>/dev/null)" "[]"

# Taken twice: built, back in Ready as a land's sync: sends it, built again.
"$AIF" board create tasks/AIF-575/ticket.md --column ready >/dev/null
wait_col AIF-575 review 60
wait_count "$L57/loop.log" 'Ready is empty — idle' 2 30
"$AIF" board move AIF-575 ready >/dev/null
wait_count "$OUT/run57a.out" 'loop [0-9]* — AIF-575 ' 2 30
wait_col AIF-575 review 60
wait_count "$L57/loop.log" 'Ready is empty — idle' 3 30
eq "a card taken twice: a log a take — the first kept, the second beside it — each named where its worker started" \
  "$(find "$L57" -name 'AIF-575*.log' | wc -l | tr -d ' '),$(grep -c 'cut .aif/worktrees/AIF-575 on aif/AIF-575' "$L57/AIF-575.log" 2>/dev/null),$(grep -c 'cut .aif/worktrees/AIF-575' "$L57/AIF-575.2.log" 2>/dev/null),$(grep -c "loop 1 — AIF-575 · .*/AIF-575.log$" "$OUT/run57a.out"),$(grep -c "loop 2 — AIF-575 · .*/AIF-575.2.log$" "$OUT/run57a.out")" \
  "2,1,0,1,1"

# A worker that exits before its claim — the stations gone from the checkout
# after the loop's preflight — leaves its card in Ready: held, and said.
mv .claude/agents/aif-implement.md "$OUT/aif-implement.md.57"
"$AIF" board create tasks/AIF-576/ticket.md --column ready >/dev/null
wait_count "$L57/loop.log" 'Ready holds only cards this loop will not take again — idle' 1 30
mv "$OUT/aif-implement.md.57" .claude/agents/aif-implement.md
eq "a worker that exited before its claim: the card held in Ready, the lock naming it with why, the idle line saying Ready holds only cards this loop will not take again" \
  "$(col AIF-576)|$(jq -r '[.held[] | .ticket + ": " + .why] | join(";")' .aif/state/loop/owner.json 2>/dev/null)|$(grep -c 'Ready holds only cards this loop will not take again — idle, looking again every 1s · .* · held: AIF-576$' "$L57/loop.log")" \
  "ready|AIF-576: its worker exited 1 before it took the card: the stations are not installed — run 'aif init'|1"

# A dead run of AIF-577 whose station left a child that ignores TERM: the
# takeover TERMs what is the run's, waits (2 s here), and refuses, exit 3,
# the card untouched. Moved back to Ready by hand, beside AIF-578.
"$AIF" board create tasks/AIF-577/ticket.md --column backlog >/dev/null
set -m
FAKE_SLEEP_IN="AIF-577:plan" FAKE_SLEEP_SECS=44 FAKE_CHILD_DEAF=1 "$AIF" work AIF-577 >"$OUT/run57c.out" 2>&1 &
w57=$!
set +m
wait_for .aif/worktrees/AIF-577/.aif/tmp/fake-running-AIF-577-plan
deaf57="$(pgrep -f 'sleep 63.3' | head -1)"
kill -9 "$w57" 2>/dev/null
wait "$w57" 2>/dev/null
"$AIF" board move AIF-577 ready >/dev/null
"$AIF" board create tasks/AIF-578/ticket.md --column ready >/dev/null
wait_col AIF-578 review 90
wait_count "$L57/loop.log" 'Ready holds only cards this loop will not take again — idle' 2 30
eq "a takeover refused — what the dead run started still runs: the card held untouched, no preflight asked again, the next card built, the loop idle" \
  "$(col AIF-577),$(col AIF-578),$(grep -c "AIF-577 not taken over — what its last worker started still runs (pid $deaf57 (sleep 63.3)); the card is held, the loop goes on" "$L57/loop.log"),$(grep -c 'checking the machine again' "$L57/loop.log"),$(kill -0 "$l57" 2>/dev/null && echo alive)" \
  "ready,review,1,0,alive"
eq "…the lock names both held cards, the refused one with what still runs" \
  "$(jq -r '[.held[] | .ticket] | join(" ")' .aif/state/loop/owner.json 2>/dev/null),$(jq -r '.held[] | select(.ticket == "AIF-577") | .why' .aif/state/loop/owner.json 2>/dev/null | grep -c "^its last worker is gone, and what it started still runs: pid $deaf57 (sleep 63.3) — aif work --status AIF-577 says what$")" \
  "AIF-576 AIF-577,1"
kill -9 "$deaf57" 2>/dev/null
"$AIF" work --loop --drain >/dev/null 2>&1
rc=0
wait_exit "$l57" 30 || rc=$?
eq "…drained: the environment never blamed, nothing re-checked, both held, and every run with its own take's log" \
  "$rc|$(jq -r '[.env, .rechecks, (.held | join(" ")), ([.results[] | .ticket + ":" + .log] | join(" "))] | map(tostring) | join("|")' "$L57/summary.json" 2>/dev/null)" \
  "1|0|0|AIF-576 AIF-577|AIF-575:AIF-575.log AIF-575:AIF-575.2.log AIF-576:AIF-576.log AIF-577:AIF-577.log AIF-578:AIF-578.log"
eq "…and its last lines name each run's log" \
  "$(grep -c 'AIF-575 · [0-9]* min · built → Review · aif land AIF-575 · AIF-575.2.log$' "$OUT/run57a.out"),$(grep -c 'AIF-576 · [0-9]* min · not built — its worker exited 1 before it took the card · AIF-576.log$' "$OUT/run57a.out")" \
  "1,1"

# A process someone opened in a dead run's worktree — nothing but its
# directory ties it to the run: never signalled, and the takeover refuses at
# once, naming it. It used to get its TERM with the rest.
"$AIF" board create tasks/AIF-579/ticket.md --column ready >/dev/null
mkdir -p .aif/worktrees/AIF-579
(cd .aif/worktrees/AIF-579 && exec sleep 52.7 >/dev/null 2>&1) &
hand57=$!
sleep 0 &
dead57=$!
wait "$dead57" 2>/dev/null
mkdir -p .aif/state/runs/AIF-579
printf '{ "ticket": "AIF-579", "pid": %s, "started_at": "2026-10-02T00:00:00Z" }\n' "$dead57" >.aif/state/runs/AIF-579/owner.json
t0=$SECONDS
rc=0
"$AIF" work AIF-579 >"$OUT/run57d.out" 2>&1 || rc=$?
secs=$((SECONDS - t0))
eq "a process opened by hand in a dead run's worktree: never signalled — the takeover refuses at once, exit 3, naming it; the card untouched" \
  "$rc,$(kill -0 "$hand57" 2>/dev/null && echo alive),$(grep -c "what it started still runs: pid $hand57 (sleep 52.7) in its worktree, never signalled" "$OUT/run57d.out"),$(col AIF-579),$([ "$secs" -lt 10 ] && echo prompt || echo "${secs}s")" \
  "3,alive,1,ready,prompt"
kill "$hand57" 2>/dev/null
wait "$hand57" 2>/dev/null
rm -rf .aif/worktrees/AIF-579 .aif/state/runs/AIF-579

# ====== 58. a Ctrl-C in the Ready read, a stop in the preflight, one bad read ==
# docs/DEFECTS.md 15.9 and 14.3. A Ctrl-C that lands while the loop reads
# Ready kills the read with it, and the loop took that for the board: env 1
# in its summary beside a 130. `aif work --loop --stop` against a loop still
# probing the suite in its preflight was read only once the probe ended. And
# a loop that is not idle ended 3 — the environment — on one Ready read the
# board's own retries could not save, with nothing asked again: an exit 3 is
# the machine only once the loop's preflight, asked again, fails too.
printf '\n58. a Ctrl-C during the Ready read is not the board, a stop reaches a loop in its preflight, and one bad read is not the machine\n'
fresh_project "$SANDBOX/p58"
for t in AIF-580 AIF-581 AIF-582; do
  ticket_for "$t"
done
git add -A && git commit -qm "three for the loop's edges" >/dev/null
"$AIF" board create tasks/AIF-582/ticket.md --column backlog >/dev/null

# The read held open by a FIFO among the board's card files, as scenario 50
# holds it, and a Ctrl-C to the loop's group while it waits.
L58a="$SANDBOX/p58-loop-a"
AIF_WORK_LOOP_POLL=1 AIF_WORK_LOOP_LOGDIR="$L58a" launch "$OUT/run58a.out" --idle --no-tui
l58=$loop
IDLE_PIDS="$IDLE_PIDS $l58"
wait_count "$L58a/loop.log" 'Ready is empty — idle' 1 30
mkfifo .aif/board/AAA.json
i=0
while ! pgrep -f 'board/AAA.json' >/dev/null 2>&1 && [ "$i" -lt 100 ]; do
  sleep 0.1
  i=$((i + 1))
done
read58="$(pgrep -f 'board/AAA.json' >/dev/null 2>&1 && echo held || echo free)"
kill -INT -- "-$l58" 2>/dev/null
rc=0
wait_exit "$l58" 30 || rc=$?
rm -f .aif/board/AAA.json
eq "a Ctrl-C while the loop reads Ready: exit 130, the summary saying Ctrl-C, and env 0 — not the board" \
  "$read58|$rc|$(jq -r '[.env, .ctrl_c, .why] | map(tostring) | join("|")' "$L58a/summary.json" 2>/dev/null)" \
  "held|130|0|1|stopped by Ctrl-C — no new card taken"

# A suite probe that takes its time: `aif work --loop --stop` while the loop
# is still in it.
tmp="$(mktemp)"
jq '.test.command = "bash .aif/suite.sh; if [ -f .aif/tmp/slow58 ]; then : >.aif/tmp/probing58; sleep 25.8; fi"' .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
mkdir -p .aif/tmp
: >.aif/tmp/slow58
L58b="$SANDBOX/p58-loop-b"
AIF_WORK_LOOP_POLL=1 AIF_WORK_LOOP_LOGDIR="$L58b" launch "$OUT/run58b.out" --idle --no-tui
l58=$loop
IDLE_PIDS="$IDLE_PIDS $l58"
wait_file .aif/tmp/probing58 30
t0=$SECONDS
rc=0
"$AIF" work --loop --stop >"$OUT/run58b2.out" 2>&1 || rc=$?
secs=$((SECONDS - t0))
rc1=0
wait_exit "$l58" 40 || rc1=$?
eq "aif work --loop --stop while the loop probes the suite in its preflight: the loop ends 143 in seconds, the probe with it, its lock gone, and the stop says so" \
  "$rc,$rc1,$([ "$secs" -lt 10 ] && echo prompt || echo "${secs}s"),$(pgrep -f 'sleep 25.8' | wc -l | tr -d ' '),$(test -d .aif/state/loop && echo held || echo released),$(grep -c "stopped the loop (pid $l58) — it stopped before taking a card" "$OUT/run58b2.out")" \
  "0,143,prompt,0,released,1"
rm -f .aif/tmp/slow58 .aif/tmp/probing58
git checkout -- .aif/project.json

# Not idle, Ready not read once — a card file that is not JSON, as a Trello
# outage would fail it — then read again: the machine asked first, and it
# passes; the card is built.
"$AIF" board create tasks/AIF-580/ticket.md --column ready >/dev/null
printf '{' >.aif/board/X.json
L58c="$SANDBOX/p58-loop-c"
AIF_WORK_LOOP_LOGDIR="$L58c" launch "$OUT/run58c.out" --no-tui --parallel 1
l58=$loop
IDLE_PIDS="$IDLE_PIDS $l58"
wait_count "$L58c/loop.log" "the board's Ready column could not be read, but the machine checks out" 1 30
rm -f .aif/board/X.json
rc=0
wait_exit "$l58" 90 || rc=$?
eq "a Ready not read once, not idle: the machine asked again and passing, Ready read again, the card built — exit 0, env 0, one re-check" \
  "$rc|$(col AIF-580)|$(jq -r '[.env, .rechecks, .why] | map(tostring) | join("|")' "$L58c/summary.json" 2>/dev/null)" \
  "0|review|0|1|Ready is empty"
"$AIF" board create tasks/AIF-581/ticket.md --column ready >/dev/null
printf '{' >.aif/board/X.json
rc=0
AIF_WORK_LOOP_LOGDIR="$SANDBOX/p58-loop-d" "$AIF" work --loop --no-tui --parallel 1 >"$OUT/run58d.out" 2>&1 || rc=$?
rm -f .aif/board/X.json
eq "…and one that cannot be read three times in a row, the preflight passing each time: exit 3, the environment, two re-checks, the card untouched" \
  "$rc|$(col AIF-581)|$(jq -r '[.env, .rechecks, .why] | map(tostring) | join("|")' "$SANDBOX/p58-loop-d/summary.json" 2>/dev/null)" \
  "3|ready|1|2|the board's Ready column could not be read three times in a row, though the preflight passes — aif board check says why"

# ====== 68. a blocked: line the board refused, posted by the next run =========
# docs/DEFECTS.md 14.2. _aif_work_block moves the card to Needs Human even when
# the board refused its comment — on purpose: in Ready it would be taken
# again — and keeps the line in .aif/tmp/blocked-<ID>.md, where it stayed: the
# card had no first line to route on until a person ran the command a
# warning named. The next worker run on this machine posts it before it takes
# a card: only over the run's own claim (the state a refused comment leaves);
# a card whose head moved on since, or one in Review, has its stale file
# removed; In Progress is the shift's to settle with the file (R3c). The
# refusal itself is check-board's (a stand-in Trello that refuses comments);
# here the state it leaves is set out on the local board.
printf '\n68. the next run posts a blocked: line the board refused, and leaves the rest where it belongs\n'
fresh_project "$SANDBOX/p68"
for t in AIF-680 AIF-681 AIF-682 AIF-683 AIF-684; do
  ticket_for "$t"
done
git add -A && git commit -qm "five for kept lines" >/dev/null
host68="$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf '%s' "${HOSTNAME:-?}")"
host68="$(printf '%s' "$host68" | tr -d '[:space:]')"
kept68() { # <ID> <column> — a card in <column> under this host's claim, its blocked: line kept
  "$AIF" board create "tasks/$1/ticket.md" --column "$2" >/dev/null
  printf 'taken: %s pid 1 at 2026-10-07T09:00:00Z — aif work\n' "$host68" >"$OUT/claim68.md"
  AIF_BOARD_BY="aif work" "$AIF" board comment "$1" "$OUT/claim68.md" >/dev/null
  mkdir -p .aif/tmp
  printf 'blocked: run — the worker exited (code 1) during plan\n\nWhat was accepted is committed on branch aif/%s.\n' "$1" >".aif/tmp/blocked-$1.md"
}
kept68 AIF-680 needs_human
kept68 AIF-681 needs_human
printf 'land: the merge conflicted\n' >"$OUT/land68.md"
AIF_BOARD_BY="aif land" "$AIF" board comment AIF-681 "$OUT/land68.md" >/dev/null
kept68 AIF-682 review
kept68 AIF-683 in_progress
"$AIF" board create tasks/AIF-684/ticket.md --column ready >/dev/null
rc=0
"$AIF" work AIF-684 >"$OUT/run68.out" 2>&1 || rc=$?
eq "the next run, before its take: the kept line is the card's head, posted by the worker, the card left in Needs Human, the file gone" \
  "$("$AIF" board head AIF-680)|$("$AIF" board show AIF-680 --json | jq -r '.comments[-1].by')|$(col AIF-680)|$(test -f .aif/tmp/blocked-AIF-680.md && echo kept || echo gone)|$(grep -c 'AIF-680 — its blocked: line, refused by the board when it was blocked, is on the card now' "$OUT/run68.out")" \
  "blocked: run — the worker exited (code 1) during plan|aif work|needs_human|gone|1"
eq "…a card whose head moved on since (land:): not posted, its stale file removed; one in Review: removed; one In Progress: left for the shift" \
  "$("$AIF" board head AIF-681)|$(test -f .aif/tmp/blocked-AIF-681.md && echo kept || echo gone)|$(test -f .aif/tmp/blocked-AIF-682.md && echo kept || echo gone)|$(test -f .aif/tmp/blocked-AIF-683.md && echo kept || echo gone)|$("$AIF" board head AIF-683 | cut -c1-7)" \
  "land: the merge conflicted|gone|gone|kept|taken: "
eq "…and the run took its own card and built it" "$rc,$(col AIF-684)" "0,review"

# ====== 69. the claim beats while its run lives ===============================
# docs/DEFECTS.md 14.4. A claim said where a card was taken and when, and
# nothing after: a worker that died left a claim no different from a live
# one's, and a shift on another machine could not tell them apart. The
# worker keeps its claim's comment id in its run lock and edits that comment
# at the start of every dispatch — `· alive at <time>` on its first line —
# on the local board as on Trello (the board adapter's comment edit; the
# Trello half is check-board's). No comment is added by it: the report after
# the claim is still the head.
printf '\n69. the worker keeps its claim id in its lock and beats on the claim at every dispatch\n'
fresh_project "$SANDBOX/p69"
ticket_for AIF-690
git add -A && git commit -qm "one to beat" >/dev/null
"$AIF" board create tasks/AIF-690/ticket.md --column ready >/dev/null
FAKE_SLEEP_IN="AIF-690:tests" FAKE_RELEASE="$OUT/release69" "$AIF" work AIF-690 >"$OUT/run69.out" 2>&1 &
w69=$!
wait_file .aif/worktrees/AIF-690/.aif/tmp/fake-running-AIF-690-tests 60
cid69="$(cat .aif/state/runs/AIF-690/claim.id 2>/dev/null)"
md69="$(sed -n 1p .aif/state/runs/AIF-690/claim.md 2>/dev/null)"
during69="$("$AIF" board show AIF-690 --json | jq -r --arg c "$cid69" '[.comments[] | select(.id == $c)][0].text' | sed -n 1p)"
: >"$OUT/release69"
rc=0
wait_exit "$w69" 90 || rc=$?
eq "while the tests station runs: the lock names the claim's comment and keeps its words, and on the card its first line says the worker is alive" \
  "$(printf '%s' "$cid69" | grep -cE '^c[0-9]+$'),$(printf '%s' "$md69" | grep -cE "^taken: ${host68:-?} pid [0-9]+ at [0-9T:Z-]+ — aif work$"),$(printf '%s' "$during69" | grep -cE "^taken: ${host68:-?} pid [0-9]+ at [0-9T:Z-]+ — aif work · alive at [0-9T:Z-]+$")" \
  "1,1,1"
eq "built: the claim edited in place at every dispatch — still its comment, no comment added — the report the head, the lock gone" \
  "$rc|$(col AIF-690)|$("$AIF" board show AIF-690 --json | jq -r --arg c "$cid69" '[(.comments | length), ([.comments[] | select(.id == $c)][0] | (.edited_at != null), (.text | split("\n")[0] | test(" · alive at [0-9T:Z-]+$")))] | map(tostring) | join(",")')|$("$AIF" board head AIF-690)|$(test -d .aif/state/runs/AIF-690 && echo held || echo gone)" \
  "0|review|2,true,true|# AIF-690 — built|gone"

# ====== 59. the worktrees line joins the .gitignore block, the rest kept ======
# docs/DEFECTS.md 15.14. Before it cuts a worktree the worker makes sure
# .aif/worktrees/ is ignored, and it did that by handing the one line to
# aif_block_inject, which rewrites everything between the markers: a block
# written before the worker existed, or edited by hand, came out ignoring
# nothing but the worktrees — .aif/profile.local, .aif/state/ and the rest
# showed in `git status`, one `git add -A` from a commit. The line now joins
# the block; a block with no end line is not touched (aif_block_inject would
# have read the rest of the file as the block and dropped it).
printf '\n59. the worktrees line joins the .gitignore block, and the block keeps what it held\n'
fresh_project "$SANDBOX/p59"
ticket_for AIF-590
awk -v b='# aif:begin' '
  index($0, b) { print; print "# per-developer model choice; the shared set is committed"; print ".aif/profile.local"; print "# gate scratch"; print ".aif/tmp/"; print "# session-local pointer for the metering hook"; print ".aif/state/"; print "# the local board"; print ".aif/board/"; skip = 1; next }
  /^# aif:end/ { skip = 0 }
  !skip        { print }
' .gitignore >"$OUT/gi59" && cat "$OUT/gi59" >.gitignore
printf 'node_modules/\n' >>.gitignore
git add -A && git commit -qm "a block from before the worker" >/dev/null
"$AIF" board create tasks/AIF-590/ticket.md --column ready >/dev/null
rc=0
"$AIF" work AIF-590 >"$OUT/run59.out" 2>&1 || rc=$?
eq "the run builds, and says it added the worktrees line to the block" \
  "$rc,$(col AIF-590),$(grep -c 'worktree  added .aif/worktrees/ to the block aif manages in .gitignore' "$OUT/run59.out")" "0,review,1"
eq "…every line the block held is still in it, the worktrees line with them, the developer's own line kept" \
  "$(awk '/^# aif:begin/{i=1;next} /^# aif:end/{i=0} i && !/^#/' .gitignore | sort | paste -sd' ' -)|$(grep -cx 'node_modules/' .gitignore)" \
  ".aif/board/ .aif/profile.local .aif/state/ .aif/tmp/ .aif/worktrees/|1"
eq "…and git status shows none of them (the profile, the state, the worktree)" \
  "$(git status --porcelain --untracked-files=all | grep -c '\.aif/\(profile\.local\|state/\|worktrees/\|board/\)')" "0"
gi59() { # <dir> — run aif_gitignore_ensure for the worktrees line there; prints rc and what it said
  /bin/bash -c '. "$1/lib/common.sh"; . "$1/lib/paths.sh"; . "$1/lib/merge.sh"; aif_gitignore_ensure "$2" ".aif/worktrees/" "worker checkouts" 2>&1; printf "rc=%s" "$?"' _ "$ROOT" "$1"
}
mkdir -p "$SANDBOX/p59b" "$SANDBOX/p59c"
printf 'mine/\n# aif:begin — managed by ai-foundry; edits inside are overwritten\n.aif/tmp/\nafter-the-marker/\n' >"$SANDBOX/p59b/.gitignore"
said59b="$(gi59 "$SANDBOX/p59b")"
eq "a block with no end line: not rewritten, the line to add named, every line kept" \
  "$(printf '%s' "$said59b" | grep -c 'has no end line'),$(printf '%s' "$said59b" | tail -c 4),$(wc -l <"$SANDBOX/p59b/.gitignore" | tr -d ' '),$(grep -cx 'after-the-marker/' "$SANDBOX/p59b/.gitignore")" \
  "1,rc=0,4,1"
printf 'mine/\n' >"$SANDBOX/p59c/.gitignore"
gi59 "$SANDBOX/p59c" >/dev/null
eq "no block at all: one is appended with the line, the developer's own line first" \
  "$(sed -n 1p "$SANDBOX/p59c/.gitignore")|$(grep -cx '.aif/worktrees/' "$SANDBOX/p59c/.gitignore")|$(grep -c '^# aif:end' "$SANDBOX/p59c/.gitignore")" \
  "mine/|1|1"

# ====== 60. the land beside the developer's own uncommitted work ==============
# The land merged into the developer's own checkout, and refused while anything
# tracked was uncommitted there — the checkout where the human talks to the
# analyst and the product partner (docs/DEFECTS.md 13.5). It merges in the
# ticket's worktree now, and moves the checkout by a fast-forward: their work
# on files the land does not touch stays as it is, staged or not; an edit to a
# file it changes refuses the land, naming the file, nothing touched.
#
# land_built <dir> <ticket> — a project with <ticket> built in its worktree and
# in Review, entered. Used by 60–67.
land_built() {
  fresh_project "$1"
  ticket_for "$2"
  git add -A && git commit -qm "the ticket" >/dev/null
  "$AIF" board create "tasks/$2/ticket.md" --column ready >/dev/null
  "$AIF" work "$2" >"$OUT/run-$2.out" 2>&1
}
printf '\n60. the land beside the developer'"'"'s own work: what it does not change stays, what it changes refuses\n'
fresh_project "$SANDBOX/p60"
printf 'notes\n' >NOTES.md
ticket_for AIF-160
git add -A && git commit -qm "ticket 60, and the notes" >/dev/null
"$AIF" board create tasks/AIF-160/ticket.md --column ready >/dev/null
rc=0
"$AIF" work AIF-160 >"$OUT/run60.out" 2>&1 || rc=$?
eq "built in its worktree, in Review" "$rc,$(col AIF-160)" "0,review"
printf 'def users():\n    return []  # my own edit\n' >src/app.py
head_before="$(git rev-parse HEAD)"
rc=0
"$AIF" land AIF-160 >"$OUT/land60b.out" 2>&1 || rc=$?
eq "an uncommitted edit to a file the land changes: refused, exit 1, the card in Review, nothing moved, the edit kept" \
  "$rc,$(col AIF-160),$(git rev-parse HEAD),$(grep -c 'my own edit' src/app.py)" "1,review,$head_before,1"
eq "…naming the file it changes" \
  "$(grep -c 'uncommitted changes to files this land changes' "$OUT/land60b.out"),$(grep -c '^  - src/app.py$' "$OUT/land60b.out")" "1,1"
eq "…the worktree still on its branch" "$(git -C .aif/worktrees/AIF-160 symbolic-ref --short HEAD 2>/dev/null)" "aif/AIF-160"
git checkout -q -- src/app.py
printf 'more notes\n' >>NOTES.md
printf 'extra\n' >extra.md
git add extra.md
rc=0
"$AIF" land AIF-160 >"$OUT/land60a.out" 2>&1 || rc=$?
eq "an edit to a file it does not change, and a new file staged: landed, exit 0, Done, one land commit" \
  "$rc,$(col AIF-160),$(git log --format=%s -1),$(git log --format=%s | grep -c '^aif: land AIF-160 — ')" \
  "0,done,aif: land AIF-160 — one-command user export,1"
eq "…the developer's edit and staged file as they were, the implementation landed beside them" \
  "$(git status --porcelain --untracked-files=no | sort | tr '\n' ';'),$(grep -c impl1 src/app.py)" " M NOTES.md;A  extra.md;,1"

# ====== 61. the dependencies are installed where the verdict is reached =======
# The land judged a merge that moved a lockfile against what was installed in
# the developer's checkout from before it, went red over a package it lacked,
# and sent a ticket with nothing wrong in it to a human (docs/DEFECTS.md 6.3,
# 13.5). The verdict is reached in the ticket's worktree now: the worker
# installed what the branch pins there, and the land installs again there only
# what the target moved against it — never here, where an install is the
# developer's to ask for. One build, four copies of it, as scenario 25's shape:
# t0 is red while the lockfile pins dep-new and the install lacks it.
printf '\n61. the dependencies installed where the verdict is reached, not here\n'
fresh_project "$SANDBOX/p61"
printf '{ "dependencies": { "dep-a": "1" } }\n' >package.json
cp package.json package-lock.json
printf 'deps/\n' >>.gitignore
cat >.aif/prepare.sh <<'PREP'
#!/bin/bash
want="$(grep -o '"dep-[a-z]*"' package.json | sort | tr '\n' ' ')"
have="$(grep -o '"dep-[a-z]*"' package-lock.json | sort | tr '\n' ' ')"
if [ "$want" != "$have" ]; then
  echo "npm error \`npm ci\` can only install packages when your package.json and package-lock.json are in sync."
  exit 1
fi
rm -rf deps && mkdir -p deps
printf '%s\n' $have >deps/installed
# npm install in tools/, where npm ci was meant: it rewrites that lockfile
if [ -f tools/package-lock.json ] && [ -n "${PREP_REWRITES:-}" ]; then printf '\n' >>tools/package-lock.json; fi
PREP
chmod +x .aif/prepare.sh
tmp="$(mktemp)"
jq '.prepare = "bash .aif/prepare.sh"' .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
t0_red_when 'grep -q dep-new package-lock.json && ! grep -q dep-new deps/installed 2>/dev/null'
ticket_for AIF-161
git add -A && git commit -qm "ticket 61, and a lockfile" >/dev/null
bash .aif/prepare.sh # the developer's own install
"$AIF" board create tasks/AIF-161/ticket.md --column ready >/dev/null
rc=0
FAKE_DEPS=1 "$AIF" work AIF-161 >"$OUT/run61.out" 2>&1 || rc=$?
eq "a ticket that adds a dependency through the lock: built in its worktree, in Review" "$rc,$(col AIF-161)" "0,review"
copy_project "$SANDBOX/p61" "$SANDBOX/p61a" AIF-161
rc=0
"$AIF" land AIF-161 >"$OUT/land61a.out" 2>&1 || rc=$?
eq "the branch moved the dependencies: landed, Done, nothing installed here" \
  "$rc,$(col AIF-161),$(installed)" '0,done,"dep-a" '
eq "…said with the command that installs them here" \
  "$(grep -c '^deps: .*not installed in this checkout.*When you need them here: bash .aif/prepare.sh' "$OUT/land61a.out")" "1"
# The target moves a manifest and its lockfile of its own after the build: the
# merge is installed in the worktree before it is judged there.
copy_project "$SANDBOX/p61" "$SANDBOX/p61b" AIF-161
mkdir -p tools
printf '{ "dependencies": { "dep-t": "1" } }\n' >tools/package.json
cp tools/package.json tools/package-lock.json
git add -A && git commit -qm "the tools' dependencies" >/dev/null
rc=0
"$AIF" land AIF-161 >"$OUT/land61b.out" 2>&1 || rc=$?
eq "what the target moved is installed in the worktree, before its verdict" \
  "$(grep -c '^prepare   tools/package-lock.json, tools/package.json moved — bash .aif/prepare.sh, in .aif/worktrees/AIF-161$' "$OUT/land61b.out")" "1"
eq "…landed, Done, this checkout's install and tree untouched" \
  "$rc,$(col AIF-161),$(installed),$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')" '0,done,"dep-a" ,0'
# The same, and the install there rewrites a lockfile: not what the merge
# pins. Refused for a human; nothing landed, the worktree back on its branch.
copy_project "$SANDBOX/p61" "$SANDBOX/p61c" AIF-161
mkdir -p tools
printf '{ "dependencies": { "dep-t": "1" } }\n' >tools/package.json
cp tools/package.json tools/package-lock.json
git add -A && git commit -qm "the tools' dependencies" >/dev/null
head_before="$(git rev-parse HEAD)"
rc=0
PREP_REWRITES=1 "$AIF" land AIF-161 >"$OUT/land61c.out" 2>&1 || rc=$?
eq "an install in the worktree that rewrites a lockfile: exit 1, Needs Human, nothing landed, this checkout clean" \
  "$rc,$(col AIF-161),$(git rev-parse HEAD),$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')" "1,needs_human,$head_before,0"
eq "…on a land: line naming the file" \
  "$(last_comment AIF-161 | sed -n 1p | grep -c '^land: .*rewrote tools/package-lock.json')" "1"
eq "…the worktree back on its branch" "$(git -C .aif/worktrees/AIF-161 symbolic-ref --short HEAD 2>/dev/null)" "aif/AIF-161"
# No worktree to borrow — removed by hand — and the target moved: the land
# cuts one at the target, installs there, and judges.
copy_project "$SANDBOX/p61" "$SANDBOX/p61d" AIF-161
"$AIF" work AIF-161 --clean >/dev/null 2>&1
printf 'notes\n' >NOTES.md
git add -A && git commit -qm "main moved" >/dev/null
rc=0
"$AIF" land AIF-161 >"$OUT/land61d.out" 2>&1 || rc=$?
eq "no worktree: one cut at the target for the land, installed, judged — landed, Done" \
  "$rc,$(col AIF-161),$(grep -c '^worktree  cut .aif/worktrees/AIF-161 at .* for the land$' "$OUT/land61d.out"),$(grep -c '^prepare   bash .aif/prepare.sh, in .aif/worktrees/AIF-161$' "$OUT/land61d.out"),$(grep -c '^suite     bash .aif/suite.sh — in .aif/worktrees/AIF-161$' "$OUT/land61d.out")" \
  "0,done,1,1,1"

# ====== 62. the verdict: the worker's, or the suite and the checks, there ======
# The land ran the suite on every merge, in the developer's checkout — minutes
# of jest on a tree the worker had judged already — and no check at all: two
# tickets that merged clean and type-checked apart could leave the target red
# (docs/DEFECTS.md 13.5). The worker's verdict stands now when the merge is
# the tree it judged and the target moved only in tasks/; otherwise the land
# runs the suite and every check bound to green, in the worktree. The stub
# suite says where it ran in $SUITE_LOG. `pair` passes on the build and fails
# once main has src/other.py beside it.
printf '\n62. the verdict: the worker'"'"'s when it stands, else the suite and the checks, there\n'
fresh_project "$SANDBOX/p62"
{
  head -1 .aif/suite.sh
  # shellcheck disable=SC2016  # a line of the suite being written, expanded when it runs
  printf '[ -z "${SUITE_LOG:-}" ] || pwd -P >>"$SUITE_LOG"\n'
  tail -n +2 .aif/suite.sh
} >"$OUT/suite62" && mv "$OUT/suite62" .aif/suite.sh && chmod +x .aif/suite.sh
tmp="$(mktemp)"
jq '.checks = [ { name: "pair", command: "! { grep -q impl1 src/app.py && [ -f src/other.py ]; }", phase: ["green"], required: true } ]' \
  .aif/project.json >"$tmp" && mv "$tmp" .aif/project.json
ticket_for AIF-165
git add -A && git commit -qm "ticket 62, a suite that says where it ran, and a check" >/dev/null
"$AIF" board create tasks/AIF-165/ticket.md --column ready >/dev/null
rc=0
"$AIF" work AIF-165 >"$OUT/run62.out" 2>&1 || rc=$?
eq "built, the check passed on the build" "$rc,$(col AIF-165)" "0,review"
copy_project "$SANDBOX/p62" "$SANDBOX/p62b" AIF-165
cd "$SANDBOX/p62" || exit 1
ticket_for AIF-166
git add -A && git commit -qm "the analyst's next ticket" >/dev/null
rc=0
SUITE_LOG="$SANDBOX/s62a.log" "$AIF" land AIF-165 >"$OUT/land62a.out" 2>&1 || rc=$?
eq "main moved only in tasks/: the worker's verdict stands — no suite run, landed" \
  "$rc,$(col AIF-165),$(grep -c '^suite     the worker'"'"'s verdict stands' "$OUT/land62a.out"),$(cat "$SANDBOX/s62a.log" 2>/dev/null | wc -l | tr -d ' ')" "0,done,1,0"
cd "$SANDBOX/p62b" || exit 1
printf 'def other():\n    return 1\n' >src/other.py
git add -A && git commit -qm "main added a module" >/dev/null
head_before="$(git rev-parse HEAD)"
rc=0
SUITE_LOG="$SANDBOX/s62b.log" "$AIF" land AIF-165 >"$OUT/land62b.out" 2>&1 || rc=$?
eq "a check bound to green, red on the result: exit 1, nothing landed, back to the worker" \
  "$rc,$(git rev-parse HEAD),$(col AIF-165)" "1,$head_before,ready"
eq "…on a sync: line naming the check" \
  "$(last_comment AIF-165 | sed -n 1p | grep -c '^sync: the check "pair" is red on ')" "1"
eq "…judged in the worktree, the suite green first" \
  "$(grep -c '/\.aif/worktrees/AIF-165$' "$SANDBOX/s62b.log" 2>/dev/null)" "1"

# ====== 63. TERM, then KILL 1.4 s later, during the verdict ===================
# One Ctrl-C in a review session sends the land TERM, and SIGKILL 1.3–1.5 s
# later (docs/DEFECTS.md 15.1; docs/FINDINGS.md #28). The land used to undo a
# merge it had made on the developer's branch, a reset the KILL could cut in
# half. Its merge is in the worktree now: the TERM puts the worktree back, and
# the KILL finds nothing. The stand-ins of scenario 27 hold the suite open
# (STOP_IN=suite); main has moved, so the land judges. One build, two copies.
#
# land_at <ticket> <stop-at> <out> [land options] — the land in the
# background, a process group of its own with SIGINT at its default (python
# puts it back, as scenario 27 says why), back once its stand-in waits.
land_at() {
  local t="$1" at="$2" out="$3" i=0
  shift 3
  rm -f "$STOP_MARK" "$STOP_GO"
  STOP_IN="$at" STOP_MARK="$STOP_MARK" STOP_GO="$STOP_GO" python3 -c '
import os, signal, sys
os.setpgrp()
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])' "$AIF" land "$t" ${1+"$@"} >"$out" 2>&1 &
  LAND_PID=$!
  while [ ! -f "$STOP_MARK" ] && [ "$i" -lt 150 ]; do
    sleep 0.1
    i=$((i + 1))
  done
}
printf '\n63. TERM to a land during its verdict, then KILL 1.4 s later: nothing landed, nothing left\n'
fresh_project "$SANDBOX/p63"
cat >.aif/stop-here.sh <<'STOP'
#!/bin/bash
[ "${STOP_IN:-}" = "$1" ] || exit 0
touch "$STOP_MARK"
i=0
while [ ! -f "$STOP_GO" ] && [ "$i" -lt 300 ]; do
  sleep 0.1
  i=$((i + 1))
done
STOP
{
  head -1 .aif/suite.sh
  printf 'bash .aif/stop-here.sh suite\n'
  tail -n +2 .aif/suite.sh
} >"$OUT/suite63" && mv "$OUT/suite63" .aif/suite.sh && chmod +x .aif/suite.sh
ticket_for AIF-170
git add -A && git commit -qm "ticket 63, a suite that can be held" >/dev/null
"$AIF" board create tasks/AIF-170/ticket.md --column ready >/dev/null
rc=0
"$AIF" work AIF-170 >"$OUT/run63.out" 2>&1 || rc=$?
printf 'notes\n' >NOTES.md
git add -A && git commit -qm "main moved" >/dev/null
eq "built, in Review; main moved since" "$rc,$(col AIF-170)" "0,review"
copy_project "$SANDBOX/p63" "$SANDBOX/p64" AIF-170
cd "$SANDBOX/p63" || exit 1
STOP_MARK="$SANDBOX/p63.at"
STOP_GO="$SANDBOX/p63.go"
head_before="$(git rev-parse HEAD)"
reflog_before="$(git reflog "$(git symbolic-ref --short HEAD)" | wc -l | tr -d ' ')"
land_at AIF-170 suite "$OUT/land63.out"
kill -TERM -- "-$LAND_PID" 2>/dev/null
sleep 1.4
kill -KILL -- "-$LAND_PID" 2>/dev/null
rc=0
wait "$LAND_PID" || rc=$?
eq "TERM, then KILL 1.4 s later: exit 143, main where it was" "$rc,$(git rev-parse HEAD)" "143,$head_before"
eq "…its reflog as long as before: nothing was written to it and taken back" \
  "$(git reflog "$(git symbolic-ref --short HEAD)" | wc -l | tr -d ' ')" "$reflog_before"
eq "…the worktree there, on its branch" "$(git -C .aif/worktrees/AIF-170 symbolic-ref --short HEAD 2>/dev/null)" "aif/AIF-170"
eq "…no land lock or marker left, the card in Review, and said" \
  "$(find .aif/state -maxdepth 1 -name 'land*' | wc -l | tr -d ' '),$(col AIF-170),$(grep -c 'terminated — nothing landed' "$OUT/land63.out")" "0,review,1"
# The land holds the ticket's worktree while it runs: a worker on that ticket
# meanwhile is refused before it touches the card. Then it lands.
land_at AIF-170 suite "$OUT/land63b.out"
rc=0
"$AIF" work AIF-170 >"$OUT/run63w.out" 2>&1 || rc=$?
eq "a worker on the ticket while its land runs: refused, exit 3, the card untouched" \
  "$rc,$(col AIF-170),$(grep -c 'aif land AIF-170 runs in this checkout right now' "$OUT/run63w.out")" "3,review,1"
touch "$STOP_GO"
rc=0
wait "$LAND_PID" || rc=$?
eq "then it lands" "$rc,$(col AIF-170)" "0,done"

# The same TERM and KILL, sent as the fast-forward starts: a branch of 30 000
# files makes it long enough to be in. It runs in a process group of its own,
# out of reach of both: main ends at the land's merge, clean, whether the land
# lived to say so (143) or was killed waiting for it (137), and the next land
# finishes the bookkeeping. A fast-forward in the land's own group stopped
# where the TERM found it, files half written, the ref not moved — and one
# that ignored the TERM still failed at its end (docs/FINDINGS.md #35).
land_built "$SANDBOX/p63c" AIF-171
python3 -c 'import os, sys
for a in range(300):
    os.makedirs("%s/big/%03d" % (sys.argv[1], a), exist_ok=True)
    for b in range(100):
        open("%s/big/%03d/f%03d.txt" % (sys.argv[1], a, b), "w").write("%d %d\n" % (a, b))' .aif/worktrees/AIF-171
git -C .aif/worktrees/AIF-171 add -A && git -C .aif/worktrees/AIF-171 -c core.hooksPath=/dev/null commit -qm "a branch of 30 000 files" >/dev/null
python3 -c '
import os, signal, subprocess, sys, time
def pre():
    os.setpgrp(); signal.signal(signal.SIGINT, signal.SIG_DFL)
p = subprocess.Popen([sys.argv[1], "land", "AIF-171"], preexec_fn=pre, stdout=open(sys.argv[3], "w"), stderr=subprocess.STDOUT)
t = time.time()
while not os.path.exists(sys.argv[2]) and p.poll() is None and time.time() - t < 120: time.sleep(0.002)
os.killpg(p.pid, signal.SIGTERM)
time.sleep(1.4)
try: os.killpg(p.pid, signal.SIGKILL)
except OSError: pass
rc = p.wait()
open(sys.argv[4], "w").write(str(128 - rc if rc < 0 else rc))' "$AIF" .aif/state/land.section "$OUT/land63c.out" "$OUT/land63c.rc"
sec63="$(cat .aif/state/land.section 2>/dev/null)"
i=0
while [ -n "$sec63" ] && kill -0 "$sec63" 2>/dev/null && [ "$i" -lt 600 ]; do
  sleep 0.1
  i=$((i + 1))
done
eq "TERM as the fast-forward starts, KILL 1.4 s later: the land stopped, main at its merge all the same, clean" \
  "$(if grep -qxE '143|137' "$OUT/land63c.rc"; then echo stopped; else cat "$OUT/land63c.rc"; fi),$(git log --format=%s -1),$(git status --porcelain --untracked-files=no | wc -l | tr -d ' '),$(jq -r .state .aif/state/land.json 2>/dev/null)" \
  "stopped,aif: land AIF-171 — one-command user export,0,landed"
rc=0
"$AIF" land AIF-171 >"$OUT/land63d.out" 2>&1 || rc=$?
eq "…and the next land finishes the bookkeeping" "$rc,$(col AIF-171),$(grep -c 'finishing the land of AIF-171' "$OUT/land63d.out")" "0,done,1"

# ====== 64. KILL alone, during the verdict =====================================
# No TERM before it — a kill -9, the power going: no handler runs. The land
# never moved main, so main is as it was; it leaves the worktree off its
# branch and its marker, which aif doctor names, the worker puts back, and the
# next land settles.
printf '\n64. KILL alone during the verdict: main untouched, the next run and the next land put back what it left\n'
cd "$SANDBOX/p64" || exit 1
STOP_MARK="$SANDBOX/p64.at"
STOP_GO="$SANDBOX/p64.go"
head_before="$(git rev-parse HEAD)"
land_at AIF-170 suite "$OUT/land64.out"
lpid="$LAND_PID"
kill -KILL "$lpid" 2>/dev/null
kill -KILL -- "-$lpid" 2>/dev/null
wait "$lpid" 2>/dev/null
eq "KILL during the verdict: main where it was, this checkout clean" \
  "$(git rev-parse HEAD),$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')" "$head_before,0"
eq "…the worktree left there, detached" \
  "$([ -e .aif/worktrees/AIF-170/.git ] && echo there),$(git -C .aif/worktrees/AIF-170 symbolic-ref -q HEAD >/dev/null 2>&1 && echo attached || echo detached)" "there,detached"
eq "aif doctor names the land that died there" \
  "$("$AIF" doctor 2>&1 | grep -c "a land of AIF-170 (pid $lpid, gone) stopped before its fast-forward")" "1"
rc=0
"$AIF" work AIF-170 >"$OUT/run64b.out" 2>&1 || rc=$?
eq "aif work puts the worktree back on its branch, says so, and builds" \
  "$rc,$(col AIF-170),$(grep -c 'back on aif/AIF-170' "$OUT/run64b.out")" "0,review,1"
rc=0
"$AIF" land AIF-170 >"$OUT/land64c.out" 2>&1 || rc=$?
eq "the next land says what it settled, and lands" \
  "$rc,$(col AIF-170),$(grep -c "an earlier land of AIF-170 (pid $lpid) stopped before it moved" "$OUT/land64c.out")" "0,done,1"

# ====== 65. what only a KILL of the fast-forward itself leaves ================
# The fast-forward runs where no signal to the land reaches it, in tens of
# milliseconds — only a KILL of that step itself, or the power going, stops it
# half way, and no signal can be timed into it. So what it leaves is built by
# hand: the marker as the land writes it, and git as it would be. Built at
# landed — the branch moved, the bookkeeping not begun — the next land
# finishes it without judging again; in its fast-forward with git's lock
# left, the next land names the lock and touches nothing; without the lock,
# the ticket's own files come back from aside, said, and the land goes on.
printf '\n65. what a KILL of the fast-forward itself leaves: finished, or named, or put back\n'
fresh_project "$SANDBOX/p65"
{
  head -1 .aif/suite.sh
  # shellcheck disable=SC2016  # a line of the suite being written, expanded when it runs
  printf '[ -z "${SUITE_LOG:-}" ] || pwd -P >>"$SUITE_LOG"\n'
  tail -n +2 .aif/suite.sh
} >"$OUT/suite65" && mv "$OUT/suite65" .aif/suite.sh && chmod +x .aif/suite.sh
git add -A && git commit -qm "a suite that says where it ran" >/dev/null
ticket_for AIF-175
"$AIF" board create tasks/AIF-175/ticket.md --column ready >/dev/null
rc=0
"$AIF" work AIF-175 >"$OUT/run65.out" 2>&1 || rc=$?
eq "built, the analyst's ticket left uncommitted here" "$rc,$(col AIF-175),$(git status --porcelain tasks/AIF-175 | cut -c1-2)" "0,review,??"
copy_project "$SANDBOX/p65" "$SANDBOX/p65b" AIF-175
cd "$SANDBOX/p65" || exit 1
sleep 30 &
gone65=$!
kill "$gone65" 2>/dev/null
wait "$gone65" 2>/dev/null
target65="$(git symbolic-ref --short HEAD)"
pre65="$(git rev-parse HEAD)"
w065="$(git rev-parse aif/AIF-175)"
mv tasks/AIF-175 "$OUT/aside65" # what the land takes aside, as it would
git merge -q --no-ff -m "aif: land AIF-175 — one-command user export" aif/AIF-175 >/dev/null 2>&1
merge65="$(git rev-parse HEAD)"
jq -n --arg t AIF-175 --argjson pid "$gone65" --arg tg "$target65" --arg pre "$pre65" --arg w0 "$w065" --arg m "$merge65" \
  '{ ticket: $t, pid: $pid, started_at: "2026-10-08T00:00:00Z", target: $tg, pre: $pre, branch: $w0, merge: $m,
     worktree: ".aif/worktrees/AIF-175", made_worktree: false, installed_in_worktree: false, keep: false,
     prepare_here: null, aside_dir: null, aside: [], state: "landed", done: [], at: "2026-10-08T00:00:01Z" }' >.aif/state/land.json
rc=0
SUITE_LOG="$SANDBOX/s65.log" "$AIF" land AIF-175 >"$OUT/land65a.out" 2>&1 || rc=$?
eq "a land gone after its fast-forward is finished by the next one: exit 0, Done, said" \
  "$rc,$(col AIF-175),$(grep -c 'finishing the land of AIF-175' "$OUT/land65a.out")" "0,done,1"
eq "…one landing note, one land commit, no suite run, the worktree and the branch gone, no marker left" \
  "$("$AIF" board show AIF-175 --json | jq '[ .comments[] | select(.text | startswith("# AIF-175 — landed")) ] | length'),$(git log --format=%s | grep -c '^aif: land AIF-175 — '),$(cat "$SANDBOX/s65.log" 2>/dev/null | wc -l | tr -d ' '),$([ -e .aif/worktrees/AIF-175 ] && echo wt),$(git show-ref --verify --quiet refs/heads/aif/AIF-175 && echo branch),$([ -e .aif/state/land.json ] && echo marker)" \
  "1,1,0,,,"
# In its fast-forward: the merge made in the worktree, the analyst's ticket
# aside, main at the tip the land found — and git's own lock left.
cd "$SANDBOX/p65b" || exit 1
pre65="$(git rev-parse HEAD)"
w065="$(git rev-parse aif/AIF-175)"
git -C .aif/worktrees/AIF-175 checkout -q --detach "$pre65" >/dev/null 2>&1
git -C .aif/worktrees/AIF-175 merge -q --no-ff -m "aif: land AIF-175 — one-command user export" "$w065" >/dev/null 2>&1
merge65="$(git -C .aif/worktrees/AIF-175 rev-parse HEAD)"
aside65=".aif/tmp/land-AIF-175-20261008T000000Z"
mkdir -p "$aside65/tasks/AIF-175" && mv tasks/AIF-175/ticket.md "$aside65/tasks/AIF-175/ticket.md"
jq -n --arg t AIF-175 --argjson pid "$gone65" --arg tg "$(git symbolic-ref --short HEAD)" --arg pre "$pre65" --arg w0 "$w065" \
  --arg m "$merge65" --arg ad "$aside65" \
  '{ ticket: $t, pid: $pid, started_at: "2026-10-08T00:00:00Z", target: $tg, pre: $pre, branch: $w0, merge: $m,
     worktree: ".aif/worktrees/AIF-175", made_worktree: false, installed_in_worktree: false, keep: false,
     prepare_here: null, aside_dir: $ad, aside: ["tasks/AIF-175/ticket.md"], state: "ff", done: [], at: "2026-10-08T00:00:01Z" }' >.aif/state/land.json
touch .git/index.lock
rc=0
"$AIF" land AIF-175 >"$OUT/land65c.out" 2>&1 || rc=$?
eq "in its fast-forward, git's lock left: exit 3, naming it — nothing touched, the card in Review" \
  "$rc,$(grep -c 'rm .git/index.lock, then aif land AIF-175' "$OUT/land65c.out"),$(git rev-parse HEAD),$([ -f "$aside65/tasks/AIF-175/ticket.md" ] && echo aside),$([ -f .aif/state/land.json ] && echo marker),$(col AIF-175)" \
  "3,1,$pre65,aside,marker,review"
rm -f .git/index.lock
rc=0
"$AIF" land AIF-175 >"$OUT/land65b.out" 2>&1 || rc=$?
eq "without the lock: main is back where the land found it, the ticket's own file back from aside, said — then it lands" \
  "$rc,$(col AIF-175),$(grep -c 'stopped in its fast-forward — .* is back at .*, as it was; the ticket.s own files are back from .aif/tmp/land-AIF-175-20261008T000000Z: tasks/AIF-175/ticket.md' "$OUT/land65b.out")" \
  "0,done,1"

# ====== 66. the land's merge commit runs the project's hooks ==================
# Every commit aif makes on its own behalf skips the project's hooks (scenario
# 86); the land's merge commit is the one they are for (docs/DEFECTS.md 13.11),
# and a clean `git merge` runs no pre-commit at all. The land commits its merge
# itself, in the worktree, with the hooks: a refusal is a land: line for a
# human, nothing landed. The hook logs where it ran.
printf '\n66. the land'"'"'s merge commit runs the project'"'"'s hooks, the worker'"'"'s git none of them\n'
fresh_project "$SANDBOX/p66"
ticket_for AIF-180
git add -A && git commit -qm "ticket 66" >/dev/null
"$AIF" board create tasks/AIF-180/ticket.md --column ready >/dev/null
HOOK_LOG66="$SANDBOX/p66-hooks.log"
HOOK_PASS66="$SANDBOX/p66-pass"
cat >.git/hooks/pre-commit <<HOOK
#!/bin/sh
printf '%s\n' "\$PWD" >>"$HOOK_LOG66"
[ -f "$HOOK_PASS66" ] && exit 0
echo "lint: 3 problems"
exit 1
HOOK
printf '#!/bin/sh\nexit 7\n' >.git/hooks/post-checkout
chmod +x .git/hooks/pre-commit .git/hooks/post-checkout
rc=0
"$AIF" work AIF-180 >"$OUT/run66.out" 2>&1 || rc=$?
eq "the worker builds under a failing pre-commit and a post-checkout that exits 7, running neither" \
  "$rc,$(col AIF-180),$(cat "$HOOK_LOG66" 2>/dev/null | wc -l | tr -d ' ')" "0,review,0"
head_before="$(git rev-parse HEAD)"
rc=0
"$AIF" land AIF-180 >"$OUT/land66a.out" 2>&1 || rc=$?
eq "the land's merge commit runs pre-commit, which refuses it: exit 1, Needs Human, nothing landed" \
  "$rc,$(col AIF-180),$(git rev-parse HEAD)" "1,needs_human,$head_before"
eq "…on a land: line, the hook's own words on the card" \
  "$(last_comment AIF-180 | sed -n 1p | grep -c "^land: the project's git hooks refused the land's merge commit"),$(last_comment AIF-180 | grep -c 'lint: 3 problems')" "1,1"
eq "…the hook ran once, in the ticket's worktree" \
  "$(cat "$HOOK_LOG66" | wc -l | tr -d ' '),$(grep -c '\.aif/worktrees/AIF-180$' "$HOOK_LOG66")" "1,1"
: >"$HOOK_PASS66"
rc=0
{ "$AIF" board move AIF-180 review && "$AIF" land AIF-180; } >"$OUT/land66b.out" 2>&1 || rc=$?
eq "the hook satisfied: landed, Done" "$rc,$(col AIF-180),$(git log --format=%s -1)" "0,done,aif: land AIF-180 — one-command user export"

# ====== 67. the target moves while the land runs ===============================
# A person committing in another terminal — here a pre-commit hook of the
# land's own merge commit, which commits in the checkout — moves the branch
# the land judged a merge onto. The land lands nothing then: the card stays
# in Review, and it says so.
printf '\n67. the target moves while the land runs: nothing landed, said\n'
land_built "$SANDBOX/p67" AIF-185
eq "built, in Review" "$(col AIF-185)" "review"
main67="$(pwd -P)"
cat >.git/hooks/pre-commit <<HOOK
#!/bin/sh
cd "$main67" && env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE git commit -q --allow-empty --no-verify -m "a commit made meanwhile" >/dev/null 2>&1
exit 0
HOOK
chmod +x .git/hooks/pre-commit
rc=0
"$AIF" land AIF-185 >"$OUT/land67.out" 2>&1 || rc=$?
eq "the branch moved during the land: exit 1, the card in Review, main at that commit, no land commit" \
  "$rc,$(col AIF-185),$(git log --format=%s -1),$(git log --format=%s | grep -c '^aif: land AIF-185')" "1,review,a commit made meanwhile,0"
eq "…said, and the worktree back on its branch" \
  "$(grep -c 'moved while the land ran' "$OUT/land67.out"),$(git -C .aif/worktrees/AIF-185 symbolic-ref --short HEAD 2>/dev/null)" "1,aif/AIF-185"

# ====== 80. the runner's usage limit pauses the run, outside the wall clock ===
# docs/DEFECTS.md 13.7. A station that met the account's usage limit returned
# an envelope with is_error, and the worker billed it to the station: the
# gate judged what the refused run left, rejected it, the retry met the same
# refusal at once, and the second identical complaint stopped the run
# blocked: run. The limit is read off the stream now (its rate_limit_event,
# docs/FINDINGS.md #30): a reset within what a run waits is a pause — the
# shared one, .aif/state/pause — and the same attempt is dispatched again
# once it is over, uncounted, the wait outside the wall clock. Here the reset
# is 24 s off and the wall clock 20 s: counted, the pause alone would stop the
# run. The claim beats while the worker waits (14.4's heartbeat, each second
# here), or another machine's shift would read a paused worker as gone.
printf '\n80. the runner'"'"'s usage limit pauses the run, and the same attempt runs again outside the wall clock\n'
fresh_project "$SANDBOX/p80"
ticket_for AIF-800
git add -A && git commit -qm "one to pause" >/dev/null
"$AIF" board create tasks/AIF-800/ticket.md --column ready >/dev/null
FAKE_LIMIT_ONCE=AIF-800:tests:24 AIF_PAUSE_MARGIN_SECS=0 AIF_WORK_MAX_SECS=20 AIF_WORK_BEAT_SECS=1 \
  "$AIF" work AIF-800 --no-worktree >"$OUT/run80.out" 2>&1 &
w80=$!
wait_count "$OUT/run80.out" 'paused until' 1 30
claim80() { "$AIF" board show AIF-800 --json | jq -r --arg c "$(cat .aif/state/runs/AIF-800/claim.id 2>/dev/null)" '[.comments[] | select(.id == $c)][0].text // "" | split("\n")[0]'; }
beat80a="$(claim80)"
sleep 2.5
beat80b="$(claim80)"
pause80="$(cat .aif/state/pause 2>/dev/null)"
rc=0
wait_exit "$w80" 120 || rc=$?
eq "a limit whose reset is 24 s off under a wall clock of 20 s: built — the wait outside the clock — the tests station dispatched twice, one attempt counted, no runner error billed to it" \
  "$rc,$(col AIF-800),$(cat .aif/tmp/fake-tests.count 2>/dev/null),$(jq -r '.attempts.tests' tasks/AIF-800/run.json),$(jq -r '(.station_errors // []) | length' tasks/AIF-800/run.json)" \
  "0,review,2,1,0"
eq "…the wait in the run's record: a limit, five_hour, 23 s or more, what the stream said kept beside it" \
  "$(jq -r '(.runner_waits // []) | length' tasks/AIF-800/run.json),$(jq -r '(.runner_waits // [])[0] | [.class, .type, (.waited_s >= 23), .rate_limit.status, .api_error, .turns] | map(tostring) | join(",")' tasks/AIF-800/run.json)" \
  "1,limit,five_hour,true,rejected,rate_limit,1"
eq "…said once; the pause written for the whole checkout, by AIF-800; the claim beating while it waited" \
  "$(grep -c 'paused until' "$OUT/run80.out"),$(printf '%s' "$pause80" | awk '{ print $2 " " $3 " " $4 }'),$([ -n "$beat80a" ] && [ "$beat80a" != "$beat80b" ] && echo beat || echo "silent: $beat80a")" \
  "1,all five_hour AIF-800,beat"
# shellcheck disable=SC2016  # the backticks are the report's markdown
eq "…the retry told that its run before was cut off after a turn; the report says how long it waited, and on what" \
  "$(grep -c "Your previous run of this same attempt ended early — the runner's usage limit — after 1 turn(s)" .aif/tmp/fake-prompt-tests-2 2>/dev/null),$(grep -c '· waited [0-9]* s on the runner ·' tasks/AIF-800/report.md),$(grep -c '^- `tests` attempt 1 — limit (five_hour)' tasks/AIF-800/report.md)" \
  "1,1,1"

# ====== 81. a limit with no reset, or one past what a run waits ================
# docs/DEFECTS.md 13.7, 13.8. A limit that names no reset — a credit limit —
# or one whose reset is further off than a run waits (a weekly reset days
# away; AIF_PAUSE_MAX_SECS=5 here, its 12 h) is no pause: the run stops on
# the environment, naming it, and leaves the pause as a hold, on which the
# loop stops taking cards — read before the loop asks the machine again,
# which would pass and take the next card into the same refusal.
printf '\n81. a limit with no reset, or one past what a run waits, is the environment, and the loop holds on it\n'
fresh_project "$SANDBOX/p81"
ticket_for AIF-810
ticket_for AIF-811
ticket_for AIF-812
git add -A && git commit -qm "three" >/dev/null
for t in AIF-810 AIF-811; do
  "$AIF" board create "tasks/$t/ticket.md" --column ready >/dev/null
done
rc=0
FAKE_LIMIT_NORESET=AIF-810:plan AIF_WORK_LOOP_LOGDIR="$SANDBOX/p81-loop" "$AIF" work --loop --parallel 1 --no-tui >"$OUT/run81.out" 2>&1 || rc=$?
S81="$SANDBOX/p81-loop/summary.json"
eq "a credit limit with no reset at the first card's plan: the loop stops on the environment — exit 3, the second card left in Ready, env 1" \
  "$rc,$(col AIF-810),$(col AIF-811),$(jq -r '.env' "$S81" 2>/dev/null)" "3,needs_human,ready,1"
eq "…the card says the runner's limit, named, no reset — the environment, mid-run; the plan station tried once" \
  "$("$AIF" board head AIF-810 | grep -c "^blocked: environment — the runner's usage limit (the usage credit limit): no reset named — longer than a run waits (You're out of usage credits)$"),$(last_comment AIF-810 | grep -c '^This machine or the runner, not the ticket'),$(cat .aif/worktrees/AIF-810/.aif/tmp/fake-plan.count 2>/dev/null)" \
  "1,1,1"
eq "…the hold it stopped on: no reset, every station, the credit limit, by AIF-810; the loop's reason names it, and nothing was asked of the machine again" \
  "$(awk '{ print $1 " " $2 " " $3 " " $4 }' .aif/state/pause 2>/dev/null),$(jq -r '.why' "$S81" 2>/dev/null | grep -c "^the runner's usage limit (the usage credit limit): no reset named — longer than the loop waits; no new card (rm .aif/state/pause to try anyway)$"),$(jq -r '.rechecks' "$S81" 2>/dev/null)" \
  "0 all overage AIF-810,1,0"
rm -f .aif/state/pause
rc=0
FAKE_LIMIT_ONCE=AIF-812:plan:60 AIF_PAUSE_MAX_SECS=5 "$AIF" work AIF-812 --no-worktree >"$OUT/run81b.out" 2>&1 || rc=$?
eq "a limit whose reset is past what a run waits: the environment, naming the reset's time; the attempt not counted" \
  "$rc,$(col AIF-812),$("$AIF" board head AIF-812 | grep -cE "^blocked: environment — the runner's usage limit \(the session limit\): resets [0-9]{2}:[0-9]{2} — longer than a run waits"),$(jq -r '.attempts.plan' tasks/AIF-812/run.json)" \
  "1,needs_human,1,0"
rm -f .aif/state/pause

# ====== 82. the server's throttle and an overload, asked again ================
# docs/DEFECTS.md 13.7. A runner that did not answer — the server's throttle,
# a 529 — is asked again after a backoff, the attempt uncounted, and none of
# it billed to the station. The throttle's own words are "Server is
# temporarily limiting requests (not your usage limit)": read as prose it is a
# usage limit, and the run would pause for nothing. It is told apart by its
# fields — a rejected event with no rateLimitType (docs/FINDINGS.md #27, #30).
printf '\n82. the server'"'"'s throttle and an overload are asked again, uncounted, and the throttle'"'"'s words are not read as a limit\n'
fresh_project "$SANDBOX/p82"
ticket_for AIF-820
git add -A && git commit -qm "one to throttle" >/dev/null
"$AIF" board create tasks/AIF-820/ticket.md --column ready >/dev/null
rc=0
FAKE_THROTTLE_ONCE=AIF-820:plan FAKE_TRANSIENT_ONCE=AIF-820:tests AIF_TRANSIENT_BACKOFF=0 \
  "$AIF" work AIF-820 --no-worktree >"$OUT/run82.out" 2>&1 || rc=$?
eq "built: the plan and the tests station each dispatched twice, each counted once" \
  "$rc,$(col AIF-820),$(cat .aif/tmp/fake-plan.count 2>/dev/null),$(cat .aif/tmp/fake-tests.count 2>/dev/null),$(jq -r '[.attempts.plan, .attempts.tests] | map(tostring) | join("/")' tasks/AIF-820/run.json)" \
  "0,review,2,2,1/1"
eq "…each wait recorded by what said it — the throttle's 429, the 529 — no runner error billed, no pause written" \
  "$(jq -r '[(.runner_waits // [])[] | .class + ":" + .type] | join(" ")' tasks/AIF-820/run.json),$(jq -r '(.station_errors // []) | length' tasks/AIF-820/run.json),$(test -f .aif/state/pause && echo paused || echo none)" \
  "transient:rate_limit-429 transient:server_error-529,0,none"
eq "…said as the runner's, with the attempt uncounted" \
  "$(grep -c 'plan — rate_limit-429: API Error: Server is temporarily limiting requests (not your usage limit)' "$OUT/run82.out"),$(grep -c 'again in 0s (attempt uncounted)' "$OUT/run82.out")" "1,2"

# ====== 83. a runner that wrote nothing, or not JSON ===========================
# docs/DEFECTS.md 13.7, 13.8. A runner that produced no envelope — the
# network, a CLI that could not start — stopped the run blocked: run on one
# try, so the loop counted it against the cards toward two in a row and never
# asked the machine; an envelope that was not JSON ended the worker under
# set -e, code 5. Both are asked again after a backoff now, then the
# environment: blocked: environment, which the loop reads as the machine.
printf '\n83. a runner that wrote nothing, or not JSON: asked again, then the environment — never the station, never a dead worker\n'
fresh_project "$SANDBOX/p83"
ticket_for AIF-830
ticket_for AIF-831
git add -A && git commit -qm "two" >/dev/null
for t in AIF-830 AIF-831; do
  "$AIF" board create "tasks/$t/ticket.md" --column ready >/dev/null
done
rc=0
FAKE_NOENVELOPE=AIF-830:tests AIF_TRANSIENT_BACKOFF="0 0" "$AIF" work AIF-830 >"$OUT/run83a.out" 2>&1 || rc=$?
eq "no envelope from the tests station, every try: asked three times, then blocked: environment — exit 1, the attempt not counted" \
  "$rc,$(cat .aif/worktrees/AIF-830/.aif/tmp/fake-tests.count 2>/dev/null),$(col AIF-830),$("$AIF" board head AIF-830 | grep -c '^blocked: environment — the runner did not answer for the tests station — no-envelope: claude: the API could not be reached, 3 tries over '),$(jq -r '.attempts.tests' .aif/worktrees/AIF-830/tasks/AIF-830/run.json)" \
  "1,3,needs_human,1,0"
rc=0
FAKE_NOTJSON=AIF-831:plan:1 AIF_TRANSIENT_BACKOFF=0 "$AIF" work AIF-831 >"$OUT/run83b.out" 2>&1 || rc=$?
eq "a plan station whose first try printed a line that is not JSON: asked again and built — the worker does not die of it" \
  "$rc,$(col AIF-831),$(jq -r '.attempts.plan' .aif/worktrees/AIF-831/tasks/AIF-831/run.json),$(jq -r '[(.runner_waits // [])[] | .type] | join(" ")' .aif/worktrees/AIF-831/tasks/AIF-831/run.json)" \
  "0,review,1,not-json"
fresh_project "$SANDBOX/p83c"
ticket_for AIF-832
ticket_for AIF-833
git add -A && git commit -qm "two for the loop" >/dev/null
for t in AIF-832 AIF-833; do
  "$AIF" board create "tasks/$t/ticket.md" --column ready >/dev/null
done
rc=0
FAKE_NOENVELOPE=AIF-832:plan AIF_TRANSIENT_BACKOFF=0 AIF_WORK_LOOP_LOGDIR="$SANDBOX/p83-loop" \
  "$AIF" work --loop --parallel 1 --no-tui >"$OUT/run83c.out" 2>&1 || rc=$?
eq "in a loop, a card whose runner never answered is the machine's: the machine asked again, and the next card built — one re-check, not one of two in a row" \
  "$rc,$(col AIF-832),$(col AIF-833),$(grep -c 'AIF-832 could not start (exit 1) — checking the machine again' "$OUT/run83c.out"),$(jq -r '.rechecks' "$SANDBOX/p83-loop/summary.json" 2>/dev/null)" \
  "1,needs_human,review,1,1"

# ====== 84. the pause is shared ===============================================
# docs/DEFECTS.md 13.7. One worker meets the limit; every other process of
# the checkout reads it from .aif/state/pause, written here by hand: a worker
# waits before its station starts, the loop takes no card until the pause is
# over and says so, and a pause for one model's limit (the weekly Opus one)
# holds only the stations that ask for that model.
printf '\n84. the pause is shared: a worker, a loop, and only the stations of the model it holds\n'
pause84() { # <seconds from now> <scope> <type>
  mkdir -p .aif/state
  printf '%s %s %s AIF-999 %s written by the harness\n' "$(($(date +%s) + $1))" "$2" "$3" "$(date +%s)" >.aif/state/pause
}
fresh_project "$SANDBOX/p84"
ticket_for AIF-840
git add -A && git commit -qm "one" >/dev/null
"$AIF" board create tasks/AIF-840/ticket.md --column ready >/dev/null
pause84 5 all five_hour
rc=0
"$AIF" work AIF-840 --no-worktree >"$OUT/run84a.out" 2>&1 || rc=$?
eq "aif work alone with a pause in force: it waits before its first station says it starts, then builds" \
  "$rc,$(col AIF-840),$(awk '/paused until/ && !p { p = NR } /^station .*plan ·/ && !s { s = NR } END { print (p > 0 && s > p) ? "pause first" : "pause " p ", station " s }' "$OUT/run84a.out")" \
  "0,review,pause first"
fresh_project "$SANDBOX/p84b"
ticket_for AIF-841
ticket_for AIF-842
git add -A && git commit -qm "two" >/dev/null
for t in AIF-841 AIF-842; do
  "$AIF" board create "tasks/$t/ticket.md" --column ready >/dev/null
done
pause84 8 all five_hour
rc=0
AIF_WORK_LOOP_LOGDIR="$SANDBOX/p84-loop" "$AIF" work --loop --parallel 1 --no-tui >"$OUT/run84b.out" 2>&1 || rc=$?
eq "a loop over two cards with a pause in force: says it, takes nothing until the pause is over, then builds both" \
  "$rc,$(col AIF-841),$(col AIF-842),$(awk '/paused until .*met by AIF-999; no new card until then/ && !p { p = NR } /the pause is over — taking cards again/ && !o { o = NR } /loop 1 — AIF-841/ && !t { t = NR } END { print (p && o > p && t > o) ? "in order" : p " " o " " t }' "$OUT/run84b.out")" \
  "0,review,review,in order"
fresh_project "$SANDBOX/p84c"
ticket_for AIF-843
sed 's/^model: .*/model: sonnet/' .claude/agents/aif-plan.md >"$OUT/plan84.md" && cat "$OUT/plan84.md" >.claude/agents/aif-plan.md
git add -A && git commit -qm "one, its plan station on sonnet" >/dev/null
"$AIF" board create tasks/AIF-843/ticket.md --column ready >/dev/null
pause84 6 opus seven_day_opus
rc=0
"$AIF" work AIF-843 --no-worktree >"$OUT/run84c.out" 2>&1 || rc=$?
eq "a pause for the weekly Opus limit: the plan station, on sonnet here, runs at once; the tests station, opus, waits for it; built" \
  "$rc,$(col AIF-843),$(awk '/^station .*plan ·/ && !a { a = NR } /paused until .*the weekly Opus limit/ && !p { p = NR } /^station .*tests ·/ && !t { t = NR } END { print (a && p > a && t > p) ? "plan, pause, tests" : a " " p " " t }' "$OUT/run84c.out")" \
  "0,review,plan, pause, tests"
rm -f .aif/state/pause

# ====== 85. stopped while it waits for the runner's limit ======================
# docs/DEFECTS.md 13.7. A stop, a Ctrl-C or a hang-up that comes while a
# worker waits out a pause runs its handler at once — the wait is spent in the
# wait builtin, a second at a time — and the card says the run was paused;
# the attempt the stage loop counted for the dispatch is taken back, since
# nothing judged it, and back in Ready the card resumes the same one.
printf '\n85. a run stopped while it waits for the runner'"'"'s limit: the card says so, and the attempt is not counted\n'
fresh_project "$SANDBOX/p85"
ticket_for AIF-850
git add -A && git commit -qm "one" >/dev/null
"$AIF" board create tasks/AIF-850/ticket.md --column ready >/dev/null
pause84 60 all five_hour
set -m
"$AIF" work AIF-850 --no-worktree >"$OUT/run85.out" 2>&1 &
w85=$!
set +m
wait_count "$OUT/run85.out" 'paused until' 1 30
st85="$("$AIF" work --status AIF-850 --json 2>/dev/null)"
eq "while it waits: aif work --status says the worker is live and paused until when, its lock the reset" \
  "$(printf '%s' "$st85" | jq -r '.class'),$(printf '%s' "$st85" | jq -r '.why' | grep -cE "^being built here — its worker \(pid [0-9]+\) is at plan, attempt 1, paused until [0-9]{2}:[0-9]{2} for the runner's usage limit$"),$(printf '%s' "$st85" | jq -r '(.lock.paused_until // 0) > now')" \
  "live,1,true"
t0="$(date +%s)"
rc=0
"$AIF" work AIF-850 --stop >"$OUT/run85-stop.out" 2>&1 || rc=$?
rc1=0
wait_exit "$w85" 30 || rc1=$?
eq "--stop while the plan station waits out the pause: the worker ends 143, in seconds" \
  "$rc,$rc1,$([ $(($(date +%s) - t0)) -lt 15 ] && echo prompt || echo slow)" "0,143,prompt"
eq "…the card says who stopped it, during plan, paused for the runner's usage limit until when; the attempt taken back, the station never run" \
  "$(col AIF-850)|$("$AIF" board head AIF-850 | grep -cE "^blocked: stopped — by Work \(aif work AIF-850 --stop\), during plan, paused for the runner's usage limit until [0-9]{2}:[0-9]{2}$")|$(jq -r '.attempts.plan' tasks/AIF-850/run.json)|$(test -f .aif/tmp/fake-plan.count && echo ran || echo never)" \
  "needs_human|1|0|never"
rm -f .aif/state/pause
"$AIF" board move AIF-850 ready >/dev/null
rc=0
"$AIF" work AIF-850 --no-worktree >"$OUT/run85b.out" 2>&1 || rc=$?
eq "…the pause lifted by hand and the card back in Ready: it resumes and builds, the plan counted once" \
  "$rc,$(col AIF-850),$(jq -r '.attempts.plan' tasks/AIF-850/run.json)" "0,review,1"

# ====== 86. the worker's own git runs none of the project's hooks ==============
# docs/DEFECTS.md 13.11. Every commit the worker makes on aif/<ID> — intake,
# each admitted station (aif _commit), the report, the sync — ran the
# project's hooks: a pre-commit that fails stopped a run as the tool's fault
# and skipped the commits made with `|| true`, one that rewrites what it is
# given changed frozen tests after their hashes were taken, and a
# post-checkout that fails made `git worktree add` exit after the worktree was
# cut. `--no-verify` would skip pre-commit and commit-msg alone. Every hook a
# git command of the worker's can run is installed here, each writing its name
# to a log; the land's own commit is the one the project's hooks are for.
printf '\n86. the worker'"'"'s own commits, merge and checkouts run none of the project'"'"'s hooks\n'
fresh_project "$SANDBOX/p86"
ticket_for AIF-860
ticket_for AIF-861
ticket_for AIF-862
git add -A && git commit -qm "three under hooks" >/dev/null
for t in AIF-860 AIF-861 AIF-862; do
  "$AIF" board create "tasks/$t/ticket.md" --column ready >/dev/null
done
H86="$SANDBOX/hooks86.log"
hooks86() { # <pre-commit's body> <post-checkout's exit> — every hook logging its name
  local h
  for h in prepare-commit-msg commit-msg post-commit post-merge pre-merge-commit post-rewrite reference-transaction post-index-change; do
    printf '#!/bin/sh\nprintf "%%s %%s\\n" %s "$*" >>"%s"\n' "$h" "$H86" >".git/hooks/$h"
  done
  printf '#!/bin/sh\nprintf "post-checkout %%s\\n" "$*" >>"%s"\nexit %s\n' "$H86" "$2" >.git/hooks/post-checkout
  printf '#!/bin/sh\nprintf "pre-commit\\n" >>"%s"\n%s\n' "$H86" "$1" >.git/hooks/pre-commit
  chmod +x .git/hooks/*
  : >"$H86"
}
hooks86 'exit 1' 7
rc=0
"$AIF" work AIF-860 >"$OUT/run86a.out" 2>&1 || rc=$?
eq "a pre-commit that fails and a post-checkout that exits 7: the worktree cut, the run built to Review, every commit made" \
  "$rc,$(col AIF-860),$(git log --format=%s aif/AIF-860 | grep -c '^aif: ')" "0,review,5"
eq "…and not one hook ran" "$(wc -l <"$H86" | tr -d ' ')" "0"
# shellcheck disable=SC2016  # the hook's own $f, expanded when the hook runs
hooks86 'git diff --cached --name-only | while IFS= read -r f; do printf "# formatted\\n" >>"$f"; git add -- "$f"; done' 0
rc=0
"$AIF" work AIF-861 >"$OUT/run86b.out" 2>&1 || rc=$?
eq "a pre-commit that rewrites every file it is given (and a post-checkout that passes): built, the frozen test as the tests station wrote it, not one hook run" \
  "$rc,$(col AIF-861),$(git show aif/AIF-861:tests/t1.py 2>/dev/null | grep -c '# formatted'),$(wc -l <"$H86" | tr -d ' ')" "0,review,0,0"
hooks86 'exit 1' 7
FAKE_SLEEP_IN="AIF-862:implement" FAKE_RELEASE="$OUT/release86" "$AIF" work AIF-862 >"$OUT/run86c.out" 2>&1 &
w86=$!
wait_file .aif/worktrees/AIF-862/.aif/tmp/fake-running-AIF-862-implement 60
printf 'notes\n' >notes86.md
git -c core.hooksPath=/dev/null add notes86.md && git -c core.hooksPath=/dev/null commit -qm "the target moves" >/dev/null
: >"$H86"
: >"$OUT/release86"
rc=0
wait_exit "$w86" 90 || rc=$?
eq "the branch it lands on moved meanwhile: brought onto it — the sync's merge and its commit — and still not one hook run" \
  "$rc,$(col AIF-862),$(git log --format=%s aif/AIF-862 | grep -c '^aif: sync AIF-862 onto '),$(wc -l <"$H86" | tr -d ' ')" "0,review,1,0"
rm -f .git/hooks/pre-commit .git/hooks/post-checkout

# ====== 87. a station's model the profile does not map ========================
# docs/DEFECTS.md 14.6. The worker resolved opus, sonnet and haiku through
# the profile and sent anything else as it was — `fable` under a profile that
# routes the other three went to that endpoint, which never heard of it, at
# the first station that asked for it, a card already taken. The preflight
# refuses it now, before the claim, naming the station and what the profile
# maps — the shift's rule, so `default`, which the CLI resolves to opus or
# sonnet, passes where both are mapped, as a station that names no model does.
printf '\n87. a station whose model the profile does not map is refused before the claim, naming it and what the profile maps\n'
fresh_project "$SANDBOX/p87"
ticket_for AIF-870
git add -A && git commit -qm "one" >/dev/null
"$AIF" board create tasks/AIF-870/ticket.md --column ready >/dev/null
X87="$SANDBOX/xdg87"
mkdir -p "$X87/aif/profiles"
profile87() { # <name> <the alias lines> — a profile of the developer's own, routed to another endpoint
  {
    printf 'AIF_PROFILE_DESC="routed (check-work 87)"\nAIF_PROFILE_RUNNER="claude"\nAIF_PROFILE_SET="claude"\n'
    printf 'AIF_PROFILE_SECRET_VAR=""\nAIF_PROFILE_SECRET_TARGET=""\nAIF_PROFILE_ISOLATE_CONFIG="0"\n'
    printf 'aif_profile_env() {\n  printf "%%s\\n" ANTHROPIC_BASE_URL=http://127.0.0.1:9/anthropic %s\n}\n' "$2"
  } >"$X87/aif/profiles/$1.profile"
}
profile87 routed87 "ANTHROPIC_DEFAULT_OPUS_MODEL=routed-large ANTHROPIC_DEFAULT_SONNET_MODEL=routed-large ANTHROPIC_DEFAULT_HAIKU_MODEL=routed-small"
profile87 haiku87 "ANTHROPIC_DEFAULT_HAIKU_MODEL=routed-small"
model87() { # <model> — the plan station asks for it, committed
  sed "s/^model: .*/model: $1/" .claude/agents/aif-plan.md >"$OUT/plan87.md" && cat "$OUT/plan87.md" >.claude/agents/aif-plan.md
  git add -A && git commit -qm "the plan station on $1" >/dev/null
}
model87 fable
rc=0
XDG_CONFIG_HOME="$X87" "$AIF" work AIF-870 --profile routed87 --no-worktree >"$OUT/run87a.out" 2>&1 || rc=$?
eq "the plan station asks for fable, which the profile does not route: refused, exit 3, naming the station and what the profile maps" \
  "$rc,$(grep -c 'the profile routed87 does not map the model a station asks for — aif-plan asks for fable (it maps opus, sonnet, haiku)' "$OUT/run87a.out")" "3,1"
eq "…before the claim: the card still in Ready, no run lock, no station run" \
  "$(col AIF-870),$(test -d .aif/state/runs/AIF-870 && echo held || echo none),$(test -f .aif/tmp/fake-plan.count && echo ran || echo never)" "ready,none,never"
model87 default
rc=0
XDG_CONFIG_HOME="$X87" "$AIF" work AIF-870 --profile haiku87 --no-worktree >"$OUT/run87b.out" 2>&1 || rc=$?
c87="$(col AIF-870)"
rc2=0
XDG_CONFIG_HOME="$X87" "$AIF" work AIF-870 --profile routed87 --no-worktree >"$OUT/run87c.out" 2>&1 || rc2=$?
eq "default — the CLI's own, which resolves to opus or sonnet: refused under a profile that maps neither, the card left in Ready; built under one that maps both, as a station that names no model is" \
  "$rc,$(grep -c 'aif-plan asks for default' "$OUT/run87b.out"),$(grep -c '(it maps haiku)' "$OUT/run87b.out"),$c87|$rc2,$(col AIF-870)" \
  "3,1,1,ready|0,review"
cd "$SANDBOX" || exit 1

# ----------------------------------------------------------------------------
printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'work: ok\n'
  cd / && rm -rf "$SANDBOX"
else
  printf 'work: %s failure(s) — sandbox kept at %s\n' "$fails" "$SANDBOX"
  exit 1
fi
