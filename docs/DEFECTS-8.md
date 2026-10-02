# Defects — 0.11.0, found upgrading a project from 0.9.0

Five problems found taking a React Native / TypeScript project (jest +
jest-junit, a Trello board) from 0.9.0 to 0.11.0. The upgrade was `brew upgrade`,
then `aif init anthropic`, then the two steps 0.11.0 newly asks for, `aif project
guide` and `aif doctor --probe`. None stops a run outright. Each leaves an
upgraded project working differently from what it is told:

- a gate laxer than the stations are told it is;
- a guard that never sees the shell;
- a guard that sees too much of it;
- a smaller budget than the stage was designed for;
- a dry run that announces deletions it does not make.

The order is roughly the order to fix them in.

Worked against `2aa2160` (0.11.0) on 2026-10-02, macOS 26.6.2 (Darwin 25.6.0),
bash 3.2.57, jq 1.8.2, git 2.50.1, python 3.13.1, Claude Code 2.1.226. Each
entry says how it was established:

- **probed** — reproduced here, with the observation quoted;
- **read** — established from the code alone.

Every probe ran in a scratch repository. 0.9.0 and 0.5.2 were taken from their
tags with `git archive` and run from the extracted tree. #2 and #3 spawn
`claude -p`: the runs `aif doctor --probe` makes, and one session with a
subagent. The rest are offline.

The project has since set its own `.aif/project.json` and `.claude/settings.json`
to what 0.11.0 ships, so it no longer reproduces #1, #2 or #4; the probes below
still do. That was a fix to its own configuration, not a workaround for aif:
the next project to upgrade meets all five.

All five are fixed on `main` after 0.11.0, each exercised offline —
`scripts/check-work.sh` scenarios 37 and 38, `scripts/check-set.sh` for the
guard — and the entries below end with what changed.

---

## Open

None.

---

## Closed

### 1. An upgraded project keeps failure classes the 0.11.0 gate no longer means — read; the silence probed

`verify-red` reads `failure_classes.legitimate` from the project
(`sets/claude/gates/verify-red.sh:265`) to decide whether a new test is red for
the right reason. The list is checked after the marker and the broken classes:

```sh
    elif printf '%s' "$msg" | grep -qF -- "$AIF_G_NOT_IMPLEMENTED"; then
      : # red because the behaviour is not built: the skeleton threw
    elif [ -n "$broken_re" ] && printf '%s' "$msg" | grep -qE "$broken_re"; then
      reject=…
    elif [ -n "$legit_re" ] && printf '%s' "$msg" | grep -qE "$legit_re"; then
      : # an assertion did not hold
    else
      reject="… fails for a reason that is neither an assertion nor the missing implementation …"
```

Through 0.10.x the jest template put `Cannot find module`, `is not a function`,
`ReferenceError` and `TypeError` in that list. That was right while a red-first
test imported a module that did not exist yet. 1cbfb8d took them out of the
template and added `toHave`, `toMatch` and `aif: not implemented`: with the
contract on disk, a `TypeError` means the test calls something the contract does
not export. The stations are told exactly that (`sets/claude/stacks/jest.md:30`):

> `TypeError: x is not a function`, `Cannot read properties of undefined`,
> `ReferenceError` are neither: the test calls a name the contract does not
> export or reaches a seam the skeleton does not have, and the gate names the
> test and sends it back.

`.aif/project.json` is not in the manifest, so `aif init` leaves the old list
where it is. In an upgraded project the gate does not send such a test back: it
admits it as red and freezes it. REBUILD-4's §3 gives O3, "the test calls a name
or signature outside the contract", two detectors: "type-check at red; runtime
class". An upgraded project has neither. The runtime class is this list, and the
type-check stays where it was (below). The next look is green's, after an
implement dispatch. And if the implementer adds the name the test assumed, the
test can get past green too, with an interface the plan never decided.

Nothing tells the project. Probed with the project's own file as the upgrade left
it (`board` removed), in a scratch repository with 0.11.0 installed:

