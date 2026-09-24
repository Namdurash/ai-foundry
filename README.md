# AI Foundry (`aif`)

Put an existing project on AI SDLC rails. You run `aif init`, pick a profile,
and the native config for that agentic coding CLI lands in your repo — agents,
skills, and context files, ready to drive.

> **Status: early, but the machine is whole.** The analyst writes a ticket's
> criteria with you; one command then builds it headless through three stations
> and five gates, metered per station, and never asks a question. It has been run
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

**Upgrading is one command.** `aif init` again: it updates what the set still
ships and **retires** what it no longer does — the old gates, skills and slash
commands of a previous version — value-guarded, so a file you have edited is
kept, named, and still tracked (so `--force` can take it later). Without that
an upgrade leaves the old files on disk *and* drops them from the manifest, so
`aif uninstall` could never remove them: measured on a real 0.4.2 → 0.5.0
upgrade as eleven orphans, three of them slash commands still pointing at a
pipeline that had been deleted. `.aif/project.json` is yours and is never
touched.

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
`aif work` time instead. See `docs/FINDINGS.md`.

### Running it

```sh
aif work                     # build the top of the board's Ready column
aif work TICK-1              # …or this one, headless, on its own branch
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

One thing to know about those worktrees: they are complete checkouts *inside*
the repository, and git hiding them does not mean your test runner will. A
runner that globs from the project root will collect every suite twice — once
real, once from a worker's copy — and report failures that belong to no ticket.
`aif doctor` detects it from the suite's own output and refuses, which means
`aif work` refuses before spending anything, and prints the pattern to add.
Anchor that pattern (`<rootDir>/.aif/worktrees/`, or a rootdir-relative path):
a bare `.aif/` also matches when the suite runs *inside* a worktree, which is
where the gates run it, and a worktree that excludes its own tree finds no
tests at all.

**A run always has two caps and optionally a third.** The two that always
apply are the wall clock (`limits.run_max_minutes`, 120) and the dispatch cap
(`limits.run_dispatches_max`, 12 station runs) — both counted by the worker
itself, so both always hold. The third is a dollar ceiling, and it is **off
unless you ask for it**: pass `--budget 5`, or set `limits.run_budget_usd` to
a number (`null` or absent means no ceiling; `--no-budget` turns off one the
project sets).

Off by default because a ceiling that cannot fire is worse than none. Spend is
the larger of the runner's own `total_cost_usd` and what `.aif/prices.json`
prices the same tokens at — and under subscription auth the first is `0`
(`docs/FINDINGS.md` #2) while the table ships empty on purpose, so on the
commonest setup the total stays `0.0000` and no ceiling is ever crossed. It
read as a guarantee and was not one. Before relying on a ceiling, put your
model in `.aif/prices.json` and check the report's Stations table: a row
saying `tokens only` is a row contributing nothing to the total.

None of the three interrupts a station mid-flight — the current `claude -p`
always finishes and the worker stops before the next one, so a ceiling is
"stop past this", not a hard stop. When a ceiling is set, each station is also
invoked with `--max-budget-usd` carrying what is left of it; with no ceiling
the flag is not passed at all.

Two smaller things, each learned the hard way. **A station
that commits is still judged on what it did**: the worker records HEAD before
every dispatch, and `scope` and `green` diff and revert against that baseline
rather than "the last commit", which after a station's own `git commit` would
have been its own. The guard hook refuses the obvious `git commit` spellings
from a station as well, and fails open on cleverer ones by design. **And
`--no-worktree` is refused unless the checkout is declared disposable** — it
runs every station with `bypassPermissions` *here*, so it wants `CI=1` (a CI
job already has it) or `AIF_DISPOSABLE=1` from you.

**And a fresh worktree holds tracked files only.** `git worktree add` brings
nothing git ignores — no `node_modules`, no `vendor/`, no `.venv` — and a
runner that needs them dies before it runs a test, let alone writes a report.
So `.aif/project.json` has `"prepare"`: a shell command (`npm ci`, `bundle
install`) the worker runs once in each worktree it cuts, then the suite is
probed *there*, where the stations will run, before anything is spent. A
checkout that cannot run the suite is refused, not built against. The jest
template ships `"prepare": "npm ci"`; add yours to a project set up before the
field existed. The worker reads it from your checkout's config, not the
branch's, so adding it after a refusal works without re-cutting the worktree.

`aif work` is the entry point for anything other than your default provider.
Routing is applied by exporting into the child process, so **a bare `claude` in
the project is not on the profile's model** — it uses whatever the project
already had. That is deliberate: the alternative is a routing setting that might
be ignored, which puts you on a model you did not choose without telling you.

The same export is how each station gets its engine: a station's agent file
declares `model: opus`, and the profile decides what `opus` resolves to
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

Or, to run **this clone** rather than the tap — which is what you want while
developing it:

```sh
cd /path/to/ai-foundry
make link      # symlinks bin/aif onto PATH, and brew-unlinks the tap first
make unlink    # and back
```

The tap and a clone install the same command name. `make link` says which one
you end up with and prints the version, because the failure mode otherwise is
silent: you edit the clone, type `aif`, and run the tap's older copy.

### Once, per project

```sh
aif init              # install the set, pick a profile
aif project init      # detect the runner, and ask what "done" means here —
                      # then REVIEW .aif/project.json, especially test.command
