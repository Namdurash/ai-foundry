# Defects — the one log

Every defect found in aif, from the review of 0.5.0 to building the autopilot
mode's shift after 0.16.0. One file, two halves: an **open** defect is written in
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
`main` with the scenario that holds it. A fix on `main` in part is a
`#### Progress` paragraph before the directions that remain, so the entry
still reads as the work order it is. A tag the tap does not serve is a fix
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

#### Progress

On `main` after 0.16.0, the half of the second direction that needs no
signal: a loop can be stopped without catching anything. `aif work --loop
--drain` (no new card; the runs in flight finish) and `aif work --loop
--stop` (the runs in flight stopped too, as a second Ctrl-C would) leave a
file in the loop's lock, `drain` or `stop`, naming who asked — and the loop
reads it at the top of every iteration with builtins only (`[ -f … ]`,
`read <file`), so there is no fork and no new window for the race. `--stop`
writes the same name into each running ticket's run lock before it forwards
the TERM, so every card says who stopped it — a person's stop, which `aif
start` never retries — then waits up to 90 s for the loop to end and prints
its summary's why (`_aif_work_loop_tell`, lib/cmd_work.sh; scenario 50).
That is how a person in another terminal ends a loop; ending `aif start`
does not — a loop in another terminal runs on, and the shift's summary says
so with `aif work --loop --drain`. The race itself is unchanged: a second
Ctrl-C typed on the tick can still be lost, and the harness's workaround
below stays.

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

### 13.5 The land judges the merge in the developer's checkout, on the suite alone — read

`aif land` merges into the developer's own checkout and runs `.test.command`
there (lib/cmd_land.sh). So:

- it refuses while anything tracked is uncommitted — in the checkout where the
  human talks to the analyst and the product partner;
- without `--prepare` the suite runs against the dependencies installed before
  the merge, and a merge that moved a manifest or a lockfile goes red over a
  package it lacks (6.3; scenario 25 holds the message) — undone, Needs Human;
- a flaky test undoes a land — and since 13.4 sends the card back to the
  worker, which finds nothing to fix on a tree that is green;
- it runs no `checks`: two tickets that merged clean and type-check apart can
  leave `tsc` red on the target, and from then on every ticket stops at the
  plan's contract check or at verify-red (13.9).

What a fix has to decide: whether the merge and its verdict move to a
worktree of their own — cut at the target's tip, `prepare` run there, where
it is not invasive, the suite and the green-phase checks run there — with the
developer's branch then only fast-forwarded to the result. The worker's sync
(13.4) already judges that tree in the ticket's worktree; the land could take
its verdict instead of running the suite again here.

#### Directions

- Land through an integration worktree; the checkout moves only by a
  fast-forward, which needs no clean tree for files the merge does not touch.
- The green-phase checks run beside the suite.

### 13.7 A usage limit, or a runner that did not answer, is billed to the station — read

Nothing in `lib/` classifies a runner's error: no line mentions a usage limit,
an overloaded API or a rate limit. A station that hits the subscription's
limit returns an envelope with `is_error`; the worker records the error and
lets the gate judge what the station left (lib/cmd_work.sh, after the
dispatch), the gate rejects it, the retry fails the same way at once, and the
second identical complaint stops the run — Needs Human, `blocked: run`. In
`aif work --loop` every worker in flight meets the same limit, and two in a
row stop the loop taking cards; a night's run on a subscription meets a
five-hour window. A runner that produced no envelope at all — the network —
stops the run as the environment, untried again. An envelope that is not JSON
ends the worker under `set -e`, at `jq -r '.num_turns // 0'`.

The user decided on 2026-10-02: a usage limit pauses, it does not stop, and
paused time is outside the wall clock.

What a fix has to decide: how a limit is recognised (the envelope's `result`,
its subtype, the reset time it names); what pauses — the worker, the loop —
and for how long; how the attempt is left uncounted; which runner errors are
transient and retried with a backoff, uncounted too.

#### Directions

- A classifier on the envelope in lib/runner_claude.sh; the worker waits for
  the reset outside the wall clock and dispatches the same attempt again; the
  loop's dashboard shows the pause.
- A scenario: a fake station that reports a limit once, then works.

### 13.8 One hiccup stops the loop, and the board is asked once — read

`_aif_work_loop` takes no new card after one worker exits 3 — the
environment: a Trello call that failed, an `npm ci` that met the network — or
after two that did not build in a row, whatever stopped them; one transient
failure in one worker parks the whole queue. Every Trello call is one `curl
-f`, never retried (`_aif_trello_call`, lib/board.sh), and every move or
comment first lists all the board's cards with their descriptions
(`_aif_trello_find_card`). With several workers and the dashboard polling, a
429 is likely: on the claim it is exit 3, on the final move it leaves the card
In Progress with no worker behind it.

What a fix has to decide: a retry with backoff for the install (the board's
is on `main` — Progress, below); which exits mean the machine cannot run
anything — and stop the loop — and which only end one card; whether two in a
row counts runs the environment stopped.

#### Progress

On `main` after 0.15.0, the board's half: every curl call carries
`--connect-timeout 10 --max-time 60`, so a connection that hangs costs a
minute, not the night; a GET or a PUT is tried up to `AIF_TRELLO_RETRIES`
(three) times on a 429, 500, 502, 503 or 504, or on curl's connect, timeout,
empty-reply and network exits, sleeping what `Retry-After` says when the
board says it (up to 60 s) and else the next of `AIF_TRELLO_RETRY_SLEEP`
(1, 3, 7) — a POST stays one attempt, because a comment posted twice is the
card's record twice; and `show` dies with the reason when the comments read
fails, where it answered `[]` (14.7). `scripts/check-board.sh` holds each
through the mock's fault file (`_aif_trello_call`, lib/board.sh).

On `main` after 0.16.0, the loop's half: a worker that could not start —
exit 3, or exit 1 in its claim, worktree or intake, which its handler labels
`blocked: environment` — has the machine asked again before it stops
anything. The loop runs its own preflight in a subshell, without the suite
probe (`AIF_WORK_LOOP=1`), under the profile it resolved to; it goes on
while that passes, and takes no new card when it fails, or at the third such
worker in a row. Those workers do not count toward two in a row, which reads
the cards. So a machine that cannot run anything costs at most three cards
in Needs Human, and only for trouble the preflight cannot see; and a loop
whose every card met the environment, never three in a row, ends on an empty
Ready with rc 1, `env` 0 and `rechecks` in its summary (the reaper in
`_aif_work_loop`, lib/cmd_work.sh; scenarios 51 and 40d — the third in a
row, a re-check that fails, an exit-1 environment failure counted toward the
three, and under `--idle` the card taken again once the machine passes).

Still open: the lookup that asks for one card instead of listing the board
(every move and comment still lists it, and the claim of 14.4 is one more
round trip per take); and a runner that produced no envelope — the network,
a CLI that could not start — which 13.7 has as the environment and the
code settles as `blocked: run` with "the environment,
not the ticket" in its why (research §6.11, verification 6), so the loop
counts it toward two in a row and never asks the machine.

#### Directions

- The lookup asks for one card, not the board.
- A runner that produced no envelope settled as `blocked: environment`, so
  the loop asks the machine again instead of reading it as the card.

### 13.9 A red test or check on the base stops every ticket, and a flaky test is a verdict — read

One test red without the ticket's tests stops verify-red ("the pre-existing
suite is red without this ticket's test files too", exit 3). A required check
failing outside the ticket's files rejects the plan at `contract` — the plan
station cannot fix it — stops verify-red at `red` ("a check bound to red fails
somewhere other than this ticket's test files"), and rejects the implement
station at `green`, which scope forbids to touch that file. On `opes` the
type-check is bound to all three phases and lint to green, so one regression
on `main` — which a land can bring, 13.5 — stops every ticket after it. A
flaky test is never run again: failing with the implementation only, it is
"this change broke it" and the implement station is rejected; failing without
it too, it is "moved" and the run stops. Parallel runs make flakes likelier: N
suites at once, and the gates copy the whole tree, `node_modules` included,
with `cp -R … || true`, which hides a copy cut short.

What a fix has to decide: whether a failure present at the target's tip —
measured there, or recorded by the last land — is the repository's, and is
let through with a line on the report instead of stopping the ticket (which
stays answerable for not adding one); one re-run of a failing test before it
is attributed; how many copies the gates make, and whether `node_modules` is
linked rather than copied.

#### Directions

- A record of the target's failures and check output per commit, read by
  verify-red and green as what was there before.
- One re-run of each failing test before a verdict.

### 13.10 Rules that refuse correct work — read

- A deletion is always out of scope: the plan has no delete list, and scope
  rejects every deleted path (sets/claude/gates/scope.sh), so a ticket that
  must remove a file cannot pass.
- A file the plan did not foresee cannot be added: `aif _amend-plan` widens
  the manifest only to files that exist (lib/cmd_amend.sh); a new file is a
  replan, and there is one.
- The denylist (`AIF_G_DENYLIST`) holds `.gitignore`, `.github/`, `.claude/`
  and `.aif/` against any implementation: a ticket that needs one cannot be
  planned.
- The guard lets the tests station write only files named like tests
  (`is_test`, sets/claude/hooks/guard.sh): `__mocks__/`, `test-utils/`, a
  fixture outside `tests/` are refused, whatever `files.tests` declared.
- The caps that remain: three attempts (four for the tests station), the same
  complaint twice, 16 dispatches, 120 minutes — which parallel runs reach
  sooner — two repairs, one replan, three amendments. `opes` still runs its
  stations at `station_max_turns: 30` and carries the caps 0.13.0 retired,
  until `aif project upgrade` runs there.

What a fix has to decide: a `files.delete` in the plan, held by scope; an
amendment that may create a file beside the plan's; a guard that reads
`files.tests` instead of a name pattern; which caps a subscription still
needs.

#### Directions

- One at a time, each with its scenario; the caps last, measured on `opes`.

### 13.11 aif's commits run the project's git hooks — read; latent

Every commit aif makes — intake, each admitted station, a repair, the report,
the land's merge — runs the project's hooks: nothing passes `--no-verify` or
sets `core.hooksPath`. A `pre-commit` that fails (husky, lint-staged) stops a
run at `aif _commit` ("the tool, not the station") and silently skips the
commits made with `|| true`; one that rewrites the files it is given changes
frozen tests after their hashes were taken, and green then rejects the
implementation for a drift it did not make. `opes` has no hooks; the next
project may.

What a fix has to decide: whether the worker's commits on `aif/<ID>` skip the
hooks — bookkeeping on a disposable branch, where the land's merge is the
commit the project's hooks are for — or run them and read a refusal as the
environment.

#### Directions

- `--no-verify` on the worker's own commits; the land's merge keeps the hooks.

### 14.1 The run lock records the worker's pid, not the station's — read

Found 2026-10-05 reading what a supervisor could trust about a card In
Progress (docs/AUTOPILOT-RESEARCH.md §6.11, verification 5). `_aif_work_lock`
writes `{ ticket, pid, started_at }` with the worker's own pid, and
`_aif_work_lock_live` asks whether that pid is alive and runs something
named `aif` (lib/cmd_work.sh). The station — `claude -p`, a child of the
worker, in the worker's process group — is in no lock. So a worker killed
outright, `kill -9` (and, until 14.8, a closed terminal), leaves its station
writing in the worktree with nobody to judge what it writes: the lock's pid
is gone, the lock reads as dead, the next `aif work <ID>` takes it over
(14.5), resumes from the run record, and dispatches a station of its own
into the tree the orphan is still editing. `--stop` and Ctrl-C reach the
station because the worker is alive to forward them; a death the worker
never saw forwards nothing.

What a fix has to decide: what the lock records of the station — its
process group, taken as each dispatch starts — so a takeover can tell an
orphaned station from a free worktree; whether a takeover refuses while any
process has the worktree as its working directory; and whether a takeover
first does what `--stop` does, a TERM to the group and a wait for it, before
it builds.

#### Progress

On `main` after 0.16.0, the reader and the shift's half.
`aif work --status <ID> [--json]` (`_aif_work_status_json`, lib/cmd_work.sh)
lists what a dead worker left running, as `lock.orphans`: by process group
when the lock's pid is gone — the loop starts each worker as a group leader,
the station stays in that group, and a group's id is not handed out again
while it has a member — and in every case by the station prompt's opening,
`Ticket <ID>. `, in a command line; a pid alive under another command is
someone else's now, and its group is never listed. `aif start` reads it:
a card In Progress whose worker is gone mid-run is offered as a requeue
(R3b), which TERMs each process listed — the whole group when it is the dead
worker's, else the process alone — waits up to 30 s, and puts the card at
the top of Ready only once nothing is left; a station still running is
named, and the card stays. Scenario 52 and `check-start.sh` (layer C, a
worker killed outright) hold it.

Still open: the station's pgid in the lock; the takeover, which still looks
at nothing but the lock — the requeue leaves the dead lock for the next
worker to take over (14.5), and `aif work <ID>` run by hand on such a card
still dispatches into the tree an orphan may be editing; a leftover with no
prompt in its command line — `prepare`'s install, a gate's suite run — of a
worker a script started without job control, whose group is its parent's,
not its own: neither reading finds it (read); and no row tells the group
TERM from a TERM per listed pid — every orphan the harness makes is listed
by its own pid, so a requeue that signalled each pid alone passed
`check-start.sh` (probed, by a mutation). A station of another clone
building the same id is 15.4.

#### Directions

- The station's pgid in the lock beside the worker's pid, written as a
  dispatch starts and cleared as it ends.
- No takeover while a process has the worktree as cwd; name it instead.
- A `--stop`-style TERM to the recorded group first, then the takeover.
- A `check-start.sh` row whose station has a child the listing does not
  name, so the group TERM is held apart from a TERM per pid.

### 14.2 `_aif_work_block` moves the card to Needs Human even when its comment was not posted — read

`_aif_work_block` (lib/cmd_work.sh) posts the `blocked:` comment and, when
the board refuses it, keeps the text in `.aif/tmp/blocked-<ID>.md`, warns
with the command that posts it later — and moves the card anyway. The move
was deliberate: a card left in Ready is taken again by the next run, and a
card left In Progress claims work that is not happening. But the card is
then in Needs Human with no first line to route on — the project manager
reads whatever comment is newest, `aif board head` finds nothing, and the
reason sits on one machine's disk (docs/AUTOPILOT-RESEARCH.md §6.11,
verification 3). `scripts/check-board.sh` asserts exactly this state, since
10.1: under a board that refuses comments, AIF-7 ends in Needs Human with
"why NOT on the card" printed, and the kept file is posted later, by hand.

What a fix has to decide: whether the reason is re-posted from the kept file
by the next thing that touches the card — the worker's next run, a pass of
`aif board` — before anyone routes on it; or whether the move waits for the
comment, the card left In Progress under its run lock until the board
answers, which a card with a claim (14.4) and no verdict already means.

#### Directions

- Re-post from `.aif/tmp/blocked-<ID>.md` on the next run that touches the
  card, or by `aif board`; remove the file once the line is up.
- Or hold the move until the comment is posted.

### 14.3 The loop's exit code is not the board's state — probed; the summary is on `main`

The loop's exit ladder reads 0 for a Ready drained, 1 for a card not built,
3 for the environment (`_aif_work_loop`, lib/cmd_work.sh), and the research
probed each against the board (docs/AUTOPILOT-RESEARCH.md §6.11,
verification 1): rc 0 with a card still in Ready — a live run lock on it
("0 taken, 0 built — Ready is empty", the card left where it was), the
taken list, `--max-tickets`; rc 1 from a preflight `aif_die` with nothing
taken (probed without `aif-implement.md`); rc 3 from one Trello 429. A
parent that read the code alone would start a loop again over a Ready it had
just drained, hold one that had taken nothing, or treat one 429 as the
machine.

#### Progress

On `main` after 0.15.0 the loop writes `summary.json` beside its logs —
`taken`, `built`, `blocked`, `stopped`, `env`, `ctrl_c`, `killed`, `hup`,
`why`, and a `results` row per run with its ticket, how it ended and its
minutes — whole, to a temp name and then moved, so a parent polling for it
never reads half; and `AIF_WORK_LOOP_LOGDIR` names the directory, so a parent
knows where to look before the loop prints anything
(`_aif_work_loop_summary`). Scenario 48 holds both. Written on every path
once the directory exists: the loop's EXIT handler writes it when something
ends the loop before its end — an errexit in the body, a print that failed —
with the counts as they stood, so a parent polling for the file never waits
for nothing. The exit ladder is unchanged.

On `main` after 0.16.0 the file says more, and its first reader reads it.
`summary.json` gains `idle` (the loop waited for Ready to fill), `rechecks`
(how often a worker that could not start had the machine asked again —
13.8) and `held` (the cards an idle loop took and that still sit in Ready);
the loop lock's `owner.json` names the log directory as soon as there is
one, so `aif work --loop --stop` and a shift find the summary of a loop they
did not start. `aif start`, running the loop in its own terminal, decides
what came of it from that file and never from the rc alone
(`_aif_start_run_build`, lib/cmd_start.sh): no summary is a loop that never
started — another holds the checkout, and the shift waits for it, or it died
in its preflight, and the build is held; a why that opens `two runs in a
row`, `stopped by` or `drained by`, or rc 1 or 143, holds the build until
the person says `b`; rc 3 with a summary is the environment, which the
loop's own preflight has already looked at again, and ends the shift with
3; 130 pauses it.

What a fix has to decide: whether the codes are made distinct — Ready
drained, stopped with cards left, nothing taken — or every caller reads the
file and the rc is only how the process ended, which is what a supervisor
does with it; and whether an exit 3 is read as the machine only once `aif
board check` has failed too (13.8).

#### Directions

- Distinct exit codes, or callers read `summary.json`; never the rc alone.
- `aif board check` before a 3 is treated as the machine; one 429 is the
  board, not the environment.

### 14.4 Two machines on one Trello board cannot tell a live remote worker from a hand-drag — read; the claim is on `main`

A take is a GET then a PUT with no compare-and-set: the worker lists the
board's cards, reads the top of Ready, and moves it (`aif_board_next_ready`,
`aif_board_move`, lib/board.sh), and two loops on two machines can list the
same card and both move it, each then building it on a branch of its own.
And once a card is In Progress nothing on it says where: the run lock that
knows the pid is in one machine's `.aif/state`, which the other cannot read,
so a live worker elsewhere and a card somebody dragged there look the same
(docs/AUTOPILOT-RESEARCH.md §6.11, verification 5).

#### Progress

On `main` after 0.15.0 the worker posts `taken: <host> pid <pid> at <time>
— aif work` on the card the moment it has moved it to In Progress — the
host, the pid the lock records, the time — a claim, listed in
`AIF_BOARD_HEADS` and routed on by nobody; the report or the `blocked:` line
after it is the newer head (`_aif_work_claim`, lib/cmd_work.sh). A claim the
board refused is a warning, not a stop. Scenario 48 and `check-board.sh`
hold it. Nothing yet reads a claim before a take. On `main` after 0.16.0
`aif start` reads one before it acts on a card In Progress: on a Trello
board the card is this shift's to report, requeue or settle only when its
newest `taken:` names this host (`aif_host_short`, the claim's own name);
another host's claim is a line, "built there; nothing to do here", and a
card with no claim is a line too (lib/start.jq; the Trello row of
`check-start.sh`).

What a fix has to decide: whether a take reads the card's head first and
skips a card another host claimed within a run's wall clock; and whether a
board shared across machines carries an owner and a heartbeat, so a claim
whose worker died (14.1) ages out.

#### Directions

- A claim check before a take: the newest head a `taken:` by another host,
  younger than the wall clock — skipped, and said.
- An owner and a heartbeat on the card, for a board two machines share.

### 14.5 A dead lock is taken over by `rm -rf` then `mkdir`, and liveness matches `*aif*` on the pid's command line — read; the command match is on `main`

`_aif_work_lock` (lib/cmd_work.sh), finding the lock held, asks
`_aif_work_lock_live` — `kill -0` on the recorded pid, then `ps -o command=`
matched against `*aif*` — and when that says dead, removes the directory and
makes it again. Two runs that find the same dead lock in the same instant
both remove and both `mkdir`, and the second believes it holds a lock the
first is already working under; the function's own comment writes the window
down. A pid the system has since handed to any program with `aif` in its
command line reads as a live worker, so that lock is never taken over — a
reused pid satisfies the test. And a takeover starts the run record's
counters again: a resume gives the record a fresh attempt count and budget
by design, the caps being per invocation, so a ticket that stops the same
way under every worker that takes it is never seen to (research §4.5).

What a fix has to decide: an order of operations that makes the takeover
one step — the dead lock moved aside (`mv` is atomic), its pid compared with
the one that was read, then the `mkdir`, so a second taker finds the
directory gone and its own `mkdir` decides; a liveness test that matches the
command, `aif work`, not the word; and a takeover count in `run.json` that a
resume leaves alone, with a cap.

#### Progress

On `main` after 0.16.0, the second direction: liveness matches the command,
not the word. `_aif_work_lock_live_as <lock> <glob>` (lib/cmd_work.sh)
matches the pid's command line against a pattern for each lock — the run
lock `*aif work*`, the loop lock `*aif work*--loop*`, the shift lock `*aif
start*` — so a pid since reused by a `claude '/aif-review …'` session, or by
a shift, no longer reads as a live worker (an unquoted pattern in `case`
honours the escaped space on bash 3.2). Every lock fixture in the harness
uses a dead pid.

Still open: the takeover, now three times over — the loop lock
(`.aif/state/loop/`) and the shift lock (`.aif/state/shift/`) take a dead
lock over the run lock's way, `rm -rf` then `mkdir`, with the same window;
a reused pid that runs any `aif work`, a loop included, still reads as a
live worker of the run lock; and the takeover counter.

#### Directions

- Rename the dead lock aside, compare its pid, then `mkdir` — one helper for
  the three locks.
- A takeover counter in `run.json` that a resume does not reset, and a cap
  on it.

### 14.6 The `fable` alias is not routed by a profile — read

`AIF_ROUTING_VARS` (lib/profile.sh:140-147) carries
`ANTHROPIC_DEFAULT_OPUS_MODEL`, `_SONNET_` and `_HAIKU_` and no variable for
`fable`; the worker resolves the three aliases through those and nothing
else (`_aif_work_dispatch`, lib/cmd_work.sh); `profiles/glm.profile` maps
the three to its models. So `--model fable` under `anthropic` works — the
CLI knows the alias (docs/FINDINGS.md #27: `modelUsage` keyed
`claude-fable-5`) — and under `glm` is sent as it is to an endpoint that has
never heard of it: the one alias the profile leaves untranslated, failing on
the far side instead of here, where a wrong base URL is caught.

What a fix has to decide: whether a profile refuses an alias it does not map
before a station is dispatched, and names the ones it does; or whether the
routing list gains the variable for it — once the CLI's name for that slot
is known — and every profile that maps the other three maps this one.

#### Progress

On `main` after 0.16.0, the shift's half: `aif start` refuses, with exit 1
before anything is opened, a role's model the profile it loaded does not
map, and names where the model came from (the flag, `.aif/start.local`, the
default) and the aliases the profile does map (`aif_profile_maps_model`,
lib/profile.sh). Under a profile with a base URL, `opus`, `sonnet` and
`haiku` pass only when their `ANTHROPIC_DEFAULT_*_MODEL` is set, `opusplan`
when both of its are, `fable` never, `default` only when `ANTHROPIC_MODEL`
is set; a full model id and no model at all pass. `check-start.sh` holds it
under a profile that routes the three and not fable. Still open: the
worker, which still sends a station an alias its profile does not map; and
`default` under a routing profile, refused unless `ANTHROPIC_MODEL` is set,
though what the CLI's own default resolves to there was never probed —
while no model at all, which is the same default, passes (read).

#### Directions

- Refuse an alias the loaded profile does not map, with the ones it does —
  the worker as the shift does, before the first dispatch.
- Or the fable slot in `AIF_ROUTING_VARS` and in `glm.profile`, once the CLI
  names it.

### 15.1 One Ctrl-C in a review session while `aif land` runs sends the land TERM, then SIGKILL about 1.4 s later — probed; the undo under it read

Found 2026-10-06 probing what a shift's sessions do to what they start
(docs/FINDINGS.md #28). A command a session runs through its Bash tool runs
in a session of its own, with no terminal; one Ctrl-C typed in claude sends
TERM to that command's whole process group within about 20 ms, and SIGKILL
1.3–1.5 s later to whatever is still alive (a stand-in that trapped every
signal, and a grandchild "gate" under it, logged the TERM and were gone
before their next line). `/aif-review` runs `aif land <ID>` exactly that way
when the demo says *as expected*. The land's stop handler,
`_aif_land_stopped` (lib/cmd_land.sh), ignores INT, TERM and HUP and then
undoes — `git reset --hard` to the commit before the merge, then
`_aif_land_restore_aside`, which puts the ticket's own untracked files back
from `.aif/tmp/land-<ID>-<when>/` — and ignoring TERM does nothing against
the SIGKILL that follows. A reset over a merge that touched many files, an
install `--prepare` had started, a slow disk: the undo may be cut in half,
the checkout left between the merge and the commit before it, or the
analyst's untracked ticket left aside. What a SIGKILL there leaves was not
probed. A closed window, the other way out, does not reach the land at all:
it runs to its verdict unwatched, the shift ends with 129, and the next
shift reads the card as the land left it.

What a fix has to decide: whether the undo is kept small and fast enough to
finish inside the grace — measured on a real merge — or survives being cut:
a marker naming the commit before the merge, written before the merge and
removed after the verdict, that the next `aif land` (or `aif doctor`) finds
and finishes; or whether a land the review starts runs outside the tool's
process group, so a Ctrl-C in the session does not reach it — and then
cannot stop it either, which a person may mean.

#### Directions

- Measure the undo on `opes`: the reset and the restore after a merge of a
  built ticket, timed.
- A marker for a land in flight, found and finished by the next land.
- A scenario: a land TERMed and then killed 1.4 s later mid-undo.

### 15.2 `.aif/start.local` is not ignored in a project set up before the shift, until its next `aif init` — read

`aif init` writes one managed block in `.gitignore` (lib/cmd_init.sh), and
the line `.aif/start.local` — a developer's own shift defaults, models and
waits — joined it with the shift. Nothing else rewrites the block: not
`brew upgrade`, not `aif project upgrade`. So in a project initialised
before, the file is untracked and not ignored — `git status` shows it, and
a `git add -A` commits one developer's choices into the team's repository;
the land's clean-tree check reads tracked files only, so nothing stops it.
The shift says so once in its header, when the file exists and `git
check-ignore` does not ignore it, and names `aif init`.

What a fix has to decide: whether `aif project upgrade` or `aif doctor`
names a managed block that is missing lines, with the command that adds
them — writing the developer's `.gitignore` unasked is the invasive kind of
action, opt-in.

#### Directions

- `aif doctor` lists the managed block's missing lines and names `aif init`.

### 15.3 A card an idle loop holds stays in Ready, and a shift beside it waits for it for good — read

Under `--idle` the loop remembers what it took and forgets a card only once
it has left Ready, or after a passing re-check of the machine (13.8). A card
whose run ended with the card still in Ready — a worker that stopped
before its claim, with exit 1 and no `blocked:` line — is held: skipped,
and never taken again by that loop. The loop then says `Ready is empty — idle`,
with the held cards only in a `held:` suffix and on the dashboard's idle
line; and nothing outside the process can know, because the loop lock's
`owner.json` carries no held list and `summary.json`'s `held` is written
when the loop ends. A shift in the other terminal reads a live loop
elsewhere and Ready ≥ 1 as work in flight (lib/start.jq, the wait) and
waits — a new look every `POLL` — until the person presses `q`.

What a fix has to decide: whether the loop publishes what it holds, in
`owner.json`, rewritten as it changes, and the shift's wait leaves those
cards out and lists them with what would move them; or whether a card the
loop will not take again leaves Ready with a line that says why; and the
idle event's words while Ready holds only cards the loop will not take.

#### Directions

- `held` in `owner.json`, read by the shift's facts: the wait excludes the
  held cards, and each is a line.
- The idle line says "Ready holds only cards this loop will not take again".

### 15.4 A station of another clone building the same ticket reads as this clone's orphan — read

`aif work --status <ID>` lists, as a dead worker's leftovers, every process
whose command line holds `Ticket <ID>. ` — the station prompt's opening —
whatever its group (`_aif_work_status_orphans`, lib/cmd_work.sh); it looks
only when this clone's run lock for the ticket is held and dead. A second
clone of the same project on this machine — a developer's own two checkouts,
a CI job's — building the same id runs a station whose argv carries the same
text. That station is listed as this clone's orphan, and `aif start`'s
requeue (R3b) TERMs it by pid, stopping a live build in the other clone,
then sees it gone and puts this clone's card back in Ready.

What a fix has to decide: how a process is tied to this clone — its working
directory under this clone's `.aif/worktrees/<ID>` (`lsof -d cwd`, not
probed on macOS), or the station's group recorded in the lock as it starts
(14.1's first direction), which would leave the prompt match a fallback.

#### Directions

- The station's pgid in the run lock (14.1); the prompt match kept only for
  a process whose working directory is this clone's worktree — probed first.

### 15.5 A request's progress is read from the tickets that name it, and old tickets name none — probed on a copy of `opes`

`aif_requests_json` (lib/requests.sh) derives a request's state from the
tickets whose meta has a `request` naming it, and falls back to the first
line of its `## Status`, a cache, when none does — with `next_slice` 1
whatever that line says: the `- slice N → <ID>` list under it is not
parsed. Tickets cut before the shift carry no `request` in their meta. On a
copy of `opes` — four requests, 24 tickets, none naming a request — all four
requests came out `effective: not cut`, so under its threshold the shift
would offer each again — the two with `## Slices` to the analyst, the two
old-format ones to the owner (R20) — a request whose first slice landed
among them (research §2.3); and a request whose cache says `cut in part` is
offered from slice 1. And the scan knows indented fences only: a fence
at column 0 holding a `## ` line or a `1. ` line reads it as a heading or a
slice (read).