```
$ jq -c '.failure_classes.legitimate' .aif/project.json
["expect\\(","toBe","toEqual","toThrow","Cannot find module","is not a function","ReferenceError","TypeError","AssertionError"]
$ aif project check
✓ .aif/project.json is valid (runner command: JEST_JUNIT_OUTPUT_FILE=.aif/tmp/report.xml npx jest --ci --reporters=default --reporters=jest-junit)
  check lint  [green]  npm run lint
  check typecheck  [green]  npx tsc --noEmit
$ aif doctor
  ✓ project.json   valid
  ✓ checks         lint [green], typecheck [green]
  ✓ stack          jest — .aif/stacks/jest.md goes to the plan and tests stations (inferred from test.command; record it as test.kind)
```

doctor already notices one thing an older file lacks, `test.kind`, on the
`stack` line (`lib/doctor.sh:113`). It notices nothing else.

The same file shows a quieter half: the type-check is bound to `green` only.
That was the right binding before the contract, when a red-first test could not
type-check, and it is why this project chose it. `aif project init` now binds the
type-check to `contract`, `red` and `green`, and the plan gate and verify-red are
built around that binding. An upgraded project keeps `green`, with two results:

- O9, a type error inside the test, is found after the freeze instead of before
  it;
- the plan's skeleton is never compiled.

**Fixed.** `.aif/project.json` stays the project's and `aif init` still never
rewrites it; what moved is now *said*, and brought forward on request:

- each template carries `failure_classes.retired` — the patterns an earlier
  template listed as legitimate and this one no longer does — and
  `aif_project_drift` (`lib/project.sh`) compares a file with the template its
  runner names: a retired class still counted as red, a template class the
  file lacks, a type-check (`typecheck` by name, or `tsc|mypy|pyright` by
  command) not bound to `contract` and `red`, a limit the template sets and
  the file omits, a runner inferred rather than recorded;
- `aif project check` lists them; `aif doctor` turns the `project.json` line
  into "valid, but behind its template" and makes `aif project upgrade` the
  next step; the worker warns once at preflight; `aif init` says so at the end
  when the installed set moved;
- `aif project upgrade` brings exactly those fields forward: the template's
  lists first and the project's own additions after, minus the retired ones;
  a type-check rebound to `contract, red, green` keeping any other phase it
  had; the template's limits where the file sets none; `test.kind` recorded.
  Idempotent, validated before it is written, and it leaves the test command,
  the roots, the checks' commands and the board as they were.

### 2. `aif init` never refreshes its own hook registration — probed

For each hook event, init drops its own hooks from the fragment when
`.claude/settings.json` already has that event (`lib/cmd_init.sh:361–382`):

```sh
        jq -e --arg e "$event" '.hooks[$e]' "$settings_dest" >/dev/null 2>&1 || continue
        case "$event" in
          PreToolUse)
            aif_warn "you already have PreToolUse hooks — skipping the guard hook so yours are not replaced"
```

That protects a user's hooks, but it cannot tell them apart from aif's own, so a
project keeps the registration from its first init. 0666171 (0.5.3) added `Bash`
to the guard's matcher, together with the guard's Bash rules. A project
initialised before that keeps `Write|Edit|MultiEdit|NotebookEdit` through every
later init, and the guard never sees a shell command.

Since 0.11.0 that also costs the tests station its verify loop. The station gets
Bash, for `aif _verify` only, once `aif doctor --probe` has watched the guard
deny a command in a spawned run. Without `Bash` in the matcher, the hook is never
called for one.

Probed — 0.5.2 installed in a scratch repository, then 0.11.0:

```
$ grep -o '"matcher": "[^"]*"' .claude/settings.json        # as 0.5.2 wrote it
"matcher": "Write|Edit|MultiEdit|NotebookEdit"
$ aif init anthropic
warn: you already have PreToolUse hooks — skipping the guard hook so yours are not replaced
warn:   register .aif/hooks/guard.sh yourself to keep the test/implementation guard
warn: you already have SubagentStop hooks — skipping the metering hook so yours are not replaced
warn:   WITHOUT IT NOTHING RECORDS WHAT A STATION COSTS. Register .aif/hooks/meter.sh yourself.
warn: nothing left to merge into .claude/settings.json
  4 created, 17 updated, 6 unchanged
$ grep -o '"matcher": "[^"]*"' .claude/settings.json
"matcher": "Write|Edit|MultiEdit|NotebookEdit"
$ aif doctor --probe --json | jq -c '.capabilities."station-guard"'
{"ok":false,"detail":"a spawned run with Bash was NOT denied by the guard — the hook did not fire, or did not reach the model: RAN — the tests station runs without aif _verify until it does"}
```

