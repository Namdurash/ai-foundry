# Defects — 0.5.1, found driving one ticket end to end

Eight problems reported from three `aif work OPES-62` runs on a React
Native / TypeScript project (jest + jest-junit, `test.roots: ["test"]`). The
ticket was written with `/aif-ba`, passed `aif _ready` (7 criteria, 2 decided,
3 gaps), and the implementation the worker produced was correct every time.
All three runs still failed to deliver.

Worked against `63260ea` (0.5.1) on 2026-09-22, macOS, bash 3.2.57, jq 1.7.1.
Each entry says how it was established:

- **probed** — reproduced here, with the observation quoted;
- **read** — established from the code alone. Believable, not witnessed;
- **reported** — taken on the reporter's word; the mechanism is confirmed,
  the trigger is not.

Section C is later: one run of the same ticket on 0.5.3, which delivered, and
which found what #2 could not name.

Two defects that were not reported are in section B: both were found while
reading the same code, and both are in the same family — a gate reading a
report that describes some other run.

---

## A. What was reported

### 1. The gates cannot write a junit report in a fresh worktree — **the diagnosis is wrong; the symptom is #2** — probed

`verify-red` has created the report's parent directory since the gate was first
written:

```sh
report_path="$(jq -r '.test.report.path' "$project")"
mkdir -p "$root/$(dirname "$report_path")"      # verify-red.sh, in e1783fc
```

`green` does the same. `.aif/tmp/` being gitignored is therefore not what put
those runs into coarse mode; `git log -L 96,106:sets/claude/gates/verify-red.sh`
shows the `mkdir -p` in the commit that introduced the file.

The consequence described — a test file that fails to *compile* admitted as
"red" — is real, and it is what #2 causes. That half is fixed; see #2 and the
coarse-mode change below.

**What did change here.** Neither gate *deleted* the previous report before
running. A command that never reaches its reporter — an uninstalled reporter, a
runner that dies on startup — left the last run's file exactly where the gate
looks for it, and the verdict was then drawn about a suite that did not run.
`aif doctor` had cleared it before probing since the probe existed. Both gates
now do the same.

### 2. Coarse mode persists when the report exists and python3 resolves — **instrumented in 0.5.3; the root cause is #11, closed in 0.5.4** — reported

The reporter established, inside the worktree, that `.aif/tmp/report.xml` was
present at 64 561 bytes, that `python3 .aif/gates/junit.py` parsed it and
printed rows, and that `command -v python3` answered `/opt/homebrew/bin/python3`
— and the gate still printed
`verify-red: red (COARSE mode — no per-test detail; install python3)`.

Three distinct causes collapsed into one empty variable at that point, and
nothing anywhere recorded which had fired:

```sh
if aif_g_have python3 && [ -f "$root/$report_path" ]; then
  results="$(python3 "$here/junit.py" "$root/$report_path" 2>/dev/null || true)"
fi
[ -z "$results" ] && mode="coarse"
```

The root cause is **#11**, found on the next run — by this instrumentation and
nothing else. What is fixed here is that it can be read off the output. Each cause is named where it is found, and the name travels to the
closing line and into `tests.lock.json` as `mode_reason`:

- `python3 is not on PATH (PATH=…)` — PATH included, because the interesting
  case is exactly a python3 the developer's shell resolves and the gate's
  environment does not;
- `junit.py could not read <path> (exit N) — not the declared format, or it
  holds no test cases`.

The third — *the suite (exit N) wrote no report at <path>* — was a coarse
cause in 0.5.3, and it is the one #11 recorded. It is not a cause of coarse
mode any more: since 0.5.4 a suite that wrote no report is an ERROR in both
gates, because it did not run. Coarse mode describes a report that exists.

The closing line no longer says "install python3", which was the one place the
answer provably was not.

**And coarse mode is no longer blind to a broken suite.** The project already
names the strings that mean "this did not run" — `failure_classes.broken`,
which carries `Test suite failed to run` — and they were consulted in per-test
mode only. `verify-red` now matches them against the suite's own output before
accepting coarse red, and stops with an ERROR rather than freezing an oracle
that asserts nothing. That is what admitted run 1's uncompilable test file.

### 3. `green` trusts a junit report that omits failed-to-run suites — probed

A junit reporter emits one `<testcase>` per test, so a suite that fails to *run*
contributes none — and jest-junit emits no failing `<testsuite>` for it either.
The file is simply absent from the report, which then reads as "everything
passed" about a run that plainly did not.

Reported, on run 1: `npm test` said `Test Suites: 1 failed, 26 passed`, the
report held zero occurrences of `HomeScreen`, and `green` passed the ticket.
Seven acceptance criteria reached `review` verified by nothing.

