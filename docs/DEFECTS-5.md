# Defects — 0.5.4, found writing one ticket

Two problems, same shape, found while putting `OPES-68` through `/aif-ba` and
`aif work` on a React Native / TypeScript project with a Trello board. The
ticket was written with `/aif-ba`, passed `aif _ready` (15 criteria, 10 decided,
3 gaps), and `aif board create` put it on the board correctly. The build then
refused to start: the worker could not find the card it had just written.

Worked against `9e1a8b9` (0.5.4) on 2026-09-23, macOS 26.6.2 (Darwin 25.6.0),
bash 3.2.57, jq 1.8.2, curl 8.7.1. Both entries are **probed** — reproduced
here, with the observation quoted.

The common cause is one idiom: a pipeline ending in a short-circuiting reader
(`grep -q`, `head -1`) under `set -o pipefail`. The reader exits at the first
line, the writer upstream takes SIGPIPE, and `pipefail` promotes 141 to the
pipeline's status — which the caller then reads as "no match" rather than
"match found early".

**All three are closed in 0.5.5** — the two reported, and a third that is the
sweep the reporter asked for under "Where else to look", done against the
whole tree on 2026-09-24. Line citations are 0.5.5's. `FINDINGS.md` #19 had
said the idiom's other uses in this tree were all of the harmless kind; it was
wrong twice, and it now says what the sweep established instead.

---

## Open

None.

---

## Closed

### 1. A Trello card whose description is long enough becomes invisible to the worker — probed

`_aif_trello_find_card` tested for a match by piping jq into `grep -q .`:

```sh
printf '%s' "$out" | jq -e --arg id "$id" \
  '[ .[] | select(.name | test("^" + $id + "([^A-Za-z0-9-]|$)")) ] | .[0] // empty' 2>/dev/null |
  grep -q . || return 1
```

`grep -q` exits at the first line it matches — which, since this jq is not `-c`,
is the opening `{`. jq is still writing the rest of the card object, and that
object carries the card's **entire description**: under this foundry the
description *is* the ticket file, `aif:meta` block and all. jq takes SIGPIPE and
dies 141; `set -o pipefail` (bin/aif:11) makes 141 the pipeline's status;
`|| return 1` reports the card as absent.

Everything that resolves a card by id goes through here via
`_aif_trello_require_card`: `show`, `move`, `comment`, `label`, and `pull`.

#### Observed

Four cards on the same board, same `aif board show` invocation, five runs:

```
run 1: 43=ok 67=ok 68=LOST 69=LOST
run 2: 43=ok 67=ok 68=LOST 69=LOST
run 3: 43=ok 67=ok 68=LOST 69=LOST
run 4: 43=ok 67=ok 68=LOST 69=LOST
run 5: 43=ok 67=ok 68=LOST 69=LOST
```

Calling `_aif_trello_find_card` directly, with the size of what jq writes:

```
OPES-43   rc=0   bytes=3427
OPES-67   rc=0   bytes=12299
OPES-68   rc=1   bytes=0        (jq#1 produced 20046 bytes, pipeline rc=141)
OPES-69   rc=1   bytes=0        (jq#1 produced 19407 bytes, pipeline rc=141)
```

The card itself is fine — name, list and description all correct on the board,
and `GET /boards/{id}/cards` returns all 35 cards (179 249 bytes) including the
two lost ones. The same jq filter, run against that same payload, matches all
four ids. Only the piped test fails.

The two cards that are lost are the only two tickets on this board written by
`/aif-ba`; the rest predate it and are short. `aif board status` is unaffected
because it does not request `desc`, which is why the board still *lists* a card
the worker then cannot find:

```
ready  OPES-68  картка Monobank після відключення     # status sees it
error: no card named OPES-68 on the Trello board      # show/move do not
```

#### What it costs

`aif work OPES-68` cut its worktree, ran `npm ci`, then died at intake:

```
error: no card named OPES-68 on the Trello board — create it: aif board create tasks/OPES-68/ticket.md
error: Trello: could not move OPES-68 — curl: (56) The requested URL returned error: 404
error: could not move OPES-68 to In Progress on the board — nothing was spent.
[exited with code 3]
```

Nothing was spent, and the failure is loud — but the message sends the user to
`aif board create`, which is the one thing that will not help: the card exists,
and re-creating it writes the same long description again. A ticket rich enough
to build headless is exactly the ticket that cannot be built.

#### Honest limit on the diagnosis

The mechanism is certain (rc=141 is SIGPIPE, and removing the pipe removes the
failure). The **boundary** is not a documented byte count: the same payload read
from a file instead of from the `printf '%s' "$out" |` pipe did not fail in 30
consecutive runs, and a synthetic single-line description did not fail at any
size up to 32 KiB. Whether a given card survives depends on how jq's writes
interleave with grep's exit. On this board, through the real binary, it is
deterministic — but it should be read as "any sufficiently large card, and no
reliable threshold to stay under" rather than "cards over N bytes".

**Fixed** (0.5.5). Captured once and tested as a variable
([lib/board.sh:258]) — one `jq -c`, no second pass over the same 179 KB, no
reader that leaves early. Reproduced first, outside the tree: a two-card
payload with a 76 KiB pretty-printed card lost 5 of 5 lookups through the old
pipeline (rc 141) and none through the new one. `scripts/check-board.sh`
([scripts/check-board.sh:276]) now creates a card from a 76 KiB ticket on the
stand-in server, confirms the whole description landed, and resolves it with
`show` and `move`. The single-line result the reporter saw up to 32 KiB has a
name: `grep -q .` needs a line to match, and a single line is read to its end.

