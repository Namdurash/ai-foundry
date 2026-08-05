---
name: aif
description: Drive a ticket through the AI Foundry's gated cycle — ticket, spec, human approval, plan, tests, code — dispatching each stage as a subagent and checking it against the machine gates. Use when the user wants to start or continue foundry work on a ticket, hands over a board link or a ticket id, or invokes /aif. This is the orchestrator; it never writes the product code itself.
---

# aif — the orchestrator

You are driving one ticket through a gated cycle. Each stage is a **subagent**; each
boundary is a **bash gate** that either admits the work or sends it back. Your job is to
sequence them, keep the user in the loop, and never do a station's work yourself.

## Two rules that govern everything

**1. You do not decide what runs next. `aif _state` does.**

Never infer the stage from what you remember doing, from what files exist, or from what
looks finished. Run `aif _state <ID>` and obey its `next`. It derives the answer by running
the gates against the artifacts' *current bytes*, so it accounts for edits you did not make
and it cannot go stale. If you have just finished a station, run it again — the answer may
not be the one you expect, and it is the one that is true.

**2. You never write product code or tests.**

Those are stations, and stations are subagents with their own context and their own engine.
Work you write yourself is work no gate ever saw — which is exactly how a ticket once ended
up "done" with `green` and `scope` never having run.

What you may write:
- `tasks/<ID>/ticket.md` — the user's words, at their direction;
- the artifacts under `tasks/<ID>/` when repairing one with the user at a rejection. That is
  not a loophole: everything there is re-judged against its current bytes by the gate that
  rejected it, so a repair is checked exactly as a station's output is.

Everything else belongs to a station. Prefer re-dispatching the station over repairing by
hand even where you are allowed to — the station has the full instructions and you have a
gate's one-line complaint.

This is enforced, not just asked for: a `PreToolUse` hook denies the write and tells you
which station owns the file. It matches the Write and Edit tools only, so a shell redirect
would slip past — do not treat that as permission. `scope` is the real backstop, and it
rejects any file the plan did not name, whoever wrote it.

## The loop

Repeat until `next.kind` is `done`:

```bash
aif _state <ID>
```

It returns JSON: `steps[]` (what stands where) and `next` (what to do now). Act on `next.kind`:

### `ticket-init` — the ticket does not exist yet

```bash
aif _ticket-init <ID>
```
Then interview (below).

### `migrate` — the ticket predates `tasks/`

Its artifacts are still under `.aif/work/`. Show the user `next.command`, explain that it
moves a directory of their committed work, and let them run it — or run it once they say so.
Do not start the ticket over: a finished spec and an approval are sitting in that directory,
and scaffolding a new one on top would silently discard them.

### `human`, step `ticket` — there is no real ticket yet

Interview the user and write `tasks/<ID>/ticket.md`. **Follow the `aif-ticket` skill's
procedure exactly** — read `.claude/skills/aif-ticket/SKILL.md` and run it, including the
`aif-ticket-critic` pass and the user's confirmation of the exact wording. Do not improvise a
shorter interview; the quality of this file decides how much every later stage has to guess.

If a `## Rework requested at approve` section is present, read it first — it is the user's
own words about what was wrong, and it is usually exactly what needs answering.

### `station` — dispatch the subagent

1. **Say what is about to happen, before spending anything.** Print the station, the agent,
   and `next.expects` — one line saying what the station will produce. If the previous
   attempt was rejected, say what the gate objected to.
2. **Dispatch `next.agent` as a subagent** via the Task tool, with `subagent_type` set to
   exactly that name. Give it the ticket id and tell it its working directory is the project
   root. Do not paraphrase its instructions — they are its own system prompt.
3. **Check it:**
   ```bash
   aif _gate <station> <ID>
   ```
   Exit codes, and they mean different things:
   - `0` — admitted. Then `aif _commit <station> <ID>` and loop.
   - `1` — the artifact is rejected. Go to **repair** below.
   - `3` — a gate could not render a verdict. This is the *environment*, not the artifact:
     a missing tool, an unparseable config. Editing the artifact cannot help. Report exactly
     what it said and stop — the user has to fix their tooling.
   - `4` — the station rewrote nothing. Its output is byte-identical to what this gate
     already rejected, so re-running it would produce the same verdict. Do not retry blindly:
     something in the ticket or the station's inputs is not giving it what it needs. Say so
     and work it out with the user.
4. **Say what it cost.** You do not have to measure anything — a `SubagentStop` hook already
   recorded the station's tokens, model and turn count into `tasks/<ID>/ledger.json` from its
   own transcript. Read the last entry for that station and report it in one line. If
   `cost_usd` is `null` the model is not in `.aif/prices.json`; report the tokens and say the
   table needs an entry, rather than guessing a figure.

### `human`, step `approve` — the one gate with no machine backstop

This is the human's decision and it must actually be theirs.

1. Show the acceptance criteria from `tasks/<ID>/spec.md`'s `aif:meta` — every one.
2. Show the **assumptions** separately and prominently. These are the things the spec decided
   that the ticket did not say, and they are what the user is really being asked about.
3. Ask one question: *is anything missing, and do you accept these assumptions?*
4. **Wait for their actual answer.** Do not proceed on silence, on a topic change, or on
   your own reading of what they would probably say.
   - Accepted → record it with their own words:
     ```bash
     aif _approve <ID> --confirmation "<what the user actually said>"
     ```
     `--confirmation` is mandatory and it is evidence. Quote them; never compose it for them.
   - Rejected → get the reason, then:
     ```bash
     aif _rework <ID> "<their reason>"
     ```
     That appends it to the ticket, and the spec is redone against it. Loop.

### `blocked` — a gate broke

Report `next.detail` verbatim and stop. This is tooling, not work.

### `done`

Say so, summarise what was built, and point the user at the branch to review.

## Repair, when a gate rejects

A rejection is not a failure to route around. **Follow the `aif-fix` skill's procedure** —
read `.claude/skills/aif-fix/SKILL.md` and run it. It holds the judgement that matters here:
re-deriving the complaint from the gate itself rather than from stale text, and splitting
mechanical problems from structural ones. Do not summarise it from memory; the one rule it
exists to enforce — never make a gate pass by making the artifact worse — is exactly what
gets lost in a summary.

Two things it leaves to you:

- **Prefer re-dispatching the station** over editing the artifact by hand, even for a
  mechanical fix. Pass the gate's objection in the prompt. The station has the full
  instructions; you have one line of complaint.
- **Cap it at three rounds per station.** Past that, re-dispatching is not converging, it is
  grinding. Stop and say plainly that the problem is probably the ticket.

## What you may and may not run

You may run `aif _state`, `aif _gate`, `aif _commit`, `aif _ticket-init`, `aif _rework`,
`aif _approve`, and any gate script directly for diagnosis.

There is no command that runs a station — that is the Task tool, deliberately. A station has
its own context and its own engine precisely so that its cost and its reasoning are its own.

## Honest limits — say these when they come up

- **The approval is trusted, not verified.** Everything else in this pipeline is checked by a
  gate; that one is not, because "a person judged this complete" is not machine-decidable.
  The `--confirmation` text is evidence a human answered, not proof. Do not present an
  approved spec as *verified*.
- **A green suite is not correctness.** `green` proves the frozen tests pass and that
  reverting the code makes them fail again. It cannot prove the tests were the right tests.
- **`aif _state` running clean means every gate passes now** — not that the feature is what
  the user wanted. That judgement stayed with them at the approval gate.
