# Defects — 0.9.0, found by `aif work --loop` on four tickets

Three problems reported from one `aif work --loop` on a React Native /
TypeScript project (jest + jest-junit, a Trello board): OPES-69 and OPES-52
stopped at `verify-red`, OPES-45 at `green` after three attempts, OPES-41 at
`green` after three attempts. The loop's two-in-a-row stop then parked two
healthy cards in Needs Human. #4–#6 turned up while fixing them.

Worked against `c8058a2` (0.9.0) on 2026-09-29, macOS 26.6.2 (Darwin 25.6.0),
bash 3.2.57, jq 1.8.2, git 2.50.1. Each entry says how it was established:

- **probed** — reproduced here, with the observation quoted;
- **read** — established from the code alone;
- **reported** — taken on the reporter's word; the mechanism is confirmed,
  the trigger is not.

Every fix is exercised by `scripts/check-work.sh`, scenarios 20–24, through the
scripted runner: no model, no network.

---

## Open

None of the three. What was deliberately not done, and why, is under each.

---

## Closed

### 1. `verify-red` blames the repository for a red its own tests caused — probed

The repository was green before the tests station ran: `aif doctor --probe`
passed on main, 204 cases, exit 0, and both worktrees were cut from that
commit. Both tickets stopped with:

```
error: verify-red could not render a verdict — that is the environment, not the artifact:
  ERROR  the pre-existing suite is not green (1 failing) — fix the repo before authoring tests; red is meaningless otherwise
```

The one red "pre-existing" test was a jest test that shells out to
`npx tsc --noEmit` over the whole tree. It went red because the new tests
import modules the plan's `files.create` had not produced yet —
`error TS2307: Cannot find module './utils'` — which is exactly what a
red-first test in TypeScript has to do.

`verify-red` ran the suite once, after the tests station had written its
files, and treated every failure outside `files.tests` as pre-existing. With
no baseline it could not tell *red before this ticket's tests existed* (the
environment — stopping is right) from *green before, red once they landed*
(the artifact interacting with the suite). It reported the second as the
first, with advice that was false for it, and with a count instead of names.
Each such run had already spent the plan and tests stations on opus: OPES-52
took 25 minutes, 3 dispatches, ~110k output tokens.

Reproduced with the harness's stub suite: a pre-existing `t0` that fails
while `tests/t1.py` exists and the implementation does not.

**Fixed.** A failure outside the declared test files is now measured against a
baseline: the suite once more, in a copy of the tree as it stood when the tests
station was dispatched (`aif_g_scratch_at`, from the run record's
`dispatch_base`). Only on that path — a green suite pays nothing. Three
answers:

- **red there** — the repository's. Still a stop, but the ids are named, on the
  first line (which is the line the ledger and the report keep):
  `the pre-existing suite is red without this ticket's test files too (1 failing: tests.t0::t0)`;
- **green there** — the new tests' interaction with the suite. Admitted,
  recorded in `tests.lock.json` as `red_with_tests`, and printed on the pass
  path. `green` requires the whole suite, so the implementation has to clear
  it — and see #2 for what `green` does when it cannot;
- **absent there** — a test that exists only with this ticket's files but lives
  outside the declared ones: the tests' own. Rejected, naming the file; or, if
  the report names no file for it at all, a stop that says the reporter must
  write one (jest-junit: `addFileAttribute`).

Where the baseline cannot be measured — no commit, a copy that writes no
report — the old stop stands, with the ids and the reason.

And the line `aif _gate` put above every exit 3, *"that is the environment, not
the artifact"*, no longer guesses: it was half of the misattribution the
reporter quoted. A 3 is the environment or an artifact the station may not
touch, and the gate's own words say which.

**Not done as suggested.** The report proposed recording per-test status at
`_aif_work_ready_worktree`'s probe. That snapshot is taken before intake, on
every invocation — and on a resume after this very stop, the worktree already
holds the uncommitted test files of the run before, so the "baseline" would
include the red it was meant to explain. The gate measures its own baseline
from the dispatch commit instead, which also makes it hold when the gate is
run by hand or in CI, where there is no worker.

