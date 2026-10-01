# jest — what the gates see, in this runner's terms

This fragment ships with aif (`sets/claude/stacks/jest.md`) and is appended to
the plan and tests stations' instructions when the project's runner is jest.
It is data, not advice: each rule below is one a gate enforces or one the
runner has, and none of it is to be rediscovered per ticket. The project's own
guide follows it, and says where things live here.

## How a run is read

- The suite is `test.command` in `.aif/project.json`, with jest-junit writing
  one `<testcase>` per test to the report the gates read. The gates never read
  jest's console output: a test is what the report says it is.
- jest-junit names a case from the describe path and the title — `classname`
  and `name` are both `{classname} {title}` by default, ancestors joined by a
  space. The gate's id for a test is `classname::name`, lower-cased with every
  run of punctuation folded to `_`: a title holding `OPES-69 AC-003` is found
  as `opes_69_ac_003` wherever it sits in the describe path or the title. A
  comment is not a title, and a file's text is not searched.
- **A file that fails to load leaves no `<testcase>` at all.** `reportTestSuiteErrors`
  is off by default; switched on, the one synthetic case it writes carries
  `Test suite failed to run`, which `failure_classes.broken` refuses. To the
  gate such a file is not red, it is absent: "the runner collected no test
  from: <file>", and every criterion whose only test was in it is "carried by
  no collected test". A file fails to load on: an import of a path that does
  not exist, a syntax error, a `jest.mock` factory that reaches a variable not
  named `mock…`, ESM syntax the transform does not handle (`Cannot use import
  statement outside a module`), a `testEnvironment` the file assumes and the
  configuration does not set.
- A new test is **red for the right reason** when its message matches
  `failure_classes.legitimate` — `expect(`, `toBe`, `toEqual`, `toThrow`,
  `toHave`, `toMatch`, … — or carries `aif: not implemented`. `TypeError: x is
  not a function`, `Cannot read properties of undefined`, `ReferenceError`
  are neither: the test calls a name the contract does not export or reaches a
  seam the skeleton does not have, and the gate names the test and sends it
  back.
- A file is **collected** when its path matches `testMatch` or `testRegex`
  (jest's defaults: `**/__tests__/**/*.[jt]s?(x)` and
  `**/?(*.)+(spec|test).[jt]s?(x)`) and falls under no
  `testPathIgnorePatterns` / `modulePathIgnorePatterns` / `roots` exclusion.
  Where the project narrows these, the guide's configuration lines say how;
  write the file where the existing tests are and named as they are named.
- The suite runs **twice** at the freeze. A test whose verdict differs between
  the runs is non-deterministic and rejected: no `Date.now()` or `new Date()`
  without `jest.useFakeTimers()` and `jest.setSystemTime(...)`, no
  `Math.random`, no dependence on test order or on state another test leaves.
- Where the project binds a type-check to the `red` phase (`npx tsc --noEmit`
  where a tsconfig was found), it runs over the tree with the skeleton on disk,
  and a type error in a test file is the test's — a mock typed as the wrong
  shape, a call with the wrong arity — and a rejection.
