# Defects — 0.10.0, found asking what the tests station can check

One problem, found while deciding whether the tests station may run the suite.
It has no Bash and keeps none, yet its prompt asked it to "confirm every test
file in the plan exists and is collected" — which it never could. The question
became whether anything else does. `verify-red` confirmed the first half for
each declared file, and the second only for all of them together.

Worked against `2c5bfba` (0.10.0) on 2026-09-29, macOS 26.6.2 (Darwin 25.6.0),
bash 3.2.57, jq 1.8.2, git 2.50.1, python 3.13.1. The entry is **probed** —
reproduced here, with the observation quoted.

The fix is exercised by `scripts/check-work.sh`, scenario 26, through the
scripted runner and the gate run by hand: no model, no network.

---

## Open

None. What was deliberately not done, and why, is under the entry.

---

## Closed

### 1. A declared test file the runner never collects counts toward coverage — probed

`verify-red` checks that each file in the plan's `files.tests` exists, and that
the report holds at least one new test from them — from all of them, together:

```sh
[ "$new_count" -gt 0 ] || aif_g_reject "no new tests were collected from the declared test files"
```

Coverage — every criterion's id is referenced, and its `expect` literal
appears — was then a `grep -F` over the *text* of every declared file. Nothing
asked whether a file had contributed a collected test. Declare `tests/t1.py`
and `tests/t2.py`, let the runner never collect `t2.py` — a name outside
`testMatch` or `python_files`, or a jest suite that fails to load, which
jest-junit leaves out of the report by default — and a criterion whose only
test is in `t2.py`:

- passes `verify-red` as covered;
- is frozen into `tests.lock.json`'s `tests`, with none of its tests in
  `covering`, so `green`'s revert-recheck never targets them;
- is not run by `green` either, when the runner does not select the file: the
  suite exits 0 without it, and the cross-check of the report against the
  runner (`docs/DEFECTS-4.md` #3) has nothing to catch. A jest suite that
  failed to load at red may load once the code exists and run at `green` —
  outside `covering`, so nothing ever asks whether it depends on the
  implementation — or fail to load still, and stop `green` after the implement
  station has been paid for.

The gate's own header had it right — "A test that was never collected did not
fail — it is absent" — and enforced it for the aggregate only. The tests
station cannot check it, so the gate is the only thing that can.

Probed in a scratch repository: the pytest template, with a stub suite whose
report holds `tests.t0::t0` (pass) and `tests.t1::test_conflict_AC_001`
(`AssertionError: 200 != 409`) and exits 1; a ticket with `AC-001` (`409`) and
`AC-002` (`410`); a plan declaring both test files; `t1.py` naming AC-001 and
409, `t2.py` naming AC-002 and 410.

```
$ bash sets/claude/gates/verify-red.sh tasks/T-1
verify-red: 1 new test(s) red for the right reason, all criteria covered
exit 0
covering: ["tests.t1::test_conflict_AC_001"]
tests:    ["tests/t0.py", "tests/t1.py", "tests/t2.py"]
```

Through the worker it goes all the way. Scenario 26's stub runner never
collects `tests/t2.py`, and its tests station puts AC-002's only test there;
against 0.10.0's gate the ticket was `built`, and the ledger says every gate
passed:

```
verify-red: pass — verify-red: 1 new test(s) red for the right reason, all criteria covered
green: pass — green: suite passes, and the covering tests depend on the implementation, 1 skipped elsewhere in the suite
```

**Fixed.** In per-test mode coverage reads only the declared files the report
holds at least one new test from — the file column of the rows the gate has
already classified. A criterion whose id or literal is found only in a file the
runner collected nothing from is rejected — exit 1, so the tests station gets
it back verbatim — naming the file; and the rejection then names every declared
file that contributed no test, with what makes a file uncollected:

```
REJECT coverage: 3 problem(s)
  - AC-002 is referenced only where the runner collected no test: tests/t2.py
  - AC-002 expected value (410) appears only where the runner collected no test: tests/t2.py
  - the runner collected no test from: tests/t2.py — a test there runs neither at this gate nor at green
      A file is not collected when its name or place is outside what the runner selects (testMatch, python_files, the test roots), or when it fails to load and the reporter leaves it out (jest-junit does, unless reportTestSuiteErrors is set).
      A support file — a helper, a conftest — needs no test of its own, and counts toward no criterion.
```

A declared support file is still allowed: it counts toward no criterion, and
the pass path names it on a line of its own. Scenario 26 retries the way a
station would — the test moves into `t1.py`, `t2.py` stays declared as a
helper — and the ticket is built with `t2.py` frozen and `covering` holding
the test that runs.

Two consequences, both deliberate:

- **An id or literal kept only in a helper or a fixture no longer counts.** The
  station prompt has always said the id goes on the test and the literal is
  the thing asserted, present in the test's text; the old grep was lenient by
  accident.
- **The rejection may not be the tests station's to clear.** A plan can declare
  a path the runner does not select, and the station writes only the declared
  files. It can move the test into another declared file that is collected, as
  scenario 26 does; if there is none, it spends its attempts and the run stops —
  exactly what "no new tests were collected" already did when no declared file
  was collected. The rejection names the selection rules, so whoever reads the
  stop knows where to look.

**Not done.** Coarse mode has no per-test report and cannot tell a collected
file from one the runner never saw. It reads every declared file, as before,
and its closing lines now say so:

```
  ! coverage was read from every declared test file — whether the runner collects each one cannot be told here.
```

And the check is by file, not by test: in a collected file, a function the
runner does not collect — a helper not named `test_*` — still counts when it
carries the id and the literal. The report names tests, not the criteria they
serve, so there is nothing to answer the finer question from.
