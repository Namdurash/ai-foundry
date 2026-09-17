# AI Foundry (`aif`)

Put an existing project on AI SDLC rails. You run `aif init`, pick a profile,
and the native config for that agentic coding CLI lands in your repo — agents,
skills, and context files, ready to drive.

> **Status: early, but the machine is whole.** The analyst writes a ticket's
> criteria with you; one command then builds it headless through four stations
> and six gates, metered per station, and never asks a question. It has been run
> against a real project; what that run found is written down in
> `docs/REBUILD.md` rather than smoothed over. What is still thin: the evals are
> a smoke test, there is one runner, and the price table ships empty.

## What it is

`aif` is not an agent runtime. The agentic loop — call the model, execute the
tool, feed the result back, repeat — already exists in `claude`, `codex` and
friends. `aif` is the layer above: the curated agents, skills and workflow that
those runners execute, plus the scaffolding to install them.

## How it is put together

**There is no neutral format.** `aif` does not transpile one definition into
many targets. It ships **per-runner sets**, each written natively in that
runner's own format. Tool restrictions, hook names and slash commands genuinely
do not map losslessly between runners, so nothing tries to.

**A profile is a (set, model) pair.** Because GLM-5.2 speaks the Anthropic
Messages API protocol, the `glm` profile reuses the `claude` set verbatim and
differs only in environment. A Chinese model costs a config file, not an
adapter.

```
sets/claude/      native Claude Code layout: CLAUDE.md, skills/, agents/, commands/
sets/codex/       native Codex layout: AGENTS.md, agents/*.toml   (later)
profiles/*.profile   (set, model, env) triples — glob-enumerated, user-extensible
tests/fixtures/   evals: fixture repo + task + deterministic oracle
```

### What lands in your repo, and what does not

```sh
aif init            # pick a profile from a list
aif init glm        # or name it, for CI
aif init --dry-run  # or just look
aif uninstall       # and take it all back
```

| Path | Committed | Why |
|---|---|---|
| `.claude/skills/`, `.claude/agents/`, `.claude/commands/` | yes | the shared foundry — the team's asset |
| `.aif/foundry.md` | yes | our context, imported by `CLAUDE.md` |
| `.aif/manifest.json` | yes | the ledger of what we installed and changed |
| `CLAUDE.md` | yes | **yours**; `aif` only appends one `@.aif/foundry.md` line |
| `.aif/profile.local` | **no** | your model choice |

So a team shares one foundry while one developer runs it on Opus and another on
GLM. Whether that actually holds is an empirical claim — which is what the
harness is for.

**`aif init` never clobbers.** The manifest records the digest of every file it
writes, so a re-run can tell "we wrote this and nobody touched it" from "you
edited it" from "this was here before us". The first is overwritten silently;
the other two are reported as conflicts and skipped unless you pass `--force`,
which keeps a backup. Your `CLAUDE.md` is only ever appended to, inside a marked
block, and re-running rewrites just that block.

**`aif uninstall` reverses it exactly.** An install/uninstall round trip leaves
`git status` empty. Files are removed only while they still hash to what we
recorded — edit one and it is yours, kept and reported. Settings keys are
removed only while they still hold the value we wrote, because deleting by key
name alone is how an uninstaller takes away the setting you actually wanted.

Model routing is deliberately absent from every file above — it is exported at
`aif run` time instead. See `docs/FINDINGS.md`.

### Running it

```sh
aif work TICK-1              # build it headless, on its own branch — no questions
aif run TICK-1               # the same pipeline, in a session you can watch
```

`aif work` is the worker: one ticket, one git worktree (`.aif/worktrees/TICK-1`
on branch `aif/TICK-1`), one budget, and **no question at any boundary**. The
ticket's bytes are hashed and committed at intake and stay frozen for the run;
every station runs as `claude -p` with its own prompt and tools; every gate
verdict is recorded; a rejection is retried with the gate's complaint in the
prompt, up to `limits.attempts_max`, and a station that will not converge stops
the run with a report rather than a conversation. What comes back is
`tasks/TICK-1/report.md` — what was built, what was decided, what was not
verified, what it cost — beside the diff, which is the one place a reviewer has
enough context to judge it. Run several tickets at once: each gets its own
worktree. The offline walk of the whole thing is `scripts/check-work.sh`.

`aif run` is the entry point for anything other than your default provider.
Routing is applied by exporting into the child process, so **a bare `claude` in
the project is not on the profile's model** — it uses whatever the project
already had. That is deliberate: the alternative is a routing setting that might
be ignored, which puts you on a model you did not choose without telling you.

The same export is how each station gets its engine: a station is a subagent
declaring `model: opus`, and the profile decides what `opus` resolves to
(`glm-5.2` on the `glm` profile). The set stays model-agnostic while a station
still says how much engine it needs.

