# Defects — rebuild-3, found by review

Fourteen problems in the machine half, found by reading what 0.5.0 ships and
running the parts that can be run offline.

**All fourteen are closed** — 1, 2, 3 and 6 in 0.5.1, 14 in 0.5.2, and the
remaining nine (4, 5, 7, 8, 9, 10, 11, 12, 13) in 0.5.3. Closed in `main` *and*
released, which for this tool is the only claim worth making: a tag the tap
does not serve is a fix nobody has.

The numbers never move. `lib/common.sh`, `lib/ledger.sh`, `lib/cmd_work.sh`,
`lib/paths.sh`, `lib/board.sh`, `lib/cmd_gate.sh`, `lib/cmd_record.sh`, the
guard hook and every gate cite them from code comments, and a renumbered list
would silently re-point each of those.

Found at `12830b1` on 2026-09-19, on macOS 26.5.2, bash 3.2.57, awk 20200816,
jq 1.7.1-apple, git 2.x, claude 2.1.226. Re-checked against 0.5.2 (`cd0eb03`)
on 2026-09-22, entry by entry; the last nine closed the same day, in 0.5.3.
Line citations below are 0.5.3's.

Every entry says how it was established:

- **probed** — reproduced on this machine, with the observation quoted;
- **read** — established from the code alone. Believable, not witnessed.

The three that produced the 0.5.0 fixes are in `FINDINGS.md` (17–19) instead:
those are established and closed. The eight from driving OPES-62 end to end are
in `DEFECTS-4.md`, and three of those stay open there for reasons that are not
"nobody got to it yet".

---

## Open

None.

---

## Closed

Kept in full rather than deleted: each says what the defect was, so that the
fix below it can be read as an answer to something. In numerical order, since
that is how the code cites them.

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
place.

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
"stopped, needs a human", which is what 1 means here.

### 3. Nothing puts the card back on any other exit — read

The card moved to In Progress and there was no `EXIT` trap anywhere in the
worker. Every `aif_die` after that point left it there — the worktree that could
not be made, the ready gate that was not installed, the `cd` into the worktree —
and, more often, any failure under `set -e` inside the loop.