### 2. A test that does not type-check is frozen, and `green` spends every attempt on it — probed

OPES-45's tests station wrote, in a declared test file:

```ts
getCategoryForTransaction: jest.fn(() => CATEGORIES.groceries)
```

— `Mock<Category, []>`, where the file types the field
`Mock<Category | null, [string]>`. jest runs it (babel strips types);
`verify-red` could not run `tsc`, because the new tests import modules not
written yet; so the file was frozen. The implementation was complete — the
whole suite passed in the worktree, 211/211 — and the project's `typecheck`
check then failed at `green` on all three attempts, over a frozen file the
implement station may not touch. About 49 minutes before the stop.

Two parts, and both were real:

**The complaint lost the location.** `aif_g_checks_run` passed `tail -1` of the
check's output. For tsc that was `Source has 0 element(s) but target requires
1.` — no file, no line. The station could not see where the error was.
**Fixed:** the violation carries the check's first fifteen non-blank lines, as
indented continuation lines under it (`aif_g_report` now prints a line that
starts with whitespace as the continuation of the problem above it, not as a
problem of its own).

**The tests stayed unchecked.** `docs/DEFECTS-4.md` #5 had already said a check
bound to `red` is the place for a type-check of the test files — and it could
not be one: a whole-tree `tsc` at red fails on every red-first import, so the
red phase was rejected for being red by design. **Fixed:** a check may carry
`legitimate_at_red`, a list of patterns for what a missing implementation
causes (for tsc: `error TS2307`, `error TS2305`, `error TS2724`). At red, a
line of its output that names a declared test file and matches none of them
rejects the tests, with the line and its continuation lines; the tests station
fixes the mock before the freeze. The ledger records such a check as
`expected`. A red check that fails without naming any test file at all is a
stop (`unlocated`): the repository fails it already, or it prints paths not
relative to the root — read as "expected" it would have been a check that
never fails. `aif project check` refuses the field on a check not bound to
`red`, where nothing would read it.

**And a failure located in a frozen file stops the run.** Not every error
located in a test file is the test's: a test calling a function the new code
declares too narrowly is reported at the call site, in the test, and the
implementation can fix it. So `green` measures it: when a required check fails
and its output names a frozen test file, the same check runs once more in the
tree without the implementation. If every line of the failure recurs there,
the implementation added none of it — exit 3, at the first attempt. If any line
is new with the implementation, it stays a rejection, with the check's own
words. The same measurement attributes a pre-existing test that went red with
the tests (#1) and is still red: failing the same way without the code, it is
out of the implementation's reach.

A limit worth knowing: for a whole-tree check that runs *inside* the suite (the
jest test of #1), the comparison is over junit failure messages, which
`junit.py` cuts at 800 characters. A long `tsc` dump may be cut before the line
that matters; `green` then rejects rather than stops, as before. OPES has since
moved its type-check out of jest into `checks`, which is compared in full.

### 3. A dependency installed inside a station bypassed the lockfile — reported; the policy hole read, the consequence probed

OPES-41 adds a native dependency. The plan listed `package.json` in
`files.change` and not `package-lock.json` — it could not have: lockfiles sat
on the shared denylist, "until a sanctioned route for dependency changes is
answered", and manifests did not. After `prepare` (`npm ci`, 13:13), something
in the stations installed `@dr.pogodin/react-native-fs` (13:44) without
updating the lock, which re-resolved unrelated packages —
`react-native-reanimated` 4.2.3 → 4.7.0, `react-native-worklets` 0.8.1 → 0.8.3,
an incompatible pair. Twelve pre-existing tests went red, and none of three
implement attempts could fix them, because `node_modules` is not source. Which
command the station ran is not known; that it went around the lockfile is.

**Fixed, as the route the denylist was waiting for.** A manifest and its
lockfile change together or not at all:

- **the plan gate** requires the lockfile whenever the plan names a manifest —
  the nearest at or above it, so a workspace package's `package.json` needs the
  root lock — and refuses a lockfile named without a manifest it pins. The
  table (`aif_g_lock_names`) covers npm, yarn, pnpm, poetry, uv, cargo and go;
- **`scope`** lets a lockfile move only when the *plan* names it, and
  `aif _amend-plan` refuses every lockfile: a dependency is the plan's
  decision, not something to widen into mid-implementation;
- **the worker** runs `prepare` again, from the lockfile, after any station
  whose changes touch a manifest or a lockfile, before any gate reads the
  suite. `npm ci` refuses a manifest the lock does not match, so a package
  installed around the lock comes back to the station as a rejection in npm's
  own words, recorded in the ledger as the `prepare` verdict and capped like
  any other;
- **`green`** stops rather than retries when a pre-existing test's breakage is
  out of reach of any diff to the manifest: one that passed at the freeze and
  still fails with the implementation reverted moved outside the tracked tree
  (exit 3, "run prepare in the worktree, then resume"). If the change itself
  moved a manifest or a lockfile, the dependencies it installs are its own, and
  that stays a rejection.

The station prompts say the same: the plan names the lockfile with the
manifest; the implementer uses the package manager, never `--no-save`,
`--no-package-lock` or a hand edit.

**Not done.** `aif land` runs the suite on the merge result in the developer's
checkout, against whatever is installed there; a merge that changes the
lockfile is judged against the old `node_modules`. It says "suite is red" and
undoes the merge, which is safe and unhelpful. Left for its own change.

### 4. `green`'s revert-recheck wrote into the real worktree's index — probed

Found while building the copy #1 and #2 needed (`docs/FINDINGS.md` #20). The
revert-recheck copied the worktree and ran `git -C <copy> checkout <base> --
<file>` in the copy. A copy of a linked worktree carries its `.git` *file*,
which points at the real worktree's gitdir — so the checkout restored the
copy's file and staged `<base>`'s blob in the **real** worktree's index:

```
wt index before: 100644 8c1384d… f
copy file: v1
wt file: v3-uncommitted
wt index after: 100644 626799f… f      (= <base>:f)
git status: MM f
```

In the worker's own flow the dispatch base is HEAD, so the staged blob equalled
HEAD's and nothing showed. After a station commit it would not have: the next
report commit would have committed the revert. **Fixed:** `aif_g_scratch_at`
asks git only read-only questions of the real repository (`diff --name-only`,
`ls-files --others`, `cat-file -e`, `show <base>:<path>`) and never runs git in
the copy. It also reverts everything the station changed since dispatch, not
only the manifest's files — an amended path or a stray file is the
implementation too — and leaves `.aif/worktrees/` out of the copy.

Two latent defects of the same shape went with it: a check command read
through jq's `@tsv`, which doubles every backslash — it ran as a different
command from the one in `project.json` — and a check that reads stdin
swallowing the rest of the check list. Both are read raw and run with stdin
from `/dev/null` now.

### 5. The worktree probe refused a worktree for a collision that was not there — probed

`aif_doctor_probe` asks whether the runner collects `.aif/worktrees/` by
grepping the suite's output and report for that string — and the worker runs
the probe INSIDE a worktree, where every absolute path runs through
`.aif/worktrees/`. A red pre-existing test whose failure carries its own stack
trace (jest's do) read as "it collects the worker's checkouts", and the run
stopped with advice about `testPathIgnorePatterns`. Reproduced in
`scripts/check-work.sh` scenario 20 once its stub suite printed a stack line.
**Fixed:** the probed root's own path, in both spellings, is taken out before
the grep; a nested checkout still names `.aif/worktrees/` after it, and
scenario 17 still catches that.

### 6. `scripts/demo.sh` did not parse — probed

It had not parsed since `12830b1`: an apostrophe escaped for a
single-quoted string (`'"'"'`) inside two double-quoted `note` lines. It is not
run by `make check`, which is how that lasted; it runs clean again.
