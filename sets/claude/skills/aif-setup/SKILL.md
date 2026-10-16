---
name: aif-setup
description: Set the foundry up for this project and this machine — whatever the stack (any test runner, web, mobile, a game engine) — by writing the test contract the gates read and proving it with the probe, then find out which roles (analyst, project manager, worker) can run here and what each is missing, fix what can be fixed, ask the user only for what only they have (which board, a token they create themselves), and never claim readiness that `aif doctor` and the probe did not confirm. Use when `aif setup` opens this session, right after `aif init`, when a role fails for a missing tool or token, or when the user invokes /aif-setup.
requires: [claude]
---

# aif-setup — the machine, made ready

The user cannot know what their machine lacks. A project manager that silently cannot
reach the board, a worker whose test command writes no report, a token that expired —
each reads as "nothing happened". This skill turns that into a table with a ✓ or an ✗ per
role, and then works down the ✗ list with the user.

## The order of trust — and it is the design

1. **`aif doctor` is the verifier, and `.aif/gates/probe.sh` for the tests.** Each probes
   for real: `board` means a token resolved *and* one call to the API succeeded *and*
   the six columns exist; `test-contract` means the probe's test was written into a copy
   of the tree, run, and read from the report as the gates read it. Run them; read their
   output; never conclude anything about readiness that they did not print.
2. **You are the explainer and the fixer.** You say what a line means in plain words, you
   fix what a command can fix, and you ask the user for the one thing only they have.
3. **You never declare readiness.** The last thing you do is run `aif doctor` again and
   show its table. If it still says ✗, it is ✗.

## Secrets never pass through you

A token pasted into this chat lands in a transcript on disk. So when a token is needed,
you do **not** ask for it. You print where to get it and this command, and the user runs
it **in their own terminal** — it reads with echo off and stores in the OS keychain:

```bash
aif secret set TRELLO_TOKEN
```

Then you run `aif secret check TRELLO_TOKEN` (it says whether it is set, never what it
is) and `aif doctor --json` again. If a user pastes a token into the chat anyway, say
that it should be rotated, and still point them at the command.

## Procedure

### 1. Measure

```bash
aif doctor --json --probe
```

`--probe` runs the project's test command once AND spawns the runner once — side
effects, which is why it is opt-in, and why it is needed here: the worker cannot be
called ready without both. Read
`roles[]`: each has `ready` (`true`, `false`, or `null` for "not known"), `missing[]`
and `unknown[]`, each entry a capability with `doctor`'s own explanation.

Show the table as it is — one line per role, ✓ / ✗ / ? — before doing anything.

### 2. The test contract — first, whatever the stack

When `aif setup` opened this session, its first message holds what aif read before
it: the runner the repository suggests, the state of `.aif/project.json`, the build
and package files at the root. Start from those facts, and check each.

Every gate after the plan reads one thing about this project's tests: the JUnit XML
report `test.command` writes. Whatever the runner — jest, vitest, go test, cargo,
xcodebuild, Gradle, an engine's automation — the gates need four things from it, and
`.aif/gates/probe.sh` checks all four:

1. a report appears at `test.report.path`, as JUnit XML, whether the tests pass or fail;
2. a new test file is collected: it is a test by `test.roots` / `test.files`, and the
   runner selects it;
3. each `<testcase>` names its file, repo-relative — `@file`, or for pytest a dotted
   `@classname` — which is how verify-red tells a ticket's tests from the rest;
4. a test's id (`classname::name`) keeps the criterion's marker the stations put in its
   name — `PROBE-1 AC-001` in the probe — and the same id comes back on every run; a
   failing assertion reads as `failure_classes.legitimate`, a file that cannot load as
   `failure_classes.broken` (or is left out of the report).

Work it out in this order, and say what you find as you go:

1. **How the tests run here, headless.** Read what the project declares — its package
   scripts, Makefile, CI workflows (`.github/workflows`, `.gitlab-ci.yml`), README, the
   test files themselves. Run the command once, as it is, and read what it prints. A
   test that needs a device or an editor is still run headless here: a simulator
   destination for `xcodebuild test`, `./gradlew test…` for JVM unit tests, the
   engine's command-line automation for Unreal — whatever the project's own CI does.
   **No tests at all, or no runner?** Say so plainly. You may propose setting one up,
   and install it only on the person's yes; without tests the worker cannot run here.
