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
pipeline that had been deleted. The hook registration in `.claude/settings.json`
is refreshed the same way, event by event: an entry whose every command runs
from `.aif/hooks/` is ours and is replaced by what the set ships now, yours stay
beside it — a project initialised before the guard matched `Bash` kept that
matcher through four upgrades, and its guard never saw a shell command
(`docs/DEFECTS.md` 8.2). `aif init --dry-run` previews all of it.

`.aif/project.json` is yours and is never touched by `aif init`. But some of
what it holds is aif's opinion, and that opinion moves: which failure classes
count as a legitimate red (with the contract, a `TypeError` is the test's own
defect), which phases a type-check binds to, the caps the stage runs under. So
`aif project check` and `aif doctor` say what has moved since the template the
file was made from, the worker says so once per run, and `aif project upgrade`
brings exactly those fields forward — the template's answers first, your own
additions kept — and leaves the test command, the roots, the checks' commands
and the board as they are.

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

The whole cycle, drawn from the code and checked against it on every `make
check`: [docs/CYCLE.md](docs/CYCLE.md) (`make cycle` redraws it).

```sh
aif work                     # build the top of the board's Ready column
aif work TICK-1              # …or this one, headless, on its own branch
```

`aif work` is the worker: one ticket, one git worktree (`.aif/worktrees/TICK-1`
on branch `aif/TICK-1`), one budget, and **no question at any boundary**. The
ticket's bytes are hashed and committed at intake and stay frozen for the run;
every station runs as `claude -p` with its own prompt and tools; every gate
verdict is recorded; a rejection is retried with the gate's complaint in the
prompt, up to the station's attempts cap (`limits.attempts_max`, three; the
tests station declares four in its `aif:meta`), and a station that will not
converge stops the run with a report rather than a conversation. What comes back is
`tasks/TICK-1/report.md` — what was built, what was decided, what was not
verified, what it cost — beside the diff, which is the one place a reviewer has
enough context to judge it. Run several tickets at once: each gets its own
worktree, and one ticket gets one worker — a second `aif work` on a ticket already
being built is refused before it touches anything. `aif work TICK-1 --stop`, from any
terminal, ends that run the way its own Ctrl-C would — and so does the terminal
closing over it, the card saying so. The offline walk of the whole thing is
`scripts/check-work.sh`.

**The queue drains, and the yes is one command.** `aif work --loop` builds the cards
in Ready, two at a time (`--parallel N`; one with `--no-worktree`), each in a worktree
of its own, until the column is empty (`--max-tickets N` to stop sooner) — or, with
`--idle`, does not end there: it looks at Ready again every 30 seconds and takes
what comes, a card that came back included. One loop per checkout: a second is
refused by the loop lock (`.aif/state/loop/`) before it probes anything. Workers
start one after another, each once the last one's worktree is ready, so installs do
not run side by side. A run that cannot start — the environment, not the card — has
the machine checked again: the loop goes on while its preflight passes, and takes
no new card when that fails or at the third such run in a row, so a machine that
cannot run anything costs at most three cards. It takes no new card after two that
did not build, because two cards in Needs Human usually mean the problem is not the
cards. While the account's usage limit pauses its workers it takes no new card either
— the dashboard says until when — and goes on once the limit resets; a limit with no
reset within 12 hours stops it, naming the limit. Ctrl-C takes no new card and lets
the runs in flight finish; Ctrl-C again stops them, each card saying so — and from
any terminal, `aif work --loop --drain`
does the first and `aif work --loop --stop` the second, each card saying who. A
`--stop` on one run is not held against the cards, and its slot takes the next.
Each worker's output is in `.aif/tmp/loop-<when>/<ID>.log` — `<ID>.2.log` for a
second take of the same card, and so on — or under `AIF_WORK_LOOP_LOGDIR`, when it
names a directory, and `summary.json` beside the logs says how the loop ended: what
it took, built, blocked and stopped, each run with its log, and why it took no more;
the exit code says how the process ended, not what Ready still holds, so whatever
started the loop reads the file — an exit 3, the environment, comes only once the
machine was asked again: the loop's own preflight failing too, or three runs in a
row that could not start, or three reads of Ready. A card whose run ended with it
still in Ready — a worker that stopped before
taking it, or refused to take over a dead run whose processes still run — is held:
the loop does not take it again, says so, and names it with why in its lock
(`owner.json`), where `aif start` in another terminal reads it instead of waiting
on the card. On a terminal the loop draws a
dashboard — itself in the middle, each worker around it with its ticket, station and
attempt, model, progress and last verdict, joined by a line whose colour is that
worker's state — and takes keys: `1`–`9` select a worker, `s` stops it (after a
`y`), `l` shows its log, `q` takes no new card. Anywhere else, or with `--no-tui`, it
prints a line per start and per end. Either way it ends with a summary and the
`aif land` for each built card. `/aif-review` prepares the human's three-minute review of a card in Review —
per criterion the test that proves it, what the run did not establish, what to look
at first — and takes the verdict. On *land*, the product partner gives the demo
before anything merges: in a fresh context it holds the build to the request it came
from, and when it says *as expected* the review runs `aif land <ID>` itself; when it
does not, its reasons go on the card for `/aif-pjm` to route, and you can still land
over it in your own terminal. `aif land <ID>` is the yes: it merges the branch onto
your checkout's branch in the ticket's own worktree, judges the *result* there,
fast-forwards your branch to it, moves the card to Done, removes the worktree and the
branch, and releases the tickets whose `depends_on` names it from Backlog to Ready —
which is how a request's slices flow without the project manager touching each one.
Your own uncommitted work stays as it is, staged or not, unless the land changes those
very files: then it refuses, naming them, and touches nothing. On Trello it refuses too
a card whose text changed after its build — the branch is a build of the text before —
naming `aif work <ID>`, and the shift offers no land of it. The verdict is the
worker's own when it judged that very tree — the target moved only in `tasks/` or
`requests/` since, under the same test command and checks — and otherwise the suite
and the checks bound to green run in the worktree, where the worker installed what
the branch pins and `prepare` installs what the merge moved against it. A conflict in
aif's own files is settled by owner, with no model: the ticket's record under
`tasks/<ID>/` is the branch's, the set under `.aif/` and `.claude/` is your checkout's,
and the analyst's uncommitted copy of the ticket is taken aside to `.aif/tmp/` instead
of stopping the fast-forward — the land note says which. A conflict in code, or a red
on the result — the suite or a check — lands nothing and sends the card back to the
top of Ready with a `sync:` comment — but not a test or a check red on your branch
before this ticket, nor a test that fails once and passes on a re-run: the land runs a
failing test once more and looks for the failure on your branch as it found it, and
lets those through, named on the landing note, as the worker's gates do. The worker brings the branch onto yours in its
worktree — the conflicts settled by the implement station, the merged tree judged
again by green and scope — and the card comes back to Review, to be looked at again.
When the station cannot settle it, or a test file is in conflict, the ticket is built
again from your branch, automatically; the first build is kept under
`refs/aif/archive/<ID>/<n>`. Every run does the same before it reports built, so what
reaches Review merges clean into the branch it was cut from. The land's merge commit
is the one commit of aif's that runs your git hooks — the worker's own skip them — so
a pre-commit that refuses it is a `land:` line for you, nothing landed. Nothing is
installed in your checkout unless you ask: `--prepare` runs `prepare` (`npm ci`) here
after the fast-forward, when the land moved a manifest or a lockfile, and a failure
there is said on the landed card. A land stopped before its fast-forward — Ctrl-C, a
TERM, the terminal closing over it, an error on the way — has landed nothing and
leaves the card in Review, since a stop decides nothing; the fast-forward itself runs
where neither a session's Ctrl-C nor the KILL after it reaches — no process of the
land's group or under it — and a land killed outright, or a fast-forward whose git
did not finish, is put back, or finished, by the next `aif land` (`aif doctor` names
it); the land says that nothing landed only when your checkout shows it.

