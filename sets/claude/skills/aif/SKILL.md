---
name: aif
description: Drive a ticket through the AI Foundry's gated cycle in a session you can watch — ready, plan, tests, code — dispatching each stage as a subagent and checking it against the machine gates. Use when the user wants to watch foundry work on a ticket in-session rather than run `aif work` headless, or invokes /aif. This is the orchestrator; it never writes the product code itself.
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
- `tasks/<ID>/ticket.md` — with the user, following the `aif-ba` skill;
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

Write `tasks/<ID>/ticket.md` with the user. **Follow the `aif-ba` skill's procedure
exactly** — read `.claude/skills/aif-ba/SKILL.md` and run it: the repository first, the
criteria with the user, every open question with a default, `aif _ready` until it passes.

### `not-ready` — the ticket exists but the Definition of Ready refuses it

`next.detail` is the ready gate's own output: one line per problem, and the lines that
start with `open question` are product questions with a proposed default. Take them to the
user as one batch, exactly as the `aif-ba` skill does at its step 4, record the answers in
the ticket's `decided` list, fix anything else the gate named, and loop. Do not dispatch
anything until `_state` stops saying `not-ready`.

### `station` — dispatch the subagent

1. **Say what is about to happen, before spending anything.** Print the station, the agent,
   and `next.expects` — one line saying what the station will produce. If the previous
   attempt was rejected, say what the gate objected to.
2. **Dispatch `next.agent` as a subagent** via the Task tool, with `subagent_type` set to
   exactly that name. Give it the ticket id and tell it its working directory is the project
   root. Do not paraphrase its instructions — they are its own system prompt.

   **Pass `next.bindings` into the prompt verbatim.** Each entry is a hash the station must
   copy into its artifact exactly as given — one line per key, e.g.
   `subject_sha256: <value>`. This is part of the dispatch contract, not a courtesy: the
   judges have no Bash tool and physically cannot hash a file, so a dispatch without the
   value is a station that cannot produce a valid verdict. Never compute these hashes
   yourself and never alter what `_state` returned — the gate verifies the recorded value
   against the real bytes, so a wrong one is caught, but a *stale* one you cached from an
   earlier `_state` call wastes the whole station run. If `bindings` is `{}`, there is
   nothing to pass.
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
4. **Show what the gate showed you.** A passing gate is not a silent gate. When `plan-form`
   passes it prints, on the pass path, three things the plan is allowed to have and the user
   is not allowed to be unaware of: files created with no criterion, an **unvalidated external
   surface**, and surface drift for the judge. Relay those lines verbatim — do not summarise
   them away because the gate said `0`. The unvalidated-surface list is the one that matters
   most: it names dependencies nothing in this run will exercise, on a ticket that is about to
   be built on them.
5. **Say what it cost.** You do not have to measure anything — a `SubagentStop` hook already
   recorded the station's tokens, model and turn count into `tasks/<ID>/ledger.json` from its
   own transcript. Read the last entry for that station and report it in one line. If
   `cost_usd` is `null` the model is not in `.aif/prices.json`; report the tokens and say the
   table needs an entry, rather than guessing a figure.

**When the station was `plan-judge` and it passed, draw the plan:**

```bash
aif explain <ID> --plan --auto plan
```

Relay the path it prints and move on — do **not** wait for an answer. The plan is the one
artifact with no human gate after it, and it is also the one the user has to live with; a
drawing they can open is the difference between that being a choice and being an accident.
It renders nothing when the project has it off, and that line is the normal answer, not a
problem to report.

### `blocked` — a gate broke

Report `next.detail` verbatim and stop. This is tooling, not work.

### `done`

Say so, summarise what was built, and point the user at the branch to review.

Then print `next.checklist` — **every entry, in full, as a checklist they are meant to act
on.** It is what this run did *not* establish: the verification gaps the analyst recorded
with them, and every external dependency the plan could point at neither a check nor a
criterion for. A gap acknowledged once at the start and never mentioned again is the same as
no gap at all, which is exactly how a module that does not run on its target environment ships
through eight green gates. If the list is empty, say that too — it is a real answer.

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

You may run `aif _state`, `aif _gate`, `aif _commit`, `aif _ticket-init`, `aif _ready`,
`aif explain`, and any gate script directly for diagnosis.

`aif explain` is safe to run at any point and as often as you like: it writes one generated
file under `tasks/`, which is on scope's denylist, and it spends nothing. If the user asks
what a criterion came from or why a decision was made, run it rather than answering from
your own reading of the artifact — what it draws is what the station wrote, and what you
would say is a reconstruction.

There is no command that runs a station — that is the Task tool, deliberately. A station has
its own context and its own engine precisely so that its cost and its reasoning are its own.

## Honest limits — say these when they come up

- **The criteria are the human's, not verified.** Everything downstream checks that the
  code matches the criteria; nothing checks that the criteria match the intent. That stayed
  with the user in the analyst's conversation, which is the point of holding it there.
- **A green suite is not correctness.** `green` proves the frozen tests pass, that the
  project's own checks pass, and that reverting the code makes the covering tests fail again.
  It cannot prove the tests were the right tests, and it cannot reach anything the acceptance
  criteria only exercise through a fake.
- **An unvalidated external dependency stays unvalidated.** Naming one in the plan's
  `external` list does not test it; it only means nobody can later say they did not know.
- **`aif _state` running clean means every gate passes now** — not that the feature is what
  the user wanted. That judgement stayed with them when the criteria were written.
