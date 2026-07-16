# Findings

Things we probed rather than assumed. Each one shapes the code, and each one is
non-obvious enough that someone will eventually try to "simplify" it back.

Probed against `claude` **2.1.85** (Homebrew cask) on macOS 26.5.2, bash 3.2.57,
jq 1.7.1-apple, on 2026-07-16.

---

## 1. Model routing goes through exported environment

`aif start` and `aif test` export environment variables into the child process
rather than writing them to a settings file.

The reason is robustness, not a defect. A variable in the process environment
takes precedence over any settings file, on every version, for every runner. It
is the one mechanism we can be certain of end to end, and the one that will still
be correct when `runner_codex` arrives.

**Established:** `env.ANTHROPIC_AUTH_TOKEN` in a discovered `settings.json` *is*
applied. A probe that supplied a dummy token there came back with

```
401 {"type":"authentication_error","message":"Invalid bearer token"}
```

which is upstream rejecting a credential that really was sent. So the `env` block
is read, and at least partly honoured.

**Open, and deliberately not relied upon:** whether `env.ANTHROPIC_BASE_URL` in a
discovered `settings.json` actually reroutes.

We could not establish this, and the reason is worth recording so that nobody
repeats the mistake — we made it once already and wrote the wrong answer down.

**A probe run from inside a Claude Code session is confounded.** That session
exports its own `ANTHROPIC_BASE_URL` into every child process, and an exported
variable correctly overrides a settings file. So the obvious probe — put a bogus
URL in `settings.json`, watch the request go somewhere else — measures
environment precedence and says nothing whatsoever about settings handling. It
produces a result that looks damning and is an artifact. Unsetting the ambient
variable does not rescue it either: the child then falls back to an interactive
auth path that cannot complete headlessly, and simply hangs.

**Answer it from a plain terminal**, outside any agent session, before relying on
it in either direction.

**What this changes for aif: nothing** — which is the point. We export because
exporting is universal, not because settings are broken. Until someone
establishes that settings routing works, `aif init` will not write
`ANTHROPIC_BASE_URL` into a settings file: a routing knob that *might* be ignored
is worse than no knob, because the failure is silent and you carry on believing
you are on a model you are not on. `aif start` is the supported entry point.

## 2. `subtype: "success"` can accompany `is_error: true`

An authentication failure returned:

```json
{ "type": "result", "subtype": "success", "is_error": true,
  "stop_reason": "stop_sequence", "total_cost_usd": 0 }
```

The run hard-failed and `subtype` still said `success`. **Gate on `is_error`.**
Never branch on `subtype`. The process exit code agreed with `is_error`, so the
two together are a reasonable belt-and-braces check.

Related: `total_cost_usd` is `0` on error, and can legitimately be `0` under
subscription auth — so never treat a zero cost as a signal of anything.

## 3. `CLAUDE_CONFIG_DIR` relocates authentication too

It exists and works, which makes it the clean structural mitigation for
[claude-code#77512](https://github.com/anthropics/claude-code/issues/77512)
(resuming a session across providers bricks it): give a profile its own config
dir and its sessions physically cannot be resumed into another provider's.

But pointing it at a fresh directory yields `Not logged in · Please run /login`.
It relocates the whole config root, auth included. So it is unambiguously right
for eval runs (which want hermetic isolation anyway) and a deliberate trade for
interactive use, where it costs a one-time re-login per profile.

## 4. `--bare` is the wrong tool for evaluating a set

Its help text: skips **CLAUDE.md auto-discovery**, hooks and plugins, and
restricts Anthropic auth to `ANTHROPIC_API_KEY` or `apiKeyHelper`.

Both halves disqualify it:

- Skipping CLAUDE.md discovery skips **the payload under test**. A `--bare` eval
  of a foundry set evaluates nothing.
- Restricting auth to `ANTHROPIC_API_KEY` breaks any provider that authenticates
  via `ANTHROPIC_AUTH_TOKEN` — which is how GLM authenticates.

Isolate eval runs with `CLAUDE_CONFIG_DIR` + `--setting-sources` instead.

## 5. jq `+` clobbers sibling keys; use `*`

```
{"env":{"A":"1","K":"keep"}} * {"env":{"A":"2"}}  =>  {"env":{"A":"2","K":"keep"}}   correct
{"env":{"A":"1","K":"keep"}} + {"env":{"A":"2"}}  =>  {"env":{"A":"2"}}              destroys K
```

`+` is shallow: it replaces `env` wholesale. Merging a single variable into a
user's settings with `+` would silently delete every other variable they had.
Always `*`.

## 6. `sed -i` is not portable

BSD sed treats the argument after `-i` as a backup suffix and then consumes the
filename; GNU sed rejects the BSD form. There is no spelling that works on both.
Every in-place edit goes through awk → temp file → `mv`.

## 7. Evals cannot be run from inside an agent session

A child `claude` spawned from within a Claude Code session cannot authenticate:

```
401 {"type":"authentication_error","message":"Invalid authentication credentials"}
```

The session holds an OAuth credential that it does not hand down to child
processes — it exports `CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH` and friends, but no
usable token. The child inherits the session's `ANTHROPIC_BASE_URL` and nothing
to authenticate against it with, so every run 401s.

This is the same entanglement as #1, wearing a different hat. `aif test` works
correctly — it reports the failure honestly rather than hiding it — but the
numbers it produces in that context measure the sandbox, not the profile.

**Run evals from a plain terminal.** If the harness reports 0/N with an
authentication error for every run, check where you are before you debug the
harness.

---

## bash 3.2 (what stock macOS ships)

The floor is 3.2 so that `aif` runs on an untouched Mac. The taxes:

- **`set -e` does not fire for `local v=$(cmd)`.** `local`'s own exit status
  masks the command's, so the assignment silently succeeds with a wrong value.
  Always split: `local v` then `v=$(cmd)`.
- **Empty arrays are fatal under `set -u`.** `arr=(); echo "${arr[@]}"` →
  `unbound variable`. Fixed in bash 4.4; not in 3.2. Expand as
  `${arr[@]+"${arr[@]}"}`.
- **`"$@"` is fatal under `set -u` with no positional parameters.** Forward
  arguments as `${1+"$@"}`.
- **A piped `while read` runs in a subshell**, so assignments and `export`s
  inside it are discarded. `printf 'a\nb\n' | while read x; do n=$((n+1)); done`
  leaves `n=0`. Use a here-doc. This directly affects environment export — a pipe
  there would silently export nothing at all.
- No associative arrays, no `mapfile`/`readarray`, no `${var,,}`/`${var^^}`, no
  `&>>`, no negative array indices, no `wait -n`.
- `readlink -f` does not exist on BSD. Walk the symlink chain by hand.

Fine in 3.2, use freely: indexed arrays, `${#arr[@]}`, `local`, `${x%%=*}` and
`${x#*=}`, `case` globs, `shopt -s nullglob`, `select`,
`$(cd … && pwd -P)` with `${BASH_SOURCE[0]}`, sourcing into a subshell to
capture values.

**shellcheck will not catch bash-4-isms** — it has no version targeting. The only
real guard is running under `/bin/bash` (3.2), which `make check` does.