**The shift: your half of the board, one session at a time.** The loop builds;
everything around it — the review, the analyst on what came back, the product
partner — is a session with you. `aif start` opens them for you, one after
another, in your terminal, while the loop builds in another:

```sh
aif start --dry-run          # what the shift would do now — touches nothing
aif start --no-build         # here: the reviews, the analyst, the owner
aif work --loop --idle       # …and in a second terminal: the builds
```

Either may start first: while Ready holds cards and no loop runs, the shift
waits for one, naming the command. Ending the shift leaves the loop running —
`aif work --loop --drain` ends the night.

Review comes first: each built card opens as `/aif-review <ID>` in claude, and
the next is offered once that session ends. Then the analyst, on what came back
— a rework, a `blocked: ticket`, a request with slices left to cut while the
build has fewer than three rounds ahead of it — and the owner when a request
needs cutting into slices first (`--po` opens `/aif-po` when nothing else is
left). The board moves on its own only on fixed first lines: `wrong:` goes back
to Backlog as `rework:` for the analyst, `cancel:` to Done, a slice whose
dependencies have landed to Ready, and a `blocked: environment` posted during
the shift (or stamped in the two minutes before it, said so) back to Ready once
the preflight passes again — on a shared Trello board only a block this
checkout's worker posted. It also finishes, without
asking, what a worker on this machine left half-done: a built run's report and
its move to Review, a stopped run's `blocked:` line and its move to Needs Human,
a `rework:`, `cancelled:` or landed card's lost move. Everything else is a line
with the command that would do it; a stopped run is never put back in Ready
behind your back (`--retry-runs` retries one an instrument stopped, once a
shift, and not one blocked twice in a row — on Trello read back past the replies
under the block before it). Each unit waits at a control point — `next: review AIF-61 — built,
branch aif/AIF-61 — Enter: open · s: skip · p: pause · q: end the shift (10)` —
and after the countdown acts on its own where acting is safe — a review opens; a
card whose worker died has what it left running sent a TERM and goes to the top
of Ready; a demo `not as expected` goes back to Backlog as `rework:` — and
leaves what is not: a land, a pull from Backlog, a person's answer under a
block. Any other key pauses, so a countdown never acts after a keypress, and
keys typed on a Ukrainian or Russian layout count as the Latin ones in their
place. A session that changed nothing — on its card, the board's cards,
`requests/` or `tasks/` — pauses the shift instead of opening the next one: an
absent person, a double Ctrl-C and a usage limit all end a session the same way
(`docs/FINDINGS.md` #28). While the loop in the other terminal builds and
nothing is yours, the shift waits, looking again every 30 seconds. Ctrl-C inside
a session is the session's; between them it ends the shift. Ctrl-Z does nothing
inside a shift: a session it suspends is continued within a second (`/exit` ends
a session). The end says what was done, what is left with the command for each,
and `claude --resume <uuid>` for every session it opened — by uuid, because
claude's own hint resumes by name and two reviews of one card share it.

The analyst and the owner run on `opus` and the reviewer and the project manager
on claude's own default, unless `--model-ba`, `--model-po`, `--model-review`,
`--model-pjm` or `--model` say otherwise; an alias your profile does not route is
refused before anything opens. Your own defaults go in `.aif/start.local`
(`MODEL_BA=opus`, `PARALLEL=3`, `WAIT=20`, …; gitignored by `aif init` — in a
project set up before the shift, `aif doctor` names the line its ignore block
lacks, and your next `aif init` adds it). Without
`--no-build` the loop runs in the shift's own terminal when Ready holds cards,
and is held — not restarted — when it stops on two runs that did not build, a
stop or a drain: while Ready still holds cards the control point offers *build
again*, its default to leave it, Enter or `b` to build.
`aif work --status [<ID>]` says what this machine knows of a run, offline: its
lock and whether its worker is alive, what a worker killed outright left running,
its worktree, branch and record. The shift reads it, and a card whose worker is
gone mid-run goes back to the top of Ready on the countdown, after the shift
sends a TERM to what it left running — and stays put, with `aif work --status`
as its line, if any of it outlives 30 seconds. What a dead worker left is what
its process group, its station's pid (kept in the run lock) and this clone's
worktree name — never a station of another checkout building the same id. The
next `aif work` on such a card does the same before it takes the lock over,
and refuses with exit 3, naming what still runs, rather than build beside it;
a run taken over three times stops instead (`blocked: run`), for someone to
read before another worker dies the same way.

A worktree reads everything about aif — the stations, the gates, the hooks, the
fragments, the guide, `project.json` — from its own branch, and `aif init`
upgrades only the checkout it runs in. So before a run the worker brings the
branch up to the checkout's set, in a commit of its own that names both
versions, and a run that had stopped under the old set restarts rather than
resuming the plan the old set wrote (`docs/DEFECTS.md` 9.1). A restart of any
stopped run — the ticket reworked after a spec stop, say — puts the tree back
to where that run started, so a stopped plan's half-written skeleton is not
read as the repository by the next one (10.3); a run that built is left as it
is, and the next round builds on it.

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
(`limits.run_dispatches_max`, 16 station runs) — both counted by the worker
itself, so both always hold. The third is a dollar ceiling, and it is **off
unless you ask for it**: pass `--budget 5`, or set `limits.run_budget_usd` to
a number (`null` or absent means no ceiling; `--no-budget` turns off one the
project sets).

Off by default because a ceiling that cannot fire is worse than none. Spend is
the larger of the runner's own `total_cost_usd` and what `.aif/prices.json`
prices the same tokens at — and under subscription auth the first is no charge
at all: older CLIs reported `0`, and claude 2.1.226 reports what the tokens would
cost at API prices, an estimate (`docs/FINDINGS.md` #2), while the table ships
empty on purpose. So on the commonest setup the total is either `0.0000` or an
estimate the subscription never bills, and a ceiling read off it was never a
guarantee. Before relying on a ceiling, put your
model in `.aif/prices.json` and check the report's Stations table: a row
saying `tokens only` is a row contributing nothing to the total.

None of the three interrupts a station mid-flight — the current `claude -p`
always finishes and the worker stops before the next one, so a ceiling is
"stop past this", not a hard stop. When a ceiling is set, each station is also
invoked with `--max-budget-usd` carrying what is left of it; with no ceiling
the flag is not passed at all.

**A usage limit pauses; it does not stop.** A station that the runner cut
off is not the station's attempt, and nothing bills it to the station. The
worker reads each station's stream (`--output-format stream-json`): when the
account's usage limit refused it and names a reset within 12 hours — any
five-hour window, a weekly reset that falls in the night — the worker writes
the pause to `.aif/state/pause` and waits it out, a second at a time, then
dispatches the same attempt again; every other worker on the checkout waits
on the same file before its next station, the loop takes no new card until
the pause is over (its dashboard says until when), and the shift opens no
session and no build meanwhile. The wait is outside the wall clock, and the
report says how long it was. `rm .aif/state/pause` lifts it by hand. A limit
that names no reset, or a later one, stops the run `blocked: environment` with
the reset named, and the loop with it; a weekly limit of one model holds only
the stations that ask for that model. A runner that did not answer — no
output, output that is not JSON, the server's throttle (whose words say "not
your usage limit"), an overload — is asked again after 1, 5 and 15 minutes,
uncounted and outside the clock, then `blocked: environment`, which the loop
reads as the machine. Each wait is in the run record's `runner_waits`, with
what the stream said.

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
It runs again after any station that changes a dependency manifest or its
lockfile, from the lockfile, before a gate reads the suite — see
[Dependencies](#dependencies-the-manifest-and-its-lockfile-together).

`aif work` is the entry point for anything other than your default provider.
Routing is applied by exporting into the child process, so **a bare `claude` in
the project is not on the profile's model** — it uses whatever the project
already had. That is deliberate: the alternative is a routing setting that might
be ignored, which puts you on a model you did not choose without telling you.

The same export is how each station gets its engine: a station's agent file
declares `model: opus`, and the profile decides what `opus` resolves to
(`glm-5.2` on the `glm` profile). The set stays model-agnostic while a station
still says how much engine it needs. A profile that routes to another endpoint
maps each alias it serves — `ANTHROPIC_DEFAULT_OPUS_MODEL`, `_SONNET_`, `_HAIKU_`
and `_FABLE_` — and a station asking for an alias it leaves unmapped, in any case
(`Fable` is `fable`), is refused before its card is taken.

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
aif project guide     # write .aif/guide/tests.md from the repository — where the
                      # tests, fixtures, doubles and factories live, what the
                      # tests import — for the stations to read; finish its one
                      # human section (or let /aif-setup), then COMMIT it
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

**`/aif-po`** is a thinking partner with a spine. It takes the problem before the
solution — says back what is wrong today and gets a yes — proposes a *smaller* version
than the one you brought and asks what it misses, and cuts one outcome into **slices**
that each ship, and are useful, on their own. It writes nothing until the request clears
a short bar: what is wrong now, who feels it and how we know — a count, a complaint, your
own use, or a guess said as one — one observable *After* with no mechanism in it, ordered
slices with the core first, at least one thing that is not included, and one concrete
thing that would make it not worth doing. Say "write it as is" and it writes anyway, with
what is still soft under *Open* instead of a blank.

It writes `requests/<slug>.md` and stops; the analyst takes one slice per ticket. It does
**not** write criteria, does not read the codebase to decide what to want, and decides
nothing: feasibility is the analyst's, and a product decision made quietly is one nobody
made. What it does read, before it says a need back, is what the product already is:
`aif rules` over the need's words — the rules of every ticket, built or in flight — and
the requests not yet cut. So a need a Done ticket already meets, one a ticket in flight
is about to change, or one a request's slice already covers comes up in the first
exchange, not as a second request. `requests/` sits beside `tasks/` and is committed — it is the record of *why* the
work exists. Give it an existing request (`/aif-po requests/<slug>.md`) and it holds that
to the same bar and reworks only what fails — including requests written before slices
existed.

**The demo.** The ticket is the analyst's reading of the request, and once it is built
nobody asked whether it is what you meant — the reviewer holds the diff to the ticket.
So on your *land* in `/aif-review`, the product partner gives the demo: a fresh context
that has not read the reviewer's brief reads the request, the ticket's rules and
defaults, the report and the diff — for what a user would meet, not for the code — and
answers with one block. `demo: as expected` and the review runs `aif land`. `demo: not
as expected` holds it back with reasons that each quote the request line the build
misses and name the document that missed it — `ticket:` for the analyst, `request:` for
the request itself — on the card, for `/aif-pjm` to route. The last slice of a request
adds whether *After* is now true as built, and what *Now* said to watch. It reads only,
runs nothing, and can hold a land back but never push one through: your *land* is still
the yes, and `aif land <ID>` in your own terminal lands over it. `/aif-po <ID>` gives the
same demo by hand, and only reports.

Five minutes or an hour; the bar decides when there is enough, and you can override it
out loud. This is the one part of the foundry with no gate and nothing downstream that
can be lied to, which is deliberate: it is the thinking, and thinking does not pass a lint.

### Before the build — the analyst

**`/aif-ba`** writes the ticket with you (`/aif-ba TICK-1 "add rate limiting to
login"`), or cuts a request into tickets (`/aif-ba requests/<slug>.md`). It ships as
both a skill and a slash command with the same name, so it is reachable whether or not
your runner lets you type skills.

Two things make it an analyst rather than an interview form. **It writes the
rules and their examples** with you, in the conversation — the rules first, a
sentence each, then the key examples of each rule as GIVEN / WHEN / THEN, each
with the literal a test will assert — rather than handing a narrative to a
station that re-derives criteria blindfolded; that second translation was where
a ticket's meaning used to get lost. And **it reads the repository first**, so
the questions it puts to you are the ones the code cannot answer: what the
product should *do*. Those are yours; a decision you do not make is recorded as
*decided by default*, in the open, with the default named — never filled in
silently.

**The size cap counts rules, not examples** (`limits.ticket_rules_max`, 6). What a
person calls an acceptance criterion is a rule; one of the ticket's criteria is an
example of one — a single literal — and a cap of fifteen examples had the analyst
cutting ordinary six-rule stories into tickets that each built one detail. Each rule
gets its key examples only: the typical case, every boundary that changes the
outcome, the nearest counter-example; the other combinations are the tests
station's. Over the cap the analyst restates a rule that only lists cases, then
looks for an axis of variation that leaves each part a behaviour of its own, and
with none asks you to keep the ticket whole — your yes is recorded as a size
decision, and the gate refuses one taken by default. The examples keep a backstop
of their own (`limits.ticket_examples_max`, 30), and a ticket written before rules
existed is held to its old cap on criteria (`limits.ticket_ac_max`, 15).

**A ticket is a delta on the tickets before it.** The code says what exists; it
does not say what was meant, nor what is coming, and an analyst reading only
`main` could restate a rule a ticket in flight already owned, or change one
without a word. So it reads the map first — `aif rules <words>`, every ticket's
rules in force with the ticket's column, computed from `tasks/` and the board —
and sorts each rule a new ticket needs: its own; a change to a rule in force,
restated whole and named in `changes` (`OPES-69 R-1`, or `OPES-69 AC-001` for a
ticket written before rules), which the ready gate holds to a ticket and a rule
that exist and the plan station reads to find the older tests that move; or
another ticket's, not written again, with that ticket in `depends_on`. A cut of a
request gives each of its rules to exactly one ticket.

Given a request from the product partner, **it cuts by the slices**: one ticket per
slice, never one across two, every other slice a named non-goal of each ticket. It
proposes the cut as one block — which slices now, which wait, the ids — and scaffolds
nothing until you say yes. The first slice's ticket lands in Ready, the rest in Backlog
in slice order for `/aif-pjm` to release; a slice that waits stays in the request, and
`/aif-ba requests/<slug>.md slice 3` cuts it when it is due. Each ticket names its
request and slice in its meta block and its first line, and the request's own
`## Status` says how far it got: `not cut` (the product partner's default), `cut in
part` with which slice became which ticket, or `cut`.

It ends with the **Definition of Ready** and a card on the board:

```sh
aif _ready TICK-1
aif board create tasks/TICK-1/ticket.md --column ready
```

One script, two callers: the analyst runs it while you still have the whole
conversation in your head, and the worker runs the same file at intake. It
prints one line per problem, and the lines that matter are the open questions,
each with its proposed default — shown to you as one batch, at the moment you
have the most context you will ever have on this ticket (or on every ticket of a
cut, in one sitting). Answer them, or say "defaults", and the ticket is buildable.
A ticket that comes back from review comes back here, not to the worker: "wrong"
almost always means the ticket did not say.

### The board — where the state is seen

The board is the coupling between the three roles, and it is where the project's
state is *seen* rather than held in a head:

```
Backlog → Ready → In Progress → Review → Done
                                  ↘ Needs Human
```

The analyst puts a ready ticket in **Ready**. `aif work` — with no argument —
takes the card at the top and moves it to **In Progress** before anything else,
says who took it — one `taken: <host>:<checkout> pid <pid> at <time>` comment, the
host and a short name of this checkout, so a board two machines share — or two clones
on one — can tell a live worker elsewhere from a card dragged there by hand —
builds, and moves it to **Review** with the report as a comment. The claim beats:
the worker edits it to `… · alive at <time>` at every station it starts, and on
Trello it reads a card's claim before it takes one — another checkout's claim
whose worker the board has seen alive within a run's wall clock (the comment's own
dates on the board, never the times in its text) is that checkout's card, skipped
and said; two that take one card at once leave it to the earlier claim, and the
later withdraws its own. Every other way out
ends in **Needs Human** with a comment whose first line says whose problem it is —
`blocked: ticket` (back to the analyst), `blocked: run`, `blocked: environment` (this
machine, nothing spent — or, mid-run, the runner: a usage limit past what a run waits,
a runner that never answered) or `blocked: stopped` (and by whom), or `land:` when `aif
land` landed nothing — an install in the worktree that failed, your git hooks refusing
its merge commit — with why and the command that lands it once resolved — so a
taken card is never left in Ready for the next run to take again, nor anywhere
without its reason — a `blocked:` line the board refused is kept in
`.aif/tmp/blocked-<ID>.md` and posted by the next `aif work` on this machine, or by
`aif start`, once the board answers. You review beside the diff, the product partner's demo holds
your *land* to the request, and the project manager routes what either of you says.
Every transition goes through one adapter, `aif board`, in bash — a model
"remembering" to move a card is fail-open bookkeeping, and a card that quietly
did not move is the same defect as a meter that quietly did not fire.

```sh
aif board status                  # every card, by column
aif board next-ready              # what the worker would take
aif board move TICK-1 ready --top # the project manager's order
aif board show TICK-1             # the card, with the reviewer's comments
aif board head TICK-1             # the first line aif or a role wrote last — what is routed on
aif board release --dry-run       # what in Backlog waits on what; without the flag, release what can be
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
intake, the repository after. One card is asked for by its id — every listing of
the board leaves the ids it saw in `.aif/state/trello-cards.json` — never found by
listing every card with its description, and a card's head is read back past its
newest twenty comments until there is one. `scripts/check-board.sh` drives both backends
offline, the Trello one against a stand-in server (`scripts/mock-trello.py`).

**`/aif-pjm`** is the project manager: it orders Ready, links tickets, reads the
reviewer's words and the demo's on a card in Review and routes them — rework to
Backlog with the comment for the analyst, a demo's `request:` line to the product
partner first, cancel to Done — and finds cards that have sat too long.
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

Three things are not retries, and each is bounded on its own
(`docs/REBUILD-4.md`):

- **A spec stop.** The plan station passes a verdict on every criterion against
  the real code — `buildable`, or `already_true`, `unfalsifiable`, `conflict`,
  `needs_decision` with its reason — and anything but buildable stops the run
  there, after one dispatch, with nothing frozen. The ticket's problem, found by
  the first station that could tell, and it goes back to `/aif-ba` with the
  plan's words. The tests station has the same door: a criterion it cannot
  falsify, or every criterion already built by its own account, in
  `tasks/<ID>/tests.note.json`.
- **A repair.** When `green` attributes a failure to the frozen tests rather
  than to the code — a test that arrived with the oracle and fails whatever the
  code does, a check failing in a frozen test file the same way without the
  implementation, a pre-existing test the new files break, a frozen test the
  implementer declares wrong in `tasks/<ID>/implement.note.json` — the run does
  not stop. The tests station is dispatched again **in a copy of the tree with
  the implementation reverted to the skeleton**, so it cannot read the code,
  amends or keeps the test, and what it leaves must pass `verify-red` there
  (red against the skeleton) before it comes back and the implementation is
  judged again without a dispatch. `limits.repairs_max`, 2 per ticket.
- **A replan.** When the implementer declares, in its note, that the contract
  cannot hold the behaviour, everything since the first plan dispatch is put
  back and the plan station runs again with the declaration in front of it.
  `limits.replans_max`, 1 per ticket.

And one rule across every retry: **the same complaint twice in a row is a
stop.** A station that cannot act on what it is told does not get the third
attempt it used to; the complaints are compared as the whole set of problems,
numbers removed, so fewer problems is progress and the same ones are not.

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
| `aif project check` | validate it, and say what has moved since the template it was made from |
| `aif project upgrade` | bring forward what aif changed its mind about — the failure classes, a type-check's phases, the caps, the runner — and leave your own fields alone |
| `aif project guide` | write `.aif/guide/tests.md` from what the repository declares, for the plan and tests stations; regenerates its block in place, keeps what you wrote |
| `aif work [ticket]` | build the top of Ready (or a named ticket) headless on its own branch, no questions; one worker per ticket on this machine; `--clean` removes the worktree, `--stop` ends the run building it, from any terminal |
| `aif work --loop [--parallel N] [--max-tickets N] [--idle] [--no-tui]` | drain Ready in the board's order, N cards at a time (default 2), each in its own worktree, on a dashboard where there is a terminal; one loop per checkout; takes no new card on an empty column (`--idle`: looks again every 30 s instead), runs that cannot start on a machine whose preflight then fails (or three in a row), two that did not build, or Ctrl-C — and a second Ctrl-C stops the runs in flight; from any terminal, `--loop --drain` takes no new card and `--loop --stop` stops the runs too |
| `aif work --status [<ID>] [--json]` | what this machine knows of a run, offline: its lock and whether the worker is alive, what a dead worker left running, its worktree, branch, run record and report — one line, or the object a supervisor reads |
| `aif start [--no-build] [--dry-run] [--model-ba M] …` | the shift: review, analyst and owner sessions one at a time in this terminal, the board moved by fixed rules on fixed first lines and the rest listed with its command; a control point per unit, a pause after a session that changed nothing, a summary with `claude --resume <uuid>` for each; `--no-build` beside `aif work --loop --idle` in another terminal |
| `aif land <ID> [--no-suite] [--keep] [--prepare]` | the yes after review: `aif/<ID>` merged and judged in its worktree (the worker's verdict, or the suite and the green checks there), this branch fast-forwarded to it, card to Done, worktree and branch gone, the tickets whose `depends_on` names it released to Ready; `--prepare` also installs here what the land moved |
| `aif board …` | the board: `next-ready`, `pull`, `move`, `comment`, `create`, `status`, `show`, `head [--json]` (the first line aif or a role wrote last — with `--json`, its time, what came after it and every head before), `label`, `check`, `release [--dry-run]` (the Backlog cards whose every dependency is Done and landed, to the bottom of Ready), `init` |
| `aif secret set\|check\|rm\|list` | a token, stored where no model sees it; nothing prints a value |
| `aif doctor [--probe] [--json]` | what is installed, and which roles are ready here — `--json` is what `/aif-setup` reads |
| `aif cost [ticket]` | what the pipeline spent, per station, from the ledger |
| `aif explain <ticket>` | draw how it got here — criteria, decisions, gaps, and the plan's reasoning |
| `aif rules [<word>…] [--all]` | every ticket's rules in force, with its column — what the product does by intent (Done) and what is coming; the map the analyst writes against |
| `aif test <eval> --profile <p>` | run an eval, N times, with a pass rate |

There is no command per stage. The worker and the skills call a small internal
surface (`aif _gate`, `_record`, `_commit`, `_ready`, `_ticket-init`,
`_amend-plan`, `_meter`, `_verify`) that is not listed in `--help` — it is an
interface between two parts of aif, not something to learn. Each one is
something a model must not decide or must not carry: `_record` writes the hash
a station was once asked to copy, `_gate` renders and records a verdict,
`_ready` is the one Definition of Ready the analyst and the worker share, and
`_verify <ID>` is the verify-red gate run dry — the one command the tests
station may run, over its own files, freezing nothing.

### Stations and their model tier

| station | tier | produces | its gate(s) | turns | attempts |
|---|---|---|---|---|---|
| *(the ticket)* | — | `ticket.md`, by the analyst with you | ready | — | — |
| `plan` | careful (opus) | `plan.md`, a verdict per criterion, and the **contract**: every new module as a skeleton on disk | plan | 60 | 3 |
| `tests` | careful (opus) | test files + `tests.lock.json`, red against the skeleton | verify-red | 60 | 4 |
| `implement` | **by risk** | code — the skeleton filled | green, scope | 60 | 3 |

There are two tiers, and the question a tier answers is "do the gates catch this
model's mistakes": `routine` where they do, `careful` where they do not. The tier
is a label; the profile maps it to a model (`opus` → glm-5.2 on the `glm`
profile). The turn cap is the station's own (`max_turns` in its `aif:meta`),
over the project-wide `limits.station_max_turns` (60): the plan and tests
stations explore and read back, and hit the old cap of 30 in three runs of five
on one batch, leaving half-written files for the gate to judge. On a
subscription the cap costs nothing to raise and a cut-off station costs a
dispatch, so every station gets 60; what the cap still does is stop a station
that loops without producing before it eats the run's wall clock. The attempts cap — rejections
in a row before the run stops — is `max_attempts` in the station's `aif:meta`
over `limits.attempts_max` the same way: the tests station gets four, because
it has already iterated with the dry verifier and a fourth informed retry is
cheaper than a human (`docs/REBUILD-4.md` §2.4).

**The contract** is what the tests and the code are both written against. The
plan station writes every path in `files.create` that is code as a skeleton —
the real exports, with their real names, signatures and types, and bodies that
throw `aif: not implemented: <name>` — and the new exports it adds to a file it
changes the same way. The tests station then imports it statically, like a
header file, and a test is red for one of two reasons only: an assertion that
does not hold, or the marker. The implement station fills it. Why: a test file
importing a module that does not exist yet fails to *load*, and jest-junit
drops the whole file from its report — on one batch, 24 new tests across three
tickets were never seen by any gate that way (`docs/FINDINGS.md` #22). And the
seams — a module path, an export name, an argument shape — are decided once, in
code a compiler can check, rather than guessed twice.

`implement`'s tier comes from the ticket's `risk`, which stays three-valued
because it describes the *work* — a human's judgement, made with the analyst —
while a tier describes an *engine*. `low` and `medium` both map to `routine`, `high` to
`careful`.

### What a station knows about the stack

Whether `jest.mock` factories are hoisted, what jest-junit does with a file that
fails to load, how pytest names a node, how a skeleton is written so that it
compiles — none of that should be rediscovered per ticket inside a 60-turn
budget, and a model's memory of it differs from run to run. So stack knowledge
is **data the pipeline supplies**, appended by the worker to the plan and tests
stations' prompts after their own instructions, in two layers
(`docs/REBUILD-4.md` §6):

- **The runner fragment**, shipped with the set — `sets/claude/stacks/jest.md`,
  `pytest.md`, installed to `.aif/stacks/` — chosen by `test.kind` in
  `.aif/project.json` (`aif project init` records it; an older file is read by
  its test command). What red looks like under that runner and how the report
  names a test; a file that fails to load leaves *no* row; the two reasons a new
  test may be red; how to write the skeleton in that language; a test that
  asserts a throw passes against a skeleton that throws, so assert the specific
  error; mocks at the boundaries, never of the module under test; no snapshots.
  One fragment per template, and `scripts/check-set.sh` holds the pair together.
  A runner the set has no fragment for leaves the stations on their general
  rules — `aif doctor` says so on its `stack` line, and the run says so too.
- **The project's guide**, `.aif/guide/tests.md`, written by `aif project guide`
  from what *this* repository declares: the runner's configuration lines, the
  setup files it loads, the manual mocks, factories and fixtures (a `conftest.py`
  by the fixtures it defines), where the tests live and how they are named, the
  modules and packages the tests import most, and the shortest test using each
  of the top helpers. One section is left for a human — **how this project mocks
  its boundaries** — because nothing mechanical can know why the tests fake the
  clock the way they do; `/aif-setup` writes it with you from the tests the
  guide names. The generated block is regenerated in place and everything
  outside it is kept. Every path in backticks is checked: a path that no longer
  exists is a `test-guide` ✗ in `aif doctor` and a refused `aif work` naming it,
  because a guide pointing at a renamed helper sends a station to a file that is
  not there. Commit it — the stations run in a worktree cut from HEAD and read
  that copy, and a guide never committed is refused too.

The project's own `CLAUDE.md` reaches the stations already (`claude -p` runs
without `--bare`). Nothing aif-specific is needed for a stack aif knows nothing
about: write what the stations should know there.

### Gates and exit codes

Every gate is `gate.sh <work-dir>` → an exit code:

| code | meaning | what the worker does |
|---|---|---|
| **0** | pass | proceeds |
| **1** | the artifact is rejected | retries the station with the complaint |
| **2** | the ticket is the problem — a spec stop | stops, for the analyst, with the gate's lines |
| **3** | the gate could not render a verdict | stops: the environment, or a defect no loop reaches |
| **4** | the oracle is the problem — a repair | sends the tests station to fix it, in a copy without the implementation |

`1` versus `3` is the difference between "your plan has a blocker" and "the repo
was already broken"; `2` and `4` are the two answers that go to somebody other
than the station that was just judged. `verify-red`: a test red because an
assertion did not hold, or because the skeleton threw its marker, is `0`; a
`SyntaxError` test, a skipped one, one failing for any other reason, one whose
criterion is not in a collected test's name, one that flips between two runs —
every one of those is `1`, because the author is still there to fix it (a
broken test used to be a `3`); every new test already green is `1` too, unless
the station said so in its note, and then it is `2`.

A `3` is not always the environment, and the gates say which it is rather than
assuming — and what is no ticket's to fix is not a stop at all. A pre-existing
test that fails is run once more: failing once and passing once, it is
**flaky**, let through and named. One that fails again is measured on the tree
*before this ticket* — a copy at the commit the ticket was cut from or last
brought onto, its installed dependencies linked, the run kept under
`.aif/tmp/base/` — and red there it is your repository's: let through by
`verify-red` and `green` alike, in the lock as `red_at_base`, on the report;
the ticket answers for what it adds. A check failing the same way there, with
no line new, is let through the same way, at every phase. One the new files
turned red is a different thing: it is admitted, recorded in the lock as
`red_with_tests`, printed on the pass path, and left for `green`, which
requires the whole suite. A copy that cannot be made whole — an unreadable
file — is a `3`, naming it. **`green`**, for every failure it cannot pin on the
implementation, runs the same thing again with the implementation reverted: a
pre-existing test that passed at the freeze and fails there too moved outside
the tracked tree — installed dependencies, most often — and that is a `3`, no
station's edit reaches it; one red since the test files landed that fails the
same way without the code, a check that fails in a frozen test file with every
line of it recurring without the code, a test that arrived with the ticket's
own files, a frozen test the implementer declares wrong — each is the oracle's,
a `4`, and the tests station repairs it rather than a human.

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

**Every check names a phase, and that is not optional.** Three phases:
`contract` is the plan boundary — the skeleton the plan station wrote, over the
tree as it left it, and a compiler there is the linker for the contract: a
signature that calls a library the way the station remembered it rather than
the way it is does not compile, and the plan is rejected with the compiler's
lines. `red` is the tests boundary: with the contract on disk every symbol a
test touches exists, typed, so a type-check is clean there and a type error is
the test's; a build is still red by design there and does not belong. `green`
is the implement boundary, and compilers, linters and builds go there. It is the
same distinction `failure_classes` already draws one level down between a
legitimate failure and a broken one.

`aif project init` writes one check without asking: the project's own
type-check, bound to all three phases, when the project declares one — a
`tsconfig.json` with `typescript` installed, or a `typecheck` script. Nothing is
invented for a project that has neither, and `--no-checks` writes none.

`green` runs every check bound to its phase, fails the station if a required one
does, and each result lands in the ledger by name — so a failure is attributable
to `typecheck` rather than to "the implement station". `test.command` keeps
working unchanged. The complaint a station gets back is the check's own
**first** lines, file and line included. It used to be the last one, and for
`tsc` that is often `Source has 0 element(s) but target requires 1.` — no file,
no line, and three attempts spent not finding it.

**A project without a contract — one whose plans create nothing, or an older
set — can still read the tests at `red`, once it says what a missing
implementation looks like.** A whole-tree `tsc` then fails at red on every
import of a module the plan has not created — red by design. With
`legitimate_at_red` those failures are let through, and the test files are held
to everything else:

```json
{ "name": "typecheck", "command": "npx tsc --noEmit", "phase": ["red", "green"],
  "required": true, "legitimate_at_red": ["error TS2307", "error TS2305", "error TS2724"] }
```

At red, a line of its output that names one of this ticket's declared test
files and matches none of the patterns rejects the tests, and the tests station
gets the line back while it can still fix it. That is the moment for a mock
typed `Mock<Category, []>` against a field declared `Mock<Category | null,
[string]>`: jest runs it happily — babel strips types — and after the freeze
nobody may edit it. A red check that fails without naming any test file stops
the run: the repository fails it already, or it prints paths that are not
relative to the project root. A red-first test that calls a signature the plan
changes in an existing file fails with other codes (`TS2554`, `TS2339`); add
them if your tickets do that, knowing the tests are then held to less.

### The test freeze, and what it actually holds

`verify-red` freezes the test tree into `tasks/<ID>/tests.lock.json`, and `green`
refuses to accept an implementation unless the tree still hashes to it. That is
what stops the implement station editing the oracle it is judged against.

The lock also holds the implementation as it stood at the freeze —
`impl_frozen`: every file the plan changes, and every skeleton it created — so
`green`'s revert-recheck puts exactly that back: the covering tests must go red
again against the skeleton, which is the tree they were written against.

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
| `rules[]` | ticket | what must hold, a sentence each — the unit the size cap counts |
| `rules[].changes` | ticket | the rules of other tickets a rule replaces — their tests move with this ticket |
| `acceptance[].rule` | ticket | the rule a criterion is an example of |
| `acceptance[].surface` | ticket | where the criterion is observed |
| `decided[].by` | ticket | `human`, or `default` — the analyst's proposal, unanswered |
| `decided[].kind` | ticket | `architecture` marks a decision that commits the project; `size`, the human keeping a ticket whole over the rules cap |
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

The hatch is bounded rather than trusted: it refuses test files, pipeline
paths, CI, `.gitignore` and lockfiles; a file that does not exist yet it
accepts only beside the plan's own — in a directory holding one of its
`files.create` or `files.change`, never the root, never a dotfile, a test or a
manifest — and records it as created; it is capped
(`limits.plan_amendments_max`, default 3), every entry carries a reason, and
`scope` prints the amendments on its *pass* path, a created one marked new — a
widened manifest nobody sees is the same as no manifest. Past the cap the
honest answer is that the plan was wrong, and the refusal names the way back:
a replan, written in the implementer's note.

A file that must go is the plan's to name, in `files.delete`: an existing path,
never a test, a manifest or the pipeline's own. `scope` passes the deletions the
plan names, refuses one it names that is still there, and refuses every other.
CI (`.github/`, `.gitlab-ci*`) and `.gitignore` move only when the plan names
them — never by amendment — and `scope` says what a planned `.gitignore` now
ignores, since its own diff reads the untracked files through it.

### Dependencies: the manifest and its lockfile, together

A dependency used to have half a door. The lockfiles were refused outright,
until a sanctioned route for dependency changes was decided; the manifests were
not, so a plan could name `package.json` and nothing else. On a live ticket that
is exactly what happened: a station installed a native package without the
lockfile, npm re-resolved packages nobody had asked to move into an
incompatible pair, and twelve pre-existing tests went red where no edit to the
manifest's files could reach them — three implement attempts, all rejected for
them. The route now runs through five places:

- **the plan gate** requires the lockfile whenever the plan names a manifest —
  the nearest one at or above it: `package.json` → `package-lock.json`,
  `npm-shrinkwrap.json`, `yarn.lock` or `pnpm-lock.yaml`; `pyproject.toml` →
  `poetry.lock` or `uv.lock`; `Cargo.toml` → `Cargo.lock`; `go.mod` → `go.sum` —
  and refuses a lockfile named without its manifest;
- **`scope`** lets a lockfile move only when the plan names it, and
  `aif _amend-plan` refuses lockfiles: a new dependency is the plan's decision;
- **the worker** runs `prepare` again, from the lockfile, after any station that
  changed a manifest or a lockfile, before any gate reads the suite. `npm ci`
  refuses a manifest the lockfile does not match, so a package installed around
  the lock comes back to the station as a rejection in npm's own words;
- **`green`**, when a pre-existing test fails, runs it again with the
  implementation reverted: one that passed at the freeze and still fails there
  moved outside the tracked tree, and the run stops instead of retrying;
- **`aif land`** judges the merge in the ticket's worktree, where the worker
  installed what the branch pins: when the merge moves a manifest or a
  lockfile against that, `prepare` runs there first, and an install that
  fails, or that rewrites a tracked file (`npm install` where `npm ci` was
  meant), lands nothing. Your checkout is never installed into unasked: what
  the land moved is named, with the command, and `aif land <ID> --prepare`
  runs `prepare` here after the fast-forward — a failure or a rewrite there
  said on the landed card.

### What each station cost

Every station is metered from its own `claude -p` envelope: four token classes,
a turn count and the model that actually ran, appended as a row to the ticket's
ledger — one row per attempt, never updated in place, because
overwriting a row is how rework disappears from a metric that exists to count it.

The ledger is a record and never a verdict: nothing reads it to decide anything,
so nothing it does can stop anything. A row it cannot write — a lock left behind
by a killed process, a ledger that is no longer JSON — is skipped with a warning
(a lock nobody holds is taken over, an unreadable ledger is set aside beside itself
and a new one started), and the run, the gate and the land go on. Nor is it in git:
it lives in your checkout, `.aif/state/ledgers/<ID>.json`, gitignored, one file per
ticket that every worktree writes to — so no branch carries it and no merge meets it.
What a reviewer needs of it, the report carries on the branch. A ticket that still has
a `tasks/<ID>/ledger.json` from before is read from there once and left alone.

Tokens are the raw datum; dollars are derived from `.aif/prices.json`. **That
table ships empty on purpose.** A wrong price produces a confident figure nobody
re-checks; a missing one produces `cost_usd: null` beside a complete token count,
which is obvious and fixable. Fill it in from your provider's pricing page.

This replaced reading `total_cost_usd` off a `claude -p` envelope, and is better
in three ways: it works under subscription auth, where that field was `0` and is
now, on claude 2.1.226, an estimate at API prices rather than anything charged; it survives a station that failed, because the transcript is written as the
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

| Writer | May write | May run | Denied |
|---|---|---|---|
| `aif-plan` | `plan.md`, and the contract: the skeleton files its manifest names | — | test files and what `files.tests` declares, the rest of the ticket's record, `.aif/`, `.claude/` |
| `aif-tests` | what the plan's `files.tests` declares — the tests, a manual mock, a test util, a fixture — files named like tests, and `tasks/<ID>/tests.note.json` | `aif _verify <ID>` and nothing else | implementation, the skeleton, `.aif/`, `.claude/`, the rest of `tasks/` |
| `aif-implement` | code the plan named, and `tasks/<ID>/implement.note.json` | the suite, the package manager | test files and what `files.tests` declares, a commit, `.aif/`, `.claude/`, the rest of `tasks/` |
| a plain `claude` session | everything, as usual | everything | nothing |

The worker tells the hook which ticket it builds (`AIF_TICKET`, beside
`AIF_STATION`), and the hook reads that plan's `files.tests`: a mock or a fixture
the tests need is the plan's to declare, whatever its name. `.aif/`, `.claude/`
and `tasks/` are how a ticket is judged and recorded — the gates, the project's
config, the hooks, the stations' instructions, the tickets' records — and no
station writes there but its own file.

Each station's note is the one file under `tasks/` it may write: a structured
way to say what its artifact cannot — "this criterion is already built", "this
one cannot be falsified", "this frozen test is wrong", "the contract cannot hold
this" — read by the gates and the worker rather than guessed from a closing
message.

The last row matters as much as the others. The guard binds to a **station**,
not to a session: a project with aif installed is still an ordinary project, and
a plain `claude` in it is not policed. There used to be a third rule — an
orchestrator session may not write product code — which existed because a
session dispatched the stations while a human watched, and once finished a
feature itself after a station ran out of turns. There is no such session now;
the worker is a subprocess and the only writers are stations.

The hook fires under `--permission-mode bypassPermissions`, and its deny
reaches the model — probed (`docs/FINDINGS.md` #21). One thing rides on that
and is therefore not assumed: the tests station's Bash exists for `aif _verify`
and nothing else, and a hook that did not fire would hand it the shell. So the
worker grants that tool only once `aif doctor --probe` has watched the hook deny
a command in a spawned run on this machine (`station-guard` in doctor's table,
remembered per runner version in `.aif/state/guard-probed`); withheld, the
station still works, with the gate's reject loop as its only loop. `scope` and
`green` are the backstops either way.

Stated plainly: for files this matches the Write and Edit tools, so `bash -c
'echo … > src/f.py'` walks past it. For Bash it matches two things: for the
tests station, the whole command must be `aif _verify <ID>` and this rule fails
closed; for every station, `git commit`, `reset`, `stash` and the like at a
command position are refused, because a station that commits moves the baseline
under the gates, and that rule deliberately does not try to match anything
cleverer: parsing shell fails open in ways nobody notices. The real backstop for
code is `scope`, which diffs against the baseline the worker recorded at
dispatch and rejects any file the plan did not name regardless of who wrote it
or what they committed since; the hook exists so the honest-but-helpful path is
closed early and by name.

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

**A test the runner never collected covers nothing.** `verify-red` requires
every criterion's id and its `expect` literal in the ticket's tests, and that
is a grep over their text — so "the tests" are the declared files the report
holds at least one new test from. A declared file the runner never collected
(a name outside `testMatch` or `python_files`, or a jest suite that fails to
load, which jest-junit leaves out of the report unless `reportTestSuiteErrors`
is set) ran nothing, at the freeze or at `green`. It used to count in full,
and a criterion whose only test lived there reached review with every gate
green and nothing having checked it. It goes back to the tests station now,
with the file named. A declared support file — a conftest, a helper — needs no
test of its own; it counts toward no criterion. Coarse mode has no per-test
report to tell by: it still reads every declared file, and says so.

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
the same command again and it resumes at the first thing that did not happen;
`scripts/check-release.sh`, part of `make check`, stops a release at each step
against local stand-ins for GitHub and the tap, and proves the re-run finishes.
`make check` ends with `scripts/release.sh --verify`, which is silent while a
version is unreleased and fails the moment a tag exists that the tap does not
serve — except for the version `make release` is itself cutting, so that the
run finishing an interrupted release can get past its own check.

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
- [x] `aif work --loop`, `aif land`, `/aif-review` — the queue drains, the yes is one command, the review has a brief
- [x] `aif explain` — the provenance chain behind a ticket, rendered, at no cost
- [x] The demo — on the reviewer's land, the product partner holds the build to its request before `aif land` runs
- [x] `aif start` — the shift: your sessions one at a time, by fixed rules, beside `aif work --loop --idle` in another terminal
- [ ] Fill `prices.json` — tokens are recorded, dollars need a table
- [ ] Fixture-level evals (a real repo, a real oracle) + guardrail evals
- [ ] `local` profile via `llama-server`, plus a profile preflight hook
- [x] Homebrew formula and tap — `Namdurash/homebrew-tap`
- [ ] `sets/codex/`

## License

MIT