What a fix has to decide: where an old ticket's request comes from — the
status list parsed as a second source under the tickets, a one-time
backfill of `request` and `slice` into old tickets' meta (tracked files: the
analyst's, with a person's yes), or the analyst asked once by the shift; and
fences at column 0 in the scan.

#### Directions

- Parse `- slice N → <ID>` under `## Status`; the tickets still win.
- Column-0 fences toggled in the awk scan, with rows in `check-start.sh`.
- Try `aif start --dry-run` on `opes` before its first shift, and read the
  analyst's list.

### 15.6 On Trello the shift reads the newest 20 comments, on another clock, at six requests a session — read

- `show` on Trello asks for the newest 20 comments (lib/board.sh), so a
  card's head, its `after` count and its list of heads are read over those:
  a card with more than 20 comments after its last first line aif knows
  reads as a card with no head, and R17's count of bounces sees no further
  back than the window.
- R16 retries a `blocked: environment` posted during the shift: the head's
  time is Trello's clock, the shift's start this machine's. A skew of a few
  seconds misjudges a block posted in the shift's first seconds — retried as
  new, or listed as old.
- A session's two snapshots read the board's cards and the card's head:
  about six requests per session, beside the facts of every tick and the
  loop's workers, all on one token's rate limit (13.8).

What a fix has to decide: a head read that asks Trello for aif's own lines
rather than the newest 20; a margin on R16's comparison, or the shift's
start taken from the board's clock; and whether a session's snapshot reuses
the tick's facts.

