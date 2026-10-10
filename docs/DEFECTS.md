# Defects — the one log

Every defect found in aif, from the review of 0.5.0 to building the autopilot
mode's shift after 0.16.0 and checking its fixes. One file, two halves: an **open** defect is written in
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

After 0.16.0 the plain tick waits in the `wait` builtin on a backgrounded
`sleep 1`, where a trapped INT always runs its trap (`_aif_work_loop_tick`,
lib/cmd_work.sh; docs/FINDINGS.md #33): a second Ctrl-C sent a tick after the
first, lost 10 times in 60 on 0.16.0, was lost 0 times in 147 by an
independent check of the fix (scenario 56). The dashboard — the default on a
terminal — still waits for its keys in `read -t 1`, and there the race moved
rather than went: a second Ctrl-C landing within about ±3 ms of that read's
timeout is lost, or starts the handler and never ends the loop — on a pty, 4
lost and 16 hung in about 250 trials aimed at the window (each hung loop
killed after 90 s), the same shape on every commit since.

#### Directions

- `scripts/check-work.sh` sends the second Ctrl-C only after the loop has said
  what the first meant, and 0.4 s after that, off the tick; so what the
  harness holds is the loop as a person uses it, not the race.
- Probe the dashboard's half first. A hypothesis to test: bash 3.2's `read`
  runs a trapped signal's handler from inside the signal handler, and the
  SIGALRM longjmp at the read's timeout abandons it mid-way.
- The dashboard's tick takes no timer read while a trap can fire: its time the
  plain tick's way (`sleep … & wait $!`), its keys read without `read -t`
  (termios `min 0 time N`, or a reader nothing can cut mid-handler), the
  terminal restored on every exit.
- Measured as it was found: at least 250 trials aimed at the read's end, 0
  lost and 0 hung, keys still answered.

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

#### Progress

After 0.16.0 `aif_requests_json` reads the analyst's `- slice N → <IDs|not
cut>` list under the last `## Status` as a second source under the tickets: an
id the project's pattern matches counts for its slice unless its ticket's meta
places it, which wins; `cut in part` with no list leaves the next slice
unguessed; a fence at column 0 hides what it holds (lib/requests.sh;
check-start layer A, Opes-shaped fixtures). The case it was probed on is
unchanged: `opes`'s four requests carry no such list, so on a copy all four
still read `not cut`, next slice 1 — an independent check of the fix.

#### Directions

- Where an old request's slices come from — the analyst writes the list once
  (a `/aif-ba` pass with a person's yes), or the shift asks — decided before
  `opes`'s first shift; then `aif start --dry-run` on `opes`, read against it.
- A fence indented one to three spaces at the top level is read as text;
  CommonMark reads it as a fence (minor).

### 15.9 Smaller seams found building the shift — read unless said

Eleven seams. After 0.16.0 most are closed: `aif _ready` exits 3 for a gate
not installed, and the facts tell that (`aif init`) from a gate that could not
run; a card whose comments fail three looks in a row is a line nothing waits
on; a session that changed only another card is a change; a move never tried
is left with its comment in `<shiftdir>/comment-<ID>.md` and the two commands
that make it; R12's key on Trello is a card's entry into Ready as the shift
saw it; a terminal that takes no write after a failed session is the hang-up,
129 (probed); the key and session seams are the shift's own, and `*` is a
whole wait; `--status` lists `--no-worktree` builds and says "its phase
unknown" of a lock with no phase; a signal during the Ready read is not the
board, and `--loop --stop` reaches a loop in its preflight (check-start layers
A, C, T and D; scenarios 55, 58). What is left, each found by an independent
check of those fixes:

- The ticket pattern is jq's in the facts and the loose-ticket scan only.
  lib/release.sh's sweep still `grep -E`s it — with `\z` the oracle plans "the
  sweep releases AIF-2" and the sweep releases nothing —, `aif land` refuses
  such a pattern (`grep -qE`, lib/cmd_land.sh), and Trello's next-ready
  matches with jq, then `grep -oE` (probed).
- A shift that ends "nothing left for the shift" with a card it could never
  read ends rc 0 (probed).
- A session that only moves a card from Needs Human to Ready, with no comment,
  still reads as "changed nothing": Ready is outside the after-read (probed).
- The by-hand lines print a path unquoted: in a project whose path holds a
  space the pasted line fails, and `&&` stops the move — safe, not useful
  (probed).
- On Trello a card that leaves Ready and comes back between two looks keeps
  its first entry, and its build is not offered again (read).
- A loop that leads no process group answers `--stop` after 90 s with rc 1,
  though it does stop (read; the code says so).

What a fix has to decide: each its own; none of them stops a shift on a local
board.

#### Directions

- One matcher for the ticket pattern — jq's `test` — in the sweep, the land
  and next-ready, a row per site.
- The rest one at a time, each with its row in `check-start.sh` or
  `check-work.sh`.

### 16.4 What the gates let through can hide a regression the ticket made — probed

Since 13.9 the gates let through what was red before the ticket (`red_at_base`
in verify-red and green, `at_base` for a check), a test that passes its one
re-run (`flaky`), and an older test in a declared file (`standing`, 12.3) —
each named on the gate's line, in the ledger and in the report. Tried with
tickets built to slip through (a fake suite writing junit, on the gates as
committed), each of these was let through and built:

- a test red on `main` that asserts two things, one of which the ticket
  removed: its message gained "users() is gone", and it was let through as red
  before the ticket — and landed, the land holding the same id against the
  target the same way;
- a count line: "Found 1 error" became "Found 2 errors", which
  `aif_g_new_lines` folds to one line on purpose, so that a fix on `main` does
  not read as new;
- a check whose command short-circuits (`lint && types`), red at base: the
  type error the ticket added never runs, and the check is `at_base`;
- a race the implementation added — a test failing 3 runs in 6 on the built
  tree — passed its one re-run and was let through as flaky at the first
  attempt;
- a standing test the tests station rewrote in place (same id, its body
  `true`) while the implementation dropped what it held: "standing" is the id
  and its status at the base, not the test;
- the land measures the target as it was with the merge's installed
  dependencies: a branch that moves a dependency from 1 to 2 let through a
  `main` test that needs 1 as red before the ticket, and a fresh clone of
  `main`, installed from its lock, is red; green's `red_at_base` measures the
  ticket base with the ticket's install the same way (read).

What a fix has to decide: what each let-through must be shown to be — the same
failure, a count that did not grow, a check that judged the code, a flake that
is not the ticket's, a test as the base wrote it, a base measured with its own
lockfile — and what each costs in runs.

#### Directions

- Failure messages compared normalised (durations, addresses, temp paths
  folded); a count line new when a count grew, not when it shrank — in
  `_lib.sh` and the land's twin.
- A short-circuit check red at base said to judge nothing, on its line and in
  the report; `aif project check` warns of `&&`, `;` and `||` in a check.
- A flake let through only on evidence it is not the ticket's — the flipped
  test re-run at the ticket base a bounded number of times —: the added race
  rejected in most trials, the base's own flake still let through, the cost
  said.
- A standing test run as the base wrote it — its files at the base, in a copy
  — when the ticket touched them.
- No let-through when a lockfile differs between the base measured and the
  tree judged, unless the base is measured with its own install (cached per
  lockfile).

### 16.5 An older test that flakes at verify-red stops the run — probed

verify-red runs the suite twice and rejects a test whose verdict moves between
the runs as non-deterministic. An older test in a declared file that failed on
the first run only — a flake that was there before the ticket — took that
path: "a test whose verdict moves between two runs of the same tree is
non-deterministic", and the run stopped, on every commit since 13.9's fix.
`flaky_ids` takes such a test out of the foreign red, never into the flakes
the gate lets through.

What a fix has to decide: nothing beyond the rule — an older test that flips
is a flake like any other, named and let through; the verdict of
non-determinism stays for the ticket's own tests.

#### Directions

- The older test that flips is `flaky` in the lock and the report; a row with
  an older test in a declared file failing on verify-red's first run alone.

### 16.6 The gates' copies reach the real tree through the dependencies they link — probed

Since 13.9 a gate's copy links the ignored dependency directories
(`node_modules` at any depth, `.venv`, `venv`) instead of copying them. A
workspace link inside them — `node_modules/@ws/pkg -> ../../packages/pkg`,
relative — then resolves against the real `node_modules`, so every copy
imports the real tree's package (probed with node 22): a contract that changed
`packages/pkg` and broke an older test was built with that test listed as red
before the ticket, though it is green on `main`; an implementation that broke
it was "out of the implementation's reach", exit 3; correct work whose
covering test imports `@ws/pkg` was rejected twice — "stays green with the
implementation reverted" — and stopped. A runner's cache written in a copy
lands in the real `node_modules`. And an ignored directory the copy cannot
read — a database's data directory owned by another user — stops every ticket
at green, exit 3, with no way to leave it out; refusing an unreadable file is
13.9's point. `AIF_G_COPY_DEPS=1` copies again and gives the right verdicts.
`opes` has no workspaces.

What a fix has to decide: how a copy links dependencies so a relative link
among them resolves inside the copy; which cache directories stay the copy's;
and how a project names paths its copies leave out.

#### Directions

- `node_modules` a real directory in the copy, each entry linked, an entry
  that is itself a link made again as the same link, one level into `@scope`;
  `.cache`, `.vite` and `.vitest` not linked.
- A `project.json` key (both templates, `aif project upgrade`) naming paths
  the copies leave out, named in the refusal; an unreadable file still
  refuses.

### 16.7 Plan, scope and the amendment read deletions, renames and new files loosely — probed

- `files.delete` naming a directory passes the plan gate and can never pass
  scope: each file deleted under it is refused, and keeping one is "still
  there".
- `git mv old.py new.py` passes scope though the deletion of old.py was never
  planned: rename detection hides it from `--diff-filter=D`, and the guard
  allows `git mv` (on every commit since the gates had a scope).
- An amendment made after its file was written judges the file as existing:
  `newroot.py`, `config/settings.py`, `src/.env` and `.babelrc`, written and
  then amended, are recorded as a change and pass scope — the place and name
  rules read the working tree, not the dispatch base; amended first, they are
  refused, as they should be.
- `src//x.py` is accepted by the amendment and fails scope.

What a fix has to decide: each its own.

#### Directions

- A directory in `files.delete` covers the files tracked under it at the base.
- Scope's diff with `--no-renames`: a rename is a deletion and a creation,
  each judged.
- The amendment judges new or existing, and the place and name rules, against
  the dispatch base, the path normalised first.

### 16.8 A pass's warnings reach no one, and green measures a file the ticket's new ignore rules hide — probed

Scope prints what a planned `.gitignore` change now ignores ("IGNORED FROM NOW
ON"), and the plan gate the CI and ignore rules it admits ("CI AND IGNORE
RULES"), after their first line; `aif _gate` keeps only the first line of a
pass, so neither reaches the worker's output, the ledger or the report. End to
end: the implementation wrote `src/gen.py` and added it to the planned
`.gitignore`; green, scope and the land passed — the land judges in the
worktree, where the file still is — and a fresh clone of `main` lacks it and
is red.

What a fix has to decide: how a pass's warning lines travel; and whether a
file only the ticket's new rules hide is left out of the gates' copies — a
fresh clone's view — or refused at scope.

#### Directions

- `aif _gate` keeps a pass's warning lines for the worker's output and the
  report.
- The gates' copies and the land's judging copy leave out what only the
  ticket's new ignore rules hide; scope computes that list already.

### 16.9 The guard lets a path through `..` — probed at the hook

The guard hook (sets/claude/hooks/guard.sh) closes `.aif/`, `.claude/` and
`tasks/` to every station but its own file there (13.10), matching the path as
it is handed: `src/../.aif/project.json`, `src/../tasks/T-2/plan.md` and the
tests station's `__tests__/../.aif/…` are allowed on every commit since. The
plan station has no Bash and no scope, so the hook is all that keeps it out of
those directories. Whether claude hands the hook a normalised path was not
checked.

What a fix has to decide: nothing beyond normalising.

#### Directions

- `.`, `..` and `//` resolved lexically before any match; a path that leaves
  the project after that is denied; rows in `check-set.sh`.
- Read or probe whether claude normalises the path first.

### 16.10 The block aif manages in `.gitignore` is read by exact lines — probed

- `aif init` (`aif_block_inject`, lib/merge.sh) on a `.gitignore` whose block
  has its begin line and no end drops every line after the begin and writes no
  end — `node_modules/` and `dist/` lost in the probe — and `aif doctor` tells
  a block with no end line to run `aif init` ("it rewrites that block and
  nothing else"). 15.14 guarded `aif_gitignore_ensure` only.
- `aif_gitignore_ensure` matches its markers exactly, where `aif_block_inject`
  and doctor take a `\r`: a CRLF `.gitignore` gives a false "has no end line"
  on every worker run, an end line with trailing text the same, and an end
  line above the begin prints "added" and adds nothing.
- `aif doctor` reads the block's text, not git: a path the developer ignores
  outside the block — their own line, or `.aif/` whole — is named missing.

What a fix has to decide: each its own.

#### Directions

- `aif_block_inject` leaves a file with a begin and no end alone, and warns,
  as `aif_gitignore_ensure` does; doctor names the end line to add.
- Markers matched past a `\r` and trailing blanks; an end above the begin is
  no end.
- Doctor asks `git check-ignore`.

### 16.11 With a dotted ticket pattern a second take's log is another ticket's — probed

15.7 gave each take its own log, `<ID>.2.log` onward. Under a `ticket_pattern`
that allows a dot, `AIF-82.2.log` is also ticket `AIF-82.2`'s log, and the
second take of AIF-82 writes over it — on every commit since 15.7's fix.

#### Directions

- A take's log under a name the pattern cannot produce, every reader of the
  names (the results rows, `--status`, the dashboard) with it.

### 16.12 The dashboard's ends: a terminal gone with no hang-up, and a KILL nobody sent — read; probed

Since 15.15 a frame that cannot be written does not end the loop, and after a
HUP its output goes to loop.log. A terminal that goes without a HUP — every
frame failing with EIO — now leaves the loop running headless at a frame a
second, where it used to end with 1 (read). Apart from that, a dashboard loop
died of SIGKILL (137) about 0.1 s after its first Ctrl-C, twice in about 230
trials on the latest commit and once on an older tree (probed); nothing in aif
sends KILL, and it was not traced.

#### Directions

- A run of frames failing in a row is a hang-up — the HUP's path: exit 129,
  the runs stopped, loop.log saying so.
- Trace the 137 to whoever sends it.

### 16.13 On Trello, what the fixes rest on and nothing has seen — read

- Head reads page back with `before=<action id>`, and a claim's age is
  `data.dateLastEdited` (or `dateLastEdited`): both were built on the mock and
  neither was seen on the real board. Without the edit's date the heartbeats
  are invisible, and a worker paused past the wall clock reads as gone to
  another checkout, which may take its card.
- A head under more than 100 newer comments reads as no head everywhere but
  R17, which says so.
- A dead claim of another checkout holds its card for up to the wall clock,
  with no override.
- A moved checkout names itself anew (`aif_clone_id`), so the claims it posted
  before the move read as another checkout's for up to the wall clock.

#### Directions

- Probe `before=` and an edited comment's fields on a board made for it —
  never a project's own.
- An override for a dead foreign claim, by a person's word.

### 16.14 The land's edges after the fast-forward moved out of reach — read

- A commitlint-style commit-msg hook refuses every land: the land's own commit
  keeps the project's hooks (13.11), and its subject is `aif: land …`, which
  the shift's facts, start.jq's `landed()` (R8, R10) and lib/release.sh read.
- `_aif_land_settle_ff` runs three or four git commands per path the merge
  touched — minutes at 30 000 files, by reading; not timed.
- A git KILLed during its ref update could leave `refs/heads/<target>.lock`;
  the settle would refuse with an empty list of paths.
- The starter that puts the fast-forward out of the land's tree lives 1–5 ms;
  an interrupt in that window can still reach the section, which ignores TERM
  and runs on.

#### Directions

- One helper owning the land's subject for every reader, or a subject the
  project sets.
- The settle timed at 30 000 files; a ref lock named as the index lock is.

### 16.15 Two harness rows can kill another run's processes, and one depends on a path's length — probed

Rows 54 and 57 of `scripts/check-work.sh` pick a pid with a global `pgrep -f
'sleep 63.3' | head -1` and `kill -9` it: two runs at once — another
checkout's, a verifier's — kill each other's processes and fail. Scenario 52's
orphan row needs the station's command within the 200 characters
`_aif_work_status_orphans` keeps of a command line; a long TMPDIR made it 211
and failed it.

#### Directions

- Each pick scoped to the row's own sandbox; the harnesses searched for the
  same shape.
- The row, or the cut, not bound to TMPDIR's length.

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

- *(11.1 is open, above: its plain tick closed after 0.16.0, its dashboard's not.)*

### Log 12 — 0.12.1, the analyst on `opes` (2026-10-04)

- **12.1** The analyst cut a feature into fragments: the size cap counted examples, not rules — observed. A ticket carries `rules` (`R-1`…, a sentence each) and every criterion names the rule it is an example of; the ready gate caps the rules (`ticket_rules_max`, 6), keeps a backstop on the examples (`ticket_examples_max`, 30) and a warning past five on one rule (`rule_examples_warn`), names the order over the cap — restate, an axis of variation, the user — instead of "split the ticket", and lets only a size decision by the human keep a ticket whole. A ticket without rules is held to `ticket_ac_max` as before — the backstop is a key of its own because `aif project upgrade` leaves a project's values alone, and `opes` holds 15. `/aif-ba` works rules first, then the key examples of each; that half is prose, measured first on a live cut. On `main` after 0.12.1; scenario 43.
- **12.2** The analyst saw `main` and nothing in flight, so a ticket could restate a rule another ticket owned — read; the case probed (OPES-69 in Review, its code only on `aif/OPES-69`, and the next request restating its days-left and allowance rules). `aif rules [<word>…]` is the map — every ticket's rules in force with its column on the board, computed from `tasks/` and the board, a rule a later ticket changed left out unless `--all`, a ticket from before rules showing its criteria. A rule names what it replaces in `changes` (`<ID> R-n`, or `<ID> AC-nnn`); the ready gate holds every name to a ticket and a rule under `tasks/` and prints them on the pass path; the plan station puts the older tests in `files.tests`, the tests station removes or rewrites the ones the rule ends. `/aif-ba` reads the map before the code, sorts each rule — its own, a change, another ticket's (not written again, `depends_on`), a conflict (asked) — and cuts a request by giving each rule to exactly one ticket. On `main` after 0.12.1; scenario 44. The worker's half is 12.3.
- **12.3** A ticket whose rule changes another's read that ticket's settled tests, left in a file it had to declare, as its own — green at freeze, out of covering, on the closing checklist — read. verify-red rejects a collected test carrying a criterion the ticket's rules replace (a stop when no station can reach its file); an older test in a declared file, there and green before the ticket, is `standing` — out of the new tests, the coverage and the checklist, frozen as pre-existing for green to hold, counted on the report; the plan gate rejects a plan that leaves a file naming a replaced criterion out of `files.tests` (`aif_g_replaced_markers`). On `main` after 0.16.0; scenario 70. The run on `opes` it was found for (OPES-75) is not yet watched; a standing test rewritten in place is 16.4, an older one flaking at verify-red 16.5.
- **12.4** Two caps from the first gates, 12 implementation files a plan and 400 lines a change, shaped tickets and never caught a run — measured on `opes`. In every run there neither fired: the widest plans were 12 files (OPES-59, OPES-66) and the largest change 371 lines (OPES-74), and the August refusals at scope were not the size (the first OPES-58 attempt changed 143 lines; OPES-61 and OPES-63 were the ledger on the denylist). Both acted before any run, through the analyst's estimate of them: the daily allowance was cut down to fit "about 420 lines", and the gate measured 186 when it was built; OPES-75/76 were split, by default, to fit 12 files. Retired: plan and scope say the size and refuse nothing for it — the paths the plan named and the whole suite stay the bounds. The templates list `plan_files_max`, `diff_lines_max` and `revisions_max` (read by nothing since 0.5) under `limits_retired`; `aif project check` names one a file still sets, `aif project upgrade` takes it out; `/aif-ba` never cuts by an estimate of lines or files. On `main` after 0.12.1; scenario 45.

### Log 13 — 0.13.0, a branch that could not land (2026-10-05)

`aif land OPES-74` on `opes` stopped on a conflict, and the conflict was not
in the code: `aif/OPES-74` met `main` in `tasks/OPES-74/ledger.json` alone.
That started a read of every place a ticket stops for a reason other than its
implementation — twelve. 13.1–13.3 and 13.12 closed in 0.13.1 (scenario 46);
13.4 and 13.13, the user's calls on them, on `main` after 0.14.0 (scenario
47); 13.6 on `main` after 0.15.0 (scenario 48); the rest — 13.5 and
13.7–13.11 — on `main` after 0.16.0 (scenarios 25, 27 and 60–88).

- **13.1** A ledger write that failed stopped the run — probed: a lock left in `tasks/<ID>/`, and the plan gate passed while `aif _gate` exited 1 on the append; the worker sent the plan back as rejected, then died writing its report — Needs Human, `blocked: run … ledger is locked`, no report; `|| true` around the fold caught nothing, since `aif_die` is an exit. Every ledger write is best-effort now, in a subshell of its own: a lock nobody holds is taken over (this process's, a gone one's, an unsigned one, one older than a minute), a live writer is waited for five seconds and the row then skipped with a warning, a ledger that is not JSON is set aside and a new one started; `aif _gate` records its verdicts in a block whose failure is a warning, so its exit is the gates' verdict alone. Released in 0.13.1; scenario 46.
- **13.2** aif's own files conflicted at land — observed on `opes`: `aif/OPES-74` (built 2026-10-02) conflicted with `main` in `tasks/OPES-74/ledger.json` alone, added on both sides — the analyst's empty one, committed with the reworked ticket after the branch was cut, and the branch's with fourteen rows; `ticket.md` was one blob on both sides and the code merged clean. Probed the same in scratch. `aif _ticket-init` and `aif board pull` write no ledger now; the worker makes it at intake. `aif land` settles a conflict in aif's own files by owner (lib/integrate.sh): the ticket's record under `tasks/<ID>/` is the branch's; another ticket's, and the set under `.aif/` and `.claude/`, the checkout's. The merge commit, the summary and the card say what was settled. Conflicts in code are 13.4. Released in 0.13.1; scenario 46.
- **13.3** The analyst's uncommitted ticket stopped the land's merge — probed: git refuses to write over an untracked file, byte-identical or not, and the land reported it as a conflict for a human. The land takes the ticket's own untracked files aside to `.aif/tmp/land-<ID>-<when>/` before merging, puts them back if the merge is undone, and says whether they differed from what landed; anyone else's untracked file in the merge's way refuses the land before anything is touched, the card left in Review. Released in 0.13.1; scenario 46.
- **13.4** A branch never took in the branch it lands on, and a conflict in code had no way through — read; observed on `opes` (`aif/OPES-74` 28 commits behind `main` when it came to land; `aif land` aborted, the card went to a human, and back in Ready the built run resumed at `done` and stopped on the same conflict). The worker brings the branch onto the checkout's branch before it says built (`_aif_work_sync`): the merge in the worktree, aif's own files by owner, a conflicted lockfile taken from the target for the package manager to write again, a conflict in code to the implement station with MERGE in its prompt (both sides' behaviour kept, no marker left — the worker checks), the test files the merge brought taken into the lock and the lock guarded from the station, then green and scope on the merged tree: scope passes over a path that is exactly the target's, and the ticket's own record; green reads a failing test from a file the merge brought as pre-existing. A test file in conflict, a replan in the station's note, or its attempts spent: the ticket is built again from the target, automatically — the first build kept under `refs/aif/archive/<ID>/<n>`, the plan station told and handed the old plan, once (`limits.rebuilds_max`). `aif land` sends a conflict in code, or a red on the result with the dependencies as the merge pins them, back to the top of Ready with a `sync:` comment, and the card returns to Review to be looked at again — the user's calls, 2026-10-05: back to Review after a settlement, a rebuild without asking. The report says what the sync took and where to look. On `main` after 0.14.0; scenario 47.
- **13.5** The land merged into the developer's own checkout and judged the result there on the suite alone — read: it refused while anything tracked was uncommitted, judged a merge that moved a lockfile against the install from before it (6.3), and ran no checks. The merge, its install and its verdict are made in the ticket's own worktree, put at the target's tip: the worker's verdict stands when the merge is the tree it judged (run.json `judged`), else the suite and the checks bound to green run there (`_aif_land_judge`); the developer's branch moves only by a fast-forward, refused only by uncommitted changes to files the land changes; `--prepare` installs here after it; R7 warns of those files alone (lib/cmd_land.sh, lib/start.jq). On `main` after 0.16.0; scenarios 25, 27, 60–62; check-start layers A and C.
- **13.6** A rework on the local board never reached a branch that already existed — probed (scenario 6's shape through a worktree: round two said "resume done — the ticket has not changed since the last run", the branch had built AC-001 while the checkout's ticket asked for AC-001 and AC-002, and the card went to Review with the old build; a Trello card is pulled into the worktree on every run, so only the local board was affected). The worker carries the checkout's `ticket.md` into an existing worktree when it differs — the ticket alone, never the checkout's stale run record over the branch's — and the run restarts on the new bytes as it does on Trello (`_aif_work_intake`, lib/cmd_work.sh). On `main` after 0.15.0; scenario 48.
- **13.7** A usage limit, or a runner that did not answer, was billed to the station — read; the stream's shapes probed and read from claude 2.1.226 (docs/FINDINGS.md #30). The gate rejected what a refused run left, the retry met the same refusal, and the second identical complaint stopped the run `blocked: run` — every worker of a loop at once; no envelope stopped it on one try; an envelope that was not JSON ended the worker with code 5. Stations run on stream-json, and `aif_runner_claude_classify` reads each try as ok, limit, transient or error on fields alone. A limit resetting within 12 h is the shared pause `.aif/state/pause`, waited out and the same attempt dispatched again, uncounted, outside the wall clock — one helper asked before every dispatch — and every worker, the loop and the shift hold on it; with no reset, or a later one, it is `blocked: environment` naming it; a runner that did not answer is asked again after 60/300/900 s, then the environment; a stop during a wait takes the attempt back (`_aif_work_dispatch`, `_aif_work_loop_pause`, lib/start.jq). A real limit's stream has not been seen; its shape is the binary's. On `main` after 0.16.0; scenarios 80–85 and 88 (16.3), check-start layers A and C.
- **13.8** One hiccup stopped the loop, and every move and comment listed the board — read. The board's calls time out and retry (after 0.15.0); a worker that could not start has the machine asked again; one card is read by its cached id (`.aif/state/trello-cards.json`, `_aif_trello_find_card`) while the board says it is still that ticket's open card in a project list; a runner that produced no envelope, or one not JSON, the throttle or an overload, is asked again after a backoff and then settles the card `blocked: environment`, which the loop reads as the machine — its preflight asked again, not one of two in a row (`AIF_WORK_RUNNER_ENV`). On `main` after 0.16.0; check-board, scenarios 51, 83.
- **13.9** One red test or check on the base stopped every ticket, a flaky test was a verdict, and the gates copied node_modules whole under `cp -R … || true` — read; measured (docs/FINDINGS.md #36: a copy of `opes` 0.28 s and 7.4 MB linked, 10.8–11.0 s and 401 MB copied). A failure not the ticket's own is run once more — passing, it is `flaky`, let through — then measured on the tree before the ticket (`aif_g_ticket_base`, cached under `.aif/tmp/base`): a test red there is let through by verify-red and green (`red_at_base`), a check failing the same way with no new line (`aif_g_new_lines`) at contract, red and green (`at_base`), the new lines judged alone; `aif land` judges its merge by the same rule against the target as it found it. Each is named on the gate's line, in the ledger and in the report. The copies link ignored dependencies (`AIF_G_COPY_DEPS=1` copies them) and stop, exit 3, on a file they could not copy. On `main` after 0.16.0; scenarios 71–74. What a let-through can hide is 16.4; an older test flaking at verify-red 16.5; what the linked copies reach 16.6.
- **13.10** Rules refused correct work — read. A deletion is the plan's `files.delete`, held by scope both ways; an amendment may create a file beside the plan's own, and past its cap names the replan; `.github/`, `.gitlab-ci*` and `.gitignore` move when the plan names them, never by amendment, and scope says what a planned `.gitignore` now ignores; the guard is told the ticket (`AIF_TICKET`), lets the tests station write what `files.tests` declares, holds the plan and implement stations off it, and closes `.aif/`, `.claude/` and `tasks/` to every station but its own file there. The caps keep their values, the wall clock asked before every dispatch (13.7) — closed by decision; the measurement on `opes` the entry asked for was not made. On `main` after 0.16.0; scenarios 75–78, check-set's guard rows, check-work's guard row over every station write. What gave way after: 16.7–16.9.
- **13.11** aif's own commits ran the project's git hooks — read; probed (FINDINGS #30: a post-checkout exiting 7 fails `worktree add` and `checkout --ours` after their work, and `--no-verify` skips pre-commit and commit-msg only). Every git command the worker runs on its own behalf that can fire a hook — its commits on `aif/<ID>`, `aif _commit`, the sync's merge, checkouts and resets, the worktree's cut — runs through `aif_git_own` (`-c core.hooksPath=/dev/null`, lib/common.sh); the land commits its merge itself, `git commit` in the worktree under the project's hooks — a refusal is a `land:` line, nothing landed — and every other git call of the land's runs none. On 0.16.0 a formatting pre-commit corrupted the run record at intake and the worker died with code 5. On `main` after 0.16.0; scenarios 66, 67, 86. A commitlint-style hook refuses every land's subject: 16.14.
- **13.12** aif's temp files sat in `tasks/<ID>/`, where scope reads any file as an implementation editing the pipeline's record — read. The ledger's go with its subshell; `aif_run_update` and `aif_meta_replace` remove theirs when a write fails. A write killed between its `mktemp` and its `mv` still leaves one. Released in 0.13.1.
- **13.13** The ledger was committed with the ticket, so it rode every merge the ticket's branch made — decided (the user, 2026-10-05): out of git. It lives in the main checkout, `.aif/state/ledgers/<ID>.json`, gitignored, written by every worktree; a ticket's old committed ledger is read once as the start of the new one and never written again; `aif cost` reads both; scope keeps the old path exempt for branches from before. On `main` after 0.14.0; scenarios 46, 47.

### Log 14 — 0.15.0, the autopilot research (2026-10-05/06)

The research for `aif start` — a mode that would open the human roles'
sessions one after another and run the loop between them — read and probed
every place such a supervisor would lean on, and the unhappy paths gave way
on each (docs/AUTOPILOT-RESEARCH.md §6.11; FINDINGS #27). Twelve entries:
14.7–14.12 on `main` after 0.15.0, held by scenarios 25, 48 and 49,
`check-board.sh` and `check-set.sh`; 14.1–14.6 on `main` after 0.16.0 —
begun in 0.15.0 and in the shift's work (log 15), finished in its fixes.

- **14.1** The run lock recorded the worker's pid and nothing of its station, and a takeover looked at nothing but the lock — read (research §6.11, verification 5). The lock records the worker's `pgid` and, while a station runs, the station's own pid in `<lock>/station`, written by the station's process (`_aif_work_dispatch`, `aif_runner_claude_station`; FINDINGS #29). What a dead worker left is named by that group when the dead worker led it (16.1), by that pid, or by a cwd in this clone's worktree, each with its `why` (`_aif_work_status_orphans`); the takeover — `aif work <ID>`, the loop's worker, a `--stop` of a gone worker — sends TERM to the group or each pid, never to a process tied to the run by its cwd alone (that refuses the takeover at once), looks again every second for 30 s, and refuses with exit 3 while anything runs; the loop holds a refused card without counting it as the machine. A worker that leads no group of its own still leaves a child that left the worktree to nobody. On `main` after 0.16.0; scenarios 54, 57, 91; check-start layer C.
- **14.2** `_aif_work_block` moved the card to Needs Human with its comment refused, and the reason stayed on one machine's disk — read. The next `aif work` on that machine posts every kept `.aif/tmp/blocked-<ID>.md` before it takes a card, comment only, while the card is in Needs Human under nothing but its run's own claim, and removes the file; a card that moved on, or reached Review or Done, has the stale file removed (`_aif_work_repost_kept`). `aif start` makes the same post as a move that does not move (`kept_block`, R18). On `main` after 0.16.0; check-board (the AIF-7 path), scenario 68, check-start layers A and T.
- **14.3** The loop's exit code was not the board's state — probed. Closed by decision: callers read `summary.json`, and the rc says how the process ended (`_aif_start_run_build`). An exit 3 is the machine only once it was asked again — a worker that could not start (13.8), a Ready that could not be read, which ended it 3 on one failed read; a refused takeover is held, not counted; the why no longer says "Ready is empty" over held cards. On `main` after 0.16.0; scenarios 51, 57, 58; check-start layer C.
- **14.4** Two machines on one Trello board could both build a card, and a live remote worker looked like a hand-drag — read; measured: 3 of 3 simultaneous takes built twice before, 8 of 8 once after (FINDINGS #34). A take skips another checkout's claim whose worker was alive within a run's wall clock (`_aif_work_claim_check`); of two live claims since the card's last other head the earlier builds, and the later withdraws as `not taken: …` (`_aif_work_claim_race`); the loop holds such a card. A claim names its checkout — `taken: <host>:<clone>` (`aif_clone_id`), so two clones on hosts of one short name no longer read each other's claim as their own (2 of 2 built twice before) — beats at every dispatch (`_aif_work_heartbeat`, `aif_board_comment_edit`), and on Trello its age is the board's clock (the comment's `date`, its last edit), not its writer's. `aif start` reads a claim silent past the wall clock + 10 min as a worker likely gone — a line, never a move. On `main` after 0.16.0; check-board, scenario 69, check-start layers A and T. What rests on Trello fields not yet seen live is 16.13.
- **14.5** A dead lock was taken over by `rm -rf` then `mkdir`, a reused pid running any `aif work` read as its holder, and a resume reset what a takeover could count — read; the race measured (5–10 of 40 races left two holders or none, FINDINGS #29). One helper takes the run, loop and shift locks (`_aif_work_lock_take`): a mark inside the dead lock decides the one taker, which re-reads, moves aside, checks the copy and remakes the lock, and only the mark's holder looks for orphans (16.2); a pid started after its lock was signed is not the holder; `run.json` counts `takeovers`, a resume keeps it, and the fourth stops the run `blocked: run`. On `main` after 0.16.0; scenarios 53, 92.
- **14.6** The `fable` alias was not routed by a profile, and the worker sent a station's alias as it was — read. claude 2.1.226 routes fable through `ANTHROPIC_DEFAULT_FABLE_MODEL` and matches an alias trimmed and lowercased (read): a profile maps fable with that variable (glm's does), aif compares aliases the same way, and the worker's preflight refuses, exit 3 before the claim, a station whose model the profile does not map, naming it and what the profile maps (`_aif_work_station_models`); `default` and no model at all are one rule, in the worker and the shift alike. On `main` after 0.16.0; scenarios 87, 93, check-start layer B.
- **14.7** Trello's `show` hid a failed comments read as `[]` with rc 0 — read (research §6.11, verification 3). A card whose comments the API would not give looked like a card with no comment, and every reading of a first line downstream — the project manager's, a sweep's — would have read "nothing here". The adapter dies with the reason (`Trello: could not read the comments of <ID> — …`); `aif board head` exits 2 for it, apart from the 1 of a card with no head; `check-board.sh` asserts it under three 500s on the actions call, through the mock's fault file. The two readers that only ever wanted a card's column — the land's "is it in Review" and `--stop`'s "is the gone worker's card still In Progress" — read it out of `show` under `2>/dev/null … || true`, so the loud failure reached them as an empty column: the land refused a landable card as "no card on the board", and the stop removed the lock under an In Progress card, left for the next `aif work` to take as fresh. Both read it through `aif_board_card_column` now — one listing of the cards, no comments asked — and a board that cannot say is the land's exit 3 and a stop that keeps the lock; `check-board.sh` holds each under a fault on the comments GET alone (`actions?`, the query string telling it from the comment's POST). On `main` after 0.15.0.
- **14.8** Nothing in aif handled HUP — read (research §6.11, verifications 2, 5 and 6). A closed window hung up on the worker's whole group: the station died of it and the card stayed In Progress; a land between its merge and its verdict died with the merge in place and nobody told. `aif_trap_arm` traps HUP beside EXIT, INT and TERM; the worker settles its card as `blocked: stopped — by a hang-up — the terminal closed — during <stage>` and exits 129, the loop stops its runs and exits 129 with `hup` in its summary — its own lines going to its loop.log from the hang-up on, because the terminal they went to is gone, a print to it fails with EIO, and errexit holds inside a trap (bash 3.2, probed): a loop that forwarded the TERM and went on to say "stopped (exit 143)" died of the saying, at 1, with no summary — the land undoes its merge and leaves the card in Review, and the ledger's own trap covers it. On `main` after 0.15.0; scenario 48, the worker's group hung up on while its plan station runs, and the loop on a pty whose master closes over it — under `--no-tui`: the dashboard's path, the default on a terminal, still ended 1 with no summary and its lock left, until 15.10.
- **14.9** A failed land's comment had no routable first line — read (research §4.5). The note opened with `# <ID> — not landed`, a title no reader of first lines knew, so a card in Needs Human over an undone merge was the one the project manager could not route. The first line is `land: <headline>` — the suite red on the result, a merge git refused, `prepare` failing or moving a tracked file — and the note's last paragraph names the command that lands it once resolved; `AIF_BOARD_HEADS` lists it and the pjm skill routes on it. On `main` after 0.15.0; scenario 25.
- **14.10** The reviewer's `wrong` and `cancel` comments had no fixed first line — read. The verdict was prose in the reviewer's words, and the project manager — or anything in bash — had to read the whole comment to know it was one. The review skill and command write `wrong: <the first thing wrong>` and `cancel: <why>` as the first line, one line per further thing under it; the pjm routes on them, and still on a human's own words. On `main` after 0.15.0; a project gets it when `aif init` refreshes its set.
- **14.11** A role's `model:` frontmatter would silently override the user's `--model` — probed (FINDINGS #27: `model: haiku` in a skill or a command answered from haiku under `--model sonnet`; only `inherit` lets the flag through; a skill beats a command of the same name). `check-set.sh` refuses a `model:` line other than `inherit` on every human role, `skills/aif-*/SKILL.md` and `commands/*.md`; the stations under `agents/` keep theirs, which is the tier's. On `main` after 0.15.0.
- **14.12** A dependent was released by the land of the ticket it names, and by nothing else — read (research §4.4; §6.11, verification 4). `_aif_land_release` takes the cards that name the ticket it just landed, so a slice cut after its dependency landed, a dependency merged by hand, or a land whose move on the board failed left a card in Backlog that nothing would release; and the Done column alone is not a landed ticket — the project manager's cancel puts a card there too. `aif board release [--dry-run]` (lib/release.sh) is the pass: every Backlog card with a `depends_on`, moved to the bottom of Ready under a `released by aif board release:` comment when each dependency is Done and `aif: land <dep> — ` is a commit on the main checkout's branch; held under a `rework:`, `blocked:` or `cancelled:` head, or a `parked` / `retired-direction` label (`AIF_RELEASE_HOLD_LABELS`); a Done dependency without a land commit named as a merge by hand, with the move that releases its dependent on purpose; loud when the board cannot be read. The land's own release is unchanged. On `main` after 0.15.0; scenario 49.

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
are 15.10 and 15.11, and what the fixes leave open is 15.12. After 0.16.0
every entry but 15.5 and 15.9 closed, with three found on the way
(15.13–15.15); an independent check of those fixes is log 16.

- **15.1** One Ctrl-C in a review session sends the land TERM and SIGKILL 1.3–1.5 s later, and a land killed outright left its merge on the developer's branch — probed (docs/FINDINGS.md #35): 0.16.0's undo beat the KILL, writing a merge and a reset to main's reflog each time; a KILL alone left the merge. The developer's branch is touched only by the last step now; a stop before it puts the worktree back in about 35 ms. The fast-forward runs where neither signal reaches it: first in a process group of its own, then — since claude's interrupt also TERMs and KILLs a command's descendants by parent pid (read, 2.1.226), and a fast-forward cut that way left 15 569 of 30 000 files untracked under "nothing landed" — in a process that is nobody's child (`_aif_land_section_start`, FINDINGS #38). "Nothing landed" is said only of a checkout proven untouched (`_aif_land_ff_untouched`); otherwise a marker, `.aif/state/land.json`, stays for the next land and `aif doctor` to finish or put back what was cut (`_aif_land_ff_left`, `_aif_land_settle_ff`), and git's own lock is named, never removed. A worker refused because a land of its card runs here is held by the loop, not the machine. On `main` after 0.16.0; scenarios 27, 63–65, 67, 79, 89, 90. What is left at its edges is 16.14.
- **15.2** `.aif/start.local` was not ignored in a project set up before the shift, and only the shift's header said so — read. `aif doctor` holds the managed `.gitignore` block against the one `aif init` writes — one list, `aif_gitignore_block` (lib/paths.sh), which init writes byte for byte as before — and names each line it lacks with `aif init`, writing nothing (`_aif_doctor_gitignore_missing`, lib/doctor.sh); the header's warning stays. On `main` after 0.16.0; check-start layer C. Its reading of the block's text is 16.10.
- **15.3** A card an idle loop held stayed in Ready, and a shift beside it waited for it for good — read; reproduced. `owner.json` says `held: [{ticket, why}]` as it changes (`_aif_work_loop_held_publish`); the idle line says "Ready holds only cards this loop will not take again"; start.jq leaves held cards out of the wait and the pull slots, a line each, and a Ready of nothing else ends the shift. On `main` after 0.16.0; scenario 57; check-start layers A and C.
- **15.4** Another clone's station building the same id was listed by its prompt as this clone's orphan, and a requeue TERMed it — read. The prompt counts only for a process whose cwd is this clone's worktree or checkout; the group — when the dead worker led it (16.1) — and the station pid name the rest. On `main` after 0.16.0; scenarios 54, 91; check-start layer C.
- **15.6** On Trello the shift read the newest 20 comments, compared another clock to its own, and spent six requests a session — read. Head reads page back to a head, 5 pages at most, and a card R17 would retry on a count its read did not settle is read further back (`aif_board_head_json`'s `<want>`, `_aif_start_deeper`) — two blocks 25 replies apart had read as one, and earned a third retry — a count still unsettled not retried, its line saying why; R16 counts from 120 s before the start (`AIF_START_FRESH_MARGIN_SECS`), a block in that margin said to be "around the shift's start"; a session's before-snapshot is the tick's facts, 3 requests a session. On `main` after 0.16.0; check-board, check-start layers A and T.
- **15.7** An idle loop that took a card twice wrote the second worker's log over the first — read; reproduced. One log per take, `<ID>.2.log` onward (`_aif_work_loop_take_log`), named in each `summary.json` results row and on the run's lines. On `main` after 0.16.0; scenario 57. Under a dotted ticket pattern that name is another ticket's: 16.11.
- **15.8** In this terminal a held build with Ready still holding cards ended the shift, though its line said `b` — read. It is a unit, *build again* (R13): its default is to leave it, Enter or `b` builds under its own key and lets the hold go; passed by, it is a line naming `aif work --loop --parallel N`, and the shift may end; behind a review, the line it was (lib/start.jq, `_aif_start_offer`, `_aif_start_run_build`). On `main` after 0.16.0; check-start layers A and C.
- **15.10** The loop's dashboard ended a closed window with 1, no `summary.json` and its lock left — probed (a pty, the dashboard on: 5 of 5 idle, 6 of 6 with a card held at plan; every card settled). bash runs a trap inside the redirections of the builtin it interrupts, and the dashboard spends its seconds in `read … </dev/tty 2>/dev/null`: the HUP handler's `exec >>loop.log 2>&1` was undone for fd 2 when the read put back its own, the next print hit the dead terminal (EIO, errexit, 1), and the bytes it could not write leaked from stdio's buffer into every `$(…)` after it — the summary's results, the lock's pid read against `$$` (docs/FINDINGS.md #28). The tick makes the redirection again once the read is done with its own, and the EXIT branch throws away what a failed print left before it captures anything (`_aif_work_loop_to_log`, lib/cmd_work.sh). 14.8's row ran `--no-tui`; a row of scenario 48 closes the master over the dashboard. Since 0.15.0; on `main` after 0.16.0.
- **15.11** A drain, a stop or a TERM that came while the loop read Ready was followed by one card more — probed (the read held open by a FIFO among the board's files). The drain had answered "takes no new card"; the TERM stopped every run and then started one no signal reached, which built on after its loop was gone. The stop and the files are looked at again, with builtins, before a card is taken, and a run started as a signal lands is sent it (lib/cmd_work.sh `_aif_work_loop`). The TERM half since before 0.15.0, the drain's since `--drain`; on `main` after 0.16.0; scenario 50.
- **15.12** On Trello the shift could not tell a build of a card's earlier text from one of its current text — read. The head read hashes the description as the pull writes it (`card_sha256`), and `_aif_work_status_json` holds the run's `ticket_sha256` against it as the local board holds `ticket.md`: a card edited after its build gets R8's line — "the card changed after this build — …" — instead of R7's review or R6's land, and `aif land` on Trello refuses such a card itself, exit 1, Review kept, `aif work <ID>` named, from the column read it makes anyway (`AIF_BOARD_CARD_SHA_TO`). On `main` after 0.16.0; check-start layers A and T.
- **15.13** A Ctrl-C that killed a `$(…)` child the loop assigned from ended the loop under `set -e` — probed while measuring 11.1: every unguarded per-second `x="$(…)"` was a window (2 of 120 dashboard trials). The clock is `SECONDS`, the run-lock directory is computed once, events guard their `$(…)`, and `aif_tui_ago` uses `printf -v` (lib/cmd_work.sh, lib/tui.sh). On `main` after 0.16.0; scenario 56.
- **15.14** `aif_gitignore_ensure` rewrote the whole block aif manages in `.gitignore` to its one worktrees line whenever that line was missing — probed: a block of five patterns left with one, `.aif/profile.local`, `.aif/tmp/`, `.aif/state/` and `.aif/board/` no longer ignored, in the developer's file, unasked. The line joins the block and the worker says so; a block with no end line is left alone with a warning (lib/merge.sh, lib/cmd_work.sh). On `main` after 0.16.0; scenario 59. Its exact matching, and `aif init`'s own write of a block with no end, are 16.10.
- **15.15** The dashboard's frame could still end a closed window with 1, the run TERMed and never waited for — probed (with every core busy, 1–4 failures in 15 on three commits, every time with the pty undrained). A frame that could not be written is no end (`_aif_work_loop_tick`): what stdio kept of it is thrown away, after a HUP the output goes to loop.log, and with no HUP yet the second is waited out. Since 0.15.0; on `main` after 0.16.0; scenario 48's frame-cut row. A terminal gone with no HUP is 16.12.
- *(15.5 and 15.9 are open, above.)*

### Log 16 — after 0.16.0, the fixes checked (2026-10-08/10)

Each fix of logs 11–15 was checked once it was committed, by a verifier that
had not built it, on snapshots of the commits: the defect reproduced on the
commit before its fix, gone on the fix's, and still gone on the latest. Most
held. What gave way — a fix in part (11.1, 15.5, 15.9, above), a hole a fix
opened, a regression, a rule read too loosely — is this log: 16.1–16.3 fixed
with it, 16.4–16.15 open above.

- **16.1** A process was taken for a dead worker's orphan by the group recorded in its lock whenever that group's leader was gone, though the worker had never led it — probed: a launcher running `aif work A & aif work B &` and exiting, then A killed, sent TERM to B's live worker and station, and B's card went to Needs Human. A group counts only when its id is the dead worker's own pid (`_aif_work_status_orphans`). On `main` after 0.16.0; scenario 91.
- **16.2** A taker looked for orphans and sent them TERM before it held the takeover, so a slow loser TERMed the winner's station — probed (lsof slowed 1–4 s: the winner's station TERMed in 9 of 12 races). Only the taker holding the mark looks, the lock read again before each round of TERMs; a `--stop` of a gone worker holds the mark too (`_aif_work_lock_take`, `_aif_work_lock_mark`): 0 of 12. On `main` after 0.16.0; scenario 92.
- **16.3** A station whose final `result` was `""` read as a runner that did not answer — three tries, then `blocked: environment` — probed (13.7's classifier: `"" | split("\n")[0]` is null, and the whole read failed). The first-line helper cannot fail: a success with an empty result is ok, an error is read by its fields (lib/runner_claude.sh). On `main` after 0.16.0; scenario 88.

### Log 10 — 0.11.0, the first `aif work --loop` after the upgrade (2026-10-02)

Four problems from a loop that built nothing: two tickets stopped at the plan
station on a criterion the tree already satisfied, and the two-runs rule
stopped the loop. None corrupts a build that reaches Review.

- **10.1** A long report was cut through a character, and the worker said it was posted — probed; the refusal observed. The cut counts UTF-16 units, as Trello does, and cuts on a character; "report posted" is said only when it was, with a command that can succeed otherwise (0.12.0; `check-board.sh`).
- **10.2** A ticket over 16 384 characters could not reach its Trello card, and the refusal gave no reason — observed; the checks read. The ready gate counts the ticket as Trello counts it on a Trello project and names how much to cut; `aif board create` refuses before sending, with the count and the limit; the analyst skill names the cap. On `main` after 0.12.0; `check-board.sh`.
- **10.3** A restarted run inherited the stopped plan's files — read; the leftover state observed. A run that did not build restarts on the tree it started from: the stopped plan's skeleton, its edits, its committed plan and tests are put back in a commit that says so, the ticket's record kept; a resumed plan station finds the branch as it is. A run that built is a rework and keeps its code. On `main` after 0.12.0; scenario 42.
- **10.4** The analyst was never told about the check that stopped both runs — observed; the skill read. `/aif-ba` asks of every criterion whether today's tree already passes it, names the shapes that slip through (a guard written as its own criterion: "still", "only", "absent", a count of 0 or 1, a value the code already returns) and the fold — one literal carrying both the guard and the change. On `main` after 0.12.0.
