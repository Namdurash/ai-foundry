---
name: aif-review
description: The reviewer's brief — prepare the human's three-minute review of a card in Review. Reads the report on the card, the diff on the branch, the ticket's criteria and gaps, and the request's After; says per criterion which test proves it and what it asserts, what the run did not establish, and what to look at first; then takes the verdict. On land, the product partner's demo holds the build to the request in a fresh context, and aif land runs when it says as expected — or its reasons go on the card when it does not; on wrong, a rework comment in the reviewer's words. The project manager routes both. No gate; writes only the comment the human dictates and the demo's verdict. Use when a card is in Review, when the user asks what to check on a build, or invokes /aif-review.
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
what the gates left and says what they did not prove. The demo it starts on a *land*
can hold that land back, never push one through.

## What this is not

- **Not a gate.** `green`, `scope` and `verify-red` already said what they say; you do
  not re-run them or second-guess a verdict. You read their record.
- **Not the decision.** The human's word decides, and the product partner's demo can
  only hold it back. You run `aif land` only after both — the human said land, the demo
  said as expected — and you never move a card yourself. The comments you post are the
  human's, as they dictated them, and the demo's verdict, as it was given.
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
   When the ticket has rules, take them in order and put each criterion under its
   rule: the human agreed to the rules, and a rule whose every example passes can
   still be missing a case the diff makes plain.
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

- **land** — the human's yes to the code. Before it lands, the product partner looks:

  1. **The install, asked now.** When the diff moves a dependency manifest or its
     lockfile, ask whether to land with `--prepare`. The verdict needs no install in
     the human's checkout — the land judges the merge in the ticket's own worktree,
     where the branch's dependencies are installed — but after the land their
     checkout still has the old ones, and `--prepare` installs the landed lockfile
     there too, with the project's `prepare`: in their checkout, which is why it is
     theirs to choose. Ask before the demo, so nothing after it waits on them.
  2. **The product partner's demo, in a fresh context.** Start a subagent and give it
     the card and nothing else: "You are the product partner. Read
     `.claude/skills/aif-po/SKILL.md` and give the demo for <ID> — read only; answer
     with the verdict block alone, in <the user's language>." Not your brief and not
     your view: the demo is worth having because it has read neither. On a runner
     that cannot start a subagent, read the request again, give the demo yourself, and
     say it was not independent.
  3. **The verdict on the card, as given.** Write it to a file, post it with
     `AIF_BOARD_BY="aif-po demo" aif board comment <ID> <file>`, and show it.
  4. **As expected — land it, here:**

     ```
     aif land <ID>        (aif land <ID> --prepare, if they chose it)
     ```

     It merges the branch onto the checkout's branch in the ticket's own worktree and
     judges the result there — the worker's verdict when it judged that very tree,
     else the suite and the checks bound to green — then fast-forwards the checkout's
     branch to it, moves the card to Done, removes the worktree and releases the next
     slice. The human's own uncommitted work stays as it is, unless the land changes
     those very files. A verdict can take minutes: run it in the background if your
     commands time out sooner, and wait for it. Then say what it said — landed, and
     what it released, and what it let through when it says so: a test or a check
     red on the checkout's branch before this ticket, or a test that failed once and
     passed on a re-run, named on its suite line — the branch's, not this build's;
     refused, and why, with nothing touched and the card still in
     Review; sent back to the worker, when the branch conflicts with the checkout's or
     is red on it — the suite, or a check — the card at the top of Ready with a
     `sync:` comment, to come back to Review brought onto it, to be looked at again;
     or not landed, with the reason, and the card in Needs Human: an install that
     failed in the worktree, the project's git hooks refusing the land's merge
     commit. Do not run it again, and do not fix what it refused over. If it was
     stopped, nothing has landed unless it says so; the next `aif land` finishes or
     puts back whatever a stopped one left.
  5. **Not as expected — stop there.** The reasons are on the card, and the project
     manager routes them (`/aif-pjm`): rework for the analyst, a `request:` line to the
     product partner first. Say so, and that the human can still land it over the
     demo in their own terminal: `aif land <ID>`.
- **wrong** — write the rework comment in the reviewer's own words. Its **first line**
  is `wrong: <the first thing that is wrong, in one line>`; then one line per further
  thing, criteria-shaped where they can be ("AC-002 passes but the export still
  includes deleted users"). Show it, take an edit, then post it with
  `aif board comment <ID> <file>` and stop. The project manager routes it
  (`/aif-pjm`): to Backlog with `rework:`, and the analyst reworks the criteria.
- **cancel** — the same, its first line `cancel: <why, in one line>`; the project
  manager cancels it.

The fixed first line is what lets bash (`aif board head`) and the project manager
route the comment without reading it as prose; without it, the reviewer's verdict
is any comment a person left on the card.

End with the plain paths: the card, the branch, the comments posted, what landed or
why not, and the command the human runs next, if there is one.

## What this skill cannot do — said so it does not oversell

- It cannot tell whether the criteria were the right ones. That was decided with the
  analyst; here the question is whether they are met and what was left unproven.
- It reads the gates' record; it does not reproduce their verdicts. A gate that lied
  would lie to this brief too — the ledger and `aif explain` are where to look then.
- It does not run the code, and neither does the demo. "Plausibly makes After true"
  and "as expected" are readings of the diff against the ticket and the request, not
  an execution of either; the human's own run is the acceptance, and nothing replaces
  it.
