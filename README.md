# AI Foundry (`aif`)

Put an existing project on AI SDLC rails. You run `aif init`, pick a profile,
and the native config for that agentic coding CLI lands in your repo — agents,
skills, and context files, ready to drive.

> **Status: early.** The machine works — `init`, `start`, `doctor`, `profiles`,
> `test`. What it pours does not exist yet: the set ships a placeholder while the
> AI SDLC content is decided. See the roadmap.

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
sets/claude/      native Claude Code layout: CLAUDE.md, skills/, agents/
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
| `.claude/skills/`, `.claude/agents/` | yes | the shared foundry — the team's asset |
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
`aif start` time instead. See `docs/FINDINGS.md`.

### Running it

```sh
aif start                    # interactive
aif start "add validation"   # interactive, opening with that task
aif start --headless "..."   # one-shot, for CI
```

`aif start` is the entry point for anything other than your default provider.
Routing is applied by exporting into the child process, so **a bare `claude` in
the project is not on the profile's model** — it uses whatever the project
already had. That is deliberate: the alternative is a routing setting that might
be ignored, which puts you on a model you did not choose without telling you.

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

**Run evals from a plain terminal.** A child `claude` spawned inside an agent
session cannot authenticate and every run will 401 — see `docs/FINDINGS.md`.

## Cheatsheet — a ticket through the pipeline

### One-time, per machine (until Homebrew)

```sh
ln -s /path/to/ai-foundry/bin/aif /opt/homebrew/bin/aif
```

### Once, per project

```sh
aif doctor            # what is installed, and what aif can therefore drive
aif init              # install the set, pick a profile
aif project init      # detect the runner — then REVIEW .aif/project.json,
                      # especially test.command and test.roots
aif test L0-smoke --profile anthropic --runs 3   # smoke: does the model answer?
```

### A ticket, in order

```
Ticket ── spec ── plan ── tests ── code
              gate      gate       gate      gates
```

```sh
aif work new TICK-1                 # creates .aif/work/TICK-1/ticket.md — you fill it in
aif station run spec TICK-1         # opus  → spec.md        · gate: spec-form
aif station run spec-judge TICK-1   # opus, blockers only    · gate: spec-judge
aif approve TICK-1                  # YOU, at a real terminal · gate: spec-approve
aif station run plan TICK-1         # opus  → plan.md        · gate: plan-form
aif station run plan-judge TICK-1   # haiku, "where would you guess?" · gate: plan-judge
aif station run tests TICK-1        # opus  → failing tests  · gate: verify-red
aif station run implement TICK-1    # by risk → code         · gates: green + scope
aif work status TICK-1              # at any point: what is done, what is next
```

`aif work status` is the "where am I" command — run it whenever you are unsure;
it names the next step.

### Commands

| command | what it does |
|---|---|
| `aif doctor` | report runners, tooling, and this project's health |
| `aif init [profile]` | install the set; merge, never clobber |
| `aif uninstall` | reverse the manifest; round-trips clean |
| `aif profiles` | list the (set, runner, model) profiles |
| `aif project init [runner]` | scaffold `.aif/project.json` |
| `aif project check` | validate it |
| `aif work new <ticket>` | start a ticket |
| `aif work status <ticket>` | the derived state, and what is next |
| `aif station run <station> <ticket>` | run one station headless (records tokens) |
| `aif approve <ticket>` | the human gate — needs a real terminal |
| `aif start` | open the runner with a profile (ad-hoc, not the pipeline) |
| `aif test <eval> --profile <p>` | run an eval, N times, with a pass rate |

### Stations and their model tier

| station | tier | produces | its gate(s) |
|---|---|---|---|
| `spec` | opus (high) | `spec.md` | spec-form |
| `spec-judge` | opus (high) | `verdict-spec.json` | spec-judge |
| `plan` | opus (high) | `plan.md` | plan-form |
| `plan-judge` | **haiku (low)** | `verdict-plan.json` | plan-judge |
| `tests` | opus (high) | test files + `tests.lock` | verify-red |
| `implement` | **by risk** | code | green, scope |

The tier is a label; the profile maps it to a model (`opus` → glm-5.2 on the
`glm` profile). `implement`'s tier comes from the spec's `risk`: low→haiku,
high→opus.

### Gates and exit codes

Every gate is `gate.sh <work-dir>` → an exit code:

| code | meaning | what to do |
|---|---|---|
| **0** | pass | proceed |
| **1** | the artifact is rejected | fix it and re-run the station |
| **3** | the gate could not render a verdict | rerun the judge, or fix the environment |

`1` versus `3` is the difference between "your spec has a blocker" and "the judge
hallucinated / the repo was already broken". `verify-red`: a real failing test is
`0`; a `SyntaxError` test is `3` (not a usable oracle); a test that already passes
is `1`.

### The backward transition — free, no command

Edit any upstream artifact and everything below it lapses on its own, because
every artifact binds to the hash of the one above it. Change `spec.md` after
approving, and the approval, the judge verdict, the plan, and the tests all go
invalid. There is no "go back" — `aif work status` just shows what became
unvalidated.

### Offline, no tokens

```sh
bash scripts/demo.sh        # the whole pipeline on hand-written artifacts
make lint                   # shellcheck everything
make check                  # run the CLI under bash 3.2
```

Run live pipeline commands from a **real terminal**: a `claude` spawned inside an
agent session cannot authenticate (see `docs/FINDINGS.md`).

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
- [x] `aif start` — profile export, interactive and headless
- [x] `aif uninstall` — reverse the manifest, value-guarded
- [ ] Fixture-level evals (a real repo, a real oracle) + guardrail evals
- [ ] `local` profile via `llama-server`, plus a profile preflight hook
- [ ] Homebrew formula and tap
- [ ] The foundry content itself: which agents implement the AI SDLC
- [ ] `sets/codex/`

## License

MIT