#### Directions

- One at a time, measured on a Trello board with a long-commented card.

### 15.7 An idle loop that takes a card twice writes the second worker's log over the first — read

Each worker's output goes to `<logdir>/<ID>.log`, opened with `>`
(`_aif_work_loop`, lib/cmd_work.sh). Under `--idle` one loop can take the
same card twice — a land's `sync:`, a shift's retry, a person's move back
to Ready — and the second worker's log replaces the first's. The first
run's report stays on its branch; what its worker said — why it stopped,
the lines before a refusal — is gone, and `summary.json` has two results
rows for one file.

What a fix has to decide: a log per take (`<ID>.<n>.log`, the results row
naming it) or one file appended with a line between runs.

#### Directions

- A log per take, named in its results row.

### 15.8 In this terminal, a held build with nothing else left ends the shift, though its line says `b` — read

With the loop in the shift's own terminal (no `--no-build`), a loop that
ended on two runs in a row, a drain, a stop, or rc 1 or 143 holds the build
(R13): no new build until the person presses `b` at the control point. But
the oracle (lib/start.jq) offers that hold as a line only; with no unit, no
move and nothing in flight, it ends the shift — "nothing left for the
shift" — with Ready still holding cards, and the `b` the line names is
never offered.

What a fix has to decide: whether a held build with Ready ≥ 1 is a unit —
"build again", default skip, its key `b` — or a pause, instead of an end;
and what the summary names for it after the shift (`aif work --loop`).

