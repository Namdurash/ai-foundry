# AI Foundry (`aif`)

Put an existing project on AI SDLC rails. You run `aif init`, pick a profile,
and the native config for that agentic coding CLI lands in your repo — agents,
skills, and context files, ready to drive.

> **Status: early.** The CLI skeleton and `aif doctor` work. `init`, `start`,
> `test` and the foundry content itself are not built yet. See the roadmap.

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

| Path | Committed | Why |
|---|---|---|
| `.claude/skills/`, `.claude/agents/` | yes | the shared foundry — the team's asset |
| `.aif/foundry.md` | yes | our context content, imported by `CLAUDE.md` |
| `CLAUDE.md` | yes | yours; `aif` only injects one `@.aif/foundry.md` line |
| `.claude/settings.local.json` | **no** | your model choice and credentials |

So a team shares one foundry while one developer runs it on Opus and another on
GLM. Whether that actually holds is an empirical claim — which is what the
harness is for.

## Testing

`aif test` is an eval, not a unit test. It runs a fixture repo through the real
agent set against a real model and checks a deterministic oracle. Models are
non-deterministic, so it reports a pass rate over N runs rather than a single
verdict.

The level-0 smoke fixture needs no agents at all — it only proves the wiring
(base URL, auth, tool-calling). That is deliberate: the harness has to exist
before the content, or there is no way to tell whether the content works.

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
- [ ] Profiles + level-0 smoke harness — answers "does GLM actually work?" with
      zero agents written
- [ ] `aif init` — profile picker, `CLAUDE.md` merge, manifest
- [ ] `aif start`
- [ ] Fixture-level evals + cost tracking
- [ ] Homebrew formula and tap
- [ ] The foundry content itself: which agents implement the AI SDLC
- [ ] `sets/codex/`

## License

MIT