The same probe, after adding `Bash` to the matcher by hand:

```
{"ok":true,"detail":"the guard denied a command in a spawned run (claude 2.1.226 (Claude Code))"}
```

The project this was found on registered its hooks before 0.5.3. It then went
through inits at 0.5.3, 0.5.4, 0.9.0 and 0.11.0, and the matcher never changed.
That meant ten days of a guard whose `git commit` rule never ran, and from 0.11.0
a tests station without its loop.

Nothing a person reads says so:

- The worker requires `claude-headless git-worktree test-toolchain board
  test-guide` (`lib/roles.sh:41`), so `aif doctor --probe` ends with
  `✓ worker ready`.
- The human-readable output has no `station-guard` line at all. That capability
  is rendered only in `--json` (`lib/doctor.sh:505`).
- The run says, on each dispatch, "tests runs without aif _verify — the guard
  hook has not been seen to deny a command here (aif doctor --probe)"
  (`lib/cmd_work.sh:488`). That sends the reader to a command whose output is all
  green.
- The warning init prints names the wrong cause: the hooks it calls "yours" are
  its own.

Fixing this turns #3 on for every project it reaches. That is how this project
met #3.

**Fixed.** Ours is read off the entry, not remembered: a hook entry whose every
command runs from `.aif/hooks/` is aif's. `aif init` now merges event by event
(`aif_hooks_merge`, `lib/merge.sh`): our earlier entry is replaced by what the
set ships, the user's entries stay beside it, and the output says `register`,
`refresh` (with the matcher ours had) or nothing, and how many of the user's
hooks were kept. The `json_merge` edit is recorded on every init, not only the
one that merged — an init that skipped the merge used to drop it, and uninstall
then left the hooks behind; `aif uninstall` subtracts ours by value and keeps
the user's. `aif doctor` reads the registration before any probe: no guard
entry, or a matcher without `Bash`, is a `station-guard` ✗ with `aif init` as
the remedy, and that capability now has a line in the human-readable output,
under *Stations*.

### 3. The guard takes any subagent for a station — probed

The guard takes the station from the payload's `agent_type` when there is one,
and from `AIF_STATION` when there is not (`sets/claude/hooks/guard.sh:46–53`):

```sh
station="$(printf '%s' "$payload" |
  jq -r '.agent_type // "" | sub("^aif-"; "") | sub("-(routine|careful)$"; "")' 2>/dev/null)"
[ -n "$station" ] || station="${AIF_STATION:-}"
…
[ -n "$station" ] || exit 0
```

The script's header expects the `agent_type` route only for the foundry's own
agents: "when a station runs as a SUBAGENT. No path in the foundry takes that
route today". It also states what must not happen: "a plain `claude` in it must
not find its Write tool policed". But every subagent has an `agent_type` —
`general-purpose`, `Explore`, any agent a project defines — and to this script
each one is a station.

Probed live, in the repository from #2 with `Bash` in the matcher and no
`AIF_STATION` in the environment. A plain `claude -p` session was asked to have
one `general-purpose` subagent run `git stash list`, a read-only command:

```
subagent → Bash {"command":"git stash list"}
tool_result (is_error: true):
a station does not commit, reset or switch branches — the worker commits each admitted station itself, and a commit from here moves the baseline the gates judge you against. Leave the tree as it is; write the code.
```

So Claude Code 2.1.226 puts `agent_type` in a subagent's PreToolUse payload, and
the guard reads it as a station. Synthetic payloads against the same `guard.sh`
show what that means for an ordinary session:

| `agent_type` | call | verdict |
|---|---|---|
| `code-reviewer` | Bash `git checkout -b x` | deny |
| `code-reviewer` | Write `src/app.ts` | allowed |
| `tests` | Write `src/app.ts` | deny |
| `tests` | Bash `npm test` | deny |
| `plan` | Write `src/app.test.ts` | deny |
| *(none)* | Bash `git commit -m x` | allowed |

- Every subagent loses `git commit`, `stash`, `reset`, `rebase`, `merge`, `push`,
  `checkout`, `switch` and `restore`. That includes read-only spellings, and the
  denial message talks about committing.
- A project's own agent named `tests` is held to the tests station in full: it
  may write no file that is not a test, and run no command but `aif _verify`.
