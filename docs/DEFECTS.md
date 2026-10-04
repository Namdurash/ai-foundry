# Defects — the one log

Every defect found in aif, from the review of 0.5.0 to the first `aif work
--loop` after 0.11.0. One file, two halves: an **open** defect is written in
full — how it was established (probed, read, observed or reported), the
observation quoted, what a fix has to decide — because an open entry is a
work order; a **closed** one is a line — what went wrong, how it was
established, what closed it and where — because its detail lives in the fix,
the scenario that holds it, and the commit.

Ids are `log.entry`: `6.3` is the third entry of the sixth log. The logs were
once files of their own (`DEFECTS-3.md` … `DEFECTS-10.md`), each written
against one release and one batch of tickets; they are folded here and the
numbers never move, because `lib/`, the gates, the hooks and the scripts cite
them from code comments. A reference `docs/DEFECTS.md 6.3` means this file,
entry 6.3. The folded files are in the history before this one.

How an entry is established, in every log:

- **probed** — reproduced offline, with the observation quoted;
- **read** — established from the code alone;
- **observed** — seen on a project's own runs and board, and quoted;
- **reported** — taken on the reporter's word; the mechanism confirmed, the
  trigger not.

---

## Open

An open entry is written in full, under `### N.M <title> — how established`,
with the observation, the code it names, what a fix has to decide, and a
`#### Directions` list; it moves to Closed, as one line, when the fix is on
`main` with the scenario that holds it. A tag the tap does not serve is a fix
nobody has, so a closed line names the release once there is one.

### 11.1 The loop's shell can lose a Ctrl-C that lands as a tick ends — probed