Each profile clears routing before applying its own, so a leftover `ANTHROPIC_*`
in your shell cannot redirect a run. A profile means the same thing on every
machine, or it means nothing.

## Testing

```sh
aif test L0-smoke --profile glm --runs 3
```

`aif test` is an eval, not a unit test. It runs a fixture through the real runner
against a real model and checks a deterministic oracle. Models are not
deterministic, so a single run means nothing — it reports a pass rate with a
Wilson interval over N runs:

```
  3/3 · 100% [44-100%] · median 2 turns · total $0.0104
```

That interval is the honest part. 3 out of 3 does not mean "it works"; it means
"you have not proven much yet". A naive implementation would print 100% ± 0%.

The level-0 smoke fixture needs no agents at all — it only proves the wiring
(base URL, auth, tool-calling). That is deliberate: the harness has to exist
before the content, or there is no way to tell whether the content works.

If every run comes back 0/N with an authentication error, check *where* you are
before debugging the harness — a nested `claude` can fail to authenticate in some
environments. It is not a rule, and nothing here is designed around it; see
`docs/FINDINGS.md` #7, which used to say it was.

## Cheatsheet — a ticket through the pipeline

### One-time, per machine

```sh
brew install Namdurash/tap/aif
```

Or, to run it straight from a clone:

```sh
ln -s /path/to/ai-foundry/bin/aif /opt/homebrew/bin/aif
```

### Once, per project

```sh
aif init              # install the set, pick a profile
aif project init      # detect the runner, and ask what "done" means here —
                      # then REVIEW .aif/project.json, especially test.command
aif doctor --probe    # which ROLES can run here — analyst, project manager,
                      # worker — and what each is missing
aif board init local  # …or: aif board init trello --board <url> --create-lists
aif project checks    # ask again later, when the Definition of Done moves
aif test L0-smoke --profile anthropic --runs 3   # smoke: does the model answer?
```

Or open a session and say `/aif-setup`: it runs `aif doctor --json`, explains
each ✗ in plain words, fixes what a command can fix, and asks you only for what
only you have — which board, a token you create yourself. It never asks for the
token: it prints `aif secret set TRELLO_TOKEN` for **your** terminal, because a
token pasted into a chat lands in a transcript on disk. And it never declares
readiness — the last thing it does is run `aif doctor` again and show its table.

`aif project init` asks one question, once: **what must pass besides the tests?**
It offers the checks it can find — the scripts your `package.json` declares, the
targets in your `Makefile` — and you confirm, edit or skip each. Nothing is
auto-written: a wrong guess costs more than a question, and a check that silently
never runs is indistinguishable from one that passes. Answer nothing and the test
command is the whole Definition of Done, which is a valid answer and a
consequential one, so `aif project check` says it out loud.

`test.roots` is the one field whose name invites the wrong reading. It is the
**smuggling net** over your shared test tree — the tree `green` re-hashes so that
logic cannot be hidden in a fixture no plan lists. It is *not* where a ticket's
own tests are declared; the plan says that, and `verify-red` freezes the union of
the two. A project that pointed `roots` at one tree while its tests lived beside
their sources froze neither, and nothing noticed.

### Before the build — the analyst

**`/aif-ba`** writes the ticket with you (`/aif-ba TICK-1 "add rate limiting to
login"`). It ships as both a skill and a slash command with the same name, so it
is reachable whether or not your runner lets you type skills.

Two things make it an analyst rather than an interview form. **It writes the
acceptance criteria** — GIVEN / WHEN / THEN, each with the literal a test will
assert — with you, in the conversation, rather than handing a narrative to a
station that re-derives criteria blindfolded; that second translation was where
a ticket's meaning used to get lost. And **it reads the repository first**, so
the questions it puts to you are the ones the code cannot answer: what the
product should *do*. Those are yours; a decision you do not make is recorded as
*decided by default*, in the open, with the default named — never filled in
silently.

It ends with the **Definition of Ready** and a card on the board:

```sh
aif _ready TICK-1
aif board create tasks/TICK-1/ticket.md --column ready
```

One script, two callers: the analyst runs it while you still have the whole
conversation in your head, and the worker runs the same file at intake. It
prints one line per problem, and the lines that matter are the open questions,
each with its proposed default — shown to you as one batch, at the moment you
have the most context you will ever have on this ticket. Answer them, or say
"defaults", and the ticket is buildable. A ticket that comes back from review
comes back here, not to the worker: "wrong" almost always means the ticket did
not say.

### The board — where the state is seen

The board is the coupling between the three roles, and it is where the project's
state is *seen* rather than held in a head:

```
Backlog → Ready → In Progress → Review → Done
                                  ↘ Needs Human
```

