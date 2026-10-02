# Defects — 0.11.0, found by the first `aif work --loop` after the upgrade

Four problems, found on the same project and the same day as DEFECTS-8 and
DEFECTS-9: a React Native / TypeScript project with jest, a Trello board, and
tickets written in Ukrainian. They came from the first `aif work --loop` on
0.11.0 and from reworking the two tickets it stopped on. That loop built
nothing. OPES-69 and OPES-74 both stopped at the plan station on a criterion
the tree already satisfied, and the loop quit after two runs that did not
build. After a rework, the next loop built both to Review.

None of the four corrupts a build that reaches Review. Each one either
misinforms the human or leaves a run exposed:

- a report that never reaches the card, while the worker says it did;
- a ticket that cannot reach its card, refused without a reason;
- a restarted run that inherits the stopped plan's files;
- an analyst who is never told about the check that stopped both runs.

Worked against `2aa2160` (0.11.0) on 2026-10-02, macOS 26.6.2 (Darwin 25.6.0),
bash 3.2.57, jq 1.8.2, git 2.50.1, python 3.13.1, Claude Code 2.1.226. All
four were present on `main` at `76416c5`; #1 is fixed after it, and its entry,
under Closed, ends with what changed. Line numbers are 0.11.0's. Each entry
says how it was established:

- **observed** — seen on the project's own runs and board, and quoted;
- **probed** — reproduced here, offline;
- **read** — established from the code alone.

---

## Open

### 2. A ticket over 16 384 characters cannot reach its card, and the refusal gives no reason — observed; the checks read

On a Trello board a ticket *is* its card's description. `aif board create`
sends the file as `desc` (`lib/board.sh:365`, `:370`), and the worker pulls it
back at intake. Trello accepts at most 16 384 characters there, and nothing in
the set knows it:

- `aif _ready` checks the contract, not the size
  (`sets/claude/gates/ready.sh`). A ticket can pass the Definition of Ready and
  still be impossible to put on the board.
- The analyst skill (`sets/claude/skills/aif-ba/SKILL.md`) never mentions the
  limit.
- `aif board create` sends the file and passes Trello's refusal on unchanged.

Observed. Reworking OPES-69 after a spec stop took its ticket from 16 199
characters to 16 871:

```
$ aif _ready OPES-69
✓ ready: 14 criteria · 15 decided · 5 gap(s)
$ aif board create tasks/OPES-69/ticket.md --column ready
error: Trello: could not update OPES-69 — curl: (56) The requested URL returned error: 400
```

Cut back to 16 199 characters, the same command answered `updated OPES-69 (…) →
ready`. Nothing explained the 400. Finding the cause meant counting characters,
which `wc -c` does not do: it puts the two versions at 24 863 and 26 084 bytes,
both far over the limit if the limit were in bytes.

The tickets near the limit are the rich ones. OPES-69 carries 14 criteria, 14
decisions and 5 gaps in Ukrainian and now sits 185 characters under the cap, so
its next rework will have to delete text before it can add any.

#### Directions

- Check the size while it can still be fixed. On a Trello board that means
  `aif _ready` (project.json names the board) and the analyst skill's drafting
  step.
- `aif board create` could refuse before sending, giving the count and the
  limit.

### 3. A restarted run inherits the stopped plan's files — read; the leftover state observed

When the plan station returns a spec stop, it has already written its contract
into the worktree: skeletons for `files.create`, and edits to the files it was
going to change. Nothing removes or commits them. The stop's report commit
covers only `tasks/<ID>` (`lib/cmd_work.sh:1039–1042`). OPES-69's `e1e7e1c`,
for example, holds `ledger.json`, `plan.md`, `report.md`, `run.json` and
`stations/`, and no source file.

The analyst then changes the ticket, as a spec stop asks. The next `aif work`
sees a new hash and restarts (`lib/cmd_work.sh:409–416`): a fresh run record in
the same worktree, with nothing reset. Observed after OPES-74's spec stop:

```
$ git -C .aif/worktrees/OPES-74 status --porcelain
 M src/services/sync/TransactionSyncService.ts
 M src/services/sync/index.ts
?? src/services/sync/BackfillRunner.ts
?? src/services/sync/SyncCursorService.ts
?? src/services/sync/syncWindows.ts
```

