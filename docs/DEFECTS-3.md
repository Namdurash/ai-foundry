# Defects — rebuild-3, found by review

Fourteen problems in the machine half, found by reading what 0.5.0 ships and
running the parts that can be run offline. **None of them is fixed here.** This
file is the list; the order is roughly the order to fix them in.

Reviewed at `12830b1` on 2026-09-19, on macOS 26.5.2, bash 3.2.57, awk 20200816,
jq 1.7.1-apple, git 2.x, claude 2.1.226. Every entry says how it was
established:

- **probed** — reproduced on this machine, with the observation quoted;
- **read** — established from the code alone. Believable, not witnessed.

The three that produced the 0.5.0 fixes are in `FINDINGS.md` (17–19) instead:
those are established and closed. What is here is open.

---

## A. The run

### 1. `aif_ledger_append` silently removes the worker's interrupt trap — probed

`aif work` installs a trap at [lib/cmd_work.sh:556] so that an interrupted run
puts its card back in `needs_human` rather than leaving it claiming that work is
happening. Thirteen lines later the run reaches intake, intake records the
`ready` verdict ([lib/cmd_work.sh:208]), and `aif_ledger_append` sets its own
trap for the lock directory ([lib/ledger.sh:70]) and then clears it:

```sh
trap - EXIT INT TERM        # lib/ledger.sh:88
```

Traps are per-process, not per-function. That line takes the worker's trap with
it, and the worker never reinstalls it. From intake to the end of the loop —
the whole expensive part of the run — the interrupt protection is off.

```
control, no ledger append:  WORKER TRAP fired / survived the signal / exit=0
after one ledger append:    exit=130, no handler, no card moved
```

The comment above that line says "No other trap exists in this codebase, so
clearing it below cannot clobber someone else's". It was true when it was
written (`1806bbe`) and stopped being true when the worker's trap arrived
(`097627e`) — which means that trap has never protected the loop it was written
for, and the live run it was written after would fail the same way today.

Cost: Ctrl-C leaves the card in In Progress for good — the exact defect the trap
was written to prevent, and the one the code calls "the same defect as a meter
that quietly did not fire".

### 2. The trap does not stop the run even when it fires — probed

[lib/cmd_work.sh:556-558] moves the card and prints `interrupted — … moved to
needs_human`, and does not exit. A bash trap handler returns to where the signal
arrived, so the loop keeps going. Probed with a stand-in loop: three signals,
three "interrupted" lines, and the loop still ran to completion.

An interactive Ctrl-C hides this — the signal reaches the whole foreground group,
`claude -p` dies with it, the dispatch returns no envelope and the loop breaks —
but it breaks through the wrong door, reporting "the runner could not run the
station — the environment, not the ticket".

A `kill -TERM` from a supervisor, a timeout or a cancelled CI job reaches only
`aif`: the card moves to `needs_human`, the message says the run was interrupted,
and the run carries on spending the budget it was told to stop spending.

### 3. Nothing puts the card back on any other exit — read

The card moves to In Progress at [lib/cmd_work.sh:545] and there is no `EXIT`
trap anywhere in the worker. Every `aif_die` after that point leaves it there:
[:157] and [:160] (the worktree could not be made), [:207] (the ready gate is not
installed), [:610] (`cd` into the worktree) — and, more often, any failure under
`set -e` inside the loop.

