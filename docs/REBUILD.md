# Rebuild: from a CLI pipeline to an in-session foundry

Status: plan, not yet implemented. Written after driving OPES-48 through the
current pipeline on a real project and finding what broke.

## Why

The current shape is a bash orchestrator that shells out to `claude -p` once per
station. It works, and its cost accounting is honest. But driven for real it has
four defects that are all the same defect:

1. **The user cannot see the work.** A station's reasoning is written to a temp
   file and deleted (`cmd_station.sh:241`). What reaches the screen is one line:
   `ran plan (attempt 1, N output tokens)`. For plan and plan-judge that is the
   entire user-visible output of a $1.27 and a $0.77 step.
2. **Every stage is its own command.** `aif create-ticket`, `aif station run`,
   `aif approve`, `aif status` — a surface the user has to learn and sequence by
   hand, when the thing that should sequence it is already sitting in the session.
3. **The session and the pipeline are two different worlds.** When implement
   failed, the session finished the feature itself, in-session, outside every
   gate — and nothing recorded that it happened. `green` and `scope` never ran.
4. **The ledger under-counts exactly where it matters.** Its error branch omits
   `reported_cost_usd`, so a failed attempt is recorded poorer than a successful
   one. And work that lands outside the pipeline is invisible. Both biases point
   the same way: the worse the foundry performs, the better its numbers look.
   `ledger.sh:14` names this as the failure mode to avoid. It arrived anyway.

The fix is one architectural move: **the Claude session becomes the orchestrator,
and the stations become subagents.**

## What the probe established

Two assumptions had to hold before this was worth planning. Both were tested on
this machine against Claude Code 2.1.212, not assumed.

**1. Per-station cost accounting survives the move.** A `SubagentStop` hook
receives, on stdin:

```json
{
  "agent_id": "a7b71f6844502e02f",
  "agent_type": "general-purpose",
  "agent_transcript_path": ".../<session>/subagents/agent-<id>.jsonl",
  "transcript_path": ".../<session>.jsonl",
  "last_assistant_message": "...",
  "session_id": "...", "prompt_id": "...", "cwd": "..."
}
```

`agent_transcript_path` is a dedicated field pointing at that one subagent's
transcript. Every assistant turn in it carries `message.usage` (all four token
classes) and `message.model`. Rolling it up gives exactly what the `claude -p`
envelope gives today — verified against a live subagent run:

```json
{ "turns": 3, "model": "claude-opus-4-8",
  "input": 6, "output": 10, "cache_read": 27882, "cache_write": 14961 }
```

Two traps, both found by measurement:
- `usage` repeats per content block (36 rows for 14 real requests). **Dedupe by
  `message.id`** or the cost inflates ~2.5x.
- Some entries carry `model: "<synthetic>"`. Not billed. **Filter them out.**

