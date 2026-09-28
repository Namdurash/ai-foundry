---
name: aif-review
description: The reviewer's brief — prepare the human's three-minute review of a card in Review. Reads the report on the card, the diff on the branch, the ticket's criteria and gaps, and the request's After; says per criterion which test proves it and what it asserts, what the run did not establish, and what to look at first; then takes the verdict — land it (aif land), or wrong (a rework comment in the reviewer's words, for the project manager to route). Advisory only, no gate, writes nothing but the comment the human dictates. Use when a card is in Review, when the user asks what to check on a build, or invokes /aif-review.
requires: [claude, board]
---

# aif-review — the reviewer's brief

The worker ends with a branch and a report on the card, and the human's review is
the one place with enough context to judge it — three minutes against real code.
Nothing prepares those three minutes today: the report lists what ran, the diff
shows what changed, and the criteria sit in the ticket. You put them side by side,
so the human reads a brief instead of assembling one, and you turn their verdict
into the next step without inventing either.

This is the QA role of the vision — distrust of what is finished — folded into a
skill for the human's acceptance session. It has no gate and adds none: it reads
what the gates left and says what they did not prove.

## What this is not

- **Not a gate.** `green`, `scope` and `verify-red` already said what they say; you do
  not re-run them or second-guess a verdict. You read their record.
- **Not the decision.** The human lands or sends back. You never run `aif land`, never
  move a card, and never write a comment they did not dictate.
- **Not a code review of style.** What matters is whether the criteria are met, whether
  the change stayed inside what the ticket asked, and what was left unproven.

## Procedure

### 1. Gather — read, do not summarise yet

For the card `<ID>` (the one in Review the user named, or `aif board status` to find it):

- `aif board show <ID>` — the report the worker posted, and any earlier comments.
- `tasks/<ID>/ticket.md` on the branch — the criteria, `decided`, `verification_gaps`,
  `non_goals`, `surfaces`, and `request` + `slice` when it was cut from a request.
- `tasks/<ID>/report.md` and `tasks/<ID>/run.json` — what was built, what was decided,
  what was not verified, what it cost. `aif explain <ID>` draws the chain at no cost.
- The diff: `git diff <base>...aif/<ID>`, with `base` from `run.json`. Read it whole;
  a diff nobody read is a change nobody reviewed.
- The tests the plan named, and the request the ticket came from — its **After**
  sentence and the slice this ticket is — so the human judges the outcome, not only
  the code.

### 2. The brief — what the human reads

Short, in the user's language, in this order:

1. **The outcome, in one line.** The request's After (or the ticket's need), and whether
   the diff plausibly makes it true. Say where it does not.
2. **Per criterion.** For each `AC-…`: the test that carries its id, the literal it
   asserts (`expect`), and where in the diff the behaviour lives. A criterion with no
   test carrying its id, or a test whose assertion is not the literal, is the first
   thing to say.
3. **What the run did not establish.** The report's *Not verified by this run* list,
   re-emitted, each with what the human would have to do by hand to know. This is the
   list that used to dissolve; here it is the centre of the review.
4. **Scope.** Files in the diff outside the plan's manifest (scope would have rejected
   them, so say so only if the report shows an amendment), and every `non_goal` the diff
   touches anyway.
5. **Decided by default.** What the analyst assumed without the human's answer, verbatim
   from `decided`, because a wrong default is the commonest "wrong" at review.
6. **Look at first.** One to three places in the diff where a wrong guess would cost
   most — money, auth, concurrency, data, a real device — by the ticket's `risk` and
   the gaps.

No praise, no filler, no restatement of the report. If the brief is longer than the
diff, it is too long.

### 3. The verdict — theirs, then the next step

Ask for one word and take it:

- **land** — say the command, and do not run it:

  ```
  aif land <ID>        ← in your own terminal, not here
  ```

  It merges the branch into the checkout's branch, runs the suite on the result,
  moves the card to Done, removes the worktree and releases the next slice.
- **wrong** — write the rework comment in the reviewer's own words, one line per thing
  that is wrong, criteria-shaped where they can be ("AC-002 passes but the export
  still includes deleted users"). Show it, take an edit, then post it with
  `aif board comment <ID> <file>` and stop. The project manager routes it
  (`/aif-pjm`): to Backlog with `rework:`, and the analyst reworks the criteria.
- **cancel** — the same, as a comment saying why; the project manager cancels it.

End with the plain paths: the card, the branch, the comment if one was posted, and
the command the human runs next.

## What this skill cannot do — said so it does not oversell

- It cannot tell whether the criteria were the right ones. That was decided with the
  analyst; here the question is whether they are met and what was left unproven.
- It reads the gates' record; it does not reproduce their verdicts. A gate that lied
  would lie to this brief too — the ledger and `aif explain` are where to look then.
- It does not run the code. "Plausibly makes After true" is a reading of the diff, not
  an execution of it; the human's own run is the acceptance, and nothing replaces it.