Reproduced here as scenario 8 of `scripts/check-work.sh` — a stub suite that
keeps writing its all-pass report and starts exiting non-zero the moment the
implementation lands. Against 0.5.1 the run reports `built`.

**Fixed.** The report is cross-checked against the runner: a non-zero suite
whose own report names nothing failing is neither a pass nor a rejection but a
gate that cannot render a verdict, which is exit 3. The scenario asserts that
the run stops, that the ledger records `error`, and that `implement` is
dispatched once rather than `attempts_max` times.

### 4. `green` blames `implement` for defects in the frozen tests — probed by reading

Run 3's frozen test file misused RNTL's async `render()`. Seven TypeScript
errors, six failing tests, and `implement` — which may write only
`files.change`, while the test file is in `files.tests` and hash-locked by
`tests.lock.json` — was dispatched three times for it: 93 turns, 51 580 output
tokens, then `limits.attempts_max` and `needs_human`.

The rejection text made it worse:

```
- HomeScreen card reads on focus reads the cards again … (failure) — the pre-existing suite broke
```

Nothing pre-existing broke. That sentence was printed unconditionally for any
failing test not in `covering` + `green_at_freeze`, and it is a claim about
where a test came from that the gate was not checking.

**Fixed, in two parts.**

The freeze already knows. `verify-red` records the whole suite's status at
freeze time in `suite_at_freeze`, so an id absent from that record did not exist
when the tests were frozen and cannot be pre-existing. Failures are now labelled
three ways — this ticket's own frozen test, genuinely pre-existing, or arrived
after the freeze — and the third names the test file it came from rather than
accusing the repository.

And when *every* failure is of the third kind, with none in `covering` and none
pre-existing, the verdict is exit 3, not exit 1: the defect is in an artifact
this station may not touch, so retrying is not merely wasteful, it is
unsatisfiable. The loop stops on the first dispatch instead of the third.

### 5. `verify-red` cannot tell "red because the code is missing" from "red because the test is wrong" — open, by design — read

`failure_classes.legitimate` includes `TypeError` and `is not a function`, which
is exactly how a test that misuses an API fails. Run 3's broken test file would
have been admitted in per-test mode too.

No change. The reporter had no clean suggestion and neither does this; the two
candidates — requiring a covering test's failure message to mention the symbol
under test, or re-running against a trivially-stubbed implementation and
requiring the failure *mode* to change — are both large and both guess.

What is worth saying, because the gate's own header already says it and the
project that hit this had not acted on it: a check bound to phase `red` is the
place for a type-check of the test files alone. `verify-red` runs
`aif_g_checks_run … "red"`, and a project whose tests are TypeScript can put
`tsc --noEmit` on the test tree there. That would have caught run 3 at the
boundary instead of three dispatches later.

### 6. `aif board status` omits a card whose title is not `<ID> · slug` — **not reproduced** — probed

Could not be reproduced, and the code does not explain it. `aif board status`
applies no id filter at all: `_aif_trello_status_json` reads
`GET /boards/<id>/cards` — the same endpoint `_aif_trello_find_card` uses, so a
card `show` can display is a card `status` was handed — and maps every row
through

```jq
{ ticket: (.name | split(" ")[0]), title: (.name | sub("^[^ ]+ *[—:-]+ *"; "")), … }
```

Driving the exact reported name, `OPES-62 — картка не зʼявляється на Home`,
through `_aif_board_title`, then `_aif_trello_status_json`'s jq, then
`_aif_board_render_status`, yields the card with `ticket` `OPES-62` and the
Cyrillic title intact.

So the omission is upstream of the rendering: either the card is not in that
response (an archived list, a second board) or the two commands were run
against different configurations. `aif board status --json` beside
`aif board show <ID> --json` will say which; that is where to look next.

### 7. A station can error and still have its output admitted — **intended, now recorded** — read

```
station   tests ended with an error: no result field
gate      tests admitted — verify-red: red (COARSE mode …)
```

The behaviour is deliberate: a station that ended badly may still have left a
usable artifact, and the gate — not the runner's exit code — is what decides.
Two lines that read as a contradiction are the defect, plus the fact that
nothing outside the scrollback remembered it happened.

**Fixed.** The worker says which of the two is the verdict, and the error goes
into the run record as `station_errors`. The report grows a section for them:
the runner reported a failure for these dispatches, their artifacts were judged
by the gate anyway, and it is worth reading next to the diff.

### 8. Worktrees inside the repository collide with the project's test runner — reported

`.aif/worktrees/<ID>` is a complete checkout inside the repo root. A runner that
globs from the root collects every suite twice — once real, once from the
worker's copy — and reports failures that belong to no ticket. git hides those
trees; the runner does not care what git thinks. One `aif work` run was enough
to make the project's `npm test` meaningless, and the project's own
`jest.config.js` already carried the scar from the previous layout
(`.claude/worktrees/`), whose ignore pattern did not follow the move.

