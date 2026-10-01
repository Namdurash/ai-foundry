# pytest — what the gates see, in this runner's terms

This fragment ships with aif (`sets/claude/stacks/pytest.md`) and is appended
to the plan and tests stations' instructions when the project's runner is
pytest. It is data, not advice: each rule below is one a gate enforces or one
the runner has, and none of it is to be rediscovered per ticket. The project's
own guide follows it, and says where things live here.

## How a run is read

- The suite is `test.command` in `.aif/project.json`, run with `--junitxml`,
  and the gates read that report, one `<testcase>` per test — never pytest's
  console output. A test is what the report says it is.
- pytest names a case from its node id. Under `junit_family=xunit2` (the
  default since pytest 6) `classname` is the dotted module path plus any
  enclosing classes — `tests/api/test_users.py::TestList::test_empty` is
  `classname="tests.api.test_users.TestList" name="test_empty"` — and the
  gate rebuilds the file from it, so a test must live in a module pytest can
  import from the project root. The gate's id for a test is
  `classname::name`, lower-cased with every run of punctuation folded to `_`:
  a function named `test_opes_69_ac_003_period_starts_on_salary_day` carries
  `opes_69_ac_003`, and so does a parametrised `[case-2]` of it.
- **A file that fails to import is one error row**, `ERROR collecting
  tests/test_x.py`, with `classname=""` and the dotted module in `name`. That
  class is in `failure_classes.broken`, and the gate rejects it naming the
  file: a test that did not run is not red. A file fails to import on: a
  syntax or indentation error, an import of a module that does not exist, a
  decorator or fixture referenced at module level that is not defined, two
  files of one basename in directories without `__init__.py` under the default
  import mode (`import file mismatch`).
- A new test is **red for the right reason** when its message matches
  `failure_classes.legitimate` — `AssertionError`, `assert ` (pytest's
  rewritten assertions begin with it) — or carries `NotImplementedError` /
  `aif: not implemented`. `TypeError: detect() got an unexpected keyword
  argument`, `AttributeError: module 'app.x' has no attribute 'y'`,
  `fixture 'db' not found`, `ImportError` are neither: the test calls a name
  or a signature outside the contract, or a fixture that is not there, and the
  gate names the test and sends it back.
- A file is **collected** when its name matches `python_files` (default
  `test_*.py` and `*_test.py`), lies under `testpaths` or the directory the
  command names, and is not under `norecursedirs`; a function is collected
  when it matches `python_functions` (default `test*`), a class when it
  matches `python_classes` (default `Test*`) and has no `__init__`. The guide's
  configuration section says how this project narrows these; write the file
  where the existing tests are and named as they are named.
- The suite runs **twice** at the freeze. A test whose verdict differs between
  the runs is non-deterministic and rejected: no `datetime.now()` or
  `time.time()` without the project's clock fixture (`freezegun`,
  `time-machine`, a `monkeypatch`), no `random` without a seed, no dependence
  on dict or set order, on the filesystem outside `tmp_path`, or on rows
  another test left in the database.
- Where the project binds a type-check to the `red` phase (mypy, pyright), it
  runs with the skeleton on disk, and a type error in a test file is the
  test's — and a rejection.
- `verify-red` also resolves every relative import (`from .x import`,
  `from ..pkg import`) in a declared test file against the disk. One that
  resolves to nothing is a misspelling, named in the complaint. An absolute
  import (`from app.users import …`) is left to the runner, so a wrong one is
  seen as an `ImportError` row — rejected, with the message.

## The contract in Python — the plan station

A skeleton is a module that imports, defines its real names with their real
signatures and type hints, and does nothing: every body raises the marker.

```py
# app/subscriptions/detect.py
from dataclasses import dataclass
from typing import Literal

from app.domain.transactions import Transaction


@dataclass(frozen=True)
class DetectedSubscription:
    merchant: str
    cadence_days: int
    confidence: Literal["high", "low"]


def detect_recurring(transactions: list[Transaction]) -> list[DetectedSubscription]:
    raise NotImplementedError("aif: not implemented: detect_recurring")
```