#### Directions

- A unit for the held build in mode here; the end only with Ready empty.

### 15.9 Smaller seams found building the shift — read unless said

- The facts read a card's ready gate from `aif _ready <ID>`'s rc — 0 ready,
  1 not, 3 the environment — and a gate not installed dies with `aif_die`,
  1, read as "not ready": no pull is offered, and nothing says why.
- A card whose head cannot be read is `unread` on every tick, and an unread
  card is work in flight: the shift waits on it until `q`, with no cap, its
  line the only word of why.
- `ticket_re` is matched by jq's regex engine in the facts and by `grep -E`
  in `_aif_start_loose` (lib/cmd_start.sh), as the code before it splits
  them: a pattern the two read differently drops a card or a loose ticket.
- A session that changed only another card — a review that posted on a
  different card — reads as "changed nothing", and the shift pauses where it
  could go on: the snapshot is the unit's own, by design (probed).
- A move the shift never tried — the shift ended first — that carries a
  comment other than `rework:` or `cancelled:` (a report, a `blocked:`
  line, a release) is left in the summary with `aif start` as its command,
  not the comment and the move that would make it. A move it tried and the
  board refused is a line of its own (lib/start.jq `as_line`): its note
  carries the comment it kept and the two commands that finish it, and its
  command is never the bare move where that would lose what the shift held
  back — a refused requeue names `aif work --status`, a `rework:` or a
  `cancelled:` the project manager.
