---
name: aif-setup
description: Set the foundry up on this machine — find out which roles (analyst, project manager, worker) can run here and what each is missing, fix what can be fixed, ask the user only for what only they have (which board, a token they create themselves), and never claim readiness that `aif doctor` did not confirm. Use right after `aif init`, when a role fails for a missing tool or token, or when the user invokes /aif-setup.
requires: []
---

# aif-setup — the machine, made ready

The user cannot know what their machine lacks. A project manager that silently cannot
reach the board, a worker whose test command writes no report, a token that expired —
each reads as "nothing happened". This skill turns that into a table with a ✓ or an ✗ per
role, and then works down the ✗ list with the user.

## The order of trust — and it is the design

1. **`aif doctor` is the verifier.** It probes each capability for real: `board` means a
   token resolved *and* one call to the API succeeded *and* the six columns exist. Run it;
   read its output; never conclude anything about readiness that it did not print.
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

`--probe` runs the project's test command once — a side effect, which is why it is
opt-in, and why it is needed here: the worker cannot be called ready without it. Read
`roles[]`: each has `ready` (`true`, `false`, or `null` for "not known"), `missing[]`
and `unknown[]`, each entry a capability with `doctor`'s own explanation.

Show the table as it is — one line per role, ✓ / ✗ / ? — before doing anything.

### 2. Work down the missing capabilities, one at a time

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

**`test-toolchain`** — the worker needs it.

- `doctor` says what is wrong: no `project.json` (→ `aif project init`), the test
  command wrote no report (→ a JUnit reporter is missing, e.g. `jest-junit` or
  `pytest --junitxml`; propose the install command for this project and run it only
  when the user says so), or no test cases were parsed (→ the format is not JUnit, or
  the suite collected nothing — a project with no tests yet cannot be worked; say so).
- Fix, then `aif doctor --probe` again.

**`claude`** — the runner. `brew install --cask claude-code` on macOS; then `claude`
once to log in. You cannot log in for them.

**`git-worktree`** — git 2.5 or newer. Almost always present; if not, say which git
they have.

**`python3`** — optional; without it the gates read only the suite's exit code. Say so
and move on unless the user wants it.

A capability marked `unknown` is not a failure — it was not probed. `--probe` answers it.

### 3. Record what was deliberately skipped

If the user decides a role is not for this project — "no board here", "no worker on this
laptop" — say which roles stay ✗ and why, so the next person reading `aif doctor` knows it
was a choice. Do not talk them into it.

### 4. Measure again, and stop

```bash
aif doctor --probe
```

Show the roles table. That is the result — not your summary of it.

## What this skill cannot do — said so it does not oversell

- It cannot verify a token it never saw, and it must never see one. `aif board check`
  verifies it by using it.
- It cannot make a project with no tests workable. The worker's gates read a test
  report; without one there is nothing to judge against.
- It cannot know that the board it configured is the *right* board. It maps the one it
  was given and prints the mapping so the user can see it once, before a card is moved
  to the wrong column silently.