- `verify-red` also resolves every relative import in a declared test file
  against the disk (with jest's extensions and index files). One that resolves
  to nothing is a misspelling, named in the complaint.

## The contract in TypeScript or JavaScript — the plan station

A skeleton is a module that loads, exports its real names with their real
types, and does nothing: every body throws the marker.

```ts
// src/services/subscriptions/detectRecurring.ts
import type { Transaction } from '../../domain/transactions';

export interface DetectedSubscription { merchant: string; cadenceDays: number; confidence: 'high' | 'low' }

export const detectRecurring = (transactions: Transaction[]): DetectedSubscription[] => {
  void transactions; // the parameter keeps its real name; noUnusedParameters would otherwise reject the skeleton
  throw new Error('aif: not implemented: detectRecurring');
};
```

- **Types, interfaces, enums, constants are written for real** — they are
  contract, not behaviour, and a test of a constant being green at the freeze
  is honest. A barrel (`index.ts`) is written for real: re-exports are contract.
- **A default export** is `export default function name(...): T { throw … }`.
  **A React component** has its real props type and a body that throws:
  `export function SubscriptionSheet(props: SubscriptionSheetProps): JSX.Element { void props; throw new Error('aif: not implemented: SubscriptionSheet'); }`
  — rendering it in a test fails with the marker, which is red for the right
  reason. **A hook** is a function that throws. **A class** keeps its real
  constructor signature and fields; every method throws.
- **A new export in a module the plan changes** is appended with a throwing
  body; the rest of the file is left as it is.
- **The marker is exactly** `aif: not implemented: <name>`. Nothing else in a
  body: no defaults that happen to be the answer, no early return, no
  `return [] as never`.
- **Imports in a skeleton point at files that exist.** A skeleton that does not
  load makes every test of it uncollectable, and that complaint reaches the
  tests station, which may not edit your file. The plan gate resolves the
  skeleton's relative imports and refuses one that resolves to nothing; a
  bare package import it cannot check — look the package up in this
  repository's existing callers.
- **It compiles.** With a type-check bound to `contract`, the compiler runs
  over the tree as you left it and the plan is rejected with its lines. Under
  `noUnusedParameters` / `noUnusedLocals`, `void param;` before the throw keeps
  the real parameter names without a rename the implementer would undo.

## The tests — the tests station

```ts
import { detectRecurring } from '../../src/services/subscriptions/detectRecurring';
import { makeTransaction } from '../factories/transaction'; // the guide says where the factories are

describe('detectRecurring', () => {
  it('OPES-69 AC-003 — a merchant seen on three consecutive salary days is high confidence', () => {
    const txs = [10, 11, 12].map((m) => makeTransaction({ merchant: 'Netflix', month: m }));
    expect(detectRecurring(txs)).toEqual([{ merchant: 'Netflix', cadenceDays: 30, confidence: 'high' }]);
  });
});
```

- **The marker goes in the `it` title** (or a `describe` title above it):
  `<TICKET> AC-nnn`, then the words. One criterion may have several tests;
  each carries the marker.
- **Import the skeleton statically, and call it.** Do not `jest.mock` the
  module under test or any module the plan creates: mocked, it is green against
  anything, and the revert-recheck at green rejects a test that does not depend
  on the implementation.
- **Mock only the boundaries** the plan names as external or injected — the
  network, the clock, the device, a store — and mock them the way this project
  does: the guide names its manual mocks (`__mocks__`), setup files, factories
  and the libraries it uses for HTTP and time. A mock that does not exist in the
  repository is a reason to look again, not to invent one.
- **`jest.mock()` is hoisted above the imports** by the transform. Its factory
  may reference only variables whose names start with `mock` (and `jest`
  itself); anything else is `ReferenceError: Cannot access before
  initialization` at load, and the file is absent from the report. A relative
  path given to `jest.mock` is relative to the test file. `jest.requireActual`
  keeps the rest of a partially mocked module real.
- **A test that asserts a throw passes against the skeleton** — the skeleton
  throws. `expect(() => parse(bad)).toThrow()` is green now and proves
  nothing. Assert the specific error — `toThrow(ValidationError)`,
  `toThrow('amount must be positive')` — which the marker's message does not
  match, so the test is red now and green only when the behaviour throws the
  right thing. For async: `await expect(fn()).rejects.toThrow(SpecificError)`.
- **Assert the criterion's literal**, with `toBe`, `toEqual`, `toHaveLength`,
  `toHaveBeenCalledWith` — the value the criterion's `expect` names must appear
  in the file. `toBeDefined()`, `not.toBeNull()`, `toBeTruthy()` pass against
  any stub and are not evidence.
- **No snapshots.** `toMatchSnapshot()` under `--ci` fails without writing one,
  and a snapshot written any other way appears under the test tree after the
  freeze — which green rejects as a modified oracle.
- **Components** render through the project's providers the guide names (a
  navigation container, a theme, a store), and assert on what the user sees
  (`screen.getByText`, `getByRole`), not on internals. A component skeleton
  throws on render: wrap nothing in `try`; the throw is the red.
- **Async behaviour** is awaited (`await`, `findBy…`, `waitFor`), never timed
  with a real `setTimeout`.
- **Leave the suite as it was.** Restore what you mock (`jest.restoreAllMocks`
  in `afterEach`, or the project's setup already does); no global patched and
  left patched; no shared fixture mutated.
- The tests station runs `aif _verify <TICKET>` after writing: it is this gate,
  without the freeze. What it prints is what the freeze would print.