OPES-69's spec stop left three such files.

What the restarted run then meets (read):

- **The plan station reads them as the repository.** A skeleton from the
  stopped plan looks like an existing module, and the edited
  `TransactionSyncService.ts` looks like the current code.
- **The first accepted station commits them.** `aif _commit` stages with
  `git add -A` (`lib/cmd_gate.sh:362`), so the restarted plan's own commit takes
  in whatever the stopped plan left, whether or not the new plan names it. From
  then on the files are part of every baseline. Scope never attributes them to
  the implementer, and the branch carries code that no surviving plan asked for
  and no frozen test covers.

This was not seen failing. The project had read the code this far, so it
removed both worktrees with `aif work <ID> --clean` before the restart, and
both tickets then built. But a restart is exactly what a spec stop tells the
analyst to cause.

#### Directions

- On a restart, bring the worktree back to the branch's HEAD before the plan
  station runs. `git checkout -- . && git clean -fd` does it, and ignored files,
  such as what `prepare` installed, survive. Alternatively, discard the contract
  when a plan stops on a spec stop.
- Either way, say so on the `restart` line.

### 4. The analyst is never told about the check that stops the plan — observed; the skill read

Since 0.11.0 the plan station gives every criterion a verdict, and a verdict of
`already_true` ("the tree satisfies it now") is a spec stop
(`sets/claude/agents/aif-plan.md:86`). That is the right call, since such a
test could never be red. But the analyst who writes the criteria is never asked
to look for it. Step 3 of `sets/claude/skills/aif-ba/SKILL.md` asks for one
observable check per criterion with a literal `expect`, and `aif _ready` checks
that form. Neither asks whether today's tree already passes.

The shape that slips through is the invariant: a guard written as its own
criterion. Observed on the first loop:

| ticket | criterion | why the tree already passed it |
|---|---|---|
| OPES-69 | AC-010: no block while the status is `idle` | the block did not exist under any status |
| OPES-74 | AC-003: the first request's `to` is now | `TransactionSyncService.ts` already sets `const to = new Date()` |
| OPES-74 | AC-005: one request 59 s after the first | the tree never makes a second request |

OPES-74 was written that same morning with the 0.11.0 analyst skill, so this is
not a leftover from an older ticket format. Reading the code before the next
run found two more in OPES-41. AC-006 says "the card is still created when the
copy fails", but there is no copy step yet. AC-008 says "an old card still
renders", and OPES-41's own `decided` list notes that this already holds.

Each stop costs one opus plan run (7 and 16 minutes here) and a round trip
through the analyst. On a loop it costs more: two such tickets in a row trip
the two-runs rule, and `aif work --loop` stops having built nothing.

In every case the human chose the same fix: fold the guard into a criterion
about the new behaviour, so that one string literal carries both sides.

| ticket | became | expect |
|---|---|---|
| OPES-69 | AC-009: present before and after `idle` → `connected` | `"false → true"` |
| OPES-74 | AC-003: both edges of the first window | `"2026-09-01T12:00:00.000Z → 2026-10-02T12:00:00.000Z"` |
| OPES-74 | AC-005: calls at 59 s and at 90 s | `"1 → 2"` |
| OPES-41 | AC-005: cards created · image empty | `"1 · true"` |

The tests stations for OPES-69 and OPES-74 wrote theirs exactly that way, for
example ``expect(`${before} → ${after}`).toBe('false → true')``, and both
tickets built.

#### Directions

- Put the plan's question to the analyst while the human is still in the
  conversation: would today's tree already pass this? Name the shapes that fail
  it, such as "still", "only", "absent", an `expect` of 0 or 1 on a count, or a
  value the code already returns, and name the fold as the usual way out.
- Make clear that a ticket can keep a guard and still be red, as long as its
  literal pairs the guard with the change. The skill could show one example.

---

## Closed

### 1. A long report is cut through a character, and the worker says it was posted — probed; the refusal observed