aif doctor --probe    # which ROLES can run here — analyst, project manager,
                      # worker — and what each is missing. --probe is the only
                      # form that ASKS: it runs your test command once and
                      # calls the runner once. Without it a capability that
                      # was not asked about reads "?", never "✓"
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

### Before the ticket — the product partner

**`/aif-po`** is a thinking partner, not a form: what is wrong today, who feels
it and how often, what should be true after, what is the *smallest* version that
changes that, what is deliberately out. It pushes back where a request arrives
larger than its problem, and it says plainly where the machine's tests will not
prove correctness — money, auth, concurrency, a real device.

It writes `requests/<slug>.md` and stops. It does **not** write criteria, does
not read the codebase, and decides nothing: feasibility is the analyst's, and a
product decision made quietly is one nobody made. `requests/` sits beside
`tasks/` and is committed — it is the record of *why* the work exists.

Five minutes or an hour; the user decides when there is enough. This is the one
part of the foundry with no gate and nothing downstream that can be lied to,
which is deliberate: it is the thinking, and thinking does not pass a lint.

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

### When a gate rejects

Nothing opens a conversation. The worker hands the gate's complaint back to the
same station, verbatim, in the next prompt, and lets it try again — up to
`limits.attempts_max`. A station that will not converge stops the run, and the
report says which stage, how many attempts, and what the gate said last.

That is the whole repair mechanism, and it replaced a skill (`/aif-fix`) that
split complaints into *mechanical* and *structural* and took the second kind
back to you mid-run. The split was real; the cost was that every rejection
became a conversation. What survives it is the rule it existed to enforce —
**never make a gate pass by making the artifact worse** — which is now
structural rather than advisory: the `ready` gate is the only one that can be
satisfied by saying less, and it runs before the run starts, with the analyst
and you.

A rejection that is really the ticket's fault surfaces as a stopped run, and it
goes back to `/aif-ba`.

### A ticket, in order

```
Ticket ── ready ── plan ── tests ── code
           gate     gate     gate     gates
```

```sh
aif work                            # the top of Ready: ready → plan → tests → code
aif work TICK-1                     # …or this ticket, headless, on aif/TICK-1
```

**One command, and there is no command per stage.** `aif work` is the worker:
it reads the run record for the stage, dispatches that station as `claude -p`
with the station's own prompt, stamps the binding with `aif _record`, judges the
output with `aif _gate`, commits what was admitted, and retries a rejection with
the gate's complaint in the prompt. Each station's own account of what it did is
kept in `tasks/<ID>/stations/` and committed — the orchestrator this replaced
wrote that to a temp file and deleted it.

Run it twice and it **resumes**. The run record says which stage was reached,
and it is bound to the ticket's bytes at intake: unchanged, the run picks up
where it stopped; changed, it starts over, because a plan made for an older
ticket no longer answers the question. That one comparison replaced a hash
cascade that lapsed backwards through five artifacts.

No model decides what runs next. The stage order is a list in bash
(`lib/run.sh`), each station declares the gate that checks it, and the worker
obeys both — if "what runs next" were the model's judgement, the pipeline would
have opinions where it needs preconditions.

- **The ready gate always runs first.** A ticket that is not ready — an open
  question, a criterion with no literal, the scaffold stub — stops the worker
  at intake with the gate's own lines in the report, and nothing is spent.