That last one was not hypothetical. The decimal-comma defect (`FINDINGS` #18)
produced exactly this shape: `run.json` left saying `"status": "running"`,
`"stage": "plan"`, and a card sitting in In Progress with nobody working on it.

**Fixed** (0.5.1). `aif_trap_arm` covers `EXIT` as well as `INT`/`TERM`, and
the handler stays armed through the report — a failure while writing the
report is exactly the case where the card must not be left claiming the work
is under way. Scenario 7 of `scripts/check-work.sh` forces a die on the far
side of the move and asserts the card came back.

### 4. The budget cap reads the number that is structurally zero — read

The loop accumulated `spent` from the envelope's `total_cost_usd` and tested
the cap against it. `FINDINGS` #2 — this repository's own — records that
`total_cost_usd` is 0 under subscription auth. So on the auth most users have,
the cap could not fire.

Meanwhile the same station was priced from its token counts and `prices.json`,
and that number went into the ledger and into the report's Stations table. One
report therefore carried two different amounts of money, and the one guarding
against a runaway run was the one that read zero.

**Fixed** (0.5.3). `_aif_work_envelope_cost` ([lib/cmd_work.sh:396]) prices
each envelope's tokens from `.aif/prices.json` exactly as the ledger row does
and takes the larger of that and the runner's own figure; the cap
([lib/cmd_work.sh:776]) reads the sum of those. A model the table does not know
contributes the runner's number alone, and its ledger row says `tokens-only`.
Scenario 11 of `check-work.sh`: every envelope reports $0, the fake model is
priced, `--budget 0.05` — the run stops on `budget:`, `spent_usd` is above
zero, and the ledger row is `priced`.

### 5. Coarse mode and the suite's exit code — read

Two defects in one sentence. The suite's status was discarded with `|| true`,
and the fallback — under a comment that said *"Coarse: exit code only"* —
grepped the suite's stdout:

```sh
if grep -qiE 'fail|error' "$work/.suite.out"; then
```

Both directions were wrong. A green suite whose output mentioned "error"
anywhere — a test named `test_error_handling`, a captured log line, `0 errors`
from tsc or eslint — was rejected for ever, with a complaint no station could
act on. A red suite that did not print those words passed. `verify-red` had the
same pair, deciding "the suite appears green" by grepping for `passed|ok|0
failed` and the absence of `fail|error`; its consequences were milder, because
a red pytest run does print "failed".

0.5.2 closed half of it by accident: the report cross-check gave both gates a
real `suite_rc`, and green's coarse branch started reading it — but ORed the
grep in beside it, so the false-rejection direction survived, and verify-red
did not change at all.

**Fixed** (0.5.3). Both greps are gone. Green's coarse branch rejects on the
exit code alone ([green.sh:308]); verify-red calls it "no observable red" only
when the suite exited 0 ([verify-red.sh:268]). Reachable wherever python3 is
missing, still — `aif doctor` warns about that and preflight fails only when
no report appears at all — and the reason a gate went coarse is now recorded
as `mode_reason` (`DEFECTS-4.md` #2), which is the instrument for it.

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

**Fixed** (0.5.1). `grep -qF --` on both greps in that block. The offline
harness asks for an `expect` of `-1` and has the test station write that
literal into the test it authors, so removing the `--` again fails the first
scenario.

### 7. `_record` and `_commit` fail silently, and everything downstream leans on them — read

Both calls in the worker ended in `>/dev/null 2>&1 || true`, and `_commit`
itself swallowed `git add` and `git commit` and printed "committed" either way.
Both are load-bearing:

- `scope`'s baseline is the last commit. If `_commit` did not happen after the
  tests station, the diff still held the test files and scope rejected the
  implementation for *"X is a test file — the implementation must not touch
  tests"*.
- `green`'s revert-recheck restored from that same commit.
- If `_record` did not stamp `ticket_sha256` into `plan.md`, `verify-red`
  rejected with *"plan.md is bound to a different ticket — re-run the plan
  station"*, the station rewrote the same plan, and the loop repeated to the
  cap.

In each case a tool failure was reported to the human as the station's fault,
at opus prices.

**Fixed** (0.5.3). The worker captures both: a failed `_record`
([lib/cmd_work.sh:788]) or `_commit` ([lib/cmd_work.sh:804]) stops the run with
the tool's own output under "the tool, not the station". `_commit` no longer
swallows git ([lib/cmd_gate.sh:293], [lib/cmd_gate.sh:308]). One deliberate
softening the other way: `_record` returns 0 quietly on an artifact with no
usable meta block ([lib/cmd_record.sh:69]) — that is the station's defect and
the gate's to report as a rejection the next attempt can fix, and dying there
would have turned a retry into a stopped run.

### 8. `implement` has Bash, and one `git commit` from the station empties scope — read

`aif-implement` and `aif-implement-careful` declare
`tools: Read, Grep, Glob, Write, Edit, Bash`. Models reach for `git commit -am`
by habit. After one, `git diff --name-only HEAD` was empty: scope passed
everything and printed *"change confined to the plan (0 lines)"*.

`green` then caught it, but for the wrong reason and with the wrong words: the
revert-recheck checked out from an index that now held the implementation, the
covering tests stayed green, and the verdict was *"the tests do not depend on
the implementation"*. The station was told its tests were worthless when what
actually happened was that it committed.

`guard.sh` was honest that it could not police Bash and named `scope` as the
real backstop. This was the case where the backstop was switched off by the
thing it was supposed to catch.

**Fixed** (0.5.3), in three layers, of which the first is the fix and the other
two are named for what they are.

The worker records HEAD as `dispatch_base` in the run record before every
dispatch ([lib/cmd_work.sh:737]), and `aif_g_dispatch_base` ([_lib.sh:168])
hands it to the gates, with HEAD as the fallback for a gate run by hand. scope
diffs and counts against it ([scope.sh:106], [scope.sh:167]) and says on its
pass path when HEAD moved under the station ([scope.sh:184]). green reverts from
it ([green.sh:353]) and then *proves* the revert, file by file, against the
hashes verify-red froze — a revert that did not happen is now an ERROR that
names the cause ([green.sh:376]), not a verdict against the tests.

The guard hook is matched on Bash as well now
([settings.fragment.json:5] — an existing project picks that up on its next
`aif init`) and refuses the obvious `git commit|reset|stash|…` spellings from a
station, saying whose job committing is ([guard.sh:62]). A speed bump: it fails
open on a subshell or a backtick by design, and stands in front of a fix that
no longer needs it.

Scenario 10 of `check-work.sh`: a station that commits its own work is built,
scope reports "(2 lines)", green's recheck holds, and the run record carries
the baseline. Then, by hand, the same tree with the record removed — the old
behaviour — reports "(0 lines)".

### 9. `aif_sha256` fails open where its gate twin fails loudly — read

`aif_sha256` returned `""` when neither `shasum` nor `sha256sum` was present;
`aif_g_sha256` in the gates raised `ERROR` in the same situation. With an
empty hash, `aif_run_resumable` compared `"" = ""` and was always true, so the
one comparison that replaced the whole cascade — *the ticket's bytes changed
since intake* — silently answered "they did not", and the report said it built
against sha `''`.

**Fixed** (0.5.3). `aif_require_sha256` ([lib/paths.sh:180]) runs from
`bin/aif` before any command that touches a project ([bin/aif:105]), and the
two hashing functions die instead of printing nothing ([lib/paths.sh:187]) for
the path that check somehow missed.

### 10. Trello, CRLF, and `^<!-- aif:meta$` — read, not verified against the API

The pull required the meta opener to be a line of its own, and the design says
a human editing the card is a legitimate author of the ticket's text
(REBUILD-3 §5). If the browser editor stored `\r\n`, the pull died with *"the
card … has no aif:meta block in its description — it was not written by the
analyst"*, which sent the human to the wrong place.

**Fixed** (0.5.3). The pull strips CR at the source ([lib/board.sh:296]) — the
file it writes is the bytes the run hashes and the bytes `board create` pushes
back, LF, so a round trip changes nothing — and both meta parsers strip it
before matching ([lib/common.sh:87], [_lib.sh:90]), kept identical as the
comment on each demands. Scenario 13 feeds a CRLF file to both. Still not
verified against a live board; the fix is robust to either answer.

### 11. `--no-worktree` puts `bypassPermissions` in the developer's checkout — read

`lib/runner_claude.sh` justifies `bypassPermissions` by the worktree being a
disposable copy, and passes it unconditionally. `--no-worktree` removed the
copy and kept the flag. The usage text said it was "only for a checkout that
is already disposable (CI, a test)" and nothing enforced that — not a clean
tree, not a CI marker.

**Fixed** (0.5.3). `--no-worktree` is refused unless `CI` is set or
`AIF_DISPOSABLE=1` is ([lib/cmd_work.sh:580]); the usage text and the README say
so, and both harnesses declare their sandboxes. Scenario 12: refused with the
message and nothing run; allowed under `CI=1`.

### 12. The local board orders by `date +%s` — read

A plain move set `pos` to the clock, and so did create. Two moves in the same
second got the same `pos`, and `sort_by(.pos)` then picked by whatever order
the glob returned — so `aif board next-ready` stopped being deterministic
exactly when the project manager was reordering the queue quickly.

**Fixed** (0.5.3). `_aif_board_local_pos` ([lib/board.sh:124]): a plain move
goes strictly below every card, `--top` strictly above, and create uses the
same. `check-board.sh` makes three moves inside one second and asserts the
order, then that every pos is distinct. The fix itself hit a trap worth a
line: handed a glob that matched nothing, `jq -s` prints its result over the
empty slurp *and* exits non-zero, so a `|| printf 1` fallback produced `11`
and the first card on a fresh board was created with `--argjson p 11`.

### 13. A resumed run reports "no code changed" — read

Intake reset `.base` to the current HEAD on every invocation, so the report's
diffstat described that invocation rather than the ticket. A run that resumed
at `done` reported `no code changed` for a ticket whose work was all on the
branch.

**Fixed** (0.5.3). A resume keeps the base the run started from
([lib/cmd_work.sh:259]); only a record from before the field existed is given
one. Scenario 6: the resume-at-done report no longer says "no code changed".

### 14. `.suite.out` survives the reject paths — read

`green` and `verify-red` both write `$work/.suite.out` and removed it only where
they passed. On a rejection it stayed under `tasks/<ID>/` and the report's
`git add -A` committed it — and a rejection is the common case, so the removals
were written for the rarer one.

**Fixed** (0.5.2). Both gates arm `trap 'rm -f "$work/.suite.out"' EXIT` the
moment the file is written. A gate is its own process, so that is the whole
fix, and unlike the per-site removals it covers every exit — including the
`ERROR` paths `DEFECTS-4.md` added.

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