- On Trello a Ready card's `moved_at` is its last activity, which a comment
  moves too: the build in the shift's own terminal (R12, keyed on each
  card's entry into Ready) is offered again after a comment on a card the
  loop left in Ready — a loop started again, its preflight with it, that
  takes nothing new.
- `aif work --status` with no id lists run locks, worktrees and `aif/*`
  branches; a `--no-worktree` build, whose one trace is `tasks/<ID>/run.json`
  in the checkout, is not among them. A lock with no `phase` file is said to
  have died "during its claim".
- A Ctrl-C that lands while the loop reads Ready ends it with `env` 1 in its
  summary beside rc 130: the interrupted read is taken for the board's
  failure. The shift reads the 130 and pauses; another reader of `env` would
  be misled.
- `aif work --loop --stop` against a loop still in its preflight is read
  only once the preflight ends; a long suite probe makes it answer "still
  running after 90 s", rc 1, though the loop stops at its first iteration.
- The session opener with no terminal returns 1 and prints "Device not
  configured" (probed). The shift checks the terminal just before it opens a
  session, so only a terminal lost in between, with no hang-up, would read
  as claude failing — exit 1, not 129.
- The harness's key seam (`AIF_START_KEYS`) is taken one key per tick of a
  wait, so a row that waits sizes its run of `_` for a wait of unknown
  length — too short ends the shift at `q`, never hangs (read and run); and
  what is left of it is inherited by the land, the loop and the sessions the
  shift runs, where it means nothing.