The analyst puts a ready ticket in **Ready**. `aif work` — with no argument —
takes the card at the top, moves it to **In Progress**, builds, and moves it to
**Review** with the report as a comment, or to **Needs Human** with the gate's
questions. You review beside the diff; the project manager routes what you say.
Every transition goes through one adapter, `aif board`, in bash — a model
"remembering" to move a card is fail-open bookkeeping, and a card that quietly
did not move is the same defect as a meter that quietly did not fire.

```sh
aif board status                  # every card, by column
aif board next-ready              # what the worker would take
aif board move TICK-1 ready --top # the project manager's order
aif board show TICK-1             # the card, with the reviewer's comments
aif board check                   # is it reachable, as configured?
```

Two backends, one interface. **`local`** is the default: cards live in
`.aif/board/` of your checkout, gitignored — this machine's board, for a project
without one. **`trello`** talks to the REST API with a key and a token from
`aif secret`; `aif board init trello --board <url>` maps the six columns to the
board's lists by name and prints the mapping, because a wrong mapping moves cards
to the wrong column silently. On Trello the card's description **is** the ticket
file: the analyst writes it there, and the worker pulls it back at intake, hashes
it, and builds exactly those bytes — the board is canonical for the text until
intake, the repository after. `scripts/check-board.sh` drives both backends
offline, the Trello one against a stand-in server (`scripts/mock-trello.py`).

**`/aif-pjm`** is the project manager: it orders Ready, links tickets, reads the
reviewer's words on a card in Review and routes them — rework to Backlog with the
comment for the analyst, cancel to Done — and finds cards that have sat too long.
It works only through `aif board`. **It never starts a build and never edits a
ticket's text**: the worker consumes Ready, the project manager decides what is
in it. Every decision it makes is a card position or a label you can override by
dragging. The moment a coordination agent can *start* work, the questions come
back through it, which is why this one cannot.

**Secrets never pass through a model.** `aif secret set NAME` reads with echo
off in your terminal and stores in the macOS keychain (a `0600` file elsewhere);
`aif secret check NAME` says whether it is set, and nothing on the CLI prints a
value. `.aif/project.json` records the secret's *name*, never the value.
Exporting the same name in your shell overrides the store, which is how CI works.

**`aif doctor` reports per role.** Every role declares what it requires — the
worker in `lib/roles.sh`, each skill in its own frontmatter — and each capability
is a probe, not a file check: `board` means a token resolved *and* one call to
the API succeeded *and* the six columns exist. The test toolchain is `?` until
`--probe` runs the suite once; "not checked" is not "fine". `aif work` runs the
board check again before the first token, so an expired token stops the run with
one line instead of a card that never moved.

### When a gate rejects — the repair bench

**`/aif-fix <ID> [station]`** is the other half of a rejection. It re-derives the
complaints by running the gate itself, explains each one from the gate's own
reasoning, and then splits them in two: *mechanical* problems (an assertion that
joins two clauses, a missing verb, prose where a literal belongs) it fixes in the
artifact with you; *structural* ones it refuses to fix, because they are the gate
saying the work is too big or the ticket too vague.

That refusal is the point. Every gate here is a proxy, so there is always a cheap
way to turn it green that destroys what it was protecting — delete six criteria to
get under a limit and `ready` passes while the ticket now says less than you
asked for. `/aif-fix` will not do that; it takes the split back to you and the
change lands in `ticket.md`, with the analyst, where the plan will actually read
it.

Inside `aif run` this is what the orchestrator does on a rejection, in the session,
with you present — the same split, the same refusal to make a structural
complaint go away.

### A ticket, in order

```
Ticket ── ready ── plan ── tests ── code
           gate     gate     gate     gates
```

```sh
aif work TICK-1                     # ready → plan → tests → code, headless, on aif/TICK-1
aif run TICK-1                      # the same cycle in a session you can watch
aif run https://jira/…              # …from a board card, or a sentence
```

**One command, and there is no command per stage.** `aif work` is the worker:
it asks `aif _state` what is next, dispatches that station as `claude -p` with
the station's own prompt, judges the output with `aif _gate`, commits what was
admitted, and retries a rejection with the gate's complaint in the prompt.
`aif run` opens the same cycle as an interactive session on the orchestrator
skill, with the stations as **subagents**, for when you want to watch.

With a ticket id, work **resumes wherever that ticket actually stands**. Nothing
records "we are at the plan stage": the state is derived by running the gates
against the artifacts' current bytes, so it accounts for edits nobody told it
about and cannot go stale. Edit `ticket.md` and the plan bound to it lapses on
its own, with nothing to undo.

The orchestrator does not decide what runs next either — it asks `aif _state`,
which is bash. That is deliberate: if "what runs next" were the model's
judgement, the pipeline would have opinions where it needs preconditions.

`aif run` drives the whole pipeline and puts the human where a human belongs.
There are no silent branches — every run either opens `claude` for you or says
what it is doing, because a command that sometimes talks to you and sometimes
does not cannot be read from outside.