Found 2026-10-03 on `main` after `807215b` (0.12.0), running
`scripts/check-work.sh` whole: scenarios 39 and 40 send a loop two interrupts a
second apart — the first takes no new card, the second is to stop the runs in
flight — and twice in two full runs the second one did nothing. The loop's
output had the first ("Ctrl-C — no new card; the runs in flight finish on their
own. Ctrl-C again stops them.") and never the second ("stopping every run in
flight (INT)"); the worker ran its station to the end and built, 35–39 seconds
later, and the card went to Review. The same scenarios pass on the untouched
`807215b` checkout, pass in isolation on the same tree (scenario 39 alone,
eight trials of the exact timing, zero lost), and fail at a different
alignment of the harness's clock against the loop's. Reproduced with the
loop's handler and tick traced (bash 3.2.57, macOS 26.6.2), two of six trials:

```
TRACE 21:04:45.228959 signal INT running=[71696:AIF-44:…]      ← the first, handled
loop      Ctrl-C — no new card; the runs in flight finish on their own. Ctrl-C again stops them.
TRACE 21:04:45.234448 tick woke
TRACE 21:04:45.236994 tick sleep                                ← sleep 1 begins
TRACE  tick woke                                                ← the second, 1.0046 s later: the `date` in the trace line died of it, the handler never ran
TRACE 21:04:46.249309 tick sleep
```

The empty timestamp is the tell: the interrupt reached the process group as
the tick's `sleep 1` ended and the shell was between commands — reaping the
child, or already forking the next — and bash 3.2 ran no trap for it. In
isolation no construct loses a trapped SIGINT on this bash — plain children,
command substitutions, `set -e`, `set -m` toggled around a background job, two
interrupts a second apart over a 1-second `sleep || true` tick: 60 of 60 every
time. The loss needs the signal inside the few microseconds between `waitpid`
returning and the shell's wait-time SIGINT handler being taken down, where the
received signal is noted in a flag nobody reads again. That is where a second
Ctrl-C sent exactly one tick after the first lands, because handling the first
realigned the tick to the first.

Two things made the harness hit it where a person rarely will: the second
interrupt sent a measured second after the first, on the boundary; and a
loop whose tick is one second. A person's second Ctrl-C is not on the tick,
and a lost one is pressed again. The run in flight is never harmed; it builds.

The same race, measured on its own: a bash 3.2 script holding in a loop of
`sleep 0.1` survived a SIGINT to its process group **10 times in 200** — the
signal landing as a sleep ends, noted by the shell's wait-time handler and
never acted on. The harness's stub station held that way, so a forwarded stop
that should have ended it at once sometimes waited out the hold (33 s for one
of two workers, scenario 40). With `trap 'exit 130' INT TERM` in the script,
0 of 200; `read -t` on a pipe and `sleep … & wait $!` also 0 of 200. A real
station is `claude -p`, not a bash loop, and dies of the signal; the stub now
traps.

What was tried and does not fix it: replacing the tick's `sleep 1` with a
wait the shell does itself — `read -t 1` on a pipe nobody writes — which on
bash 3.2 behaved worse (the loop's own interrupt went unhandled every time,
and the stop reached the worker by a route not understood). Left as it was.

#### Directions

- `scripts/check-work.sh` now sends the second Ctrl-C only after the loop has
  said what the first meant, and 0.4 s after that, off the tick; the loop's
  code is unchanged, so what the harness holds is the loop as a person uses
  it, not the race.
- A fix in the loop has to take the shell out of `wait_for` at the moment a
  signal may arrive: a tick that is a builtin wait and behaves on bash 3.2
  (`read -t` did not — why is worth a probe of its own), or a loop whose
  reaction to a second Ctrl-C does not depend on catching it (the first one
  starting a watcher that stops the runs on a file the second one cannot
  write — which the terminal cannot do either; no good shape found yet).
- Whatever is chosen is measured the way this was: the handler and the tick
  traced, the two interrupts sent at the harness's old alignment, many trials.

### 12.3 A ticket that changes another's rule: the older tests left in a declared file read as green at freeze — read; the worker's path not yet observed

Found 2026-10-04 closing 12.2, reading verify-red. A rule with `changes`
makes the plan declare the older ticket's test file in `files.tests`, so the
tests station can remove or rewrite the tests of the rule it replaces
(`aif-plan.md`, `aif-tests.md`). verify-red counts every test in a declared
file as new: the ones this ticket rewrote are red, as they should be — and
every other test in that file, untouched and green, is recorded green at
freeze, kept out of covering, and re-emitted on the closing checklist as a
criterion this run never proved red. A reviewer would read the older ticket's
settled tests as this run's doubts.

And nothing has run the path yet. The harness's stub stations do not read
`changes`; no live ticket has carried it. OPES-75 (Ready in `opes`) does the
same thing through prose — `decided` says OPES-52's English-text tests are
updated in it — and its run is the first observation of a ticket moving
another ticket's tests.

What a fix has to decide: whether verify-red tells a test that sat in the
declared file at the dispatch base, unchanged and green, from one this ticket
wrote — it already runs a baseline copy for failures outside the declared
files (6.1), and the same copy answers this — and keeps such a test off the
checklist; and whether the stub stations learn `changes`, so the harness holds
the path offline instead of a live run.

#### Directions

- Watch OPES-75's run: what its plan declares, what the tests station does to
  OPES-52's tests, and what verify-red and the report say about the ones it
  left alone.
- Then the baseline in verify-red for declared files, and a scenario: a ticket
  whose rule changes an older one's, built through the stubs with the older
  test removed, the older ticket's other tests off the checklist.

---

## Closed

### Log 3 — rebuild-3, 0.5.0 read end to end (2026-09-22)

Fourteen problems in the machine half, found by reading what 0.5.0 shipped and
running what could run offline. Closed in 0.5.1 (3.1, 3.2, 3.3, 3.6), 0.5.2
(3.14) and 0.5.3 (the rest).

- **3.1** `aif_ledger_append` silently removed the worker's interrupt trap — probed. A bare `trap -` in a library took the caller's handler; `aif_trap_arm` / `aif_trap_restore` in `lib/common.sh`, and no library clears a trap since.
- **3.2** The trap did not stop the run when it fired — probed. The handler is `_aif_work_abandon`, and it exits.
- **3.3** Nothing put the card back on any other exit — read. The handler covers `EXIT` as well as `INT`/`TERM`.
- **3.4** The budget cap read the number that is structurally zero under subscription auth — read. The cap takes the larger of the runner's figure and the token-priced one.
- **3.5** Coarse mode read the suite's output for "passed", not its exit code — read. The exit code, and nothing else.
- **3.6** `grep -qF "$expect"` without `--`, so an expect of `-1` was an option — probed. `--` on both greps.
- **3.7** `_record` and `_commit` failed silently, and everything downstream leaned on them — read. The worker stops and says whose fault it was.
- **3.8** `implement` has Bash, and one `git commit` from the station emptied scope's diff — read. The worker records `dispatch_base` before every dispatch and the gates judge against it; the guard refuses the obvious commit spellings.
- **3.9** `aif_sha256` failed open where its gate twin failed loudly — read. `aif_require_sha256` runs before any command that touches a project.
- **3.10** Trello, CRLF, and `^<!-- aif:meta$` — read. CR is stripped at the pull and in both meta readers.
- **3.11** `--no-worktree` put `bypassPermissions` in the developer's checkout — read. Refused unless `CI` or `AIF_DISPOSABLE=1` says the checkout is disposable.
- **3.12** The local board ordered by `date +%s`, so two cards in one second tied — read. A position field.
- **3.13** A resumed run reported "no code changed" — read. The base is kept across a resume.
- **3.14** `.suite.out` survived the reject paths and was committed under `tasks/` — read. The gates arm an `EXIT` trap the moment the file is written.

### Log 4 — 0.5.1, three runs of OPES-62 (2026-09-22)

Eight problems reported from three `aif work` runs on a React Native project
that produced a correct implementation every time and delivered none; three
more found in the same code. Closed in 0.5.3 and 0.5.4.

- **4.1** The gates cannot write a junit report in a fresh worktree — probed; the diagnosis was wrong, the symptom is 4.2.
- **4.2** Coarse mode persisted when the report existed and python3 resolved — reported. Instrumented in 0.5.3 (the degradation is named on the closing line and in the lock); the root cause is 4.11.
- **4.3** `green` trusted a junit report that omits failed-to-run suites — probed. The report is cross-checked against the runner; when the two disagree the gate answers 3, not pass.
- **4.4** `green` blamed `implement` for defects in the frozen tests — probed by reading. The failure is measured in a copy with the implementation reverted and attributed; since 0.11.0 an attributed failure is a repair by the tests station (REBUILD-4 §2.3), not a stop.
- **4.5** `verify-red` could not tell "red because the code is missing" from "red because the test is wrong" — read; open by design then. Closed by the contract in 0.11.0: with the plan's skeleton on disk a new test is red for an assertion or the not-implemented marker, and anything else is the test's own defect, rejected before the freeze.
- **4.6** `aif board status` omits a card whose title is not `<ID> · slug` — probed; not reproduced.
- **4.7** A station can error and still have its output admitted — read; intended. The run record and the report now carry the runner's error beside the gate's verdict.
- **4.8** Worktrees inside the repository collide with the project's test runner — reported. Detected from the suite's own output by `aif doctor --probe` and the worker's preflight, with the ignore pattern to add.
- **4.9** `green`'s revert-recheck parsed the report of the run before it — read. The scratch report is deleted before the reverted run.
- **4.10** `green` claimed the revert-recheck held when it examined nothing — probed. An empty `covering` sets the recheck to not-done and says why.
- **4.11** A fresh worktree has no `node_modules`, the root cause of 4.2 — probed. `prepare` in `project.json`, run once per worktree, and the probe run there before anything is spent (0.5.4).

### Log 5 — 0.5.4, writing OPES-68 (2026-09-23)

Two problems of one shape, found putting a ticket through the analyst and the
worker on a Trello project; the sweep found the shape everywhere. Closed in
0.5.5; FINDINGS #19 records the law.

- **5.1** A Trello card whose description is long enough became invisible to the worker — probed. `cmd | grep -q` under `pipefail`: grep left at the first match, jq took SIGPIPE, the card read as absent. Captured once and tested as a variable.
- **5.2** Project detection missed a Python project with many test files — probed. The same shape in `_aif_detect_runner`; the find moved inside a substitution.
- **5.3** The same shape, everywhere else — the sweep — probed. Every `… | grep -q` under `pipefail` replaced.

### Log 6 — 0.9.0, the first `aif work --loop` on four tickets (2026-09-29)

Three problems from one loop that parked two healthy cards in Needs Human;
six more found fixing and releasing them. Closed in 0.10.0; `check-work.sh`
scenarios 20–25 and `check-release.sh` hold them.

- **6.1** `verify-red` blamed the repository for a red its own tests caused — probed. A failure outside the declared files is measured against a baseline copy from the tests station's dispatch: red before is the repository's (a stop), green before is the tests' interaction (admitted, recorded as `red_with_tests`).
- **6.2** A test that did not type-check was frozen, and `green` spent every attempt on it — probed. A check may bind to `red`, with `legitimate_at_red` for what the missing implementation causes; the complaint carries the check's first lines. Since 0.11.0 the contract makes a type-check clean at red.
- **6.3** A dependency installed inside a station bypassed the lockfile — reported; the hole read, the consequence probed. A manifest and its lockfile are planned together, scope lets only a planned lockfile move, `aif _amend-plan` refuses lockfiles, and the worker reinstalls from the lock after any station that touched either.
- **6.4** `green`'s revert-recheck wrote into the real worktree's index — probed. Git is never run inside the copy (FINDINGS #20).
- **6.5** The worktree probe refused a worktree for a collision that was not there — probed. The probed root's own path is taken out before the output is searched.
- **6.6** `scripts/demo.sh` did not parse — probed.
- **6.7** `make release` could not finish a release it had tagged — probed. The run names its version in `AIF_RELEASING`, and `--verify` lets that one tag stand ahead of the tap.
- **6.8** A re-run after a refused tap push said "released" and pushed nothing — probed. The tap is pushed on every run, whichever run made the commit.
- **6.9** A tarball cut short on every try was hashed into the formula — probed. Fetched is curl's word, not a file being there.

### Log 7 — 0.10.0, asking what the tests station can check (2026-09-29)

- **7.1** A declared test file the runner never collected counted toward coverage — probed. Coverage reads only the declared files the report collected, and names the ones it did not (0.10.1; scenario 26).

### Log 8 — 0.11.0, upgrading a project from 0.9.0 (2026-10-02)

Five problems taking a project from 0.9.0 to 0.11.0, none stopping a run,
each leaving an upgraded project working differently from what it was told.
Closed on `main` and released in 0.12.0; scenarios 37–38 and `check-set.sh`
hold them.

- **8.1** An upgraded project kept failure classes the gate no longer meant, and a type-check bound to green alone — read; the silence probed. The templates carry `failure_classes.retired`; `aif project check`, `aif doctor`, the worker's preflight and `aif init` say what moved; `aif project upgrade` brings forward what aif decided and leaves the project's own fields.
- **8.2** `aif init` never refreshed its own hook registration, so a guard matcher without `Bash` survived four upgrades — probed. Hooks are merged event by event, ours by command path, the user's kept; the edit is recorded on every init; doctor reads the matcher before any probe and shows `station-guard` in its text output.
- **8.3** The guard took any subagent for a station — probed. Only `aif-*` agent types are stations (FINDINGS #9, narrowed).
- **8.4** A `project.json` from before 0.11.0 ran the new stage on the old dispatch cap, and the design's fourth attempt for the tests station was nowhere — read. The fallback is 16; a station's attempts cap is `max_attempts` in its `aif:meta` over `limits.attempts_max`, and the tests station declares four.
- **8.5** `aif init --dry-run` reported every updated file as retired — probed. A created or updated file gets its manifest row in a dry run too.

### Log 9 — 0.11.0, moving stopped tickets back to Ready after the upgrade (2026-10-02)

- **9.1** An upgrade stranded every ticket already in flight — probed; the gates read. A worktree on an existing `aif/<ID>` branch ran the vendored set the branch was cut with — 0.9.0's stations, caps and gates under the 0.11.0 driver — and the guide check misread the branch's age as an uncommitted file. Now the worker brings the branch up to the checkout's set before anything reads it (the manifest's files copied, a retired file removed, project.json, the hooks' registration and the guide with them), commits it on the branch naming both versions, and a run that had stopped under an older set restarts rather than resuming the plan that set wrote — the run record names its set, the way it names its ticket. `aif doctor` lists worktrees still on an older set. On `main` after 0.12.0; scenario 42.

### Log 11 — 0.12.0, the harness run whole (2026-10-03)

- *(11.1 is open, above.)*

### Log 12 — 0.12.1, the analyst on `opes` (2026-10-04)

- **12.1** The analyst cut a feature into fragments: the size cap counted examples, not rules — observed. A ticket carries `rules` (`R-1`…, a sentence each) and every criterion names the rule it is an example of; the ready gate caps the rules (`ticket_rules_max`, 6), keeps a backstop on the examples (`ticket_examples_max`, 30) and a warning past five on one rule (`rule_examples_warn`), names the order over the cap — restate, an axis of variation, the user — instead of "split the ticket", and lets only a size decision by the human keep a ticket whole. A ticket without rules is held to `ticket_ac_max` as before — the backstop is a key of its own because `aif project upgrade` leaves a project's values alone, and `opes` holds 15. `/aif-ba` works rules first, then the key examples of each; that half is prose, measured first on a live cut. On `main` after 0.12.1; scenario 43.
- **12.2** The analyst saw `main` and nothing in flight, so a ticket could restate a rule another ticket owned — read; the case probed (OPES-69 in Review, its code only on `aif/OPES-69`, and the next request restating its days-left and allowance rules). `aif rules [<word>…]` is the map — every ticket's rules in force with its column on the board, computed from `tasks/` and the board, a rule a later ticket changed left out unless `--all`, a ticket from before rules showing its criteria. A rule names what it replaces in `changes` (`<ID> R-n`, or `<ID> AC-nnn`); the ready gate holds every name to a ticket and a rule under `tasks/` and prints them on the pass path; the plan station puts the older tests in `files.tests`, the tests station removes or rewrites the ones the rule ends. `/aif-ba` reads the map before the code, sorts each rule — its own, a change, another ticket's (not written again, `depends_on`), a conflict (asked) — and cuts a request by giving each rule to exactly one ticket. On `main` after 0.12.1; scenario 44. The worker's half is 12.3.
- *(12.3 is open, above.)*

### Log 10 — 0.11.0, the first `aif work --loop` after the upgrade (2026-10-02)

Four problems from a loop that built nothing: two tickets stopped at the plan
station on a criterion the tree already satisfied, and the two-runs rule
stopped the loop. None corrupts a build that reaches Review.

- **10.1** A long report was cut through a character, and the worker said it was posted — probed; the refusal observed. The cut counts UTF-16 units, as Trello does, and cuts on a character; "report posted" is said only when it was, with a command that can succeed otherwise (0.12.0; `check-board.sh`).
- **10.2** A ticket over 16 384 characters could not reach its Trello card, and the refusal gave no reason — observed; the checks read. The ready gate counts the ticket as Trello counts it on a Trello project and names how much to cut; `aif board create` refuses before sending, with the count and the limit; the analyst skill names the cap. On `main` after 0.12.0; `check-board.sh`.
- **10.3** A restarted run inherited the stopped plan's files — read; the leftover state observed. A run that did not build restarts on the tree it started from: the stopped plan's skeleton, its edits, its committed plan and tests are put back in a commit that says so, the ticket's record kept; a resumed plan station finds the branch as it is. A run that built is a rework and keeps its code. On `main` after 0.12.0; scenario 42.
- **10.4** The analyst was never told about the check that stopped both runs — observed; the skill read. `/aif-ba` asks of every criterion whether today's tree already passes it, names the shapes that slip through (a guard written as its own criterion: "still", "only", "absent", a count of 0 or 1, a value the code already returns) and the fold — one literal carrying both the guard and the change. On `main` after 0.12.0.