**Fixed, as detection rather than relocation.** Moving the checkouts out of the
repository is the other answer and a larger one. `aif doctor`'s probe now looks
for `.aif/worktrees/` in the suite's own output and in the report it just wrote,
and refuses — which means `aif work` refuses too, before spending anything,
since preflight runs the probe. It prints the runner-appropriate pattern
(`testPathIgnorePatterns: ["<rootDir>/.aif/worktrees/"]`,
`norecursedirs = .aif/worktrees`) and names the trap in the obvious fix: an
unanchored `.aif/` also matches when the suite runs *inside* a worktree, where
the gates run it, and a worktree that excludes its own tree collects nothing,
writes an empty report, and puts the gate into coarse mode on a project that is
fine. That is how run 2 died.

Detection is evidence-based, so it is silent until a worktree exists — which
means the first `aif work` on a project still sees it and the second one
refuses. Accepted: the alternative is warning every project about a directory
most of them will never notice.

---

## B. Found in the same code, not reported

### 9. `green`'s revert-recheck parses the report of the run before it — read

The recheck copies the tree into a scratch directory, reverts the
implementation, re-runs, and requires the covering tests to fail. The copy is
taken *after* the green run, so it carries that run's report. If the reverted
run fails to produce one, the stale file is what gets parsed — every covering
test reads as `pass` and the gate rejects a correct implementation for tests
that "do not depend on" it.

**Fixed.** The scratch report is deleted before the reverted run. Same family as
#1 and #3: a gate reading a report that describes some other run.

### 10. `green` claims the revert-recheck held when it examined nothing — probed

The recheck iterates `covering`. A lock frozen in coarse mode has an empty
`covering` **by construction**, so the loop ran zero times and the gate printed

```
green: suite passes, and the covering tests depend on the implementation
```

about a check that had looked at nothing at all — on exactly the runs where the
oracle is weakest.

**Fixed.** An empty `covering` sets the recheck to not-done and says why,
naming the coarse freeze and its recorded reason. The full tree copy is skipped
in that case too, since there was nothing to learn from it. Scenario 9 of
`check-work.sh` asserts all three.

---

## C. Found driving the same ticket on 0.5.3

One `aif work OPES-62` run against 0.5.3 (`be8e138`) on 2026-09-22, same machine
and same project. It is the first run of this ticket that delivered: one attempt
per station, 3 dispatches, 10 minutes, `stage: done`, card moved to Review. The
implementation was again correct. The **evidence** behind it was again empty,
for the reason #2 left open.

### 11. The root cause of #2: a fresh worktree has no `node_modules` — probed — **fixed in 0.5.4**

`tests.lock.json` from that run:

```json
"mode": "coarse",
"mode_reason": "the suite (exit 1) wrote no report at .aif/tmp/report.xml",
"at": "2026-09-22T16:55:50Z",
"covering": []
```

**The instrumentation added for #2 is what found this.** The old line said
"install python3", which sent the last three runs looking at a python that was
never the problem. The new reason names the suite, and the suite is where it is.

`git worktree add` checks out tracked files. `node_modules` is gitignored, so
`.aif/worktrees/<ID>` does not have one, and nothing in `aif work` installs
dependencies before the first gate runs its test command. Parking the directory
and running the project's own command reproduces the recorded reason exactly:

```
$ mv node_modules ../nm-parked
$ JEST_JUNIT_OUTPUT_FILE=.aif/tmp/report.xml npx --no-install jest --ci \
    --reporters=default --reporters=jest-junit
● Validation Error:

  Module <rootDir>/node_modules/react-native-worklets/jest/resolver.js in the
  resolver option was not found.
         <rootDir> is: /Users/…/opes/.aif/worktrees/OPES-62

EXIT=1
$ ls .aif/tmp/
(empty)
```

Restore the directory and the same command gives 27 suites, 179 tests, and a
58 KB report. jest dies in config validation — **before it runs a single
test** — so it never reaches its reporter, and the gate's `mkdir -p` (#1) has
nothing to do with it: the directory is there and empty.

Note the second-order trap: the resolver path is `<rootDir>`-anchored, which is
what #8 tells projects to do. Anchoring is right and it is also what makes the
worktree's missing `node_modules` fatal instead of silently resolving upward to
the parent checkout's copy.

**Why the 0.5.3 hardening did not catch it.** #2 now matches
`failure_classes.broken` against the suite's output before accepting coarse red.
That list is project-authored, and this project's carries `SyntaxError`,
`Unexpected token`, `Cannot use import statement`, `Test suite failed to run`,
`must contain at least one test`. A jest **config** failure prints none of them.
The check assumes the runner started; the failure is that it did not. No regex
list a project writes in advance can be relied on to cover the ways a runner
refuses to boot.