What a fix has to decide: each its own; none of them stops a shift on a
local board.

#### Directions

- One at a time, each with its row in `check-start.sh` or `check-work.sh`,
  as a shift's use meets it.

### 15.12 On Trello the shift cannot tell a build of a card's earlier text from a build of its current one — read

`aif work --status` says whether the ticket changed since the build by
comparing the run record's `ticket_sha256` with the checkout's
`tasks/<ID>/ticket.md` (`_aif_work_status_json`, lib/cmd_work.sh) — the
ticket on the local board. On Trello the card's description is the ticket,
each run pulls it into its worktree and hashes that, and the checkout's file
is the analyst's older copy: a card a person fixed in the browser before
its build was read as built from "the ticket before its rework" — no review
offered, `aif work <ID>` resuming at done round after round, an In Progress
card moved to Needs Human with a false `blocked:` line (probed against the
stand-in Trello). The review's fix leaves the comparison out on Trello, so
the other half is open: a description changed AFTER the build reads as
built, the shift offers its review and its land, and nothing says the build
is of the earlier text until the next `aif work <ID>` pulls the card and
restarts the run. The reader is offline by design; the card's text is a
board read.

What a fix has to decide: whether the shift's one status read a tick asks
Trello for `desc` too (lib/board.sh asks for name, list, pos, activity and
labels — a board of long tickets makes it a large answer) and the facts hash
each Review and In Progress card's description as the pull writes it,
against its run's `ticket_sha256`, routing a mismatch to R8 ("the card
changed after this build — aif work <ID>"); or whether `aif land` refuses a
build whose ticket sha is not the card's — the land reads the board already.

#### Directions

- The card's description hashed in the facts on Trello, CR stripped as the
  pull strips it; R7 and R6 only for a build of the card as it is.
- A row in `check-board.sh`: the description edited after the build, and
  the shift offers no review.

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
- **12.4** Two caps from the first gates, 12 implementation files a plan and 400 lines a change, shaped tickets and never caught a run — measured on `opes`. In every run there neither fired: the widest plans were 12 files (OPES-59, OPES-66) and the largest change 371 lines (OPES-74), and the August refusals at scope were not the size (the first OPES-58 attempt changed 143 lines; OPES-61 and OPES-63 were the ledger on the denylist). Both acted before any run, through the analyst's estimate of them: the daily allowance was cut down to fit "about 420 lines", and the gate measured 186 when it was built; OPES-75/76 were split, by default, to fit 12 files. Retired: plan and scope say the size and refuse nothing for it — the paths the plan named and the whole suite stay the bounds. The templates list `plan_files_max`, `diff_lines_max` and `revisions_max` (read by nothing since 0.5) under `limits_retired`; `aif project check` names one a file still sets, `aif project upgrade` takes it out; `/aif-ba` never cuts by an estimate of lines or files. On `main` after 0.12.1; scenario 45.
- *(12.3 is open, above.)*

### Log 13 — 0.13.0, a branch that could not land (2026-10-05)

`aif land OPES-74` on `opes` stopped on a conflict, and the conflict was not
in the code: `aif/OPES-74` met `main` in `tasks/OPES-74/ledger.json` alone.
That started a read of every place a ticket stops for a reason other than its
implementation — twelve. 13.1–13.3 and 13.12 closed in 0.13.1 (scenario 46);
13.4 and 13.13, the user's calls on them, on `main` after 0.14.0 (scenario
47); 13.6 on `main` after 0.15.0 (scenario 48); the rest open above.