This is strictly better than the current envelope: `total_cost_usd` is
structurally 0 under subscription auth (FINDINGS #2), whereas a token rollup
works under any auth, survives a failed station, and is per-turn rather than a
single total — so a 30-turn thrash is visible as a thrash.

**2. The orchestrator/subagent boundary is enforceable.** A `PreToolUse` payload
carries `agent_id` and `agent_type` **only** when the tool call originates in a
subagent. From the main session those keys are absent entirely:

```
PreToolUse from subagent:  { "agent_id": "a7b7…", "agent_type": "general-purpose" }
PreToolUse from session:   { }            # keys not present
```

So `guard.sh` can enforce "the orchestrator never writes code itself" with a
presence check, and defect #3 above becomes structurally impossible rather than
merely discouraged.

**3. Incidental: FINDINGS #7 is wrong as stated.** It claims a `claude -p`
spawned inside a Claude Code session cannot authenticate. The probe ran exactly
that, from an OAuth session with no `ANTHROPIC_API_KEY`, and got
`is_error: false`. The 401 recorded in #7 was real but not general — it must be
narrowed to the conditions it was actually observed under, or retired. This
matters because the "real terminal only" rule in `cmd_run.sh:14` rests on it.

## Target shape

```
aif run <ID | board-link>          ← the ONLY user-facing pipeline command
  │
  ├─ resolves profile, preflights doctor, resolves/creates tasks/<ID>/
  └─ exec claude "/aif <ID>"       ← an ordinary interactive session

        the /aif skill = the orchestrator
          │
          ├─ asks `aif _state <ID>` which station is next   (bash decides, not the model)
          ├─ Task → aif-spec        (subagent, careful tier)
          │    └─ SubagentStop hook → rolls up tokens → ledger
          ├─ runs the gate (bash, unchanged)
          ├─ human approval — in chat, in front of the AC list
          ├─ Task → aif-plan / aif-plan-judge / aif-tests / aif-implement
          └─ on rejection: repairs in-session with the user
```

Nothing about the *verification* model changes. Gates stay bash scripts run
against current bytes. The ledger stays append-only and hash-chained. Artifact
hash bindings stay. Only the *driver* and the *execution surface* change.

## Invariants that must survive

Written down because they are the reason the current design is worth keeping at
all, and a rewrite is exactly where they get quietly dropped.

| Invariant | Where it lives now | After |
| --- | --- | --- |
| State is derived, never stored | `cmd_ticket.sh:63` | `aif _state` (JSON), same gate-run logic |
| Gates pass *now*, not *passed once* | gate scripts | unchanged |
| One ledger row per attempt, never updated | `ledger.sh:38` | unchanged, written by hook |
| Tokens are the raw datum; dollars derived | `ledger.sh:15` | **finally true** — price table |
| Approval binds to the spec's bytes | `cmd_ticket.sh:284` | unchanged |
| `tests.lock` binds to the plan's bytes | `green.sh:38` | unchanged |
| Implementation cannot touch pipeline machinery | `scope.sh:41` denylist | denylist extended to `tasks/` |
| One commit per accepted station | `cmd_station.sh:287` | orchestrator calls the same helper |

## Phases

Ordered so each phase leaves the tree working. Phases 1 and 6 are independent of
the architectural move and can land first.

### Phase 1 — Foundations (no architecture change) — **DONE**

Verified by `make lint`, `make check`, and `scripts/demo.sh` (12 gate assertions,
no failures), plus an end-to-end `init → project init → create-ticket → status`
in a scratch repo.

Two things the work turned up that were not in the plan:

- **The `unchanged` ledger branch had the same defect as the `error` branch** —
  no `reported_cost_usd`. Both are fixed; all three paths (success, unchanged,
  error) now record identical fields.
- **An old `project.json` now fails validation**, by design and with a usable
  message (`tiers.routine is required` / `tiers.careful is required`) rather than
  a silent fallback. A project initialised before this change must have its
  `tiers` block replaced. This is the migration question below, arriving early
  and answered as a hard break for `project.json` specifically.

- **`tasks/<ID>/` replaces `.aif/work/<ID>/`**, with all of the ticket's files
  (`ticket.md`, `spec.md`, `plan.md`, `ledger.json`, `approval.json`,
  `tests.lock`). `.aif/` keeps only install-managed things: `project.json`,
  `gates/`, `agents/`, `hooks/`, `skills/`.
  - `gates/_lib.sh:104` walks upward to find `project.json`, so it is
    depth-agnostic — no change needed there. Verified.
  - **`scope.sh:41` denylist must gain `^tasks/`.** Without this an
    implementation could edit its own plan and ledger. This is load-bearing, and
    it is a *different* defence from the plan's file list: "not in the plan"
    cannot stop an implementation that adds itself to the plan. `demo.sh` now
    runs exactly that attack — a plan amended to permit `tasks/PROJ-1/plan.md`
    and `tasks/PROJ-1/ledger.json`, then a tampered ledger — and asserts the
    denylist is what rejects it.
  - 17 files reference `.aif/work`; all need updating.
- **Two tiers.** `routine` → sonnet, `careful` → opus. The tier means "the
  cheapest engine whose errors the gates catch", which with two levels reads
  directly: routine where gates catch, careful where they do not. `risk` in the
  ticket stays three-valued (it is a human judgement about the work, not about a
  model) and maps `low|medium → routine`, `high → careful`.
  - Touches: `project.templates/*.json`, every `stations/*.md` tier declaration,
    `cmd_station.sh:84` risk remap, README.
  - Removes haiku entirely, which is what put implement into a 30-turn spiral on
    OPES-48 at 1.48M cache-read for 10.7k output.
- **Ledger error-branch fix** (`cmd_station.sh:200`): add `reported_cost_usd`,
  `cost_source`, and `subtype`. Phase 4 supersedes this, but it is three lines
  and stops the bleeding now.
  - `subtype` is recorded, never branched on. FINDINGS #2 forbids *branching*;
    it was over-read into *not recording*, and that cost a whole diagnosis.

### Phase 2 — Stations become subagents — **DONE**

Verified by `make lint`, `make check` (which now runs `scripts/check-set.sh`),
`scripts/demo.sh`, and one live `aif station run spec` in a scratch repo —
which resolved `tier careful → model opus`, ran, and wrote a spec. That last
run also confirms the frontmatter never reaches the system prompt: the station
behaved correctly on an empty template ticket, refusing to invent scope and
recording an assumption saying so.

Two decisions the plan did not anticipate:

- **`implement` needs two agent files, not one.** Its tier comes from the
  ticket's risk, and YAML frontmatter is static — a subagent's model cannot be
  chosen at dispatch time. So `aif-implement` (sonnet) and
  `aif-implement-careful` (opus) exist, generated so their bodies are identical
  by construction, and the orchestrator picks by risk. `meta.agents` records the
  mapping.
- **The two consumers of a station file can now disagree.** The runner reads the
  frontmatter (`model`), aif reads `aif:meta` (`tier`) — nothing forces them to
  agree, and a disagreement means a station silently on the wrong engine, which
  is exactly the class of defect that made this rebuild necessary.
  `scripts/check-set.sh` asserts they agree, that the tier variants have not
  drifted, and that the guard hook routes correctly. It was verified to fail
  when either is broken, because a check that cannot fail proves nothing.

- Each `sets/claude/stations/<name>.md` becomes
  `sets/claude/agents/aif-<name>.md` with subagent frontmatter: `name`,
  `description`, `model`, `tools`.
- The `aif:meta` block stays and stays authoritative — `produces`, `judges`,
  `freezes`, `gates`, `requires`, `requires_recorded`, `tier`. The orchestrator
  and `aif _state` read it, exactly as `cmd_station.sh` does today.
- **New: `expects` field** — a static, human-readable description of the
  artifact the station will produce ("verdict-plan.json with fields …"). The
  orchestrator prints it *before* dispatching, so the user knows what is coming.
  Static from the declaration, not model-generated: cheap, predictable, no extra
  reasoning round.
- **Tool scoping moves from the env marker to subagent frontmatter.** Today
  `guard.sh` reads `AIF_STATION` exported by `cmd_station.sh:165`. A subagent has
  no such env, but it has `agent_type` in the hook payload — which is the same
  information arriving by a better route. `guard.sh` switches to that.
- **Model routing still works.** `aif run` exports the profile env before
  `exec claude`; subagents inherit it, so `model: opus` still resolves to
  `glm-5.2` on the glm profile. The three-level indirection is preserved.

### Phase 3 — The orchestrator skill and the single entry point

- **`sets/claude/skills/aif/SKILL.md`** — the orchestrator. Responsibilities:
  ticket resolution, dispatching subagents in order, running gates, presenting
  approvals, driving repair. It does **not** decide what is next by itself.
- **`aif _state <ID>` → JSON.** Same derivation as `cmd_ticket.sh:63`, emitted as
  data. This is deliberate: if "what runs next" lives in the model's head, the
  state machine is gone. Bash decides; the model dispatches.
- **`aif run [<ID> | <link>]`** — resolve, preflight, `exec claude "/aif <ID>"`.
  - Board link: extract `OPES-\d+` from the card title, look for `tasks/<ID>/`.
    Found → resume at the derived stage. Not found → create and start at the
    interview. Pulling the card is the MCP connector's job and the user's to set
    up (already how `aif-ticket` works).
  - A fully-finished ticket resolves to "done" and the orchestrator says so
    rather than re-running anything.
- **Commands removed:** `create-ticket`, `status`, `station`, `approve`, `start`.
- **Commands kept:** `init`, `uninstall`, `doctor`, `project`, `profiles`,
  `test`, `version`, `help` — the library's own surface.
- **Internal, underscore-prefixed, called by the skill and hooks:** `_state`,
  `_gate`, `_ledger`, `_commit`, `_ticket-init`. Not in `--help`.
  - *This is a deliberate deviation from "remove the commands".* The commands
    that go are the ones a **user** had to sequence. An internal surface has to
    remain, because the alternative is moving gate execution and ledger writes
    into the model's judgement — and that is precisely the integrity the foundry
    exists to provide.

### Phase 4 — Accounting

- **`sets/claude/hooks/meter.sh` on `SubagentStop`.** Reads the payload, rolls up
  `agent_transcript_path` (dedupe by `message.id`, drop `<synthetic>`), appends
  one ledger row: station (from `agent_type`), model, tokens, turns, `agent_id`,
  `last_assistant_message` as the outcome summary.
- **Ticket resolution:** the payload has no ticket. `aif run` writes a pointer
  (`.aif/state/current`) that the hook reads.
- **`sets/claude/prices.json`** — model id → per-MTok rates for input, output,
  cache read, cache write. Unknown model → record tokens, cost `null`, never a
  wrong number. Needs maintaining; that is the price of dollar figures.
- **Concurrency:** two subagents finishing together would both read-modify-write
  `ledger.json`. Needs a lock (`mkdir`-based, portable) around the append.
- **The transcript is retained**, not deleted — it is already on disk, and it is
  what `rm -f "$out" "$err"` used to throw away. Defect #1 is fixed by not
  destroying evidence.

### Phase 5 — Boundaries

- **`guard.sh` denies `Write|Edit` when `agent_type` is absent** — the
  orchestrator may not write code, only dispatch. Verified discriminator.
- **Per-station scoping via `agent_type`**: `aif-implement` may not write under
  `test.roots`; `aif-tests` may not write implementation. Same rules as today,
  new signal.
- **Approval.** Written by the orchestrator after showing the AC list and the
  spec's assumptions in chat. `approval.json` keeps `subject_sha256`, gains the
  user's verbatim confirmation text, and `tty: true` becomes
  `channel: "chat"`.
  - **Stated honestly:** the TTY check was a real capability boundary — an
    agent's Bash tool is not a terminal. Chat approval is a weaker guarantee: a
    model *could* fabricate consent. We accept this because the boundary was
    already porous (a pty wrapper defeats it) and because it blocked the
    intended workflow. It must be documented as a trust assumption in the
    README, not left implied.

### Phase 6 — Gates (independent of the architecture)

- **`doctor` preflights the test toolchain.** Run `test.command`, confirm a
  report appears at `test.report.path` in the declared format, confirm `python3`
  is on PATH for `junit.py`. OPES-48 discovered a missing `jest-junit` at the
  *last* gate, after ~$6.61 was spent. `aif run` calls this before dispatching
  anything.
- **`plan-judge` verifies manifest coverage.** It gains `spec.md` as an input and
  checks that `files.create + files.change` plausibly covers every surface the
  spec names. This moves the `scope` rejection from after implementation to
  before it.
- **`implement` may amend the manifest.** When it needs a file the plan could not
  foresee, it appends to `files.change` and the amendment is recorded in the
  ledger as a distinct event (`plan-amended`, with the file and the reason).
  `scope` then checks against the amended plan. The escape hatch exists, and it
  is never silent.

### Phase 7 — Cleanup

- Delete `lib/cmd_station.sh`, `lib/cmd_run.sh`, `lib/cmd_start.sh`; reduce
  `lib/cmd_ticket.sh` to the internal helpers.
- `skills/aif-fix` folds into the orchestrator — repair is now just the session
  doing what a session does, with the user present.
- README: rewrite the pipeline section; remove haiku; document the chat-approval
  trust assumption.
- `scripts/demo.sh`: rewrite against the new entry point.
- `docs/FINDINGS.md`: narrow or retire #7; add the `usage`-duplication and
  `<synthetic>` findings; add the "recording ≠ branching" note on `subtype`.
- Migration for existing `.aif/work/<ID>/` tickets, or an explicit clean break.

## What we knowingly give up

1. **Hard human-presence guarantee at approval.** Phase 5. Traded for a workflow
   that works; documented, not hidden.
2. **`total_cost_usd` from the vendor.** Replaced by a token rollup priced from a
   table we maintain. More accurate under subscription, but the table can go
   stale — an unknown model records tokens and a null cost rather than guessing.
3. **A bash-guaranteed station order.** The orchestrator is a model. Mitigated on
   two levels: `aif _state` decides what is next, and the gates' hash bindings
   mean a station run out of order still cannot produce an admissible artifact
   (`green` requires a `tests.lock` bound to the current plan's bytes). Integrity
   survives a disobedient orchestrator; tidiness does not.

## Open

- Migration vs clean break for tickets already under `.aif/work/`.
- Whether `aif test` (the eval harness) stays as-is or moves to subagents too. It
  has the same visibility problem but is not on the user's critical path.