2. **`.aif/project.json`.** If aif ships a template for the runner (`aif project init
   --help` names them), `aif project init <runner> --no-checks`; otherwise `aif project
   init <runner-name> --no-checks` writes the base template with the contract empty.
   Then write, for this project:
   - `test.command` — the whole suite, headless, writing JUnit to `test.report.path`
     even when tests fail (the exit code does not matter; the report does). From the
     repository root, no interactive prompts, no watch mode.
   - `test.roots` — the trees that hold only tests and what only they use: helpers,
     fixtures, setup (`test/`, `tests/`, `__tests__/`). Every file under a root is
     the tests' to the gates — verify-red freezes it, green re-hashes it, scope keeps
     the implementation out of it — so a tree that holds the code is never one, even
     when its unit tests sit beside their sources there: `src/` with `x.spec.ts`
     beside `x.ts` is no root, and those tests are found by `test.files`. With no
     tree of tests at all, `[]`. The probe refuses a root whose tests sit beside the
     code they test.
   - `test.files` — what makes a file a test here by its name or place: globs, against
     the path when one holds a `/`, against the file name when not — `*/Tests/*`,
     `*Tests.swift`, `*Spec.cpp`, `*.test.ts`. The defaults are the jest and pytest
     conventions.
   - `failure_classes.legitimate` — patterns of this runner's *assertion* failure
     message (keep `aif: not implemented`); `failure_classes.broken` — patterns of a
     test file that could not load, compile or be collected.
   - `deps` — this stack's manifests and the lockfiles that pin them, as
     `[{ "manifest": "Podfile", "lockfiles": ["Podfile.lock"] }]` (a manifest may be a
     glob, `*.uproject`); `prepare` — what makes a fresh checkout able to run the
     suite (`npm ci`, `pod install`, `uv sync`).
   - `copies.link` — installed dependencies every copy of the tree may share,
     read-only (`node_modules`, `Pods`, `/vendor/bundle`); `copies.leave_out` — big
     ignored build output the copies should not carry (`Intermediate`,
     `DerivedDataCache`, `target`). Never link a build's output: the copies would all
     write into it.
   - `checks` — the rest of Done (lint, type-check, build), each bound to phases. For
     a compiled language bind the build to `contract` (the plan's skeleton must
     compile) and `red` (the tests must compile), so a file that does not compile is
     found before the suite.
3. **An adapter, only if the runner cannot write that report itself.** Write it under
   `.aif/adapter/` — a script `test.command` runs, that runs the suite and converts
   what the runner writes (Go's `-json`, an `.xcresult`, Unreal's `index.json`) into
   JUnit with `@file` on every case and the test's own name in `@name`. It runs in CI
   from a fresh checkout with no aif: POSIX shell and python3's standard library only,
   nothing fetched at run time. Prefer a reporter the runner already has
   (`jest-junit`, vitest's `--reporter=junit`, `pytest --junitxml`,
   `gotestsum --junitfile`, `cargo nextest` with a JUnit profile) over writing one;
   installing it is the person's yes.
4. **`test.probe`** — `{ "path", "red", "green", "broken", "watch" }`: one test in this
   project's language, written as a station would write a test of ticket `PROBE-1`'s
   first criterion — `PROBE-1 AC-001` in its name, separators kept — failing by an
   assertion in `red`, the same test passing in `green`, the same file unable to load
   in `broken`; `path` where the project's tests live; `watch` the runner's
   configuration files, so a change to one is proven again.
5. **Prove it:** `bash .aif/gates/probe.sh`. It prints what does not hold and the fix;
   change the configuration (never the gates) and run it again until it says the
   contract holds. Then `aif doctor --probe`.
6. **`.aif/stack.md`** — what the plan and tests stations are told about this stack,
   appended to their instructions before every ticket. Read `.aif/stacks/jest.md` or
   `.aif/stacks/pytest.md` first and write this project's the same way, in its terms:
   how a run is read (the report, how a test's id is built, what a file that fails to
   load does to the report); the contract — a skeleton in this language that loads or
   compiles, keeps the real names and types, and whose every body throws, raises or
   fails with exactly `aif: not implemented: <name>`; the tests — the marker in the
   test's name as the probe's shows, the project's way of mocking a boundary, no
   snapshots, no clocks or randomness unfaked; that the tests station runs
   `aif _verify <TICKET>` after writing. Open it with a `# ` title. Facts the gates
   enforce or the runner has, nothing else.
7. **Commit**, on the person's yes: `.aif/project.json`, `.aif/stack.md`,
   `.aif/adapter/` — the stations run in a checkout cut from HEAD.

When `aif project init` wrote a template's probe and the probe already holds, say so
and move on: there is nothing to write.

### 3. Work down the other missing capabilities, one at a time

**`board`** — the analyst, the project manager and the worker all need it.

- First ask which board this project uses: **Trello**, or **none** (the local board on
  this machine). Do not assume.