- **13.1** A ledger write that failed stopped the run — probed: a lock left in `tasks/<ID>/`, and the plan gate passed while `aif _gate` exited 1 on the append; the worker sent the plan back as rejected, then died writing its report — Needs Human, `blocked: run … ledger is locked`, no report; `|| true` around the fold caught nothing, since `aif_die` is an exit. Every ledger write is best-effort now, in a subshell of its own: a lock nobody holds is taken over (this process's, a gone one's, an unsigned one, one older than a minute), a live writer is waited for five seconds and the row then skipped with a warning, a ledger that is not JSON is set aside and a new one started; `aif _gate` records its verdicts in a block whose failure is a warning, so its exit is the gates' verdict alone. Released in 0.13.1; scenario 46.
- **13.2** aif's own files conflicted at land — observed on `opes`: `aif/OPES-74` (built 2026-10-02) conflicted with `main` in `tasks/OPES-74/ledger.json` alone, added on both sides — the analyst's empty one, committed with the reworked ticket after the branch was cut, and the branch's with fourteen rows; `ticket.md` was one blob on both sides and the code merged clean. Probed the same in scratch. `aif _ticket-init` and `aif board pull` write no ledger now; the worker makes it at intake. `aif land` settles a conflict in aif's own files by owner (lib/integrate.sh): the ticket's record under `tasks/<ID>/` is the branch's; another ticket's, and the set under `.aif/` and `.claude/`, the checkout's. The merge commit, the summary and the card say what was settled. Conflicts in code are 13.4. Released in 0.13.1; scenario 46.
- **13.3** The analyst's uncommitted ticket stopped the land's merge — probed: git refuses to write over an untracked file, byte-identical or not, and the land reported it as a conflict for a human. The land takes the ticket's own untracked files aside to `.aif/tmp/land-<ID>-<when>/` before merging, puts them back if the merge is undone, and says whether they differed from what landed; anyone else's untracked file in the merge's way refuses the land before anything is touched, the card left in Review. Released in 0.13.1; scenario 46.
- **13.4** A branch never took in the branch it lands on, and a conflict in code had no way through — read; observed on `opes` (`aif/OPES-74` 28 commits behind `main` when it came to land; `aif land` aborted, the card went to a human, and back in Ready the built run resumed at `done` and stopped on the same conflict). The worker brings the branch onto the checkout's branch before it says built (`_aif_work_sync`): the merge in the worktree, aif's own files by owner, a conflicted lockfile taken from the target for the package manager to write again, a conflict in code to the implement station with MERGE in its prompt (both sides' behaviour kept, no marker left — the worker checks), the test files the merge brought taken into the lock and the lock guarded from the station, then green and scope on the merged tree: scope passes over a path that is exactly the target's, and the ticket's own record; green reads a failing test from a file the merge brought as pre-existing. A test file in conflict, a replan in the station's note, or its attempts spent: the ticket is built again from the target, automatically — the first build kept under `refs/aif/archive/<ID>/<n>`, the plan station told and handed the old plan, once (`limits.rebuilds_max`). `aif land` sends a conflict in code, or a red on the result with the dependencies as the merge pins them, back to the top of Ready with a `sync:` comment, and the card returns to Review to be looked at again — the user's calls, 2026-10-05: back to Review after a settlement, a rebuild without asking. The report says what the sync took and where to look. On `main` after 0.14.0; scenario 47.
- **13.6** A rework on the local board never reached a branch that already existed — probed (scenario 6's shape through a worktree: round two said "resume done — the ticket has not changed since the last run", the branch had built AC-001 while the checkout's ticket asked for AC-001 and AC-002, and the card went to Review with the old build; a Trello card is pulled into the worktree on every run, so only the local board was affected). The worker carries the checkout's `ticket.md` into an existing worktree when it differs — the ticket alone, never the checkout's stale run record over the branch's — and the run restarts on the new bytes as it does on Trello (`_aif_work_intake`, lib/cmd_work.sh). On `main` after 0.15.0; scenario 48.
- **13.12** aif's temp files sat in `tasks/<ID>/`, where scope reads any file as an implementation editing the pipeline's record — read. The ledger's go with its subshell; `aif_run_update` and `aif_meta_replace` remove theirs when a write fails. A write killed between its `mktemp` and its `mv` still leaves one. Released in 0.13.1.
- **13.13** The ledger was committed with the ticket, so it rode every merge the ticket's branch made — decided (the user, 2026-10-05): out of git. It lives in the main checkout, `.aif/state/ledgers/<ID>.json`, gitignored, written by every worktree; a ticket's old committed ledger is read once as the start of the new one and never written again; `aif cost` reads both; scope keeps the old path exempt for branches from before. On `main` after 0.14.0; scenarios 46, 47.
- *(13.5 and 13.7–13.11 are open, above.)*

### Log 14 — 0.15.0, the autopilot research (2026-10-05/06)

The research for `aif start` — a mode that would open the human roles'
sessions one after another and run the loop between them — read and probed
every place such a supervisor would lean on, and the unhappy paths gave way
on each (docs/AUTOPILOT-RESEARCH.md §6.11; FINDINGS #27). Twelve entries:
14.7–14.12 on `main` after 0.15.0, held by scenarios 25, 48 and 49,
`check-board.sh` and `check-set.sh`; 14.1–14.6 open above, 14.1 and
14.3–14.6 in part — 14.3 and 14.4 since 0.15.0, all five moved on by the
shift's work (log 15).

- **14.7** Trello's `show` hid a failed comments read as `[]` with rc 0 — read (research §6.11, verification 3). A card whose comments the API would not give looked like a card with no comment, and every reading of a first line downstream — the project manager's, a sweep's — would have read "nothing here". The adapter dies with the reason (`Trello: could not read the comments of <ID> — …`); `aif board head` exits 2 for it, apart from the 1 of a card with no head; `check-board.sh` asserts it under three 500s on the actions call, through the mock's fault file. The two readers that only ever wanted a card's column — the land's "is it in Review" and `--stop`'s "is the gone worker's card still In Progress" — read it out of `show` under `2>/dev/null … || true`, so the loud failure reached them as an empty column: the land refused a landable card as "no card on the board", and the stop removed the lock under an In Progress card, left for the next `aif work` to take as fresh. Both read it through `aif_board_card_column` now — one listing of the cards, no comments asked — and a board that cannot say is the land's exit 3 and a stop that keeps the lock; `check-board.sh` holds each under a fault on the comments GET alone (`actions?`, the query string telling it from the comment's POST). On `main` after 0.15.0.
- **14.8** Nothing in aif handled HUP — read (research §6.11, verifications 2, 5 and 6). A closed window hung up on the worker's whole group: the station died of it and the card stayed In Progress; a land between its merge and its verdict died with the merge in place and nobody told. `aif_trap_arm` traps HUP beside EXIT, INT and TERM; the worker settles its card as `blocked: stopped — by a hang-up — the terminal closed — during <stage>` and exits 129, the loop stops its runs and exits 129 with `hup` in its summary — its own lines going to its loop.log from the hang-up on, because the terminal they went to is gone, a print to it fails with EIO, and errexit holds inside a trap (bash 3.2, probed): a loop that forwarded the TERM and went on to say "stopped (exit 143)" died of the saying, at 1, with no summary — the land undoes its merge and leaves the card in Review, and the ledger's own trap covers it. On `main` after 0.15.0; scenario 48, the worker's group hung up on while its plan station runs, and the loop on a pty whose master closes over it — under `--no-tui`: the dashboard's path, the default on a terminal, still ended 1 with no summary and its lock left, until 15.10.
- **14.9** A failed land's comment had no routable first line — read (research §4.5). The note opened with `# <ID> — not landed`, a title no reader of first lines knew, so a card in Needs Human over an undone merge was the one the project manager could not route. The first line is `land: <headline>` — the suite red on the result, a merge git refused, `prepare` failing or moving a tracked file — and the note's last paragraph names the command that lands it once resolved; `AIF_BOARD_HEADS` lists it and the pjm skill routes on it. On `main` after 0.15.0; scenario 25.
- **14.10** The reviewer's `wrong` and `cancel` comments had no fixed first line — read. The verdict was prose in the reviewer's words, and the project manager — or anything in bash — had to read the whole comment to know it was one. The review skill and command write `wrong: <the first thing wrong>` and `cancel: <why>` as the first line, one line per further thing under it; the pjm routes on them, and still on a human's own words. On `main` after 0.15.0; a project gets it when `aif init` refreshes its set.
- **14.11** A role's `model:` frontmatter would silently override the user's `--model` — probed (FINDINGS #27: `model: haiku` in a skill or a command answered from haiku under `--model sonnet`; only `inherit` lets the flag through; a skill beats a command of the same name). `check-set.sh` refuses a `model:` line other than `inherit` on every human role, `skills/aif-*/SKILL.md` and `commands/*.md`; the stations under `agents/` keep theirs, which is the tier's. On `main` after 0.15.0.
- **14.12** A dependent was released by the land of the ticket it names, and by nothing else — read (research §4.4; §6.11, verification 4). `_aif_land_release` takes the cards that name the ticket it just landed, so a slice cut after its dependency landed, a dependency merged by hand, or a land whose move on the board failed left a card in Backlog that nothing would release; and the Done column alone is not a landed ticket — the project manager's cancel puts a card there too. `aif board release [--dry-run]` (lib/release.sh) is the pass: every Backlog card with a `depends_on`, moved to the bottom of Ready under a `released by aif board release:` comment when each dependency is Done and `aif: land <dep> — ` is a commit on the main checkout's branch; held under a `rework:`, `blocked:` or `cancelled:` head, or a `parked` / `retired-direction` label (`AIF_RELEASE_HOLD_LABELS`); a Done dependency without a land commit named as a merge by hand, with the move that releases its dependent on purpose; loud when the board cannot be read. The land's own release is unchanged. On `main` after 0.15.0; scenario 49.
- *(14.1–14.6 are open, above.)*

### Log 15 — 0.16.0, building the shift (2026-10-06/07)

`aif start` — the shift: review, analyst and owner sessions opened one at a
time in a person's terminal, the board moved by fixed rules on fixed first
lines — and the loop beside it in another terminal (`aif work --loop
--idle`, `--drain`, `--stop`, the loop lock, `aif work --status`), built to
docs/AUTOPILOT-PHASE1.md. What gave way was found by the probes of
docs/FINDINGS.md #28, by three critics of the spec reading it against the
code, and by the implementers of each part, reading and running what they
built. Nothing in this log closed with it; the work it did on older
entries is Progress under 11.1, 13.8, 14.1 and 14.3–14.6. A review of the
built shift (2026-10-07: reviewers, then adversarial verifiers) confirmed
twenty findings in it, fixed on `main` before the release — each behaviour
with its row in `check-start.sh`, `check-work.sh` or `check-board.sh`, the
rest in the README and the usage; the two in code released before the shift
are 15.10 and 15.11, and what the fixes leave open is 15.12.

- **15.10** The loop's dashboard ended a closed window with 1, no `summary.json` and its lock left — probed (a pty, the dashboard on: 5 of 5 idle, 6 of 6 with a card held at plan; every card settled). bash runs a trap inside the redirections of the builtin it interrupts, and the dashboard spends its seconds in `read … </dev/tty 2>/dev/null`: the HUP handler's `exec >>loop.log 2>&1` was undone for fd 2 when the read put back its own, the next print hit the dead terminal (EIO, errexit, 1), and the bytes it could not write leaked from stdio's buffer into every `$(…)` after it — the summary's results, the lock's pid read against `$$` (docs/FINDINGS.md #28). The tick makes the redirection again once the read is done with its own, and the EXIT branch throws away what a failed print left before it captures anything (`_aif_work_loop_to_log`, lib/cmd_work.sh). 14.8's row ran `--no-tui`; a row of scenario 48 closes the master over the dashboard. Since 0.15.0; on `main` after 0.16.0.
- **15.11** A drain, a stop or a TERM that came while the loop read Ready was followed by one card more — probed (the read held open by a FIFO among the board's files). The drain had answered "takes no new card"; the TERM stopped every run and then started one no signal reached, which built on after its loop was gone. The stop and the files are looked at again, with builtins, before a card is taken, and a run started as a signal lands is sent it (lib/cmd_work.sh `_aif_work_loop`). The TERM half since before 0.15.0, the drain's since `--drain`; on `main` after 0.16.0; scenario 50.
- *(15.1–15.9 and 15.12 are open, above.)*

### Log 10 — 0.11.0, the first `aif work --loop` after the upgrade (2026-10-02)

Four problems from a loop that built nothing: two tickets stopped at the plan
station on a criterion the tree already satisfied, and the two-runs rule
stopped the loop. None corrupts a build that reaches Review.

- **10.1** A long report was cut through a character, and the worker said it was posted — probed; the refusal observed. The cut counts UTF-16 units, as Trello does, and cuts on a character; "report posted" is said only when it was, with a command that can succeed otherwise (0.12.0; `check-board.sh`).
- **10.2** A ticket over 16 384 characters could not reach its Trello card, and the refusal gave no reason — observed; the checks read. The ready gate counts the ticket as Trello counts it on a Trello project and names how much to cut; `aif board create` refuses before sending, with the count and the limit; the analyst skill names the cap. On `main` after 0.12.0; `check-board.sh`.
- **10.3** A restarted run inherited the stopped plan's files — read; the leftover state observed. A run that did not build restarts on the tree it started from: the stopped plan's skeleton, its edits, its committed plan and tests are put back in a commit that says so, the ticket's record kept; a resumed plan station finds the branch as it is. A run that built is a rework and keeps its code. On `main` after 0.12.0; scenario 42.
- **10.4** The analyst was never told about the check that stopped both runs — observed; the skill read. `/aif-ba` asks of every criterion whether today's tree already passes it, names the shapes that slip through (a guard written as its own criterion: "still", "only", "absent", a count of 0 or 1, a value the code already returns) and the fold — one literal carrying both the guard and the change. On `main` after 0.12.0.