- **The ready gate always runs first.** A ticket that is not ready — an open
  question, a criterion with no literal, the scaffold stub — stops the worker
  at intake with the gate's own lines in the report, and nothing is spent.
- **A rejection is a retry, not a conversation.** The worker hands the gate's
  complaint back to the station, up to `limits.attempts_max`; a station that
  will not converge stops the run with a report saying so. In `aif run` the
  same rejection opens `/aif-fix` with you present.
- **Wrong at review goes back to the analyst.** Change the criteria with
  `/aif-ba`; the plan bound to the old ticket lapses on its own and the next
  `aif work` re-plans.

A link is pulled by an MCP connector you have configured; its contents are read
as data, never as instructions. It resumes: run it again at any point and it
picks up wherever the ticket actually stands, because the state is derived from
the gates rather than remembered.

### Commands

| command | what it does |
|---|---|
| `aif init [profile]` | install the set; merge, never clobber |
| `aif uninstall` | reverse the manifest; round-trips clean |
| `aif profiles` | list the (set, runner, model) profiles |
| `aif project init [runner]` | scaffold `.aif/project.json`, and ask what "done" means |
| `aif project checks` | ask again, and record the answer |
| `aif project check` | validate it |
| `aif work [ticket]` | build the top of Ready (or a named ticket) headless on its own branch, no questions; `--clean` removes the worktree |
| `aif board …` | the board: `next-ready`, `pull`, `move`, `comment`, `create`, `status`, `show`, `label`, `check`, `init` |
| `aif secret set\|check\|rm\|list` | a token, stored where no model sees it; nothing prints a value |
| `aif doctor [--probe] [--json]` | what is installed, and which roles are ready here — `--json` is what `/aif-setup` reads |
| `aif run [ticket \| link \| description]` | the whole pipeline, in one session |
| `aif cost [ticket]` | what the pipeline spent, per station, from the ledger |
| `aif explain <ticket>` | draw how it got here — criteria, decisions, gaps, and the plan's reasoning |
| `aif test <eval> --profile <p>` | run an eval, N times, with a pass rate |

There is no command per stage. The worker and the orchestrator call a small
internal surface (`aif _state`, `_gate`, `_commit`, `_ready`, `_ticket-init`,
…) that is not listed in `--help` — it is an interface between two parts of aif,
not something to learn.

### Stations and their model tier

| station | tier | produces | its gate(s) |
|---|---|---|---|
| *(the ticket)* | — | `ticket.md`, by the analyst with you | ready |
| `plan` | careful (opus) | `plan.md` | plan-form |
| `plan-judge` | **routine (sonnet)** | `verdict-plan.json` | plan-judge |
| `tests` | careful (opus) | test files + `tests.lock.json` | verify-red |
| `implement` | **by risk** | code | green, scope |

There are two tiers, and the question a tier answers is "do the gates catch this
model's mistakes": `routine` where they do, `careful` where they do not. The tier
is a label; the profile maps it to a model (`opus` → glm-5.2 on the `glm`
profile).

`implement`'s tier comes from the ticket's `risk`, which stays three-valued
because it describes the *work* — a human's judgement, made with the analyst —
while a tier describes an *engine*. `low` and `medium` both map to `routine`, `high` to
`careful`.

### Gates and exit codes

Every gate is `gate.sh <work-dir>` → an exit code:

| code | meaning | what to do |
|---|---|---|
| **0** | pass | proceed |
| **1** | the artifact is rejected | fix it and re-run the station |
| **3** | the gate could not render a verdict | rerun the judge, or fix the environment |

`1` versus `3` is the difference between "your plan has a blocker" and "the judge
hallucinated / the repo was already broken". `verify-red`: a real failing test is
`0`; a `SyntaxError` test is `3` (not a usable oracle); a test that already passes
is `1`.

### What "done" means here, beyond the tests

`green` used to read exactly one thing to decide whether a station passed:
`.test.command`. There was no way for a project to say it also has a compiler, a
linter, a build, or a dependency-integrity check — so a Definition of Done wider
than "the test command exits 0" could not be expressed and was therefore never
enforced. A module that did not run on its target runtime shipped through a
green suite that way, with the type-check and the lint pass established by a
human during review rather than by the pipeline.

`.aif/project.json` now carries them:

```json
"checks": [
  { "name": "typecheck", "command": "…", "phase": ["green"], "required": true },
  { "name": "lint",      "command": "…", "phase": ["green"], "required": true }
]
```

**Every check names a phase, and that is not optional.** The tests station writes
*failing* tests before any implementation exists — that is its whole purpose — so
a compiler run at that moment would fail correctly, and a phase-blind check would
reject the red phase for being red by design. `red` is the tests boundary and
only a check that is true of the test files alone belongs there; `green` is the
implement boundary, and compilers, linters and builds go there. It is the same
distinction `failure_classes` already draws one level down between a legitimate
failure and a broken one.