- *none* → `aif board init local`. That is the whole fix.
- *Trello* → in this order:
  1. the API key and token. Tell the user: create them at
     `https://trello.com/power-ups/admin` (a Power-Up gives an API key; the key page has
     a link that issues a token for their account). Then, in their terminal:
     `aif secret set TRELLO_KEY` and `aif secret set TRELLO_TOKEN`. Wait for them to say
     it is done; confirm with `aif secret check` for each.
  2. the board: ask for its URL (`https://trello.com/b/<id>/<name>`).
  3. `aif board init trello --board <url>`. It maps the six columns — Backlog, Ready, In
     Progress, Review, Done, Needs Human — to the board's lists by name and prints the
     mapping. For any it could not map, ask: create the missing lists (`--create-lists`),
     or should an existing list with a different name serve? If the latter, name the
     mapping and set it in `.aif/project.json` under `board.lists` by list id
     (`aif board init` prints ids next to names).
  4. `aif board check`. Read what it says.

**`test-toolchain`** and **`test-contract`** — the worker needs both, and step 2 is
how they are fixed: the toolchain is the command writing a report at all, the contract
the four facts the probe proves.

**`test-guide`** — the worker needs it. `.aif/guide/tests.md` is this project's guide
to its own tests, and the worker appends it to the plan and tests stations' prompts;
`doctor` says which of three things is wrong, and each has one fix:

- *no guide* → `aif project guide`. It writes the file from what the repository
  declares — the runner's configuration, where the tests, fixtures, doubles and
  factories live, what the tests import most, which tests to read first — and leaves
  one section for a human: **How this project mocks its boundaries**. That section is
  the part worth your turns. Read the tests the guide names under *Tests to read
  first* and the files under *Fixtures, doubles, factories, setup*, and write it from
  what you read, not from memory: one line per boundary the tests do not cross for
  real (the database, the clock, HTTP, the filesystem, a queue, a device) — the
  double this project uses for it, and where it lives, as a path in backticks.
  Replace the `_Not written yet._` paragraph with those lines; touch nothing between
  the `<!-- aif:guide:begin` and `<!-- aif:guide:end -->` markers. Show the user the
  section and change it as they say; a boundary you could not find a double for is
  written as such ("no double: the tests hit the real X"), not invented.
- *paths that no longer exist* → `aif project guide` regenerates the block; a stale
  path in the human's section you fix by hand, with the user.
- *not committed* → ask, then `git add .aif/guide/tests.md && git commit` — the
  stations run in a checkout cut from HEAD and read that copy.

Then `aif doctor --json` again. The `stack` line under *Project* is not a capability:
a runner aif ships no fragment for leaves the stations on their general rules, and
you say so rather than fix it; `test.kind` missing from `.aif/project.json` while the
command plainly runs jest or pytest is one line to add, with the user's yes.

**`claude`** — a session to type a skill into. `brew install --cask claude-code` on
macOS. If this one is ✗, the user cannot even be reading you, so say it and stop.

**`claude-headless`** — the worker spawning `claude -p` and getting an answer. It is a
*different* question from the one above and fails on its own: the CLI keeps its own
stored OAuth session, separate from the app the user is talking to, and it expires
while everything they can see keeps working (docs/FINDINGS.md #7). The fix is theirs to
run, in their terminal: `claude`, then `/login` if it does not ask. You cannot log in
for them. Reported `?` until `aif doctor --probe` actually spawns one.

**`git-worktree`** — git 2.5 or newer. Almost always present; if not, say which git
they have.

**`python3`** — optional; without it the gates read only the suite's exit code. Say so
and move on unless the user wants it.

A capability marked `unknown` is not a failure — it was not probed. `--probe` answers it.

### 4. Record what was deliberately skipped

If the user decides a role is not for this project — "no board here", "no worker on this
laptop" — say which roles stay ✗ and why, so the next person reading `aif doctor` knows it
was a choice. Do not talk them into it.

### 5. Measure again, and stop

```bash
aif doctor --probe
```

Show the roles table. That is the result — not your summary of it.

## What this skill cannot do — said so it does not oversell

- It cannot verify a token it never saw, and it must never see one. `aif board check`
  verifies it by using it.
- It cannot make a project with no tests workable on its own. The worker's gates read
  a test report; without one there is nothing to judge against. It can set a runner
  up, on the person's yes.
- It cannot vouch for the contract it wrote. The probe does — and proves it again
  before every run whenever what it stands on moves.
- It cannot know that the board it configured is the *right* board. It maps the one it
  was given and prints the mapping so the user can see it once, before a card is moved
  to the wrong column silently.