**What it cost, exactly.** Coarse red was admitted, so `covering` is empty by
construction, so #10's fix correctly reported the revert-recheck as not-done —
and `green` passed anyway:

```
green: suite passes (revert-recheck NOT done — the lock names no covering test,
so there was nothing to revert-recheck (the lock is COARSE: the suite (exit 1)
wrote no report at .aif/tmp/report.xml)), 1 check(s) green
```

By the time `green` ran, `node_modules` was present in the worktree (mtime
16:56Z, one minute after the 16:55:50Z freeze; the run ended 16:56:55Z), so that
suite genuinely ran and genuinely passed. The gap is not the code. It is that
**nothing in the run established that the frozen tests fail without the
implementation** — which is the one thing the freeze exists to establish.

Done by hand afterwards, it takes about thirty seconds: reverting the single
implementation file against the frozen tests puts AC-002 and AC-003 red
(177/179), and restoring it gives 179/179. The tests are a real oracle. The run
is simply not what showed that.

**Two fixes, in order of how much they buy.**

1. **Probe the worktree, not the repository.** `aif doctor --probe` runs in the
   main checkout, where `node_modules` exists — it passed, minutes before this
   run, and could not have seen the problem. The probe's value is entirely in
   running where the stations will run. Doing one report-producing suite run
   inside the freshly created worktree, before dispatching `plan`, converts this
   from a silent downgrade in rigour into a refusal that costs nothing. It also
   catches every sibling of it: a missing `bundle install`, a `.env` the runner
   needs, a native module built out of tree.

2. **Treat "no report at all" as broken, not as red.** A suite that never reached
   its reporter did not run, and that is structural — it needs no regex and no
   project cooperation. `mode_reason` already distinguishes the three causes;
   only one of them is compatible with coarse red. Keep coarse for *junit.py
   could not read it*, refuse for *the suite wrote no report*. On this run that
   alone would have stopped the freeze at 16:55:50Z with an accurate message.

A third, smaller: a project-level `prepare` command in `.aif/project.json`
(`npm ci`, `bundle install`) run once after the worktree is cut. Worth having,
but 1 and 2 are what make the failure loud, and loud is the part that was
missing.

**Fixed** (0.5.4), all three, in the order given.

1. The worker cuts the worktree *before* the card moves and probes the suite
   in it — `_aif_work_ready_worktree` ([lib/cmd_work.sh:223]), the same probe
   `aif doctor --probe` runs, but where the stations run. A checkout that
   cannot run the suite is refused with exit 3, nothing spent and no card to
   put back ([lib/cmd_work.sh:697], ahead of the move at [lib/cmd_work.sh:711]).
   The preflight probe in the developer's checkout stays, for the one thing
   only it can see: the `.aif/worktrees/` collision (#8).
2. No report is no run. `verify-red` answers 3 instead of coarse red
   ([verify-red.sh:147]); `green` does the same for its own run
   ([green.sh:171]) and for the reverted one ([green.sh:421]) — a
   revert-recheck that did not run is not a pass with a caveat. Coarse mode is
   left with the two causes that describe a report that exists.
3. `"prepare"` in `.aif/project.json` ([lib/project.sh:141]): a shell command
   the worker runs once per worktree it cuts, with a marker under `.aif/tmp/`
   so a resume does not repeat it and a prepare that died halfway is tried
   again ([lib/cmd_work.sh:232]). Read from the developer's config rather than
   the branch's, on purpose: the run that gets refused is the one after which
   the field gets added, to a file the branch does not have yet. The jest
   template ships `"prepare": "npm ci"` ([jest.json:13]); a project set up
   before the field existed adds it by hand, and the refusal says so.

Scenarios 14 and 15 of `check-work.sh`: a suite that needs a gitignored
directory is refused in a fresh worktree — the message, the card unmoved, no
run started — and with `prepare` set the same ticket is built with a per-test
freeze. Driven straight at the gate, a runner that does not boot after the
tests station leaves `verify-red` at `error`, nothing frozen, `implement`
never dispatched.

What this run's `tests.lock.json` would say under 0.5.4 is nothing: the run
stops at the worktree probe, ten minutes and three dispatches earlier, with
`wrote no report` and the name of the field to set.

---

## Also closed here

`docs/DEFECTS-3.md` #14 — `.suite.out` surviving the reject paths and being
committed under `tasks/<ID>/`. Both gates now arm an `EXIT` trap the moment the
file is written; a gate is its own process, so that is the whole fix, and it
covers every early exit rather than the pass paths the removals were written
for.