`green` runs every check bound to its phase, fails the station if a required one
does, and each result lands in the ledger by name — so a failure is attributable
to `typecheck` rather than to "the implement station". `test.command` keeps
working unchanged.

### The test freeze, and what it actually holds

`verify-red` freezes the test tree into `tasks/<ID>/tests.lock.json`, and `green`
refuses to accept an implementation unless the tree still hashes to it. That is
what stops the implement station editing the oracle it is judged against.

The frozen set is the **union** of two things, and for a while it was one:

- `test.roots` — the whole shared test tree, so logic cannot be smuggled into a
  fixture that no plan lists. This net is correct and stays.
- the plan's `files.tests` — *this ticket's own oracle*, which the plan has
  always declared and the freeze ignored.

A project whose `roots` pointed at `__tests__` while its tests lived beside their
sources in `src/` froze one file unrelated to the ticket and none of the ticket's
own — so the guarantee did not apply to that ticket at all, and nothing detected
it. Two invariants now make that a hard stop rather than a silent absence: every
path in `plan.files.tests` must be in the frozen map, and every entry in
`covering` must resolve to a file the lock actually holds.

The file was called `tests.lock` and is now `tests.lock.json`. Same meaning —
generated, pins resolved state, do not hand-edit — without lying about the
format. Its contents cannot move into `plan.md`: the lock carries `plan_sha256`,
so writing it into the plan would change the plan's bytes and invalidate the
binding just recorded, and the hashes cannot be computed at plan time because the
tests do not exist yet. The plan declares intent; the lock records fact.

### The external surface, and what validates it

Every `because` a planning model writes points *backwards into the ticket*:
"AC-007 and AC-008". That proves conformance to the criteria and is
structurally incapable of proving conformance to **reality**. On a live
ticket two decisions asserted the shape of a third-party API from memory — a
runtime global that does not exist on the target, and a method the real library
does not have — and every gate passed.

The first fix proposed was a self-declared provenance field (`grounds: {kind:
"verified", at: "<path>:78"}`) and it was rejected during review, correctly: a
model that hallucinated a method name will just as readily write `verified`
beside it, and a judge that sees `verified` relaxes. Self-attestation is not
verification.

What replaced it asks a different question — not *"prove your claim is true"*,
which no self-report can answer, but *"what validates this dependency?"*, which
is a set-coverage question of exactly the same shape as "which criterion covers
this file":

```json
"external": [
  { "name": "the keychain module",  "check": "typecheck" },
  { "name": "the storage library",  "ac": "AC-004" },
  { "name": "the crypto global" }
]
```

Every name must point at a check from `.aif/project.json` or a criterion from
`ticket.md` — **checked against those files, not against the plan's word for it**,
so naming a validator you have not got is a rejection. An entry that points at
neither is a *verification gap*: it is not rejected, because some dependencies
genuinely cannot be exercised in CI. It is printed at the gate:

```
UNVALIDATED EXTERNAL SURFACE — no check and no criterion touches these:
  - the keychain module
  - the storage library
  - the crypto global
```

Three lines, on a ticket whose entire purpose is storing a secret safely. That is
the conversation that never happened.

Stated plainly: the list is compiled by the same model, so it can omit an entry.
That is a strictly weaker failure than the rejected design — an omission is an
oversight a plan review can catch, where writing `verified` without verifying is
an active falsehood nothing catches.

### Blind spots do not dissolve into the ticket

A ticket records two different kinds of sentence, and they are kept apart:

- **`decided`** — how the system behaves, and *who* chose it. "Email uniqueness
  is case-insensitive — by default." A question you did not answer is decided
  by the analyst's default and printed as such by the `ready` gate, on its pass
  path.
- **`verification_gaps`** — what this cycle will *not establish*. "The on-device
  path is not exercised by this suite."

They used to share a list, and therefore a keystroke: a human approved "the API
is named get/set/delete" and "the target environment is never verified" with one
click, and after that nothing referred to the second again. The pipeline had
exactly one place where it acknowledged its own blind spot, and that
acknowledgement was structurally designed to disappear.

Now the ticket files them apart: the `ready` gate prints what was decided by
default on its pass path, and a gap must say which criteria it leaves unproven.
At the end of the cycle `aif _state` re-emits the gaps, together with every
unvalidated external dependency and every test that was green at freeze, as the
ticket's **manual verification checklist** — and `aif work` puts that list in
the report beside the diff. A gap acknowledged once and
never surfaced again is the same as no gap at all.

aif never learns what "device" means. It learns that a class of statement exists
which says *"this is not verified"*, and that statements of that class are not
allowed to vanish quietly.