- **A rejection is a retry, not a conversation.** The worker hands the gate's
  complaint back to the station, up to `limits.attempts_max`; a station that
  will not converge stops the run with a report saying so.
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
| `aif cost [ticket]` | what the pipeline spent, per station, from the ledger |
| `aif explain <ticket>` | draw how it got here — criteria, decisions, gaps, and the plan's reasoning |
| `aif test <eval> --profile <p>` | run an eval, N times, with a pass rate |

There is no command per stage. The worker and the skills call a small internal
surface (`aif _gate`, `_record`, `_commit`, `_ready`, `_ticket-init`,
`_amend-plan`, `_meter`) that is not listed in `--help` — it is an interface
between two parts of aif, not something to learn. Each one is something a model
must not decide or must not carry: `_record` writes the hash a station was once
asked to copy, `_gate` renders and records a verdict, `_ready` is the one
Definition of Ready the analyst and the worker share.

### Stations and their model tier

| station | tier | produces | its gate(s) |
|---|---|---|---|
| *(the ticket)* | — | `ticket.md`, by the analyst with you | ready |
| `plan` | careful (opus) | `plan.md` | plan |
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

`1` versus `3` is the difference between "your plan has a blocker" and "the repo
was already broken". The worker retries a `1` with the gate's complaint in the
prompt; it stops on a `3`, because editing the artifact cannot fix the
environment. `verify-red`: a real failing test is
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
At the end of the cycle the report re-emits the gaps, together with every
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
reason the plan gate prints an unvalidated external surface: a question decided by
default rather than by you, and a plan decision that serves no criterion.
Forcing either to look settled would buy a plausible line in place of an honest
gap.

The analyst draws the ticket when it is ready, while you are still in the room,
and you can draw the plan yourself once it is admitted. What that is
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

The plan gate asks the same question about three kinds of entity, and the third
is the one that was missing:

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

There used to be a fourth, and a whole station to adjudicate it: the plan
declared a `surface_map`, the gate flagged a criterion whose coverage differed
from its surface, and a `plan-judge` station decided each flag as `intended` or
`drift`. It is gone, with the rest of the form lint. What judges a plan now is
the **outcome** — tests that will not go green, or a diff that leaves the
manifest — and either sends the run back to the plan station inside a budget.
That is cheaper than a second model reading the first one's prose, and it
cannot be satisfied by agreeing.

### The backward transition — free, no command

Edit any upstream artifact and everything below it lapses on its own, because
every artifact binds to the hash of the one above it. Change `ticket.md` and
the plan, its verdict, and the tests all go invalid. There is no "go back" —
the derived state simply stops showing them as done. The chain is one hop
shorter than it was: the ticket is the top, and nothing sits between it and the
plan to lapse with it.

### Before the first dollar

`aif work` runs your test command once and checks a parseable report comes out of
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

- **`aif _amend-plan <ID> <path> "<why>"`** is the escape hatch. It writes `tasks/<ID>/plan-amendments.json`, not `plan.md` — amending
  the plan would invalidate `tests.lock.json`, which binds to the plan's bytes, so
  `green` would then reject the implementation the amendment existed to permit.

The hatch is bounded rather than trusted: it refuses test files and pipeline
paths, it refuses a file that does not exist, it is capped
(`limits.plan_amendments_max`, default 3), every entry carries a reason, and
`scope` prints the amendments on its *pass* path — a widened manifest nobody sees
is the same as no manifest. Past the cap the honest answer is that the plan was
wrong, and the ticket goes back to planning.

### What each station cost

Every station is metered from its own `claude -p` envelope: four token classes,
a turn count and the model that actually ran, appended as a row to
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
| a plain `claude` session | everything, as usual | nothing |

The last row matters as much as the others. The guard binds to a **station**,
not to a session: a project with aif installed is still an ordinary project, and
a plain `claude` in it is not policed. There used to be a third rule — an
orchestrator session may not write product code — which existed because a
session dispatched the stations while a human watched, and once finished a
feature itself after a station ran out of turns. There is no such session now;
the worker is a subprocess and the only writers are stations.

