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
- [ ] `aif uninstall` — reverse the manifest
- [ ] Fixture-level evals (a real repo, a real oracle) + guardrail evals
- [ ] `local` profile via `llama-server`, plus a profile preflight hook
- [ ] Homebrew formula and tap
- [ ] The foundry content itself: which agents implement the AI SDLC
- [ ] `sets/codex/`

## License

MIT