- **Dataclasses, TypedDicts, Enums, Protocols, pydantic models, constants are
  written for real** — they are contract, not behaviour. A package's
  `__init__.py` is written for real: its re-exports are contract.
- **A class** keeps its real `__init__` signature; a body that only stores
  arguments is contract, every other method raises. **An `async def`** raises
  the same way. **A view, route or command handler** raises: a test through an
  HTTP client then sees the marker (a test client that re-raises) or a 5xx
  (one that does not) — both red, and the test asserts the status the
  criterion names.
- **A new export in a module the plan changes** is appended with a raising
  body; the rest of the file is left as it is.
- **The marker is exactly** `aif: not implemented: <name>`, raised as
  `NotImplementedError`. Nothing else in a body: no default return, no `pass`,
  no `return []`.
- **Imports in a skeleton resolve.** A skeleton that does not import makes
  every test of it a collection error, and that complaint reaches the tests
  station, which may not edit your file. The plan gate resolves the skeleton's
  relative imports and refuses one that resolves to nothing; an absolute
  import it cannot check — look the module up in this repository's existing
  callers, and mind `pythonpath` / `src` layouts the guide's configuration
  shows.
- **It imports and type-checks.** With a type-checker bound to `contract` the
  checker runs over the tree as you left it, and the plan is rejected with its
  lines.

## The tests — the tests station

```py
import pytest

from app.subscriptions.detect import detect_recurring
from tests.factories import make_transaction  # the guide says where the factories are


def test_opes_69_ac_003_period_starts_on_salary_day(frozen_clock):
    txs = [make_transaction(merchant="Netflix", month=m) for m in (10, 11, 12)]
    assert detect_recurring(txs) == [DetectedSubscription("Netflix", 30, "high")]
```

- **The marker goes in the function name** (a class name above it also
  counts): `test_<ticket>_ac_nnn_<words>`, lower case, underscores. One
  criterion may have several tests; each carries the marker.
- **Import the skeleton and call it.** Do not `monkeypatch` or `mock.patch`
  the function under test or any module the plan creates: patched, it is green
  against anything, and the revert-recheck at green rejects a test that does
  not depend on the implementation.
- **Mock only the boundaries** the plan names as external or injected — HTTP,
  the clock, the filesystem, a queue, a third-party SDK — and mock them the way
  this project does: the guide names its `conftest.py` fixtures, factories and
  the libraries it uses (`responses`, `respx`, `freezegun`, `time-machine`,
  `factory_boy`, `pytest-httpx`). A fixture that is not in a `conftest.py` the
  runner loads is `fixture 'x' not found` — a rejection. `monkeypatch.setattr`
  targets the name where it is *looked up* (the module that calls it), not
  where it is defined.
- **A test that asserts a raise passes against the skeleton** — the skeleton
  raises. `with pytest.raises(Exception)` is green now and proves nothing.
  Assert the specific exception — `pytest.raises(ValidationError)`,
  `pytest.raises(ValueError, match="amount must be positive")` — which a
  `NotImplementedError` does not satisfy, so the test is red now and green
  only when the behaviour raises the right thing.
- **Assert the criterion's literal** with `==`, `in`, `pytest.approx`; the
  value the criterion's `expect` names must appear in the file. `assert result`
  and `assert result is not None` pass against any stub and are not evidence.
- **Database tests use the project's transactional fixture** the guide names,
  so nothing a test writes outlives it. **File tests use `tmp_path`.**
- **Parametrise** with `@pytest.mark.parametrize` where a criterion lists
  cases; the id still carries the marker.
- **Leave the suite as it was.** `monkeypatch` undoes itself; a `mock.patch`
  is a context manager or a decorator, never a bare `.start()` without
  `.stop()`; no module-level state mutated for good.
- The tests station runs `aif _verify <TICKET>` after writing: it is this gate,
  without the freeze. What it prints is what the freeze would print.