- A project's own agent named `plan` cannot write a test.

The foundry's own agents are all named `aif-…`, and the guard already strips that
prefix, so the payload route could accept only those names.

**Fixed.** It does: an `agent_type` that does not start with `aif-` names no
station, and the environment then decides — unset in a plain session, so a
general-purpose subagent, a code reviewer or a project's own agent called
`tests` is not policed; set inside a station's process, so a subagent spawned
there is held to that station. `scripts/check-set.sh` holds both.

### 4. A `project.json` from before 0.11.0 runs the new stage on the old dispatch cap — read

`lib/cmd_work.sh:1305`:

```sh
  dispatches_max="$(jq -r '.limits.run_dispatches_max // 12' "$project")"
```

`aif work --help` says the same: "limits.run_dispatches_max (12 station runs)"
(`lib/cmd_work.sh:81`). Everything else says 16:

- the 0.11.0 templates (`sets/claude/project.templates/jest.json:49`,
  `pytest.json:43`);
- REBUILD-4 §2.4, which budgets "dispatches per run | 16";
- REBUILD-4 §7, which records the change as "16 in the templates".

The number was raised for the new stage: up to two repairs and a replan, on top
of the plan, tests and implement retries. That stage runs in every project, but
the higher cap reaches only a project created from a 0.11.0 template. A project
that never named the key, as this one had not, runs the new stage on 12. Neither
`aif project check` nor `aif doctor` mentions it; #1's probe shows both on such a
file.

The same table gives the tests station 4 attempts at the freeze ("tests rejected
at freeze | 4"). The worker holds every stage to one `limits.attempts_max`
(`lib/cmd_work.sh:1304`, `:1377`), which is 3 in both templates. Nothing gives
the tests station a fourth. Either the table or the code is wrong, and which one
is a maintainer's decision.

**Fixed.** The fallback is 16, in the code and in `aif work --help`, and a file
that omits the key is one of the things `aif project check` names (#1). The
table was right: a station's attempts cap is its own `max_attempts` in
`aif:meta` over `limits.attempts_max`, the way `max_turns` already was, and
`aif-tests.md` declares four — it has iterated with the dry verifier already,
and a fourth informed retry is cheaper than a human. The repair loop uses the
same cap. `docs/CYCLE.md` draws the attempts per station from the agents' files.

### 5. `aif init --dry-run` reports every updated file as retired — probed

The install loop adds a created or updated file to `$files_tsv` only when it
actually writes the file (`lib/cmd_init.sh:254–267`, inside
`if [ "$AIF_DRY_RUN" -eq 0 ]`). The retire pass then treats any manifest path
missing from `$files_tsv` as one the set no longer ships (`:303`):

```sh
    cut -f1 "$files_tsv" 2>/dev/null | grep -xF "$prev_path" >/dev/null && continue
```

Under `--dry-run` every updated file is missing, so each one is listed twice,
first under `update` and then under `retire`, and counted in both. The unchanged
and conflict paths add their row in both modes (`:242`, `:250`), so only updates
are misreported. The real run retires none of them.

Probed — 0.9.0 installed in a scratch repository, then 0.11.0:

```
$ aif init anthropic --dry-run
(dry run — nothing will be written)
  update    .claude/skills/aif-review/SKILL.md
  …                                              12 update, 2 create
  update    .aif/hooks/guard.sh
  retire    .claude/skills/aif-review/SKILL.md
  …                                              the same 12
  retire    .aif/hooks/guard.sh
  import    CLAUDE.md

  2 created, 12 updated, 13 unchanged, 12 retired
$ aif init anthropic
  …
  2 created, 12 updated, 13 unchanged
$ ls .aif/gates/green.sh .aif/hooks/guard.sh .claude/agents/aif-plan.md
.aif/gates/green.sh
.aif/hooks/guard.sh
.claude/agents/aif-plan.md
```

The dry run is the only preview an upgrade has, and here it announces the
deletion of every file the upgrade updates: five gates, four agents, two skills
and the guard hook. Taken at its word, it says not to run the upgrade. Knowing
the real run was safe meant reading `cmd_init.sh` first.

**Fixed.** A created or updated file gets its manifest row in a dry run too,
with the digest the real run would record (the source's), so the retire pass
sees the same list either way. The preview's counts now match the real run's.