The second line of that error — `could not move OPES-68 — 404` — was a
different defect and is closed with it. The five callers of
`_aif_trello_require_card` assigned it inside `$(…)` and relied on `set -e` to
stop when it died; `set -e` is off inside any `if`, including the worker's
`if ! (aif_board_move …)`, so `move` carried on with an empty card and PUT to
`/cards/null`. Each now follows with `|| return 1` ([lib/board.sh:277]), which
behaves the same whether or not `-e` is on.

### 2. Project detection misses a Python project with many test files — probed

`_aif_detect_runner` (lib/cmd_project.sh) had the same shape, with `head -1` as
the short-circuiting reader:

```sh
elif [ -d "$root/tests" ] &&
  find "$root/tests" -name '*.py' -print 2>/dev/null | head -1 | grep -q .; then
  printf 'pytest'
```

`head -1` exits after one line; `find`, still walking the tree, takes SIGPIPE;
`pipefail` makes the pipeline 141; the `elif` reads that as false and detection
falls through to `printf ''`.

#### Observed

The same pipeline against `tests/` directories of increasing size:

```
      1 .py files → elif exit 0    detected as pytest
      5 .py files → elif exit 0    detected as pytest
     50 .py files → elif exit 0    detected as pytest
    500 .py files → elif exit 0    detected as pytest
   5000 .py files → elif exit 141  NOT detected — falls through to ""
```

Smaller than #1 in blast radius — it needs a large `tests/` tree, and only
matters for a project with no `pyproject.toml`, `pytest.ini`, `setup.cfg` or
`conftest.py`, since those are checked first. But the failure is silent: the
project is simply reported as having no test kind.

**Fixed** (0.5.5). The pipeline moved inside a substitution, where its status
is not what the condition reads: `[ -n "$(find … | head -1)" ]`
([lib/cmd_project.sh:49]). Reproduced first at 5000 files (rc 141, then
detected), and held by scenario 16 of `scripts/check-work.sh`
([scripts/check-work.sh:683]): 5000 test files, no config file, `aif project
init` says pytest.

### 3. The same shape, everywhere else — the sweep — probed

Every pipeline in the tree that ends in a reader which can leave early — `head
-N`, `grep -q`, `grep -m N`, `grep -l`, `read`, `sed … q`, `awk … exit` — was
listed (46 sites) and classified by two questions: is the pipeline's status
*tested* (`if`, `elif`, `&&`, `||`), and can the producer outgrow a pipe
buffer? A third question the reporter's entry did not raise turned out to
matter as much: **is it a plain assignment under `set -e`?** `bin/aif` runs
under `set -euo pipefail`, and `x="$(cmd | head -1)"` at statement level makes
the substitution's 141 the assignment's status — the program exits, silently,
at the one line that looked like it could not fail.

Nine sites were both. In order of what they would have cost:

- [lib/doctor.sh:209] — the `.aif/worktrees/` collision check (DEFECTS-4 #8)
  grepped the suite's whole output with `-q`. Probed: 295 KB of output with
  the path on its first line → rc 141, not found. The `-q` is gone; without
  it grep reads to the end. Held by scenario 17 of `check-work.sh`
  ([scripts/check-work.sh:702]).
- [lib/runner_claude.sh:98] — `result_error` took the first line of a
  station's final message with `| head -1`; assigned as a statement in the
  worker's loop, where `-e` is on, so a long enough message would have ended
  the run right after "ended with an error". First line taken in jq.
- [lib/cmd_meter.sh:115] — the metering hook's summary, same shape on
  `last_assistant_message`; a long message would have killed the hook and
  lost the cost row. In jq.
- [lib/cmd_work.sh:439] — the dispatch summary (`.result | head -1 | cut`);
  called under `|| rc=$?`, so `-e` was off and the cost was an empty summary
  rather than a dead run. In jq.
- [lib/cmd_gate.sh:117] and the line below — the first line of a gate's
  output, into an assignment; `sed -n 1p` reads to EOF.
- [lib/cmd_work.sh:897] and three siblings — the complaint quoted on a retry
  and the `why` on a stop, `head -40`/`-20`/`-10` over gate and tool output;
  `sed -n '1,Np'`.
- [lib/board.sh:291] — `next-ready`'s `grep -oE | head -1` over card names;
  `sed -n 1p`.
- [lib/cmd_init.sh:290] — `cut | grep -qxF` over the installed-file list as an
  `&&` condition; `-q` dropped.
- [lib/manifest.sh:42] and [green.sh:403] — `jq | head -1` where jq can
  select the first element itself.

The rest are harmless and were left: `--version | head -1` (a line of
output), `printf '%s' "$short" | grep -q` where the writer finishes before
the reader is scheduled — the case `FINDINGS` #19 always described — and every
`$(… | head -1)` in an argument position, where the status is discarded.

Also swept, and clean: `$(grep -c …)` under `-e` (exit 1 on zero matches),
`local x=$(…)` (masks the status), `read` without `-r`, jq programs with a
top-level comma after `| length` (DEFECTS-4's precedence trap), and globals
assigned inside `$(…)`.

---

## Where else to look

These were the only two `| grep -q .` sites in the tree. The pattern to grep for
more broadly is any pipeline whose last stage stops reading early — `head`,
`grep -q`, `grep -m`, `read` — where the pipeline's own status is then tested,
either by `||`, by `&&`, or as an `if`/`elif` condition. Under `pipefail` those
all inherit the upstream SIGPIPE. Add to that list a plain assignment under
`set -e`, and a function that relies on `-e` and is called from a condition.
`FINDINGS.md` #19 carries the substitutes.