### How a ticket got here, drawn

The artifacts are written for gates, and it shows: a list of criteria, a list
of decisions, a list of gaps, every entry admissible and none of them saying how
it came to be. So the analyst and the stations record the chain while they
decide, in fields the gates check afterwards:

| field | in | says |
|---|---|---|
| `acceptance[].surface` | ticket | where the criterion is observed |
| `decided[].by` | ticket | `human`, or `default` — the analyst's proposal, unanswered |
| `decided[].kind` | ticket | `architecture` marks a decision that commits the project |
| `verification_gaps[].leaves` | ticket | the criteria a gap leaves unproven |
| `decisions[].because` | plan | what forced the decision |
| `decisions[].serves` | plan | the criteria it exists for |

Provenance used to be a `from` field with a verbatim fragment of the ticket,
looked up literally by a gate — needed because a separate station re-derived the
criteria from a narrative. The criteria are now written *in* the ticket, with
you, so there is nothing to trace them back to: they are the ticket.

Then `aif explain <ticket>` draws it:

```sh
aif explain TICK-1                  # → tasks/TICK-1/explain.md, mermaid
aif explain TICK-1 --format tree    # the same chain, in the terminal
```

**It runs no model and costs nothing.** That is the design, not an
optimisation: a picture of "how the agent got here" drawn *afterwards, by a
model reading the finished artifact* is a plausible story about the artifact
rather than a record of anything, and it would buy the reader a confidence no
gate had earned. This renders only fields a station wrote while deciding and a
gate checked after. It can draw nothing that was not written, and nothing it
draws is unchecked. The generated file records the `sha256` of the artifacts it
came from, so a stale drawing reads as stale rather than as wrong.

Two things are printed on the **pass** path rather than rejected, for the same
reason `plan-form` prints an unvalidated external surface: a question decided by
default rather than by you, and a plan decision that serves no criterion.
Forcing either to look settled would buy a plausible line in place of an honest
gap.

The analyst draws the ticket when it is ready, while you are still in the room,
and the orchestrator draws the plan once `plan-judge` admits it. What that is
worth in tokens is nothing; what it is worth in attention is a setting:

```json
{ "explain": { "auto": "ready" } }
```

`ready` (the default) draws when the ticket is ready, `always` also draws the
plan, `never` leaves it to you. `.aif/project.json` holds what the *repository*
does; `~/.config/aif/config.json` and `AIF_EXPLAIN=never|ready|always`
override it per developer, because "I have the budget for this" is a fact about
a person and does not belong in a shared file. None of the three can stop a
human who types the command: a setting that overrode a direct question would be
a different feature and a worse one.

### Three coverage questions of one shape

`plan-form` asks the same question about three kinds of entity, and the third is
the one that was missing:

| entity | must be covered by | otherwise |
|---|---|---|
| a criterion | a file in the manifest | rejected |
| a file the plan **creates** | a criterion — or `uncovered[]` | rejected |
| an **external dependency** | a check or a criterion | printed as a gap |

The middle row catches a blind spot by construction: a file the plan orders into
existence that no criterion points at. On a live ticket that file was the
module's public entry point; it threw on import, every consumer was broken, and
no test noticed because no criterion imported the barrel. Documentation files
normally land in `uncovered`, which is fine — the point is that the list is seen,
not that it is empty.

A fourth check is a signal rather than a rule. The plan declares `surface_map`:
one file set per surface the ticket names. Where a criterion's coverage differs
from its own surface's entry, the gate **flags it and does not reject** — a
narrower coverage is often correct — and `plan-judge` has to adjudicate each flag
as `intended` or `drift`. Only `drift` sends the plan back. The case behind it:
four criteria declared one surface and were mapped to three different file sets,
and the narrowest of them ended up pinning a standalone function in the test
runtime instead of the startup path it was written about.

### What the judge examined

`{"pass": true, "findings": []}` is the shape of a thorough pass and also the
shape of a judge that read nothing; from the artifact alone they are the same
document. Both verdicts now carry `checked[]` — one line per thing actually
examined — and on a `risk: high` ticket a verdict with an empty one is rejected.
It stays optional below high, so a cheap ticket is not taxed for a signal nobody
will read.

This catches nothing on its own. It makes an under-performing judge visible in
the artifact instead of indistinguishable from a diligent one.

### The backward transition — free, no command

Edit any upstream artifact and everything below it lapses on its own, because
every artifact binds to the hash of the one above it. Change `ticket.md` and
the plan, its verdict, and the tests all go invalid. There is no "go back" —
the derived state simply stops showing them as done. The chain is one hop
shorter than it was: the ticket is the top, and nothing sits between it and the
plan to lapse with it.

### Before the first dollar

`aif run` runs your test command once and checks a parseable report comes out of
it, before dispatching anything. `aif doctor --probe` does the same on demand.