That last one is not hypothetical. The decimal-comma defect (`FINDINGS` #18)
produced exactly this shape: `run.json` left saying `"status": "running"`,
`"stage": "plan"`, and a card sitting in In Progress with nobody working on it.

### 4. The budget cap reads the number that is structurally zero — read

[lib/cmd_work.sh:671] accumulates `spent` from the envelope's `total_cost_usd`
and [lib/cmd_work.sh:679] tests the cap against it. `FINDINGS` #2 — this
repository's own — records that `total_cost_usd` is 0 under subscription auth.
So on the auth most users have, the cap cannot fire.

Meanwhile [lib/cmd_work.sh:339] prices the same station from its token counts
and `prices.json`, and that number goes into the ledger and into the report's
Stations table. One report therefore carries two different amounts of money, and
the one guarding against a runaway run is the one that reads zero.

---

## B. Gates that render a false verdict

### 5. `green`'s coarse mode never looks at the exit code — read

[sets/claude/gates/green.sh:135] discards the suite's status with `|| true`, and
the fallback at [green.sh:179-182], under a comment that says *"Coarse: exit code
only"*, greps the suite's stdout:

```sh
if grep -qiE 'fail|error' "$work/.suite.out"; then
```

Both directions are wrong. A green suite whose output mentions "error" anywhere
— a test named `test_error_handling`, a captured log line, `0 errors` from tsc or
eslint — is rejected for ever, with a complaint no station can act on. A red
suite that does not print those words passes.

Reachable wherever python3 is missing: `aif doctor` only warns about it
([lib/doctor.sh:160]) and preflight fails the run only when no report appears at
all. `verify-red` has the same pair at [verify-red.sh:204]; its consequences are
milder, because a red pytest run does print "failed".

### 6. `grep -qF "$expect"` without `--` — probed

[sets/claude/gates/verify-red.sh:235] greps each test file for the criterion's
expected literal. An `expect` that starts with a dash becomes an option:

```
grep -qF "-1" t.py    → rc=1   (the file contains -1)
grep -qF -- "-1" t.py → rc=0
```

So a criterion whose expected value is `-1`, `--force`, or any negative number
passes the ready gate and is then rejected by `verify-red` with *"expected value
(-1) does not appear in any test"* — about a test where it plainly does. The
station cannot fix it: it burns `attempts_max` opus runs and stops the ticket.

### 7. `_record` and `_commit` fail silently, and everything downstream leans on them — read

[lib/cmd_work.sh:686] and [lib/cmd_work.sh:693] both end in
`>/dev/null 2>&1 || true`. Both are load-bearing:

- `scope`'s baseline is the last commit ([scope.sh:98]). If `_commit` did not
  happen after the tests station, the diff still holds the test files and scope
  rejects the implementation for *"X is a test file — the implementation must not
  touch tests"*.
- `green`'s revert-recheck restores from that same commit's index
  ([green.sh:199]).
- If `_record` did not stamp `ticket_sha256` into `plan.md`, `verify-red` rejects
  with *"plan.md is bound to a different ticket — re-run the plan station"*, the
  station rewrites the same plan, and the loop repeats to the cap.

In each case a tool failure is reported to the human as the station's fault, at
opus prices.

### 8. `implement` has Bash, and one `git commit` from the station empties scope — read

`aif-implement` and `aif-implement-careful` declare
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

---

## C. Smaller, and risks

### 9. `aif_sha256` fails open where its gate twin fails loudly — read

[lib/paths.sh:161] returns `""` when neither `shasum` nor `sha256sum` is present;
[sets/claude/gates/_lib.sh:71] raises `ERROR` in the same situation. With an
empty hash, `aif_run_resumable` compares `"" = ""` and is always true, so the
one comparison that replaced the whole cascade — *the ticket's bytes changed
since intake* — silently answers "they did not", and the report says it built
against sha `''`.

### 10. Trello, CRLF, and `^<!-- aif:meta$` — read, not verified against the API

[lib/board.sh:271] requires the meta opener to be a line of its own, and the
design says a human editing the card is a legitimate author of the ticket's text
(REBUILD-3 §5). If the browser editor stores `\r\n`, the pull dies with *"the
card … has no aif:meta block in its description — it was not written by the
analyst"*, which sends the human to the wrong place. Cheap to make robust; worth
confirming against a real board first.

### 11. `--no-worktree` puts `bypassPermissions` in the developer's checkout — read

[lib/runner_claude.sh:123] justifies `bypassPermissions` by the worktree being a
disposable copy. `--no-worktree` removes the copy and keeps the flag. The usage
text says it is "only for a checkout that is already disposable (CI, a test)" and
nothing enforces that — not a clean tree, not a CI marker.

### 12. The local board orders by `date +%s` — read

[lib/board.sh:121]. Two moves in the same second get the same `pos`, and
`sort_by(.pos)` then picks by whatever order the glob returned — so
`aif board next-ready` stops being deterministic exactly when the project manager
is reordering the queue quickly.

### 13. A resumed run reports "no code changed" — read

Intake resets `.base` to the current HEAD ([lib/cmd_work.sh:227]), so the report's
diffstat describes this invocation rather than the ticket. A run that resumes at
`done` reports `no code changed` for a ticket whose work is all on the branch.

### 14. `.suite.out` survives the reject paths — read

`green` and `verify-red` both write `$work/.suite.out` and remove it only where
they pass. On a rejection it stays under `tasks/<ID>/` and the report's
`git add -A` commits it.

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
