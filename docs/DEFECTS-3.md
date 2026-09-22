# Defects — rebuild-3, found by review

Fourteen problems in the machine half, found by reading what 0.5.0 ships and
running the parts that can be run offline.

**Five are closed — 1, 2, 3, 6 and 14 — and they have moved to section D.**
Nine are open and keep their place in A, B and C. The numbers never move:
`lib/common.sh`, `lib/ledger.sh`, `lib/cmd_work.sh` and both gates cite them
from code comments, and a renumbered list would silently re-point every one of
those.

Found at `12830b1` on 2026-09-19, on macOS 26.5.2, bash 3.2.57, awk 20200816,
jq 1.7.1-apple, git 2.x, claude 2.1.226.

**Re-checked against 0.5.2 (`cd0eb03`) on 2026-09-22**, entry by entry, against
the code rather than against memory. Line citations below are 0.5.2's. Two
entries changed status in that pass: 14 closed, and 5 lost half of itself —
see its heading.

Every entry says how it was established:

- **probed** — reproduced on this machine, with the observation quoted;
- **read** — established from the code alone. Believable, not witnessed.

The three that produced the 0.5.0 fixes are in `FINDINGS.md` (17–19) instead:
those are established and closed. The eight from driving OPES-62 end to end are
in `DEFECTS-4.md`.

---

## A. The run

### 4. The budget cap reads the number that is structurally zero — read — **open**

[lib/cmd_work.sh:710] accumulates `spent` from the envelope's `total_cost_usd`
and [lib/cmd_work.sh:730] tests the cap against it. `FINDINGS` #2 — this
repository's own — records that `total_cost_usd` is 0 under subscription auth.
So on the auth most users have, the cap cannot fire.

Meanwhile [lib/cmd_work.sh:363] prices the same station from its token counts
and `prices.json`, and that number goes into the ledger and into the report's
Stations table. One report therefore carries two different amounts of money, and
the one guarding against a runaway run is the one that reads zero.

Unchanged in 0.5.2.

---

## B. Gates that render a false verdict

### 5. Coarse mode and the suite's exit code — read — **half closed, still open**

The entry as written was two defects in one sentence, and 0.5.2 closed one of
them.

**Closed:** the exit code was discarded with `|| true` and nothing read it.
Both gates now capture it as `suite_rc` ([green.sh:156],
[verify-red.sh:125]), and green's coarse branch rejects on a non-zero suite
([green.sh:304]). A red suite that does not print the magic words no longer
passes.

**Still open:** the grep is still there, and in the other direction it is still
wrong. [green.sh:304] is an `or`, so a suite that exits 0 while its output
mentions "error" anywhere — a test named `test_error_handling`, a captured log
line, `0 errors` from tsc or eslint — is rejected for ever, with a complaint no
station can act on:

```sh
if [ "$suite_rc" -ne 0 ] || grep -qiE 'fail|error' "$work/.suite.out"; then
```

`verify-red` did not change at all here. [verify-red.sh:262] still decides
"the suite appears green" by grepping for `passed|ok|0 failed` and the absence
of `fail|error`, while `suite_rc` sits unused three lines above it. Its
consequences are milder, because a red pytest run does print "failed".

The fix is now small and was not taken only because it was out of scope when
`suite_rc` arrived: with a trustworthy exit code in hand, both greps are
redundant and should go.

