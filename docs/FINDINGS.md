# Findings

Things we probed rather than assumed. Each one shapes the code, and each one is
non-obvious enough that someone will eventually try to "simplify" it back.

Probed against `claude` **2.1.85** (Homebrew cask) on macOS 26.5.2, bash 3.2.57,
jq 1.7.1-apple, on 2026-07-16. Findings 8–10 were probed against `claude`
**2.1.212** on 2026-08-05; where a later probe contradicted an earlier one, the
earlier entry says so rather than being quietly rewritten.

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

**Record it anyway.** "Do not branch on it" was over-read into "do not store it",
and that cost a diagnosis. An `implement` attempt on a live ticket ended with
`is_error: true` and no `.result` field, and the ledger row said only "no result
field" — the shape of an exhausted turn budget, which had to be reconstructed
from which keys were *missing*. `subtype` would have said `error_max_turns` in
one word. Untrustworthy as a decision input and valuable as a record are not in
tension; they are different uses.

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

## 5b. Merging into a user's JSON reformats it; round-trip is content-clean, not byte-clean

`aif init` merges the guard-hook registration into `.claude/settings.json` with
jq, and jq has no format-preserving mode — it rewrites the whole file
2-space-indented. So the round-trip promise is precise:

- A file aif **created** (fresh project, no `.claude/settings.json`) is deleted
  on uninstall → byte-clean.
- **Marker-block** files (`CLAUDE.md`, `.gitignore`) are edited by text surgery,
  never jq → byte-clean.
- A `settings.json` the user **already had** is restored to the same *content* on
  uninstall (verified with `jq -S`), but jq's reformatting means `git diff` may
  show a formatting-only change.

Two more traps this merge exposed, both real bugs that were fixed:

- `${var:-{}}` mis-parses in bash: the `}` in the `{}` default closes the
  parameter expansion, and a stray `}` is appended to the value. Assign the
  default on its own line.
- A `*` merge **replaces** arrays, it does not append. Merging a hook into a
  `settings.json` that already has `hooks.PreToolUse` would drop the user's
  hooks, so `aif init` refuses and warns rather than clobber. Uninstall subtracts
  the fragment structurally (recursive, with array difference) — a flat
  leaf-path deletion cannot invert a nested hook array and leaves `[{}]` behind.

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

## 7a. Gates cannot call lib/ functions — they run without aif

A gate ships into a project and runs from a fresh CI checkout, where `aif` is not
installed and `lib/common.sh` is not on disk. A gate that calls `aif_have`,
`aif_die`, or any `lib/` helper works on the author's machine (where the shell
happens to have them in scope during testing) and fails in CI.

Worse, it fails *silently*. Gates run under `set +e`, so a call to a missing
function returns 127 and an `if aif_have python3 && …` simply takes the false
branch — turning an optional-tool check into a quiet downgrade. verify-red went
to coarse mode this way and every scenario passed vacuously.

Gates use only their own `.aif/gates/_lib.sh` (`aif_g_*`) plus POSIX tools. When
a gate needs something `lib/` already has, duplicate the few lines into `_lib.sh`
rather than reaching across.

## 7. A nested `claude` sometimes cannot authenticate — NARROWED, 2026-08-05

**This entry was written as a general rule and the general rule is false.** It is
kept, corrected, because a whole architecture was justified by it: `aif run` used
to refuse to start unless stdin was a terminal, on the grounds that a station
spawned from inside a session could never authenticate.

What was observed on 2026-07-16 was real:

```
401 {"type":"authentication_error","message":"Invalid authentication credentials"}
```

What was inferred from it was not. The conclusion — a session holds an OAuth
credential it does not hand down, so every nested run 401s — was never isolated
against the other things in that environment.

**Re-probed 2026-08-05, claude 2.1.212.** A `claude -p` spawned from inside a
Claude Code session, itself OAuth (`CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH=1`, no
`ANTHROPIC_API_KEY`), returned `is_error: false` and did its work. Twice, on
different prompts. The nested call authenticates.

So the honest statement is the diagnostic one that was always at the bottom of
this entry, and nothing more than it: **if a nested run 401s, look at where you
are before you debug the harness.** It can happen. It is not a law, and no design
should rest on it. The one that did has been rebuilt (`docs/REBUILD.md`).

---