`_aif_trello_comment` keeps a report under Trello's comment limit, which is
16 384 characters, by counting bytes (`lib/board.sh:336–340`):

```sh
  # Trello caps a comment at 16384 characters. Cut, and say where the rest is,
  # rather than fail after the work is done.
  tmp="$(mktemp "${TMPDIR:-/tmp}/aif-comment-XXXXXX")"
  if [ "$(wc -c <"$file" | tr -d ' ')" -gt 16000 ]; then
    head -c 15800 "$file" >"$tmp"
```

For any text that is not ASCII, this goes wrong in two ways:

- **The threshold is in bytes.** Cyrillic takes two bytes per character, so a
  Ukrainian report is cut well below what Trello would accept. OPES-69's
  spec-stop report was 16 198 bytes but only 12 347 characters, so it would
  have fit in one comment as it was.
- **The cut is in bytes.** `head -c` stops wherever byte 15 800 falls. Here that
  was the middle of a character.

Probed, on that report as the branch holds it:

```
$ git show e1e7e1c:tasks/OPES-69/report.md | wc -c
   16198
$ git show e1e7e1c:tasks/OPES-69/report.md | head -c 15800 | python3 -c '…bytes.decode("utf-8")…'
cut is invalid UTF-8: unexpected end of data at byte 15799 of 15800 ; tail bytes b8 d0 bc d0
```

The final `d0` is the first byte of a two-byte character whose second byte was
cut off.

Observed, at the end of the run:

```
error: Trello: could not comment on OPES-69 — curl: (56) The requested URL returned error: 400
warn: could not post the report to the board — run: aif board comment OPES-69 .aif/worktrees/OPES-69/tasks/OPES-69/report.md
board     OPES-69 → needs_human, report posted
```

Three things are wrong in those three lines:

- **The card has no report.** It moved to Needs Human without the one comment
  that says why.
- **The printed remedy cannot work.** `aif board comment` runs the same
  function on the same file.
- **The last line contradicts the first.** "report posted" is printed from the
  `else` branch of the card's *move* (`lib/cmd_work.sh:1605–1611`), so it
  appears whenever the move succeeds, whatever happened to the comment.

That Trello answers malformed UTF-8 with a 400 is inferred, not probed, because
proving it would mean posting a broken comment to a live board. Nothing else
fits, though. The cut text is 11 998 characters, far under the limit, and the
same board accepted both of OPES-74's reports later that day: 11 032 and 13 894
bytes, neither long enough to be cut.

#### Directions

- Measure the limit in characters and cut on a character boundary. Running
  `iconv -c -f UTF-8 -t UTF-8` after the cut, for example, drops a trailing
  partial character.
- Say "report posted" only when the comment was posted, and print a remedy that
  can succeed.

**Fixed.** The cut counts what Trello counts, and cuts on a character:

- `_aif_trello_comment` (`lib/board.sh`) measures the text in UTF-16 code
  units — one for a Cyrillic letter, two for an emoji — against Trello's
  16 384, through `jq`, which reads the file as UTF-8, slices by character and
  writes valid UTF-8 back. A report that fits is posted whole: OPES-69's 16 198
  bytes, 12 347 characters, would now go as they were. One that does not is
  cut on a character boundary and ends by naming where the whole text is; the
  worker passes `tasks/<ID>/report.md on branch <branch>`.
- The worker says "report posted" only when the comment was posted, and
  otherwise "report NOT on the card", with `aif board comment <ID> <file>` —
  which, through the same function, now succeeds once the board answers. The
  same holds for the `blocked:` comment on a card sent to Needs Human, whose
  text is kept under `.aif/tmp/` for that command.
- `scripts/mock-trello.py` holds a comment to Trello's limit and refuses text
  that is not UTF-8 with a 400, as Trello answered here. `scripts/check-board.sh`
  posts a Ukrainian comment over 16 000 bytes and under the limit (whole), one
  over the limit (cut on a letter, saying where the rest is), 9 000 emoji (cut,
  two units each), and runs the worker against a board that refuses comments
  (not said to be posted; the printed command posts it afterwards). Against
  the old cut, all seven of those checks fail — the first two on that 400.