Reachable wherever python3 is missing: `aif doctor` only warns about it
([lib/doctor.sh:164]) and preflight fails the run only when no report appears at
all. What 0.5.2 did add is a reason — `mode_reason` in `tests.lock.json` and on
the gate's closing line — and a check that the project's own
`failure_classes.broken` are matched against the run's output before coarse red
is accepted (`DEFECTS-4.md` #2).

### 7. `_record` and `_commit` fail silently, and everything downstream leans on them — read — **open**

[lib/cmd_work.sh:737] and [lib/cmd_work.sh:744] both end in
`>/dev/null 2>&1 || true`. Both are load-bearing:

- `scope`'s baseline is the last commit ([scope.sh:98]). If `_commit` did not
  happen after the tests station, the diff still holds the test files and scope
  rejects the implementation for *"X is a test file — the implementation must not
  touch tests"*.
- `green`'s revert-recheck restores from that same commit's index
  ([green.sh:342]).
- If `_record` did not stamp `ticket_sha256` into `plan.md`, `verify-red` rejects
  with *"plan.md is bound to a different ticket — re-run the plan station"*, the
  station rewrites the same plan, and the loop repeats to the cap.

In each case a tool failure is reported to the human as the station's fault, at
opus prices.

Unchanged in 0.5.2. Worth reading beside `DEFECTS-4.md` #4, which is the same
shape one layer up: a station blamed for a defect it cannot reach.

### 8. `implement` has Bash, and one `git commit` from the station empties scope — read — **open**

`aif-implement` and `aif-implement-careful` still declare
`tools: Read, Grep, Glob, Write, Edit, Bash`. Models reach for `git commit -am`
by habit. After one, `git diff --name-only HEAD` ([scope.sh:98]) is empty: scope
passes everything and prints *"change confined to the plan (0 lines)"*.

`green` then catches it, but for the wrong reason and with the wrong words: the
revert-recheck checks out from an index that now holds the implementation, the
covering tests stay green, and the verdict is *"the tests do not depend on the
implementation"*. The station is told its tests are worthless when what actually
happened is that it committed.

`guard.sh` is honest that it cannot police Bash and names `scope` as the real
backstop. This is the case where the backstop is switched off by the thing it
was supposed to catch.

Unchanged in 0.5.2.

---

## C. Smaller, and risks

### 9. `aif_sha256` fails open where its gate twin fails loudly — read — **open**

[lib/paths.sh:172] returns `""` when neither `shasum` nor `sha256sum` is present;
[sets/claude/gates/_lib.sh:65] raises `ERROR` in the same situation. With an
empty hash, `aif_run_resumable` compares `"" = ""` and is always true, so the
one comparison that replaced the whole cascade — *the ticket's bytes changed
since intake* — silently answers "they did not", and the report says it built
against sha `''`.

Unchanged in 0.5.2.

### 10. Trello, CRLF, and `^<!-- aif:meta$` — read, not verified against the API — **open**

[lib/board.sh:271] requires the meta opener to be a line of its own, and the
design says a human editing the card is a legitimate author of the ticket's text
(REBUILD-3 §5). If the browser editor stores `\r\n`, the pull dies with *"the
card … has no aif:meta block in its description — it was not written by the
analyst"*, which sends the human to the wrong place. Cheap to make robust; worth
confirming against a real board first. The same anchor is in
[lib/common.sh:85] and in the gates' `aif_g_meta`.

Unchanged in 0.5.2.

### 11. `--no-worktree` puts `bypassPermissions` in the developer's checkout — read — **open**

[lib/runner_claude.sh:123] justifies `bypassPermissions` by the worktree being a
disposable copy, and [lib/runner_claude.sh:147] passes it unconditionally.
`--no-worktree` ([lib/cmd_work.sh:530]) removes the copy and keeps the flag. The
usage text says it is "only for a checkout that is already disposable (CI, a
test)" and nothing enforces that — not a clean tree, not a CI marker.

Unchanged in 0.5.2.

### 12. The local board orders by `date +%s` — read — **open**

[lib/board.sh:121], and the same at [lib/board.sh:151] where a card is created.
Two moves in the same second get the same `pos`, and `sort_by(.pos)` then picks
by whatever order the glob returned — so `aif board next-ready` stops being
deterministic exactly when the project manager is reordering the queue quickly.

Unchanged in 0.5.2.

### 13. A resumed run reports "no code changed" — read — **open**

Intake resets `.base` to the current HEAD ([lib/cmd_work.sh:251]), so the
report's diffstat ([lib/cmd_work.sh:418]) describes this invocation rather than
the ticket. A run that resumes at `done` reports `no code changed` for a ticket
whose work is all on the branch.

Unchanged in 0.5.2.

---

## D. Closed

Kept in full rather than deleted: each says what the defect was, so that the fix
below it can be read as an answer to something. They are closed in `main` *and*
released — 1, 2, 3 and 6 in 0.5.1, 14 in 0.5.2 — which for this tool is the only
claim worth making. A tag the tap does not serve is a fix nobody has.

### 1. `aif_ledger_append` silently removes the worker's interrupt trap — probed

`aif work` installs a trap so that an interrupted run puts its card back in
`needs_human` rather than leaving it claiming that work is happening. Thirteen
lines later the run reaches intake, intake records the `ready` verdict, and
`aif_ledger_append` set its own trap for the lock directory and then cleared it:

```sh
trap - EXIT INT TERM        # lib/ledger.sh, before the fix
```

Traps are per-process, not per-function. That line took the worker's trap with
it, and the worker never reinstalled it. From intake to the end of the loop —
the whole expensive part of the run — the interrupt protection was off.

```
control, no ledger append:  WORKER TRAP fired / survived the signal / exit=0
after one ledger append:    exit=130, no handler, no card moved
```

The comment above that line said "No other trap exists in this codebase, so
clearing it below cannot clobber someone else's". It was true when it was
written (`1806bbe`) and stopped being true when the worker's trap arrived
(`097627e`) — which means that trap had never protected the loop it was written
for, and the live run it was written after would have failed the same way.