A red suite passes this check — the question is "does the runner run and emit a
report", not "do the tests pass", which at ticket start they had better not. The
report is the discriminator: a failing suite still writes one, a runner that is
not installed does not.

This exists because on a live ticket the missing piece — a junit reporter — was
found by the *last* gate, after roughly $6.61 of stations had run and the feature
was already written. Every gate reads that report; one command establishes
whether they can.

`python3` is checked here too. Without it `verify-red` and `green` fall back to
the suite's exit code alone and cannot tell a legitimately failing suite from a
broken one. That is a warning, not a refusal: a blunt gate is worse than a sharp
one and better than none.

### When the plan could not have known

`scope` rejects any file the plan did not name. Sometimes that is correct and
sometimes the plan simply could not have foreseen it — an import pulls in a
neighbouring module, a handler only takes effect once registered somewhere.

Two things cover that, at different costs:

- **`plan-judge` looks for it first.** The judge traces what each planned change
  forces and lists files the implementation would have to edit that the manifest
  does not permit. Same defect, found before the code is written instead of after.
- **`aif _amend-plan <ID> <path> "<why>"`** is the escape hatch when it still
  happens. It writes `tasks/<ID>/plan-amendments.json`, not `plan.md` — amending
  the plan would invalidate `tests.lock.json`, which binds to the plan's bytes, so
  `green` would then reject the implementation the amendment existed to permit.

The hatch is bounded rather than trusted: it refuses test files and pipeline
paths, it refuses a file that does not exist, it is capped
(`limits.plan_amendments_max`, default 3), every entry carries a reason, and
`scope` prints the amendments on its *pass* path — a widened manifest nobody sees
is the same as no manifest. Past the cap the honest answer is that the plan was
wrong, and the ticket goes back to planning.

### What each station cost

Every station is metered. A `SubagentStop` hook reads that subagent's own
transcript, rolls up its four token classes, and appends a row to
`tasks/<ID>/ledger.json` — one row per attempt, never updated in place, because
overwriting a row is how rework disappears from a metric that exists to count it.

Tokens are the raw datum; dollars are derived from `.aif/prices.json`. **That
table ships empty on purpose.** A wrong price produces a confident figure nobody
re-checks; a missing one produces `cost_usd: null` beside a complete token count,
which is obvious and fixable. Fill it in from your provider's pricing page.

This replaced reading `total_cost_usd` off a `claude -p` envelope, and is better
in three ways: it works under subscription auth, where that field is structurally
`0`; it survives a station that failed, because the transcript is written as the
run happens rather than assembled at the end; and it is per-turn, so a station
that ground through its turn budget looks like grinding instead of like one large
number.

A station that leaves no readable transcript is recorded as `unmetered` rather
than skipped. An accounting gap that announces itself is recoverable; a silent
one just makes the total look better than it was.

`aif cost <ticket>` reads those rows back — one line per station, in pipeline
order, with attempts, turns and the four token classes. `aif cost` with no ticket
does the same per ticket, with a grand total. Both refuse to flatter: a station
whose row carries no price shows its tokens and a dash instead of a dollar
figure, a total that includes one is marked `>=`, and unmetered attempts are
counted in the footer rather than dropped. `--json` gives the same roll-up
unformatted.

Pricing happens when a station is metered, and the ledger is append-only — so
filling in `.aif/prices.json` prices later runs and never backfills earlier rows.

Nothing records a station's cost unless `.aif/hooks/meter.sh` is registered as a
`SubagentStop` hook **and is executable**. The runner execs hooks directly, and
this one is deliberately fail-open (metering must never block a subagent from
finishing), so a hook that cannot run costs you the whole accounting silently:
gate rows keep appearing and the ledger looks complete. `aif cost` names that
case explicitly when it sees gate rows and no station rows; `aif init` repairs
the mode.

### Who may write what

A `PreToolUse` hook bounds every writer in a run:

| Writer | May write | Denied |
|---|---|---|
| `aif-implement` | code the plan named | test files |
| `aif-tests` | test files | implementation |
| the orchestrator | `tasks/` and `.aif/prices.json` | code, tests, gates |
| a plain `claude` session | everything, as usual | nothing |

The orchestrator rule is the OPES-48 defect made impossible on the easy path: the
implement station exhausted its turn budget, the session finished the feature
itself, and no gate ever saw it — the commit looked like any other. Work written
outside a station is work outside every gate.

The last row matters as much as the others. The guard is active only inside
`aif run`, which marks the session; a project with aif installed is still an
ordinary project, and a plain `claude` in it is not policed.

Stated plainly: this matches the Write and Edit tools, so `bash -c 'echo … >
src/f.py'` walks past it. Matching shell commands would mean parsing shell, which
fails open in ways nobody notices. The real backstop for code is `scope`, which
rejects any file the plan did not name regardless of who wrote it; the hook exists
so the honest-but-helpful path is closed early and by name.