## 8. A subagent's usage is fully recoverable from its own transcript

Claude Code writes one transcript per subagent:

```
~/.claude/projects/<slug>/<session-id>/subagents/agent-<id>.jsonl
~/.claude/projects/<slug>/<session-id>/subagents/agent-<id>.meta.json
```

Every assistant turn carries `message.usage` (all four token classes) and
`message.model`; the `.meta.json` carries `agentType`, `description`,
`toolUseId` and `parentAgentId`. Rolling one up yields exactly what a
`claude -p` envelope reports — measured against a live run.

This matters because "an in-session subagent reports no usage" was the reason
the pipeline shelled out to `claude -p` once per station, which in turn is why a
user could not see any of the work. It is false. The transcript route is also
strictly better: it works under subscription auth, where `total_cost_usd` is
structurally `0` (#2); it survives a failed station, because the file is written
as the run happens rather than assembled at the end; and it is per-turn, so a
run that ground through its turn budget looks like grinding.

**Two traps, both found by measuring rather than reading:**

- **`message.usage` repeats per content block.** One measured file had 36 rows
  carrying usage for 14 real requests. Sum them naively and the cost inflates
  ~2.5×. **Dedupe by `message.id`.**
- **Some entries carry `model: "<synthetic>"`.** Not billed. Filter them out, or
  a single one contributes ~10k phantom tokens.

## 9. Hook payloads say who is calling — and the absence of a field is the signal

`SubagentStop` receives, on stdin:

```json
{ "agent_id": "a7b7…", "agent_type": "general-purpose",
  "agent_transcript_path": ".../subagents/agent-<id>.jsonl",
  "transcript_path": ".../<session>.jsonl",
  "last_assistant_message": "…", "session_id": "…", "cwd": "…" }
```

`agent_transcript_path` is a dedicated field pointing at that one subagent's
transcript — no guessing from timestamps.

`PreToolUse` carries `agent_id` and `agent_type` **only when the call originates
inside a subagent.** From the main session the keys are absent entirely, not
empty:

```
from a subagent:     { "agent_id": "a7b7…", "agent_type": "general-purpose" }
from the session:    { }
```

That absence is a usable discriminator, and the guard hook is built on it: it is
how "the orchestrator is writing this" is told from "a station is writing this".

Hooks also inherit the parent process's environment — probed, because the write
ban depends on `aif run` exporting a marker the hook can see.

## 10. `junit.py` emits one line, not one line per case

It prints a JSON array. `wc -l` on its output returns 0 for a perfectly good
report, which is how a toolchain probe came to declare a working project broken.
Count with `jq 'length'`.

Small, and recorded because it is the exact shape of mistake this file exists
for: an interface assumed from its name instead of run once.

---

## 11. A hook's exec bit is load-bearing, and a fail-open hook loses it silently

`meter.sh` shipped as mode `644`. The runner execs a `type: "command"` hook
directly, so it failed on every `SubagentStop` — and because the hook is
deliberately fail-open (metering must never block a subagent from finishing),
nothing said so. One whole ticket ran with 17 ledger entries, all of them gate
rows and not one station row, while the ledger looked complete.

Three separate things had to be wrong at once, and each is worth its own note:

- **`cp` preserves mode**, so a 644 in the set propagated to every install. The
  fix is a `chmod +x` pass over `.aif/hooks/` in `cmd_init`, placed *after* the
  install loop rather than beside the `cp` — the `unchanged` branch skips `cp`
  entirely, so a project that already had the bad copy would never be repaired
  by a re-init.
- **Gates hid the problem from the tests.** Everything else aif runs is invoked
  as `/bin/bash <path>`, which works at any mode; `check-set.sh` tested the guard
  hook that way too. So the one file whose exec bit mattered was the one file
  nothing verified. The check now asserts the mode itself.
- **Content hashing cannot see this.** The manifest records sha256, so a
  mode-only difference is invisible to it — which is why the repair pass has to
  be unconditional over what is on disk rather than driven by the verdict.

The general lesson is about fail-open by design: it is the right choice here
(losing the record of work beats losing the work), but it converts every failure
into missing data that reads as a cheap run. Anything fail-open needs a reader
that can tell "nothing happened" from "nothing was recorded". `aif cost` does
that by looking for gate rows next to absent station rows.

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