Whether the hook fires at all inside a worker run is **unverified** — the
stations run under `--permission-mode bypassPermissions`, and no probe has yet
watched it deny one (`docs/FINDINGS.md` #12). `scope` and `green` are the
backstops either way.

Stated plainly: for files this matches the Write and Edit tools, so `bash -c
'echo … > src/f.py'` walks past it. For Bash it matches one thing — `git commit`,
`reset`, `stash` and the like at a command position — because a station that
commits moves the baseline under the gates, and it deliberately does not try to
match anything cleverer: parsing shell fails open in ways nobody notices. The
real backstop for code is `scope`, which diffs against the baseline the worker
recorded at dispatch and rejects any file the plan did not name regardless of
who wrote it or what they committed since; the hook exists
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

**And a skipped test is not a passing one.** `green` is strict about the tests
*this ticket* froze — a skip there is red made to go away without implementing
anything, and it is a rejection. It is deliberately **not** strict about the
rest of your suite: a platform guard, an `importorskip`, a slow marker are
ordinary, and `verify-red` allows them at the other boundary. What it still
catches is a pre-existing test that was *passing* when the tests were frozen
and is skipped now — the implementation cannot edit a test, but it can change
source until one stops collecting. `verify-red` records the rest of the suite's
status in `tests.lock.json` so the two can be told apart, and green prints how
many it allowed on its pass path, because a test that did not run is a
criterion nobody exercised whoever skipped it.

**A report is evidence, not testimony — and the gates now treat it that way.**
Every verdict here rests on the junit report the project's `test.command`
writes, and a report can be silent about a suite that failed to *run*: a junit
reporter emits one `<testcase>` per test, so a file that does not compile
contributes none, and jest-junit emits no failing `<testsuite>` for it either.
Read alone, such a report says "everything passed" about a run that plainly did
not. So it is cross-checked against the runner: a non-zero suite whose own
report names nothing failing is neither a pass nor a rejection but a gate that
cannot render a verdict, and the run stops. The two gates also delete the
previous report before running, so a command that never reaches its reporter
cannot be judged on the last run's file — and a suite that writes *no* report
is not a weaker red, it is no run at all: an ERROR in both gates, and the
freeze never happens. Coarse mode is only for a report that exists and cannot
be read per test.

**Coarse mode is a real downgrade, and it now says so out loud.** Without a
readable per-test report the gates fall back to the suite's exit code alone,
which cannot tell a legitimate failure from a broken one. `verify-red` still
matches the project's `failure_classes.broken` against the run's output there —
a suite that did not compile is not usable red, whatever its exit code — and
records *why* it degraded in `tests.lock.json` as `mode_reason`: no python3 on
PATH (with the PATH), no report at the declared path, or a report the parser
could not read. A coarse freeze also names no covering test, so `green`'s
revert-recheck has nothing to target; it now reports that it did not run
instead of printing the sentence it prints when it did.

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

**The plan boundary is recorded for the same reason.** The plan gate asserts that
every `files.create` path does not exist *yet* — a premise the implement station
is later paid to falsify. So the plan gates run once, at plan time, and the
recorded pass holds for the life of the run. A ticket edited between runs does
not lapse it artifact by artifact — it restarts the run, which is the one
comparison that replaced the cascade.

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

### Releasing

A release is the tag **and** the tap. `aif` is installed with
`brew install Namdurash/tap/aif`, so a tag the formula does not point at is a
version nobody can install — `brew upgrade` goes on handing out the previous one
and says nothing about it. 0.5.0 shipped that way for two days.

```sh
make release V=0.5.1
```

That bumps both version markers (`AIF_VERSION` and `SET_VERSION` — the bottle is
a CLI-and-set pair and the formula's own test asserts they agree), runs lint and
check, commits, tags, pushes, then points `Namdurash/homebrew-tap` at the new
tarball and pushes that too.

GitHub only builds the tarball once the tag is pushed, so the two halves cannot
be simultaneous. Every step is therefore idempotent: if it stops in between, run
the same command again and it resumes at the first thing that did not happen.
`make check` ends with `scripts/release.sh --verify`, which is silent while a
version is unreleased and fails the moment a tag exists that the tap does not
serve.

Never `git tag` a release by hand.

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
- [x] Per-station metering from each station's envelope, into a hash-chained ledger
- [x] `/aif-po` — the product partner, and `requests/` as what the analyst cuts from
- [x] `aif explain` — the provenance chain behind a ticket, rendered, at no cost
- [ ] Fill `prices.json` — tokens are recorded, dollars need a table
- [ ] Fixture-level evals (a real repo, a real oracle) + guardrail evals
- [ ] `local` profile via `llama-server`, plus a profile preflight hook
- [x] Homebrew formula and tap — `Namdurash/homebrew-tap`
- [ ] `sets/codex/`

## License

MIT