### What is verified, and what is trusted

Almost everything here is checked by a gate that can be re-run. Three things are
not, and saying so plainly is the point of this section — a claim of "verified"
that quietly includes these would be worth less than no claim at all.

**The criteria are the human's, not verified.** Everything downstream checks
that the code matches the ticket's criteria; nothing checks that the criteria
match the intent. That judgement is made once, in the analyst's conversation,
with the repository in front of you and every open question shown with its
default — and it is made there precisely because it is the one moment with
enough context to make it. There used to be a separate approval gate later,
where a person ratified criteria a model had derived from their narrative; that
was a ritual at the point of least context, and it is gone. "A person judged
this complete" is not machine-decidable, and this is where that shows.

**A green suite is not correctness.** `green` proves the frozen tests pass, that
the project's own checks pass, and that reverting the implementation makes the
covering tests red again. It cannot prove the tests were the right tests. The
oracle is only as good as the criteria it came from, which is why they are
written with you, before anything runs.

**An external dependency behind a fake is not verified by anything here.** The
plan's `external` list makes that visible and nothing more: an entry with no
check and no criterion is printed at the gate and re-emitted at close as a manual
task. Naming a blind spot is not closing it — it only means nobody can say
afterwards that they did not know.

**At the code boundary, "passes now" weakens to "passed, against an unchanged
plan".** `green` and `scope` are both relative to a baseline that the accepting
commit moves: after it, reverting no longer removes the implementation and there
is no diff left to scope. Their recorded verdicts bind to `plan.md`, so a changed
plan invalidates them — but editing the source afterwards does not re-open the
gate. Nothing cheap fixes this; the evidence a revert-recheck needs is destroyed
by the commit that preserves the work.

**The plan boundary is recorded for the same reason.** `plan-form` asserts that
every `files.create` path does not exist *yet* — a premise the implement station
is later paid to falsify. So the plan gates run once, at plan time, and the
recorded pass holds while the plan's bytes and its `ticket_sha256` binding
hold. Editing the ticket still lapses the plan automatically; finishing the
ticket no longer invalidates the plan that shaped it.

### Offline, no tokens

```sh
bash scripts/demo.sh        # the whole pipeline on hand-written artifacts
make lint                   # shellcheck everything
make check                  # the CLI under bash 3.2, plus the set's own assertions
```

`scripts/demo.sh` runs every gate against known-good and known-bad artifacts,
including the attacks: an implementation that adds itself to the plan, a ticket
with a question still open, tests that stop depending on the code, a required
check that fails, and a freeze that does not hold the ticket's own oracle.
`scripts/check-cycle.sh` walks a rework over a finished round;
`scripts/check-work.sh` drives the worker end to end through a scripted runner.
No model is called by any of them.

## Requirements

- **bash 3.2+** — what stock macOS ships. No Homebrew bash needed.
- **jq** — a system binary on macOS 14+; `brew install jq` elsewhere.
- **At least one runner**: `claude` today, `codex` next.

Run `aif doctor` to see what you have.

## Development

```sh
make check   # run the CLI under /bin/bash (3.2) explicitly
make lint    # shellcheck
```

`aif` targets bash 3.2, which means no associative arrays, no `mapfile`, and no
`${var,,}`. `make check` runs the entry point under `/bin/bash` on purpose, so a
newer bash on `PATH` cannot mask an incompatibility.

## Roadmap

- [x] CLI skeleton, `aif doctor`
- [x] Profiles — `anthropic` and `glm`, user-extensible
- [x] Eval harness + L0 smoke, with pass rates and cost tracking
- [x] `aif init` — profile picker, non-clobbering merge, ownership manifest
- [x] `aif uninstall` — reverse the manifest, value-guarded
- [x] The gated cycle: ready → plan → tests → code, six gates
- [x] `/aif-ba` — the analyst writes the criteria with you; `aif _ready` is the one Definition of Ready
- [x] `aif work` — one ticket, one worktree, one budget, no questions
- [x] The board — `aif board` over `local` and `trello`, `/aif-pjm` as its policy, `aif secret`, `aif doctor` per role, `/aif-setup`
- [x] `aif run` — the same cycle in a visible session, stations as subagents
- [x] Per-station metering from subagent transcripts, into a hash-chained ledger
- [x] `aif explain` — the provenance chain behind a ticket, rendered, at no cost
- [ ] Fill `prices.json` — tokens are recorded, dollars need a table
- [ ] Fixture-level evals (a real repo, a real oracle) + guardrail evals
- [ ] `local` profile via `llama-server`, plus a profile preflight hook
- [x] Homebrew formula and tap — `Namdurash/homebrew-tap`
- [ ] `sets/codex/`

## License

MIT