Cost: Ctrl-C left the card in In Progress for good — the exact defect the trap
was written to prevent, and the one the code calls "the same defect as a meter
that quietly did not fire".

**Fixed** (0.5.1). `aif_trap_arm` / `aif_trap_restore` in [lib/common.sh:40]:
the ledger's lock appends the caller's handler to its own trap and puts it back
on the way out ([lib/ledger.sh:90]) instead of clearing the slate.
`scripts/check-work.sh` asserts that a ledger write leaves an armed handler in
place. Verified still in force at 0.5.2.

### 2. The trap does not stop the run even when it fires — probed

The handler moved the card and printed `interrupted — … moved to needs_human`,
and did not exit. A bash trap handler returns to where the signal arrived, so
the loop kept going. Probed with a stand-in loop: three signals, three
"interrupted" lines, and the loop still ran to completion.

An interactive Ctrl-C hid this — the signal reaches the whole foreground group,
`claude -p` dies with it, the dispatch returns no envelope and the loop breaks —
but it broke through the wrong door, reporting "the runner could not run the
station — the environment, not the ticket".

A `kill -TERM` from a supervisor, a timeout or a cancelled CI job reaches only
`aif`: the card moved to `needs_human`, the message said the run was
interrupted, and the run carried on spending the budget it was told to stop
spending.

**Fixed** (0.5.1). The handler is `_aif_work_abandon` ([lib/cmd_work.sh:92]),
it is idempotent, and where it acts it exits 1 — a run nobody finished is
"stopped, needs a human", which is what 1 means here. Verified still in force at
0.5.2.

### 3. Nothing puts the card back on any other exit — read

The card moved to In Progress and there was no `EXIT` trap anywhere in the
worker. Every `aif_die` after that point left it there — the worktree that could
not be made, the ready gate that was not installed, the `cd` into the worktree —
and, more often, any failure under `set -e` inside the loop.

That last one was not hypothetical. The decimal-comma defect (`FINDINGS` #18)
produced exactly this shape: `run.json` left saying `"status": "running"`,
`"stage": "plan"`, and a card sitting in In Progress with nobody working on it.

**Fixed** (0.5.1). `aif_trap_arm` covers `EXIT` as well as `INT`/`TERM`
([lib/cmd_work.sh:595]), and the handler stays armed through the report — a
failure while writing the report is exactly the case where the card must not be
left claiming the work is under way. Scenario 7 of `scripts/check-work.sh`
forces a die on the far side of the move and asserts the card came back.
Verified still in force at 0.5.2.

### 6. `grep -qF "$expect"` without `--` — probed

`verify-red` greps each test file for the criterion's expected literal. An
`expect` that starts with a dash became an option:

```
grep -qF "-1" t.py    → rc=1   (the file contains -1)
grep -qF -- "-1" t.py → rc=0
```

So a criterion whose expected value was `-1`, `--force`, or any negative number
passed the ready gate and was then rejected by `verify-red` with *"expected
value (-1) does not appear in any test"* — about a test where it plainly did.
The station could not fix it: it burned `attempts_max` opus runs and stopped the
ticket.

**Fixed** (0.5.1). `grep -qF --` on both greps in that block
([verify-red.sh:281] and [verify-red.sh:299]). The offline harness asks for an
`expect` of `-1` and has the test station write that literal into the test it
authors, so removing the `--` again fails the first scenario. Verified still in
force at 0.5.2.

### 14. `.suite.out` survives the reject paths — read

`green` and `verify-red` both write `$work/.suite.out` and removed it only where
they passed. On a rejection it stayed under `tasks/<ID>/` and the report's
`git add -A` committed it — and a rejection is the common case, so the removals
were written for the rarer one.

**Fixed** (0.5.2). Both gates arm `trap 'rm -f "$work/.suite.out"' EXIT` the
moment the file is written ([green.sh:153], [verify-red.sh:122]). A gate is its
own process, so that is the whole fix, and unlike the per-site removals it
covers every exit — including the two `ERROR` paths `DEFECTS-4.md` added.

---

## What was checked and found sound

Recorded so the next reader does not spend the time again:

- the revert-recheck's copy **does** work inside a linked worktree — `git -C` on
  a copied `.git` *file* resolves the worktree to the copy, reverts there, and
  leaves the live checkout alone (probed);
- `--tools "A,B,C"` is the correct spelling for `claude 2.1.226` (probed against
  `claude --help`);
- no `local v=$(cmd)` anywhere in the tree — the bash 3.2 rule in `FINDINGS` is
  kept;
- `_amend-plan`'s escape hatch cannot be walked around with `./` or `..`: the
  denylist in `scope` compares against git's own normalised spelling, so a
  cleverly spelled amendment simply fails to match and the path is rejected
  anyway.
